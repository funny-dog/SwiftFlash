import AppKit
import SwiftUI

// MARK: - Local Completion & Merge Provider

enum LocalCompletionProvider {
    private static let fromImportRegex = try! NSRegularExpression(
        pattern: #"^\s*from\s+([A-Za-z_]\w*)\s+import\s+(?:\(?\s*(?:\w+\s*(?:as\s+\w+\s*)?,\s*)*)(\w*)$"#
    )
    private static let modRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:import|from)\s+(?:\w+\s*,\s*)*(\w*)$"#
    )
    private static let fromWordRegex = try! NSRegularExpression(
        pattern: #"^\s*from\s+\w+\s+\w"#
    )
    private static let memberRegex = try! NSRegularExpression(
        pattern: #"((?:[A-Za-z_]\w*\s*\.\s*)*[A-Za-z_]\w*|[)\]])\s*\.\s*(\w*)$"#
    )
    private static let identifierRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z_][A-Za-z0-9_]{1,63}\b"#
    )
    private static let pythonDefRegex = try! NSRegularExpression(
        pattern: #"^\s*def\s+([A-Za-z_]\w*)"#,
        options: .anchorsMatchLines
    )

    private final class IdentifierCacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String = ""
        private var cached: [String] = []

        func lookup(key: String) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return self.key == key ? cached : nil
        }

        func store(key: String, identifiers: [String]) {
            lock.lock()
            self.key = key
            self.cached = identifiers
            lock.unlock()
        }
    }

    private static let identifierCache = IdentifierCacheBox()

    static func identifierPrefixRange(in nsString: NSString, at cursorOffset: Int) -> NSRange {
        let clamped = max(0, min(cursorOffset, nsString.length))
        var start = clamped
        while start > 0 {
            let codeUnit = nsString.character(at: start - 1)
            if isIdentifierChar(codeUnit) {
                start -= 1
            } else {
                break
            }
        }
        return NSRange(location: start, length: clamped - start)
    }

    static func isIdentifierChar(_ codeUnit: unichar) -> Bool {
        (codeUnit >= 65 && codeUnit <= 90)      // A-Z
            || (codeUnit >= 97 && codeUnit <= 122) // a-z
            || (codeUnit >= 48 && codeUnit <= 57)  // 0-9
            || codeUnit == 95                      // _
    }

    static func keywords(for language: CodeLanguage) -> [String] {
        let base = Array(LanguageKeywords.keywordSet(for: language))
        let extras = LanguageKeywords.completionExtras(for: language)
        return (base + extras).sorted()
    }

    enum PythonLineContext: Equatable {
        case general
        case importModules
        case importMembers(module: String)
        case memberAccess(target: String, viaSelf: Bool)
    }

    static let pythonModuleMembers: [String: [(label: String, kind: LSPCompletionKind)]] = [
        "collections": [
            ("deque", .class), ("defaultdict", .class), ("Counter", .class),
            ("OrderedDict", .class), ("namedtuple", .function), ("ChainMap", .class)
        ],
        "heapq": [
            ("heappush", .function), ("heappop", .function), ("heapify", .function),
            ("heappushpop", .function), ("heapreplace", .function), ("nlargest", .function),
            ("nsmallest", .function), ("merge", .function)
        ],
        "math": [
            ("inf", .constant), ("pi", .constant), ("e", .constant), ("nan", .constant),
            ("sqrt", .function), ("isqrt", .function), ("gcd", .function), ("lcm", .function),
            ("ceil", .function), ("floor", .function), ("log", .function), ("log2", .function),
            ("log10", .function), ("pow", .function), ("exp", .function), ("factorial", .function),
            ("comb", .function), ("perm", .function), ("fabs", .function), ("hypot", .function)
        ],
        "bisect": [
            ("bisect_left", .function), ("bisect_right", .function), ("bisect", .function),
            ("insort", .function), ("insort_left", .function), ("insort_right", .function)
        ],
        "itertools": [
            ("accumulate", .function), ("permutations", .function), ("combinations", .function),
            ("combinations_with_replacement", .function), ("product", .function), ("chain", .function),
            ("groupby", .function), ("count", .function), ("cycle", .function), ("repeat", .function),
            ("islice", .function), ("zip_longest", .function), ("pairwise", .function)
        ],
        "functools": [
            ("lru_cache", .function), ("cache", .function), ("reduce", .function),
            ("cmp_to_key", .function), ("partial", .function), ("wraps", .function), ("total_ordering", .function)
        ],
        "typing": [
            ("List", .typeParameter), ("Optional", .typeParameter), ("Dict", .typeParameter),
            ("Set", .typeParameter), ("Tuple", .typeParameter), ("Deque", .typeParameter),
            ("DefaultDict", .typeParameter), ("Counter", .typeParameter), ("Iterable", .typeParameter),
            ("Iterator", .typeParameter), ("Callable", .typeParameter), ("Any", .typeParameter), ("Union", .typeParameter)
        ],
        "sys": [
            ("argv", .variable), ("exit", .function), ("stdin", .variable), ("stdout", .variable),
            ("stderr", .variable), ("maxsize", .constant), ("setrecursionlimit", .function), ("path", .variable)
        ],
        "os": [
            ("path", .module), ("getcwd", .function), ("listdir", .function), ("makedirs", .function),
            ("environ", .variable), ("getenv", .function), ("remove", .function), ("rename", .function)
        ],
        "re": [
            ("match", .function), ("search", .function), ("fullmatch", .function), ("findall", .function),
            ("finditer", .function), ("sub", .function), ("split", .function), ("compile", .function)
        ],
        "json": [
            ("loads", .function), ("dumps", .function), ("load", .function), ("dump", .function)
        ],
        "pathlib": [
            ("Path", .class), ("PurePath", .class)
        ],
        "random": [
            ("randint", .function), ("random", .function), ("choice", .function),
            ("choices", .function), ("shuffle", .function), ("sample", .function), ("randrange", .function)
        ],
        "string": [
            ("ascii_lowercase", .constant), ("ascii_uppercase", .constant), ("ascii_letters", .constant),
            ("digits", .constant), ("hexdigits", .constant), ("punctuation", .constant), ("whitespace", .constant)
        ],
        "operator": [
            ("add", .function), ("sub", .function), ("mul", .function),
            ("itemgetter", .function), ("attrgetter", .function), ("xor", .function)
        ],
        "dataclasses": [
            ("dataclass", .function), ("field", .function), ("asdict", .function)
        ]
    ]

    static let extraPythonModules: [String] = [
        "argparse", "asyncio", "copy", "csv", "datetime", "enum", "glob",
        "hashlib", "io", "logging", "pickle", "shutil", "socket", "sqlite3",
        "subprocess", "tempfile", "threading", "time", "traceback", "unittest", "urllib", "uuid"
    ]

    static let pythonTypeMembers: [String: [(label: String, kind: LSPCompletionKind)]] = [
        "list": ["append", "extend", "insert", "pop", "remove", "index", "count", "sort", "reverse", "copy", "clear"].map { ($0, .method) },
        "dict": ["get", "keys", "values", "items", "pop", "popitem", "setdefault", "update", "clear", "copy", "fromkeys"].map { ($0, .method) },
        "set": ["add", "remove", "discard", "pop", "union", "intersection", "difference", "symmetric_difference", "update", "issubset", "issuperset", "clear", "copy"].map { ($0, .method) },
        "str": ["split", "join", "strip", "lstrip", "rstrip", "replace", "find", "rfind", "index", "count", "startswith", "endswith", "lower", "upper", "isdigit", "isalpha", "isalnum", "format", "encode"].map { ($0, .method) },
        "deque": ["append", "appendleft", "pop", "popleft", "extend", "extendleft", "rotate", "clear", "count", "index", "insert", "remove", "reverse", "copy"].map { ($0, .method) },
        "Counter": ["most_common", "elements", "subtract", "total", "get", "keys", "values", "items", "update", "clear"].map { ($0, .method) },
        "defaultdict": [("default_factory", .property)] + ["get", "keys", "values", "items", "pop", "setdefault", "update", "clear", "copy"].map { ($0, .method) }
    ]

    static func detectPythonLineContext(beforeCursorOnLine: String) -> PythonLineContext {
        let ns = beforeCursorOnLine as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        if let match = fromImportRegex.firstMatch(in: beforeCursorOnLine, range: fullRange) {
            let modName = ns.substring(with: match.range(at: 1))
            return .importMembers(module: modName)
        }

        if modRegex.firstMatch(in: beforeCursorOnLine, range: fullRange) != nil,
           fromWordRegex.firstMatch(in: beforeCursorOnLine, range: fullRange) == nil {
            return .importModules
        }

        if let match = memberRegex.firstMatch(in: beforeCursorOnLine, range: fullRange) {
            let rawChain = ns.substring(with: match.range(at: 1))
            let parts = rawChain.split(separator: ".").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let target = parts.last ?? rawChain
            let viaSelf = parts.count == 2 && parts.first == "self"
            return .memberAccess(target: target, viaSelf: viaSelf)
        }

        return .general
    }

    static func stripStringsAndComments(from text: String, language: CodeLanguage) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        var i = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var inTripleDouble = false
        var inTripleSingle = false
        var inLineComment = false
        var inBlockComment = false
        var escaped = false

        let usesHashComment = (language == .python || language == .shell || language == .yaml || language == .toml)
        let usesTripleQuotes = (language == .python || language == .swift)

        while i < n {
            let ch = scalars[i]
            let next: UnicodeScalar? = (i + 1 < n) ? scalars[i + 1] : nil
            let next2: UnicodeScalar? = (i + 2 < n) ? scalars[i + 2] : nil

            if inLineComment {
                if ch == "\n" {
                    inLineComment = false
                    output.unicodeScalars.append(ch)
                }
                i += 1
                continue
            }
            if inBlockComment {
                if ch == "*" && next == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    if ch == "\n" { output.unicodeScalars.append(ch) }
                    i += 1
                }
                continue
            }
            if inTripleDouble {
                if escaped {
                    escaped = false
                    i += 1
                } else if ch == "\\" {
                    escaped = true
                    i += 1
                } else if ch == "\"" && next == "\"" && next2 == "\"" {
                    inTripleDouble = false
                    output.append(" ")
                    i += 3
                } else {
                    if ch == "\n" { output.unicodeScalars.append(ch) }
                    i += 1
                }
                continue
            }
            if inTripleSingle {
                if escaped {
                    escaped = false
                    i += 1
                } else if ch == "\\" {
                    escaped = true
                    i += 1
                } else if ch == "'" && next == "'" && next2 == "'" {
                    inTripleSingle = false
                    output.append(" ")
                    i += 3
                } else {
                    if ch == "\n" { output.unicodeScalars.append(ch) }
                    i += 1
                }
                continue
            }
            if inSingleQuote {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "'" {
                    inSingleQuote = false
                    output.append(" ")
                } else if ch == "\n" {
                    inSingleQuote = false
                    output.unicodeScalars.append(ch)
                }
                i += 1
                continue
            }
            if inDoubleQuote {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inDoubleQuote = false
                    output.append(" ")
                } else if ch == "\n" {
                    inDoubleQuote = false
                    output.unicodeScalars.append(ch)
                }
                i += 1
                continue
            }

            if usesHashComment && ch == "#" {
                inLineComment = true
                i += 1
                continue
            }
            if !usesHashComment && ch == "/" && next == "/" {
                inLineComment = true
                i += 2
                continue
            }
            if !usesHashComment && ch == "/" && next == "*" {
                inBlockComment = true
                i += 2
                continue
            }
            if usesTripleQuotes && ch == "\"" && next == "\"" && next2 == "\"" {
                inTripleDouble = true
                i += 3
                continue
            }
            if language == .python && ch == "'" && next == "'" && next2 == "'" {
                inTripleSingle = true
                i += 3
                continue
            }
            if ch == "'" {
                inSingleQuote = true
                i += 1
                continue
            }
            if ch == "\"" {
                inDoubleQuote = true
                i += 1
                continue
            }

            output.unicodeScalars.append(ch)
            i += 1
        }
        return output
    }

    static func collectDocumentIdentifiers(
        in text: String,
        excluding exactPrefix: String,
        language: CodeLanguage = .plainText
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let limited = text.count > 80_000 ? String(text.prefix(80_000)) : text
        let cacheKey = "\(language.rawValue)|\(limited.utf8.count)|\(limited.hashValue)"

        let allIdentifiers: [String]
        if let hit = identifierCache.lookup(key: cacheKey) {
            allIdentifiers = hit
        } else {
            let sanitized = stripStringsAndComments(from: limited, language: language)
            let nsSanitized = sanitized as NSString
            let matches = identifierRegex.matches(in: sanitized, range: NSRange(location: 0, length: nsSanitized.length))
            var seen = Set<String>()
            var collected: [String] = []
            collected.reserveCapacity(min(600, matches.count))
            for m in matches {
                let word = nsSanitized.substring(with: m.range)
                if seen.insert(word).inserted {
                    collected.append(word)
                    if collected.count >= 600 { break }
                }
            }
            identifierCache.store(key: cacheKey, identifiers: collected)
            allIdentifiers = collected
        }

        if exactPrefix.isEmpty {
            return allIdentifiers
        }
        return allIdentifiers.filter { $0 != exactPrefix }
    }

    private static func inferPythonVariableType(for name: String, in text: String, viaSelf: Bool) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let prefix = viaSelf ? #"self\."# : #"(?<![\w.])"#
        let pattern = #"\#(prefix)\#(escapedName)\s*(?::\s*([^=\n,)]+?)\s*)?(?:=(?!=)\s*([^\n]+)|[,\n)])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var found: String?
        for m in matches {
            for idx in [1, 2] {
                let r = m.range(at: idx)
                if r.location != NSNotFound {
                    let expr = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let t = classifyPythonExprType(expr) {
                        found = t
                    }
                }
            }
        }
        return found
    }

    private static func classifyPythonExprType(_ expr: String) -> String? {
        let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("List[") || trimmed.hasPrefix("list[") || trimmed.hasPrefix("list(") || trimmed.hasPrefix("sorted(") || trimmed.hasPrefix("[") {
            return "list"
        }
        if trimmed.hasPrefix("DefaultDict[") || trimmed.hasPrefix("defaultdict(") || trimmed.hasPrefix("collections.defaultdict(") {
            return "defaultdict"
        }
        if trimmed.hasPrefix("Counter") || trimmed.hasPrefix("collections.Counter") {
            return "Counter"
        }
        if trimmed.hasPrefix("Deque") || trimmed.hasPrefix("deque(") || trimmed.hasPrefix("collections.deque(") {
            return "deque"
        }
        if trimmed.hasPrefix("Dict[") || trimmed.hasPrefix("dict[") || trimmed.hasPrefix("dict(") || trimmed == "{}" {
            return "dict"
        }
        if trimmed.hasPrefix("Set[") || trimmed.hasPrefix("set[") || trimmed.hasPrefix("set(") {
            return "set"
        }
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") || trimmed.hasPrefix("str(") {
            return "str"
        }
        return nil
    }

    static func mergeAndRank(
        prefix: String,
        language: CodeLanguage,
        documentText: String,
        lspItems: [LSPCompletionItem],
        beforeCursorOnLine: String? = nil,
        maxItems: Int = 40
    ) -> [LSPCompletionItem] {
        var combined: [LSPCompletionItem] = []
        var seenLabels = Set<String>()

        let pythonContext: PythonLineContext = (language == .python && beforeCursorOnLine != nil)
            ? detectPythonLineContext(beforeCursorOnLine: beforeCursorOnLine ?? "")
            : .general

        for item in lspItems {
            if case .importModules = pythonContext, item.kind == .keyword {
                continue
            }
            if seenLabels.insert(item.label).inserted {
                combined.append(item)
            }
        }

        switch pythonContext {
        case .importModules:
            let allMods = (Array(pythonModuleMembers.keys) + extraPythonModules).sorted()
            for modName in allMods where seenLabels.insert(modName).inserted {
                combined.append(LSPCompletionItem(
                    label: modName,
                    kind: .module,
                    detail: "stdlib",
                    documentation: nil,
                    insertText: modName,
                    filterText: modName,
                    sortText: "zm_\(modName)",
                    isLocalFallback: true
                ))
            }

        case .importMembers(let moduleName):
            for member in (pythonModuleMembers[moduleName] ?? []) where seenLabels.insert(member.label).inserted {
                combined.append(LSPCompletionItem(
                    label: member.label,
                    kind: member.kind,
                    detail: moduleName,
                    documentation: nil,
                    insertText: member.label,
                    filterText: member.label,
                    sortText: "zm_\(member.label)",
                    isLocalFallback: true
                ))
            }

        case .memberAccess(let target, let viaSelf):
            if target == "self" {
                let ns = documentText as NSString
                for m in pythonDefRegex.matches(in: documentText, range: NSRange(location: 0, length: ns.length)) {
                    let name = ns.substring(with: m.range(at: 1))
                    if !name.hasPrefix("__"), seenLabels.insert(name).inserted {
                        combined.append(LSPCompletionItem(
                            label: name, kind: .method, detail: "self", documentation: nil,
                            insertText: name, filterText: name, sortText: "zm_\(name)", isLocalFallback: true
                        ))
                    }
                }
            } else if let modMembers = pythonModuleMembers[target] {
                for member in modMembers where seenLabels.insert(member.label).inserted {
                    combined.append(LSPCompletionItem(
                        label: member.label, kind: member.kind, detail: target, documentation: nil,
                        insertText: member.label, filterText: member.label, sortText: "zm_\(member.label)", isLocalFallback: true
                    ))
                }
            } else if let inferred = inferPythonVariableType(for: target, in: documentText, viaSelf: viaSelf),
                      let members = pythonTypeMembers[inferred] {
                for member in members where seenLabels.insert(member.label).inserted {
                    combined.append(LSPCompletionItem(
                        label: member.label, kind: member.kind, detail: inferred, documentation: nil,
                        insertText: member.label, filterText: member.label, sortText: "zm_\(member.label)", isLocalFallback: true
                    ))
                }
            }

        case .general:
            for kw in keywords(for: language) where seenLabels.insert(kw).inserted {
                combined.append(LSPCompletionItem(
                    label: kw,
                    kind: .keyword,
                    detail: language.rawValue,
                    documentation: nil,
                    insertText: kw,
                    filterText: kw,
                    sortText: "zk_\(kw)",
                    isLocalFallback: true
                ))
            }

            for ident in collectDocumentIdentifiers(in: documentText, excluding: prefix, language: language)
            where seenLabels.insert(ident).inserted {
                combined.append(LSPCompletionItem(
                    label: ident,
                    kind: .variable,
                    detail: nil,
                    documentation: nil,
                    insertText: ident,
                    filterText: ident,
                    sortText: "zy_\(ident)",
                    isLocalFallback: true
                ))
            }
        }

        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        let lowerPrefix = trimmed.lowercased()

        // Schwartzian transform: compute matchRank once per candidate instead of O(N log N) times.
        let scored: [(item: LSPCompletionItem, rank: Int)]
        if lowerPrefix.isEmpty {
            scored = combined.map { ($0, 0) }
        } else {
            scored = combined.compactMap { item in
                guard let rank = matchRank(for: item, trimmedPrefix: trimmed, lowerPrefix: lowerPrefix) else {
                    return nil
                }
                return (item, rank)
            }
        }

        let ranked = scored.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }

            let lhsLSP = !lhs.item.isLocalFallback
            let rhsLSP = !rhs.item.isLocalFallback
            if lhsLSP != rhsLSP { return lhsLSP }

            if lhs.item.sortText != rhs.item.sortText {
                return lhs.item.sortText < rhs.item.sortText
            }
            if lhs.item.label.count != rhs.item.label.count {
                return lhs.item.label.count < rhs.item.label.count
            }
            return lhs.item.label < rhs.item.label
        }

        return Array(ranked.prefix(maxItems).map(\.item))
    }

    /// Lower score = better match; nil = does not match prefix well enough to show.
    private static func matchRank(
        for item: LSPCompletionItem,
        trimmedPrefix: String,
        lowerPrefix: String
    ) -> Int? {
        let primary = item.filterText.isEmpty ? item.label : item.filterText
        let lowerPrimary = primary.lowercased()
        let lowerLabel = item.label.lowercased()

        if primary == trimmedPrefix || item.label == trimmedPrefix {
            return 0
        }
        if primary.hasPrefix(trimmedPrefix) || item.label.hasPrefix(trimmedPrefix) {
            return 1
        }
        if lowerPrimary.hasPrefix(lowerPrefix) || lowerLabel.hasPrefix(lowerPrefix) {
            return 2
        }

        // For short 1-2 character prefixes, require strict prefix match so typing "fr"
        // only shows items starting with "fr" (e.g. from, frozenset), not unrelated substrings.
        guard lowerPrefix.count >= 3 else {
            return nil
        }

        if hasWordBoundaryPrefix(in: primary, lowerPrefix: lowerPrefix)
            || hasWordBoundaryPrefix(in: item.label, lowerPrefix: lowerPrefix) {
            return 3
        }
        if lowerPrimary.contains(lowerPrefix) || lowerLabel.contains(lowerPrefix) {
            return 4
        }
        return nil
    }

    /// Unicode-safe word boundary check operating strictly on original `text` indices.
    static func hasWordBoundaryPrefix(in text: String, lowerPrefix: String) -> Bool {
        guard !lowerPrefix.isEmpty else { return true }
        let chars = Array(text)
        guard !chars.isEmpty else { return false }

        for i in 0..<chars.count {
            let isBoundary: Bool
            if i == 0 {
                isBoundary = true
            } else {
                let prev = chars[i - 1]
                let cur = chars[i]
                isBoundary = prev == "_" || prev == "." || (prev.isLowercase && cur.isUppercase)
            }
            guard isBoundary else { continue }

            // Check if the remainder starting at `i` starts with `lowerPrefix` case-insensitively.
            var remaining = ""
            remaining.reserveCapacity(lowerPrefix.count + 4)
            var j = i
            while j < chars.count && remaining.count < lowerPrefix.count {
                remaining.append(chars[j].lowercased())
                j += 1
            }
            if remaining.hasPrefix(lowerPrefix) {
                return true
            }
        }
        return false
    }
}

