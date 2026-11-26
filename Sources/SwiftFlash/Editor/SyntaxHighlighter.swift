import AppKit
import Foundation

// MARK: - Dynamic Theme Proxy (Backed by Cached ResolvedThemeColors)

@MainActor
enum ZedTheme {
    private static var colors: ResolvedThemeColors { ThemeManager.shared.resolvedColors }
    static var palette: ThemePalette { colors.palette }
    static var isDark: Bool { palette.isDark }

    static var background: NSColor { colors.background }
    static var sidebarBackground: NSColor { colors.sidebarBackground }
    static var tabBarBackground: NSColor { colors.tabBarBackground }
    static var activeTabBackground: NSColor { colors.activeTabBackground }
    static var statusBarBackground: NSColor { colors.statusBarBackground }
    static var gutterBackground: NSColor { colors.gutterBackground }
    static var border: NSColor { colors.border }

    static var activeLineBackground: NSColor { colors.activeLineBackground }
    static var selectionBackground: NSColor { colors.selectionBackground }
    static var cursor: NSColor { colors.cursor }

    static var primaryText: NSColor { colors.primaryText }
    static var secondaryText: NSColor { colors.secondaryText }
    static var mutedText: NSColor { colors.mutedText }
    static var hoverBackground: NSColor { colors.hoverBackground }
    static var pillBackground: NSColor { colors.pillBackground }
    static var pillText: NSColor { colors.pillText }

    static var plainText: NSColor { colors.plainText }
    static var gutterText: NSColor { colors.gutterText }
    static var gutterActiveText: NSColor { colors.gutterActiveText }

    static var keyword: NSColor { colors.keyword }
    static var typeName: NSColor { colors.typeName }
    static var function: NSColor { colors.function }
    static var string: NSColor { colors.string }
    static var comment: NSColor { colors.comment }
    static var number: NSColor { colors.number }
    static var attribute: NSColor { colors.attribute }
    static var operatorColor: NSColor { colors.operatorColor }
}

// MARK: - Shared Language Keywords (Single Source of Truth)

enum LanguageKeywords {
    static let swift: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
        "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init",
        "inout", "internal", "is", "let", "mutating", "nil", "nonisolated", "nonmutating", "open",
        "operator", "override", "package", "private", "protocol", "public", "repeat", "required",
        "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super",
        "switch", "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
        "where", "while"
    ]

    static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
        "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
        "trait", "true", "type", "unsafe", "use", "where", "while"
    ]

    static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def",
        "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if",
        "import", "in", "is", "lambda", "match", "None", "nonlocal", "not", "or", "pass",
        "raise", "return", "True", "try", "while", "with", "yield"
    ]

    static let jsTs: Set<String> = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false",
        "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof",
        "interface", "let", "new", "null", "package", "private", "protected", "public", "return",
        "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof",
        "undefined", "var", "void", "while", "with", "yield"
    ]

    static let cFamily: Set<String> = [
        "auto", "bool", "BOOL", "break", "case", "char", "class", "const", "continue", "default",
        "define", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if",
        "include", "inline", "int", "long", "namespace", "nil", "NO", "NULL", "nullptr",
        "private", "protected", "public", "register", "return", "short", "signed", "sizeof",
        "static", "struct", "switch", "template", "this", "typedef", "typename", "union",
        "unsigned", "using", "virtual", "void", "volatile", "while", "YES"
    ]

    static let shell: Set<String> = [
        "case", "do", "done", "echo", "elif", "else", "esac", "exit", "export", "false", "fi",
        "for", "function", "if", "in", "local", "return", "set", "source", "then", "true",
        "unset", "until", "while"
    ]

    static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "error",
        "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "iota",
        "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type",
        "var"
    ]

    static func keywordSet(for language: CodeLanguage) -> Set<String> {
        switch language {
        case .swift: return swift
        case .rust: return rust
        case .python: return python
        case .typescript, .javascript: return jsTs
        case .c: return cFamily
        case .shell: return shell
        case .go: return go
        default: return []
        }
    }

    static func completionExtras(for language: CodeLanguage) -> [String] {
        switch language {
        case .swift:
            return ["@MainActor", "@Published", "@State", "@ObservedObject", "@Sendable"]
        case .rust:
            return ["Some", "None", "Ok", "Err", "Result", "Option", "Vec", "String"]
        case .python:
            return ["self", "cls", "print", "len", "range", "enumerate", "isinstance"]
        case .typescript, .javascript:
            return ["Promise", "Array", "Record", "Partial", "console"]
        case .go:
            return ["make", "len", "cap", "append"]
        default:
            return []
        }
    }
}

