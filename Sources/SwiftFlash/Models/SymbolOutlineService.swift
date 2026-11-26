import Foundation

// MARK: - Local Fallback Symbol Outline & Active Breadcrumb Resolver

enum SymbolOutlineService {
    private struct PatternRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let kind: LSPSymbolKind
        let nameGroup: Int
        let detailPrefix: String?
    }

    private static let swiftRules: [PatternRule] = compile([
        (#"^\s*(?:public|private|fileprivate|internal|open|final|indirect|nonisolated|@[\w()]+\s+)*\s*(class|struct|enum|protocol|actor)\s+([A-Za-z_]\w*)"#, .struct, 2, nil),
        (#"^\s*(?:public|private|fileprivate|internal|open)?\s*extension\s+([A-Za-z_][\w.<>]*)"#, .namespace, 1, "extension"),
        (#"^\s*(?:public|private|fileprivate|internal|open|static|class|override|mutating|nonmutating|nonisolated|final|@[\w()]+\s+)*\s*func\s+([A-Za-z_]\w*)"#, .function, 1, "func"),
        (#"^\s*(?:public|private|fileprivate|internal|open|required|convenience|override)?\s*(init\??)\s*\("#, .constructor, 1, nil),
        (#"^\s*(?:public|private|fileprivate|internal|open)?\s*typealias\s+([A-Za-z_]\w*)"#, .typeParameter, 1, "typealias")
    ])

    private static let rustRules: [PatternRule] = compile([
        (#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|union)\s+([A-Za-z_]\w*)"#, .struct, 1, nil),
        (#"^\s*impl(?:<[^>]*>)?\s+([A-Za-z_][\w:<> ]*?)\s*\{"#, .namespace, 1, "impl"),
        (#"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+|unsafe\s+|const\s+|extern\s+(?:"[^"]*"\s+)?)?fn\s+([A-Za-z_]\w*)"#, .function, 1, "fn"),
        (#"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z_]\w*)"#, .module, 1, "mod")
    ])

    private static let pythonRules: [PatternRule] = compile([
        (#"^\s*class\s+([A-Za-z_]\w*)"#, .class, 1, "class"),
        (#"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)"#, .function, 1, "def")
    ])

    private static let jsTsRules: [PatternRule] = compile([
        (#"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)"#, .class, 1, "class"),
        (#"^\s*(?:export\s+)?interface\s+([A-Za-z_$][\w$]*)"#, .interface, 1, "interface"),
        (#"^\s*(?:export\s+)?type\s+([A-Za-z_$][\w$]*)\s*="#, .typeParameter, 1, "type"),
        (#"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)"#, .function, 1, "function"),
        (#"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"#, .function, 1, "=>")
    ])

    private static let goRules: [PatternRule] = compile([
        (#"^\s*type\s+([A-Za-z_]\w*)\s+(?:struct|interface)"#, .struct, 1, "type"),
        (#"^\s*func\s+(?:\([^)]+\)\s*)?([A-Za-z_]\w*)\s*\("#, .function, 1, "func")
    ])

    private static let cRules: [PatternRule] = compile([
        (#"^\s*(?:typedef\s+)?(?:struct|class|enum|union)\s+([A-Za-z_]\w*)"#, .struct, 1, nil),
        (#"^\s*(?:static\s+|inline\s+|extern\s+|virtual\s+)?[A-Za-z_][\w:*&<> ]+\s+([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const\s*)?\{"#, .function, 1, nil)
    ])

    private static let markdownRules: [PatternRule] = compile([
        (#"^(#{1,6})\s+(.+?)\s*#*$"#, .string, 2, nil)
    ])

    private static func compile(_ specs: [(String, LSPSymbolKind, Int, String?)]) -> [PatternRule] {
        specs.compactMap { pattern, kind, group, detail in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return PatternRule(regex: regex, kind: kind, nameGroup: group, detailPrefix: detail)
        }
    }

    static func extractLocalSymbols(from text: String, language: CodeLanguage) -> [LSPDocumentSymbol] {
        guard !text.isEmpty else { return [] }
        let rules: [PatternRule]
        switch language {
        case .swift: rules = swiftRules
        case .rust: rules = rustRules
        case .python: rules = pythonRules
        case .typescript, .javascript: rules = jsTsRules
        case .go: rules = goRules
        case .c: rules = cRules
        case .markdown: rules = markdownRules
        default: return []
        }

        let lines = text.components(separatedBy: "\n")
        var symbols: [LSPDocumentSymbol] = []
        symbols.reserveCapacity(64)

        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            for rule in rules {
                guard let match = rule.regex.firstMatch(in: line, range: fullRange),
                      rule.nameGroup < match.numberOfRanges,
                      match.range(at: rule.nameGroup).location != NSNotFound else {
                    continue
                }
                let name = nsLine.substring(with: match.range(at: rule.nameGroup))
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }

                var resolvedKind = rule.kind
                var resolvedDetail = rule.detailPrefix
                var depth = 0

                if language == .swift, match.numberOfRanges > 1, rule.nameGroup == 2 {
                    let kw = nsLine.substring(with: match.range(at: 1))
                    resolvedDetail = kw
                    switch kw {
                    case "class": resolvedKind = .class
                    case "enum": resolvedKind = .enum
                    case "protocol": resolvedKind = .interface
                    default: resolvedKind = .struct
                    }
                } else if language == .markdown, match.numberOfRanges > 1 {
                    let hashes = nsLine.substring(with: match.range(at: 1))
                    depth = max(0, hashes.count - 1)
                    resolvedDetail = "H\(hashes.count)"
                } else {
                    let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                    depth = leadingSpaces >= 2 ? 1 : 0
                }

                let nameRange = match.range(at: rule.nameGroup)
                let startPos = LSPPosition(line: idx, character: nameRange.location)
                let endPos = LSPPosition(line: idx, character: nameRange.location + nameRange.length)
                let lineEndPos = LSPPosition(line: idx, character: nsLine.length)

                symbols.append(LSPDocumentSymbol(
                    name: name,
                    detail: resolvedDetail,
                    kind: resolvedKind,
                    range: LSPRange(start: LSPPosition(line: idx, character: 0), end: lineEndPos),
                    selectionRange: LSPRange(start: startPos, end: endPos),
                    containerName: nil,
                    depth: depth
                ))
                break
            }
        }
        return symbols
    }

    /// Finds the deepest symbol enclosing (or immediately preceding) a 1-based cursor line.
    static func activeSymbol(atLine oneBasedLine: Int, in symbols: [LSPDocumentSymbol]) -> LSPDocumentSymbol? {
        guard !symbols.isEmpty else { return nil }
        let zeroLine = max(0, oneBasedLine - 1)

        // First try true range containment (LSP hierarchical symbols have real end lines).
        let containing = symbols.filter { sym in
            sym.range.start.line <= zeroLine && sym.range.end.line >= zeroLine && sym.range.end.line > sym.range.start.line
        }
        if let deepest = containing.max(by: { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            let lhsSpan = lhs.range.end.line - lhs.range.start.line
            let rhsSpan = rhs.range.end.line - rhs.range.start.line
            return lhsSpan > rhsSpan
        }) {
            return deepest
        }

        // Fallback for line-based local symbols: latest symbol starting at or before current line.
        return symbols.last { $0.selectionRange.start.line <= zeroLine }
    }

    /// Built-in JSON formatter fallback when no LSP formatting server is active.
    static func fallbackFormatDocument(content: String, language: CodeLanguage) -> String? {
        switch language {
        case .json:
            guard let data = content.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let pretty = try? JSONSerialization.data(
                      withJSONObject: obj,
                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                  ),
                  let str = String(data: pretty, encoding: .utf8) else {
                return nil
            }
            return str + "\n"
        default:
            return nil
        }
    }
}
