import AppKit
import Combine
import Foundation

// MARK: - WorkspaceState (Coordinator)

@MainActor
final class WorkspaceState: ObservableObject {
    @Published var rootURL: URL
    @Published var hasWorkspaceOpen: Bool
    @Published var rootItems: [FileItem] = []
    @Published var allWorkspaceFiles: [URL] = []
    @Published var openTabs: [EditorTab] = []
    @Published var activeTabID: UUID?

    @Published var sidebarMode: SidebarMode = .explorer
    @Published var isSidebarVisible: Bool = true
    @Published var isTerminalVisible: Bool = true
    @Published var activeOverlay: OverlayPanelMode = .none

    // Project Switcher & Bounded Session Snapshots (LRU up to 8 projects)
    @Published var windowProjects: [URL] = []
    @Published var recentProjects: [URL] = []
    var projectSessions: [String: ProjectSessionSnapshot] = [:]
    private var projectSessionOrder: [String] = []
    private static let maxCachedProjectSessions = 8

    // Git Worktree & Branch State
    @Published var isGitRepository: Bool = false
    @Published var gitBranch: String = "no-git"
    @Published var currentWorktreeName: String = "main"
    @Published var gitWorktrees: [GitWorktreeItem] = []
    @Published var gitBranches: [GitBranchItem] = []
    @Published var isGitOperationInProgress: Bool = false
    @Published var gitPanelTab: GitPanelTab = .changes
    @Published var gitChangeFilter: GitChangeFilter = .all
    @Published var gitCommitActionMode: GitCommitActionMode = .commitTracked
    @Published var gitCommitMessage: String = ""
    @Published var gitChanges: [GitChangedFileItem] = []
    @Published var gitCommitHistory: [GitCommitLogItem] = []
    @Published var lastCommitSubject: String = ""
    @Published var lastCommitShortHash: String = ""
    @Published var gitAheadCount: Int = 0
    @Published var gitBehindCount: Int = 0
    var gitRepoTopLevel: URL?
    private var activeGitOperationCount: Int = 0

    // Search State
    @Published var searchQuery: String = ""
    @Published var searchResults: [SearchMatch] = []
    @Published var isSearching: Bool = false
    @Published var searchFocusNonce: Int = 0

    // High-frequency editor status isolated into its own ObservableObject
    let editorStatus = EditorStatusModel()

    var statusMessage: String {
        get { editorStatus.statusMessage }
        set { editorStatus.statusMessage = newValue }
    }

    var lastRenderLatencyMs: Double {
        get { editorStatus.lastRenderLatencyMs }
        set { editorStatus.lastRenderLatencyMs = newValue }
    }

    // Non-published per-tab scroll/selection cache (0 redraws while scrolling or moving caret)
    var tabViewStates: [UUID: TabViewState] = [:]

    // Find & Replace, Diagnostics, Bottom Panel & Task Runner
    enum SettingsSection: String, CaseIterable, Sendable {
        case appearance
        case languageServers
    }

    let findState = EditorFindState()
    let taskRunner = TaskRunnerState()
    @Published var bottomPanelTab: BottomPanelTab = .terminal
    @Published var preferredSettingsSection: SettingsSection = .appearance
    @Published var diagnosticsByFile: [String: [LSPDiagnostic]] = [:]

    // Callbacks handled by Editor / Split Controller
    var onToggleCommentRequested: (() -> Void)?
    var onJumpToLocationRequested: ((Int, Int?) -> Void)?
    var onFocusEditorRequested: (() -> Void)?
    var onToggleSidebarAction: (() -> Void)?
    var onSelectSidebarModeAction: ((SidebarMode) -> Void)?
    var onToggleTerminalAction: (() -> Void)?
    var onShowBottomPanelAction: ((BottomPanelTab) -> Void)?
    var onRequestCompletionAction: (() -> Void)?
    var onGoToDefinitionAction: (() -> Void)?
    var onFindMatchesChanged: (() -> Void)?
    var onHighlightRangeRequested: ((NSRange) -> Void)?
    var onReplaceTextInActiveEditor: ((NSRange, String) -> Void)?
    var onReplaceAllTextInActiveEditor: ((String) -> Void)?
    var onDiagnosticsUpdated: (() -> Void)?

