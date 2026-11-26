import CryptoKit
import Foundation

// MARK: - LSP Storage

enum LSPStorage {
    static var rootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("SwiftFlash", isDirectory: true)
            .appendingPathComponent("LSP", isDirectory: true)
            .standardizedFileURL
    }

    static func serverDirectory(id: String) -> URL {
        rootDirectory.appendingPathComponent(id, isDirectory: true)
    }
}

// MARK: - LSPManager

@MainActor
final class LSPManager: ObservableObject {
    static let shared = LSPManager()

    @Published private(set) var statuses: [String: LSPServerStatus] = [:]
    @Published private(set) var activeServerIDs: Set<String> = []
    @Published private(set) var isScanningStatuses: Bool = false
    @Published var lastErrorMessage: String?

    private var sessions: [String: LSPServerConnection] = [:]
    private var startingTasks: [String: Task<LSPServerConnection?, Never>] = [:]

    /// Per-session document version & last synced content maps so terminating one LSP
    /// never corrupts version tracking of other active language servers.
    private var openDocumentVersionsBySession: [String: [String: Int]] = [:]
    private var lastSentDocumentContentsBySession: [String: [String: String]] = [:]
    private var latestDocumentContents: [String: String] = [:]
    private var pendingChangeTasks: [String: Task<Void, Never>] = [:]

    private var hasScannedInitialStatuses = false
    private var refreshTask: Task<Void, Never>?

    static let diagnosticsDidUpdateNotification = Notification.Name("dev.swiftflash.lsp.diagnosticsDidUpdate")
    static let serverBecameReadyNotification = Notification.Name("dev.swiftflash.lsp.serverBecameReady")

    var onDiagnosticsReceived: ((URL, [LSPDiagnostic]) -> Void)?
    var onServerBecameReady: (() -> Void)?

    private init() {
        // Keep singleton initialization side-effect free so Swift Concurrency tasks
        // on MainActor never re-enter dispatch_once while subprocesses pump RunLoop.
    }

    // MARK: - Server Discovery & Status

    func refreshStatuses() {
        Task { [weak self] in
            await self?.refreshStatusesAsync()
        }
    }

    func ensureStatusesScanned() async {
        guard !hasScannedInitialStatuses else { return }
        await refreshStatusesAsync()
    }

    func refreshStatusesAsync() async {
        if let existing = refreshTask {
            await existing.value
            return
        }

        isScanningStatuses = true

        let task = Task<Void, Never> { [weak self] in
            let probed = await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: LSPStorage.rootDirectory, withIntermediateDirectories: true)
                return Self.probeAllStatuses()
            }.value

            guard let self else { return }
            let previouslyReady = Set(self.statuses.filter { $0.value.isReady }.keys)
            var updated = self.statuses
            for def in LSPServerCatalog.all {
                if case .installing = self.statuses[def.id] {
                    continue
                }
                updated[def.id] = probed[def.id] ?? .notInstalled
            }
            self.statuses = updated
            self.hasScannedInitialStatuses = true
            self.isScanningStatuses = false
            self.refreshTask = nil

