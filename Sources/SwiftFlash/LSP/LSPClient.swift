import Foundation

// MARK: - JSON-RPC Content-Length Framer

struct LSPMessageFramer: Sendable {
    private static let headerSeparator = Data("\r\n\r\n".utf8)
    static let maxMessageBytes = 64 * 1024 * 1024

    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var messages: [Data] = []
        var cursor = buffer.startIndex

        while cursor < buffer.endIndex {
            guard let headerEndRange = buffer.range(of: Self.headerSeparator, in: cursor..<buffer.endIndex) else {
                break
            }

            let headerData = buffer[cursor..<headerEndRange.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8),
                  let contentLength = Self.parseContentLength(from: headerString),
                  contentLength >= 0,
                  contentLength <= Self.maxMessageBytes else {
                // Corrupt or out-of-bounds header; drop up to separator to recover safely.
                cursor = headerEndRange.upperBound
                continue
            }

            let bodyStart = headerEndRange.upperBound
            let remaining = buffer.distance(from: bodyStart, to: buffer.endIndex)
            guard remaining >= contentLength else {
                break
            }

            let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
            messages.append(Data(buffer[bodyStart..<bodyEnd]))
            cursor = bodyEnd
        }

        if cursor > buffer.startIndex {
            if cursor >= buffer.endIndex {
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer = Data(buffer[cursor..<buffer.endIndex])
            }
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
                guard let value = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      value >= 0,
                      value <= maxMessageBytes else {
                    return nil
                }
                return value
            }
        }
        return nil
    }
}

// MARK: - LSP Diagnostics & Response Parsing Helpers

