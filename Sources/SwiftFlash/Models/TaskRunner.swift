import Foundation

// MARK: - Project Task Detection

enum ProjectTaskKind: String, Equatable, Sendable {
    case run
    case test
    case build
}

struct ProjectTask: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let command: String
    let kind: ProjectTaskKind
    let sourceLabel: String
}

enum ProjectTaskDetector {
    static func detectTasks(in rootURL: URL, activeFileURL: URL? = nil) -> [ProjectTask] {
        let fm = FileManager.default
        var tasks: [ProjectTask] = []

        // 1. Swift Package Manager
        if fm.fileExists(atPath: rootURL.appendingPathComponent("Package.swift").path) {
            tasks.append(ProjectTask(id: "spm-run", name: "swift run", command: "swift run", kind: .run, sourceLabel: "SwiftPM"))
            tasks.append(ProjectTask(id: "spm-test", name: "swift test", command: "swift test", kind: .test, sourceLabel: "SwiftPM"))
            tasks.append(ProjectTask(id: "spm-build", name: "swift build", command: "swift build", kind: .build, sourceLabel: "SwiftPM"))
        }

        // 2. Rust Cargo
        if fm.fileExists(atPath: rootURL.appendingPathComponent("Cargo.toml").path) {
            tasks.append(ProjectTask(id: "cargo-run", name: "cargo run", command: "cargo run", kind: .run, sourceLabel: "Cargo"))
            tasks.append(ProjectTask(id: "cargo-test", name: "cargo test", command: "cargo test", kind: .test, sourceLabel: "Cargo"))
            tasks.append(ProjectTask(id: "cargo-build", name: "cargo build", command: "cargo build", kind: .build, sourceLabel: "Cargo"))
        }

        // 3. Node.js / package.json
        let pkgJSONURL = rootURL.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkgJSONURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = obj["scripts"] as? [String: String] {
            let runner: String
            if fm.fileExists(atPath: rootURL.appendingPathComponent("pnpm-lock.yaml").path) {
                runner = "pnpm"
            } else if fm.fileExists(atPath: rootURL.appendingPathComponent("yarn.lock").path) {
                runner = "yarn"
            } else {
                runner = "npm run"
            }

            let orderedKeys = ["dev", "start", "test", "build", "lint"]
            let sortedScripts = scripts.keys.sorted { lhs, rhs in
                let li = orderedKeys.firstIndex(of: lhs) ?? Int.max
                let ri = orderedKeys.firstIndex(of: rhs) ?? Int.max
                if li != ri { return li < ri }
                return lhs < rhs
            }
            for scriptName in sortedScripts.prefix(6) {
                let kind: ProjectTaskKind
                if scriptName == "test" {
                    kind = .test
                } else if scriptName == "build" {
                    kind = .build
                } else {
                    kind = .run
                }
                let displayName = runner == "npm run" && scriptName == "test" ? "npm test" : "\(runner) \(scriptName)"
                let safeArg = isSafeBareShellToken(scriptName) ? scriptName : shellQuoted(scriptName)
                let cmd = runner == "npm run" && scriptName == "test" ? "npm test" : "\(runner) \(safeArg)"
                tasks.append(ProjectTask(
                    id: "node-\(scriptName)",
                    name: displayName,
                    command: cmd,
                    kind: kind,
                    sourceLabel: "package.json"
                ))
            }
        }

        // 4. Go Module
        if fm.fileExists(atPath: rootURL.appendingPathComponent("go.mod").path) {
            tasks.append(ProjectTask(id: "go-run", name: "go run .", command: "go run .", kind: .run, sourceLabel: "Go"))
            tasks.append(ProjectTask(id: "go-test", name: "go test ./...", command: "go test ./...", kind: .test, sourceLabel: "Go"))
            tasks.append(ProjectTask(id: "go-build", name: "go build ./...", command: "go build ./...", kind: .build, sourceLabel: "Go"))
        }

        // 5. Python
        let hasPyproject = fm.fileExists(atPath: rootURL.appendingPathComponent("pyproject.toml").path)
        let hasPytestIni = fm.fileExists(atPath: rootURL.appendingPathComponent("pytest.ini").path)
        let hasRequirements = fm.fileExists(atPath: rootURL.appendingPathComponent("requirements.txt").path)
        if hasPyproject || hasPytestIni || hasRequirements {
            tasks.append(ProjectTask(id: "py-test", name: "pytest", command: "pytest", kind: .test, sourceLabel: "Python"))
        }

        // 6. Makefile common targets
        let makefileURL = rootURL.appendingPathComponent("Makefile")
        if let makeText = try? String(contentsOf: makefileURL, encoding: .utf8) {
            for target in ["run", "test", "build"] {
                if makeText.range(of: "(?m)^\(target):", options: .regularExpression) != nil {
                    let kind: ProjectTaskKind = target == "test" ? .test : (target == "build" ? .build : .run)
                    tasks.append(ProjectTask(
                        id: "make-\(target)",
                        name: "make \(target)",
                        command: "make \(target)",
                        kind: kind,
                        sourceLabel: "Makefile"
                    ))
                }
            }
        }

        // 7. Active single-file execution option
        if let fileURL = activeFileURL {
            let escaped = shellQuoted(fileURL.path)
            switch fileURL.pathExtension.lowercased() {
            case "py":
                tasks.append(ProjectTask(
                    id: "file-python",
                    name: "python3 \(fileURL.lastPathComponent)",
                    command: "python3 \(escaped)",
                    kind: .run,
                    sourceLabel: fileURL.lastPathComponent
                ))
            case "swift":
                tasks.append(ProjectTask(
                    id: "file-swift",
                    name: "swift \(fileURL.lastPathComponent)",
                    command: "swift \(escaped)",
                    kind: .run,
                    sourceLabel: fileURL.lastPathComponent
                ))
            case "js", "mjs":
                tasks.append(ProjectTask(
                    id: "file-node",
                    name: "node \(fileURL.lastPathComponent)",
                    command: "node \(escaped)",
                    kind: .run,
                    sourceLabel: fileURL.lastPathComponent
                ))
            case "sh", "zsh", "bash":
                tasks.append(ProjectTask(
                    id: "file-shell",
                    name: "bash \(fileURL.lastPathComponent)",
                    command: "bash \(escaped)",
                    kind: .run,
                    sourceLabel: fileURL.lastPathComponent
                ))
            default:
                break
            }
        }

        return tasks
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isSafeBareShellToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57)     // 0-9
                || (s.value >= 65 && s.value <= 90)  // A-Z
                || (s.value >= 97 && s.value <= 122) // a-z
                || s == "_" || s == "-" || s == "." || s == ":"
        }
    }
}

