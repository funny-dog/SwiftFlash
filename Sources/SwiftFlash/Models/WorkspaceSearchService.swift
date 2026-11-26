import Foundation

// MARK: - Debounced Global Workspace Search

extension WorkspaceState {
    func performGlobalSearch(query: String, debounceMs: UInt64 = 120) {
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
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }

            var matches: [SearchMatch] = []

            for url in files {
                if Task.isCancelled { return }
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 2_000_000 {
                    continue
                }
                guard let data = try? Data(contentsOf: url),
                      !WorkspaceState.isLikelyBinaryData(data),
                      let content = String(data: data, encoding: .utf8) else {
                    continue
                }
                // Case-insensitive search directly without allocating a lowercased copy of the whole file.
                guard content.range(of: trimmed, options: .caseInsensitive) != nil else { continue }

                let relPath = url.path.hasPrefix(rootPath + "/")
                    ? String(url.path.dropFirst(rootPath.count + 1))
                    : url.lastPathComponent

                var lineNumber = 0
                content.enumerateLines { lineText, stop in
                    if Task.isCancelled {
                        stop = true
                        return
                    }
                    lineNumber += 1
                    if lineText.range(of: trimmed, options: .caseInsensitive) != nil {
                        matches.append(
                            SearchMatch(
                                url: url,
                                relativePath: relPath,
                                lineNumber: lineNumber,
                                linePreview: lineText.trimmingCharacters(in: .whitespaces)
                            )
                        )
                        if matches.count >= 250 {
                            stop = true
                        }
                    }
                }
                if matches.count >= 250 { break }
            }

            guard !Task.isCancelled else { return }
            let finalMatches = matches
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.searchResults = finalMatches
                self.isSearching = false
            }
        }
    }
}
