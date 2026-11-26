import Foundation

// MARK: - Find & Replace Pure Logic & State

enum EditorFindEngine {
    static let defaultDisplayMatchLimit = 5000

    static func findMatches(
        in text: String,
        query: String,
        isCaseSensitive: Bool,
        isRegex: Bool,
        limit: Int? = defaultDisplayMatchLimit
    ) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if isRegex {
            let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                return []
            }
            var results: [NSRange] = []
            regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, stop in
                guard let range = match?.range, range.length > 0 else { return }
                results.append(range)
                if let limit, results.count >= limit {
                    stop.pointee = true
                }
            }
            return results
        } else {
            let options: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
            var results: [NSRange] = []
            var searchStart = 0
            while searchStart < nsText.length {
                let searchRange = NSRange(location: searchStart, length: nsText.length - searchStart)
                let found = nsText.range(of: query, options: options, range: searchRange)
                if found.location == NSNotFound || found.length == 0 {
                    break
                }
                results.append(found)
                searchStart = found.location + found.length
                if let limit, results.count >= limit { break }
            }
            return results
        }
    }

    static func replacementString(
        in text: String,
        matchRange: NSRange,
        query: String,
        replacement: String,
        isCaseSensitive: Bool,
        isRegex: Bool
    ) -> String {
        guard isRegex else { return replacement }
        let nsText = text as NSString
        guard matchRange.location >= 0, matchRange.location + matchRange.length <= nsText.length else {
            return replacement
        }
        let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: query, options: options),
              let match = regex.firstMatch(in: text, options: [], range: matchRange),
              match.range == matchRange else {
            return replacement
        }
        return regex.replacementString(for: match, in: text, offset: 0, template: replacement)
    }

    static func replaceAll(
        in text: String,
        query: String,
        replacement: String,
        isCaseSensitive: Bool,
        isRegex: Bool
    ) -> (updatedText: String, count: Int) {
        guard !query.isEmpty, !text.isEmpty else { return (text, 0) }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if isRegex {
            let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                return (text, 0)
            }
            let nonEmptyMatches = regex.matches(in: text, options: [], range: fullRange)
                .filter { $0.range.length > 0 }
            guard !nonEmptyMatches.isEmpty else { return (text, 0) }

            let mutable = NSMutableString(string: text)
            for match in nonEmptyMatches.reversed() {
                let expanded = regex.replacementString(for: match, in: text, offset: 0, template: replacement)
                mutable.replaceCharacters(in: match.range, with: expanded)
            }
            return (mutable as String, nonEmptyMatches.count)
        } else {
            let matches = findMatches(
                in: text,
                query: query,
                isCaseSensitive: isCaseSensitive,
                isRegex: false,
                limit: nil
            )
            guard !matches.isEmpty else { return (text, 0) }
            let mutable = NSMutableString(string: text)
            for range in matches.reversed() {
                mutable.replaceCharacters(in: range, with: replacement)
            }
            return (mutable as String, matches.count)
        }
    }

    static func nextMatchIndex(
        in matches: [NSRange],
        fromCursor cursorLocation: Int,
        forward: Bool
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        if forward {
            if let idx = matches.firstIndex(where: { $0.location >= cursorLocation }) {
                return idx
            }
            return 0
        } else {
            if let idx = matches.lastIndex(where: { $0.location < cursorLocation }) {
                return idx
            }
            return matches.count - 1
        }
    }
}

@MainActor
final class EditorFindState: ObservableObject {
    @Published var isFindBarVisible: Bool = false
    @Published var isReplaceExpanded: Bool = false
    @Published var isGoToLineVisible: Bool = false
    @Published var focusRequestNonce: Int = 0

    @Published var findQuery: String = ""
    @Published var replaceQuery: String = ""
    @Published var goToLineInput: String = ""

    @Published var isCaseSensitive: Bool = false
    @Published var isRegex: Bool = false

    @Published var matches: [NSRange] = []
    @Published var currentMatchIndex: Int = -1

    func recomputeMatches(in text: String, cursorLocation: Int? = nil) {
        let computed = EditorFindEngine.findMatches(
            in: text,
            query: findQuery,
            isCaseSensitive: isCaseSensitive,
            isRegex: isRegex
        )
        matches = computed
        if computed.isEmpty {
            currentMatchIndex = -1
        } else if let cursorLocation {
            currentMatchIndex = EditorFindEngine.nextMatchIndex(
                in: computed,
                fromCursor: cursorLocation,
                forward: true
            ) ?? 0
        } else if currentMatchIndex < 0 || currentMatchIndex >= computed.count {
            currentMatchIndex = 0
        }
    }

    func stepMatch(forward: Bool, cursorLocation: Int) -> NSRange? {
        guard !matches.isEmpty else { return nil }
        if currentMatchIndex >= 0 && currentMatchIndex < matches.count {
            if forward {
                currentMatchIndex = (currentMatchIndex + 1) % matches.count
            } else {
                currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
            }
        } else {
            currentMatchIndex = EditorFindEngine.nextMatchIndex(
                in: matches,
                fromCursor: cursorLocation,
                forward: forward
            ) ?? 0
        }
        return matches[currentMatchIndex]
    }
}
