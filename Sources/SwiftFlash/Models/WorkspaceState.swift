import AppKit
import Combine
import Foundation

// MARK: - Editor Pane Handler Registration (Supports Split Editor)

@MainActor
struct EditorPaneHandlers {
    var toggleComment: (() -> Void)?
    var jumpToLocation: ((Int, Int?) -> Void)?
    var focusEditor: (() -> Void)?
    var requestCompletion: (() -> Void)?
    var goToDefinition: (() -> Void)?
    var findReferences: (() -> Void)?
    var showHover: (() -> Void)?
    var formatDocument: (() -> Void)?
    var findMatchesChanged: (() -> Void)?
    var highlightRange: ((NSRange) -> Void)?
    var replaceText: ((NSRange, String) -> Void)?
    var replaceAllText: ((String) -> Void)?
    var diagnosticsUpdated: (() -> Void)?
    var selectNextOccurrence: (() -> Void)?
    var moveLines: ((Bool) -> Void)?
    var duplicateLines: ((Bool) -> Void)?
    var deleteLines: (() -> Void)?
    var insertLine: ((Bool) -> Void)?
    var syncBufferExternally: ((UUID, String) -> Void)?
}

// MARK: - WorkspaceState (Coordinator)

@MainActor
final class WorkspaceState: ObservableObject {
    @Published var rootURL: URL
    @Published var hasWorkspaceOpen: Bool
    @Published var rootItems: [FileItem] = []
    @Published var allWorkspaceFiles: [URL] = []
    @Published var openTabs: [EditorTab] = []
    @Published var activeTabID: UUID?

    // Split Editor State
    @Published var isSplitEditorActive: Bool = false
    @Published var secondaryTabID: UUID?
    @Published var focusedEditorPane: EditorPane = .primary

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

    // Advanced Global Search & Replace State
    @Published var searchQuery: String = ""
    @Published var searchResults: [SearchMatch] = []
    @Published var isSearching: Bool = false
    @Published var searchFocusNonce: Int = 0
    @Published var searchCaseSensitive: Bool = false
    @Published var searchWholeWord: Bool = false
    @Published var searchUseRegex: Bool = false
    @Published var searchIncludeGlob: String = ""
    @Published var searchExcludeGlob: String = ""
    @Published var globalReplaceQuery: String = ""
    @Published var isGlobalReplaceExpanded: Bool = false
    @Published var searchRegexError: String? = nil

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

    // Find & Replace, Diagnostics, References, Symbols, Navigation, Bottom Panel & Task Runner
    enum SettingsSection: String, CaseIterable, Sendable {
        case appearance
        case languageServers
    }

    let findState = EditorFindState()
    let taskRunner = TaskRunnerState()
    let navigationHistory = NavigationHistory()
    @Published var bottomPanelTab: BottomPanelTab = .terminal
    @Published var preferredSettingsSection: SettingsSection = .appearance
    @Published var diagnosticsByFile: [String: [LSPDiagnostic]] = [:]

    // LSP References & Document Symbols
    @Published var referenceResults: [WorkspaceReferenceEntry] = []
    @Published var referenceTargetTitle: String = ""
    @Published var isLoadingReferences: Bool = false
    @Published var activeDocumentSymbols: [LSPDocumentSymbol] = []
    @Published var currentBreadcrumbSymbol: LSPDocumentSymbol?

    // Split-aware Editor Pane Handlers
    private var paneHandlers: [EditorPane: EditorPaneHandlers] = [:]

