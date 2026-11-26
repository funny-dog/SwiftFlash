import AppKit
import Foundation

// MARK: - External URL Parsing, File CRUD, Save, Termination Guard & Find/Replace

extension WorkspaceState {
    static let maxEditableFileSizeBytes = 20 * 1024 * 1024

    // MARK: - Binary File Detection

    nonisolated static func isLikelyBinaryData(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        // UTF-16 BOM is valid text even though UTF-16 contains 0x00 bytes.
        if data.count >= 2 {
            let b0 = data[data.startIndex]
            let b1 = data[data.index(after: data.startIndex)]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                return false
            }
        }
        let sampleLen = min(data.count, 8192)
        var suspiciousControlCount = 0
        for offset in 0..<sampleLen {
            let byte = data[data.index(data.startIndex, offsetBy: offset)]
            if byte == 0x00 {
                return true
            }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0C && byte != 0x1B {
                suspiciousControlCount += 1
            }
        }
        return sampleLen >= 16 && Double(suspiciousControlCount) / Double(sampleLen) > 0.30
    }

    nonisolated static func decodeTextFile(_ data: Data) -> String? {
        guard !isLikelyBinaryData(data) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - External URL Opening

    nonisolated static func parseExternalURL(_ url: URL) -> ExternalOpenTarget? {
        if url.isFileURL {
            return ExternalOpenTarget(url: url.standardized, line: nil)
        }
        guard url.scheme?.lowercased() == "swiftflash",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        switch components.host?.lowercased() {
        case "file":
            let rawPath = components.path
            guard !rawPath.isEmpty, rawPath != "/" else { return nil }
            let (resolvedPath, line) = resolvePathAndLineSuffix(rawPath)
            guard !resolvedPath.isEmpty, resolvedPath != "/" else { return nil }
            return ExternalOpenTarget(url: URL(fileURLWithPath: resolvedPath).standardized, line: line)

        case "open":
            guard let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
                  !path.isEmpty else {
                return nil
            }
            let line: Int?
            if let lineRaw = components.queryItems?.first(where: { $0.name == "line" })?.value,
               let parsedLine = Int(lineRaw), parsedLine > 0 {
                line = parsedLine
            } else {
                line = nil
            }
            return ExternalOpenTarget(url: URL(fileURLWithPath: path).standardized, line: line)

        default:
            return nil
        }
    }

    private nonisolated static func resolvePathAndLineSuffix(_ rawPath: String) -> (path: String, line: Int?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: rawPath) {
            return (rawPath, nil)
        }
        guard let first = stripTrailingPositiveInt(rawPath) else {
            return (rawPath, nil)
        }
        if fm.fileExists(atPath: first.prefix) {
            return (first.prefix, first.number)
        }
        if let second = stripTrailingPositiveInt(first.prefix) {
            return (second.prefix, second.number)
        }
        return (first.prefix, first.number)
    }

    private nonisolated static func stripTrailingPositiveInt(_ value: String) -> (prefix: String, number: Int)? {
        guard let colonIndex = value.lastIndex(of: ":") else { return nil }
        let suffix = value[value.index(after: colonIndex)...]
        guard !suffix.isEmpty,
              suffix.allSatisfy({ $0.isASCII && $0 >= "0" && $0 <= "9" }),
              let number = Int(suffix),
              number > 0 else {
            return nil
        }
        let prefix = String(value[..<colonIndex])
        guard !prefix.isEmpty, prefix != "/" else { return nil }
        return (prefix, number)
    }

    func openExternalURLs(_ urls: [URL]) {
        var directories: [URL] = []
        var seenDirectoryPaths = Set<String>()
        var files: [ExternalOpenTarget] = []
        var seenFileKeys = Set<String>()

        for url in urls {
            guard let target = Self.parseExternalURL(url) else { continue }
            let stdURL = target.url.standardized
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: stdURL.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                if seenDirectoryPaths.insert(stdURL.path).inserted {
                    directories.append(stdURL)
                }
            } else {
                let dedupeKey = "\(stdURL.path)#\(target.line.map(String.init) ?? "")"
                if seenFileKeys.insert(dedupeKey).inserted {
                    files.append(ExternalOpenTarget(url: stdURL, line: target.line))
                }
            }
        }

        if let primaryDir = directories.first {
            for extraDir in directories.dropFirst() {
                if !windowProjects.contains(where: { $0.standardized.path == extraDir.path }) {
                    windowProjects.append(extraDir)
                }
                recordRecentProject(extraDir)
            }
            if !hasWorkspaceOpen || rootURL.standardized.path != primaryDir.path {
                switchProject(to: primaryDir)
            }
        }

        for fileTarget in files {
            openFile(url: fileTarget.url, atLine: fileTarget.line)
        }
    }

    // MARK: - Open, Create, Rename, Duplicate, Delete Files

    func openFile(
        url: URL,
        atLine line: Int? = nil,
        atColumn column: Int? = nil,
        recordHistory: Bool = true,
        targetPane: EditorPane? = nil
    ) {
        let targetURL = url.standardized
        let resolvedPane = targetPane ?? (isSplitEditorActive ? focusedEditorPane : .primary)

        if recordHistory {
            recordCurrentNavigationLocation()
        }

        if let existingIdx = openTabs.firstIndex(where: { $0.url?.standardized.path == targetURL.path }) {
            let targetID = openTabs[existingIdx].id
            let alreadyShowingInPane: Bool
            if resolvedPane == .secondary && isSplitEditorActive {
                alreadyShowingInPane = (secondaryTabID == targetID)
                secondaryTabID = targetID
                focusedEditorPane = .secondary
            } else {
                alreadyShowingInPane = (activeTabID == targetID)
                activeTabID = targetID
                focusedEditorPane = .primary
            }

            if let line {
                if alreadyShowingInPane {
                    handlers(for: resolvedPane)?.jumpToLocation?(line, column)
                } else {
                    openTabs[existingIdx].pendingJumpLine = line
                    openTabs[existingIdx].pendingJumpColumn = column
                }
            }
            refreshTasksForCurrentContext()
            refreshActiveDocumentSymbols()
            handlers(for: resolvedPane)?.focusEditor?()
            persistCurrentProjectSession()
            return
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: targetURL.path),
           let fileSize = attrs[.size] as? Int,
           fileSize > Self.maxEditableFileSizeBytes {
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
            statusMessage = L10n("status.fileTooLargeFormat", formatted, targetURL.lastPathComponent)
            return
        }

        let startTime = DispatchTime.now().uptimeNanoseconds
        let data: Data
        do {
            data = try Data(contentsOf: targetURL)
        } catch {
            statusMessage = L10n("status.failedOpenFileFormat", targetURL.lastPathComponent, error.localizedDescription)
            return
        }

        guard let content = Self.decodeTextFile(data) else {
            statusMessage = L10n("status.binaryFileFormat", targetURL.lastPathComponent)
            return
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000.0
        let tab = EditorTab(
            id: UUID(),
            url: targetURL,
            title: targetURL.lastPathComponent,
            content: content,
            savedContent: content,
            language: CodeLanguage.detect(from: targetURL),
            pendingJumpLine: line,
            pendingJumpColumn: column
        )
        openTabs.append(tab)
        if resolvedPane == .secondary && isSplitEditorActive {
            secondaryTabID = tab.id
            focusedEditorPane = .secondary
        } else {
            activeTabID = tab.id
            focusedEditorPane = .primary
        }
        updateRenderLatency(elapsedMs)
        statusMessage = L10n("status.openedFileFormat", targetURL.lastPathComponent, elapsedMs)
        refreshTasksForCurrentContext()
        connectTabToLSP(tab)
        refreshActiveDocumentSymbols()
        handlers(for: resolvedPane)?.focusEditor?()
        persistCurrentProjectSession()
    }

    func createNewUntitledFile() {
        let count = openTabs.filter { $0.url == nil && $0.virtualKey == nil }.count + 1
        let tab = EditorTab(
            id: UUID(),
            url: nil,
            title: count == 1 ? "Untitled.swift" : "Untitled-\(count).swift",
            content: "",
            savedContent: "",
            language: .swift
        )
        openTabs.append(tab)
        activeTabID = tab.id
        statusMessage = L10n("status.createdBuffer")
        onFocusEditorRequested?()
    }

    func validatedRelativeURL(named rawName: String, inside baseDir: URL) -> URL? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\0") else {
            return nil
        }
        let segments = trimmed.split(separator: "/")
        guard !segments.isEmpty,
              segments.allSatisfy({ $0 != "." && $0 != ".." }) else {
            return nil
        }
        let normalizedBase = baseDir.standardizedFileURL
        let candidate = normalizedBase.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path.hasPrefix(normalizedBase.path + "/") else {
            return nil
        }
        return candidate
    }

    func createFileInWorkspace(named fileName: String, inside directory: URL? = nil) {
        let baseDir = (directory ?? rootURL).standardizedFileURL
        guard let targetURL = validatedRelativeURL(named: fileName, inside: baseDir) else {
            statusMessage = L10n("status.invalidPath")
            return
        }
        let parentDir = targetURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try "".write(to: targetURL, atomically: true, encoding: .utf8)
                reloadWorkspace(ensuringExpanded: [baseDir, parentDir])
                statusMessage = L10n("status.createdFileFormat", targetURL.lastPathComponent)
            }
            openFile(url: targetURL)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    // MARK: - Explorer Context Menu File Operations

    func promptNewFile(inside directory: URL) {
        let targetDir = directory.standardizedFileURL
        let folderDisplay = targetDir.path == rootURL.standardized.path ? rootURL.lastPathComponent : targetDir.lastPathComponent
        guard let name = promptForName(
            title: L10n("explorer.dialog.newFileTitle"),
            message: L10n("explorer.dialog.newFileMessage", folderDisplay),
            defaultValue: "",
            placeholder: L10n("explorer.dialog.newFilePlaceholder"),
            confirmTitle: L10n("explorer.dialog.create")
        ) else { return }

        guard let targetURL = validatedRelativeURL(named: name, inside: targetDir) else {
            statusMessage = L10n("status.invalidPath")
            return
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) {
            if isDir.boolValue {
                statusMessage = L10n("status.itemExistsFormat", targetURL.lastPathComponent)
            } else {
                openFile(url: targetURL)
            }
            return
        }

        createFileInWorkspace(named: name, inside: targetDir)
    }

    func promptNewFolder(inside directory: URL) {
        let targetDir = directory.standardizedFileURL
        let folderDisplay = targetDir.path == rootURL.standardized.path ? rootURL.lastPathComponent : targetDir.lastPathComponent
        guard let name = promptForName(
            title: L10n("explorer.dialog.newFolderTitle"),
            message: L10n("explorer.dialog.newFolderMessage", folderDisplay),
            defaultValue: "",
            placeholder: L10n("explorer.dialog.newFolderPlaceholder"),
            confirmTitle: L10n("explorer.dialog.create")
        ) else { return }

        guard let targetURL = validatedRelativeURL(named: name, inside: targetDir) else {
            statusMessage = L10n("status.invalidPath")
            return
        }
        if FileManager.default.fileExists(atPath: targetURL.path) {
            statusMessage = L10n("status.itemExistsFormat", targetURL.lastPathComponent)
            return
        }

        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            reloadWorkspace(ensuringExpanded: [targetDir, targetURL])
            statusMessage = L10n("status.createdFolderFormat", targetURL.lastPathComponent)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    func promptRenameItem(at url: URL, isDirectory: Bool) {
        let sourceURL = url.standardized
        let oldName = sourceURL.lastPathComponent
        guard let newName = promptForName(
            title: L10n("explorer.dialog.renameTitle", oldName),
            message: L10n("explorer.dialog.renameMessage"),
            defaultValue: oldName,
            placeholder: oldName,
            confirmTitle: L10n("explorer.dialog.renameConfirm"),
            selectStemOnly: !isDirectory
        ) else { return }

        guard newName != oldName else { return }
        guard !newName.contains("/"), !newName.contains("\0"), newName != ".", newName != ".." else {
            statusMessage = L10n("status.invalidPath")
            return
        }

        let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName).standardized
        let isCaseOnlyRename = oldName.caseInsensitiveCompare(newName) == .orderedSame
        if !isCaseOnlyRename && FileManager.default.fileExists(atPath: destURL.path) {
            statusMessage = L10n("status.itemExistsFormat", newName)
            return
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            updateOpenTabsForRenamedItem(from: sourceURL, to: destURL, isDirectory: isDirectory)
            reloadWorkspace(replacingExpandedPrefix: isDirectory ? (sourceURL, destURL) : nil)
            statusMessage = L10n("status.renamedFormat", newName)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    func duplicateItem(at url: URL, isDirectory: Bool) {
        let sourceURL = url.standardized
        let parentDir = sourceURL.deletingLastPathComponent()
        let fm = FileManager.default

        let ext = isDirectory ? "" : sourceURL.pathExtension
        let stem = isDirectory ? sourceURL.lastPathComponent : (sourceURL.lastPathComponent as NSString).deletingPathExtension

        func candidateName(index: Int) -> String {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            return ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
        }

        var copyIndex = 1
        var destURL = parentDir.appendingPathComponent(candidateName(index: copyIndex)).standardized
        while fm.fileExists(atPath: destURL.path) {
            copyIndex += 1
            destURL = parentDir.appendingPathComponent(candidateName(index: copyIndex)).standardized
        }

        do {
            try fm.copyItem(at: sourceURL, to: destURL)
            reloadWorkspace(ensuringExpanded: [parentDir])
            if !isDirectory {
                openFile(url: destURL)
            }
            statusMessage = L10n("status.duplicatedFormat", destURL.lastPathComponent)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    func promptDeleteItem(at url: URL, isDirectory: Bool) {
        let targetURL = url.standardized
        let alert = NSAlert()
        alert.messageText = L10n("explorer.dialog.deleteTitle", targetURL.lastPathComponent)
        alert.informativeText = isDirectory
            ? L10n("explorer.dialog.deleteFolderMessage")
            : L10n("explorer.dialog.deleteFileMessage")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n("explorer.dialog.deleteConfirm"))
        alert.addButton(withTitle: L10n("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
            closeOpenTabsForDeletedItem(at: targetURL, isDirectory: isDirectory)
            reloadWorkspace()
            statusMessage = L10n("status.movedToTrashFormat", targetURL.lastPathComponent)
        } catch {
            statusMessage = L10n("status.fileOpFailedFormat", error.localizedDescription)
        }
    }

    func copyPathToPasteboard(_ url: URL, relative: Bool) {
        let value = relative ? relativePath(for: url.standardized) : url.standardized.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusMessage = L10n("status.copiedPathFormat", value)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url.standardized])
    }

    private func promptForName(
        title: String,
        message: String,
        defaultValue: String,
        placeholder: String,
        confirmTitle: String,
        selectStemOnly: Bool = false
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L10n("common.cancel"))

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 24))
        inputField.stringValue = defaultValue
        inputField.placeholderString = placeholder
        inputField.bezelStyle = .roundedBezel
        inputField.usesSingleLineMode = true
        inputField.lineBreakMode = .byTruncatingHead
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        DispatchQueue.main.async {
            alert.window.makeFirstResponder(inputField)
            if selectStemOnly && !defaultValue.isEmpty, let editor = inputField.currentEditor() {
                let stemLength = (defaultValue as NSString).deletingPathExtension.count
                if stemLength > 0 && !defaultValue.hasPrefix(".") && stemLength < defaultValue.count {
                    editor.selectedRange = NSRange(location: 0, length: stemLength)
                } else {
                    editor.selectAll(nil)
                }
            }
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func updateOpenTabsForRenamedItem(from oldURL: URL, to newURL: URL, isDirectory: Bool) {
        let oldPath = oldURL.standardized.path
        let newPath = newURL.standardized.path

        // Remove stale diagnostics for old path(s).
        var diagChanged = false
        for diagPath in Array(diagnosticsByFile.keys) {
            if diagPath == oldPath || (isDirectory && diagPath.hasPrefix(oldPath + "/")) {
                diagnosticsByFile.removeValue(forKey: diagPath)
                diagChanged = true
            }
        }
        if diagChanged {
            onDiagnosticsUpdated?()
        }

        for idx in openTabs.indices {
            guard let oldTabURL = openTabs[idx].url else { continue }
            let tabPath = oldTabURL.standardized.path
            let updatedURL: URL?
            if tabPath == oldPath {
                updatedURL = newURL
            } else if isDirectory && tabPath.hasPrefix(oldPath + "/") {
                let suffix = String(tabPath.dropFirst(oldPath.count + 1))
                updatedURL = newURL.appendingPathComponent(suffix).standardized
            } else {
                updatedURL = nil
            }

            if let updatedURL {
                let oldLang = openTabs[idx].language
                if isProductionDefaults {
                    LSPManager.shared.notifyDocumentClosed(url: oldTabURL, language: oldLang, workspaceRoot: rootURL)
                }
                openTabs[idx].url = updatedURL
                openTabs[idx].title = updatedURL.lastPathComponent
                openTabs[idx].language = CodeLanguage.detect(from: updatedURL)
                // Force editor container to resync language & re-highlight if extension changed.
                openTabs[idx].externalReloadRevision += 1
                connectTabToLSP(openTabs[idx])
            }
        }
        _ = newPath
    }

    func closeOpenTabsForDeletedItem(at deletedURL: URL, isDirectory: Bool) {
        let deletedPath = deletedURL.standardized.path

        var diagChanged = false
        for diagPath in Array(diagnosticsByFile.keys) {
            if diagPath == deletedPath || (isDirectory && diagPath.hasPrefix(deletedPath + "/")) {
                diagnosticsByFile.removeValue(forKey: diagPath)
                diagChanged = true
            }
        }
        if diagChanged {
            onDiagnosticsUpdated?()
        }

        let affectedTabs = openTabs.filter { tab in
            guard let tabPath = tab.url?.standardized.path else { return false }
            return tabPath == deletedPath || (isDirectory && tabPath.hasPrefix(deletedPath + "/"))
        }
        for tab in affectedTabs {
            if let tabURL = tab.url, isProductionDefaults {
                LSPManager.shared.notifyDocumentClosed(url: tabURL, language: tab.language, workspaceRoot: rootURL)
            }
            tabViewStates.removeValue(forKey: tab.id)
        }

        openTabs.removeAll { tab in
            guard let tabPath = tab.url?.standardized.path else { return false }
            return tabPath == deletedPath || (isDirectory && tabPath.hasPrefix(deletedPath + "/"))
        }
        if let activeTabID, !openTabs.contains(where: { $0.id == activeTabID }) {
            self.activeTabID = openTabs.last?.id
        }
    }

    // MARK: - Save & Application Termination Guard

    @discardableResult
    func saveActiveTab() -> Bool {
        guard let targetID = focusedTabID,
              let idx = openTabs.firstIndex(where: { $0.id == targetID }) else { return false }
        return saveTab(at: idx)
    }

    func saveActiveTabWithOptionalFormatting() {
        guard let tab = focusedTab, tab.virtualKey == nil else {
            _ = saveActiveTab()
            return
        }
        if ThemeManager.shared.formatOnSave && isProductionDefaults {
            formatActiveDocument { [weak self] in
                _ = self?.saveActiveTab()
            }
        } else {
            _ = saveActiveTab()
        }
    }

    @discardableResult
    private func saveTab(at idx: Int) -> Bool {
        guard openTabs.indices.contains(idx) else { return false }
        var tab = openTabs[idx]
        if tab.virtualKey != nil {
            statusMessage = L10n("status.diffReadOnly")
            return false
        }

        let wasNewFile = (tab.url == nil)
        if tab.url == nil {
            let panel = NSSavePanel()
            panel.directoryURL = rootURL
            panel.nameFieldStringValue = tab.title
            guard panel.runModal() == .OK, let chosenURL = panel.url else { return false }
            tab.url = chosenURL.standardized
            tab.title = chosenURL.lastPathComponent
            tab.language = CodeLanguage.detect(from: chosenURL)
            tab.externalReloadRevision += 1
        }

        guard let targetURL = tab.url else { return false }
        do {
            let startTime = DispatchTime.now().uptimeNanoseconds
            try tab.content.write(to: targetURL, atomically: true, encoding: .utf8)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000.0
            tab.replaceBufferAndMarkSaved(tab.content)
            openTabs[idx] = tab
            statusMessage = L10n("status.savedFileFormat", tab.title, elapsedMs)
            if isProductionDefaults {
                if wasNewFile {
                    connectTabToLSP(tab)
                } else {
                    LSPManager.shared.notifyDocumentSaved(
                        url: targetURL,
                        language: tab.language,
                        content: tab.content,
                        workspaceRoot: rootURL
                    )
                }
            }
            if wasNewFile {
                reloadWorkspace(ensuringExpanded: [targetURL.deletingLastPathComponent()])
            } else {
                // Fast path: overwriting an existing file only needs Git status refresh,
                // not a full 8,000-file index and FileItem tree rebuild.
                refreshGitMetadata()
            }
            return true
        } catch {
            statusMessage = L10n("status.saveFailedFormat", error.localizedDescription)
            return false
        }
    }

    func dirtyTabCountAcrossAllSessions() -> Int {
        var count = openTabs.filter(\.isDirty).count
        let currentKey = rootURL.standardized.path
        for (key, snapshot) in projectSessions where key != currentKey {
            count += snapshot.openTabs.filter(\.isDirty).count
        }
        return count
    }

    /// Prompts the user before quitting if any tab (including background project snapshots) has unsaved changes.
    /// Returns `true` if termination may proceed, or `false` if cancelled.
    func confirmTerminationWithUnsavedChanges() -> Bool {
        let dirtyCount = dirtyTabCountAcrossAllSessions()
        guard dirtyCount > 0 else { return true }

        let alert = NSAlert()
        alert.messageText = L10n("alert.unsavedQuit.titleFormat", dirtyCount)
        alert.informativeText = L10n("alert.unsavedQuit.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n("alert.unsavedQuit.saveAll"))
        alert.addButton(withTitle: L10n("alert.unsavedQuit.quitWithoutSaving"))
        alert.addButton(withTitle: L10n("common.cancel"))

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            return true
        }
        if response == .alertThirdButtonReturn {
            return false
        }

        // Save all dirty tabs in the current workspace first.
        for idx in openTabs.indices where openTabs[idx].isDirty {
            if !saveTab(at: idx) {
                return false
            }
        }
        // Save any dirty tabs stored in cached background project sessions.
        let currentKey = rootURL.standardized.path
        for (sessionKey, var snapshot) in projectSessions where sessionKey != currentKey {
            for idx in snapshot.openTabs.indices where snapshot.openTabs[idx].isDirty {
                var tab = snapshot.openTabs[idx]
                if tab.url == nil {
                    let panel = NSSavePanel()
                    panel.directoryURL = URL(fileURLWithPath: sessionKey)
                    panel.nameFieldStringValue = tab.title
                    guard panel.runModal() == .OK, let chosen = panel.url else {
                        return false
                    }
                    tab.url = chosen.standardized
                }
                guard let url = tab.url else { return false }
                do {
                    try tab.content.write(to: url, atomically: true, encoding: .utf8)
                    tab.replaceBufferAndMarkSaved(tab.content)
                    snapshot.openTabs[idx] = tab
                } catch {
                    statusMessage = L10n("status.saveFailedFormat", error.localizedDescription)
                    return false
                }
            }
            projectSessions[sessionKey] = snapshot
        }
        return true
    }

    // MARK: - In-File Find & Replace + Go to Line

    func presentFindBar(replace: Bool) {
        guard let tab = focusedTab else { return }
        findState.isGoToLineVisible = false
        findState.isFindBarVisible = true
        if replace {
            findState.isReplaceExpanded = true
        }
        let selRange = selectedRange(for: tab.id)
        if selRange.length > 0 {
            let ns = tab.content as NSString
            if selRange.location >= 0 && selRange.location + selRange.length <= ns.length {
                let selected = ns.substring(with: selRange)
                if !selected.contains("\n"), !selected.isEmpty {
                    findState.findQuery = selected
                }
            }
        }
        findState.focusRequestNonce &+= 1
        recomputeFindMatches()
    }

    func presentGoToLine() {
        guard focusedTab != nil else { return }
        findState.isFindBarVisible = false
        findState.isGoToLineVisible = true
        findState.goToLineInput = ""
        findState.focusRequestNonce &+= 1
    }

    func closeFindAndGoToLine() {
        findState.isFindBarVisible = false
        findState.isGoToLineVisible = false
        onFindMatchesChanged?()
        onFocusEditorRequested?()
    }

    func recomputeFindMatches(fromCursor overrideCursor: Int? = nil) {
        guard let tab = focusedTab else {
            findState.matches = []
            findState.currentMatchIndex = -1
            onFindMatchesChanged?()
            return
        }
        let cursor = overrideCursor ?? selectedRange(for: tab.id).location
        findState.recomputeMatches(in: tab.content, cursorLocation: cursor)
        onFindMatchesChanged?()
    }

    func findNextInActiveFile() {
        guard let tab = focusedTab else { return }
        if findState.matches.isEmpty && !findState.findQuery.isEmpty {
            recomputeFindMatches()
        }
        let sel = selectedRange(for: tab.id)
        if let range = findState.stepMatch(forward: true, cursorLocation: sel.location + sel.length) {
            onHighlightRangeRequested?(range)
            onFindMatchesChanged?()
        }
    }

    func findPreviousInActiveFile() {
        guard let tab = focusedTab else { return }
        if findState.matches.isEmpty && !findState.findQuery.isEmpty {
            recomputeFindMatches()
        }
        let sel = selectedRange(for: tab.id)
        if let range = findState.stepMatch(forward: false, cursorLocation: sel.location) {
            onHighlightRangeRequested?(range)
            onFindMatchesChanged?()
        }
    }

    func replaceCurrentInActiveFile() {
        guard let tab = focusedTab, tab.virtualKey == nil, !findState.matches.isEmpty else { return }
        let idx = (findState.currentMatchIndex >= 0 && findState.currentMatchIndex < findState.matches.count)
            ? findState.currentMatchIndex
            : 0
        let targetRange = findState.matches[idx]
        let expandedReplacement = EditorFindEngine.replacementString(
            in: tab.content,
            matchRange: targetRange,
            query: findState.findQuery,
            replacement: findState.replaceQuery,
            isCaseSensitive: findState.isCaseSensitive,
            isRegex: findState.isRegex
        )
        let advanceCursorTo = targetRange.location + (expandedReplacement as NSString).length
        onReplaceTextInActiveEditor?(targetRange, expandedReplacement)
        // Advance past the inserted text so replacements containing the query (e.g. `foo` -> `foobar`) never loop in place.
        recomputeFindMatches(fromCursor: advanceCursorTo)
        if let nextRange = findState.matches.indices.contains(findState.currentMatchIndex)
            ? findState.matches[findState.currentMatchIndex]
            : findState.matches.first {
            onHighlightRangeRequested?(nextRange)
        }
    }

    func replaceAllInActiveFile() {
        guard let tab = focusedTab, tab.virtualKey == nil, !findState.findQuery.isEmpty else { return }
        let result = EditorFindEngine.replaceAll(
            in: tab.content,
            query: findState.findQuery,
            replacement: findState.replaceQuery,
            isCaseSensitive: findState.isCaseSensitive,
            isRegex: findState.isRegex
        )
        guard result.count > 0 else { return }
        onReplaceAllTextInActiveEditor?(result.updatedText)
        recomputeFindMatches()
        statusMessage = L10n("find.replacedAllCountFormat", result.count)
    }

    func commitGoToLine() {
        let trimmed = findState.goToLineInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = Int(trimmed), line > 0 {
            recordCurrentNavigationLocation()
            onJumpToLocationRequested?(line, nil)
        }
        findState.isGoToLineVisible = false
        findState.goToLineInput = ""
        onFocusEditorRequested?()
    }
}