enum LSPPayloadParser {
    private static let placeholderWithDefaultRegex = try! NSRegularExpression(pattern: #"\$\{\d+:([^}]*)\}"#)
    private static let choicePlaceholderRegex = try! NSRegularExpression(pattern: #"\$\{\d+\|([^|,}]*)[^}]*\|\}"#)
    private static let barePlaceholderRegex = try! NSRegularExpression(pattern: #"\$\d+"#)

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

    static func parseHover(from result: Any?) -> LSPHover? {
        guard let dict = result as? [String: Any], let rawContents = dict["contents"] else {
            return nil
        }
        let text = extractHoverMarkdown(rawContents).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let range = (dict["range"] as? [String: Any]).flatMap(parseRange)
        return LSPHover(contents: text, range: range)
    }

    private static func extractHoverMarkdown(_ raw: Any) -> String {
        if let str = raw as? String {
            return str
        }
        if let dict = raw as? [String: Any] {
            if let value = dict["value"] as? String {
                if let lang = dict["language"] as? String, !lang.isEmpty {
                    return "```\(lang)\n\(value)\n```"
                }
                return value
            }
        }
        if let list = raw as? [Any] {
            return list
                .map { extractHoverMarkdown($0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        }
        return ""
    }

    static func parseTextEdits(from result: Any?) -> [LSPTextEdit] {
        guard let rawEdits = result as? [[String: Any]] else { return [] }
        return rawEdits.compactMap { dict in
            guard let rangeDict = dict["range"] as? [String: Any],
                  let range = parseRange(rangeDict),
                  let newText = dict["newText"] as? String else {
                return nil
            }
            return LSPTextEdit(range: range, newText: newText)
        }
    }

    static func parseDocumentSymbols(from result: Any?) -> [LSPDocumentSymbol] {
        guard let rawItems = result as? [[String: Any]] else { return [] }
        var flattened: [LSPDocumentSymbol] = []

        func walkDocumentSymbol(_ dict: [String: Any], container: String?, depth: Int) {
            guard let name = dict["name"] as? String, !name.isEmpty else { return }
            let rawKind = dict["kind"] as? Int ?? LSPSymbolKind.function.rawValue
            let kind = LSPSymbolKind(rawValue: rawKind) ?? .function
            let detail = dict["detail"] as? String

            if let rangeDict = dict["range"] as? [String: Any],
               let range = parseRange(rangeDict) {
                let selRange = (dict["selectionRange"] as? [String: Any]).flatMap(parseRange) ?? range
                flattened.append(LSPDocumentSymbol(
                    name: name,
                    detail: detail,
                    kind: kind,
                    range: range,
                    selectionRange: selRange,
                    containerName: container,
                    depth: depth
                ))
                if let children = dict["children"] as? [[String: Any]] {
                    for child in children {
                        walkDocumentSymbol(child, container: name, depth: depth + 1)
                    }
                }
            } else if let locDict = dict["location"] as? [String: Any],
                      let rangeDict = locDict["range"] as? [String: Any],
                      let range = parseRange(rangeDict) {
                let containerName = dict["containerName"] as? String
                flattened.append(LSPDocumentSymbol(
                    name: name,
                    detail: detail,
                    kind: kind,
                    range: range,
                    selectionRange: range,
                    containerName: containerName,
                    depth: (containerName?.isEmpty == false) ? 1 : 0
                ))
            }
        }

        for item in rawItems {
            walkDocumentSymbol(item, container: nil, depth: 0)
        }
        return flattened
    }

    static func applyTextEdits(_ edits: [LSPTextEdit], to text: String) -> String {
        guard !edits.isEmpty else { return text }
        let nsText = text as NSString

        // Build UTF-16 line start table once: O(N)
        var lineStarts: [Int] = [0]
        let totalLen = nsText.length
        var i = 0
        while i < totalLen {
            let ch = nsText.character(at: i)
            if ch == 0x000A {
                lineStarts.append(i + 1)
            }
            i += 1
        }

        func utf16Offset(for pos: LSPPosition) -> Int {
            guard pos.line >= 0 else { return 0 }
            if pos.line >= lineStarts.count {
                return totalLen
            }
            let lineStart = lineStarts[pos.line]
            let lineEnd: Int
            if pos.line + 1 < lineStarts.count {
                var end = lineStarts[pos.line + 1] - 1
                if end > lineStart && nsText.character(at: end - 1) == 0x000D {
                    end -= 1
                }
                lineEnd = max(lineStart, end)
            } else {
                lineEnd = totalLen
            }
            return min(max(lineStart, lineStart + max(0, pos.character)), max(lineEnd, lineStart))
        }

        struct ResolvedEdit {
            let range: NSRange
            let newText: String
            let order: Int
        }

        var resolved: [ResolvedEdit] = []
        resolved.reserveCapacity(edits.count)
        for (idx, edit) in edits.enumerated() {
            let start = utf16Offset(for: edit.range.start)
            let end = max(start, utf16Offset(for: edit.range.end))
            resolved.append(ResolvedEdit(range: NSRange(location: start, length: end - start), newText: edit.newText, order: idx))
        }

        // Apply from bottom-to-top so earlier offsets remain valid.
        resolved.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location > rhs.range.location
            }
            if lhs.range.length != rhs.range.length {
                return lhs.range.length > rhs.range.length
            }
            return lhs.order > rhs.order
        }

        let mutable = NSMutableString(string: text)
        for edit in resolved {
            guard edit.range.location >= 0, edit.range.location + edit.range.length <= mutable.length else {
                continue
            }
            mutable.replaceCharacters(in: edit.range, with: edit.newText)
        }
        return mutable as String
    }

    static func sanitizeSnippetPlaceholders(_ text: String) -> String {
        guard text.contains("$") else { return text }
        var output = text
        var range = NSRange(location: 0, length: (output as NSString).length)
        output = choicePlaceholderRegex.stringByReplacingMatches(in: output, range: range, withTemplate: "$1")
        range = NSRange(location: 0, length: (output as NSString).length)
        output = placeholderWithDefaultRegex.stringByReplacingMatches(in: output, range: range, withTemplate: "$1")
        range = NSRange(location: 0, length: (output as NSString).length)
        output = barePlaceholderRegex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
        return output
    }
}

// MARK: - LSP Server Connection (Stdio JSON-RPC 2.0)

enum LSPClientError: LocalizedError, Sendable {
    case processNotRunning
    case timeout
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .processNotRunning: return "Language server is not running"
        case .timeout: return "Language server request timed out"
        case .serverError(let msg): return msg
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
    private let stateLock = NSLock()
    private var framer = LSPMessageFramer()
    private var nextRequestID: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var isClosedFlag = false
    private var isInitializedFlag = false

    private var diagnosticsCallback: (@Sendable (String, [LSPDiagnostic]) -> Void)?
    private var terminatedCallback: (@Sendable () -> Void)?

    var isInitialized: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isInitializedFlag && !isClosedFlag && process.isRunning
    }

    var onDiagnostics: (@Sendable (String, [LSPDiagnostic]) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return diagnosticsCallback
        }
        set {
            stateLock.lock()
            diagnosticsCallback = newValue
            stateLock.unlock()
        }
    }

    var onTerminated: (@Sendable () -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return terminatedCallback
        }
        set {
            stateLock.lock()
            terminatedCallback = newValue
            stateLock.unlock()
        }
    }

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
        proc.environment = ToolchainEnvironment.augmentedEnvironment()

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
        // Non-blocking cleanup using stateLock (never calls ioQueue.sync to prevent re-entrancy deadlock).
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
            guard let client = self else { return }
            client.ioQueue.async { [weak client] in
                guard let client, !client.isClosed else { return }
                let payloads = client.framer.append(data)
                for payload in payloads {
                    client.handleIncomingPayload(payload)
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

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isClosedFlag
    }

    private func handleEOF() {
        stateLock.lock()
        guard !isClosedFlag else {
            stateLock.unlock()
            return
        }
        isClosedFlag = true
        let pending = pendingRequests
        pendingRequests.removeAll()
        let onTerm = terminatedCallback
        stateLock.unlock()

        for (_, cont) in pending {
            cont.resume(throwing: LSPClientError.processNotRunning)
        }
        onTerm?()
    }

    private func handleIncomingPayload(_ payload: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }

        if let rawID = obj["id"], !(rawID is NSNull) {
            if let method = obj["method"] as? String {
                let reply: [String: Any]
                if method == "workspace/configuration" {
                    let count = ((obj["params"] as? [String: Any])?["items"] as? [Any])?.count ?? 0
                    reply = ["jsonrpc": "2.0", "id": rawID, "result": Array(repeating: NSNull(), count: count)]
                } else {
                    reply = ["jsonrpc": "2.0", "id": rawID, "result": NSNull()]
                }
                if let replyData = try? JSONSerialization.data(withJSONObject: reply) {
                    writeFrameOnIOQueue(LSPMessageFramer.encode(replyData))
                }
                return
            }

            if let id = rawID as? Int {
                stateLock.lock()
                let cont = pendingRequests.removeValue(forKey: id)
                stateLock.unlock()

                if let cont {
                    if let errorObj = obj["error"] as? [String: Any] {
                        let msg = (errorObj["message"] as? String) ?? "LSP error"
                        cont.resume(throwing: LSPClientError.serverError(msg))
                    } else {
                        cont.resume(returning: payload)
                    }
                }
            }
        } else if let method = obj["method"] as? String {
            if method == "textDocument/publishDiagnostics",
               let params = obj["params"] as? [String: Any],
               let parsed = LSPPayloadParser.parseDiagnostics(from: params) {
                let callback = onDiagnostics
                callback?(parsed.uri, parsed.diagnostics)
            }
        }
    }

