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
    let fallbackFormat = LocalizationManager.defaultEnglishStrings[key] ?? key
    // Defense-in-depth: never pass a format string with mismatched C format specifiers into String(format:).
    let safeFormat = LocalizationManager.hasMatchingFormatSpecifiers(format, reference: fallbackFormat)
        ? format
        : fallbackFormat
    return String(format: safeFormat, arguments: args)
}

// MARK: - LocalizationManager

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    static let builtInEnglishID = ""

    private enum Keys {
        static let activeLanguagePluginID = "swiftflash.activeLanguagePluginID"
    }

    private nonisolated static let formatSpecifierRegex = try! NSRegularExpression(
        pattern: #"%(?:%|(?:\d+\$)?[-+# 0]*(?:\d+)?(?:\.\d+)?(?:ll|l|h|hh|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF])"#
    )

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
              PluginManager.isValidPluginID(pluginID),
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

        // Filter out any entries whose format specifiers don't match the canonical English string.
        var validated: [String: String] = [:]
        validated.reserveCapacity(result.strings.count)
        for (key, value) in result.strings {
            if let reference = Self.defaultEnglishStrings[key],
               !Self.hasMatchingFormatSpecifiers(value, reference: reference) {
                continue
            }
            validated[key] = value
        }

        activeStrings = validated
        loadedLanguagePluginID = pluginID
        loadedLanguageDisplayName = result.nativeName
    }

    nonisolated static func extractFormatSpecifiers(from text: String) -> [String] {
        let ns = text as NSString
        let matches = formatSpecifierRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            let token = ns.substring(with: match.range)
            if token == "%%" { return nil }
            return token.last.map { String($0) }
        }
    }

    nonisolated static func hasMatchingFormatSpecifiers(_ candidate: String, reference: String) -> Bool {
        extractFormatSpecifiers(from: candidate) == extractFormatSpecifiers(from: reference)
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
        guard let pluginDir = PluginStorage.validatedPluginDirectory(id: pluginID) else {
            return nil
        }
        let manifestURL = pluginDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData),
              manifest.type == .language,
              let loc = manifest.contributes?.localization,
              let stringsURL = PluginStorage.validatedRelativeFile(loc.stringsFile, inside: pluginDir),
              let stringsData = try? Data(contentsOf: stringsURL),
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
        "status.invalidPath": "Invalid file or folder name",
        "status.fileTooLargeFormat": "File too large to open in editor (%@): %@",
        "status.gitTimedOutFormat": "Git %@ timed out",

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
        "git.commit.placeholder": "Enter commit message (⌘↵ to commit)",
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
        "statusbar.dock.gitHelp": "Git Panel (⌃⇧G)",
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
        "alert.unsavedQuit.titleFormat": "You have %d unsaved file(s). Save changes before quitting?",
        "alert.unsavedQuit.message": "Unsaved changes will be lost if you quit without saving.",
        "alert.unsavedQuit.saveAll": "Save All & Quit",
        "alert.unsavedQuit.quitWithoutSaving": "Quit Without Saving",
        "alert.discardFile.titleFormat": "Discard changes to \"%@\"?",
        "alert.discardFile.untrackedMsg": "This untracked file will be permanently deleted from disk.",
        "alert.discardFile.modifiedMsg": "Your uncommitted modifications to this file will be reverted.",
        "alert.discardAll.title": "Discard all uncommitted changes?",
        "alert.discardAll.message": "Tracked modifications will be reverted and untracked files will be removed.",

        "menu.edit.find": "Find...",
        "menu.edit.findReplace": "Find and Replace...",
        "menu.edit.findNext": "Find Next",
        "menu.edit.findPrevious": "Find Previous",
        "menu.edit.goToLine": "Go to Line...",
        "menu.edit.triggerCompletion": "Code Completion",
        "menu.edit.goToDefinition": "Go to Definition (F12 / ⌘Click)",
        "menu.view.showProblems": "Show Problems",
        "menu.run": "Run",
        "menu.run.run": "Run Project / File",
        "menu.run.test": "Run Tests",
        "menu.run.stop": "Stop Running Task",

        "find.toggleReplaceHelp": "Toggle Replace",
        "find.placeholder": "Find in file...",
        "find.caseSensitiveHelp": "Match Case",
        "find.regexHelp": "Regular Expression",
        "find.previousHelp": "Previous Match (⇧⌘G)",
        "find.nextHelp": "Next Match (⌘G)",
        "find.replacePlaceholder": "Replace with...",
        "find.replaceButton": "Replace",
        "find.replaceAllButton": "Replace All",
        "find.noResults": "No results",
        "find.replacedAllCountFormat": "Replaced %d occurrence(s)",
        "goToLine.label": "Go to Line:",
        "goToLine.placeholder": "Line number",
        "goToLine.jump": "Go",

        "panel.tab.terminal": "Terminal",
        "panel.tab.run": "Run",
        "panel.tab.problems": "Problems",
        "runner.run": "Run",
        "runner.rerun": "Rerun",
        "runner.stop": "Stop",
        "runner.clearHelp": "Clear Run Output",
        "runner.empty": "Run a project task or script to view output here.",
        "runner.exitCodeFormat": "[process exited with code %d]",
        "runner.selectTaskHelp": "Select Task",
        "runner.runHelp": "Run Selected Task (⌘R)",
        "runner.testHelp": "Run Project Tests (⌘U)",
        "runner.stopHelp": "Stop Running Task (⌘.)",
        "problems.empty": "No problems detected in workspace",
        "problems.summaryFormat": "%d errors, %d warnings",
        "statusbar.problemsHelp": "Show Problems Panel",

        "settings.tab.appearance": "Appearance",
        "settings.tab.languageServers": "Language Servers",
        "settings.lsp.subtitle": "Manage language servers for completion, diagnostics, and go-to-definition.",
        "settings.lsp.storageHintFormat": "Managed directory: %@",
        "settings.lsp.rescan": "Rescan",
        "settings.lsp.running": "Active",
        "settings.lsp.detected": "Detected",
        "settings.lsp.installed": "Installed",
        "settings.lsp.notInstalled": "Not installed",
        "settings.lsp.update": "Reinstall",
        "settings.lsp.uninstallHelp": "Uninstall managed language server",
        "settings.lsp.readyBadge": "Ready",
        "settings.lsp.installingBadge": "Installing",
        "settings.lsp.detectButton": "Detect",
        "settings.lsp.installButton": "Install",
        "settings.lsp.currentFile": "Auto-selected for Current File",
        "statusbar.lsp.help": "Auto-selected Language Server for current file (click to configure)",

        "lsp.status.preparing": "Preparing...",
        "lsp.status.detecting": "Detecting toolchain...",
        "lsp.status.downloading": "Downloading...",
        "lsp.status.extracting": "Extracting...",
        "lsp.status.fetchingRelease": "Checking latest release...",
        "lsp.status.installingNpm": "Installing via npm...",
        "lsp.status.installingGo": "Installing via go...",
        "lsp.error.xcodeToolsRequired": "Not found. Run `%@` in Terminal to install Xcode Command Line Tools.",
        "lsp.error.checksumMismatch": "Downloaded binary checksum verification failed.",
        "lsp.error.npmMissing": "npm not found in PATH. Install Node.js or run `%@`.",
        "lsp.error.goMissing": "go toolchain not found in PATH. Install Go or run `%@`.",
        "lsp.definition.notFound": "Definition not found"
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
        "status.fileOpFailedFormat": "操作失败：%@",
        "status.invalidPath": "无效的文件或文件夹名称",
        "status.fileTooLargeFormat": "文件过大无法在编辑器中打开（%@）：%@",
        "status.gitTimedOutFormat": "Git %@ 执行超时",

        "alert.unsavedQuit.titleFormat": "有 %d 个未保存的文件，退出前是否保存更改？",
        "alert.unsavedQuit.message": "如果不保存直接退出，未保存的修改将会丢失。",
        "alert.unsavedQuit.saveAll": "全部保存并退出",
        "alert.unsavedQuit.quitWithoutSaving": "不保存并退出",

        "statusbar.dock.gitHelp": "Git 面板 (⌃⇧G)",
        "git.commit.placeholder": "输入提交说明 (⌘↵ 提交)",

        "menu.edit.find": "查找...",
        "menu.edit.findReplace": "查找并替换...",
        "menu.edit.findNext": "查找下一个",
        "menu.edit.findPrevious": "查找上一个",
        "menu.edit.goToLine": "跳转到行...",
        "menu.edit.triggerCompletion": "代码补全",
        "menu.edit.goToDefinition": "跳转到定义 (F12 / ⌘点击)",
        "menu.view.showProblems": "显示问题面板",
        "menu.run": "运行",
        "menu.run.run": "运行项目 / 文件",
        "menu.run.test": "运行测试",
        "menu.run.stop": "停止运行",

        "find.toggleReplaceHelp": "展开/收起替换",
        "find.placeholder": "在当前文件中查找...",
        "find.caseSensitiveHelp": "区分大小写",
        "find.regexHelp": "正则表达式",
        "find.previousHelp": "上一个匹配 (⇧⌘G)",
        "find.nextHelp": "下一个匹配 (⌘G)",
        "find.replacePlaceholder": "替换为...",
        "find.replaceButton": "替换",
        "find.replaceAllButton": "全部替换",
        "find.noResults": "无匹配",
        "find.replacedAllCountFormat": "已替换 %d 处",
        "goToLine.label": "跳转到行：",
        "goToLine.placeholder": "输入行号",
        "goToLine.jump": "跳转",

        "panel.tab.terminal": "终端",
        "panel.tab.run": "运行输出",
        "panel.tab.problems": "问题",
        "runner.run": "运行",
        "runner.rerun": "重新运行",
        "runner.stop": "停止",
        "runner.clearHelp": "清空运行输出",
        "runner.empty": "运行项目任务或当前脚本后，输出将显示在此处。",
        "runner.exitCodeFormat": "[进程已退出，退出码 %d]",
        "runner.selectTaskHelp": "选择运行任务",
        "runner.runHelp": "运行当前任务 (⌘R)",
        "runner.testHelp": "运行项目测试 (⌘U)",
        "runner.stopHelp": "停止当前任务 (⌘.)",
        "problems.empty": "工作区暂无错误或警告",
        "problems.summaryFormat": "%d 个错误，%d 个警告",
        "statusbar.problemsHelp": "打开问题面板",

        "settings.tab.appearance": "外观与语言",
        "settings.tab.languageServers": "语言服务器 (LSP)",
        "settings.lsp.subtitle": "管理代码补全、错误诊断与跳转定义所需的语言服务器。",
        "settings.lsp.storageHintFormat": "托管目录：%@",
        "settings.lsp.rescan": "重新扫描",
        "settings.lsp.running": "运行中",
        "settings.lsp.detected": "已检测到",
        "settings.lsp.installed": "已安装",
        "settings.lsp.notInstalled": "未安装",
        "settings.lsp.update": "重新安装",
        "settings.lsp.uninstallHelp": "卸载托管的语言服务器",
        "settings.lsp.readyBadge": "就绪",
        "settings.lsp.installingBadge": "安装中",
        "settings.lsp.detectButton": "检测",
        "settings.lsp.installButton": "安装",
        "settings.lsp.currentFile": "当前文件自动匹配",
        "statusbar.lsp.help": "当前文件自动选择的语言服务器（点击管理）",
        "common.close": "关闭",

        "lsp.status.preparing": "准备中...",
        "lsp.status.detecting": "正在检测工具链...",
        "lsp.status.downloading": "正在下载...",
        "lsp.status.extracting": "正在解压...",
        "lsp.status.fetchingRelease": "获取最新版本...",
        "lsp.status.installingNpm": "正在通过 npm 安装...",
        "lsp.status.installingGo": "正在通过 go 安装...",
        "lsp.error.xcodeToolsRequired": "未找到工具链，请在终端运行 `%@` 安装 Xcode Command Line Tools。",
        "lsp.error.checksumMismatch": "下载包 SHA-256 校验失败。",
        "lsp.error.npmMissing": "未在 PATH 中找到 npm，请先安装 Node.js 或执行 `%@`。",
        "lsp.error.goMissing": "未在 PATH 中找到 go，请先安装 Go 或执行 `%@`。",
        "lsp.definition.notFound": "未找到符号定义"
    ]
}
