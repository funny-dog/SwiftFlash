import AppKit
import Foundation

// MARK: - Workspace Search Options & Pure Engine

struct WorkspaceSearchOptions: Equatable, Sendable {
    var caseSensitive: Bool = false
    var wholeWord: Bool = false
    var useRegex: Bool = false
    var includeGlob: String = ""
    var excludeGlob: String = ""
}

struct WorkspaceReplaceSummary: Equatable, Sendable {
    let filesModified: Int
    let replacementsCount: Int
}

enum WorkspaceSearchEngine {
    static func buildRegex(query: String, options: WorkspaceSearchOptions) throws -> NSRegularExpression {
        let basePattern = options.useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        let pattern = options.wholeWord ? "\\b(?:\(basePattern))\\b" : basePattern
        let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        return try NSRegularExpression(pattern: pattern, options: regexOptions)
    }

    /// Matches a relative path against comma-separated glob patterns (e.g. `*.swift, Sources/**`).
    static func matchesGlobs(relativePath: String, rawGlobs: String) -> Bool {
        let patterns = rawGlobs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !patterns.isEmpty else { return true }
        let fileName = (relativePath as NSString).lastPathComponent
        for glob in patterns {
            let target = glob.contains("/") ? relativePath : fileName
            if globMatches(pattern: glob, string: target) || globMatches(pattern: glob, string: relativePath) {
                return true
            }
        }
        return false
    }

    static func globMatches(pattern: String, string: String) -> Bool {
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            if ch == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    if i < pattern.endIndex && pattern[i] == "/" {
                        regex += "(?:.*/)?"
                        i = pattern.index(after: i)
                    }
                    continue
                } else {
                    regex += "[^/]*"
                }
            } else if ch == "?" {
                regex += "[^/]"
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
            i = pattern.index(after: i)
        }
        regex += "$"
        return string.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func searchWithRipgrepIfAvailable(
        query: String,
        options: WorkspaceSearchOptions,
        rootURL: URL,
        maxMatches: Int = 1500
    ) -> [SearchMatch]? {
        guard let rgPath = LSPManager.findExecutableInCommonPaths("rg") else {
            return nil
        }

        var args = ["--line-number", "--no-heading", "--color=never", "--max-filesize", "2M"]
        args.append(options.caseSensitive ? "--case-sensitive" : "--ignore-case")
        if options.wholeWord { args.append("--word-regexp") }
        if !options.useRegex { args.append("--fixed-strings") }

        for glob in options.includeGlob.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !glob.isEmpty {
            args.append(contentsOf: ["--glob", glob])
        }
        for glob in options.excludeGlob.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !glob.isEmpty {
            let neg = glob.hasPrefix("!") ? glob : "!\(glob)"
            args.append(contentsOf: ["--glob", neg])
        }
        args.append(contentsOf: ["--", query, "."])

        let res = ProcessRunner.run(
            executablePath: rgPath,
            arguments: args,
            currentDirectoryURL: rootURL,
            timeoutSeconds: 12
        )
        // rg exit code: 0 = matches found, 1 = no matches, 2 = error
        guard res.exitCode == 0 || res.exitCode == 1 else {
            return nil
        }
        guard res.exitCode == 0 else { return [] }

        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(256, maxMatches))

        for rawLine in res.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            if matches.count >= maxMatches { break }
            let line = String(rawLine)
            guard let firstColon = line.firstIndex(of: ":") else { continue }
            let afterFirst = line.index(after: firstColon)
            guard afterFirst < line.endIndex, let secondColon = line[afterFirst...].firstIndex(of: ":") else { continue }

            var relPath = String(line[..<firstColon])
            if relPath.hasPrefix("./") {
                relPath = String(relPath.dropFirst(2))
            }
            guard let lineNum = Int(line[afterFirst..<secondColon]), lineNum > 0 else { continue }
            let preview = String(line[line.index(after: secondColon)...]).trimmingCharacters(in: .whitespaces)
            let fileURL = rootURL.appendingPathComponent(relPath).standardized

            matches.append(
                SearchMatch(
                    url: fileURL,
                    relativePath: relPath,
                    lineNumber: lineNum,
                    linePreview: preview
                )
            )
        }
        return matches
    }

    static func searchFallback(
        query: String,
        options: WorkspaceSearchOptions,
        files: [URL],
        rootPath: String,
        maxMatches: Int = 1500
    ) throws -> [SearchMatch] {
        let regex = try buildRegex(query: query, options: options)
        let hasInclude = !options.includeGlob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasExclude = !options.excludeGlob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var matches: [SearchMatch] = []
        for url in files {
            if Task.isCancelled { return matches }
            let relPath = url.path.hasPrefix(rootPath + "/")
                ? String(url.path.dropFirst(rootPath.count + 1))
                : url.lastPathComponent

            if hasInclude && !matchesGlobs(relativePath: relPath, rawGlobs: options.includeGlob) {
                continue
            }
            if hasExclude && matchesGlobs(relativePath: relPath, rawGlobs: options.excludeGlob) {
                continue
            }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 2_000_000 {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  !WorkspaceState.isLikelyBinaryData(data),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            let fullNS = content as NSString
            guard regex.firstMatch(in: content, range: NSRange(location: 0, length: fullNS.length)) != nil else {
                continue
            }

            var lineNumber = 0
            content.enumerateLines { lineText, stop in
                if Task.isCancelled {
                    stop = true
                    return
                }
                lineNumber += 1
                let nsLine = lineText as NSString
                if regex.firstMatch(in: lineText, range: NSRange(location: 0, length: nsLine.length)) != nil {
                    matches.append(
                        SearchMatch(
                            url: url,
                            relativePath: relPath,
                            lineNumber: lineNumber,
                            linePreview: lineText.trimmingCharacters(in: .whitespaces)
                        )
                    )
                    if matches.count >= maxMatches {
                        stop = true
                    }
                }
            }
            if matches.count >= maxMatches { break }
        }
        return matches
    }

    static func replaceInContent(
        _ content: String,
        query: String,
        replacement: String,
        options: WorkspaceSearchOptions
    ) throws -> (updated: String, count: Int) {
        let regex = try buildRegex(query: query, options: options)
        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let count = regex.numberOfMatches(in: content, range: fullRange)
        guard count > 0 else { return (content, 0) }
        let template = options.useRegex
            ? replacement
            : NSRegularExpression.escapedTemplate(for: replacement)
        let updated = regex.stringByReplacingMatches(in: content, range: fullRange, withTemplate: template)
        return (updated, count)
    }
}