    private func writeFrameOnIOQueue(_ frame: Data) {
        guard !isClosed else { return }
        do {
            try stdinHandle.write(contentsOf: frame)
        } catch {
            handleEOF()
        }
    }

    private func encodeMessage(_ dict: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return LSPMessageFramer.encode(data)
    }

    func sendNotification(method: String, params: [String: Any]) {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        guard let frame = encodeMessage(message) else { return }
        ioQueue.async { [weak self] in
            self?.writeFrameOnIOQueue(frame)
        }
    }

    private func sendRequestPayload(
        method: String,
        params: [String: Any],
        timeoutSeconds: TimeInterval = 5.0
    ) async throws -> Data {
        guard process.isRunning, !isClosed else {
            throw LSPClientError.processNotRunning
        }

        let requestID = stateLock.withLock {
            let id = nextRequestID
            nextRequestID += 1
            return id
        }

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params
        ]
        guard let frame = encodeMessage(message) else {
            throw LSPClientError.serverError("Failed to serialize LSP request")
        }

        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            guard !isClosedFlag, process.isRunning else {
                stateLock.unlock()
                continuation.resume(throwing: LSPClientError.processNotRunning)
                return
            }
            pendingRequests[requestID] = continuation
            stateLock.unlock()

            ioQueue.async { [weak self] in
                self?.writeFrameOnIOQueue(frame)
            }

