import Foundation

// MARK: - Find & Replace Pure Logic & State

struct FindMatchResult: Equatable {
    let range: NSRange
}

enum EditorFindEngine {
    static func findMatches(
        in text: String,
        query: String,
        isCaseSensitive: Bool,
        isRegex: Bool
    ) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        if isRegex {
            let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                return []
            }
            return regex.matches(in: text, options: [], range: fullRange)
                .map(\.range)
                .filter { $0.length > 0 }
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
                if results.count >= 5000 { break }
            }
            return results
        }
    }

    static func replaceAll(
        in text: String,
        query: String,
        replacement: String,
        isCaseSensitive: Bool,
        isRegex: Bool
    ) -> (updatedText: String, count: Int) {
        let matches = findMatches(in: text, query: query, isCaseSensitive: isCaseSensitive, isRegex: isRegex)
        guard !matches.isEmpty else { return (text, 0) }

        if isRegex {
            let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: query, options: options) else {
                return (text, 0)
            }
            let mutable = NSMutableString(string: text)
            let count = regex.replaceMatches(
                in: mutable,
                options: [],
                range: NSRange(location: 0, length: mutable.length),
                withTemplate: replacement
            )
            return (mutable as String, count)
        } else {
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