// MARK: - Debounced Global Workspace Search & Replace

extension WorkspaceState {
    var currentSearchOptions: WorkspaceSearchOptions {
        WorkspaceSearchOptions(
            caseSensitive: searchCaseSensitive,
            wholeWord: searchWholeWord,
            useRegex: searchUseRegex,
            includeGlob: searchIncludeGlob,
            excludeGlob: searchExcludeGlob
        )
    }

    func performGlobalSearch(query: String? = nil, debounceMs: UInt64 = 120) {
        searchTask?.cancel()
        let activeQuery = (query ?? searchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activeQuery.isEmpty else {
            searchResults = []
            searchRegexError = nil
            isSearching = false
            return
        }

        let options = currentSearchOptions
        do {
            _ = try WorkspaceSearchEngine.buildRegex(query: activeQuery, options: options)
            searchRegexError = nil
        } catch {
            searchRegexError = error.localizedDescription
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true
        let files = allWorkspaceFiles
        let root = rootURL
        let rootPath = root.path

        searchTask = Task.detached(priority: .userInitiated) {
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }

            let finalMatches: [SearchMatch]
            if let rgMatches = WorkspaceSearchEngine.searchWithRipgrepIfAvailable(
                query: activeQuery,
                options: options,
                rootURL: root
            ) {
                finalMatches = rgMatches
            } else {
                finalMatches = (try? WorkspaceSearchEngine.searchFallback(
                    query: activeQuery,
                    options: options,
                    files: files,
                    rootPath: rootPath
                )) ?? []
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.searchResults = finalMatches
                self.isSearching = false
            }
        }
    }

    @discardableResult
    func replaceInWorkspaceFiles(
        urls targetURLs: [URL],
        query: String? = nil,
        replacement: String? = nil
    ) -> WorkspaceReplaceSummary {
        let q = (query ?? searchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !targetURLs.isEmpty else {
            return WorkspaceReplaceSummary(filesModified: 0, replacementsCount: 0)
        }
        let rep = replacement ?? globalReplaceQuery
        let options = currentSearchOptions

        var filesModified = 0
        var totalReplacements = 0
        var seenPaths = Set<String>()

        for rawURL in targetURLs {
            let url = rawURL.standardized
            guard seenPaths.insert(url.path).inserted else { continue }

            let openIdx = openTabs.firstIndex(where: { $0.url?.standardized.path == url.path })
            let sourceText: String
            if let openIdx {
                sourceText = openTabs[openIdx].content
            } else if let data = try? Data(contentsOf: url),
                      let decoded = Self.decodeTextFile(data) {
                sourceText = decoded
            } else {
                continue
            }

            guard let result = try? WorkspaceSearchEngine.replaceInContent(
                sourceText,
                query: q,
                replacement: rep,
                options: options
            ), result.count > 0 else {
                continue
            }

            do {
                try result.updated.write(to: url, atomically: true, encoding: .utf8)
                filesModified += 1
                totalReplacements += result.count

                if let openIdx {
                    openTabs[openIdx].replaceBufferAndMarkSaved(result.updated)
                    openTabs[openIdx].externalReloadRevision += 1
                    if isProductionDefaults {
                        LSPManager.shared.notifyDocumentSaved(
                            url: url,
                            language: openTabs[openIdx].language,
                            content: result.updated,
                            workspaceRoot: rootURL
                        )
                    }
                }
            } catch {
                continue
            }
        }

        if filesModified > 0 {
            refreshGitMetadata()
            performGlobalSearch(debounceMs: 0)
            statusMessage = L10n("search.replacedSummaryFormat", totalReplacements, filesModified)
        }
        return WorkspaceReplaceSummary(filesModified: filesModified, replacementsCount: totalReplacements)
    }

    func confirmAndReplaceAllInWorkspace() {
        let uniqueFiles = Array(Set(searchResults.map { $0.url.standardized }))
        guard !uniqueFiles.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = L10n("search.replaceAll.confirmTitleFormat", searchResults.count, uniqueFiles.count)
        alert.informativeText = L10n("search.replaceAll.confirmMessageFormat", searchQuery, globalReplaceQuery)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n("find.replaceAllButton"))
        alert.addButton(withTitle: L10n("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        _ = replaceInWorkspaceFiles(urls: uniqueFiles)
    }
}