            ioQueue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let timedOut = self.pendingRequests.removeValue(forKey: requestID)
                self.stateLock.unlock()
                timedOut?.resume(throwing: LSPClientError.timeout)
            }
        }
    }

    private static func extractResult(from payload: Data) -> Any? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        return obj["result"]
    }

    func initialize() async throws {
        if isInitialized { return }
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
                    "hover": [
                        "contentFormat": ["markdown", "plaintext"]
                    ],
                    "references": [:],
                    "formatting": [:],
                    "documentSymbol": [
                        "hierarchicalDocumentSymbolSupport": true
                    ],
                    "publishDiagnostics": [
                        "relatedInformation": false
                    ]
                ]
            ]
        ]

        _ = try await sendRequestPayload(method: "initialize", params: params, timeoutSeconds: 12.0)
        stateLock.withLock {
            isInitializedFlag = true
        }
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
        let payload = try await sendRequestPayload(
            method: "textDocument/completion",
            params: [
                "textDocument": ["uri": url.absoluteString],
                "position": ["line": line, "character": character]
            ],
            timeoutSeconds: 6.0
        )
        return LSPPayloadParser.parseCompletionItems(from: Self.extractResult(from: payload))
    }

    func definition(url: URL, line: Int, character: Int) async throws -> [LSPLocation] {
        let payload = try await sendRequestPayload(
            method: "textDocument/definition",
            params: [
                "textDocument": ["uri": url.absoluteString],
                "position": ["line": line, "character": character]
            ],
            timeoutSeconds: 4.0
        )
        return LSPPayloadParser.parseLocations(from: Self.extractResult(from: payload))
    }

    func hover(url: URL, line: Int, character: Int) async throws -> LSPHover? {
        let payload = try await sendRequestPayload(
            method: "textDocument/hover",
            params: [
                "textDocument": ["uri": url.absoluteString],
                "position": ["line": line, "character": character]
            ],
            timeoutSeconds: 3.5
        )
        return LSPPayloadParser.parseHover(from: Self.extractResult(from: payload))
    }

    func references(url: URL, line: Int, character: Int, includeDeclaration: Bool = true) async throws -> [LSPLocation] {
        let payload = try await sendRequestPayload(
            method: "textDocument/references",
            params: [
                "textDocument": ["uri": url.absoluteString],
                "position": ["line": line, "character": character],
                "context": ["includeDeclaration": includeDeclaration]
            ],
            timeoutSeconds: 6.0
        )
        return LSPPayloadParser.parseLocations(from: Self.extractResult(from: payload))
    }

    func formatting(url: URL, tabSize: Int = 4, insertSpaces: Bool = true) async throws -> [LSPTextEdit] {
        let payload = try await sendRequestPayload(
            method: "textDocument/formatting",
            params: [
                "textDocument": ["uri": url.absoluteString],
                "options": [
                    "tabSize": tabSize,
                    "insertSpaces": insertSpaces,
                    "trimTrailingWhitespace": true,
                    "insertFinalNewline": true
                ]
            ],
            timeoutSeconds: 8.0
        )
        return LSPPayloadParser.parseTextEdits(from: Self.extractResult(from: payload))
    }

    func documentSymbols(url: URL) async throws -> [LSPDocumentSymbol] {
        let payload = try await sendRequestPayload(
            method: "textDocument/documentSymbol",
            params: [
                "textDocument": ["uri": url.absoluteString]
            ],
            timeoutSeconds: 5.0
        )
        return LSPPayloadParser.parseDocumentSymbols(from: Self.extractResult(from: payload))
    }

    func shutdownNow() {
        stateLock.lock()
        guard !isClosedFlag else {
            stateLock.unlock()
            return
        }
        isClosedFlag = true
        isInitializedFlag = false
        let pending = pendingRequests
        pendingRequests.removeAll()
        diagnosticsCallback = nil
        terminatedCallback = nil
        stateLock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdinHandle.close()

        for (_, cont) in pending {
            cont.resume(throwing: LSPClientError.processNotRunning)
        }
        if process.isRunning {
            ProcessRunner.terminateProcessTree(rootPID: process.processIdentifier)
        }
    }
}