    // Direct callbacks (backward compatible & split-routed)
    var onToggleCommentRequested: (() -> Void)? {
        get { activePaneHandlers?.toggleComment }
        set { setLegacyHandler(\.toggleComment, newValue) }
    }
    var onJumpToLocationRequested: ((Int, Int?) -> Void)? {
        get { activePaneHandlers?.jumpToLocation }
        set { setLegacyHandler(\.jumpToLocation, newValue) }
    }
    var onFocusEditorRequested: (() -> Void)? {
        get { activePaneHandlers?.focusEditor }
        set { setLegacyHandler(\.focusEditor, newValue) }
    }
    var onRequestCompletionAction: (() -> Void)? {
        get { activePaneHandlers?.requestCompletion }
        set { setLegacyHandler(\.requestCompletion, newValue) }
    }
    var onGoToDefinitionAction: (() -> Void)? {
        get { activePaneHandlers?.goToDefinition }
        set { setLegacyHandler(\.goToDefinition, newValue) }
    }
    var onFindReferencesAction: (() -> Void)? {
        get { activePaneHandlers?.findReferences }
        set { setLegacyHandler(\.findReferences, newValue) }
    }
    var onShowHoverAction: (() -> Void)? {
        get { activePaneHandlers?.showHover }
        set { setLegacyHandler(\.showHover, newValue) }
    }
    var onFormatDocumentAction: (() -> Void)? {
        get { activePaneHandlers?.formatDocument }
        set { setLegacyHandler(\.formatDocument, newValue) }
    }
    var onFindMatchesChanged: (() -> Void)? {
        get {
            { [weak self] in
                self?.paneHandlers[.primary]?.findMatchesChanged?()
                self?.paneHandlers[.secondary]?.findMatchesChanged?()
            }
        }
        set { setLegacyHandler(\.findMatchesChanged, newValue) }
    }
    var onHighlightRangeRequested: ((NSRange) -> Void)? {
        get { activePaneHandlers?.highlightRange }
        set { setLegacyHandler(\.highlightRange, newValue) }
    }
    var onReplaceTextInActiveEditor: ((NSRange, String) -> Void)? {
        get { activePaneHandlers?.replaceText }
        set { setLegacyHandler(\.replaceText, newValue) }
    }
    var onReplaceAllTextInActiveEditor: ((String) -> Void)? {
        get { activePaneHandlers?.replaceAllText }
        set { setLegacyHandler(\.replaceAllText, newValue) }
    }
    var onDiagnosticsUpdated: (() -> Void)? {
        get {
            { [weak self] in
                self?.paneHandlers[.primary]?.diagnosticsUpdated?()
                self?.paneHandlers[.secondary]?.diagnosticsUpdated?()
            }
        }
        set { setLegacyHandler(\.diagnosticsUpdated, newValue) }
    }
    var onSelectNextOccurrenceAction: (() -> Void)? {
        get { activePaneHandlers?.selectNextOccurrence }
        set { setLegacyHandler(\.selectNextOccurrence, newValue) }
    }
    var onMoveLinesAction: ((Bool) -> Void)? {
        get { activePaneHandlers?.moveLines }
        set { setLegacyHandler(\.moveLines, newValue) }
    }
    var onDuplicateLinesAction: ((Bool) -> Void)? {
        get { activePaneHandlers?.duplicateLines }
        set { setLegacyHandler(\.duplicateLines, newValue) }
    }
    var onDeleteLinesAction: (() -> Void)? {
        get { activePaneHandlers?.deleteLines }
        set { setLegacyHandler(\.deleteLines, newValue) }
    }
    var onInsertLineAction: ((Bool) -> Void)? {
        get { activePaneHandlers?.insertLine }
        set { setLegacyHandler(\.insertLine, newValue) }
    }

    // Window / Chrome actions
    var onToggleSidebarAction: (() -> Void)?
    var onSelectSidebarModeAction: ((SidebarMode) -> Void)?
    var onToggleTerminalAction: (() -> Void)?
    var onShowBottomPanelAction: ((BottomPanelTab) -> Void)?
    var onNewTerminalTabAction: (() -> Void)?
    var onNewWindowRequested: (() -> Void)?
    var onOpenFolderInNewWindowRequested: (() -> Void)?

    var fileIndexTask: Task<Void, Never>?
    var searchTask: Task<Void, Never>?
    var gitMetadataTask: Task<Void, Never>?
    var symbolsTask: Task<Void, Never>?
    private var hasLoadedWorkspaceTree = false
    private var isNavigatingHistory = false
    private var fileWatcher: WorkspaceFileWatcher?
    private var lspCancellables: Set<AnyCancellable> = []

    let userDefaults: UserDefaults
    var isProductionDefaults: Bool { userDefaults === UserDefaults.standard }