struct HighlightToken: Sendable {
    let range: NSRange
    let colorHex: UInt32
}

// MARK: - High-Speed Async Viewport Syntax Highlighter

final class SyntaxHighlighter: @unchecked Sendable {
    static let shared = SyntaxHighlighter()

    private let identifierRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
    private let functionCallRegex = try! NSRegularExpression(pattern: #"\b([a-z_][A-Za-z0-9_]*)\s*\("#)
    private let numberRegex = try! NSRegularExpression(pattern: #"\b(?:0x[0-9A-Fa-f_]+|0b[01_]+|\d[\d_]*(?:\.[\d_]+)?)\b"#)
    private let attributeRegex = try! NSRegularExpression(pattern: #"(?:@[A-Za-z_][A-Za-z0-9_]*|#[A-Za-z_][A-Za-z0-9_]*)"#)
    private let stringDoubleRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\\n])*""#)
    private let markdownHeadingRegex = try! NSRegularExpression(pattern: #"^#{1,6}\s+.*$"#, options: [.anchorsMatchLines])
    private let markdownCodeRegex = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private let jsonKeyRegex = try! NSRegularExpression(pattern: #""([^"\\\n]|\\.)*"\s*(?=:)"#)
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

        // 1. Lex strings and comments in a single left-to-right pass so comments inside strings
        //    (e.g. `"https://example.com"`, `"#ff0055"`) and quotes inside comments are never miscolored.
        let protectedSpans = scanStringsAndComments(nsSlice: nsSlice, language: language, palette: palette)
        let keywords = LanguageKeywords.keywordSet(for: language)

        // 2. Numbers (outside strings/comments)
        for m in numberRegex.matches(in: slice, range: fullRange) where !overlapsProtected(m.range, in: protectedSpans) {
            tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.numberHex))
        }

        // 3. Identifiers -> Keywords & PascalCase Type Names
        for m in identifierRegex.matches(in: slice, range: fullRange) where !overlapsProtected(m.range, in: protectedSpans) {
            let word = nsSlice.substring(with: m.range)
            if keywords.contains(word) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.keywordHex))
            } else if let first = word.first, first.isUppercase, word.count > 1 {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.typeNameHex))
            }
        }

        // 4. Function calls
        for m in functionCallRegex.matches(in: slice, range: fullRange) where m.numberOfRanges > 1 {
            let fnRange = m.range(at: 1)
            guard !overlapsProtected(fnRange, in: protectedSpans) else { continue }
            let word = nsSlice.substring(with: fnRange)
            if !keywords.contains(word) {
                tokens.append(HighlightToken(range: shifted(fnRange, by: baseOffset), colorHex: palette.functionHex))
            }
        }

        // 5. Attributes / Macros (`@MainActor`, `#selector`, etc.)
        if language == .swift || language == .python || language == .rust || language == .c {
            for m in attributeRegex.matches(in: slice, range: fullRange) where !overlapsProtected(m.range, in: protectedSpans) {
                tokens.append(HighlightToken(range: shifted(m.range, by: baseOffset), colorHex: palette.attributeHex))
            }
        }

        // 6. Emit non-overlapping string and comment spans from pass 1
        for span in protectedSpans {
            tokens.append(HighlightToken(range: shifted(span.range, by: baseOffset), colorHex: span.colorHex))
        }

        return tokens
    }

    private struct ProtectedSpan {
        let range: NSRange
        let colorHex: UInt32
    }

    private func scanStringsAndComments(
        nsSlice: NSString,
        language: CodeLanguage,
        palette: ThemePalette
    ) -> [ProtectedSpan] {
        let length = nsSlice.length
        guard length > 0 else { return [] }

        let usesHashComment = (language == .python || language == .shell || language == .yaml || language == .toml)
        let usesSlashComment = (language == .swift || language == .rust || language == .typescript
            || language == .javascript || language == .c || language == .css || language == .go)
        let usesSingleQuoteStrings = (language == .python || language == .javascript || language == .typescript || language == .shell || language == .yaml || language == .toml)
        let usesBacktickStrings = (language == .javascript || language == .typescript || language == .go)
        let usesTripleQuotes = (language == .python || language == .swift)

        var spans: [ProtectedSpan] = []
        var i = 0

        let quoteD: unichar = 0x22     // "
        let quoteS: unichar = 0x27     // '
        let backtick: unichar = 0x60   // `
        let backslash: unichar = 0x5C  // \
        let slash: unichar = 0x2F      // /
        let star: unichar = 0x2A       // *
        let hash: unichar = 0x23       // #
        let newline: unichar = 0x0A    // \n

        while i < length {
            let ch = nsSlice.character(at: i)
            let next: unichar = (i + 1 < length) ? nsSlice.character(at: i + 1) : 0

            // Line comment (`//` or `#`)
            if usesSlashComment && ch == slash && next == slash {
                let start = i
                i += 2
                while i < length && nsSlice.character(at: i) != newline {
                    i += 1
                }
                spans.append(ProtectedSpan(range: NSRange(location: start, length: i - start), colorHex: palette.commentHex))
                continue
            }
            if usesHashComment && ch == hash {
                let start = i
                i += 1
                while i < length && nsSlice.character(at: i) != newline {
                    i += 1
                }
                spans.append(ProtectedSpan(range: NSRange(location: start, length: i - start), colorHex: palette.commentHex))
                continue
            }

            // Block comment (`/* ... */`)
            if usesSlashComment && ch == slash && next == star {
                let start = i
                i += 2
                while i < length {
                    if nsSlice.character(at: i) == star && i + 1 < length && nsSlice.character(at: i + 1) == slash {
                        i += 2
                        break
                    }
                    i += 1
                }
                spans.append(ProtectedSpan(range: NSRange(location: start, length: i - start), colorHex: palette.commentHex))
                continue
            }

            // Triple-quoted strings (`"""..."""` or `'''...'''`)
            if usesTripleQuotes && (ch == quoteD || (language == .python && ch == quoteS))
                && i + 2 < length
                && nsSlice.character(at: i + 1) == ch
                && nsSlice.character(at: i + 2) == ch {
                let delim = ch
                let start = i
                i += 3
                while i < length {
                    let c = nsSlice.character(at: i)
                    if c == backslash {
                        i += 2
                        continue
                    }
                    if c == delim && i + 2 < length && nsSlice.character(at: i + 1) == delim && nsSlice.character(at: i + 2) == delim {
                        i += 3
                        break
                    }
                    i += 1
                }
                spans.append(ProtectedSpan(range: NSRange(location: start, length: min(i, length) - start), colorHex: palette.stringHex))
                continue
            }

            // Single-line double-quoted or single-quoted string
            if ch == quoteD || (usesSingleQuoteStrings && ch == quoteS) {
                let delim = ch
                let start = i
                i += 1
                while i < length {
                    let c = nsSlice.character(at: i)
                    if c == newline {
                        // Terminate unclosed string at end of line to prevent runaway highlighting.
                        break
                    }
                    if c == backslash {
                        i += 2
                        continue
                    }
                    i += 1
                    if c == delim {
                        break
                    }
                }
                spans.append(ProtectedSpan(range: NSRange(location: start, length: min(i, length) - start), colorHex: palette.stringHex))
                continue
            }

            // Backtick template/raw string
            if usesBacktickStrings && ch == backtick {
                let start = i
                i += 1
                while i < length {
                    let c = nsSlice.character(at: i)
                    if language != .go && c == backslash {
                        i += 2
                        continue
                    }
                    i += 1
                    if c == backtick {
                        break
                    }
                }
                spans.append(ProtectedSpan(range: NSRange(location: start, length: min(i, length) - start), colorHex: palette.stringHex))
                continue
            }

            i += 1
        }

        return spans
    }

    /// Binary searches sorted non-overlapping protected spans in O(log S).
    private func overlapsProtected(_ range: NSRange, in spans: [ProtectedSpan]) -> Bool {
        guard !spans.isEmpty else { return false }
        let targetStart = range.location
        let targetEnd = range.location + range.length
        var lo = 0
        var hi = spans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let span = spans[mid].range
            let spanEnd = span.location + span.length
            if targetEnd <= span.location {
                hi = mid - 1
            } else if targetStart >= spanEnd {
                lo = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    private func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}
