import Foundation

// MARK: - JSON-RPC Content-Length Framer

struct LSPMessageFramer {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var messages: [Data] = []
        let separator = Data("\r\n\r\n".utf8)

        while true {
            guard let headerEndRange = buffer.range(of: separator) else {
                break
            }

            let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8),
                  let contentLength = Self.parseContentLength(from: headerString) else {
                // Corrupt header; drop up to separator to recover
                buffer.removeSubrange(0..<headerEndRange.upperBound)
                continue
            }

            let bodyStart = headerEndRange.upperBound
            let bodyEnd = bodyStart + contentLength
            guard buffer.count >= bodyEnd else {
                break
            }

            let payload = buffer.subdata(in: bodyStart..<bodyEnd)
            messages.append(payload)
            buffer.removeSubrange(0..<bodyEnd)
        }

        return messages
    }

    static func encode(_ payload: Data) -> Data {
        let header = "Content-Length: \(payload.count)\r\n\r\n"
        var frame = Data(header.utf8)
        frame.append(payload)
        return frame
    }

    static func parseContentLength(from header: String) -> Int? {
        for rawLine in header.components(separatedBy: "\r\n") {
            let parts = rawLine.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

// MARK: - LSP Diagnostics & Response Parsing Helpers

enum LSPPayloadParser {
    static func parseDiagnostics(from params: [String: Any]) -> (uri: String, diagnostics: [LSPDiagnostic])? {
        guard let uri = params["uri"] as? String,
              let rawDiagnostics = params["diagnostics"] as? [[String: Any]] else {
            return nil
        }

        let parsed: [LSPDiagnostic] = rawDiagnostics.compactMap { dict in
            guard let rangeDict = dict["range"] as? [String: Any],
                  let range = parseRange(rangeDict),
                  let message = dict["message"] as? String else {
                return nil
            }
            let rawSeverity = dict["severity"] as? Int ?? 1
            let severity = LSPDiagnosticSeverity(rawValue: rawSeverity) ?? .error
            let code: String?
            if let strCode = dict["code"] as? String {
                code = strCode
            } else if let intCode = dict["code"] as? Int {
                code = String(intCode)
            } else {
                code = nil
            }
            let source = dict["source"] as? String
            return LSPDiagnostic(
                range: range,
                severity: severity,
                code: code,
                source: source,
                message: message
            )
        }
        return (uri, parsed)
    }

    static func parseCompletionItems(from result: Any?) -> [LSPCompletionItem] {
        let rawItems: [[String: Any]]
        if let listDict = result as? [String: Any], let items = listDict["items"] as? [[String: Any]] {
            rawItems = items
        } else if let items = result as? [[String: Any]] {
            rawItems = items
        } else {
            return []
        }

        return rawItems.compactMap { dict in
            guard let label = dict["label"] as? String, !label.isEmpty else { return nil }
            let rawKind = dict["kind"] as? Int ?? 1
            let kind = LSPCompletionKind(rawValue: rawKind) ?? .text
            let detail = dict["detail"] as? String
            let doc: String?
            if let strDoc = dict["documentation"] as? String {
                doc = strDoc
            } else if let objDoc = dict["documentation"] as? [String: Any] {
                doc = objDoc["value"] as? String
            } else {
                doc = nil
            }

            let rawInsert: String
            if let textEdit = dict["textEdit"] as? [String: Any],
               let newText = textEdit["newText"] as? String {
                rawInsert = newText
            } else if let insertText = dict["insertText"] as? String, !insertText.isEmpty {
                rawInsert = insertText
            } else {
                rawInsert = label
            }

            let sanitizedInsert = sanitizeSnippetPlaceholders(rawInsert)
            let filterText = (dict["filterText"] as? String) ?? label
            let sortText = (dict["sortText"] as? String) ?? label
            return LSPCompletionItem(
                label: label,
                kind: kind,
                detail: detail,
                documentation: doc,
                insertText: sanitizedInsert,
                filterText: filterText,
                sortText: sortText,
                isLocalFallback: false
            )
        }
    }

    static func parseLocations(from result: Any?) -> [LSPLocation] {
        if let single = result as? [String: Any],
           let loc = parseLocation(single) {
            return [loc]
        }
        if let array = result as? [[String: Any]] {
            var locs: [LSPLocation] = []
            for item in array {
                if let loc = parseLocation(item) {
                    locs.append(loc)
                } else if let targetURI = item["targetUri"] as? String,
                          let targetRangeDict = (item["targetSelectionRange"] as? [String: Any]) ?? (item["targetRange"] as? [String: Any]),
                          let targetRange = parseRange(targetRangeDict) {
                    locs.append(LSPLocation(uri: targetURI, range: targetRange))
                }
            }
            return locs
        }
        return []
    }

    static func parseLocation(_ dict: [String: Any]) -> LSPLocation? {
        guard let uri = dict["uri"] as? String,
              let rangeDict = dict["range"] as? [String: Any],
              let range = parseRange(rangeDict) else {
            return nil
        }
        return LSPLocation(uri: uri, range: range)
    }

    static func parseRange(_ dict: [String: Any]) -> LSPRange? {
        guard let startDict = dict["start"] as? [String: Any],
              let endDict = dict["end"] as? [String: Any],
              let startLine = startDict["line"] as? Int,
              let startChar = startDict["character"] as? Int,
              let endLine = endDict["line"] as? Int,
              let endChar = endDict["character"] as? Int else {
            return nil
        }
        return LSPRange(
            start: LSPPosition(line: startLine, character: startChar),
            end: LSPPosition(line: endLine, character: endChar)
        )
    }

    static func sanitizeSnippetPlaceholders(_ text: String) -> String {
        // Strip basic LSP snippet markers like `${1:arg}` -> `arg`, `$0` -> ``
        var output = text
        if let regex = try? NSRegularExpression(pattern: #"\$\{\d+:([^}]*)\}"#) {
            let range = NSRange(location: 0, length: (output as NSString).length)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "$1")
        }
        if let bareRegex = try? NSRegularExpression(pattern: #"\$\d+"#) {
            let range = NSRange(location: 0, length: (output as NSString).length)
            output = bareRegex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
        }
        return output
    }
}

// MARK: - LSP Server Connection (Stdio JSON-RPC 2.0)

enum LSPClientError: LocalizedError {
    case processNotRunning
    case timeout
    case serverError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .processNotRunning: return "Language server is not running"
        case .timeout: return "Language server request timed out"
        case .serverError(let msg): return msg
        case .invalidResponse: return "Invalid LSP response"
        }
    }
}

