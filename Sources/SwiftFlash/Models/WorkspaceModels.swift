import AppKit
import Foundation

// MARK: - Language Definition

enum CodeLanguage: String, CaseIterable, Identifiable, Sendable {
    case swift = "Swift"
    case rust = "Rust"
    case python = "Python"
    case typescript = "TypeScript"
    case javascript = "JavaScript"
    case json = "JSON"
    case markdown = "Markdown"
    case shell = "Shell"
    case c = "C/C++"
    case go = "Go"
    case yaml = "YAML"
    case toml = "TOML"
    case html = "HTML"
    case css = "CSS"
    case diff = "Diff"
    case plainText = "Plain Text"

    var id: String { rawValue }

    var lineCommentPrefix: String? {
        switch self {
        case .swift, .rust, .typescript, .javascript, .c, .css, .go:
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
        case .go: return "hare"
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
        case .go: return NSColor(hex: 0x00ADD8)
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
        case "ts", "tsx", "mts", "cts": return .typescript
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "json", "jsonc": return .json
        case "md", "markdown": return .markdown
        case "sh", "zsh", "bash": return .shell
        case "c", "h", "cpp", "hpp", "cc", "cxx", "hh", "m", "mm": return .c
        case "go": return .go
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "html", "htm", "xml", "plist": return .html
        case "css", "scss": return .css
        case "diff", "patch": return .diff
        default: return .plainText
        }
    }
}

// MARK: - File Tree & Editor Tab Models

@MainActor
final class FileItem: Identifiable, ObservableObject {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let language: CodeLanguage
    @Published var isExpanded: Bool = false
    @Published var children: [FileItem]? = nil

    nonisolated static let ignoredNames: Set<String> = [
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

/// Reference-backed text buffer allowing in-place keystroke updates without triggering
/// `@Published var openTabs` full-window SwiftUI redraw storms on every typed character.
@MainActor
final class TextBufferBox {
    var text: String
    init(_ text: String) {
        self.text = text
    }
}

struct TabViewState {
    var scrollOffsetY: CGFloat?
    var selectedRange: NSRange = NSRange(location: 0, length: 0)
    var cursorLine: Int = 1
    var cursorColumn: Int = 1
}

struct EditorTab: Identifiable, Equatable {
    let id: UUID
    var url: URL?
    var virtualKey: String? = nil
    var title: String
    private var contentBox: TextBufferBox
    var savedContent: String
    var isDirty: Bool
    var language: CodeLanguage
    var pendingJumpLine: Int?
    var pendingJumpColumn: Int?
    var externalReloadRevision: Int = 0

    @MainActor
    var content: String {
        get { contentBox.text }
        nonmutating set { contentBox.text = newValue }
    }

    @MainActor
    init(
        id: UUID,
        url: URL?,
        virtualKey: String? = nil,
        title: String,
        content: String,
        savedContent: String,
        language: CodeLanguage,
        pendingJumpLine: Int? = nil,
        pendingJumpColumn: Int? = nil,
        externalReloadRevision: Int = 0
    ) {
        self.id = id
        self.url = url
        self.virtualKey = virtualKey
        self.title = title
        self.contentBox = TextBufferBox(content)
        self.savedContent = savedContent
        self.isDirty = (virtualKey == nil && content != savedContent)
        self.language = language
        self.pendingJumpLine = pendingJumpLine
        self.pendingJumpColumn = pendingJumpColumn
        self.externalReloadRevision = externalReloadRevision
    }

    /// Updates buffer text in place and returns whether `isDirty` changed.
    @MainActor
    mutating func updateBufferContent(_ newText: String) -> Bool {
        contentBox.text = newText
        let nowDirty = (virtualKey == nil && newText != savedContent)
        if nowDirty != isDirty {
            isDirty = nowDirty
            return true
        }
        return false
    }

    @MainActor
    mutating func replaceBufferAndMarkSaved(_ newText: String) {
        contentBox.text = newText
        savedContent = newText
        isDirty = false
    }

    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool {
        lhs.id == rhs.id
            && lhs.url == rhs.url
            && lhs.virtualKey == rhs.virtualKey
            && lhs.title == rhs.title
            && lhs.isDirty == rhs.isDirty
            && lhs.language == rhs.language
            && lhs.externalReloadRevision == rhs.externalReloadRevision
            && lhs.pendingJumpLine == rhs.pendingJumpLine
            && lhs.pendingJumpColumn == rhs.pendingJumpColumn
    }
}

struct SearchMatch: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let relativePath: String
    let lineNumber: Int
    let linePreview: String
}

enum SidebarMode: String, CaseIterable, Sendable {
    case explorer = "Explorer"
    case git = "Git"
    case search = "Search"
}

enum GitPanelTab: String, CaseIterable, Sendable {
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

enum GitChangeFilter: String, CaseIterable, Sendable {
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

enum GitCommitActionMode: String, CaseIterable, Sendable {
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

struct GitChangedFileItem: Identifiable, Equatable, Sendable {
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

struct GitCommitLogItem: Identifiable, Equatable, Sendable {
    let id: String
    let hash: String
    let shortHash: String
    let subject: String
    let author: String
    let relativeDate: String
}

enum OverlayPanelMode: Equatable, Sendable {
    case none
    case projectSwitcher
    case worktreeSwitcher
    case branchSwitcher
    case quickOpen
    case settings
}

@MainActor
struct ProjectSessionSnapshot {
    var openTabs: [EditorTab]
    var activeTabID: UUID?
    var tabViewStates: [UUID: TabViewState]
}

struct GitWorktreeItem: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let branch: String
    let commitShort: String
    let isCurrent: Bool
    let isDetached: Bool
}

struct GitBranchItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isCurrent: Bool
    let isCheckedOutElsewhere: Bool
    let isRemote: Bool
    let commitShort: String
}

struct ExternalOpenTarget: Equatable, Sendable {
    let url: URL
    let line: Int?
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
