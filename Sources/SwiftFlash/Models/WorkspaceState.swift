import AppKit
import Combine
import Foundation

// MARK: - Language Definition

enum CodeLanguage: String, CaseIterable, Identifiable {
    case swift = "Swift"
    case rust = "Rust"
    case python = "Python"
    case typescript = "TypeScript"
    case javascript = "JavaScript"
    case json = "JSON"
    case markdown = "Markdown"
    case shell = "Shell"
    case c = "C/C++"
    case yaml = "YAML"
    case toml = "TOML"
    case html = "HTML"
    case css = "CSS"
    case diff = "Diff"
    case plainText = "Plain Text"

    var id: String { rawValue }

    var lineCommentPrefix: String? {
        switch self {
        case .swift, .rust, .typescript, .javascript, .c, .css:
            return "//"
        case .python, .shell, .yaml, .toml:
            return "#"
        case .html:
            return "<!--"
        case .json, .markdown, .diff, .plainText:
            return nil
        }
    }

    var iconName: String {
        switch self {
        case .swift: return "swift"
        case .rust: return "gearshape.2"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .typescript, .javascript: return "curlybraces"
        case .json: return "curlybraces.square"
        case .markdown: return "doc.richtext"
        case .shell: return "terminal"
        case .c: return "cpu"
        case .yaml, .toml: return "list.bullet.rectangle"
        case .html, .css: return "globe"
        case .diff: return "plusminus"
        case .plainText: return "doc.text"
        }
    }

    var iconColor: NSColor {
        switch self {
        case .swift: return NSColor(hex: 0xF05138)
        case .rust: return NSColor(hex: 0xDEA584)
        case .python: return NSColor(hex: 0x3572A5)
        case .typescript: return NSColor(hex: 0x3178C6)
        case .javascript: return NSColor(hex: 0xF7DF1E)
        case .json: return NSColor(hex: 0xE5C07B)
        case .markdown: return NSColor(hex: 0x61AFEF)
        case .shell: return NSColor(hex: 0x98C379)
        case .c: return NSColor(hex: 0x56B6C2)
        case .yaml, .toml: return NSColor(hex: 0xC678DD)
        case .html: return NSColor(hex: 0xE06C75)
        case .css: return NSColor(hex: 0x61AFEF)
        case .diff: return NSColor(hex: 0x56B6C2)
        case .plainText: return NSColor(hex: 0x8A9199)
        }
    }

    static func detect(from url: URL) -> CodeLanguage {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if name == "package.swift" || ext == "swift" { return .swift }
        switch ext {
        case "rs": return .rust
        case "py", "pyi": return .python
        case "ts", "tsx", "mts": return .typescript
        case "js", "jsx", "mjs": return .javascript
        case "json", "jsonc": return .json
        case "md", "markdown": return .markdown
        case "sh", "zsh", "bash": return .shell
        case "c", "h", "cpp", "hpp", "cc", "m", "mm": return .c
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "html", "htm", "xml", "plist": return .html
        case "css", "scss": return .css
        case "diff", "patch": return .diff
        default: return .plainText
        }
    }
}

// MARK: - File Tree & Search Models

final class FileItem: Identifiable, ObservableObject {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let language: CodeLanguage
    @Published var isExpanded: Bool = false
    @Published var children: [FileItem]? = nil

    static let ignoredNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", ".DS_Store",
        "DerivedData", "__pycache__", ".pytest_cache", "target", ".vscode", ".idea"
    ]

    init(url: URL, isDirectory: Bool) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.language = isDirectory ? .plainText : CodeLanguage.detect(from: url)
    }

    func loadChildrenIfNeeded() {
        guard isDirectory, children == nil else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            children = []
            return
        }

        var items: [FileItem] = []
        for childURL in urls {
            let name = childURL.lastPathComponent
            if Self.ignoredNames.contains(name) { continue }
            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            items.append(FileItem(url: childURL, isDirectory: isDir))
        }

        items.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        children = items
    }
}

struct EditorTab: Identifiable, Equatable {
    let id: UUID
    var url: URL?
    var virtualKey: String? = nil
    var title: String
    var content: String
    var savedContent: String
    var language: CodeLanguage
    var cursorLine: Int = 1
    var cursorColumn: Int = 1
    var selectedRange: NSRange = NSRange(location: 0, length: 0)
    var scrollOffsetY: CGFloat = 0
    var lastLoadTimeMs: Double = 0.0
    var pendingJumpLine: Int?
    var externalReloadRevision: Int = 0

    var isDirty: Bool {
        virtualKey == nil && content != savedContent
    }

    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool {
        lhs.id == rhs.id
            && lhs.externalReloadRevision == rhs.externalReloadRevision
            && lhs.pendingJumpLine == rhs.pendingJumpLine
    }
}

struct SearchMatch: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let relativePath: String
    let lineNumber: Int
    let linePreview: String
}

enum SidebarMode: String, CaseIterable {
    case explorer = "Explorer"
    case git = "Git"
    case search = "Search"
}

enum GitPanelTab: String, CaseIterable {
    case changes = "Changes"
    case history = "History"

    @MainActor
    var localizedTitle: String {
        switch self {
        case .changes: return L10n("git.tab.changes")
        case .history: return L10n("git.tab.history")
        }
    }
}

enum GitChangeFilter: String, CaseIterable {
    case all = "Uncommitted"
    case staged = "Staged"
    case unstaged = "Unstaged"
    case untracked = "Untracked"

    @MainActor
    var localizedTitle: String {
        switch self {
        case .all: return L10n("git.filter.all")
        case .staged: return L10n("git.filter.staged")
        case .unstaged: return L10n("git.filter.unstaged")
        case .untracked: return L10n("git.filter.untracked")
        }
    }
}

enum GitCommitActionMode: String, CaseIterable {
    case commitTracked = "Commit Tracked"
    case commitStaged = "Commit Staged"
    case commitAll = "Commit All"
    case amend = "Commit Amend"

    @MainActor
    var localizedTitle: String {
        switch self {
        case .commitTracked: return L10n("git.commitMode.tracked")
        case .commitStaged: return L10n("git.commitMode.staged")
        case .commitAll: return L10n("git.commitMode.all")
        case .amend: return L10n("git.commitMode.amend")
        }
    }
}