    var fileIndexTask: Task<Void, Never>?
    var searchTask: Task<Void, Never>?
    var gitMetadataTask: Task<Void, Never>?
    private var hasLoadedWorkspaceTree = false

    let userDefaults: UserDefaults
    var isProductionDefaults: Bool { userDefaults === UserDefaults.standard }

    private static let recentProjectsDefaultsKey = "swiftflash.recentProjects"

    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return openTabs.first { $0.id == activeTabID }
    }

    init(initialURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let startURL: URL?
        if let initialURL, Self.isExistingDirectory(initialURL) {
            startURL = initialURL.standardized
        } else {
            let savedPaths = userDefaults.stringArray(forKey: Self.recentProjectsDefaultsKey) ?? []
            startURL = savedPaths
                .map { URL(fileURLWithPath: $0).standardized }
                .first { Self.isExistingDirectory($0) }
        }

        if let startURL {
            self.rootURL = startURL
            self.hasWorkspaceOpen = true
            self.windowProjects = [startURL]
            loadRecentProjects(currentURL: startURL)
            reloadWorkspace()
            openInitialFiles()
        } else {
            self.rootURL = FileManager.default.homeDirectoryForCurrentUser.standardized
            self.hasWorkspaceOpen = false
            self.windowProjects = []
            self.recentProjects = []
            self.rootItems = []
            self.allWorkspaceFiles = []
        }

        if isProductionDefaults {
            LSPManager.shared.onDiagnosticsReceived = { [weak self] fileURL, diagnostics in
                guard let self else { return }
                let key = fileURL.standardized.path
                if diagnostics.isEmpty {
                    self.diagnosticsByFile.removeValue(forKey: key)
                } else {
                    self.diagnosticsByFile[key] = diagnostics
                }
                self.onDiagnosticsUpdated?()
            }
            LSPManager.shared.onServerBecameReady = { [weak self] in
                self?.connectActiveTabToLSP()
            }
            LSPManager.shared.refreshStatuses()
        }
    }

    static func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.standardized.path, isDirectory: &isDir) && isDir.boolValue
    }

    func beginGitOperation() {
        activeGitOperationCount += 1
        isGitOperationInProgress = true
    }

    func endGitOperation() {
        activeGitOperationCount = max(0, activeGitOperationCount - 1)
        isGitOperationInProgress = activeGitOperationCount > 0
    }

    // MARK: - Overlay Control

    func openSettings(section: SettingsSection = .appearance) {
        preferredSettingsSection = section
        activeOverlay = .settings
    }

    func toggleOverlay(_ mode: OverlayPanelMode) {
        if activeOverlay == mode {
            dismissOverlay()
        } else {
            activeOverlay = mode
            if mode == .worktreeSwitcher || mode == .branchSwitcher {
                refreshGitMetadata()
            }
        }
    }

    func dismissOverlay() {
        activeOverlay = .none
        onFocusEditorRequested?()
    }

    // MARK: - Project & Folder Switching

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n("dialog.openFolder.prompt")
        panel.message = L10n("dialog.openFolder.message")
        if panel.runModal() == .OK, let url = panel.url {
            switchProject(to: url)
        }
    }

    func addFolderToWindowPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n("dialog.addFolder.prompt")
        panel.message = L10n("dialog.addFolder.message")
        if panel.runModal() == .OK, let url = panel.url {
            let normalized = url.standardized
            if !windowProjects.contains(where: { $0.standardized.path == normalized.path }) {
                windowProjects.append(normalized)
            }
            recordRecentProject(normalized)
            switchProject(to: normalized)
        }
    }

    func switchProject(to url: URL) {
        let target = url.standardized
        guard Self.isExistingDirectory(target) else {
            statusMessage = L10n("status.folderNotFoundFormat", target.lastPathComponent)
            return
        }

        let wasOpen = hasWorkspaceOpen
        let currentKey = rootURL.standardized.path
        if !wasOpen || currentKey != target.path {
            if wasOpen {
                saveProjectSessionSnapshot(forKey: currentKey)
            }
            if isProductionDefaults {
                LSPManager.shared.shutdownAll()
            }
            diagnosticsByFile.removeAll()
            taskRunner.stop()
            rootURL = target

            if let snapshot = projectSessions[target.path] {
                openTabs = snapshot.openTabs
                activeTabID = snapshot.activeTabID
                tabViewStates = snapshot.tabViewStates
                reloadUnmodifiedOpenTabs()
            } else {
                openTabs.removeAll()
                activeTabID = nil
                tabViewStates.removeAll()
            }
        }

        hasWorkspaceOpen = true
        if !windowProjects.contains(where: { $0.standardized.path == target.path }) {
            windowProjects.append(target)
        }
        recordRecentProject(target)

        searchQuery = ""
        searchResults = []
        reloadWorkspace(resetExpansion: true)
        if openTabs.isEmpty {
            openInitialFiles()
        } else {
            connectActiveTabToLSP()
        }
        refreshTasksForCurrentContext()
        statusMessage = L10n("status.switchedToFormat", target.lastPathComponent)
        dismissOverlay()
    }

    private func saveProjectSessionSnapshot(forKey key: String) {
        projectSessions[key] = ProjectSessionSnapshot(
            openTabs: openTabs,
            activeTabID: activeTabID,
            tabViewStates: tabViewStates
        )
        projectSessionOrder.removeAll { $0 == key }
        projectSessionOrder.append(key)

        // Evict oldest clean snapshots beyond LRU limit so RAM does not grow unboundedly.
        while projectSessionOrder.count > Self.maxCachedProjectSessions {
            if let evictIndex = projectSessionOrder.firstIndex(where: { candidate in
                candidate != key && !(projectSessions[candidate]?.openTabs.contains(where: \.isDirty) ?? false)
            }) {
                let evictedKey = projectSessionOrder.remove(at: evictIndex)
                projectSessions.removeValue(forKey: evictedKey)
            } else {
                break
            }
        }
    }

    private func loadRecentProjects(currentURL: URL?) {
        var merged: [URL] = []
        var seenPaths = Set<String>()

        func appendIfValidDir(_ url: URL) {
            let std = url.standardized
            guard !seenPaths.contains(std.path), Self.isExistingDirectory(std) else { return }
            seenPaths.insert(std.path)
            merged.append(std)
        }

        if let currentURL {
            appendIfValidDir(currentURL)
        }

        let savedPaths = userDefaults.stringArray(forKey: Self.recentProjectsDefaultsKey) ?? []
        for path in savedPaths {
            appendIfValidDir(URL(fileURLWithPath: path))
        }

        recentProjects = merged
        persistRecentProjects()
    }

    func recordRecentProject(_ url: URL) {
        let std = url.standardized
        recentProjects.removeAll { $0.standardized.path == std.path }
        recentProjects.insert(std, at: 0)
        if recentProjects.count > 40 {
            recentProjects = Array(recentProjects.prefix(40))
        }
        persistRecentProjects()
    }

    private func persistRecentProjects() {
        let paths = recentProjects.map { $0.standardized.path }
        userDefaults.set(paths, forKey: Self.recentProjectsDefaultsKey)
    }

    func reloadWorkspace(
        ensuringExpanded additionalExpandedURLs: [URL] = [],
        replacingExpandedPrefix: (old: URL, new: URL)? = nil,
        resetExpansion: Bool = false
    ) {
        var expandedPaths: Set<String> = resetExpansion ? [] : Self.collectExpandedPaths(from: rootItems)

        if let remap = replacingExpandedPrefix {
            let oldPath = remap.old.standardized.path
            let newPath = remap.new.standardized.path
            var remapped = Set<String>()
            for path in expandedPaths {
                if path == oldPath {
                    remapped.insert(newPath)
                } else if path.hasPrefix(oldPath + "/") {
                    remapped.insert(newPath + String(path.dropFirst(oldPath.count)))
                } else {
                    remapped.insert(path)
                }
            }
            expandedPaths = remapped
        }

        let rootPath = rootURL.standardized.path
        for url in additionalExpandedURLs {
            var current = url.standardized
            while current.path.count >= rootPath.count {
                expandedPaths.insert(current.path)
                if current.path == rootPath { break }
                let parent = current.deletingLastPathComponent().standardized
                if parent.path == current.path { break }
                current = parent
            }
        }

        let rootItem = FileItem(url: rootURL, isDirectory: true)
        rootItem.loadChildrenIfNeeded()
        let newItems = rootItem.children ?? []

        if !hasLoadedWorkspaceTree || resetExpansion {
            hasLoadedWorkspaceTree = true
            for item in newItems where item.name == "Sources" && item.isDirectory {
                expandedPaths.insert(item.url.standardized.path)
            }
        }

        Self.restoreExpandedPaths(expandedPaths, in: newItems)
        rootItems = newItems

        refreshGitMetadata()
        rebuildFileIndex()
        refreshTasksForCurrentContext()
    }

    private static func collectExpandedPaths(from items: [FileItem]) -> Set<String> {
        var result = Set<String>()
        for item in items where item.isDirectory && item.isExpanded {
            result.insert(item.url.standardized.path)
            if let children = item.children {
                result.formUnion(collectExpandedPaths(from: children))
            }
        }
        return result
    }

    private static func restoreExpandedPaths(_ paths: Set<String>, in items: [FileItem]) {
        for item in items where item.isDirectory {
            if paths.contains(item.url.standardized.path) {
                item.isExpanded = true
                item.loadChildrenIfNeeded()
                if let children = item.children {
                    restoreExpandedPaths(paths, in: children)
                }
            }
        }
    }

    private func openInitialFiles() {
        let candidates = [
            rootURL.appendingPathComponent("README.md"),
            rootURL.appendingPathComponent("Package.swift"),
            rootURL.appendingPathComponent("Cargo.toml"),
            rootURL.appendingPathComponent("package.json")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            openFile(url: candidate)
            return
        }
    }

    func rebuildFileIndex() {
        fileIndexTask?.cancel()
        let root = rootURL
        fileIndexTask = Task.detached(priority: .utility) {
            let indexed = Self.scanAllFiles(under: root, limit: 8000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.rootURL.standardized.path == root.standardized.path else { return }
                self.allWorkspaceFiles = indexed
            }
        }
    }

    private nonisolated static func scanAllFiles(under root: URL, limit: Int) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            if Task.isCancelled || results.count >= limit { break }
            let name = fileURL.lastPathComponent
            if FileItem.ignoredNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == false {
                results.append(fileURL)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - Sidebar & Tab Lifecycle

    func toggleDockPanel(_ mode: SidebarMode) {
        if let onSelectSidebarModeAction {
            onSelectSidebarModeAction(mode)
        } else {
            if isSidebarVisible && sidebarMode == mode {
                isSidebarVisible = false
            } else {
                sidebarMode = mode
                isSidebarVisible = true
                if mode == .git {
                    refreshGitMetadata()
                }
            }
        }
        if mode == .search && isSidebarVisible {
            searchFocusNonce &+= 1
        }
    }

    func reloadUnmodifiedOpenTabs() {
        for idx in openTabs.indices {
            guard !openTabs[idx].isDirty, let url = openTabs[idx].url else { continue }
            if let data = try? Data(contentsOf: url),
               let text = Self.decodeTextFile(data) {
                if openTabs[idx].content != text {
                    openTabs[idx].replaceBufferAndMarkSaved(text)
                    openTabs[idx].externalReloadRevision += 1
                }
            }
        }
    }

    func connectActiveTabToLSP() {
        guard let tab = activeTab else { return }
        connectTabToLSP(tab)
    }

    func connectTabToLSP(_ tab: EditorTab) {
        guard isProductionDefaults, let url = tab.url else { return }
        let root = rootURL
        let lang = tab.language
        let content = tab.content
        Task {
            await LSPManager.shared.ensureSessionAndOpenDocument(
                url: url,
                language: lang,
                content: content,
                workspaceRoot: root
            )
        }
    }

    func closeTab(id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = openTabs[index]
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = L10n("alert.saveChanges.titleFormat", tab.title)
            alert.informativeText = L10n("alert.saveChanges.message")
            alert.addButton(withTitle: L10n("common.save"))
            alert.addButton(withTitle: L10n("common.dontSave"))
            alert.addButton(withTitle: L10n("common.cancel"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                activeTabID = tab.id
                if !saveActiveTab() { return }
            } else if response == .alertThirdButtonReturn {
                return
            }
        }

        if let tabURL = tab.url, isProductionDefaults {
            LSPManager.shared.notifyDocumentClosed(url: tabURL, language: tab.language, workspaceRoot: rootURL)
        }
        tabViewStates.removeValue(forKey: id)
        openTabs.remove(at: index)
        if activeTabID == id {
            if openTabs.isEmpty {
                activeTabID = nil
            } else {
                let nextIdx = min(index, openTabs.count - 1)
                activeTabID = openTabs[nextIdx].id
            }
        }
        refreshTasksForCurrentContext()
    }

    func selectTab(id: UUID) {
        activeTabID = id
        if let state = tabViewStates[id] {
            editorStatus.cursorLine = state.cursorLine
            editorStatus.cursorColumn = state.cursorColumn
        } else {
            editorStatus.cursorLine = 1
            editorStatus.cursorColumn = 1
        }
        refreshTasksForCurrentContext()
        if let tab = activeTab {
            connectTabToLSP(tab)
        }
        if findState.isFindBarVisible {
            recomputeFindMatches()
        }
        onFocusEditorRequested?()
    }

    func closeActiveTab() {
        if let activeTabID {
            closeTab(id: activeTabID)
        }
    }

    func clearPendingJump(for tabID: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        if openTabs[idx].pendingJumpLine != nil || openTabs[idx].pendingJumpColumn != nil {
            openTabs[idx].pendingJumpLine = nil
            openTabs[idx].pendingJumpColumn = nil
        }
    }

    func scrollOffsetY(for tabID: UUID) -> CGFloat? {
        tabViewStates[tabID]?.scrollOffsetY
    }

    func selectedRange(for tabID: UUID) -> NSRange {
        tabViewStates[tabID]?.selectedRange ?? NSRange(location: 0, length: 0)
    }

    /// Mutates buffer text in place via `TextBufferBox` so typing only publishes `@Published openTabs`
    /// when `isDirty` actually flips (0 SwiftUI full-window redraws per subsequent keystroke).
    func updateActiveTabContent(_ newContent: String) {
        guard let activeTabID,
              let idx = openTabs.firstIndex(where: { $0.id == activeTabID }) else { return }

        let tab = openTabs[idx]
        guard tab.content != newContent else { return }

        let nowDirty = (tab.virtualKey == nil && newContent != tab.savedContent)
        if nowDirty != tab.isDirty {
            var updated = tab
            _ = updated.updateBufferContent(newContent)
            openTabs[idx] = updated
        } else {
            // Mutate reference box without mutating `@Published var openTabs`.
            tab.content = newContent
        }

        if let url = tab.url, isProductionDefaults {
            LSPManager.shared.notifyDocumentChanged(
                url: url,
                language: tab.language,
                content: newContent,
                workspaceRoot: rootURL
            )
        }
        if findState.isFindBarVisible {
            recomputeFindMatches()
        }
    }

    func updateActiveTabCursor(line: Int, column: Int, range: NSRange) {
        guard let activeTabID else { return }
        var state = tabViewStates[activeTabID] ?? TabViewState()
        state.cursorLine = line
        state.cursorColumn = column
        state.selectedRange = range
        tabViewStates[activeTabID] = state

        if editorStatus.cursorLine != line {
            editorStatus.cursorLine = line
        }
        if editorStatus.cursorColumn != column {
            editorStatus.cursorColumn = column
        }
    }

    func updateActiveTabScroll(y: CGFloat) {
        guard let activeTabID else { return }
        var state = tabViewStates[activeTabID] ?? TabViewState()
        state.scrollOffsetY = y
        tabViewStates[activeTabID] = state
    }

    func updateRenderLatency(_ ms: Double) {
        editorStatus.lastRenderLatencyMs = ms
    }

    func relativePath(for url: URL?) -> String {
        guard let url else { return L10n("common.unsavedBuffer") }
        let rootPath = rootURL.path
        if url.path.hasPrefix(rootPath + "/") {
            return String(url.path.dropFirst(rootPath.count + 1))
        }
        return url.path
    }

    // MARK: - Diagnostics & Task Runner Helpers

    var diagnosticsForActiveTab: [LSPDiagnostic] {
        guard let url = activeTab?.url else { return [] }
        return diagnosticsByFile[url.standardized.path] ?? []
    }

    var allDiagnosticEntries: [WorkspaceDiagnosticEntry] {
        var entries: [WorkspaceDiagnosticEntry] = []
        for (path, list) in diagnosticsByFile {
            let url = URL(fileURLWithPath: path)
            let rel = relativePath(for: url)
            for diag in list {
                entries.append(WorkspaceDiagnosticEntry(fileURL: url, relativePath: rel, diagnostic: diag))
            }
        }
        return entries.sorted { lhs, rhs in
            if lhs.diagnostic.severity.rawValue != rhs.diagnostic.severity.rawValue {
                return lhs.diagnostic.severity.rawValue < rhs.diagnostic.severity.rawValue
            }
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.diagnostic.range.start.line < rhs.diagnostic.range.start.line
        }
    }

    var totalErrorCount: Int {
        diagnosticsByFile.values.reduce(0) { acc, list in
            acc + list.filter { $0.severity == .error }.count
        }
    }

    var totalWarningCount: Int {
        diagnosticsByFile.values.reduce(0) { acc, list in
            acc + list.filter { $0.severity == .warning }.count
        }
    }

    func showBottomPanel(_ tab: BottomPanelTab) {
        bottomPanelTab = tab
        onShowBottomPanelAction?(tab)
    }

    func refreshTasksForCurrentContext() {
        taskRunner.refreshTasks(in: rootURL, activeFileURL: activeTab?.url, hasWorkspaceOpen: hasWorkspaceOpen)
    }

    func runTask(_ task: ProjectTask) {
        guard hasWorkspaceOpen else { return }
        if activeTab?.isDirty == true {
            _ = saveActiveTab()
        }
        showBottomPanel(.run)
        taskRunner.run(task: task, in: rootURL)
    }

    func runDefaultRunTask() {
        guard hasWorkspaceOpen else { return }
        refreshTasksForCurrentContext()
        if activeTab?.isDirty == true {
            _ = saveActiveTab()
        }
        showBottomPanel(.run)
        taskRunner.runDefault(kind: .run, in: rootURL, activeFileURL: activeTab?.url)
    }

    func runDefaultTestTask() {
        guard hasWorkspaceOpen else { return }
        refreshTasksForCurrentContext()
        if activeTab?.isDirty == true {
            _ = saveActiveTab()
        }
        showBottomPanel(.run)
        taskRunner.runDefault(kind: .test, in: rootURL, activeFileURL: activeTab?.url)
    }

    func stopRunningTask() {
        taskRunner.stop()
    }
}
