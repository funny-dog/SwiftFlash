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

        let initialFolder = parseFolderArgument()
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

        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
            return
        }
        if let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func parseFolderArgument() -> URL? {
        let args = CommandLine.arguments.dropFirst()
        if let firstPath = args.first {
            let url = URL(fileURLWithPath: firstPath).standardized
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }

    private func updateWindowTitle() {
        guard workspace.hasWorkspaceOpen else {
            window.title = "SwiftFlash"
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
        editMenu.addItem(makeItem(L10n("menu.edit.findInWorkspace"), action: #selector(globalSearchAction(_:)), key: "F"))

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
        viewMenu.addItem(makeItem(L10n("menu.view.toggleGitPanel"), action: #selector(toggleGitPanelAction(_:)), key: "G"))
        let viewDiffItem = NSMenuItem(title: L10n("menu.view.viewGitDiff"), action: #selector(viewGitDiffAction(_:)), keyEquivalent: "d")
        viewDiffItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(viewDiffItem)
        viewMenu.addItem(makeItem(L10n("menu.view.toggleTerminal"), action: #selector(toggleTerminalAction(_:)), key: "j"))
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
