import AppKit
import Foundation

// MARK: - LSP Protocol Data Models

struct LSPPosition: Codable, Equatable, Hashable, Sendable {
    let line: Int       // 0-based
    let character: Int  // 0-based UTF-16 offset
}

struct LSPRange: Codable, Equatable, Hashable, Sendable {
    let start: LSPPosition
    let end: LSPPosition
}

struct LSPLocation: Codable, Equatable, Hashable, Sendable {
    let uri: String
    let range: LSPRange
}

struct LSPHover: Equatable, Sendable {
    let contents: String
    let range: LSPRange?
}

struct LSPTextEdit: Equatable, Sendable {
    let range: LSPRange
    let newText: String
}

enum LSPSymbolKind: Int, Codable, Equatable, Hashable, Sendable {
    case file = 1
    case module = 2
    case namespace = 3
    case package = 4
    case `class` = 5
    case method = 6
    case property = 7
    case field = 8
    case constructor = 9
    case `enum` = 10
    case interface = 11
    case function = 12
    case variable = 13
    case constant = 14
    case string = 15
    case number = 16
    case boolean = 17
    case array = 18
    case object = 19
    case key = 20
    case null = 21
    case enumMember = 22
    case `struct` = 23
    case event = 24
    case `operator` = 25
    case typeParameter = 26

    var iconName: String {
        switch self {
        case .class, .struct, .interface, .object, .typeParameter:
            return "cube"
        case .method, .function, .constructor:
            return "f.cursive"
        case .property, .field, .variable, .key:
            return "v.square"
        case .enum, .enumMember:
            return "list.bullet.rectangle"
        case .module, .namespace, .package:
            return "shippingbox"
        case .constant, .number:
            return "number.square"
        case .file, .string:
            return "doc.text"
        default:
            return "chevron.left.forwardslash.chevron.right"
        }
    }

    var badgeColorHex: UInt32 {
        switch self {
        case .class, .struct, .interface, .typeParameter:
            return 0xE5C07B
        case .method, .function, .constructor:
            return 0x61AFEF
        case .property, .field, .variable:
            return 0xE06C75
        case .enum, .enumMember, .constant, .module, .namespace, .package:
            return 0x56B6C2
        default:
            return 0xC678DD
        }
    }
}

struct LSPDocumentSymbol: Identifiable, Equatable, Sendable {
    var id: String {
        "\(containerName ?? "")::\(name)::\(kind.rawValue)::\(selectionRange.start.line):\(selectionRange.start.character)"
    }
    let name: String
    let detail: String?
    let kind: LSPSymbolKind
    let range: LSPRange
    let selectionRange: LSPRange
    let containerName: String?
    let depth: Int
}

struct WorkspaceReferenceEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(fileURL.path):\(line):\(column):\(preview)" }
    let fileURL: URL
    let relativePath: String
    let line: Int        // 1-based
    let column: Int      // 1-based
    let preview: String
}

enum LSPDiagnosticSeverity: Int, Codable, Equatable, Hashable, Sendable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4

    var iconName: String {
        switch self {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .information: return "info.circle.fill"
        case .hint: return "lightbulb.fill"
        }
    }

    var colorHex: UInt32 {
        switch self {
        case .error: return 0xE06C75
        case .warning: return 0xE5C07B
        case .information: return 0x61AFEF
        case .hint: return 0x8A9199
        }
    }
}

struct LSPDiagnostic: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String {
        "\(range.start.line):\(range.start.character)-\(range.end.line):\(range.end.character):\(severity.rawValue):\(message)"
    }
    let range: LSPRange
    let severity: LSPDiagnosticSeverity
    let code: String?
    let source: String?
    let message: String
}

struct WorkspaceDiagnosticEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(fileURL.path):\(diagnostic.id)" }
    let fileURL: URL
    let relativePath: String
    let diagnostic: LSPDiagnostic
}

enum LSPCompletionKind: Int, Codable, Equatable, Hashable, Sendable {
    case text = 1
    case method = 2
    case function = 3
    case constructor = 4
    case field = 5
    case variable = 6
    case `class` = 7
    case interface = 8
    case module = 9
    case property = 10
    case unit = 11
    case value = 12
    case `enum` = 13
    case keyword = 14
    case snippet = 15
    case color = 16
    case file = 17
    case reference = 18
    case folder = 19
    case enumMember = 20
    case constant = 21
    case `struct` = 22
    case event = 23
    case `operator` = 24
    case typeParameter = 25

    var iconName: String {
        switch self {
        case .method, .function, .constructor:
            return "f.cursive"
        case .field, .property, .variable:
            return "v.square"
        case .class, .struct, .interface, .typeParameter:
            return "cube"
        case .enum, .enumMember:
            return "list.bullet.rectangle"
        case .keyword:
            return "key"
        case .module:
            return "shippingbox"
        case .constant, .value:
            return "number.square"
        case .snippet:
            return "curlybraces"
        default:
            return "text.word.spacing"
        }
    }

