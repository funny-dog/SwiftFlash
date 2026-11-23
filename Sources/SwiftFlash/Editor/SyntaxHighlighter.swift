import AppKit
import Foundation

// MARK: - Dynamic Theme Proxy

@MainActor
enum ZedTheme {
    static var palette: ThemePalette { ThemeManager.shared.palette }
    static var isDark: Bool { palette.isDark }

    static var background: NSColor { palette.background }
    static var sidebarBackground: NSColor { palette.sidebarBackground }
    static var tabBarBackground: NSColor { palette.tabBarBackground }
    static var activeTabBackground: NSColor { palette.activeTabBackground }
    static var statusBarBackground: NSColor { palette.statusBarBackground }
    static var gutterBackground: NSColor { palette.gutterBackground }
    static var border: NSColor { palette.border }

    static var activeLineBackground: NSColor { palette.activeLineBackground }
    static var selectionBackground: NSColor { palette.selectionBackground }
    static var cursor: NSColor { palette.cursor }

    static var primaryText: NSColor { palette.primaryText }
    static var secondaryText: NSColor { palette.secondaryText }
    static var mutedText: NSColor { palette.mutedText }
    static var hoverBackground: NSColor { palette.hoverBackground }
    static var pillBackground: NSColor { palette.pillBackground }
    static var pillText: NSColor { palette.pillText }

    static var plainText: NSColor { palette.plainText }
    static var gutterText: NSColor { palette.gutterText }
    static var gutterActiveText: NSColor { palette.gutterActiveText }

    static var keyword: NSColor { palette.keyword }
    static var typeName: NSColor { palette.typeName }
    static var function: NSColor { palette.function }
    static var string: NSColor { palette.string }
    static var comment: NSColor { palette.comment }
    static var number: NSColor { palette.number }
    static var attribute: NSColor { palette.attribute }
    static var operatorColor: NSColor { palette.operatorColor }
}

struct HighlightToken: Sendable {
    let range: NSRange
    let colorHex: UInt32
}

// MARK: - High-Speed Async Viewport Syntax Highlighter