            let newlyReady = Set(updated.filter { $0.value.isReady }.keys).subtracting(previouslyReady)
            if !newlyReady.isEmpty {
                self.onServerBecameReady?()
                NotificationCenter.default.post(name: Self.serverBecameReadyNotification, object: self)
            }
        }

        refreshTask = task
        await task.value
    }

    func status(for serverID: String) -> LSPServerStatus {
        statuses[serverID] ?? .notInstalled
    }

    func serverDefinition(for language: CodeLanguage, url: URL? = nil) -> LSPServerDefinition? {
        switch language {
        case .swift:
            return LSPServerCatalog.definition(forID: "sourcekit-lsp")
        case .rust:
            return LSPServerCatalog.definition(forID: "rust-analyzer")
        case .c:
            let clangdDef = LSPServerCatalog.definition(forID: "clangd")
            if let clangdDef, status(for: clangdDef.id).isReady {
                return clangdDef
            }
            if let sourcekitDef = LSPServerCatalog.definition(forID: "sourcekit-lsp"),
               status(for: sourcekitDef.id).isReady {
                return sourcekitDef
            }
            return clangdDef
        case .typescript, .javascript:
            return LSPServerCatalog.definition(forID: "typescript-language-server")
        case .python:
            return LSPServerCatalog.definition(forID: "pyright")
        case .go:
            return LSPServerCatalog.definition(forID: "gopls")
        default:
            return nil
        }
    }

    func lspLanguageID(for language: CodeLanguage, url: URL?) -> String? {
        switch language {
        case .swift: return "swift"
        case .rust: return "rust"
        case .python: return "python"
        case .typescript:
            let ext = url?.pathExtension.lowercased() ?? ""
            return ext == "tsx" ? "typescriptreact" : "typescript"
        case .javascript:
            let ext = url?.pathExtension.lowercased() ?? ""
            return ext == "jsx" ? "javascriptreact" : "javascript"
        case .go: return "go"
        case .c:
            let ext = url?.pathExtension.lowercased() ?? ""
            if ext == "m" { return "objective-c" }
            if ext == "mm" { return "objective-cpp" }
            return ["cpp", "cc", "cxx", "hpp", "hh"].contains(ext) ? "cpp" : "c"
        default:
            return nil
        }
    }

    // MARK: - Install & Uninstall

    func installServer(id: String) async {
        guard let def = LSPServerCatalog.definition(forID: id) else { return }
        if case .installing = statuses[id] { return }

        lastErrorMessage = nil
        updateInstallProgress(id: id, message: L10n("lsp.status.preparing"), fraction: nil, detail: nil)

        do {
            let dir = LSPStorage.serverDirectory(id: id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            switch def.installStrategy {
            case .systemToolchain(let xcrunTool):
                updateInstallProgress(id: id, message: L10n("lsp.status.detecting"), fraction: nil, detail: nil)
                let exeName = def.executableName
                let resolved = await Task.detached(priority: .userInitiated) {
                    Self.resolveViaXcrun(xcrunTool) ?? Self.findExecutableInCommonPaths(exeName)
                }.value
                if let resolved {
                    statuses[id] = .detected(path: resolved)
                    onServerBecameReady?()
                    return
                }
                throw NSError(
                    domain: "SwiftFlashLSP",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L10n("lsp.error.xcodeToolsRequired", def.manualInstallHint)]
                )

            case .githubGzipBinary(let urlString, let expectedSHA):
                guard let url = URL(string: urlString) else {
                    throw URLError(.badURL)
                }
                let downloadMsg = L10n("lsp.status.downloading")
                updateInstallProgress(id: id, message: downloadMsg, fraction: 0.0, detail: nil)
                let downloadedFile = try await Self.downloadToTempFile(from: url) { [weak self] fraction, detail in
                    Task { @MainActor [weak self] in
                        self?.updateInstallProgress(id: id, message: downloadMsg, fraction: fraction, detail: detail)
                    }
                }
                defer { try? FileManager.default.removeItem(at: downloadedFile) }

                if let expectedSHA, !expectedSHA.isEmpty {
                    let actual = try await Task.detached(priority: .userInitiated) {
                        try Self.sha256Hex(ofFileAt: downloadedFile)
                    }.value
                    guard actual.lowercased() == expectedSHA.lowercased() else {
                        throw NSError(
                            domain: "SwiftFlashLSP",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: L10n("lsp.error.checksumMismatch")]
                        )
                    }
                }

                updateInstallProgress(id: id, message: L10n("lsp.status.extracting"), fraction: 1.0, detail: nil)
                let destBinary = dir.appendingPathComponent(def.executableName)
                try await Task.detached(priority: .userInitiated) {
                    try Self.extractGzipBinary(fromFile: downloadedFile, to: destBinary)
                }.value
                statuses[id] = .installed(path: destBinary.path)

            case .githubLatestZipBinary(let repo, let assetPrefix, let binaryRelativePath):
                updateInstallProgress(id: id, message: L10n("lsp.status.fetchingRelease"), fraction: nil, detail: nil)
                let downloadURL = try await Self.resolveLatestGitHubAssetURL(
                    repo: repo,
                    prefix: assetPrefix,
                    suffix: ".zip"
                )
                let downloadMsg = L10n("lsp.status.downloading")
                updateInstallProgress(id: id, message: downloadMsg, fraction: 0.0, detail: nil)
                let downloadedZip = try await Self.downloadToTempFile(from: downloadURL) { [weak self] fraction, detail in
                    Task { @MainActor [weak self] in
                        self?.updateInstallProgress(id: id, message: downloadMsg, fraction: fraction, detail: detail)
                    }
                }
                defer { try? FileManager.default.removeItem(at: downloadedZip) }

                updateInstallProgress(id: id, message: L10n("lsp.status.extracting"), fraction: 1.0, detail: nil)
                let extractedBinary = try await Task.detached(priority: .userInitiated) {
                    try Self.extractZipArchive(fromFile: downloadedZip, into: dir, expectedRelativeBinary: binaryRelativePath)
                }.value
                statuses[id] = .installed(path: extractedBinary.path)

            case .npmPackages(let packages, let binaryName):
                guard let npmPath = Self.findExecutableInCommonPaths("npm") else {
                    throw NSError(
                        domain: "SwiftFlashLSP",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: L10n("lsp.error.npmMissing", def.manualInstallHint)]
                    )
                }
                let npmMsg = L10n("lsp.status.installingNpm")
                updateInstallProgress(id: id, message: npmMsg, fraction: nil, detail: packages.joined(separator: " "))
                let binPath = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let weakSelf = self
                    return try Self.runNpmInstall(npmPath: npmPath, prefixDir: dir, packages: packages, binaryName: binaryName) { line in
                        Task { @MainActor in
                            weakSelf?.updateInstallProgress(id: id, message: npmMsg, fraction: nil, detail: line)
                        }
                    }
                }.value
                statuses[id] = .installed(path: binPath.path)

            case .goInstall(let packagePath, let binaryName):
                guard let goPath = Self.findExecutableInCommonPaths("go") else {
                    throw NSError(
                        domain: "SwiftFlashLSP",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: L10n("lsp.error.goMissing", def.manualInstallHint)]
                    )
                }
                let goMsg = L10n("lsp.status.installingGo")
                updateInstallProgress(id: id, message: goMsg, fraction: nil, detail: packagePath)
                let binPath = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let weakSelf = self
                    return try Self.runGoInstall(goPath: goPath, serverDir: dir, packagePath: packagePath, binaryName: binaryName) { line in
                        Task { @MainActor in
                            weakSelf?.updateInstallProgress(id: id, message: goMsg, fraction: nil, detail: line)
                        }
                    }
                }.value
                statuses[id] = .installed(path: binPath.path)
            }
            onServerBecameReady?()
        } catch {
            let msg = error.localizedDescription
            statuses[id] = .failed(msg)
            lastErrorMessage = "\(def.displayName): \(msg)"
        }
    }

    private func updateInstallProgress(id: String, message: String, fraction: Double?, detail: String?) {
        statuses[id] = .installing(LSPInstallProgress(message: message, fraction: fraction, detail: detail))
    }

    func uninstallServer(id: String) {
        shutdownSessions(forServerID: id)
        let dir = LSPStorage.serverDirectory(id: id)
        try? FileManager.default.removeItem(at: dir)
        refreshStatuses()
    }

    // MARK: - Document Lifecycle & LSP Operations

    func ensureSessionAndOpenDocument(
        url: URL,
        language: CodeLanguage,
        content: String,
        workspaceRoot: URL
    ) async {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        await ensureStatusesScanned()
        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return
        }

        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        syncDocumentImmediately(
            sessionKey: sKey,
            connection: conn,
            url: url,
            languageID: lspLangID,
            content: latestDocumentContents[dKey] ?? content
        )
    }

    func notifyDocumentChanged(
        url: URL,
        language: CodeLanguage,
        content: String,
        workspaceRoot: URL
    ) {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url) else {
            return
        }
        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        guard sessions[sKey]?.isInitialized == true else { return }

        let taskKey = "\(sKey)::\(dKey)"
        pendingChangeTasks[taskKey]?.cancel()
        pendingChangeTasks[taskKey] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingChangeTasks.removeValue(forKey: taskKey)
            guard let conn = self.sessions[sKey], conn.isInitialized,
                  let currentText = self.latestDocumentContents[dKey] else { return }
            self.syncDocumentImmediately(
                sessionKey: sKey,
                connection: conn,
                url: url,
                languageID: lspLangID,
                content: currentText
            )
        }
    }

    func notifyDocumentSaved(
        url: URL,
        language: CodeLanguage,
        content: String,
        workspaceRoot: URL
    ) {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url) else { return }
        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        guard let conn = sessions[sKey], conn.isInitialized else { return }

        flushPendingChange(sessionKey: sKey, url: url, languageID: lspLangID, content: content, connection: conn)
        conn.didSave(url: url, text: content)
    }

    func notifyDocumentClosed(url: URL, language: CodeLanguage, workspaceRoot: URL) {
        let dKey = documentKey(url: url)
        latestDocumentContents.removeValue(forKey: dKey)
        for (sKey, conn) in sessions {
            let taskKey = "\(sKey)::\(dKey)"
            pendingChangeTasks[taskKey]?.cancel()
            pendingChangeTasks.removeValue(forKey: taskKey)

            if openDocumentVersionsBySession[sKey]?.removeValue(forKey: dKey) != nil {
                lastSentDocumentContentsBySession[sKey]?.removeValue(forKey: dKey)
                conn.didClose(url: url)
            }
        }
    }

    func requestCompletions(
        url: URL,
        language: CodeLanguage,
        content: String,
        line: Int,
        character: Int,
        workspaceRoot: URL
    ) async -> [LSPCompletionItem]? {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        await ensureStatusesScanned()
        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return nil
        }

        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        flushPendingChange(
            sessionKey: sKey,
            url: url,
            languageID: lspLangID,
            content: latestDocumentContents[dKey] ?? content,
            connection: conn
        )
        return try? await conn.completion(url: url, line: line, character: character)
    }

    func requestDefinition(
        url: URL,
        language: CodeLanguage,
        content: String,
        line: Int,
        character: Int,
        workspaceRoot: URL
    ) async -> [LSPLocation] {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        await ensureStatusesScanned()
        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return []
        }

        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        flushPendingChange(
            sessionKey: sKey,
            url: url,
            languageID: lspLangID,
            content: latestDocumentContents[dKey] ?? content,
            connection: conn
        )
        return (try? await conn.definition(url: url, line: line, character: character)) ?? []
    }

    func requestHover(
        url: URL,
        language: CodeLanguage,
        content: String,
        line: Int,
        character: Int,
        workspaceRoot: URL
    ) async -> LSPHover? {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        await ensureStatusesScanned()
        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return nil
        }

        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        flushPendingChange(
            sessionKey: sKey,
            url: url,
            languageID: lspLangID,
            content: latestDocumentContents[dKey] ?? content,
            connection: conn
        )
        return try? await conn.hover(url: url, line: line, character: character)
    }

    func requestReferences(
        url: URL,
        language: CodeLanguage,
        content: String,
        line: Int,
        character: Int,
        workspaceRoot: URL
    ) async -> [LSPLocation] {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        await ensureStatusesScanned()
        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return []
        }

        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        flushPendingChange(
            sessionKey: sKey,
            url: url,
            languageID: lspLangID,
            content: latestDocumentContents[dKey] ?? content,
            connection: conn
        )
        return (try? await conn.references(url: url, line: line, character: character)) ?? []
    }

    func requestFormatting(
        url: URL,
        language: CodeLanguage,
        content: String,
        workspaceRoot: URL,
        tabSize: Int = 4,
        insertSpaces: Bool = true
    ) async -> [LSPTextEdit]? {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        await ensureStatusesScanned()
        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return nil
        }

        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        flushPendingChange(
            sessionKey: sKey,
            url: url,
            languageID: lspLangID,
            content: latestDocumentContents[dKey] ?? content,
            connection: conn
        )
        return try? await conn.formatting(url: url, tabSize: tabSize, insertSpaces: insertSpaces)
    }

    func requestDocumentSymbols(
        url: URL,
        language: CodeLanguage,
        content: String,
        workspaceRoot: URL
    ) async -> [LSPDocumentSymbol] {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        await ensureStatusesScanned()
        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return []
        }

        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        flushPendingChange(
            sessionKey: sKey,
            url: url,
            languageID: lspLangID,
            content: latestDocumentContents[dKey] ?? content,
            connection: conn
        )
        return (try? await conn.documentSymbols(url: url)) ?? []
    }

    func shutdownAll() {
        for (_, task) in pendingChangeTasks {
            task.cancel()
        }
        pendingChangeTasks.removeAll()
        for (_, task) in startingTasks {
            task.cancel()
        }
        startingTasks.removeAll()
        for (_, conn) in sessions {
            conn.shutdownNow()
        }
        sessions.removeAll()
        openDocumentVersionsBySession.removeAll()
        lastSentDocumentContentsBySession.removeAll()
        latestDocumentContents.removeAll()
        activeServerIDs.removeAll()
    }

    private func shutdownSessions(forServerID serverID: String) {
        let prefix = serverID + "::"
        let keysToRemove = sessions.keys.filter { $0.hasPrefix(prefix) }
        for key in keysToRemove {
            sessions[key]?.shutdownNow()
            clearSessionState(forSessionKey: key)
        }
        for key in startingTasks.keys where key.hasPrefix(prefix) {
            startingTasks[key]?.cancel()
            startingTasks.removeValue(forKey: key)
        }
        activeServerIDs = Set(sessions.values.map(\.serverID))
    }

    private func clearSessionState(forSessionKey sKey: String) {
        sessions.removeValue(forKey: sKey)
        openDocumentVersionsBySession.removeValue(forKey: sKey)
        lastSentDocumentContentsBySession.removeValue(forKey: sKey)
        let pendingPrefix = sKey + "::"
        for taskKey in pendingChangeTasks.keys where taskKey.hasPrefix(pendingPrefix) {
            pendingChangeTasks[taskKey]?.cancel()
            pendingChangeTasks.removeValue(forKey: taskKey)
        }
    }

    private func flushPendingChange(
        sessionKey sKey: String,
        url: URL,
        languageID: String,
        content: String,
        connection conn: LSPServerConnection
    ) {
        let dKey = documentKey(url: url)
        let taskKey = "\(sKey)::\(dKey)"
        pendingChangeTasks[taskKey]?.cancel()
        pendingChangeTasks.removeValue(forKey: taskKey)
        syncDocumentImmediately(
            sessionKey: sKey,
            connection: conn,
            url: url,
            languageID: languageID,
            content: content
        )
    }

    private func syncDocumentImmediately(
        sessionKey sKey: String,
        connection conn: LSPServerConnection,
        url: URL,
        languageID: String,
        content: String
    ) {
        let dKey = documentKey(url: url)
        var versions = openDocumentVersionsBySession[sKey] ?? [:]
        var sentContents = lastSentDocumentContentsBySession[sKey] ?? [:]

        if versions[dKey] == nil {
            versions[dKey] = 1
            sentContents[dKey] = content
            openDocumentVersionsBySession[sKey] = versions
            lastSentDocumentContentsBySession[sKey] = sentContents
            conn.didOpen(url: url, languageID: languageID, version: 1, text: content)
        } else if sentContents[dKey] != content {
            let nextVer = (versions[dKey] ?? 0) + 1
            versions[dKey] = nextVer
            sentContents[dKey] = content
            openDocumentVersionsBySession[sKey] = versions
            lastSentDocumentContentsBySession[sKey] = sentContents
            conn.didChange(url: url, version: nextVer, text: content)
        }
    }

    private func connection(for def: LSPServerDefinition, workspaceRoot: URL) async -> LSPServerConnection? {
        let key = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        if let existing = sessions[key], existing.isInitialized {
            return existing
        }
        if let inFlight = startingTasks[key] {
            return await inFlight.value
        }

        await ensureStatusesScanned()
        guard let executablePath = status(for: def.id).executablePath else {
            return nil
        }

        let startTask = Task<LSPServerConnection?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                let conn = try LSPServerConnection(
                    serverID: def.id,
                    executablePath: executablePath,
                    arguments: def.arguments,
                    workspaceRoot: workspaceRoot
                )
                conn.onDiagnostics = { [weak self] uriString, diagnostics in
                    guard let fileURL = URL(string: uriString) else { return }
                    let stdURL = fileURL.standardized
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.onDiagnosticsReceived?(stdURL, diagnostics)
                        NotificationCenter.default.post(
                            name: Self.diagnosticsDidUpdateNotification,
                            object: self,
                            userInfo: ["url": stdURL, "diagnostics": diagnostics]
                        )
                    }
                }
                conn.onTerminated = { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.clearSessionState(forSessionKey: key)
                        self.activeServerIDs = Set(self.sessions.values.map(\.serverID))
                    }
                }
                try await conn.initialize()
                guard !Task.isCancelled else {
                    conn.shutdownNow()
                    return nil
                }
                self.sessions[key] = conn
                self.activeServerIDs.insert(def.id)
                return conn
            } catch {
                return nil
            }
        }

        startingTasks[key] = startTask
        let result = await startTask.value
        startingTasks.removeValue(forKey: key)
        return result
    }

    private func sessionKey(serverID: String, workspaceRoot: URL) -> String {
        "\(serverID)::\(workspaceRoot.standardized.path)"
    }

    private func documentKey(url: URL) -> String {
        url.standardized.path
    }

    // MARK: - Executable Resolution Helpers

    private nonisolated static func probeAllStatuses() -> [String: LSPServerStatus] {
        var result: [String: LSPServerStatus] = [:]
        for def in LSPServerCatalog.all {
            if let installedPath = findManagedExecutable(for: def) {
                result[def.id] = .installed(path: installedPath)
            } else if let detectedPath = findSystemExecutable(for: def) {
                result[def.id] = .detected(path: detectedPath)
            } else {
                result[def.id] = .notInstalled
            }
        }
        return result
    }

    private nonisolated static func findManagedExecutable(for def: LSPServerDefinition) -> String? {
        let fm = FileManager.default
        let dir = LSPStorage.serverDirectory(id: def.id)
        let candidates = [
            dir.appendingPathComponent(def.executableName),
            dir.appendingPathComponent("bin").appendingPathComponent(def.executableName),
            dir.appendingPathComponent("node_modules/.bin").appendingPathComponent(def.executableName)
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        if case .githubLatestZipBinary(_, _, let relativePath) = def.installStrategy,
           let nested = Self.findFile(matchingSuffix: relativePath, under: dir),
           fm.isExecutableFile(atPath: nested.path) {
            return nested.path
        }
        return nil
    }

    private nonisolated static func findSystemExecutable(for def: LSPServerDefinition) -> String? {
        if case .systemToolchain(let xcrunTool) = def.installStrategy,
           let xcrunPath = Self.resolveViaXcrun(xcrunTool) {
            return xcrunPath
        }
        return Self.findExecutableInCommonPaths(def.executableName)
    }

    private nonisolated static func resolveViaXcrun(_ tool: String) -> String? {
        let res = ProcessRunner.run(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--find", tool],
            timeoutSeconds: 8
        )
        guard res.exitCode == 0 else { return nil }
        let path = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated static func findExecutableInCommonPaths(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in ToolchainEnvironment.searchDirectories() {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Zero-Copy Download & Archive Extraction Helpers

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let onProgress: @Sendable (Double?, String) -> Void
        private let continuation: CheckedContinuation<URL, Error>
        private var didResume = false
        private var lastUpdateTime: CFAbsoluteTime = 0

        init(
            onProgress: @escaping @Sendable (Double?, String) -> Void,
            continuation: CheckedContinuation<URL, Error>
        ) {
            self.onProgress = onProgress
            self.continuation = continuation
        }

        private func resumeOnce(_ result: Result<URL, Error>) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()
            continuation.resume(with: result)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            let shouldEmit = (now - lastUpdateTime >= 0.08) || totalBytesWritten == totalBytesExpectedToWrite
            if shouldEmit {
                lastUpdateTime = now
            }
            lock.unlock()
            guard shouldEmit else { return }

            let writtenStr = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
            if totalBytesExpectedToWrite > 0 {
                let fraction = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
                let totalStr = ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file)
                let pct = Int((fraction * 100).rounded())
                onProgress(fraction, "\(writtenStr) / \(totalStr) (\(pct)%)")
            } else {
                onProgress(nil, writtenStr)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                resumeOnce(.failure(NSError(
                    domain: "SwiftFlashLSP",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )))
                return
            }
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftflash-dl-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: tempFile)
                resumeOnce(.success(tempFile))
            } catch {
                resumeOnce(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                resumeOnce(.failure(error))
            } else {
                // Safeguard against unexpected completion without didFinishDownloadingTo.
                resumeOnce(.failure(URLError(.unknown)))
            }
        }
    }

    private nonisolated static func downloadToTempFile(
        from url: URL,
        onProgress: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadProgressDelegate(onProgress: onProgress, continuation: continuation)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            let task = session.downloadTask(with: request)
            task.resume()
            session.finishTasksAndInvalidate()
        }
    }

    private nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func resolveLatestGitHubAssetURL(repo: String, prefix: String, suffix: String) async throws -> URL {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "SwiftFlashLSP",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub API HTTP \(http.statusCode)"]
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        for asset in assets {
            if let name = asset["name"] as? String,
               name.hasPrefix(prefix),
               name.hasSuffix(suffix),
               let urlStr = asset["browser_download_url"] as? String,
               let url = URL(string: urlStr) {
                return url
            }
        }
        throw NSError(
            domain: "SwiftFlashLSP",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Matching release asset not found in \(repo)"]
        )
    }

    private nonisolated static func extractGzipBinary(fromFile downloadedFile: URL, to destination: URL) throws {
        let fm = FileManager.default
        let gzURL = destination.appendingPathExtension("gz")
        try? fm.removeItem(at: destination)
        try? fm.removeItem(at: gzURL)
        try fm.copyItem(at: downloadedFile, to: gzURL)

        let res = ProcessRunner.run(
            executablePath: "/usr/bin/gunzip",
            arguments: ["-f", gzURL.path],
            timeoutSeconds: 60
        )
        guard res.exitCode == 0, fm.fileExists(atPath: destination.path) else {
            throw NSError(
                domain: "SwiftFlashLSP",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: res.stderr.isEmpty ? "gunzip failed" : res.stderr]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private nonisolated static func extractZipArchive(
        fromFile zipURL: URL,
        into directory: URL,
        expectedRelativeBinary: String
    ) throws -> URL {
        let fm = FileManager.default
        // Clean stale artifacts from previous versions before extracting a fresh archive.
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let res = ProcessRunner.run(
            executablePath: "/usr/bin/ditto",
            arguments: ["-xk", zipURL.path, directory.path],
            timeoutSeconds: 120
        )
        guard res.exitCode == 0 else {
            throw NSError(
                domain: "SwiftFlashLSP",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: res.stderr.isEmpty ? "unzip failed" : res.stderr]
            )
        }

        guard let binaryURL = findFile(matchingSuffix: expectedRelativeBinary, under: directory) else {
            throw NSError(
                domain: "SwiftFlashLSP",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Binary \(expectedRelativeBinary) not found in archive"]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        return binaryURL
    }

    private nonisolated static func findFile(matchingSuffix suffix: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.path.hasSuffix("/" + suffix) || url.lastPathComponent == suffix {
                return url
            }
        }
        return nil
    }

    private nonisolated static func runNpmInstall(
        npmPath: String,
        prefixDir: URL,
        packages: [String],
        binaryName: String,
        onLogLine: @escaping @Sendable (String) -> Void
    ) throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: npmPath)
        proc.arguments = ["install", "--prefix", prefixDir.path, "--no-audit", "--no-fund"] + packages
        let npmDir = URL(fileURLWithPath: npmPath).deletingLastPathComponent().path
        proc.environment = ToolchainEnvironment.augmentedEnvironment(prependDirs: [npmDir])
        let errText = try runProcessStreamingOutput(proc, onLogLine: onLogLine)

        let binURL = prefixDir.appendingPathComponent("node_modules/.bin/\(binaryName)")
        guard proc.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: binURL.path) else {
            throw NSError(domain: "SwiftFlashLSP", code: 20, userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "npm install failed" : errText])
        }
        return binURL
    }

    private nonisolated static func runGoInstall(
        goPath: String,
        serverDir: URL,
        packagePath: String,
        binaryName: String,
        onLogLine: @escaping @Sendable (String) -> Void
    ) throws -> URL {
        let binDir = serverDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: goPath)
        proc.arguments = ["install", "-v", packagePath]
        let goDir = URL(fileURLWithPath: goPath).deletingLastPathComponent().path
        proc.environment = ToolchainEnvironment.augmentedEnvironment(
            prependDirs: [goDir],
            extraVariables: ["GOBIN": binDir.path]
        )
        let errText = try runProcessStreamingOutput(proc, onLogLine: onLogLine)

        let binURL = binDir.appendingPathComponent(binaryName)
        guard proc.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: binURL.path) else {
            throw NSError(domain: "SwiftFlashLSP", code: 21, userInfo: [NSLocalizedDescriptionKey: errText.isEmpty ? "go install failed" : errText])
        }
        return binURL
    }

    private nonisolated static func runProcessStreamingOutput(
        _ proc: Process,
        onLogLine: @escaping @Sendable (String) -> Void
    ) throws -> String {
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        final class StreamCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var outDecoder = IncrementalLineDecoder()
            private var errDecoder = IncrementalLineDecoder()
            private var errLines: [String] = []

            func append(_ data: Data, isError: Bool) -> [String] {
                lock.lock()
                defer { lock.unlock() }
                let lines = isError ? errDecoder.append(data) : outDecoder.append(data)
                if isError {
                    errLines.append(contentsOf: lines)
                }
                return lines
            }

            func flushAll() -> ([String], String) {
                lock.lock()
                defer { lock.unlock() }
                let outTail = outDecoder.flush()
                let errTail = errDecoder.flush()
                errLines.append(contentsOf: errTail)
                return (outTail + errTail, errLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        let collector = StreamCollector()
        let forward: @Sendable ([String]) -> Void = { lines in
            if let last = lines.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).last(where: { !$0.isEmpty }) {
                onLogLine(last)
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            forward(collector.append(data, isError: false))
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            forward(collector.append(data, isError: true))
        }

        try proc.run()
        proc.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let remOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        if !remOut.isEmpty {
            forward(collector.append(remOut, isError: false))
        }
        let remErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        if !remErr.isEmpty {
            forward(collector.append(remErr, isError: true))
        }

        let (tailLines, errSummary) = collector.flushAll()
        forward(tailLines)
        return errSummary
    }
}