    var badgeColorHex: UInt32 {
        switch self {
        case .method, .function, .constructor:
            return 0x61AFEF
        case .class, .struct, .interface, .typeParameter:
            return 0xE5C07B
        case .keyword:
            return 0xC678DD
        case .field, .property, .variable:
            return 0xE06C75
        case .module, .constant, .enum, .enumMember:
            return 0x56B6C2
        default:
            return 0x98C379
        }
    }
}

struct LSPCompletionItem: Identifiable, Equatable, Sendable {
    var id: String { "\(label)|\(kind.rawValue)|\(detail ?? "")|\(insertText)" }
    let label: String
    let kind: LSPCompletionKind
    let detail: String?
    let documentation: String?
    let insertText: String
    let filterText: String
    let sortText: String
    let isLocalFallback: Bool
}

// MARK: - Server Catalog & Status

enum LSPInstallStrategy: Equatable, Sendable {
    case systemToolchain(xcrunTool: String)
    case githubGzipBinary(url: String, sha256: String?)
    case githubLatestZipBinary(repo: String, assetPrefix: String, binaryRelativePath: String)
    case npmPackages(packages: [String], binaryName: String)
    case goInstall(packagePath: String, binaryName: String)
}

struct LSPServerDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let languageSummary: String
    let executableName: String
    let arguments: [String]
    let installStrategy: LSPInstallStrategy
    let manualInstallHint: String
}

struct LSPInstallProgress: Equatable, Sendable {
    let message: String
    let fraction: Double?
    let detail: String?
}

enum LSPServerStatus: Equatable, Sendable {
    case notInstalled
    case detected(path: String)
    case installed(path: String)
    case installing(LSPInstallProgress)
    case failed(String)

    var executablePath: String? {
        switch self {
        case .detected(let path), .installed(let path):
            return path
        case .notInstalled, .installing, .failed:
            return nil
        }
    }

    var isReady: Bool {
        executablePath != nil
    }
}

enum LSPServerCatalog {
    static let all: [LSPServerDefinition] = [
        LSPServerDefinition(
            id: "sourcekit-lsp",
            displayName: "SourceKit-LSP",
            languageSummary: "Swift / C / Objective-C",
            executableName: "sourcekit-lsp",
            arguments: [],
            installStrategy: .systemToolchain(xcrunTool: "sourcekit-lsp"),
            manualInstallHint: "xcode-select --install"
        ),
        LSPServerDefinition(
            id: "rust-analyzer",
            displayName: "rust-analyzer",
            languageSummary: "Rust",
            executableName: "rust-analyzer",
            arguments: [],
            installStrategy: .githubGzipBinary(
                url: "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-aarch64-apple-darwin.gz",
                sha256: nil
            ),
            manualInstallHint: "brew install rust-analyzer"
        ),
        LSPServerDefinition(
            id: "clangd",
            displayName: "clangd",
            languageSummary: "C / C++",
            executableName: "clangd",
            arguments: ["--background-index"],
            installStrategy: .githubLatestZipBinary(
                repo: "clangd/clangd",
                assetPrefix: "clangd-mac-",
                binaryRelativePath: "bin/clangd"
            ),
            manualInstallHint: "brew install llvm"
        ),
        LSPServerDefinition(
            id: "typescript-language-server",
            displayName: "TypeScript Language Server",
            languageSummary: "TypeScript / JavaScript",
            executableName: "typescript-language-server",
            arguments: ["--stdio"],
            installStrategy: .npmPackages(
                packages: ["typescript-language-server", "typescript"],
                binaryName: "typescript-language-server"
            ),
            manualInstallHint: "npm install -g typescript-language-server typescript"
        ),
        LSPServerDefinition(
            id: "pyright",
            displayName: "Pyright",
            languageSummary: "Python",
            executableName: "pyright-langserver",
            arguments: ["--stdio"],
            installStrategy: .npmPackages(
                packages: ["pyright"],
                binaryName: "pyright-langserver"
            ),
            manualInstallHint: "npm install -g pyright"
        ),
        LSPServerDefinition(
            id: "gopls",
            displayName: "gopls",
            languageSummary: "Go",
            executableName: "gopls",
            arguments: ["serve"],
            installStrategy: .goInstall(
                packagePath: "golang.org/x/tools/gopls@latest",
                binaryName: "gopls"
            ),
            manualInstallHint: "go install golang.org/x/tools/gopls@latest"
        )
    ]

    static func definition(forID id: String) -> LSPServerDefinition? {
        all.first { $0.id == id }
    }
}