// MARK: - Compiler / Runtime Output Location Parser

struct ParsedOutputLocation: Equatable, Sendable {
    let url: URL
    let line: Int
    let column: Int?
}

enum OutputLocationParser {
    private struct PatternEntry: @unchecked Sendable {
        let regex: NSRegularExpression
        let fileGroup: Int
        let lineGroup: Int
        let colGroup: Int?
    }

    private static let patterns: [PatternEntry] = {
        var list: [PatternEntry] = []
        // 1. Python traceback: File "/path/foo.py", line 42
        if let r = try? NSRegularExpression(pattern: #"File "([^"]+)", line (\d+)"#) {
            list.append(PatternEntry(regex: r, fileGroup: 1, lineGroup: 2, colGroup: nil))
        }
        // 2. Rust arrow: --> src/main.rs:12:5
        if let r = try? NSRegularExpression(pattern: #"-->\s*([^\s:]+):(\d+):(\d+)"#) {
            list.append(PatternEntry(regex: r, fileGroup: 1, lineGroup: 2, colGroup: 3))
        }
        // 3. TypeScript/MSBuild: src/app.ts(12,5)
        if let r = try? NSRegularExpression(pattern: #"([^\s(:]+)\((\d+),(\d+)\)"#) {
            list.append(PatternEntry(regex: r, fileGroup: 1, lineGroup: 2, colGroup: 3))
        }
        // 4. Generic path:line:col or path:line (Swift, Clang, Go, Jest, etc.)
        if let r = try? NSRegularExpression(pattern: #"([A-Za-z0-9_./-]+\.[A-Za-z0-9]+):(\d+)(?::(\d+))?"#) {
            list.append(PatternEntry(regex: r, fileGroup: 1, lineGroup: 2, colGroup: 3))
        }
        return list
    }()

    static func parseLocation(from rawLine: String, workspaceRoot: URL) -> ParsedOutputLocation? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nsLine = trimmed as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        for entry in patterns {
            guard let match = entry.regex.firstMatch(in: trimmed, range: fullRange) else { continue }
            let rawPath = nsLine.substring(with: match.range(at: entry.fileGroup))
            let lineStr = nsLine.substring(with: match.range(at: entry.lineGroup))
            guard let lineNum = Int(lineStr), lineNum > 0 else { continue }

            var colNum: Int? = nil
            if let cGroup = entry.colGroup,
               cGroup < match.numberOfRanges,
               match.range(at: cGroup).location != NSNotFound {
                colNum = Int(nsLine.substring(with: match.range(at: cGroup)))
            }

            let candidateURL: URL
            if rawPath.hasPrefix("/") {
                candidateURL = URL(fileURLWithPath: rawPath).standardized
            } else {
                candidateURL = workspaceRoot.appendingPathComponent(rawPath).standardized
            }
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                return ParsedOutputLocation(url: candidateURL, line: lineNum, column: colNum)
            }
        }
        return nil
    }
}

// MARK: - Task Runner State

struct TaskOutputLine: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
    let isError: Bool
    let location: ParsedOutputLocation?
}

@MainActor
final class TaskRunnerState: ObservableObject {
    @Published var detectedTasks: [ProjectTask] = []
    @Published var selectedTaskID: String?
    @Published var isRunning: Bool = false
    @Published var activeTaskName: String = ""
    @Published var lastExitCode: Int32?
    @Published var outputLines: [TaskOutputLine] = []
    @Published private(set) var outputRevision: Int = 0

    private var activeProcess: Process?
    private var activeRunToken: UUID?

