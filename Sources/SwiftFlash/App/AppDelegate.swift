import AppKit
import Combine

// MARK: - Per-Window IDE Controller (Multi-Window Support)

@MainActor
final class IDEWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let workspace: WorkspaceState
    let rootController: RootIDEViewController

    private var titleCancellable: AnyCancellable?
    private var themeCancellable: AnyCancellable?
    var onDidClose: ((IDEWindowController) -> Void)?

    init(
        workspace: WorkspaceState,
        cascadeFrom previousWindow: NSWindow? = nil
    ) {
        self.workspace = workspace
        self.rootController = RootIDEViewController(workspace: workspace)

        let initialRect = Self.resolveInitialWindowRect(cascadeFrom: previousWindow)
        self.window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = ZedTheme.background
        window.minSize = NSSize(width: 820, height: 520)
        window.contentViewController = rootController
        updateWindowTitle()

        titleCancellable = workspace.$rootURL
            .combineLatest(workspace.$activeTabID, workspace.$openTabs, workspace.$hasWorkspaceOpen)
            .sink { [weak self] _ in
                self?.updateWindowTitle()
            }

        themeCancellable = ThemeManager.shared.$currentThemeID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.window.backgroundColor = ZedTheme.background
            }
    }

    private static func resolveInitialWindowRect(cascadeFrom previousWindow: NSWindow?) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let prev = previousWindow {
            let offset: CGFloat = 28
            var rect = prev.frame
            rect.origin.x = min(screenFrame.maxX - rect.width, rect.origin.x + offset)
            rect.origin.y = max(screenFrame.minY, rect.origin.y - offset)
            return rect
        }

        if let saved = SessionPersistence.loadWindowFrame(),
           saved.width >= 820,
           saved.height >= 520 {
            let candidate = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                return candidate
            }
        }

        let width = min(1360, screenFrame.width * 0.88)
        let height = min(860, screenFrame.height * 0.88)
        let originX = screenFrame.midX - width / 2
        let originY = screenFrame.midY - height / 2
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateWindowTitle() {
        let tab = workspace.focusedTab ?? workspace.activeTab
        guard workspace.hasWorkspaceOpen else {
            if let tab {
                let dirtyMark = tab.isDirty ? " •" : ""
                window.title = "\(tab.title)\(dirtyMark) — SwiftFlash"
            } else {
                window.title = "SwiftFlash"
            }
            return
        }
        let folderName = workspace.rootURL.lastPathComponent
        if let tab {
            let dirtyMark = tab.isDirty ? " •" : ""
            window.title = "\(tab.title)\(dirtyMark) — \(folderName) (SwiftFlash)"
        } else {
            window.title = "\(folderName) — SwiftFlash"
        }
    }

    func persistWindowGeometry() {
        let f = window.frame
        SessionPersistence.saveWindowFrame(
            PersistedWindowFrame(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height)
        )
    }

    func shutdownWindowResources() {
        persistWindowGeometry()
        rootController.mainSplitController.shutdownTerminal()
        workspace.teardownResources()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        workspace.confirmTerminationWithUnsavedChanges()
    }

    func windowWillClose(_ notification: Notification) {
        shutdownWindowResources()
        onDidClose?(self)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistWindowGeometry()
    }

    func windowDidMove(_ notification: Notification) {
        persistWindowGeometry()
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [IDEWindowController] = []
    private var themeCancellable: AnyCancellable?
    private var systemAppearanceObserver: NSObjectProtocol?
    private var pendingOpenURLs: [URL] = []
    private var hasFinishedLaunching = false

    private var activeController: IDEWindowController? {
        if let keyWin = NSApp.keyWindow,
           let matched = windowControllers.first(where: { $0.window === keyWin }) {
            return matched
        }
        return windowControllers.last
    }

    private var activeWorkspace: WorkspaceState? {
        activeController?.workspace
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LocalizationManager.shared
        _ = PluginManager.shared
        NSApp.setActivationPolicy(.regular)
        applyAppThemeAppearance()
        applySystemAppIcon()

        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applySystemAppIcon()
            }
        }

        let launchURLs = Self.parseLaunchArguments(Array(CommandLine.arguments.dropFirst())) + pendingOpenURLs
        pendingOpenURLs.removeAll()

        var initialFolder: URL?
        var remainingURLs: [URL] = []
        var extraDirectories: [URL] = []
        for url in launchURLs {
            if let target = WorkspaceState.parseExternalURL(url) {
                var isDir: ObjCBool = false
                let stdURL = target.url.standardized
                if FileManager.default.fileExists(atPath: stdURL.path, isDirectory: &isDir), isDir.boolValue {
                    if initialFolder == nil {
                        initialFolder = stdURL
                        continue
                    } else if stdURL.path == initialFolder?.path {
                        continue
                    } else {
                        extraDirectories.append(stdURL)
                        continue
                    }
                }
            }
            remainingURLs.append(url)
        }

        buildMainMenu()

        let mainController = createWindow(initialURL: initialFolder, restoreLastProjectIfNil: true)

        themeCancellable = ThemeManager.shared.$currentThemeID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyAppThemeAppearance()
            }

        hasFinishedLaunching = true

        // Register extra directories into window switcher without re-reloading `initialFolder`.
        for extraDir in extraDirectories {
            if !mainController.workspace.windowProjects.contains(where: { $0.standardized.path == extraDir.path }) {
                mainController.workspace.windowProjects.append(extraDir)
            }
            mainController.workspace.recordRecentProject(extraDir)
        }
        if !remainingURLs.isEmpty {
            mainController.workspace.openExternalURLs(remainingURLs)
        }
    }

    @discardableResult
    func createWindow(initialURL: URL?, restoreLastProjectIfNil: Bool) -> IDEWindowController {
        let ws = WorkspaceState(
            initialURL: initialURL,
            userDefaults: .standard,
            restoreLastProjectIfNil: restoreLastProjectIfNil
        )
        ws.onNewWindowRequested = { [weak self] in
            self?.newWindowAction(nil)
        }
        ws.onOpenFolderInNewWindowRequested = { [weak self] in
            self?.openFolderInNewWindowAction(nil)
        }

        let controller = IDEWindowController(workspace: ws, cascadeFrom: activeController?.window)
        controller.onDidClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        controller.show()
        return controller
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard hasFinishedLaunching, let controller = activeController else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        controller.workspace.openExternalURLs(urls)
        controller.show()
    }

    private func applyAppThemeAppearance() {
        let isDark = ThemeManager.shared.palette.isDark
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        for controller in windowControllers {
            controller.window.backgroundColor = ZedTheme.background
        }
    }

    private func applySystemAppIcon() {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        let isSystemDark = (style == "Dark")
        let resourceName = isSystemDark ? "AppIcon-Dark" : "AppIcon-Light"

        if let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
            return
        }
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in windowControllers {
            if !controller.workspace.confirmTerminationWithUnsavedChanges() {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
            self.systemAppearanceObserver = nil
        }
        for controller in windowControllers {
            controller.shutdownWindowResources()
        }
        LSPManager.shared.shutdownAll()
    }

    nonisolated static func parseLaunchArguments(_ arguments: [String]) -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        for arg in arguments {
            guard !arg.isEmpty else { continue }
            let lower = arg.lowercased()
            if lower.hasPrefix("swiftflash://") || lower.hasPrefix("file://") {
                if let url = URL(string: arg) {
                    urls.append(url)
                } else if let encoded = arg.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                          let url = URL(string: encoded) {
                    urls.append(url)
                }
                continue
            }
            let fileURL = URL(fileURLWithPath: arg).standardized
            let exists = fm.fileExists(atPath: fileURL.path)
            if arg.hasPrefix("-") && !exists {
                continue
            }
            if exists {
                urls.append(fileURL)
            }
        }
        return urls
    }

    // MARK: - Menu Actions

    @objc private func newWindowAction(_ sender: Any?) {
        createWindow(initialURL: nil, restoreLastProjectIfNil: false)
    }

    @objc private func openFolderInNewWindowAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n("dialog.openFolder.prompt")
        panel.message = L10n("dialog.openFolder.message")
        if panel.runModal() == .OK, let url = panel.url {
            createWindow(initialURL: url, restoreLastProjectIfNil: false)
        }
    }

    @objc private func openFolderAction(_ sender: Any?) {
        activeWorkspace?.openFolderPanel()
    }

    @objc private func newFileAction(_ sender: Any?) {
        activeWorkspace?.createNewUntitledFile()
    }

    @objc private func saveFileAction(_ sender: Any?) {
        activeWorkspace?.saveActiveTabWithOptionalFormatting()
    }

    @objc private func closeTabAction(_ sender: Any?) {
        activeWorkspace?.closeActiveTab()
    }

    @objc private func quickOpenAction(_ sender: Any?) {
        activeWorkspace?.toggleOverlay(.quickOpen)
    }

    @objc private func commandPaletteAction(_ sender: Any?) {
        activeWorkspace?.toggleOverlay(.commandPalette)
    }

    @objc private func symbolOutlineAction(_ sender: Any?) {
        activeWorkspace?.toggleOverlay(.symbolOutline)
    }

    @objc private func switchProjectAction(_ sender: Any?) {
        activeWorkspace?.toggleOverlay(.projectSwitcher)
    }

    @objc private func switchWorktreeAction(_ sender: Any?) {
        activeWorkspace?.toggleOverlay(.worktreeSwitcher)
    }

    @objc private func switchBranchAction(_ sender: Any?) {
        activeWorkspace?.toggleOverlay(.branchSwitcher)
    }

    @objc private func openSettingsAction(_ sender: Any?) {
        activeWorkspace?.toggleOverlay(.settings)
    }

    @objc private func zoomInAction(_ sender: Any?) {
        ThemeManager.shared.increaseFontSize()
    }

    @objc private func zoomOutAction(_ sender: Any?) {
        ThemeManager.shared.decreaseFontSize()
    }

    @objc private func resetZoomAction(_ sender: Any?) {
        ThemeManager.shared.resetFontSize()
    }

    @objc private func globalSearchAction(_ sender: Any?) {
        activeController?.rootController.mainSplitController.ensureSidebarVisible(mode: .search)
        activeWorkspace?.searchFocusNonce &+= 1
    }

    @objc private func toggleGitPanelAction(_ sender: Any?) {
        activeController?.rootController.mainSplitController.selectOrToggleSidebar(mode: .git)
    }

    @objc private func viewGitDiffAction(_ sender: Any?) {
        activeWorkspace?.openGitDiffInEditor()
    }

    @objc private func toggleSidebarAction(_ sender: Any?) {
        activeController?.rootController.mainSplitController.toggleSidebar()
    }

    @objc private func toggleSplitEditorAction(_ sender: Any?) {
        activeWorkspace?.toggleSplitEditor()
    }

    @objc private func toggleTerminalAction(_ sender: Any?) {
        activeController?.rootController.mainSplitController.toggleTerminal()
    }

    @objc private func newTerminalTabAction(_ sender: Any?) {
        activeWorkspace?.onNewTerminalTabAction?()
    }

    @objc private func toggleCommentAction(_ sender: Any?) {
        activeWorkspace?.onToggleCommentRequested?()
    }

    @objc private func selectNextOccurrenceAction(_ sender: Any?) {
        activeWorkspace?.onSelectNextOccurrenceAction?()
    }

    @objc private func deleteLineAction(_ sender: Any?) {
        activeWorkspace?.onDeleteLinesAction?()
    }

    @objc private func formatDocumentAction(_ sender: Any?) {
        activeWorkspace?.formatActiveDocument()
    }

    @objc private func findAction(_ sender: Any?) {
        activeWorkspace?.presentFindBar(replace: false)
    }

    @objc private func findReplaceAction(_ sender: Any?) {
        activeWorkspace?.presentFindBar(replace: true)
    }

    @objc private func findNextAction(_ sender: Any?) {
        activeWorkspace?.findNextInActiveFile()
    }

    @objc private func findPreviousAction(_ sender: Any?) {
        activeWorkspace?.findPreviousInActiveFile()
    }

    @objc private func goToLineAction(_ sender: Any?) {
        activeWorkspace?.presentGoToLine()
    }

    @objc private func navigateBackAction(_ sender: Any?) {
        activeWorkspace?.navigateBack()
    }

    @objc private func navigateForwardAction(_ sender: Any?) {
        activeWorkspace?.navigateForward()
    }

    @objc private func previousTabAction(_ sender: Any?) {
        activeWorkspace?.selectAdjacentTab(delta: -1)
    }

    @objc private func nextTabAction(_ sender: Any?) {
        activeWorkspace?.selectAdjacentTab(delta: 1)
    }

    @objc private func selectTabNumberAction(_ sender: NSMenuItem) {
        activeWorkspace?.selectTabAtIndex(sender.tag)
    }

    @objc private func triggerCompletionAction(_ sender: Any?) {
        activeWorkspace?.onRequestCompletionAction?()
    }

    @objc private func showHoverAction(_ sender: Any?) {
        activeWorkspace?.onShowHoverAction?()
    }

    @objc private func goToDefinitionAction(_ sender: Any?) {
        activeWorkspace?.onGoToDefinitionAction?()
    }

    @objc private func findReferencesAction(_ sender: Any?) {
        activeWorkspace?.onFindReferencesAction?()
    }

    @objc private func runProjectAction(_ sender: Any?) {
        activeWorkspace?.runDefaultRunTask()
    }

    @objc private func testProjectAction(_ sender: Any?) {
        activeWorkspace?.runDefaultTestTask()
    }

    @objc private func stopTaskAction(_ sender: Any?) {
        activeWorkspace?.stopRunningTask()
    }

    @objc private func showProblemsAction(_ sender: Any?) {
        activeWorkspace?.showBottomPanel(.problems)
    }

    @objc private func showReferencesAction(_ sender: Any?) {
        activeWorkspace?.showBottomPanel(.references)
    }

    // MARK: - Main Menu Bar Construction

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n("menu.app.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(makeItem(L10n("menu.app.settings"), action: #selector(openSettingsAction(_:)), key: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L10n("menu.app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: L10n("menu.file"))
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(makeItem(L10n("menu.file.new"), action: #selector(newFileAction(_:)), key: "n"))
        fileMenu.addItem(makeItem(L10n("menu.file.newWindow"), action: #selector(newWindowAction(_:)), key: "N"))
        fileMenu.addItem(makeItem(L10n("menu.file.openFolder"), action: #selector(openFolderAction(_:)), key: "o"))
        fileMenu.addItem(NSMenuItem(title: L10n("menu.file.openFolderNewWindow"), action: #selector(openFolderInNewWindowAction(_:)), keyEquivalent: ""))
        let switchProjItem = NSMenuItem(title: L10n("menu.file.switchProject"), action: #selector(switchProjectAction(_:)), keyEquivalent: "o")
        switchProjItem.keyEquivalentModifierMask = [.control, .command]
        fileMenu.addItem(switchProjItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(makeItem(L10n("menu.file.save"), action: #selector(saveFileAction(_:)), key: "s"))
        fileMenu.addItem(makeItem(L10n("menu.file.closeTab"), action: #selector(closeTabAction(_:)), key: "w"))

        // Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L10n("menu.edit"))
        editMenuItem.submenu = editMenu
        editMenu.addItem(makeItem(L10n("menu.edit.undo"), action: Selector(("undo:")), key: "z"))
        editMenu.addItem(makeItem(L10n("menu.edit.redo"), action: Selector(("redo:")), key: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(makeItem(L10n("menu.edit.cut"), action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(makeItem(L10n("menu.edit.copy"), action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(makeItem(L10n("menu.edit.paste"), action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(makeItem(L10n("menu.edit.selectAll"), action: #selector(NSText.selectAll(_:)), key: "a"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(makeItem(L10n("menu.edit.toggleComment"), action: #selector(toggleCommentAction(_:)), key: "/"))
        editMenu.addItem(makeItem(L10n("menu.edit.selectNextOccurrence"), action: #selector(selectNextOccurrenceAction(_:)), key: "d"))
        editMenu.addItem(makeItem(L10n("menu.edit.deleteLine"), action: #selector(deleteLineAction(_:)), key: "K"))
        let formatItem = NSMenuItem(title: L10n("menu.edit.formatDocument"), action: #selector(formatDocumentAction(_:)), keyEquivalent: "f")
        formatItem.keyEquivalentModifierMask = [.option, .shift]
        editMenu.addItem(formatItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(makeItem(L10n("menu.edit.find"), action: #selector(findAction(_:)), key: "f"))
        let findReplaceItem = NSMenuItem(title: L10n("menu.edit.findReplace"), action: #selector(findReplaceAction(_:)), keyEquivalent: "f")
        findReplaceItem.keyEquivalentModifierMask = [.option, .command]
        editMenu.addItem(findReplaceItem)
        editMenu.addItem(makeItem(L10n("menu.edit.findNext"), action: #selector(findNextAction(_:)), key: "g"))
        editMenu.addItem(makeItem(L10n("menu.edit.findPrevious"), action: #selector(findPreviousAction(_:)), key: "G"))
        editMenu.addItem(makeItem(L10n("menu.edit.findInWorkspace"), action: #selector(globalSearchAction(_:)), key: "F"))
        editMenu.addItem(NSMenuItem.separator())
        let completionItem = NSMenuItem(title: L10n("menu.edit.triggerCompletion"), action: #selector(triggerCompletionAction(_:)), keyEquivalent: " ")
        completionItem.keyEquivalentModifierMask = [.control]
        editMenu.addItem(completionItem)
        editMenu.addItem(makeItem(L10n("menu.edit.showHover"), action: #selector(showHoverAction(_:)), key: "k"))
        editMenu.addItem(NSMenuItem(title: L10n("menu.edit.goToDefinition"), action: #selector(goToDefinitionAction(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: L10n("menu.edit.findReferences"), action: #selector(findReferencesAction(_:)), keyEquivalent: ""))

        // Go Menu
        let goMenuItem = NSMenuItem()
        mainMenu.addItem(goMenuItem)
        let goMenu = NSMenu(title: L10n("menu.go"))
        goMenuItem.submenu = goMenu
        let backItem = NSMenuItem(title: L10n("menu.go.back"), action: #selector(navigateBackAction(_:)), keyEquivalent: "-")
        backItem.keyEquivalentModifierMask = [.control]
        goMenu.addItem(backItem)
        let fwdItem = NSMenuItem(title: L10n("menu.go.forward"), action: #selector(navigateForwardAction(_:)), keyEquivalent: "-")
        fwdItem.keyEquivalentModifierMask = [.control, .shift]
        goMenu.addItem(fwdItem)
        goMenu.addItem(NSMenuItem.separator())
        goMenu.addItem(makeItem(L10n("menu.view.quickOpen"), action: #selector(quickOpenAction(_:)), key: "p"))
        goMenu.addItem(makeItem(L10n("symbols.title"), action: #selector(symbolOutlineAction(_:)), key: "O"))
        goMenu.addItem(makeItem(L10n("menu.edit.goToLine"), action: #selector(goToLineAction(_:)), key: "l"))
        goMenu.addItem(NSMenuItem.separator())
        let prevTabItem = NSMenuItem(title: L10n("menu.go.previousTab"), action: #selector(previousTabAction(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(prevTabItem)
        let nextTabItem = NSMenuItem(title: L10n("menu.go.nextTab"), action: #selector(nextTabAction(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(nextTabItem)
        for num in 1...9 {
            let item = NSMenuItem(title: "Tab \(num)", action: #selector(selectTabNumberAction(_:)), keyEquivalent: "\(num)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = num - 1
            item.isHidden = true
            goMenu.addItem(item)
        }

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: L10n("menu.view"))
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(makeItem(L10n("commandPalette.title"), action: #selector(commandPaletteAction(_:)), key: "P"))
        viewMenu.addItem(makeItem(L10n("menu.view.toggleSplitEditor"), action: #selector(toggleSplitEditorAction(_:)), key: "\\"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeItem(L10n("menu.view.switchWorktree"), action: #selector(switchWorktreeAction(_:)), key: "W"))
        viewMenu.addItem(makeItem(L10n("menu.view.switchBranch"), action: #selector(switchBranchAction(_:)), key: "B"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeItem(L10n("menu.view.zoomIn"), action: #selector(zoomInAction(_:)), key: "="))
        viewMenu.addItem(makeItem(L10n("menu.view.zoomOut"), action: #selector(zoomOutAction(_:)), key: "-"))
        viewMenu.addItem(makeItem(L10n("menu.view.resetZoom"), action: #selector(resetZoomAction(_:)), key: "0"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(makeItem(L10n("menu.view.toggleSidebar"), action: #selector(toggleSidebarAction(_:)), key: "b"))
        let toggleGitItem = NSMenuItem(title: L10n("menu.view.toggleGitPanel"), action: #selector(toggleGitPanelAction(_:)), keyEquivalent: "g")
        toggleGitItem.keyEquivalentModifierMask = [.control, .shift]
        viewMenu.addItem(toggleGitItem)
        let viewDiffItem = NSMenuItem(title: L10n("menu.view.viewGitDiff"), action: #selector(viewGitDiffAction(_:)), keyEquivalent: "d")
        viewDiffItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(viewDiffItem)
        viewMenu.addItem(makeItem(L10n("menu.view.toggleTerminal"), action: #selector(toggleTerminalAction(_:)), key: "j"))
        let newTermItem = NSMenuItem(title: L10n("terminal.newTab"), action: #selector(newTerminalTabAction(_:)), keyEquivalent: "`")
        newTermItem.keyEquivalentModifierMask = [.control, .shift]
        viewMenu.addItem(newTermItem)
        viewMenu.addItem(NSMenuItem(title: L10n("menu.view.showProblems"), action: #selector(showProblemsAction(_:)), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: L10n("menu.view.showReferences"), action: #selector(showReferencesAction(_:)), keyEquivalent: ""))

        // Run Menu
        let runMenuItem = NSMenuItem()
        mainMenu.addItem(runMenuItem)
        let runMenu = NSMenu(title: L10n("menu.run"))
        runMenuItem.submenu = runMenu
        runMenu.addItem(makeItem(L10n("menu.run.run"), action: #selector(runProjectAction(_:)), key: "r"))
        runMenu.addItem(makeItem(L10n("menu.run.test"), action: #selector(testProjectAction(_:)), key: "u"))
        runMenu.addItem(makeItem(L10n("menu.run.stop"), action: #selector(stopTaskAction(_:)), key: "."))

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
    }

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if key.count == 1, let ch = key.first, ch.isUppercase {
            item.keyEquivalentModifierMask = [.command, .shift]
        } else {
            item.keyEquivalentModifierMask = [.command]
        }
        return item
    }
}
