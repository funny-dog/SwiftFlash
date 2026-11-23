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
    private var startingKeys: Set<String> = []
    private var openDocumentVersions: [String: Int] = [:]
    private var latestDocumentContents: [String: String] = [:]
    private var lastSentDocumentContents: [String: String] = [:]
    private var customPaths: [String: String] = [:]
    private var hasScannedInitialStatuses = false
    private var refreshTask: Task<Void, Never>?

    var onDiagnosticsReceived: ((URL, [LSPDiagnostic]) -> Void)?
    var onServerBecameReady: (() -> Void)?

    private static let customPathsDefaultsKey = "swiftflash.lsp.customPaths"

    private init() {
        // Keep singleton initialization side-effect free so Swift Concurrency tasks
        // on MainActor never re-enter dispatch_once while subprocesses pump RunLoop.
        if let saved = UserDefaults.standard.dictionary(forKey: Self.customPathsDefaultsKey) as? [String: String] {
            customPaths = saved
        }
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

        let snapshotCustomPaths = customPaths
        isScanningStatuses = true

        let task = Task<Void, Never> { [weak self] in
            let probed = await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: LSPStorage.rootDirectory, withIntermediateDirectories: true)
                return Self.probeAllStatuses(customPaths: snapshotCustomPaths)
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
            }
        }

        refreshTask = task
        await task.value
    }

    func status(for serverID: String) -> LSPServerStatus {
        statuses[serverID] ?? .notInstalled
    }

    func setCustomExecutablePath(_ path: String, for serverID: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customPaths.removeValue(forKey: serverID)
        } else {
            customPaths[serverID] = trimmed
        }
        UserDefaults.standard.set(customPaths, forKey: Self.customPathsDefaultsKey)
        refreshStatuses()
    }

    func customExecutablePath(for serverID: String) -> String {
        customPaths[serverID] ?? ""
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
            // Fallback to SourceKit-LSP on macOS when Xcode tools are present and clangd isn't installed.
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
                updateInstallProgress(id: id, message: L10n("lsp.status.downloading"), fraction: 0.0, detail: nil)
                let downloadMsg = L10n("lsp.status.downloading")
                let data = try await Self.downloadData(from: url) { [weak self] fraction, detail in
                    Task { @MainActor [weak self] in
                        self?.updateInstallProgress(id: id, message: downloadMsg, fraction: fraction, detail: detail)
                    }
                }
                if let expectedSHA, !expectedSHA.isEmpty {
                    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
                    try Self.extractGzipBinary(data: data, to: destBinary)
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
                let zipData = try await Self.downloadData(from: downloadURL) { [weak self] fraction, detail in
                    Task { @MainActor [weak self] in
                        self?.updateInstallProgress(id: id, message: downloadMsg, fraction: fraction, detail: detail)
                    }
                }
                updateInstallProgress(id: id, message: L10n("lsp.status.extracting"), fraction: 1.0, detail: nil)
                let extractedRoot = try await Task.detached(priority: .userInitiated) {
                    try Self.extractZipArchive(data: zipData, into: dir, expectedRelativeBinary: binaryRelativePath)
                }.value
                statuses[id] = .installed(path: extractedRoot.path)

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
        let key = documentKey(url: url)
        latestDocumentContents[key] = content

        await ensureStatusesScanned()
        guard let def = serverDefinition(for: language, url: url),
              let lspLangID = lspLanguageID(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return
        }

        let currentText = latestDocumentContents[key] ?? content
        if openDocumentVersions[key] == nil {
            openDocumentVersions[key] = 1
            lastSentDocumentContents[key] = currentText
            conn.didOpen(url: url, languageID: lspLangID, version: 1, text: currentText)
        } else if lastSentDocumentContents[key] != currentText {
            let nextVer = (openDocumentVersions[key] ?? 0) + 1
            openDocumentVersions[key] = nextVer
            lastSentDocumentContents[key] = currentText
            conn.didChange(url: url, version: nextVer, text: currentText)
        }
    }

    func notifyDocumentChanged(
        url: URL,
        language: CodeLanguage,
        content: String,
        workspaceRoot: URL
    ) {
        let dKey = documentKey(url: url)
        latestDocumentContents[dKey] = content

        guard let def = serverDefinition(for: language, url: url) else { return }
        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        guard let conn = sessions[sKey], conn.isInitialized else { return }

        let nextVer = (openDocumentVersions[dKey] ?? 0) + 1
        openDocumentVersions[dKey] = nextVer
        lastSentDocumentContents[dKey] = content
        if nextVer == 1, let lspLangID = lspLanguageID(for: language, url: url) {
            conn.didOpen(url: url, languageID: lspLangID, version: 1, text: content)
        } else {
            conn.didChange(url: url, version: nextVer, text: content)
        }
    }

    func notifyDocumentSaved(
        url: URL,
        language: CodeLanguage,
        content: String,
        workspaceRoot: URL
    ) {
        guard let def = serverDefinition(for: language, url: url) else { return }
        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        guard let conn = sessions[sKey], conn.isInitialized else { return }
        conn.didSave(url: url, text: content)
    }

    func notifyDocumentClosed(url: URL, language: CodeLanguage, workspaceRoot: URL) {
        let dKey = documentKey(url: url)
        openDocumentVersions.removeValue(forKey: dKey)
        latestDocumentContents.removeValue(forKey: dKey)
        lastSentDocumentContents.removeValue(forKey: dKey)
        guard let def = serverDefinition(for: language, url: url) else { return }
        let sKey = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        sessions[sKey]?.didClose(url: url)
    }

    func requestCompletions(
        url: URL,
        language: CodeLanguage,
        content: String,
        line: Int,
        character: Int,
        workspaceRoot: URL
    ) async -> [LSPCompletionItem]? {
        guard let def = serverDefinition(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return nil
        }
        await ensureSessionAndOpenDocument(url: url, language: language, content: content, workspaceRoot: workspaceRoot)
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
        guard let def = serverDefinition(for: language, url: url),
              let conn = await connection(for: def, workspaceRoot: workspaceRoot) else {
            return []
        }
        await ensureSessionAndOpenDocument(url: url, language: language, content: content, workspaceRoot: workspaceRoot)
        return (try? await conn.definition(url: url, line: line, character: character)) ?? []
    }

    func shutdownAll() {
        for (_, conn) in sessions {
            conn.shutdownNow()
        }
        sessions.removeAll()
        openDocumentVersions.removeAll()
        lastSentDocumentContents.removeAll()
        activeServerIDs.removeAll()
    }

    private func shutdownSessions(forServerID serverID: String) {
        let keysToRemove = sessions.keys.filter { $0.hasPrefix(serverID + "::") }
        for key in keysToRemove {
            sessions[key]?.shutdownNow()
            sessions.removeValue(forKey: key)
        }
        activeServerIDs = Set(sessions.values.map(\.serverID))
    }

    private func connection(for def: LSPServerDefinition, workspaceRoot: URL) async -> LSPServerConnection? {
        let key = sessionKey(serverID: def.id, workspaceRoot: workspaceRoot)
        if let existing = sessions[key], existing.isInitialized {
            return existing
        }
        if startingKeys.contains(key) {
            return nil
        }

        await ensureStatusesScanned()
        guard let executablePath = status(for: def.id).executablePath else {
            return nil
        }

        startingKeys.insert(key)
        defer { startingKeys.remove(key) }

        do {
            let conn = try LSPServerConnection(
                serverID: def.id,
                executablePath: executablePath,
                arguments: def.arguments,
                workspaceRoot: workspaceRoot
            )
            conn.onDiagnostics = { [weak self] uriString, diagnostics in
                guard let fileURL = URL(string: uriString) else { return }
                Task { @MainActor [weak self] in
                    self?.onDiagnosticsReceived?(fileURL.standardized, diagnostics)
                }
            }
            conn.onTerminated = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.sessions.removeValue(forKey: key)
                    self?.openDocumentVersions.removeAll()
                    self?.lastSentDocumentContents.removeAll()
                    self?.activeServerIDs = Set(self?.sessions.values.map(\.serverID) ?? [])
                }
            }
            try await conn.initialize()
            sessions[key] = conn
            activeServerIDs.insert(def.id)
            return conn
        } catch {
            return nil
        }
    }

    private func sessionKey(serverID: String, workspaceRoot: URL) -> String {
        "\(serverID)::\(workspaceRoot.standardized.path)"
    }

    private func documentKey(url: URL) -> String {
        url.standardized.path
    }

    // MARK: - Executable Resolution Helpers

    private nonisolated static func probeAllStatuses(customPaths: [String: String]) -> [String: LSPServerStatus] {
        var result: [String: LSPServerStatus] = [:]
        for def in LSPServerCatalog.all {
            if let installedPath = findManagedExecutable(for: def) {
                result[def.id] = .installed(path: installedPath)
            } else if let detectedPath = findSystemExecutable(for: def, customPaths: customPaths) {
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

    private nonisolated static func findSystemExecutable(
        for def: LSPServerDefinition,
        customPaths: [String: String]
    ) -> String? {
        let fm = FileManager.default
        if let custom = customPaths[def.id], !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            return custom
        }
        if case .systemToolchain(let xcrunTool) = def.installStrategy,
           let xcrunPath = Self.resolveViaXcrun(xcrunTool) {
            return xcrunPath
        }
        return Self.findExecutableInCommonPaths(def.executableName)
    }

    private nonisolated static func resolveViaXcrun(_ tool: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["--find", tool]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    nonisolated static func findExecutableInCommonPaths(_ name: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var searchDirs: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            searchDirs.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        searchDirs.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/opt/llvm/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(home)/.cargo/bin",
            "\(home)/go/bin",
            "\(home)/.local/bin"
        ])
        for dir in searchDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Download & Archive Extraction Helpers

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double?, String) -> Void
        private let continuation: CheckedContinuation<Data, Error>
        private var didResume = false
        private var lastUpdateTime: CFAbsoluteTime = 0

        init(
            onProgress: @escaping @Sendable (Double?, String) -> Void,
            continuation: CheckedContinuation<Data, Error>
        ) {
            self.onProgress = onProgress
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastUpdateTime >= 0.08 || totalBytesWritten == totalBytesExpectedToWrite else { return }
            lastUpdateTime = now

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
            guard !didResume else { return }
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                didResume = true
                continuation.resume(throwing: NSError(
                    domain: "SwiftFlashLSP",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                ))
                return
            }
            do {
                let data = try Data(contentsOf: location)
                didResume = true
                continuation.resume(returning: data)
            } catch {
                didResume = true
                continuation.resume(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !didResume, let error else { return }
            didResume = true
            continuation.resume(throwing: error)
        }
    }

    private nonisolated static func downloadData(
        from url: URL,
        onProgress: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> Data {
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

    private nonisolated static func extractGzipBinary(data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let gzURL = destination.appendingPathExtension("gz")
        try? fm.removeItem(at: destination)
        try? fm.removeItem(at: gzURL)
        try data.write(to: gzURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        proc.arguments = ["-f", gzURL.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, fm.fileExists(atPath: destination.path) else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "gunzip failed"
            throw NSError(domain: "SwiftFlashLSP", code: 10, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private nonisolated static func extractZipArchive(
        data: Data,
        into directory: URL,
        expectedRelativeBinary: String
    ) throws -> URL {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("swiftflash-lsp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let zipURL = tempRoot.appendingPathComponent("archive.zip")
        try data.write(to: zipURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-xk", zipURL.path, directory.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unzip failed"
            throw NSError(domain: "SwiftFlashLSP", code: 11, userInfo: [NSLocalizedDescriptionKey: msg])
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
        var env = ProcessInfo.processInfo.environment
        let npmDir = URL(fileURLWithPath: npmPath).deletingLastPathComponent().path
        env["PATH"] = npmDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
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
        var env = ProcessInfo.processInfo.environment
        let goDir = URL(fileURLWithPath: goPath).deletingLastPathComponent().path
        env["PATH"] = goDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["GOBIN"] = binDir.path
        proc.environment = env
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

        final class ErrBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var text = ""
            func append(_ str: String) {
                lock.lock()
                text += str
                lock.unlock()
            }
            func value() -> String {
                lock.lock()
                defer { lock.unlock() }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let errBuffer = ErrBuffer()

        let forwardChunk: @Sendable (Data, Bool) -> Void = { data, captureErr in
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            if captureErr {
                errBuffer.append(str)
            }
            let lines = str.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let last = lines.last {
                onLogLine(last)
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            forwardChunk(handle.availableData, false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            forwardChunk(handle.availableData, true)
        }

        try proc.run()
        proc.waitUntilExit()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        return errBuffer.value()
    }
}
