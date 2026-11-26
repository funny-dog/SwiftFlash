import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var workspace: WorkspaceState!
    private var rootController: RootIDEViewController!
    private var titleCancellable: AnyCancellable?
    private var themeCancellable: AnyCancellable?
    private var systemAppearanceObserver: NSObjectProtocol?
    private var pendingOpenURLs: [URL] = []
    private var hasFinishedLaunching = false

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

        workspace = WorkspaceState(initialURL: initialFolder)
        rootController = RootIDEViewController(workspace: workspace)

        buildMainMenu()

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1360, screenFrame.width * 0.88)
        let height = min(860, screenFrame.height * 0.88)
        let originX = screenFrame.midX - width / 2
        let originY = screenFrame.midY - height / 2

        window = NSWindow(
            contentRect: NSRect(x: originX, y: originY, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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
                self?.applyAppThemeAppearance()
            }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hasFinishedLaunching = true

        // Register extra directories into window switcher without re-reloading `initialFolder`.
        for extraDir in extraDirectories {
            if !workspace.windowProjects.contains(where: { $0.standardized.path == extraDir.path }) {
                workspace.windowProjects.append(extraDir)
            }
            workspace.recordRecentProject(extraDir)
        }
        if !remainingURLs.isEmpty {
            workspace.openExternalURLs(remainingURLs)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard hasFinishedLaunching, workspace != nil else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        workspace.openExternalURLs(urls)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppThemeAppearance() {
        let isDark = ThemeManager.shared.palette.isDark
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window?.backgroundColor = ZedTheme.background
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
        guard let workspace else { return .terminateNow }
        return workspace.confirmTerminationWithUnsavedChanges() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
            self.systemAppearanceObserver = nil
        }
        rootController?.mainSplitController.shutdownTerminal()
        workspace?.stopRunningTask()
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

    private func updateWindowTitle() {
        guard workspace.hasWorkspaceOpen else {
            if let tab = workspace.activeTab {
                let dirtyMark = tab.isDirty ? " •" : ""
                window.title = "\(tab.title)\(dirtyMark) — SwiftFlash"
            } else {
                window.title = "SwiftFlash"
            }
            return
        }
        let folderName = workspace.rootURL.lastPathComponent
        if let tab = workspace.activeTab {
            let dirtyMark = tab.isDirty ? " •" : ""
            window.title = "\(tab.title)\(dirtyMark) — \(folderName) (SwiftFlash)"
        } else {
            window.title = "\(folderName) — SwiftFlash"
        }
    }

    // MARK: - Menu Actions

    @objc private func openFolderAction(_ sender: Any?) {
        workspace.openFolderPanel()
    }

    @objc private func newFileAction(_ sender: Any?) {
        workspace.createNewUntitledFile()
    }

    @objc private func saveFileAction(_ sender: Any?) {
        workspace.saveActiveTab()
    }

    @objc private func closeTabAction(_ sender: Any?) {
        workspace.closeActiveTab()
    }

    @objc private func quickOpenAction(_ sender: Any?) {
        workspace.toggleOverlay(.quickOpen)
    }

    @objc private func switchProjectAction(_ sender: Any?) {
        workspace.toggleOverlay(.projectSwitcher)
    }

    @objc private func switchWorktreeAction(_ sender: Any?) {
        workspace.toggleOverlay(.worktreeSwitcher)
    }

    @objc private func switchBranchAction(_ sender: Any?) {
        workspace.toggleOverlay(.branchSwitcher)
    }

    @objc private func openSettingsAction(_ sender: Any?) {
        workspace.toggleOverlay(.settings)
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
        rootController.mainSplitController.ensureSidebarVisible(mode: .search)
        workspace.searchFocusNonce &+= 1
    }

    @objc private func toggleGitPanelAction(_ sender: Any?) {
        rootController.mainSplitController.selectOrToggleSidebar(mode: .git)
    }

    @objc private func viewGitDiffAction(_ sender: Any?) {
        workspace.openGitDiffInEditor()
    }

    @objc private func toggleSidebarAction(_ sender: Any?) {
        rootController.mainSplitController.toggleSidebar()
    }

    @objc private func toggleTerminalAction(_ sender: Any?) {
        rootController.mainSplitController.toggleTerminal()
    }

    @objc private func toggleCommentAction(_ sender: Any?) {
        workspace.onToggleCommentRequested?()
    }

    @objc private func findAction(_ sender: Any?) {
        workspace.presentFindBar(replace: false)
    }

    @objc private func findReplaceAction(_ sender: Any?) {
        workspace.presentFindBar(replace: true)
    }

    @objc private func findNextAction(_ sender: Any?) {
        workspace.findNextInActiveFile()
    }

    @objc private func findPreviousAction(_ sender: Any?) {
        workspace.findPreviousInActiveFile()
    }

    @objc private func goToLineAction(_ sender: Any?) {
        workspace.presentGoToLine()
    }

    @objc private func triggerCompletionAction(_ sender: Any?) {
        workspace.onRequestCompletionAction?()
    }

    @objc private func goToDefinitionAction(_ sender: Any?) {
        workspace.onGoToDefinitionAction?()
    }

    @objc private func runProjectAction(_ sender: Any?) {
        workspace.runDefaultRunTask()
    }

    @objc private func testProjectAction(_ sender: Any?) {
        workspace.runDefaultTestTask()
    }

    @objc private func stopTaskAction(_ sender: Any?) {
        workspace.stopRunningTask()
    }

    @objc private func showProblemsAction(_ sender: Any?) {
        workspace.showBottomPanel(.problems)
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
        fileMenu.addItem(makeItem(L10n("menu.file.openFolder"), action: #selector(openFolderAction(_:)), key: "o"))
        fileMenu.addItem(makeItem(L10n("menu.file.switchProject"), action: #selector(switchProjectAction(_:)), key: "O"))
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
        editMenu.addItem(makeItem(L10n("menu.edit.find"), action: #selector(findAction(_:)), key: "f"))
        let findReplaceItem = NSMenuItem(title: L10n("menu.edit.findReplace"), action: #selector(findReplaceAction(_:)), keyEquivalent: "f")
        findReplaceItem.keyEquivalentModifierMask = [.option, .command]
        editMenu.addItem(findReplaceItem)
        editMenu.addItem(makeItem(L10n("menu.edit.findNext"), action: #selector(findNextAction(_:)), key: "g"))
        editMenu.addItem(makeItem(L10n("menu.edit.findPrevious"), action: #selector(findPreviousAction(_:)), key: "G"))
        editMenu.addItem(makeItem(L10n("menu.edit.goToLine"), action: #selector(goToLineAction(_:)), key: "l"))
        editMenu.addItem(makeItem(L10n("menu.edit.findInWorkspace"), action: #selector(globalSearchAction(_:)), key: "F"))
        editMenu.addItem(NSMenuItem.separator())
        let completionItem = NSMenuItem(title: L10n("menu.edit.triggerCompletion"), action: #selector(triggerCompletionAction(_:)), keyEquivalent: " ")
        completionItem.keyEquivalentModifierMask = [.control]
        editMenu.addItem(completionItem)
        editMenu.addItem(NSMenuItem(title: L10n("menu.edit.goToDefinition"), action: #selector(goToDefinitionAction(_:)), keyEquivalent: ""))

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: L10n("menu.view"))
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(makeItem(L10n("menu.view.quickOpen"), action: #selector(quickOpenAction(_:)), key: "p"))
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
        viewMenu.addItem(NSMenuItem(title: L10n("menu.view.showProblems"), action: #selector(showProblemsAction(_:)), keyEquivalent: ""))

        // Run Menu
        let runMenuItem = NSMenuItem()
        mainMenu.addItem(runMenuItem)
        let runMenu = NSMenu(title: L10n("menu.run"))
        runMenuItem.submenu = runMenu
        runMenu.addItem(makeItem(L10n("menu.run.run"), action: #selector(runProjectAction(_:)), key: "r"))
        runMenu.addItem(makeItem(L10n("menu.run.test"), action: #selector(testProjectAction(_:)), key: "u"))
        runMenu.addItem(makeItem(L10n("menu.run.stop"), action: #selector(stopTaskAction(_:)), key: "."))
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
