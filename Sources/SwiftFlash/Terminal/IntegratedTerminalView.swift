import AppKit
import SwiftUI

// MARK: - Semantic ANSI Styling (Theme-Reactive)

enum TerminalColorRole: Equatable, Sendable {
    case plain
    case error
    case comment
    case attribute
    case string
    case typeName
    case function
    case keyword
    case operatorColor
    case primaryText
    case number

    @MainActor
    var color: Color {
        switch self {
        case .plain: return Color(nsColor: ZedTheme.plainText)
        case .error: return Color(nsColor: ZedTheme.attribute)
        case .comment: return Color(nsColor: ZedTheme.comment)
        case .attribute: return Color(nsColor: ZedTheme.attribute)
        case .string: return Color(nsColor: ZedTheme.string)
        case .typeName: return Color(nsColor: ZedTheme.typeName)
        case .function: return Color(nsColor: ZedTheme.function)
        case .keyword: return Color(nsColor: ZedTheme.keyword)
        case .operatorColor: return Color(nsColor: ZedTheme.operatorColor)
        case .primaryText: return Color(nsColor: ZedTheme.primaryText)
        case .number: return Color(nsColor: ZedTheme.number)
        }
    }
}

struct TerminalStyledSpan: Equatable, Sendable {
    let text: String
    let role: TerminalColorRole
}

// MARK: - ANSI CSI & OSC Escape Parser

enum ANSITextParser {
    // Matches CSI sequences (`ESC [ params intermediates final`) and OSC sequences (`ESC ] ... BEL/ST`).
    private static let escapeRegex = try! NSRegularExpression(
        pattern: #"\x1B(?:\[([0-9;?]*)([ -/]*[@-~])|\][^\x07\x1B]*(?:\x07|\x1B\\))"#
    )

    static func parseSpans(_ input: String, defaultRole: TerminalColorRole) -> [TerminalStyledSpan] {
        guard !input.isEmpty else { return [] }
        let ns = input as NSString
        let matches = escapeRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            return [TerminalStyledSpan(text: input, role: defaultRole)]
        }

        var spans: [TerminalStyledSpan] = []
        var currentRole = defaultRole
        var cursor = 0

        for match in matches {
            let matchRange = match.range
            if matchRange.location > cursor {
                let plain = ns.substring(with: NSRange(location: cursor, length: matchRange.location - cursor))
                if !plain.isEmpty {
                    spans.append(TerminalStyledSpan(text: plain, role: currentRole))
                }
            }

            let finalRange = match.range(at: 2)
            let paramRange = match.range(at: 1)
            if finalRange.location != NSNotFound,
               ns.substring(with: finalRange) == "m" {
                let paramStr = paramRange.location != NSNotFound ? ns.substring(with: paramRange) : ""
                if !paramStr.contains("?") {
                    let codes = paramStr.isEmpty
                        ? [0]
                        : paramStr.split(separator: ";").compactMap { Int($0) }
                    for code in codes {
                        switch code {
                        case 0: currentRole = defaultRole
                        case 30, 90: currentRole = .comment
                        case 31, 91: currentRole = .attribute
                        case 32, 92: currentRole = .string
                        case 33, 93: currentRole = .typeName
                        case 34, 94: currentRole = .function
                        case 35, 95: currentRole = .keyword
                        case 36, 96: currentRole = .operatorColor
                        case 37, 97: currentRole = .primaryText
                        default: break
                        }
                    }
                }
            }

            cursor = matchRange.location + matchRange.length
        }

        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty {
                spans.append(TerminalStyledSpan(text: tail, role: currentRole))
            }
        }
        return spans
    }

    @MainActor
    static func renderAttributedString(from spans: [TerminalStyledSpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var part = AttributedString(span.text)
            part.foregroundColor = span.role.color
            result.append(part)
        }
        return result
    }
}

// MARK: - Terminal Session Model

@MainActor
final class TerminalSession: ObservableObject {
    struct OutputLine: Identifiable, Sendable {
        let id = UUID()
        let spans: [TerminalStyledSpan]
    }

    @Published var lines: [OutputLine] = []
    @Published var currentDirectory: URL
    @Published var isRunning: Bool = false
    @Published var commandInput: String = ""
    @Published private(set) var outputRevision: Int = 0

    private var activeProcess: Process?
    private var activeRunToken: UUID?
    private var previousDirectory: URL?
    private var history: [String] = []
    private var historyIndex: Int = -1

    init(workingDirectory: URL) {
        self.currentDirectory = workingDirectory
        appendSystemBanner()
    }

    func syncWorkingDirectory(_ url: URL) {
        if currentDirectory != url && !isRunning {
            previousDirectory = currentDirectory
            currentDirectory = url
            appendColoredLine(L10n("terminal.workspaceChangedFormat", url.path), role: .operatorColor)
        }
    }