struct GitChangedFileItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let relativePath: String
    let fileName: String
    let indexStatus: String
    let worktreeStatus: String
    let isStaged: Bool
    let hasUnstagedChanges: Bool
    let isUntracked: Bool
    let displayStatus: String
}

struct GitCommitLogItem: Identifiable, Equatable {
    let id: String
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let relativeDate: String
}

enum OverlayPanelMode: Equatable {
    case none
    case projectSwitcher
    case worktreeSwitcher
    case branchSwitcher
    case quickOpen
    case settings
}

struct ProjectSessionSnapshot {
    var openTabs: [EditorTab]
    var activeTabID: UUID?
}

struct GitWorktreeItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let name: String
    let branch: String
    let commitShort: String
    let isCurrent: Bool
    let isDetached: Bool
}

struct GitBranchItem: Identifiable, Equatable {
    let id: String
    let name: String
    let isCurrent: Bool
    let isCheckedOutElsewhere: Bool
    let isRemote: Bool
    let commitShort: String
}

// MARK: - NSColor Hex Helper

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - WorkspaceState

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

    var isQuickOpenVisible: Bool {
        get { activeOverlay == .quickOpen }
        set { activeOverlay = newValue ? .quickOpen : .none }
    }

    // Project Switcher & Session Snapshots
    @Published var windowProjects: [URL] = []
    @Published var recentProjects: [URL] = []
    private var projectSessions: [String: ProjectSessionSnapshot] = [:]

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
    private var gitRepoTopLevel: URL?

    @Published var searchQuery: String = ""
    @Published var searchResults: [SearchMatch] = []
    @Published var isSearching: Bool = false
    @Published var statusMessage: String = L10n("status.ready")
    @Published var lastRenderLatencyMs: Double = 0.0

    // Callbacks handled by Editor Controller
    var onToggleCommentRequested: (() -> Void)?
    var onJumpToLineRequested: ((Int) -> Void)?
    var onFocusEditorRequested: (() -> Void)?
    var onSaveSuccessFlash: (() -> Void)?
    var onToggleSidebarAction: (() -> Void)?
    var onSelectSidebarModeAction: ((SidebarMode) -> Void)?
    var onToggleTerminalAction: (() -> Void)?

    private var fileIndexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var gitMetadataTask: Task<Void, Never>?
    private var hasLoadedWorkspaceTree = false

    private let userDefaults: UserDefaults

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
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.standardized.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Overlay Control

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

    func setRootURL(_ url: URL) {
        switchProject(to: url)
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
                projectSessions[currentKey] = ProjectSessionSnapshot(
                    openTabs: openTabs,
                    activeTabID: activeTabID
                )
            }
            rootURL = target

            if let snapshot = projectSessions[target.path] {
                openTabs = snapshot.openTabs
                activeTabID = snapshot.activeTabID
            } else {
                openTabs.removeAll()
                activeTabID = nil
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
        }
        statusMessage = L10n("status.switchedToFormat", target.lastPathComponent)
        dismissOverlay()
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

    private func recordRecentProject(_ url: URL) {
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

        detectGitBranch()
        rebuildFileIndex()
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
            await MainActor.run { [weak self] in
                self?.allWorkspaceFiles = indexed
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

    // MARK: - Git Worktree, Branch & Source Control Management

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
    }

    var filteredGitChanges: [GitChangedFileItem] {
        switch gitChangeFilter {
        case .all:
            return gitChanges
        case .staged:
            return gitChanges.filter { $0.isStaged }
        case .unstaged:
            return gitChanges.filter { $0.hasUnstagedChanges && !$0.isUntracked }
        case .untracked:
            return gitChanges.filter { $0.isUntracked }
        }
    }

    func detectGitBranch() {
        refreshGitMetadata()
    }

    func refreshGitMetadata() {
        gitMetadataTask?.cancel()
        let root = rootURL.standardized
        gitMetadataTask = Task.detached(priority: .utility) {
            let isRepoRes = Self.runGit(["rev-parse", "--is-inside-work-tree"], in: root)
            guard isRepoRes.exitCode == 0,
                  isRepoRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                await MainActor.run { [weak self] in
                    guard let self, self.rootURL.standardized.path == root.path else { return }
                    self.isGitRepository = false
                    self.gitRepoTopLevel = nil
                    self.gitBranch = "no-git"
                    self.currentWorktreeName = root.lastPathComponent
                    self.gitWorktrees = []
                    self.gitBranches = []
                    self.gitChanges = []
                    self.gitCommitHistory = []
                    self.lastCommitSubject = ""
                    self.lastCommitShortHash = ""
                    self.gitAheadCount = 0
                    self.gitBehindCount = 0
                }
                return
            }

            let topLevelRes = Self.runGit(["rev-parse", "--show-toplevel"], in: root)
            let repoTopLevel = topLevelRes.exitCode == 0
                ? URL(fileURLWithPath: topLevelRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().standardized
                : root.resolvingSymlinksInPath().standardized

            let headBranchRes = Self.runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: root)
            var currentBranch = headBranchRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentBranch == "HEAD" || currentBranch.isEmpty {
                let shaRes = Self.runGit(["rev-parse", "--short", "HEAD"], in: root)
                let sha = shaRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                currentBranch = sha.isEmpty ? "HEAD" : sha
            }

            let worktreeRes = Self.runGit(["worktree", "list", "--porcelain"], in: root)
            let worktrees = Self.parseWorktrees(
                worktreeRes.stdout,
                currentRepoPath: repoTopLevel.path
            )

            let branchRes = Self.runGit(
                ["branch", "-a", "--format=%(refname)|%(refname:short)|%(HEAD)|%(objectname:short)"],
                in: root
            )
            let branches = Self.parseBranches(branchRes.stdout)

            let statusRes = Self.runGit(
                ["-c", "core.quotepath=false", "status", "--porcelain=v1", "-uall"],
                in: repoTopLevel
            )
            let changes = Self.parseGitStatus(statusRes.stdout, repoTopLevel: repoTopLevel)

            let lastCommitRes = Self.runGit(["log", "-1", "--pretty=format:%h%x1f%s"], in: repoTopLevel)
            var lastShort = ""
            var lastSubject = ""
            if lastCommitRes.exitCode == 0 {
                let parts = lastCommitRes.stdout.components(separatedBy: "\u{1F}")
                if parts.count >= 2 {
                    lastShort = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    lastSubject = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            let historyRes = Self.runGit(
                ["log", "-n", "40", "--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%ar"],
                in: repoTopLevel
            )
            let history = historyRes.exitCode == 0 ? Self.parseCommitHistory(historyRes.stdout) : []

            var ahead = 0
            var behind = 0
            let revListRes = Self.runGit(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: repoTopLevel)
            if revListRes.exitCode == 0 {
                let counts = revListRes.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0.isWhitespace })
                if counts.count >= 2 {
                    ahead = Int(counts[0]) ?? 0
                    behind = Int(counts[1]) ?? 0
                }
            }

            let resolvedWorktreeName: String = {
                if let activeWT = worktrees.first(where: { $0.isCurrent }) {
                    if worktrees.first?.id == activeWT.id {
                        return activeWT.branch.isEmpty ? activeWT.name : activeWT.branch
                    }
                    return activeWT.name
                }
                return currentBranch
            }()

            let resolvedBranch = currentBranch
            let resolvedLastShort = lastShort
            let resolvedLastSubject = lastSubject
            let resolvedAhead = ahead
            let resolvedBehind = behind
            await MainActor.run { [weak self] in
                guard let self, self.rootURL.standardized.path == root.path else { return }
                self.isGitRepository = true
                self.gitRepoTopLevel = repoTopLevel
                self.gitBranch = resolvedBranch
                self.currentWorktreeName = resolvedWorktreeName
                self.gitWorktrees = worktrees
                self.gitBranches = branches
                self.gitChanges = changes
                self.gitCommitHistory = history
                self.lastCommitShortHash = resolvedLastShort
                self.lastCommitSubject = resolvedLastSubject
                self.gitAheadCount = resolvedAhead
                self.gitBehindCount = resolvedBehind
            }
        }
    }

    func switchWorktree(to item: GitWorktreeItem) {
        switchProject(to: item.url)
        statusMessage = L10n("status.worktreeSwitchedFormat", item.name, item.branch)
    }

    func createAndSwitchWorktree(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty, isGitRepository else { return }

        let sanitizedDirSuffix = name.replacingOccurrences(of: "/", with: "-")
        let baseRepoDir = gitWorktrees.first?.url ?? rootURL
        let targetURL = baseRepoDir.deletingLastPathComponent()
            .appendingPathComponent("\(baseRepoDir.lastPathComponent)-\(sanitizedDirSuffix)")
            .standardized

        if FileManager.default.fileExists(atPath: targetURL.path) {
            switchProject(to: targetURL)
            statusMessage = L10n("status.openedWorktreeFormat", targetURL.lastPathComponent)
            return
        }

        let currentRoot = rootURL
        let hasLocalBranch = gitBranches.contains { !$0.isRemote && $0.name == name }
        isGitOperationInProgress = true

        Task.detached(priority: .userInitiated) {
            let args: [String] = hasLocalBranch
                ? ["worktree", "add", targetURL.path, name]
                : ["worktree", "add", "-b", name, targetURL.path]
            let res = Self.runGit(args, in: currentRoot)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if res.exitCode == 0 {
                    self.switchProject(to: targetURL)
                    self.statusMessage = L10n("status.createdWorktreeFormat", targetURL.lastPathComponent, name)
                } else {
                    let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = msg.isEmpty ? L10n("status.failedWorktree") : msg
                }
            }
        }
    }

    func switchGitBranch(to branchName: String, createNew: Bool = false, isRemote: Bool = false) {
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isGitRepository else { return }

        let currentRoot = rootURL
        isGitOperationInProgress = true

        Task.detached(priority: .userInitiated) {
            let args: [String]
            if createNew {
                args = ["checkout", "-b", trimmed]
            } else if isRemote {
                let localCandidate = trimmed.split(separator: "/", maxSplits: 1).last.map(String.init) ?? trimmed
                let checkLocal = Self.runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(localCandidate)"], in: currentRoot)
                if checkLocal.exitCode == 0 {
                    args = ["checkout", localCandidate]
                } else {
                    args = ["checkout", "--track", trimmed]
                }
            } else {
                args = ["checkout", trimmed]
            }

            let res = Self.runGit(args, in: currentRoot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if res.exitCode == 0 {
                    self.reloadWorkspace()
                    self.reloadUnmodifiedOpenTabs()
                    self.statusMessage = L10n("status.switchedBranchFormat", trimmed)
                    self.dismissOverlay()
                } else {
                    let errMsg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = errMsg.isEmpty ? L10n("status.gitCheckoutFailed") : errMsg
                }
            }
        }
    }

    func initializeGitRepository() {
        let currentRoot = rootURL
        isGitOperationInProgress = true
        Task.detached(priority: .userInitiated) {
            let res = Self.runGit(["init"], in: currentRoot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if res.exitCode == 0 {
                    self.refreshGitMetadata()
                    self.statusMessage = L10n("status.initializedGitFormat", currentRoot.lastPathComponent)
                } else {
                    self.statusMessage = L10n("status.gitInitFailedFormat", res.stderr)
                }
            }
        }
    }

    func stageGitFile(_ item: GitChangedFileItem) {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        runGitMutation(["add", "--", item.relativePath], in: repoDir, successMessage: L10n("status.stagedFileFormat", item.fileName))
    }

    func unstageGitFile(_ item: GitChangedFileItem) {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let hasHead = !lastCommitShortHash.isEmpty
        let args = hasHead
            ? ["reset", "-q", "HEAD", "--", item.relativePath]
            : ["rm", "--cached", "-q", "--", item.relativePath]
        runGitMutation(args, in: repoDir, successMessage: L10n("status.unstagedFileFormat", item.fileName))
    }

    func toggleStageGitFile(_ item: GitChangedFileItem) {
        if item.isStaged && !item.hasUnstagedChanges {
            unstageGitFile(item)
        } else {
            stageGitFile(item)
        }
    }

    func stageAllGitChanges(trackedOnly: Bool = false) {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let args = trackedOnly ? ["add", "-u"] : ["add", "-A"]
        let msg = trackedOnly ? L10n("status.stagedAllTracked") : L10n("status.stagedAll")
        runGitMutation(args, in: repoDir, successMessage: msg)
    }

    func unstageAllGitChanges() {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let hasHead = !lastCommitShortHash.isEmpty
        let args = hasHead ? ["reset", "-q", "HEAD"] : ["rm", "-r", "--cached", "-q", "."]
        runGitMutation(args, in: repoDir, successMessage: L10n("status.unstagedAll"))
    }

    func discardGitFileChanges(_ item: GitChangedFileItem) {
        guard isGitRepository else { return }
        let alert = NSAlert()
        alert.messageText = L10n("alert.discardFile.titleFormat", item.fileName)
        alert.informativeText = item.isUntracked
            ? L10n("alert.discardFile.untrackedMsg")
            : L10n("alert.discardFile.modifiedMsg")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n("common.discard"))
        alert.addButton(withTitle: L10n("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let repoDir = gitRepoTopLevel ?? rootURL
        isGitOperationInProgress = true
        Task.detached(priority: .userInitiated) {
            let res: (exitCode: Int32, stdout: String, stderr: String)
            if item.isUntracked {
                res = Self.runGit(["clean", "-fd", "--", item.relativePath], in: repoDir)
            } else if item.indexStatus == "A" {
                res = Self.runGit(["rm", "-f", "--", item.relativePath], in: repoDir)
            } else {
                if item.isStaged {
                    _ = Self.runGit(["reset", "-q", "HEAD", "--", item.relativePath], in: repoDir)
                }
                res = Self.runGit(["checkout", "--", item.relativePath], in: repoDir)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if res.exitCode == 0 {
                    self.reloadWorkspace()
                    self.reloadUnmodifiedOpenTabs()
                    self.statusMessage = L10n("status.discardedFileFormat", item.fileName)
                } else {
                    let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = msg.isEmpty ? L10n("status.failedDiscardFileFormat", item.fileName) : msg
                }
            }
        }
    }

    func discardAllUnstagedGitChanges() {
        guard isGitRepository else { return }
        let alert = NSAlert()
        alert.messageText = L10n("alert.discardAll.title")
        alert.informativeText = L10n("alert.discardAll.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n("common.discardAll"))
        alert.addButton(withTitle: L10n("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let repoDir = gitRepoTopLevel ?? rootURL
        isGitOperationInProgress = true
        Task.detached(priority: .userInitiated) {
            let checkoutRes = Self.runGit(["checkout", "--", "."], in: repoDir)
            let cleanRes = Self.runGit(["clean", "-fd"], in: repoDir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if checkoutRes.exitCode == 0 && cleanRes.exitCode == 0 {
                    self.reloadWorkspace()
                    self.reloadUnmodifiedOpenTabs()
                    self.statusMessage = L10n("status.discardedAll")
                } else {
                    let msg = (checkoutRes.stderr + " " + cleanRes.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = msg.isEmpty ? L10n("status.failedDiscardAll") : msg
                }
            }
        }
    }

    func commitGitChanges() {
        guard isGitRepository else { return }
        let msg = gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty && gitCommitActionMode != .amend {
            statusMessage = L10n("status.enterCommitMessage")
            return
        }

        let repoDir = gitRepoTopLevel ?? rootURL
        let mode = gitCommitActionMode
        isGitOperationInProgress = true

        Task.detached(priority: .userInitiated) {
            let res: (exitCode: Int32, stdout: String, stderr: String)
            switch mode {
            case .commitTracked:
                res = Self.runGit(["commit", "-a", "-m", msg], in: repoDir)
            case .commitStaged:
                res = Self.runGit(["commit", "-m", msg], in: repoDir)
            case .commitAll:
                let addRes = Self.runGit(["add", "-A"], in: repoDir)
                if addRes.exitCode != 0 {
                    res = addRes
                } else {
                    res = Self.runGit(["commit", "-m", msg], in: repoDir)
                }
            case .amend:
                if msg.isEmpty {
                    res = Self.runGit(["commit", "--amend", "--no-edit"], in: repoDir)
                } else {
                    res = Self.runGit(["commit", "--amend", "-m", msg], in: repoDir)
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if res.exitCode == 0 {
                    self.gitCommitMessage = ""
                    self.reloadWorkspace()
                    let summary = msg.components(separatedBy: .newlines).first ?? mode.rawValue
                    self.statusMessage = L10n("status.committedFormat", summary.isEmpty ? L10n("status.amended") : summary)
                } else {
                    let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let out = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let combined = !err.isEmpty ? err : out
                    self.statusMessage = combined.isEmpty ? L10n("status.commitFailed") : combined
                }
            }
        }
    }

    func uncommitLastGitCommit() {
        guard isGitRepository, !lastCommitShortHash.isEmpty else {
            statusMessage = L10n("status.noCommitToUndo")
            return
        }

        let repoDir = gitRepoTopLevel ?? rootURL
        isGitOperationInProgress = true

        Task.detached(priority: .userInitiated) {
            let prevMsgRes = Self.runGit(["log", "-1", "--pretty=format:%B"], in: repoDir)
            let prevMessage = prevMsgRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let hasParent = Self.runGit(["rev-parse", "--verify", "--quiet", "HEAD~1"], in: repoDir).exitCode == 0
            let resetRes = hasParent
                ? Self.runGit(["reset", "--soft", "HEAD~1"], in: repoDir)
                : Self.runGit(["update-ref", "-d", "HEAD"], in: repoDir)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if resetRes.exitCode == 0 {
                    if self.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prevMessage.isEmpty {
                        self.gitCommitMessage = prevMessage
                    }
                    self.refreshGitMetadata()
                    self.statusMessage = L10n("status.uncommittedLast")
                } else {
                    let err = resetRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = err.isEmpty ? L10n("status.failedUndoCommit") : err
                }
            }
        }
    }

    func generateDraftCommitMessage() {
        let stagedItems = gitChanges.filter { $0.isStaged }
        let targetItems = stagedItems.isEmpty ? gitChanges : stagedItems
        guard !targetItems.isEmpty else {
            statusMessage = L10n("status.noChangesForDraft")
            return
        }

        if targetItems.count == 1, let only = targetItems.first {
            let verb: String
            let prefix: String
            if only.isUntracked || only.indexStatus == "A" {
                prefix = "feat"
                verb = "add"
            } else if only.displayStatus == "D" {
                prefix = "chore"
                verb = "remove"
            } else {
                prefix = "chore"
                verb = "update"
            }
            gitCommitMessage = "\(prefix): \(verb) \(only.fileName)"
        } else {
            let names = targetItems.prefix(2).map(\.fileName).joined(separator: ", ")
            let suffix = targetItems.count > 2 ? " and \(targetItems.count - 2) more files" : ""
            let details = targetItems.prefix(8).map { "- \($0.displayStatus): \($0.relativePath)" }.joined(separator: "\n")
            gitCommitMessage = "chore: update \(names)\(suffix)\n\n\(details)"
        }
        statusMessage = L10n("status.generatedDraft")
    }

    func performGitRemoteAction(_ action: String) {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let normalized = action.lowercased()
        let args: [String]
        switch normalized {
        case "fetch":
            args = ["fetch", "--prune"]
        case "pull":
            args = ["pull"]
        case "push":
            args = ["push"]
        default:
            return
        }

        isGitOperationInProgress = true
        statusMessage = L10n("status.runningGitFormat", normalized)

        Task.detached(priority: .userInitiated) {
            let res = Self.runGit(args, in: repoDir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if res.exitCode == 0 {
                    if normalized == "pull" {
                        self.reloadWorkspace()
                        self.reloadUnmodifiedOpenTabs()
                    } else {
                        self.refreshGitMetadata()
                    }
                    self.statusMessage = L10n("status.gitCompletedFormat", normalized)
                } else {
                    let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = err.isEmpty ? L10n("status.gitFailedFormat", normalized) : err
                }
            }
        }
    }

    func openGitDiffInEditor(for item: GitChangedFileItem? = nil) {
        guard isGitRepository else {
            statusMessage = L10n("git.notARepo.title")
            return
        }

        let repoDir = gitRepoTopLevel ?? rootURL
        let hasHead = !lastCommitShortHash.isEmpty
        let snapshotChanges = gitChanges

        Task.detached(priority: .userInitiated) {
            var diffChunks: [String] = []
            if let item {
                if item.isUntracked {
                    let res = Self.runGit(["diff", "--no-index", "--", "/dev/null", item.relativePath], in: repoDir)
                    if !res.stdout.isEmpty { diffChunks.append(res.stdout) }
                } else if hasHead {
                    let res = Self.runGit(["diff", "HEAD", "--", item.relativePath], in: repoDir)
                    if !res.stdout.isEmpty { diffChunks.append(res.stdout) }
                } else {
                    let staged = Self.runGit(["diff", "--cached", "--", item.relativePath], in: repoDir)
                    let unstaged = Self.runGit(["diff", "--", item.relativePath], in: repoDir)
                    if !staged.stdout.isEmpty { diffChunks.append(staged.stdout) }
                    if !unstaged.stdout.isEmpty { diffChunks.append(unstaged.stdout) }
                }
            } else {
                if hasHead {
                    let res = Self.runGit(["diff", "HEAD"], in: repoDir)
                    if !res.stdout.isEmpty { diffChunks.append(res.stdout) }
                } else {
                    let staged = Self.runGit(["diff", "--cached"], in: repoDir)
                    let unstaged = Self.runGit(["diff"], in: repoDir)
                    if !staged.stdout.isEmpty { diffChunks.append(staged.stdout) }
                    if !unstaged.stdout.isEmpty { diffChunks.append(unstaged.stdout) }
                }

                for untracked in snapshotChanges where untracked.isUntracked {
                    let res = Self.runGit(["diff", "--no-index", "--", "/dev/null", untracked.relativePath], in: repoDir)
                    if !res.stdout.isEmpty { diffChunks.append(res.stdout) }
                }
            }

            let combined = diffChunks.joined(separator: "\n")
            await MainActor.run { [weak self] in
                guard let self else { return }
                if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.statusMessage = item == nil ? L10n("status.noUncommittedDiff") : L10n("status.noFileDiffFormat", item!.fileName)
                    return
                }
                let key = item.map { "diff:\($0.relativePath)" } ?? "diff:uncommitted"
                let title = item.map { "Diff: \($0.fileName)" } ?? "Git Diff"
                self.openVirtualDiffTab(key: key, title: title, content: combined)
            }
        }
    }

    func openGitCommitDiffInEditor(commitHash: String, shortHash: String) {
        guard isGitRepository, !commitHash.isEmpty else { return }
        let repoDir = gitRepoTopLevel ?? rootURL

        Task.detached(priority: .userInitiated) {
            let res = Self.runGit(["show", "--stat", "--patch", commitHash], in: repoDir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if res.exitCode == 0, !res.stdout.isEmpty {
                    self.openVirtualDiffTab(
                        key: "commit:\(commitHash)",
                        title: "Commit \(shortHash)",
                        content: res.stdout
                    )
                } else {
                    let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = err.isEmpty ? L10n("status.failedLoadCommitFormat", shortHash) : err
                }
            }
        }
    }

    private func openVirtualDiffTab(key: String, title: String, content: String) {
        let displayContent = content.isEmpty ? "# No diff output\n" : content
        if let existingIdx = openTabs.firstIndex(where: { $0.virtualKey == key }) {
            openTabs[existingIdx].title = title
            openTabs[existingIdx].content = displayContent
            openTabs[existingIdx].savedContent = displayContent
            openTabs[existingIdx].language = .diff
            openTabs[existingIdx].externalReloadRevision += 1
            activeTabID = openTabs[existingIdx].id
        } else {
            let tab = EditorTab(
                id: UUID(),
                url: nil,
                virtualKey: key,
                title: title,
                content: displayContent,
                savedContent: displayContent,
                language: .diff
            )
            openTabs.append(tab)
            activeTabID = tab.id
        }
        statusMessage = title
        onFocusEditorRequested?()
    }

    private func runGitMutation(_ arguments: [String], in repoDir: URL, successMessage: String) {
        isGitOperationInProgress = true
        Task.detached(priority: .userInitiated) {
            let res = Self.runGit(arguments, in: repoDir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitOperationInProgress = false
                if res.exitCode == 0 {
                    self.refreshGitMetadata()
                    self.statusMessage = successMessage
                } else {
                    let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = err.isEmpty ? L10n("status.gitOpFailed") : err
                }
            }
        }
    }

    private func reloadUnmodifiedOpenTabs() {
        for idx in openTabs.indices {
            guard !openTabs[idx].isDirty, let url = openTabs[idx].url else { continue }
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                if openTabs[idx].content != text {
                    openTabs[idx].content = text
                    openTabs[idx].savedContent = text
                    openTabs[idx].externalReloadRevision += 1
                }
            }
        }
    }

    private nonisolated static func runGit(_ arguments: [String], in directory: URL) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }

    private nonisolated static func parseWorktrees(_ output: String, currentRepoPath: String) -> [GitWorktreeItem] {
        var items: [GitWorktreeItem] = []
        let blocks = output.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !lines.isEmpty else { continue }

            var path: String?
            var head = ""
            var branch = ""
            var isDetached = false

            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count).prefix(7))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                } else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst("branch ".count))
                } else if line == "detached" {
                    isDetached = true
                }
            }

            guard let path else { continue }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized
            let isCurrent = (url.path == currentRepoPath)
            let displayBranch = isDetached ? (head.isEmpty ? "detached" : head) : branch
            items.append(
                GitWorktreeItem(
                    id: url.path,
                    url: url,
                    name: url.lastPathComponent,
                    branch: displayBranch,
                    commitShort: head,
                    isCurrent: isCurrent,
                    isDetached: isDetached
                )
            )
        }
        return items
    }

    private nonisolated static func parseBranches(_ output: String) -> [GitBranchItem] {
        var branches: [GitBranchItem] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let fullRef = parts[0]
            let shortName = parts[1]
            let headFlag = parts[2]
            let commitShort = parts[3]

            if fullRef.hasSuffix("/HEAD") || shortName == "origin" { continue }
            let isRemote = fullRef.hasPrefix("refs/remotes/")
            let key = "\(isRemote ? "R" : "L"):\(shortName)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            branches.append(
                GitBranchItem(
                    id: key,
                    name: shortName,
                    isCurrent: headFlag == "*",
                    isCheckedOutElsewhere: headFlag == "+",
                    isRemote: isRemote,
                    commitShort: commitShort
                )
            )
        }
        return branches
    }

    private nonisolated static func parseGitStatus(_ output: String, repoTopLevel: URL) -> [GitChangedFileItem] {
        var items: [GitChangedFileItem] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count >= 4 else { continue }

            let x = String(line.prefix(1))
            let y = String(line.dropFirst(1).prefix(1))
            var relPath = String(line.dropFirst(3))

            if (x == "R" || x == "C"), let range = relPath.range(of: " -> ") {
                relPath = String(relPath[range.upperBound...])
            }
            if relPath.hasPrefix("\"") && relPath.hasSuffix("\"") && relPath.count >= 2 {
                relPath = String(relPath.dropFirst().dropLast())
            }

            let isUntracked = (x == "?" && y == "?")
            let isStaged = !isUntracked && x != " " && x != "!"
            let hasUnstagedChanges = isUntracked || (y != " " && y != "!")

            let displayStatus: String
            if isUntracked {
                displayStatus = "?"
            } else if x == "U" || y == "U" {
                displayStatus = "!"
            } else if y != " " {
                displayStatus = y
            } else {
                displayStatus = x
            }

            let fileURL = repoTopLevel.appendingPathComponent(relPath)
            let fileName = (relPath as NSString).lastPathComponent
            items.append(
                GitChangedFileItem(
                    id: relPath,
                    url: fileURL,
                    relativePath: relPath,
                    fileName: fileName,
                    indexStatus: x,
                    worktreeStatus: y,
                    isStaged: isStaged,
                    hasUnstagedChanges: hasUnstagedChanges,
                    isUntracked: isUntracked,
                    displayStatus: displayStatus
                )
            )
        }
        return items
    }

    private nonisolated static func parseCommitHistory(_ output: String) -> [GitCommitLogItem] {
        var items: [GitCommitLogItem] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = String(rawLine).components(separatedBy: "\u{1F}")
            guard parts.count >= 5 else { continue }
            items.append(
                GitCommitLogItem(
                    id: parts[0],
                    hash: parts[0],
                    shortHash: parts[1],
                    subject: parts[2],
                    author: parts[3],
                    relativeDate: parts[4]
                )
            )
        }
        return items
    }

    // MARK: - File & Tab Operations

    func openFile(url: URL, atLine line: Int? = nil) {
        if let existingIdx = openTabs.firstIndex(where: { $0.url == url }) {
            activeTabID = openTabs[existingIdx].id
            if let line {
                openTabs[existingIdx].pendingJumpLine = line
                onJumpToLineRequested?(line)
            }
            onFocusEditorRequested?()
            return
        }

        let startTime = DispatchTime.now().uptimeNanoseconds
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            statusMessage = L10n("status.failedOpenFileFormat", url.lastPathComponent, error.localizedDescription)
            return
        }

        let content: String
        if let utf8 = String(data: data, encoding: .utf8) {
            content = utf8
        } else if let ascii = String(data: data, encoding: .isoLatin1) {
            content = ascii
        } else {
            statusMessage = L10n("status.binaryFileFormat", url.lastPathComponent)
            return
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000.0
        let tab = EditorTab(
            id: UUID(),
            url: url,
            title: url.lastPathComponent,
            content: content,
            savedContent: content,
            language: CodeLanguage.detect(from: url),
            lastLoadTimeMs: elapsedMs,
            pendingJumpLine: line
        )
        openTabs.append(tab)
        activeTabID = tab.id
        lastRenderLatencyMs = elapsedMs
        statusMessage = L10n("status.openedFileFormat", url.lastPathComponent, elapsedMs)
        onFocusEditorRequested?()
    }

    func createNewUntitledFile() {
        let count = openTabs.filter { $0.url == nil }.count + 1
        let tab = EditorTab(
            id: UUID(),
            url: nil,
            title: count == 1 ? "Untitled.swift" : "Untitled-\(count).swift",
            content: "",
            savedContent: "",
            language: .swift
        )
        openTabs.append(tab)
        activeTabID = tab.id
        statusMessage = L10n("status.createdBuffer")
        onFocusEditorRequested?()
    }

    func createFileInWorkspace(named fileName: String, inside directory: URL? = nil) {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let baseDir = (directory ?? rootURL).standardized
        let targetURL = baseDir.appendingPathComponent(trimmed).standardized
        let parentDir = targetURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try "".write(to: targetURL, atomically: true, encoding: .utf8)
                reloadWorkspace(ensuringExpanded: [baseDir, parentDir])
                statusMessage = L10n("status.createdFileFormat", targetURL.lastPathComponent)
            }
            openFile(url: targetURL)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    // MARK: - Explorer Context Menu File Operations

    func promptNewFile(inside directory: URL) {
        let targetDir = directory.standardized
        let folderDisplay = targetDir.path == rootURL.standardized.path ? rootURL.lastPathComponent : targetDir.lastPathComponent
        guard let name = promptForName(
            title: L10n("explorer.dialog.newFileTitle"),
            message: L10n("explorer.dialog.newFileMessage", folderDisplay),
            defaultValue: "",
            placeholder: L10n("explorer.dialog.newFilePlaceholder"),
            confirmTitle: L10n("explorer.dialog.create")
        ) else { return }

        let targetURL = targetDir.appendingPathComponent(name).standardized
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) {
            if isDir.boolValue {
                statusMessage = L10n("status.itemExistsFormat", targetURL.lastPathComponent)
            } else {
                openFile(url: targetURL)
            }
            return
        }

        createFileInWorkspace(named: name, inside: targetDir)
    }

    func promptNewFolder(inside directory: URL) {
        let targetDir = directory.standardized
        let folderDisplay = targetDir.path == rootURL.standardized.path ? rootURL.lastPathComponent : targetDir.lastPathComponent
        guard let name = promptForName(
            title: L10n("explorer.dialog.newFolderTitle"),
            message: L10n("explorer.dialog.newFolderMessage", folderDisplay),
            defaultValue: "",
            placeholder: L10n("explorer.dialog.newFolderPlaceholder"),
            confirmTitle: L10n("explorer.dialog.create")
        ) else { return }

        let targetURL = targetDir.appendingPathComponent(name).standardized
        if FileManager.default.fileExists(atPath: targetURL.path) {
            statusMessage = L10n("status.itemExistsFormat", targetURL.lastPathComponent)
            return
        }

        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            reloadWorkspace(ensuringExpanded: [targetDir, targetURL])
            statusMessage = L10n("status.createdFolderFormat", targetURL.lastPathComponent)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    func promptRenameItem(at url: URL, isDirectory: Bool) {
        let sourceURL = url.standardized
        let oldName = sourceURL.lastPathComponent
        guard let newName = promptForName(
            title: L10n("explorer.dialog.renameTitle", oldName),
            message: L10n("explorer.dialog.renameMessage"),
            defaultValue: oldName,
            placeholder: oldName,
            confirmTitle: L10n("explorer.dialog.renameConfirm"),
            selectStemOnly: !isDirectory
        ) else { return }

        guard newName != oldName, !newName.contains("/") else { return }
        let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName).standardized

        let isCaseOnlyRename = oldName.caseInsensitiveCompare(newName) == .orderedSame
        if !isCaseOnlyRename && FileManager.default.fileExists(atPath: destURL.path) {
            statusMessage = L10n("status.itemExistsFormat", newName)
            return
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            updateOpenTabsForRenamedItem(from: sourceURL, to: destURL, isDirectory: isDirectory)
            reloadWorkspace(replacingExpandedPrefix: isDirectory ? (sourceURL, destURL) : nil)
            statusMessage = L10n("status.renamedFormat", newName)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    func duplicateItem(at url: URL, isDirectory: Bool) {
        let sourceURL = url.standardized
        let parentDir = sourceURL.deletingLastPathComponent()
        let fm = FileManager.default

        let ext = isDirectory ? "" : sourceURL.pathExtension
        let stem = isDirectory ? sourceURL.lastPathComponent : (sourceURL.lastPathComponent as NSString).deletingPathExtension

        func candidateName(index: Int) -> String {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            return ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
        }

        var copyIndex = 1
        var destURL = parentDir.appendingPathComponent(candidateName(index: copyIndex)).standardized
        while fm.fileExists(atPath: destURL.path) {
            copyIndex += 1
            destURL = parentDir.appendingPathComponent(candidateName(index: copyIndex)).standardized
        }

        do {
            try fm.copyItem(at: sourceURL, to: destURL)
            reloadWorkspace(ensuringExpanded: [parentDir])
            if !isDirectory {
                openFile(url: destURL)
            }
            statusMessage = L10n("status.duplicatedFormat", destURL.lastPathComponent)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    func promptDeleteItem(at url: URL, isDirectory: Bool) {
        let targetURL = url.standardized
        let alert = NSAlert()
        alert.messageText = L10n("explorer.dialog.deleteTitle", targetURL.lastPathComponent)
        alert.informativeText = isDirectory
            ? L10n("explorer.dialog.deleteFolderMessage")
            : L10n("explorer.dialog.deleteFileMessage")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n("explorer.dialog.deleteConfirm"))
        alert.addButton(withTitle: L10n("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
            closeOpenTabsForDeletedItem(at: targetURL, isDirectory: isDirectory)
            reloadWorkspace()
            statusMessage = L10n("status.movedToTrashFormat", targetURL.lastPathComponent)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    func copyPathToPasteboard(_ url: URL, relative: Bool) {
        let value = relative ? relativePath(for: url.standardized) : url.standardized.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusMessage = L10n("status.copiedPathFormat", value)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url.standardized])
    }

    private func promptForName(
        title: String,
        message: String,
        defaultValue: String,
        placeholder: String,
        confirmTitle: String,
        selectStemOnly: Bool = false
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L10n("common.cancel"))

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 24))
        inputField.stringValue = defaultValue
        inputField.placeholderString = placeholder
        inputField.bezelStyle = .roundedBezel
        inputField.usesSingleLineMode = true
        inputField.lineBreakMode = .byTruncatingHead
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        DispatchQueue.main.async {
            alert.window.makeFirstResponder(inputField)
            if selectStemOnly && !defaultValue.isEmpty, let editor = inputField.currentEditor() {
                let stemLength = (defaultValue as NSString).deletingPathExtension.count
                if stemLength > 0 && !defaultValue.hasPrefix(".") && stemLength < defaultValue.count {
                    editor.selectedRange = NSRange(location: 0, length: stemLength)
                } else {
                    editor.selectAll(nil)
                }
            }
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func updateOpenTabsForRenamedItem(from oldURL: URL, to newURL: URL, isDirectory: Bool) {
        let oldPath = oldURL.standardized.path
        for idx in openTabs.indices {
            guard let tabPath = openTabs[idx].url?.standardized.path else { continue }
            if tabPath == oldPath {
                openTabs[idx].url = newURL
                openTabs[idx].title = newURL.lastPathComponent
                openTabs[idx].language = CodeLanguage.detect(from: newURL)
            } else if isDirectory && tabPath.hasPrefix(oldPath + "/") {
                let suffix = String(tabPath.dropFirst(oldPath.count + 1))
                let updatedURL = newURL.appendingPathComponent(suffix).standardized
                openTabs[idx].url = updatedURL
                openTabs[idx].title = updatedURL.lastPathComponent
                openTabs[idx].language = CodeLanguage.detect(from: updatedURL)
            }
        }
    }

    private func closeOpenTabsForDeletedItem(at deletedURL: URL, isDirectory: Bool) {
        let deletedPath = deletedURL.standardized.path
        openTabs.removeAll { tab in
            guard let tabPath = tab.url?.standardized.path else { return false }
            if tabPath == deletedPath { return true }
            return isDirectory && tabPath.hasPrefix(deletedPath + "/")
        }
        if let activeTabID, !openTabs.contains(where: { $0.id == activeTabID }) {
            self.activeTabID = openTabs.last?.id
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

        openTabs.remove(at: index)
        if activeTabID == id {
            if openTabs.isEmpty {
                activeTabID = nil
            } else {
                let nextIdx = min(index, openTabs.count - 1)
                activeTabID = openTabs[nextIdx].id
            }
        }
    }

    func closeActiveTab() {
        if let activeTabID {
            closeTab(id: activeTabID)
        }
    }

    func updateActiveTabContent(_ newContent: String) {
        guard let activeTabID,
              let idx = openTabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        if openTabs[idx].content != newContent {
            openTabs[idx].content = newContent
        }
    }

    func updateActiveTabCursor(line: Int, column: Int, range: NSRange) {
        guard let activeTabID,
              let idx = openTabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        openTabs[idx].cursorLine = line
        openTabs[idx].cursorColumn = column
        openTabs[idx].selectedRange = range
    }

    func updateActiveTabScroll(y: CGFloat) {
        guard let activeTabID,
              let idx = openTabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        openTabs[idx].scrollOffsetY = y
    }

    @discardableResult
    func saveActiveTab() -> Bool {
        guard let activeTabID,
              let idx = openTabs.firstIndex(where: { $0.id == activeTabID }) else { return false }

        var tab = openTabs[idx]
        if tab.virtualKey != nil {
            statusMessage = L10n("status.diffReadOnly")
            return false
        }
        if tab.url == nil {
            let panel = NSSavePanel()
            panel.directoryURL = rootURL
            panel.nameFieldStringValue = tab.title
            guard panel.runModal() == .OK, let chosenURL = panel.url else { return false }
            tab.url = chosenURL
            tab.title = chosenURL.lastPathComponent
            tab.language = CodeLanguage.detect(from: chosenURL)
        }

        guard let targetURL = tab.url else { return false }
        do {
            let startTime = DispatchTime.now().uptimeNanoseconds
            try tab.content.write(to: targetURL, atomically: true, encoding: .utf8)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000.0
            tab.savedContent = tab.content
            openTabs[idx] = tab
            statusMessage = L10n("status.savedFileFormat", tab.title, elapsedMs)
            onSaveSuccessFlash?()
            reloadWorkspace()
            return true
        } catch {
            statusMessage = L10n("status.saveFailedFormat", error.localizedDescription)
            return false
        }
    }

    // MARK: - Global Workspace Search

    func performGlobalSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        let files = allWorkspaceFiles
        let rootPath = rootURL.path

        searchTask = Task.detached(priority: .userInitiated) {
            var matches: [SearchMatch] = []
            let lowerQuery = trimmed.lowercased()

            for url in files {
                if Task.isCancelled { break }
                // Skip files larger than 2MB during global text search
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 2_000_000 {
                    continue
                }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if !content.lowercased().contains(lowerQuery) { continue }

                let relPath = url.path.hasPrefix(rootPath + "/")
                    ? String(url.path.dropFirst(rootPath.count + 1))
                    : url.lastPathComponent

                let lines = content.components(separatedBy: .newlines)
                for (idx, lineText) in lines.enumerated() {
                    if lineText.lowercased().contains(lowerQuery) {
                        matches.append(
                            SearchMatch(
                                url: url,
                                relativePath: relPath,
                                lineNumber: idx + 1,
                                linePreview: lineText.trimmingCharacters(in: .whitespaces)
                            )
                        )
                        if matches.count >= 250 { break }
                    }
                }
                if matches.count >= 250 { break }
            }

            let finalMatches = matches
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.searchResults = finalMatches
                self.isSearching = false
            }
        }
    }

    func relativePath(for url: URL?) -> String {
        guard let url else { return L10n("common.unsavedBuffer") }
        let rootPath = rootURL.path
        if url.path.hasPrefix(rootPath + "/") {
            return String(url.path.dropFirst(rootPath.count + 1))
        }
        return url.path
    }
}