final class LSPServerConnection: @unchecked Sendable {
    let serverID: String
    let workspaceRoot: URL
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    private let ioQueue = DispatchQueue(label: "dev.swiftflash.lsp.io")
    private var framer = LSPMessageFramer()
    private var nextRequestID: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var isClosed = false
    private(set) var isInitialized = false

    var onDiagnostics: (@Sendable (String, [LSPDiagnostic]) -> Void)?
    var onTerminated: (@Sendable () -> Void)?

    init(
        serverID: String,
        executablePath: String,
        arguments: [String],
        workspaceRoot: URL
    ) throws {
        self.serverID = serverID
        self.workspaceRoot = workspaceRoot

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        proc.currentDirectoryURL = workspaceRoot

        var env = ProcessInfo.processInfo.environment
        let extraBins = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("go/bin").path
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraBins + [existingPath]).joined(separator: ":")
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading
        self.stderrHandle = errPipe.fileHandleForReading

        try proc.run()
        startReading()
    }

    deinit {
        shutdownNow()
    }

    private func startReading() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.handleEOF()
                return
            }
            self?.ioQueue.async {
                guard let self, !self.isClosed else { return }
                let payloads = self.framer.append(data)
                for payload in payloads {
                    self.handleIncomingPayload(payload)
                }
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    private func handleEOF() {
        ioQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.isClosed = true
            let pending = self.pendingRequests
            self.pendingRequests.removeAll()
            for (_, cont) in pending {
                cont.resume(throwing: LSPClientError.processNotRunning)
            }
            self.onTerminated?()
        }
    }

    private func handleIncomingPayload(_ payload: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }

        if let rawID = obj["id"], !(rawID is NSNull) {
            // Response or server->client request
            if let method = obj["method"] as? String {
                // Reply empty success to server-initiated requests (e.g. client/registerCapability, workspace/configuration)
                let reply: [String: Any]
                if method == "workspace/configuration" {
                    let count = ((obj["params"] as? [String: Any])?["items"] as? [Any])?.count ?? 0
                    reply = ["jsonrpc": "2.0", "id": rawID, "result": Array(repeating: NSNull(), count: count)]
                } else {
                    reply = ["jsonrpc": "2.0", "id": rawID, "result": NSNull()]
                }
                sendRawJSON(reply)
                return
            }

            if let id = rawID as? Int,
               let cont = pendingRequests.removeValue(forKey: id) {
                if let errorObj = obj["error"] as? [String: Any] {
                    let msg = (errorObj["message"] as? String) ?? "LSP error"
                    cont.resume(throwing: LSPClientError.serverError(msg))
                } else {
                    cont.resume(returning: obj["result"])
                }
            }
        } else if let method = obj["method"] as? String {
            if method == "textDocument/publishDiagnostics",
               let params = obj["params"] as? [String: Any],
               let parsed = LSPPayloadParser.parseDiagnostics(from: params) {
                onDiagnostics?(parsed.uri, parsed.diagnostics)
            }
        }
    }

    private func sendRawJSON(_ dict: [String: Any]) {
        guard !isClosed,
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return
        }
        let frame = LSPMessageFramer.encode(data)
        try? stdinHandle.write(contentsOf: frame)
    }

    func sendNotification(method: String, params: [String: Any]) {
        ioQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            let message: [String: Any] = [
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ]
            self.sendRawJSON(message)
        }
    }

    func sendRequest(method: String, params: [String: Any], timeoutSeconds: TimeInterval = 5.0) async throws -> Any? {
        guard process.isRunning else {
            throw LSPClientError.processNotRunning
        }

        let requestID: Int = ioQueue.sync {
            let id = nextRequestID
            nextRequestID += 1
            return id
        }

        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self, !self.isClosed, self.process.isRunning else {
                    continuation.resume(throwing: LSPClientError.processNotRunning)
                    return
                }
                self.pendingRequests[requestID] = continuation
                let message: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": requestID,
                    "method": method,
                    "params": params
                ]
                self.sendRawJSON(message)

                self.ioQueue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    guard let self else { return }
                    if let timedOut = self.pendingRequests.removeValue(forKey: requestID) {
                        timedOut.resume(throwing: LSPClientError.timeout)
                    }
                }
            }
        }
    }

    func initialize() async throws {
        guard !isInitialized else { return }
        let rootURI = workspaceRoot.absoluteString
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": rootURI,
            "workspaceFolders": [
                ["uri": rootURI, "name": workspaceRoot.lastPathComponent]
            ],
            "capabilities": [
                "textDocument": [
                    "synchronization": [
                        "didSave": true
                    ],
                    "completion": [
                        "completionItem": [
                            "snippetSupport": true,
                            "documentationFormat": ["plaintext", "markdown"]
                        ]
                    ],
                    "definition": [
                        "linkSupport": true
                    ],
                    "publishDiagnostics": [
                        "relatedInformation": false
                    ]
                ]
            ]
        ]

        _ = try await sendRequest(method: "initialize", params: params, timeoutSeconds: 12.0)
        isInitialized = true
        sendNotification(method: "initialized", params: [:])
    }

    func didOpen(url: URL, languageID: String, version: Int, text: String) {
        sendNotification(
            method: "textDocument/didOpen",
            params: [
                "textDocument": [
                    "uri": url.absoluteString,
                    "languageId": languageID,
                    "version": version,
                    "text": text
                ]
            ]
        )
    }

    func didChange(url: URL, version: Int, text: String) {
        sendNotification(
            method: "textDocument/didChange",
            params: [
                "textDocument": [
                    "uri": url.absoluteString,
                    "version": version
                ],
                "contentChanges": [
                    ["text": text]
                ]
            ]
        )
    }

    func didSave(url: URL, text: String) {
        sendNotification(
            method: "textDocument/didSave",
            params: [
                "textDocument": ["uri": url.absoluteString],
                "text": text
            ]
        )
    }

    func didClose(url: URL) {
        sendNotification(
            method: "textDocument/didClose",
            params: [
                "textDocument": ["uri": url.absoluteString]
            ]
        )
    }

    func completion(url: URL, line: Int, character: Int) async throws -> [LSPCompletionItem] {
        let result = try await sendRequest(
            method: "textDocument/completion",
            params: [
                "textDocument": ["uri": url.absoluteString],
                "position": ["line": line, "character": character]
            ],
            timeoutSeconds: 6.0
        )
        return LSPPayloadParser.parseCompletionItems(from: result)
    }

    func definition(url: URL, line: Int, character: Int) async throws -> [LSPLocation] {
        let result = try await sendRequest(
            method: "textDocument/definition",
            params: [
                "textDocument": ["uri": url.absoluteString],
                "position": ["line": line, "character": character]
            ],
            timeoutSeconds: 4.0
        )
        return LSPPayloadParser.parseLocations(from: result)
    }

    func shutdownNow() {
        ioQueue.sync {
            guard !isClosed else { return }
            isClosed = true
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            let pending = pendingRequests
            pendingRequests.removeAll()
            for (_, cont) in pending {
                cont.resume(throwing: LSPClientError.processNotRunning)
            }
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