    private static let recentProjectsDefaultsKey = "swiftflash.recentProjects"

    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return openTabs.first { $0.id == activeTabID }
    }

    var secondaryTab: EditorTab? {
        guard let secondaryTabID else { return nil }
        return openTabs.first { $0.id == secondaryTabID }
    }

    var focusedTabID: UUID? {
        if isSplitEditorActive && focusedEditorPane == .secondary {
            return secondaryTabID ?? activeTabID
        }
        return activeTabID
    }

    var focusedTab: EditorTab? {
        guard let id = focusedTabID else { return nil }
        return openTabs.first { $0.id == id }
    }

    private var activePaneHandlers: EditorPaneHandlers? {
        if isSplitEditorActive, let h = paneHandlers[focusedEditorPane] {
            return h
        }
        return paneHandlers[.primary] ?? paneHandlers[.secondary]
    }

    private func setLegacyHandler<T>(_ keyPath: WritableKeyPath<EditorPaneHandlers, T?>, _ value: T?) {
        var h = paneHandlers[.primary] ?? EditorPaneHandlers()
        h[keyPath: keyPath] = value
        paneHandlers[.primary] = h
    }

    func registerEditorHandlers(_ handlers: EditorPaneHandlers, for pane: EditorPane) {
        paneHandlers[pane] = handlers
    }

    func unregisterEditorHandlers(for pane: EditorPane) {
        paneHandlers.removeValue(forKey: pane)
    }

    func handlers(for pane: EditorPane) -> EditorPaneHandlers? {
        paneHandlers[pane]
    }

    init(
        initialURL: URL? = nil,
        userDefaults: UserDefaults = .standard,
        restoreLastProjectIfNil: Bool = true
    ) {
        self.userDefaults = userDefaults

        let startURL: URL?
        if let initialURL, Self.isExistingDirectory(initialURL) {
            startURL = initialURL.standardized
        } else if restoreLastProjectIfNil {
            let savedPaths = userDefaults.stringArray(forKey: Self.recentProjectsDefaultsKey) ?? []
            startURL = savedPaths
                .map { URL(fileURLWithPath: $0).standardized }
                .first { Self.isExistingDirectory($0) }
        } else {
            startURL = nil
        }

        if let startURL {
            self.rootURL = startURL
            self.hasWorkspaceOpen = true
            self.windowProjects = [startURL]
            loadRecentProjects(currentURL: startURL)
            reloadWorkspace()
            if !restorePersistedSessionIfAvailable(for: startURL) {
                openInitialFiles()
            }
            startFileWatcher(for: startURL)
        } else {
            self.rootURL = FileManager.default.homeDirectoryForCurrentUser.standardized
            self.hasWorkspaceOpen = false
            self.windowProjects = []
            self.recentProjects = []
            self.rootItems = []
            self.allWorkspaceFiles = []
        }

        if isProductionDefaults {
            NotificationCenter.default.publisher(
                for: LSPManager.diagnosticsDidUpdateNotification,
                object: LSPManager.shared
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let url = note.userInfo?["url"] as? URL,
                      let diagnostics = note.userInfo?["diagnostics"] as? [LSPDiagnostic] else { return }
                let key = url.standardized.path
                if diagnostics.isEmpty {
                    self.diagnosticsByFile.removeValue(forKey: key)
                } else {
                    self.diagnosticsByFile[key] = diagnostics
                }
                self.onDiagnosticsUpdated?()
            }
            .store(in: &lspCancellables)

            NotificationCenter.default.publisher(
                for: LSPManager.serverBecameReadyNotification,
                object: LSPManager.shared
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.connectActiveTabToLSP()
            }
            .store(in: &lspCancellables)

            LSPManager.shared.refreshStatuses()
        }
    }

    deinit {
        fileWatcher?.stop()
    }

    func teardownResources() {
        persistCurrentProjectSession()
        fileWatcher?.stop()
        fileWatcher = nil
        fileIndexTask?.cancel()
        searchTask?.cancel()
        gitMetadataTask?.cancel()
        symbolsTask?.cancel()
        taskRunner.stop()
        lspCancellables.removeAll()
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

    // MARK: - FSEvents File Watcher

    func startFileWatcher(for directory: URL) {
        fileWatcher?.stop()
        guard Self.isExistingDirectory(directory) else { return }
        let watcher = WorkspaceFileWatcher(debounceInterval: 0.28) { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.handleExternalFileChangeBatch(batch)
            }
        }
        watcher.start(watching: directory)
        self.fileWatcher = watcher
    }

    func handleExternalFileChangeBatch(_ batch: WorkspaceFileChangeBatch) {
        guard hasWorkspaceOpen else { return }

        if batch.structureChanged {
            reloadWorkspace(refreshGit: false)
        }
        if batch.gitChanged || batch.structureChanged {
            refreshGitMetadata()
        }

        if !batch.modifiedFilePaths.isEmpty {
            let modifiedSet = Set(batch.modifiedFilePaths.map { URL(fileURLWithPath: $0).standardized.path })
            for idx in openTabs.indices {
                guard let tabURL = openTabs[idx].url else { continue }
                let tabPath = tabURL.standardized.path
                let resolvedTabPath = tabURL.resolvingSymlinksInPath().standardized.path
                guard modifiedSet.contains(tabPath) || modifiedSet.contains(resolvedTabPath) else { continue }

                guard FileManager.default.fileExists(atPath: tabPath),
                      let data = try? Data(contentsOf: tabURL),
                      let diskText = Self.decodeTextFile(data) else {
                    continue
                }

                if !openTabs[idx].isDirty {
                    if openTabs[idx].content != diskText {
                        openTabs[idx].replaceBufferAndMarkSaved(diskText)
                        openTabs[idx].externalReloadRevision += 1
                        if isProductionDefaults {
                            LSPManager.shared.notifyDocumentChanged(
                                url: tabURL,
                                language: openTabs[idx].language,
                                content: diskText,
                                workspaceRoot: rootURL
                            )
                        }
                        if openTabs[idx].id == focusedTabID {
                            refreshActiveDocumentSymbols()
                        }
                    }
                } else if diskText != openTabs[idx].savedContent && diskText != openTabs[idx].content {
                    if !openTabs[idx].hasExternalConflict {
                        openTabs[idx].hasExternalConflict = true
                        statusMessage = L10n("status.externalFileChangedFormat", openTabs[idx].title)
                    }
                }
            }
        }
    }

    func reloadConflictedTab(id: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == id }),
              let url = openTabs[idx].url,
              let data = try? Data(contentsOf: url),
              let diskText = Self.decodeTextFile(data) else {
            return
        }
        openTabs[idx].replaceBufferAndMarkSaved(diskText)
        openTabs[idx].externalReloadRevision += 1
        statusMessage = L10n("status.reloadedFromDiskFormat", openTabs[idx].title)
        if isProductionDefaults {
            LSPManager.shared.notifyDocumentChanged(
                url: url,
                language: openTabs[idx].language,
                content: diskText,
                workspaceRoot: rootURL
            )
        }
        if id == focusedTabID {
            refreshActiveDocumentSymbols()
        }
    }

    func keepLocalChangesForTab(id: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == id }) else { return }
        openTabs[idx].hasExternalConflict = false
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
            } else if mode == .symbolOutline {
                refreshActiveDocumentSymbols()
            }
        }
    }

    func dismissOverlay() {
        activeOverlay = .none
        onFocusEditorRequested?()
    }

    // MARK: - Navigation History (Back / Forward)

    func currentNavigationLocation() -> NavigationLocation? {
        guard let tab = focusedTab, let url = tab.url else { return nil }
        let state = tabViewStates[tab.id]
        let line = max(1, state?.cursorLine ?? editorStatus.cursorLine)
        let col = max(1, state?.cursorColumn ?? editorStatus.cursorColumn)
        return NavigationLocation(url: url, line: line, column: col)
    }

    func recordCurrentNavigationLocation() {
        guard !isNavigatingHistory, let loc = currentNavigationLocation() else { return }
        navigationHistory.record(loc)
    }

    func navigateBack() {
        guard let target = navigationHistory.goBack(from: currentNavigationLocation()) else { return }
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        openFile(url: target.url, atLine: target.line, atColumn: target.column, recordHistory: false)
    }

    func navigateForward() {
        guard let target = navigationHistory.goForward(from: currentNavigationLocation()) else { return }
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        openFile(url: target.url, atLine: target.line, atColumn: target.column, recordHistory: false)
    }

    // MARK: - Split Editor Controls

    func toggleSplitEditor() {
        if isSplitEditorActive {
            closeSplitEditor()
        } else {
            guard !openTabs.isEmpty else { return }
            isSplitEditorActive = true
            if let existingSecondary = secondaryTabID, openTabs.contains(where: { $0.id == existingSecondary }) {
                // Keep existing secondary tab
            } else if let otherTab = openTabs.first(where: { $0.id != activeTabID }) {
                secondaryTabID = otherTab.id
            } else {
                secondaryTabID = activeTabID
            }
            focusedEditorPane = .secondary
            handlers(for: .secondary)?.focusEditor?()
            persistCurrentProjectSession()
        }
    }

    func closeSplitEditor() {
        isSplitEditorActive = false
        focusedEditorPane = .primary
        handlers(for: .primary)?.focusEditor?()
        persistCurrentProjectSession()
    }

    func openInSecondaryPane(tabID: UUID) {
        guard openTabs.contains(where: { $0.id == tabID }) else { return }
        isSplitEditorActive = true
        secondaryTabID = tabID
        focusedEditorPane = .secondary
        if let tab = openTabs.first(where: { $0.id == tabID }) {
            connectTabToLSP(tab)
        }
        refreshActiveDocumentSymbols()
        handlers(for: .secondary)?.focusEditor?()
        persistCurrentProjectSession()
    }

    func focusPane(_ pane: EditorPane) {
        guard isSplitEditorActive || pane == .primary else { return }
        if focusedEditorPane != pane {
            focusedEditorPane = pane
            if let tab = focusedTab {
                if let state = tabViewStates[tab.id] {
                    editorStatus.cursorLine = state.cursorLine
                    editorStatus.cursorColumn = state.cursorColumn
                }
                refreshTasksForCurrentContext()
                refreshActiveDocumentSymbols()
            }
        }
        handlers(for: pane)?.focusEditor?()
    }

    // MARK: - Session Persistence

    func persistCurrentProjectSession() {
        guard hasWorkspaceOpen else { return }
        let records: [PersistedTabRecord] = openTabs.compactMap { tab in
            guard tab.virtualKey == nil, let url = tab.url else { return nil }
            let state = tabViewStates[tab.id]
            return PersistedTabRecord(
                path: url.standardized.path,
                cursorLine: state?.cursorLine ?? 1,
                cursorColumn: state?.cursorColumn ?? 1,
                scrollOffsetY: state?.scrollOffsetY.map(Double.init)
            )
        }
        let session = PersistedProjectSession(
            projectPath: rootURL.standardized.path,
            openTabs: records,
            activeFilePath: activeTab?.url?.standardized.path,
            secondaryFilePath: secondaryTab?.url?.standardized.path,
            isSplitEditorActive: isSplitEditorActive,
            isSidebarVisible: isSidebarVisible,
            isTerminalVisible: isTerminalVisible,
            sidebarModeRaw: sidebarMode.rawValue,
            bottomPanelTabRaw: bottomPanelTab.rawValue,
            updatedAt: Date().timeIntervalSince1970
        )
        SessionPersistence.saveSession(session, userDefaults: userDefaults)
    }

    @discardableResult
    func restorePersistedSessionIfAvailable(for projectURL: URL) -> Bool {
        guard let persisted = SessionPersistence.loadSession(for: projectURL, userDefaults: userDefaults) else {
            return false
        }

        if let mode = SidebarMode(rawValue: persisted.sidebarModeRaw) {
            sidebarMode = mode
        }
        if let bTab = BottomPanelTab(rawValue: persisted.bottomPanelTabRaw) {
            bottomPanelTab = bTab
        }
        isSidebarVisible = persisted.isSidebarVisible
        isTerminalVisible = persisted.isTerminalVisible

        var restoredTabs: [EditorTab] = []
        var restoredViewStates: [UUID: TabViewState] = [:]
        let fm = FileManager.default

        for rec in persisted.openTabs {
            let fileURL = URL(fileURLWithPath: rec.path).standardized
            guard fm.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let content = Self.decodeTextFile(data) else {
                continue
            }
            let tab = EditorTab(
                id: UUID(),
                url: fileURL,
                title: fileURL.lastPathComponent,
                content: content,
                savedContent: content,
                language: CodeLanguage.detect(from: fileURL),
                pendingJumpLine: rec.cursorLine > 1 ? rec.cursorLine : nil,
                pendingJumpColumn: rec.cursorColumn > 1 ? rec.cursorColumn : nil
            )
            restoredTabs.append(tab)
            restoredViewStates[tab.id] = TabViewState(
                scrollOffsetY: rec.scrollOffsetY.map { CGFloat($0) },
                selectedRange: NSRange(location: 0, length: 0),
                cursorLine: rec.cursorLine,
                cursorColumn: rec.cursorColumn
            )
        }

        guard !restoredTabs.isEmpty else { return false }

        openTabs = restoredTabs
        tabViewStates = restoredViewStates

        if let activePath = persisted.activeFilePath,
           let matched = restoredTabs.first(where: { $0.url?.standardized.path == activePath }) {
            activeTabID = matched.id
        } else {
            activeTabID = restoredTabs.first?.id
        }

        if persisted.isSplitEditorActive,
           let secPath = persisted.secondaryFilePath,
           let matchedSec = restoredTabs.first(where: { $0.url?.standardized.path == secPath }) {
            isSplitEditorActive = true
            secondaryTabID = matchedSec.id
        } else {
            isSplitEditorActive = false
            secondaryTabID = nil
        }

        focusedEditorPane = .primary
        connectActiveTabToLSP()
        refreshTasksForCurrentContext()
        refreshActiveDocumentSymbols()
        return true
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
                persistCurrentProjectSession()
            }
            diagnosticsByFile.removeAll()
            referenceResults.removeAll()
            referenceTargetTitle = ""
            activeDocumentSymbols = []
            currentBreadcrumbSymbol = nil
            navigationHistory.clear()
            taskRunner.stop()
            rootURL = target

            if let snapshot = projectSessions[target.path] {
                openTabs = snapshot.openTabs
                activeTabID = snapshot.activeTabID
                secondaryTabID = snapshot.secondaryTabID
                isSplitEditorActive = snapshot.isSplitEditorActive
                focusedEditorPane = .primary
                tabViewStates = snapshot.tabViewStates
                reloadUnmodifiedOpenTabs()
            } else {
                openTabs.removeAll()
                activeTabID = nil
                secondaryTabID = nil
                isSplitEditorActive = false
                focusedEditorPane = .primary
                tabViewStates.removeAll()
                _ = restorePersistedSessionIfAvailable(for: target)
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
        startFileWatcher(for: target)

        if openTabs.isEmpty {
            openInitialFiles()
        } else {
            connectActiveTabToLSP()
            refreshActiveDocumentSymbols()
        }
        refreshTasksForCurrentContext()
        statusMessage = L10n("status.switchedToFormat", target.lastPathComponent)
        dismissOverlay()
    }

    private func saveProjectSessionSnapshot(forKey key: String) {
        projectSessions[key] = ProjectSessionSnapshot(
            openTabs: openTabs,
            activeTabID: activeTabID,
            secondaryTabID: secondaryTabID,
            isSplitEditorActive: isSplitEditorActive,
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
        resetExpansion: Bool = false,
        refreshGit: Bool = true
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

        if refreshGit {
            refreshGitMetadata()
        }
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
            openFile(url: candidate, recordHistory: false)
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
        if let tab = activeTab {
            connectTabToLSP(tab)
        }
        if isSplitEditorActive, let sec = secondaryTab, sec.id != activeTab?.id {
            connectTabToLSP(sec)
        }
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
        if secondaryTabID == id {
            if let fallback = openTabs.first(where: { $0.id != activeTabID }) ?? openTabs.first {
                secondaryTabID = fallback.id
            } else {
                secondaryTabID = nil
                isSplitEditorActive = false
                focusedEditorPane = .primary
            }
        }
        if openTabs.isEmpty {
            isSplitEditorActive = false
            focusedEditorPane = .primary
        }
        refreshTasksForCurrentContext()
        refreshActiveDocumentSymbols()
        persistCurrentProjectSession()
    }

    func closeOtherTabs(keeping id: UUID) {
        let toClose = openTabs.filter { $0.id != id }.map(\.id)
        for tabID in toClose {
            closeTab(id: tabID)
        }
    }

    func closeTabsToRight(of id: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == id }), idx + 1 < openTabs.count else { return }
        let toClose = openTabs[(idx + 1)...].map(\.id)
        for tabID in toClose {
            closeTab(id: tabID)
        }
    }

    func selectTab(id: UUID, in pane: EditorPane? = nil) {
        let targetPane = pane ?? (isSplitEditorActive ? focusedEditorPane : .primary)
        if targetPane == .secondary && isSplitEditorActive {
            if secondaryTabID != id {
                recordCurrentNavigationLocation()
            }
            secondaryTabID = id
            focusedEditorPane = .secondary
        } else {
            if activeTabID != id {
                recordCurrentNavigationLocation()
            }
            activeTabID = id
            focusedEditorPane = .primary
        }

        if let state = tabViewStates[id] {
            editorStatus.cursorLine = state.cursorLine
            editorStatus.cursorColumn = state.cursorColumn
        } else {
            editorStatus.cursorLine = 1
            editorStatus.cursorColumn = 1
        }
        refreshTasksForCurrentContext()
        if let tab = focusedTab {
            connectTabToLSP(tab)
        }
        refreshActiveDocumentSymbols()
        if findState.isFindBarVisible {
            recomputeFindMatches()
        }
        handlers(for: targetPane)?.focusEditor?()
        persistCurrentProjectSession()
    }

    func selectTabAtIndex(_ zeroBasedIndex: Int) {
        guard openTabs.indices.contains(zeroBasedIndex) else { return }
        selectTab(id: openTabs[zeroBasedIndex].id)
    }

    func selectAdjacentTab(delta: Int) {
        guard openTabs.count > 1, let currentID = focusedTabID,
              let idx = openTabs.firstIndex(where: { $0.id == currentID }) else { return }
        let nextIdx = (idx + delta + openTabs.count) % openTabs.count
        selectTab(id: openTabs[nextIdx].id)
    }

    func closeActiveTab() {
        if let targetID = focusedTabID {
            closeTab(id: targetID)
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

    func updateActiveTabContent(_ newContent: String) {
        guard let targetID = focusedTabID else { return }
        updateTabContent(tabID: targetID, newContent: newContent, sourcePane: focusedEditorPane)
    }

    /// Mutates buffer text in place via `TextBufferBox` so typing only publishes `@Published openTabs`
    /// when `isDirty` actually flips (0 SwiftUI full-window redraws per subsequent keystroke).
    func updateTabContent(tabID: UUID, newContent: String, sourcePane: EditorPane) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }

        let tab = openTabs[idx]
        guard tab.content != newContent else { return }

        let nowDirty = (tab.virtualKey == nil && newContent != tab.savedContent)
        if nowDirty != tab.isDirty {
            var updated = tab
            _ = updated.updateBufferContent(newContent)
            openTabs[idx] = updated
        } else {
            tab.content = newContent
        }

        // Mirror edits immediately to the sibling pane if both panes show the same file.
        if isSplitEditorActive {
            let otherPane: EditorPane = (sourcePane == .primary) ? .secondary : .primary
            let otherTabID = (otherPane == .primary) ? activeTabID : secondaryTabID
            if otherTabID == tabID {
                handlers(for: otherPane)?.syncBufferExternally?(tabID, newContent)
            }
        }

        if let url = tab.url, isProductionDefaults {
            LSPManager.shared.notifyDocumentChanged(
                url: url,
                language: tab.language,
                content: newContent,
                workspaceRoot: rootURL
            )
        }
        if findState.isFindBarVisible && tabID == focusedTabID {
            recomputeFindMatches()
        }
    }

    func updateTabCursor(tabID: UUID, line: Int, column: Int, range: NSRange, pane: EditorPane) {
        var state = tabViewStates[tabID] ?? TabViewState()
        state.cursorLine = line
        state.cursorColumn = column
        state.selectedRange = range
        tabViewStates[tabID] = state

        if pane == focusedEditorPane || !isSplitEditorActive {
            if editorStatus.cursorLine != line {
                editorStatus.cursorLine = line
                updateBreadcrumbSymbol(forLine: line)
            }
            if editorStatus.cursorColumn != column {
                editorStatus.cursorColumn = column
            }
        }
    }

    func updateActiveTabCursor(line: Int, column: Int, range: NSRange) {
        guard let targetID = focusedTabID else { return }
        updateTabCursor(tabID: targetID, line: line, column: column, range: range, pane: focusedEditorPane)
    }

    func updateTabScroll(tabID: UUID, y: CGFloat) {
        var state = tabViewStates[tabID] ?? TabViewState()
        state.scrollOffsetY = y
        tabViewStates[tabID] = state
    }

    func updateActiveTabScroll(y: CGFloat) {
        guard let targetID = focusedTabID else { return }
        updateTabScroll(tabID: targetID, y: y)
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

    // MARK: - Diagnostics, References, Symbols & Formatting

    func diagnostics(for tab: EditorTab?) -> [LSPDiagnostic] {
        guard let url = tab?.url else { return [] }
        return diagnosticsByFile[url.standardized.path] ?? []
    }

    var diagnosticsForActiveTab: [LSPDiagnostic] {
        diagnostics(for: focusedTab)
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

    func refreshActiveDocumentSymbols() {
        symbolsTask?.cancel()
        guard let tab = focusedTab, tab.virtualKey == nil else {
            activeDocumentSymbols = []
            currentBreadcrumbSymbol = nil
            return
        }

        let content = tab.content
        let language = tab.language
        let localSymbols = SymbolOutlineService.extractLocalSymbols(from: content, language: language)
        activeDocumentSymbols = localSymbols
        updateBreadcrumbSymbol(forLine: editorStatus.cursorLine)

        guard isProductionDefaults, let url = tab.url else { return }
        let root = rootURL
        let expectedTabID = tab.id

        symbolsTask = Task { [weak self] in
            let lspSymbols = await LSPManager.shared.requestDocumentSymbols(
                url: url,
                language: language,
                content: content,
                workspaceRoot: root
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.focusedTabID == expectedTabID else { return }
                if !lspSymbols.isEmpty {
                    self.activeDocumentSymbols = lspSymbols
                    self.updateBreadcrumbSymbol(forLine: self.editorStatus.cursorLine)
                }
            }
        }
    }

    func updateBreadcrumbSymbol(forLine line: Int) {
        currentBreadcrumbSymbol = SymbolOutlineService.activeSymbol(atLine: line, in: activeDocumentSymbols)
    }

    func findReferences(
        for tab: EditorTab,
        line: Int,
        character: Int,
        symbolName: String
    ) {
        guard let fileURL = tab.url else {
            statusMessage = L10n("lsp.references.notFound")
            return
        }

        referenceTargetTitle = symbolName.isEmpty ? fileURL.lastPathComponent : symbolName
        referenceResults = []
        isLoadingReferences = true
        showBottomPanel(.references)

        let content = tab.content
        let language = tab.language
        let root = rootURL

        Task { [weak self] in
            let locations = await LSPManager.shared.requestReferences(
                url: fileURL,
                language: language,
                content: content,
                line: line,
                character: character,
                workspaceRoot: root
            )
            let entries = await Task.detached(priority: .userInitiated) {
                Self.buildReferenceEntries(from: locations, workspaceRoot: root)
            }.value

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingReferences = false
                self.referenceResults = entries
                if entries.isEmpty {
                    self.statusMessage = L10n("lsp.references.notFound")
                } else {
                    self.statusMessage = L10n("lsp.references.foundCountFormat", entries.count)
                }
            }
        }
    }

    private nonisolated static func buildReferenceEntries(
        from locations: [LSPLocation],
        workspaceRoot: URL
    ) -> [WorkspaceReferenceEntry] {
        var fileLinesCache: [String: [String]] = [:]
        var entries: [WorkspaceReferenceEntry] = []
        var seen = Set<String>()
        let rootPath = workspaceRoot.standardized.path

        for loc in locations {
            guard let url = URL(string: loc.uri)?.standardized, url.isFileURL else { continue }
            let path = url.path
            let lineIdx = max(0, loc.range.start.line)
            let colIdx = max(0, loc.range.start.character)
            let dedupeKey = "\(path):\(lineIdx):\(colIdx)"
            guard seen.insert(dedupeKey).inserted else { continue }

            let lines: [String]
            if let cached = fileLinesCache[path] {
                lines = cached
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                let split = text.components(separatedBy: "\n")
                fileLinesCache[path] = split
                lines = split
            } else {
                lines = []
            }

            let preview = lineIdx < lines.count
                ? lines[lineIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let relPath = path.hasPrefix(rootPath + "/")
                ? String(path.dropFirst(rootPath.count + 1))
                : url.lastPathComponent

            entries.append(WorkspaceReferenceEntry(
                fileURL: url,
                relativePath: relPath,
                line: lineIdx + 1,
                column: colIdx + 1,
                preview: preview
            ))
        }
        return entries
    }

    func formatActiveDocument(onFinished: (() -> Void)? = nil) {
        guard let tab = focusedTab, tab.virtualKey == nil else {
            onFinished?()
            return
        }
        let tabID = tab.id
        let originalContent = tab.content
        let language = tab.language
        let root = rootURL

        guard let url = tab.url else {
            if let fallback = SymbolOutlineService.fallbackFormatDocument(content: originalContent, language: language),
               fallback != originalContent {
                applyFormattedText(fallback, toTabID: tabID)
                statusMessage = L10n("status.formattedFormat", tab.title)
            } else {
                statusMessage = L10n("lsp.format.unavailable")
            }
            onFinished?()
            return
        }

        Task { [weak self] in
            var formattedText: String? = nil
            if let edits = await LSPManager.shared.requestFormatting(
                url: url,
                language: language,
                content: originalContent,
                workspaceRoot: root
            ), !edits.isEmpty {
                formattedText = LSPPayloadParser.applyTextEdits(edits, to: originalContent)
            } else {
                formattedText = SymbolOutlineService.fallbackFormatDocument(content: originalContent, language: language)
            }

            await MainActor.run { [weak self] in
                guard let self else {
                    onFinished?()
                    return
                }
                if let formattedText, formattedText != originalContent {
                    // Only apply if buffer wasn't edited concurrently while awaiting LSP.
                    if let current = self.openTabs.first(where: { $0.id == tabID }), current.content == originalContent {
                        self.applyFormattedText(formattedText, toTabID: tabID)
                        self.statusMessage = L10n("status.formattedFormat", current.title)
                    }
                } else if formattedText == originalContent {
                    self.statusMessage = L10n("status.alreadyFormatted")
                } else {
                    self.statusMessage = L10n("lsp.format.unavailable")
                }
                onFinished?()
            }
        }
    }

    private func applyFormattedText(_ newText: String, toTabID tabID: UUID) {
        if tabID == focusedTabID, let replaceAll = onReplaceAllTextInActiveEditor {
            replaceAll(newText)
        } else if let idx = openTabs.firstIndex(where: { $0.id == tabID }) {
            _ = openTabs[idx].updateBufferContent(newText)
            openTabs[idx].externalReloadRevision += 1
        }
    }

    func showBottomPanel(_ tab: BottomPanelTab) {
        bottomPanelTab = tab
        onShowBottomPanelAction?(tab)
    }

    func refreshTasksForCurrentContext() {
        taskRunner.refreshTasks(in: rootURL, activeFileURL: focusedTab?.url, hasWorkspaceOpen: hasWorkspaceOpen)
    }

    func runTask(_ task: ProjectTask) {
        guard hasWorkspaceOpen else { return }
        if focusedTab?.isDirty == true {
            _ = saveActiveTab()
        }
        showBottomPanel(.run)
        taskRunner.run(task: task, in: rootURL)
    }

    func runDefaultRunTask() {
        guard hasWorkspaceOpen else { return }
        refreshTasksForCurrentContext()
        if focusedTab?.isDirty == true {
            _ = saveActiveTab()
        }
        showBottomPanel(.run)
        taskRunner.runDefault(kind: .run, in: rootURL, activeFileURL: focusedTab?.url)
    }

    func runDefaultTestTask() {
        guard hasWorkspaceOpen else { return }
        refreshTasksForCurrentContext()
        if focusedTab?.isDirty == true {
            _ = saveActiveTab()
        }
        showBottomPanel(.run)
        taskRunner.runDefault(kind: .test, in: rootURL, activeFileURL: focusedTab?.url)
    }

    func stopRunningTask() {
        taskRunner.stop()
    }
}