// MARK: - Completion State & Popup View

@MainActor
final class CompletionState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var items: [LSPCompletionItem] = []
    @Published var selectedIndex: Int = 0
    @Published var prefixRange: NSRange = NSRange(location: 0, length: 0)
    @Published var renderRevision: Int = 0

    func show(items: [LSPCompletionItem], prefixRange: NSRange) {
        guard !items.isEmpty else {
            dismiss()
            return
        }
        self.items = items
        self.prefixRange = prefixRange
        self.selectedIndex = 0
        self.renderRevision &+= 1
        self.isVisible = true
    }

    func dismiss() {
        isVisible = false
        items = []
        selectedIndex = 0
        renderRevision &+= 1
    }

    func moveUp() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    func moveDown() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    var selectedItem: LSPCompletionItem? {
        guard isVisible, selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }
}

struct CompletionPopupView: View {
    @ObservedObject var state: CompletionState
    @ObservedObject private var themeManager = ThemeManager.shared
    let onAccept: (LSPCompletionItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(state.items.enumerated()), id: \.offset) { idx, item in
                            let isSelected = idx == state.selectedIndex
                            Button {
                                onAccept(item)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.kind.iconName)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundColor(Color(nsColor: NSColor(hex: item.kind.badgeColorHex)))
                                        .frame(width: 16, height: 16)
                                        .background(Color(nsColor: NSColor(hex: item.kind.badgeColorHex)).opacity(0.14))
                                        .cornerRadius(4)

                                    Text(item.label)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .monospaced))
                                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                                        .lineLimit(1)

                                    Spacer(minLength: 8)

                                    if let detail = item.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(Color(nsColor: ZedTheme.mutedText))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(isSelected ? Color(nsColor: ZedTheme.activeTabBackground) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                        }
                    }
                    .padding(4)
                    .id(state.renderRevision)
                }
                .onChange(of: state.selectedIndex) { _, newIdx in
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
        .frame(width: 340, height: min(230, CGFloat(max(1, state.items.count)) * 27 + 10))
        .background(Color(nsColor: ZedTheme.sidebarBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
        )
        .shadow(color: .black.opacity(ZedTheme.isDark ? 0.45 : 0.18), radius: 14, y: 6)
    }
}