    func clear() {
        lines.removeAll()
        appendSystemBanner()
    }

    func terminateRunningCommand(appendNotice: Bool = true) {
        activeRunToken = nil
        if let proc = activeProcess, proc.isRunning {
            ProcessRunner.terminateProcessTree(rootPID: proc.processIdentifier)
            if appendNotice {
                appendColoredLine(L10n("terminal.processTerminated"), role: .attribute)
            }
        }
        activeProcess = nil
        isRunning = false
    }

    func historyUp() {
        guard !history.isEmpty else { return }
        if historyIndex == -1 {
            historyIndex = history.count - 1
        } else if historyIndex > 0 {
            historyIndex -= 1
        }
        commandInput = history[historyIndex]
    }

    func historyDown() {
        guard !history.isEmpty, historyIndex != -1 else { return }
        if historyIndex < history.count - 1 {
            historyIndex += 1
            commandInput = history[historyIndex]
        } else {
            historyIndex = -1
            commandInput = ""
        }
    }

    /// Extracts the target directory only when `cmd` is a standalone `cd` command
    /// (not a compound command like `cd foo && ls`).
    nonisolated static func parseStandaloneCDTarget(from cmd: String) -> String? {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "cd" || trimmed.hasPrefix("cd ") || trimmed.hasPrefix("cd\t") else {
            return nil
        }

        // If shell chaining/piping operators exist outside quotes, delegate to zsh.
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(trimmed)
        for ch in chars {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && !inSingle {
                escaped = true
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }
            if !inSingle && !inDouble {
                if ch == ";" || ch == "&" || ch == "|" || ch == ">" || ch == "<" || ch == "`" {
                    return nil
                }
            }
        }

        var rawArg = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if rawArg.count >= 2 {
            if (rawArg.hasPrefix("\"") && rawArg.hasSuffix("\""))
                || (rawArg.hasPrefix("'") && rawArg.hasSuffix("'")) {
                rawArg = String(rawArg.dropFirst().dropLast())
            }
        }
        return rawArg.replacingOccurrences(of: "\\ ", with: " ")
    }