    var selectedTask: ProjectTask? {
        if let selectedTaskID, let found = detectedTasks.first(where: { $0.id == selectedTaskID }) {
            return found
        }
        return detectedTasks.first
    }

    func refreshTasks(in rootURL: URL, activeFileURL: URL?, hasWorkspaceOpen: Bool) {
        guard hasWorkspaceOpen else {
            detectedTasks = []
            selectedTaskID = nil
            return
        }
        let tasks = ProjectTaskDetector.detectTasks(in: rootURL, activeFileURL: activeFileURL)
        detectedTasks = tasks
        if let current = selectedTaskID, tasks.contains(where: { $0.id == current }) {
            return
        }
        selectedTaskID = tasks.first(where: { $0.kind == .run })?.id ?? tasks.first?.id
    }

    func runDefault(kind: ProjectTaskKind, in workspaceRoot: URL, activeFileURL: URL?) {
        if kind == .run, let selected = selectedTask {
            run(task: selected, in: workspaceRoot)
            return
        }
        if let match = detectedTasks.first(where: { $0.kind == kind }) {
            if kind == .run {
                selectedTaskID = match.id
            }
            run(task: match, in: workspaceRoot)
            return
        }
        if let first = detectedTasks.first {
            run(task: first, in: workspaceRoot)
        }
    }

    func run(task: ProjectTask, in workspaceRoot: URL) {
        if isRunning {
            stop()
        }

        let runToken = UUID()
        activeRunToken = runToken
        selectedTaskID = task.id
        isRunning = true
        activeTaskName = task.name
        lastExitCode = nil
        outputLines = [
            TaskOutputLine(text: "$ \(task.command)", isError: false, location: nil)
        ]
        outputRevision &+= 1

        let root = workspaceRoot
        Task.detached(priority: .userInitiated) { [weak self] in
            let weakSelf = self
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-l", "-c", task.command]
            proc.currentDirectoryURL = root
            proc.environment = ToolchainEnvironment.augmentedEnvironment()

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

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
            let emitParsedLines: @Sendable ([String], Bool) -> Void = { rawLines, isError in
                guard !rawLines.isEmpty else { return }
                let parsed = rawLines.map { line in
                    TaskOutputLine(
                        text: line,
                        isError: isError,
                        location: OutputLocationParser.parseLocation(from: line, workspaceRoot: root)
                    )
                }
                Task { @MainActor in
                    weakSelf?.appendLines(parsed, for: runToken)
                }
            }

            let shouldProceed = await MainActor.run { () -> Bool in
                guard let strongSelf = weakSelf, strongSelf.activeRunToken == runToken else {
                    return false
                }
                strongSelf.activeProcess = proc
                return true
            }
            guard shouldProceed else { return }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                emitParsedLines(decoderState.append(data, isError: false), false)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                emitParsedLines(decoderState.append(data, isError: true), true)
            }

            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                let errLine = TaskOutputLine(text: error.localizedDescription, isError: true, location: nil)
                await MainActor.run {
                    weakSelf?.appendLines([errLine], for: runToken)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            let tailOut = decoderState.append(remainingOut, isError: false) + decoderState.flush(isError: false)
            if !tailOut.isEmpty {
                let parsed = tailOut.map {
                    TaskOutputLine(text: $0, isError: false, location: OutputLocationParser.parseLocation(from: $0, workspaceRoot: root))
                }
                await MainActor.run {
                    weakSelf?.appendLines(parsed, for: runToken)
                }
            }

            let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            let tailErr = decoderState.append(remainingErr, isError: true) + decoderState.flush(isError: true)
            if !tailErr.isEmpty {
                let parsed = tailErr.map {
                    TaskOutputLine(text: $0, isError: true, location: OutputLocationParser.parseLocation(from: $0, workspaceRoot: root))
                }
                await MainActor.run {
                    weakSelf?.appendLines(parsed, for: runToken)
                }
            }

            let status = proc.terminationStatus
            await MainActor.run {
                guard let strongSelf = weakSelf, strongSelf.activeRunToken == runToken else { return }
                strongSelf.isRunning = false
                strongSelf.activeProcess = nil
                strongSelf.lastExitCode = status
                strongSelf.appendLines(
                    [TaskOutputLine(
                        text: L10n("runner.exitCodeFormat", Int(status)),
                        isError: status != 0,
                        location: nil
                    )],
                    for: runToken
                )
            }
        }
    }

    func stop() {
        activeRunToken = nil
        if let proc = activeProcess, proc.isRunning {
            ProcessRunner.terminateProcessTree(rootPID: proc.processIdentifier)
        }
        activeProcess = nil
        isRunning = false
    }

    func clear() {
        outputLines.removeAll()
        lastExitCode = nil
        outputRevision &+= 1
    }

    private func appendLines(_ newLines: [TaskOutputLine], for runToken: UUID) {
        guard activeRunToken == runToken, !newLines.isEmpty else { return }
        outputLines.append(contentsOf: newLines)
        if outputLines.count > 2500 {
            outputLines.removeFirst(outputLines.count - 2500)
        }
        outputRevision &+= 1
    }
}