final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    private struct Rule {
        let regex: NSRegularExpression
        let colorHex: UInt32
        let captureGroup: Int
    }

    private let swiftKeywords = Set([
        "actor", "as", "async", "await", "break", "case", "catch", "class", "continue",
        "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
        "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in",
        "init", "inout", "internal", "is", "let", "mutating", "nil", "nonisolated",
        "nonmutating", "open", "operator", "override", "package", "private", "protocol",
        "public", "repeat", "required", "rethrows", "return", "self", "Self", "some",
        "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
        "try", "typealias", "var", "weak", "where", "while", "any"
    ])

    private let rustKeywords = Set([
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
        "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
        "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
        "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
        "where", "while"
    ])

    private let pythonKeywords = Set([
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
        "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
        "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
        "raise", "return", "True", "try", "while", "with", "yield", "match", "case"
    ])

    private let jsKeywords = Set([
        "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
        "false", "finally", "for", "function", "if", "implements", "import", "in",
        "instanceof", "interface", "let", "new", "null", "package", "private",
        "protected", "public", "return", "static", "super", "switch", "this", "throw",
        "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with",
        "yield", "from", "as"
    ])

    private let cKeywords = Set([
        "auto", "break", "case", "char", "class", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
        "int", "long", "namespace", "nullptr", "public", "private", "protected",
        "register", "return", "short", "signed", "sizeof", "static", "struct",
        "switch", "template", "this", "typedef", "typename", "union", "unsigned",
        "using", "virtual", "void", "volatile", "while", "BOOL", "YES", "NO", "nil"
    ])

    private let shellKeywords = Set([
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
        "until", "case", "esac", "function", "return", "local", "export", "source",
        "set", "unset", "echo", "exit", "true", "false"
    ])

    private let goKeywords = Set([
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
        "map", "package", "range", "return", "select", "struct", "switch", "type",
        "var", "nil", "true", "false", "iota", "error"
    ])

    private let identifierRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
    private let functionCallRegex = try! NSRegularExpression(pattern: #"\b([a-z_][A-Za-z0-9_]*)\s*\("#)
    private let numberRegex = try! NSRegularExpression(pattern: #"\b(?:0x[0-9A-Fa-f_]+|0b[01_]+|\d[\d_]*(?:\.[\d_]+)?)\b"#)
    private let attributeRegex = try! NSRegularExpression(pattern: #"(?:@[A-Za-z_][A-Za-z0-9_]*|#[A-Za-z_][A-Za-z0-9_]*)"#)
    private let stringDoubleRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
    private let stringSingleRegex = try! NSRegularExpression(pattern: #"'(?:\\.|[^'\\])*'"#)
    private let slashCommentRegex = try! NSRegularExpression(pattern: #"//.*$"#, options: [.anchorsMatchLines])
    private let blockCommentRegex = try! NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#)
    private let hashCommentRegex = try! NSRegularExpression(pattern: #"#.*$"#, options: [.anchorsMatchLines])
    private let markdownHeadingRegex = try! NSRegularExpression(pattern: #"^#{1,6}\s+.*$"#, options: [.anchorsMatchLines])
    private let markdownCodeRegex = try! NSRegularExpression(pattern: #"`[^`]+`"#)
    private let jsonKeyRegex = try! NSRegularExpression(pattern: #""([^"\\]|\\.)*"\s*(?=:)"#)
    private let diffHeaderRegex = try! NSRegularExpression(pattern: #"^(?:diff --git|index|---|\+\+\+|commit|Author:|Date:).*$"#, options: [.anchorsMatchLines])
    private let diffHunkRegex = try! NSRegularExpression(pattern: #"^@@.*@@.*$"#, options: [.anchorsMatchLines])
    private let diffAddRegex = try! NSRegularExpression(pattern: #"^\+.*$"#, options: [.anchorsMatchLines])
    private let diffDeleteRegex = try! NSRegularExpression(pattern: #"^-.*$"#, options: [.anchorsMatchLines])

    /// Computes syntax highlight tokens for a slice of document text.
    /// Locations in returned tokens are relative to the full document (`baseOffset + localLocation`).
    func tokenize(
        slice: String,
        baseOffset: Int,
        language: CodeLanguage,
        palette: ThemePalette = ThemePalette.palette(for: .zedOneDark)
    ) -> [HighlightToken] {
        guard language != .plainText, !slice.isEmpty else { return [] }
        let nsSlice = slice as NSString
        let fullRange = NSRange(location: 0, length: nsSlice.length)

        var tokens: [HighlightToken] = []
        tokens.reserveCapacity(max(32, nsSlice.length / 16))

        if language == .markdown {
            for m in markdownHeadingRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.attributeHex))
            }
            for m in markdownCodeRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.stringHex))
            }
            return tokens
        }

        if language == .json {
            for m in numberRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.numberHex))
            }
            for m in stringDoubleRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.stringHex))
            }
            for m in jsonKeyRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.attributeHex))
            }
            return tokens
        }

        if language == .diff {
            for m in diffAddRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.stringHex))
            }
            for m in diffDeleteRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.attributeHex))
            }
            for m in diffHunkRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.operatorHex))
            }
            for m in diffHeaderRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.functionHex))
            }
            return tokens
        }

        let keywords: Set<String>
        switch language {
        case .swift: keywords = swiftKeywords
        case .rust: keywords = rustKeywords
        case .python: keywords = pythonKeywords
        case .typescript, .javascript: keywords = jsKeywords
        case .c: keywords = cKeywords
        case .shell: keywords = shellKeywords
        case .go: keywords = goKeywords
        default: keywords = []
        }

        // 1. Numbers
        for m in numberRegex.matches(in: slice, range: fullRange) {
            tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.numberHex))
        }

        // 2. Identifiers -> Types (PascalCase) & Keywords
        for m in identifierRegex.matches(in: slice, range: fullRange) {
            let word = nsSlice.substring(with: m.range)
            if keywords.contains(word) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.keywordHex))
            } else if let first = word.first, first.isUppercase, word.count > 1 {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.typeNameHex))
            }
        }

        // 3. Function calls
        for m in functionCallRegex.matches(in: slice, range: fullRange) where m.numberOfRanges > 1 {
            let fnRange = m.range(at: 1)
            let word = nsSlice.substring(with: fnRange)
            if !keywords.contains(word) {
                tokens.append(HighlightToken(range: shifted(fnRange, by: baseOffset), colorHex: palette.functionHex))
            }
        }

        // 4. Attributes / Macros (`@MainActor`, `#selector`, etc.)
        if language == .swift || language == .python || language == .rust || language == .c {
            for m in attributeRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.attributeHex))
            }
        }

        // 5. Strings (override inner identifiers/keywords)
        for m in stringDoubleRegex.matches(in: slice, range: fullRange) {
            tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.stringHex))
        }
        if language == .python || language == .javascript || language == .typescript || language == .shell {
            for m in stringSingleRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.stringHex))
            }
        }

        // 6. Comments (highest precedence)
        switch language {
        case .python, .shell, .yaml, .toml:
            for m in hashCommentRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.commentHex))
            }
        case .swift, .rust, .typescript, .javascript, .c, .css, .go:
            for m in blockCommentRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.commentHex))
            }
            for m in slashCommentRegex.matches(in: slice, range: fullRange) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.commentHex))
            }
        default:
            break
        }

        return tokens
    }

    private func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}