    func runCommand(_ rawCommand: String? = nil) {
        let cmd = (rawCommand ?? commandInput).trimmingCharacters(in: .whitespacesAndNewlines)
        if rawCommand == nil {
            commandInput = ""
        }
        guard !cmd.isEmpty else { return }

        if history.last != cmd {
            history.append(cmd)
        }
        historyIndex = -1

        if cmd == "clear" {
            clear()
            return
        }

        let dirName = currentDirectory.lastPathComponent
        appendColoredLine("\(dirName) % \(cmd)", role: .function)

        if let cdTarget = Self.parseStandaloneCDTarget(from: cmd) {
            handleChangeDirectory(targetRaw: cdTarget)
            return
        }

        if isRunning {
            terminateRunningCommand(appendNotice: true)
        }

        let runToken = UUID()
        activeRunToken = runToken
        isRunning = true
        let cwd = currentDirectory

        Task.detached(priority: .userInitiated) { [weak self] in
            let weakSelf = self
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", cmd]
            process.currentDirectoryURL = cwd
            process.environment = ToolchainEnvironment.augmentedEnvironment(
                extraVariables: [
                    "TERM": "xterm-256color",
                    "CLICOLOR_FORCE": "1"
                ]
            )

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            final class DecoderState: @unchecked Sendable {
                private let lock = NSLock()
                private var outDecoder = IncrementalLineDecoder()
                private var errDecoder = IncrementalLineDecoder()

                func append(_ data: Data, isError: Bool) -> [String] {
                    lock.lock()
                    defer { lock.unlock() }
                    return isError ? errDecoder.append(data) : outDecoder.append(data)
                }

                func flush(isError: Bool) -> [String] {
                    lock.lock()
                    defer { lock.unlock() }
                    return isError ? errDecoder.flush() : outDecoder.flush()
                }
            }

            let decoderState = DecoderState()
            let emitLines: @Sendable ([String], TerminalColorRole) -> Void = { rawLines, role in
                guard !rawLines.isEmpty else { return }
                let outputItems = rawLines.map { line in
                    OutputLine(spans: ANSITextParser.parseSpans(line, defaultRole: role))
                }
                Task { @MainActor in
                    weakSelf?.appendOutputLines(outputItems, for: runToken)
                }
            }

            let shouldProceed = await MainActor.run { () -> Bool in
                guard let strongSelf = weakSelf, strongSelf.activeRunToken == runToken else {
                    return false
                }
                strongSelf.activeProcess = process
                return true
            }
            guard shouldProceed else { return }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                emitLines(decoderState.append(data, isError: false), .plain)
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                emitLines(decoderState.append(data, isError: true), .error)
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                let errMsg = error.localizedDescription
                await MainActor.run {
                    guard let strongSelf = weakSelf, strongSelf.activeRunToken == runToken else { return }
                    strongSelf.appendColoredLine(L10n("terminal.failedExecuteFormat", errMsg), role: .attribute)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            let tailOut = decoderState.append(remainingOut, isError: false) + decoderState.flush(isError: false)
            if !tailOut.isEmpty {
                let items = tailOut.map { OutputLine(spans: ANSITextParser.parseSpans($0, defaultRole: .plain)) }
                await MainActor.run {
                    weakSelf?.appendOutputLines(items, for: runToken)
                }
            }

            let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            let tailErr = decoderState.append(remainingErr, isError: true) + decoderState.flush(isError: true)
            if !tailErr.isEmpty {
                let items = tailErr.map { OutputLine(spans: ANSITextParser.parseSpans($0, defaultRole: .error)) }
                await MainActor.run {
                    weakSelf?.appendOutputLines(items, for: runToken)
                }
            }

            let exitCode = process.terminationStatus
            await MainActor.run {
                guard let strongSelf = weakSelf, strongSelf.activeRunToken == runToken else { return }
                strongSelf.isRunning = false
                strongSelf.activeProcess = nil
                if exitCode != 0 {
                    strongSelf.appendColoredLine(L10n("terminal.exitCodeFormat", Int(exitCode)), role: .number)
                }
            }
        }
    }

    private func handleChangeDirectory(targetRaw: String) {
        let resolved: URL
        if targetRaw == "-" {
            guard let prev = previousDirectory else {
                appendColoredLine(L10n("terminal.cdNoSuchDirFormat", "-"), role: .attribute)
                return
            }
            resolved = prev
        } else if targetRaw.isEmpty || targetRaw == "~" {
            resolved = FileManager.default.homeDirectoryForCurrentUser
        } else if targetRaw.hasPrefix("/") {
            resolved = URL(fileURLWithPath: targetRaw).standardized
        } else if targetRaw.hasPrefix("~/") {
            let sub = String(targetRaw.dropFirst(2))
            resolved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(sub).standardized
        } else {
            resolved = currentDirectory.appendingPathComponent(targetRaw).standardized
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
            previousDirectory = currentDirectory
            currentDirectory = resolved
            appendColoredLine("→ \(resolved.path)", role: .string)
        } else {
            appendColoredLine(L10n("terminal.cdNoSuchDirFormat", targetRaw), role: .attribute)
        }
    }

    private func appendSystemBanner() {
        appendColoredLine(
            L10n("terminal.readyBannerFormat", currentDirectory.path),
            role: .comment
        )
    }

    private func appendColoredLine(_ text: String, role: TerminalColorRole) {
        lines.append(OutputLine(spans: [TerminalStyledSpan(text: text, role: role)]))
        trimBufferIfNeeded()
        outputRevision &+= 1
    }

    private func appendOutputLines(_ items: [OutputLine], for runToken: UUID) {
        guard activeRunToken == runToken, !items.isEmpty else { return }
        lines.append(contentsOf: items)
        trimBufferIfNeeded()
        outputRevision &+= 1
    }

    private func trimBufferIfNeeded() {
        if lines.count > 1200 {
            lines.removeFirst(lines.count - 1200)
        }
    }
}

// MARK: - IntegratedTerminalView

struct IntegratedTerminalView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject var session: TerminalSession
    @ObservedObject private var themeManager = ThemeManager.shared

    private var terminalFont: Font {
        themeManager.editorSwiftUIFont(size: max(11, themeManager.editorFontSize - 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Output Scroll Area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.lines) { line in
                            Text(ANSITextParser.renderAttributedString(from: line.spans))
                                .font(terminalFont)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("BOTTOM_ANCHOR")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: session.outputRevision) { _, _ in
                    proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                }
            }
            .background(Color(nsColor: ZedTheme.background))

            // Prompt Input Line
            HStack(spacing: 8) {
                Text("\(session.currentDirectory.lastPathComponent) %")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.string))

                TextField(L10n("terminal.inputPlaceholder"), text: $session.commandInput)
                    .textFieldStyle(.plain)
                    .font(terminalFont)
                    .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                    .onSubmit {
                        session.runCommand()
                    }
                    .onKeyPress(.upArrow) {
                        session.historyUp()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        session.historyDown()
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: ZedTheme.sidebarBackground))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: ZedTheme.border)).frame(height: 1)
            }
        }
        .onChange(of: workspace.rootURL) { _, newRoot in
            session.syncWorkingDirectory(newRoot)
        }
    }
}
