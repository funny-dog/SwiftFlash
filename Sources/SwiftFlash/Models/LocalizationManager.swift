import AppKit
import Combine
import Foundation

// MARK: - Localization Shorthand

@MainActor
func L10n(_ key: String) -> String {
    LocalizationManager.shared.tr(key)
}

@MainActor
func L10n(_ key: String, _ args: CVarArg...) -> String {
    let format = LocalizationManager.shared.tr(key)
    return String(format: format, arguments: args)
}

// MARK: - LocalizationManager

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    static let builtInEnglishID = ""

    private enum Keys {
        static let activeLanguagePluginID = "swiftflash.activeLanguagePluginID"
    }

    /// The language plugin ID saved for the next launch (persisted immediately).
    @Published var selectedLanguagePluginID: String {
        didSet {
            UserDefaults.standard.set(selectedLanguagePluginID, forKey: Keys.activeLanguagePluginID)
        }
    }

    /// The language plugin ID actually loaded during this app launch.
    @Published private(set) var loadedLanguagePluginID: String = ""
    @Published private(set) var loadedLanguageDisplayName: String = "English"

    private var activeStrings: [String: String] = [:]

    var needsRestartToApply: Bool {
        selectedLanguagePluginID != loadedLanguagePluginID
    }

    private init() {
        let savedID = UserDefaults.standard.string(forKey: Keys.activeLanguagePluginID) ?? ""
        self.selectedLanguagePluginID = savedID
        loadLanguagePackOnStartup(pluginID: savedID)
    }

    func tr(_ key: String) -> String {
        if let localized = activeStrings[key], !localized.isEmpty {
            return localized
        }
        if loadedLanguagePluginID == "com.swiftflash.lang.zh-cn",
           let zhFallback = Self.fallbackSimplifiedChineseStrings[key] {
            return zhFallback
        }
        return Self.defaultEnglishStrings[key] ?? key
    }

    func selectLanguagePlugin(id: String) {
        selectedLanguagePluginID = id
    }

    /// Loads the configured language plugin from disk. Called at startup (or in tests).
    func loadLanguagePackOnStartup(pluginID: String) {
        guard !pluginID.isEmpty,
              let result = Self.readLanguagePluginStrings(pluginID: pluginID) else {
            activeStrings = [:]
            loadedLanguagePluginID = ""
            loadedLanguageDisplayName = "English"
            if !pluginID.isEmpty {
                // Plugin missing or invalid on disk; fall back cleanly to built-in English.
                selectedLanguagePluginID = ""
            }
            return
        }

        activeStrings = result.strings
        loadedLanguagePluginID = pluginID
        loadedLanguageDisplayName = result.nativeName
    }

    func restartApplication() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            let folderArgs = Array(CommandLine.arguments.dropFirst())
            if !folderArgs.isEmpty {
                config.arguments = folderArgs
            }
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        } else if let executableURL = Bundle.main.executableURL {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = Array(CommandLine.arguments.dropFirst())
            try? process.run()
            NSApp.terminate(nil)
        }
    }

    private static func readLanguagePluginStrings(pluginID: String) -> (nativeName: String, strings: [String: String])? {
        let pluginDir = PluginStorage.pluginsDirectory.appendingPathComponent(pluginID, isDirectory: true)
        let manifestURL = pluginDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData),
              manifest.type == .language,
              let loc = manifest.contributes?.localization else {
            return nil
        }

        let stringsURL = pluginDir.appendingPathComponent(loc.stringsFile)
        guard let stringsData = try? Data(contentsOf: stringsURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: stringsData) else {
            return nil
        }

        return (loc.nativeName, decoded)
    }

    // MARK: - Built-in English Strings

    static let defaultEnglishStrings: [String: String] = [
        "common.cancel": "Cancel",
        "common.discard": "Discard",
        "common.discardAll": "Discard All",
        "common.dontSave": "Don't Save",
        "common.reset": "Reset",
        "common.save": "Save",
        "common.unsavedBuffer": "Unsaved Buffer",
        "common.close": "Close",
        "common.install": "Install",
        "common.uninstall": "Uninstall",
        "common.installed": "Installed",
        "common.active": "Active",
        "common.use": "Use",
        "common.refresh": "Refresh",

        "menu.app.about": "About SwiftFlash",
        "menu.app.settings": "Theme, Font & Language Settings...",
        "menu.app.quit": "Quit SwiftFlash",
        "menu.file": "File",
        "menu.file.new": "New File",
        "menu.file.openFolder": "Open Folder...",
        "menu.file.switchProject": "Switch Project...",
        "menu.file.save": "Save",
        "menu.file.closeTab": "Close Tab",
        "menu.edit": "Edit",
        "menu.edit.undo": "Undo",
        "menu.edit.redo": "Redo",
        "menu.edit.cut": "Cut",
        "menu.edit.copy": "Copy",
        "menu.edit.paste": "Paste",
        "menu.edit.selectAll": "Select All",
        "menu.edit.toggleComment": "Toggle Line Comment",
        "menu.edit.findInWorkspace": "Find in Workspace",
        "menu.view": "View",
        "menu.view.quickOpen": "Quick Open File...",
        "menu.view.switchWorktree": "Switch Git Worktree...",
        "menu.view.switchBranch": "Switch Git Branch...",
        "menu.view.zoomIn": "Zoom In",
        "menu.view.zoomOut": "Zoom Out",
        "menu.view.resetZoom": "Reset Zoom",
        "menu.view.toggleSidebar": "Toggle Sidebar",
        "menu.view.toggleGitPanel": "Toggle Git Panel",
        "menu.view.viewGitDiff": "View Git Diff",
        "menu.view.toggleTerminal": "Toggle Integrated Terminal",

        "theme.subtitle.zedOneDark": "Classic dark",
        "theme.subtitle.zedGruvboxLight": "Warm retro light",
        "theme.subtitle.zedOneLight": "Crisp daylight",
        "theme.subtitle.tokyoNight": "Deep indigo night",
        "theme.subtitle.catppuccinMocha": "Soothing pastel dark",
        "theme.subtitle.githubDarkDimmed": "Soft slate dark",

        "header.project.help": "Switch Project / Directory (⌘⇧O)",
        "header.worktree.local": "local",
        "header.worktree.help": "Switch Git Worktree (⌘⇧W)",
        "header.branch.help": "Switch Git Branch (⌘⇧B)",
        "header.quickOpen.help": "Quick Open File (⌘P)",
        "header.settings.help": "Theme, Font & Language Settings (⌘,)",
        "header.sidebar.help": "Toggle Sidebar (⌘B)",
        "header.terminal.help": "Toggle Terminal (⌘J)",

        "switcher.project.searchPlaceholder": "Search projects...",
        "switcher.project.thisWindow": "This Window",
        "switcher.project.recentProjects": "Recent Projects",
        "switcher.project.empty": "No matching projects",
        "switcher.project.openFolders": "Open Local Folders",
        "switcher.project.addFolder": "Add Folder to Window",

        "switcher.worktree.searchPlaceholder": "Search worktrees or type new name...",
        "switcher.worktree.section": "Git Worktrees",
        "switcher.worktree.createFormat": "Create Worktree \"%@\"",
        "switcher.worktree.openFolder": "Open Folder as Worktree...",

        "switcher.branch.searchPlaceholder": "Search branches or create new branch...",
        "switcher.branch.local": "Local Branches",
        "switcher.branch.remote": "Remote Branches",
        "switcher.branch.empty": "No branches found",
        "switcher.branch.createFormat": "Create & checkout branch \"%@\"",
        "switcher.branch.worktreeBadge": "worktree",

        "settings.title": "Theme, Typography & Language",
        "settings.section.theme": "COLOR THEME",
        "settings.theme.dark": "Dark",
        "settings.theme.light": "Light",
        "settings.section.fontFamily": "EDITOR FONT FAMILY",
        "settings.section.sizeSpacing": "SIZE & SPACING",
        "settings.fontSize": "Editor Font Size",
        "settings.lineHeight": "Line Height Multiplier",
        "settings.uiFontSize": "Sidebar UI Font Size",
        "settings.section.preview": "LIVE PREVIEW",
        "settings.preview.comment": "    // Instant 120Hz CoreText preview",
        "settings.section.languagePlugins": "INTERFACE LANGUAGE",
        "settings.language.active": "Display Language",
        "settings.language.builtinEnglish": "English (Built-in)",
        "settings.language.installOptionSuffix": "%@ (Install...)",
        "settings.language.confirmTitleFormat": "Install \"%@\" language pack?",
        "settings.language.confirmBodyFormat": "Download v%@ from the plugin registry. It will take effect after restarting SwiftFlash.",
        "settings.language.confirmInstallButton": "Install",
        "settings.language.pendingRestartBanner": "Language changed. Restart SwiftFlash to apply \"%@\".",
        "settings.language.restartNow": "Restart Now",
        "settings.plugins.downloading": "Downloading...",
        "settings.plugins.refreshHelp": "Refresh available languages",
        "settings.plugins.uninstallHelp": "Uninstall language pack",

        "sidebar.explorer.switchProjectHelp": "Switch Project (⌘⇧O)",
        "sidebar.explorer.newFileHelp": "New File in Workspace",
        "sidebar.explorer.openFolderHelp": "Open Folder (⌘O)",
        "sidebar.explorer.refreshHelp": "Refresh Explorer",
        "sidebar.explorer.newFilePlaceholder": "filename.swift",

        "explorer.context.open": "Open",
        "explorer.context.newFile": "New File...",
        "explorer.context.newFolder": "New Folder...",
        "explorer.context.rename": "Rename...",
        "explorer.context.duplicate": "Duplicate",
        "explorer.context.delete": "Move to Trash...",
        "explorer.context.copyPath": "Copy Path",
        "explorer.context.copyRelativePath": "Copy Relative Path",
        "explorer.context.revealInFinder": "Reveal in Finder",
        "explorer.context.refresh": "Refresh Explorer",
        "explorer.dialog.newFileTitle": "New File",
        "explorer.dialog.newFileMessage": "Enter a file name to create in \"%@\":",
        "explorer.dialog.newFilePlaceholder": "filename.swift",
        "explorer.dialog.create": "Create",
        "explorer.dialog.newFolderTitle": "New Folder",
        "explorer.dialog.newFolderMessage": "Enter a folder name to create in \"%@\":",
        "explorer.dialog.newFolderPlaceholder": "NewFolder",
        "explorer.dialog.renameTitle": "Rename \"%@\"",
        "explorer.dialog.renameMessage": "Enter a new name:",
        "explorer.dialog.renameConfirm": "Rename",
        "explorer.dialog.deleteTitle": "Move \"%@\" to Trash?",
        "explorer.dialog.deleteFolderMessage": "This folder and all of its contents will be moved to the Trash.",
        "explorer.dialog.deleteFileMessage": "This file will be moved to the Trash.",
        "explorer.dialog.deleteConfirm": "Move to Trash",
        "status.createdFileFormat": "Created %@",
        "status.createdFolderFormat": "Created folder %@",
        "status.renamedFormat": "Renamed to %@",
        "status.duplicatedFormat": "Duplicated as %@",
        "status.movedToTrashFormat": "Moved %@ to Trash",
        "status.copiedPathFormat": "Copied path: %@",
        "status.itemExistsFormat": "Already exists: %@",
        "status.fileOpFailedFormat": "Operation failed: %@",

        "git.notARepo.title": "Not a Git repository",
        "git.notARepo.detail": "Current directory is not a Git repository",
        "git.init.button": "Initialize Repository",
        "git.init.buttonFull": "Initialize Git Repository (git init)",
        "git.tab.changes": "Changes",
        "git.tab.history": "History",
        "git.filter.all": "Uncommitted",
        "git.filter.staged": "Staged",
        "git.filter.unstaged": "Unstaged",
        "git.filter.untracked": "Untracked",
        "git.action.viewDiff": "View Diff",
        "git.action.viewDiffHelp": "View Diff  ⌃⌘D",
        "git.action.refreshStatus": "Refresh Status",
        "git.action.stageAllChanges": "Stage All Changes",
        "git.action.stageTrackedOnly": "Stage Tracked Only",
        "git.action.unstageAllChanges": "Unstage All Changes",
        "git.action.discardAllUnstaged": "Discard All Unstaged...",
        "git.action.optionsHelp": "Git Options",
        "git.action.stageAll": "Stage All",
        "git.action.unstageAll": "Unstage All",
        "git.action.stageTracked": "Stage Tracked",
        "git.empty.noChanges": "No changes to commit",
        "git.empty.filteredFormat": "No %@ changes",
        "git.history.recentCommitsFormat": "Recent Commits (%d)",
        "git.history.refreshHelp": "Refresh Commit History",
        "git.history.empty": "No commits yet",
        "git.remote.fetch": "Fetch",
        "git.remote.fetchPrune": "Fetch (--prune)",
        "git.remote.pull": "Pull",
        "git.remote.push": "Push",
        "git.commit.placeholder": "Enter commit message",
        "git.commit.collapseHelp": "Collapse Commit Editor",
        "git.commit.expandHelp": "Expand Commit Editor",
        "git.commit.optionsHelp": "Commit Options",
        "git.commit.generateHelp": "Generate Commit Message",
        "git.commitMode.tracked": "Commit Tracked",
        "git.commitMode.staged": "Commit Staged",
        "git.commitMode.all": "Commit All",
        "git.commitMode.amend": "Commit Amend",
        "git.commit.viewLastHelpFormat": "View Last Commit (%@)",
        "git.commit.undoLastHelp": "Undo Last Commit (git reset --soft HEAD~1)",
        "git.commit.showLastDiffHelp": "Show Last Commit Diff",
        "git.file.stage": "Stage File",
        "git.file.unstage": "Unstage File",
        "git.file.open": "Open File",
        "git.file.discard": "Discard Changes",
        "git.file.discardEllipsis": "Discard Changes...",

        "statusbar.dock.explorerHelp": "Project Panel (⌘B)",
        "statusbar.dock.gitHelp": "Git Panel (⌘⇧G)",
        "statusbar.dock.searchHelp": "Search Panel (⌘⇧F)",
        "statusbar.terminal": "Terminal",
        "statusbar.terminal.help": "Toggle Integrated Terminal (⌘J)",
        "statusbar.cursorFormat": "Ln %d, Col %d",
        "statusbar.spacesFormat": "Spaces: 4",

        "search.placeholder": "Search in workspace...",
        "search.searching": "Searching...",
        "search.matchesFormat": "%d matches",
        "search.hint": "Press ⌘⇧F anytime to search",

        "quickOpen.placeholder": "Search files by name (⌘P)...",
        "quickOpen.empty": "No matching files found",

        "editor.modifiedHint": "Modified • Press ⌘S to Save",
        "editor.welcome.subtitle": "Native AppKit + CoreText B-Tree Viewport Engine",
        "editor.welcome.switchProject": "Switch Project",
        "editor.welcome.switchWorktree": "Switch Git Worktree",
        "editor.welcome.switchBranch": "Switch Git Branch",
        "editor.welcome.settings": "Theme & Font Settings",
        "editor.welcome.quickOpen": "Quick Open File",
        "editor.welcome.globalSearch": "Global Search",
        "editor.welcome.toggleTerminal": "Toggle Terminal",
        "editor.welcome.toggleSidebar": "Toggle Sidebar",

        "terminal.title": "TERMINAL",
        "terminal.stop": "Stop",
        "terminal.clearHelp": "Clear Terminal",
        "terminal.hideHelp": "Hide Terminal (⌘J)",
        "terminal.inputPlaceholder": "Run zsh command (e.g. swift build, ls, git status)...",
        "terminal.readyBannerFormat": "SwiftFlash Terminal (%@) — Ready",
        "terminal.workspaceChangedFormat": "→ Workspace changed to %@",
        "terminal.processTerminated": "^C Process terminated",
        "terminal.failedExecuteFormat": "Failed to execute: %@",
        "terminal.exitCodeFormat": "[exit %d]",
        "terminal.cdNoSuchDirFormat": "cd: no such directory: %@",

        "status.ready": "CoreText B-Tree • Ready",
        "status.folderNotFoundFormat": "Folder not found: %@",
        "status.switchedToFormat": "Switched to %@",
        "status.worktreeSwitchedFormat": "Worktree: %@ (%@)",
        "status.openedWorktreeFormat": "Opened existing worktree %@",
        "status.createdWorktreeFormat": "Created worktree %@ [%@]",
        "status.failedWorktree": "Failed to create worktree",
        "status.switchedBranchFormat": "Switched to branch %@",
        "status.gitCheckoutFailed": "Git checkout failed",
        "status.initializedGitFormat": "Initialized Git repository in %@",
        "status.gitInitFailedFormat": "git init failed: %@",
        "status.stagedFileFormat": "Staged %@",
        "status.unstagedFileFormat": "Unstaged %@",
        "status.stagedAllTracked": "Staged all tracked changes",
        "status.stagedAll": "Staged all changes",
        "status.unstagedAll": "Unstaged all changes",
        "status.discardedFileFormat": "Discarded changes to %@",
        "status.failedDiscardFileFormat": "Failed to discard %@",
        "status.discardedAll": "Discarded all unstaged changes",
        "status.failedDiscardAll": "Failed to discard changes",
        "status.enterCommitMessage": "Enter a commit message before committing",
        "status.committedFormat": "Committed: %@",
        "status.amended": "amended",
        "status.commitFailed": "Commit failed",
        "status.noCommitToUndo": "No commit to undo",
        "status.uncommittedLast": "Uncommitted last commit",
        "status.failedUndoCommit": "Failed to undo commit",
        "status.noChangesForDraft": "No changes to generate commit message",
        "status.generatedDraft": "Generated commit message draft",
        "status.runningGitFormat": "Running git %@...",
        "status.gitCompletedFormat": "Git %@ completed",
        "status.gitFailedFormat": "Git %@ failed",
        "status.noUncommittedDiff": "No uncommitted changes to view",
        "status.noFileDiffFormat": "No diff available for %@",
        "status.failedLoadCommitFormat": "Failed to load commit %@",
        "status.gitOpFailed": "Git operation failed",
        "status.failedOpenFileFormat": "Failed to open %@: %@",
        "status.binaryFileFormat": "Binary file cannot be displayed as text: %@",
        "status.openedFileFormat": "Opened %@ in %.2f ms",
        "status.createdBuffer": "Created new buffer",
        "status.diffReadOnly": "Diff view is read-only",
        "status.savedFileFormat": "Saved %@ (%.2f ms)",
        "status.saveFailedFormat": "Save failed: %@",

        "dialog.openFolder.prompt": "Open Folder",
        "dialog.openFolder.message": "Select a project folder to open in SwiftFlash",
        "dialog.addFolder.prompt": "Add to Window",
        "dialog.addFolder.message": "Add a project folder to This Window switcher",

        "alert.saveChanges.titleFormat": "Save changes to \"%@\"?",
        "alert.saveChanges.message": "Your changes will be lost if you don't save them.",
        "alert.discardFile.titleFormat": "Discard changes to \"%@\"?",
        "alert.discardFile.untrackedMsg": "This untracked file will be permanently deleted from disk.",
        "alert.discardFile.modifiedMsg": "Your uncommitted modifications to this file will be reverted.",
        "alert.discardAll.title": "Discard all uncommitted changes?",
        "alert.discardAll.message": "Tracked modifications will be reverted and untracked files will be removed."
    ]

    static let fallbackSimplifiedChineseStrings: [String: String] = [
        "explorer.context.open": "打开",
        "explorer.context.newFile": "新建文件...",
        "explorer.context.newFolder": "新建文件夹...",
        "explorer.context.rename": "重命名...",
        "explorer.context.duplicate": "创建副本",
        "explorer.context.delete": "移到废纸篓...",
        "explorer.context.copyPath": "复制路径",
        "explorer.context.copyRelativePath": "复制相对路径",
        "explorer.context.revealInFinder": "在访达中显示",
        "explorer.context.refresh": "刷新文件树",
        "explorer.dialog.newFileTitle": "新建文件",
        "explorer.dialog.newFileMessage": "输入要在 \"%@\" 中创建的文件名：",
        "explorer.dialog.newFilePlaceholder": "filename.swift",
        "explorer.dialog.create": "创建",
        "explorer.dialog.newFolderTitle": "新建文件夹",
        "explorer.dialog.newFolderMessage": "输入要在 \"%@\" 中创建的文件夹名称：",
        "explorer.dialog.newFolderPlaceholder": "NewFolder",
        "explorer.dialog.renameTitle": "重命名 \"%@\"",
        "explorer.dialog.renameMessage": "请输入新名称：",
        "explorer.dialog.renameConfirm": "重命名",
        "explorer.dialog.deleteTitle": "将 \"%@\" 移到废纸篓？",
        "explorer.dialog.deleteFolderMessage": "该文件夹及其所有内容将被移到废纸篓。",
        "explorer.dialog.deleteFileMessage": "该文件将被移到废纸篓。",
        "explorer.dialog.deleteConfirm": "移到废纸篓",
        "status.createdFileFormat": "已创建 %@",
        "status.createdFolderFormat": "已创建文件夹 %@",
        "status.renamedFormat": "已重命名为 %@",
        "status.duplicatedFormat": "已创建副本 %@",
        "status.movedToTrashFormat": "已将 %@ 移到废纸篓",
        "status.copiedPathFormat": "已复制路径：%@",
        "status.itemExistsFormat": "已存在同名项目：%@",
        "status.fileOpFailedFormat": "操作失败：%@"
    ]
}
