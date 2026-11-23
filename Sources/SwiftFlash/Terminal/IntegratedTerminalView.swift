import AppKit
import SwiftUI

// MARK: - Terminal Session Model

@MainActor
final class TerminalSession: ObservableObject {
    struct OutputLine: Identifiable {
        let id = UUID()
        let text: AttributedString
    }

    @Published var lines: [OutputLine] = []
    @Published var currentDirectory: URL
    @Published var isRunning: Bool = false
    @Published var commandInput: String = ""

    private var activeProcess: Process?
    private var history: [String] = []
    private var historyIndex: Int = -1

    init(workingDirectory: URL) {
        self.currentDirectory = workingDirectory
        appendSystemBanner()
    }

    func syncWorkingDirectory(_ url: URL) {
        if currentDirectory != url && !isRunning {
            currentDirectory = url
            appendColoredLine(L10n("terminal.workspaceChangedFormat", url.path), color: ZedTheme.operatorColor)
        }
    }

    func clear() {
        lines.removeAll()
        appendSystemBanner()
    }

    func terminateRunningCommand() {
        if let proc = activeProcess, proc.isRunning {
            proc.interrupt()
            proc.terminate()
            appendColoredLine(L10n("terminal.processTerminated"), color: ZedTheme.attribute)
        }
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
        appendColoredLine("\(dirName) % \(cmd)", color: ZedTheme.function)

        // Handle pure `cd` directly
        if cmd == "cd" || cmd.hasPrefix("cd ") {
            handleChangeDirectory(cmd)
            return
        }

        if isRunning {
            terminateRunningCommand()
        }

        isRunning = true
        let cwd = currentDirectory

        Task.detached(priority: .userInitiated) { [weak self] in
            let weakSelf = self
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", cmd]
            process.currentDirectoryURL = cwd

            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["CLICOLOR_FORCE"] = "1"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            await MainActor.run {
                weakSelf?.activeProcess = process
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let str = String(data: data, encoding: .utf8) {
                    Task { @MainActor in
                        weakSelf?.appendRawStreamText(str, defaultColor: ZedTheme.plainText)
                    }
                }
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let str = String(data: data, encoding: .utf8) {
                    Task { @MainActor in
                        weakSelf?.appendRawStreamText(str, defaultColor: ZedTheme.attribute)
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                let errMsg = error.localizedDescription
                await MainActor.run {
                    weakSelf?.appendColoredLine(L10n("terminal.failedExecuteFormat", errMsg), color: ZedTheme.attribute)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let exitCode = process.terminationStatus
            await MainActor.run {
                guard let strongSelf = weakSelf else { return }
                strongSelf.isRunning = false
                strongSelf.activeProcess = nil
                if exitCode != 0 {
                    strongSelf.appendColoredLine(L10n("terminal.exitCodeFormat", exitCode), color: ZedTheme.number)
                }
            }
        }
    }

    private func handleChangeDirectory(_ cmd: String) {
        let targetRaw = String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let resolved: URL
        if targetRaw.isEmpty || targetRaw == "~" {
            resolved = FileManager.default.homeDirectoryForCurrentUser
        } else if targetRaw.hasPrefix("/") {
            resolved = URL(fileURLWithPath: targetRaw)
        } else if targetRaw.hasPrefix("~/") {
            let sub = String(targetRaw.dropFirst(2))
            resolved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(sub)
        } else {
            resolved = currentDirectory.appendingPathComponent(targetRaw).standardized
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
            currentDirectory = resolved
            appendColoredLine("→ \(resolved.path)", color: ZedTheme.string)
        } else {
            appendColoredLine(L10n("terminal.cdNoSuchDirFormat", targetRaw), color: ZedTheme.attribute)
        }
    }

    private func appendSystemBanner() {
        appendColoredLine(
            L10n("terminal.readyBannerFormat", currentDirectory.path),
            color: ZedTheme.comment
        )
    }

    private func appendColoredLine(_ text: String, color: NSColor) {
        var attr = AttributedString(text)
        attr.foregroundColor = Color(nsColor: color)
        lines.append(OutputLine(text: attr))
        trimBufferIfNeeded()
    }

    private func appendRawStreamText(_ raw: String, defaultColor: NSColor) {
        let cleanLines = raw.components(separatedBy: .newlines)
        for line in cleanLines where !line.isEmpty {
            let attr = ANSITextParser.parse(line, defaultColor: defaultColor)
            lines.append(OutputLine(text: attr))
        }
        trimBufferIfNeeded()
    }

    private func trimBufferIfNeeded() {
        if lines.count > 1200 {
            lines.removeFirst(lines.count - 1200)
        }
    }
}

// MARK: - Lightweight ANSI Color Stripper & Parser

@MainActor
private enum ANSITextParser {
    static func parse(_ input: String, defaultColor: NSColor) -> AttributedString {
        var result = AttributedString()
        var currentColor = Color(nsColor: defaultColor)

        let scanner = Scanner(string: input)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            if let plain = scanner.scanUpToString("\u{1B}[") {
                var part = AttributedString(plain)
                part.foregroundColor = currentColor
                result.append(part)
            }

            if scanner.scanString("\u{1B}[") != nil {
                if let codeStr = scanner.scanUpToString("m"), scanner.scanString("m") != nil {
                    let codes = codeStr.split(separator: ";").compactMap { Int($0) }
                    for code in codes {
                        switch code {
                        case 0: currentColor = Color(nsColor: defaultColor)
                        case 30, 90: currentColor = Color(nsColor: ZedTheme.comment)
                        case 31, 91: currentColor = Color(nsColor: ZedTheme.attribute)
                        case 32, 92: currentColor = Color(nsColor: ZedTheme.string)
                        case 33, 93: currentColor = Color(nsColor: ZedTheme.typeName)
                        case 34, 94: currentColor = Color(nsColor: ZedTheme.function)
                        case 35, 95: currentColor = Color(nsColor: ZedTheme.keyword)
                        case 36, 96: currentColor = Color(nsColor: ZedTheme.operatorColor)
                        case 37, 97: currentColor = Color(nsColor: ZedTheme.primaryText)
                        default: break
                        }
                    }
                } else {
                    // Skip non-SGR escape sequence
                    _ = scanner.scanUpToCharacters(from: .letters)
                    _ = scanner.scanCharacters(from: .letters)
                }
            }
        }
        return result
    }
}

// MARK: - IntegratedTerminalView

struct IntegratedTerminalView: View {
    @ObservedObject var workspace: WorkspaceState
    @ObservedObject var session: TerminalSession
    var showHeader: Bool = true
    @ObservedObject private var themeManager = ThemeManager.shared

    private var terminalFont: Font {
        let size = max(11, themeManager.editorFontSize - 1)
        if themeManager.editorFontFamily == "System Monospace" {
            return .system(size: size, design: .monospaced)
        }
        if let nsFont = NSFont(name: themeManager.editorFontFamily, size: size) {
            return Font(nsFont)
        }
        return .system(size: size, design: .monospaced)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                // Terminal Header Bar
                HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.string))
                    Text(L10n("terminal.title"))
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundColor(Color(nsColor: ZedTheme.primaryText))
                }

                Text(session.currentDirectory.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: ZedTheme.mutedText))

                if session.isRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }

                Spacer()

                quickButton("swift build", color: ZedTheme.function) {
                    session.runCommand("swift build")
                }

                quickButton("git status", color: ZedTheme.keyword) {
                    session.runCommand("git status -sb")
                }

                if session.isRunning {
                    quickButton(L10n("terminal.stop"), color: ZedTheme.attribute) {
                        session.terminateRunningCommand()
                    }
                }

                Button {
                    session.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                }
                .buttonStyle(.plain)
                .help(L10n("terminal.clearHelp"))

                Button {
                    workspace.onToggleTerminalAction?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ZedTheme.secondaryText))
                }
                .buttonStyle(.plain)
                .help(L10n("terminal.hideHelp"))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color(nsColor: ZedTheme.tabBarBackground))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: ZedTheme.border)).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: ZedTheme.border)).frame(height: 1)
            }
            }

            // Output Scroll Area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.lines) { line in
                            Text(line.text)
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
                .onChange(of: session.lines.count) { _, _ in
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

    private func quickButton(_ title: String, color: NSColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: color))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color(nsColor: ZedTheme.background))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: ZedTheme.border), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
