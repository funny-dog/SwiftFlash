import Darwin
import Foundation

// MARK: - Unified Toolchain Environment

enum ToolchainEnvironment {
    static func augmentedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        prependDirs: [String] = [],
        extraVariables: [String: String] = [:]
    ) -> [String: String] {
        var env = base
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultBins = [
            "/opt/homebrew/bin",
            "/opt/homebrew/opt/llvm/bin",
            "/usr/local/bin",
            "\(home)/.cargo/bin",
            "\(home)/go/bin",
            "\(home)/.local/bin"
        ]
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)

        var seen = Set<String>()
        var merged: [String] = []
        for dir in prependDirs + defaultBins + existing {
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            merged.append(trimmed)
        }
        env["PATH"] = merged.joined(separator: ":")
        for (k, v) in extraVariables {
            env[k] = v
        }
        return env
    }

    static func searchDirectories() -> [String] {
        let env = augmentedEnvironment()
        return (env["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
    }
}

// MARK: - Incremental UTF-8 & Line Stream Decoder

struct IncrementalLineDecoder: Sendable {
    private var pendingBytes = Data()
    private var pendingLine = ""

    /// Decodes an arbitrary chunk of bytes without dropping split multi-byte UTF-8
    /// sequences or splitting lines mid-way.
    mutating func append(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        pendingBytes.append(chunk)

        let completeCount = Self.validUTF8PrefixLength(in: pendingBytes)
        guard completeCount > 0 else { return [] }

        let decodable = pendingBytes.prefix(completeCount)
        pendingBytes.removeFirst(completeCount)

        let text = String(decoding: decodable, as: UTF8.self)
        return consumeText(text)
    }

    /// Flushes any trailing bytes and unterminated line at EOF.
    mutating func flush() -> [String] {
        var result: [String] = []
        if !pendingBytes.isEmpty {
            let text = String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll(keepingCapacity: false)
            result.append(contentsOf: consumeText(text))
        }
        if !pendingLine.isEmpty {
            let finalLine = stripTrailingCR(pendingLine)
            pendingLine.removeAll(keepingCapacity: false)
            if !finalLine.isEmpty {
                result.append(finalLine)
            }
        }
        return result
    }

    private mutating func consumeText(_ text: String) -> [String] {
        var emitted: [String] = []
        var segmentStart = text.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx] == "\n" {
                pendingLine.append(contentsOf: text[segmentStart..<idx])
                let finished = stripTrailingCR(pendingLine)
                pendingLine.removeAll(keepingCapacity: true)
                if !finished.isEmpty {
                    emitted.append(finished)
                }
                idx = text.index(after: idx)
                segmentStart = idx
            } else {
                idx = text.index(after: idx)
            }
        }
        if segmentStart < text.endIndex {
            pendingLine.append(contentsOf: text[segmentStart..<text.endIndex])
        }
        return emitted
    }

    private func stripTrailingCR(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    /// Returns the number of leading bytes that form complete UTF-8 sequences
    /// (excluding up to 3 trailing bytes of an incomplete multi-byte character).
    private static func validUTF8PrefixLength(in data: Data) -> Int {
        let count = data.count
        guard count > 0 else { return 0 }

        // Walk back at most 3 bytes to check for an incomplete UTF-8 sequence at the tail.
        let maxLookback = min(3, count)
        for back in 1...maxLookback {
            let pos = count - back
            let byte = data[data.index(data.startIndex, offsetBy: pos)]
            if byte & 0x80 == 0 {
                // ASCII byte: everything up to the end is complete (or malformed continuation bytes we let UTF8 decoder replace).
                return count
            }
            if byte & 0xC0 != 0x80 {
                // Found a UTF-8 leading byte; check expected sequence length.
                let expectedLength: Int
                if byte & 0xE0 == 0xC0 {
                    expectedLength = 2
                } else if byte & 0xF0 == 0xE0 {
                    expectedLength = 3
                } else if byte & 0xF8 == 0xF0 {
                    expectedLength = 4
                } else {
                    // Invalid leading byte; let String(decoding:as:UTF8.self) emit U+FFFD immediately.
                    return count
                }
                return back < expectedLength ? pos : count
            }
        }
        return count
    }
}

// MARK: - Deadlock-Free Process Runner & Process Tree Termination

struct ProcessRunResult: Sendable {
    let exitCode: Int32
    let stdoutData: Data
    let stderrData: Data
    let timedOut: Bool

    var stdout: String {
        String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self)
    }

    var stderr: String {
        String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)
    }
}

enum ProcessRunner {
    /// Runs an external command while draining stdout and stderr concurrently to prevent
    /// 64KB pipe buffer deadlocks, with optional timeout termination of the full process tree.
    static func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                exitCode: -1,
                stdoutData: Data(),
                stderrData: Data(error.localizedDescription.utf8),
                timedOut: false
            )
        }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            var stdout = Data()
            var stderr = Data()
            var didTimeout = false

            func setStdout(_ data: Data) {
                lock.lock()
                stdout = data
                lock.unlock()
            }

            func setStderr(_ data: Data) {
                lock.lock()
                stderr = data
                lock.unlock()
            }

            func markTimedOut() {
                lock.lock()
                didTimeout = true
                lock.unlock()
            }

            func snapshot() -> (Data, Data, Bool) {
                lock.lock()
                defer { lock.unlock() }
                return (stdout, stderr, didTimeout)
            }
        }

        let box = Box()
        let group = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = outHandle.readDataToEndOfFile()
            box.setStdout(data)
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = errHandle.readDataToEndOfFile()
            box.setStderr(data)
            group.leave()
        }

        var timeoutItem: DispatchWorkItem?
        if let timeoutSeconds, timeoutSeconds > 0 {
            let pid = process.processIdentifier
            let item = DispatchWorkItem {
                if process.isRunning {
                    box.markTimedOut()
                    terminateProcessTree(rootPID: pid)
                }
            }
            timeoutItem = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: item)
        }

        process.waitUntilExit()
        timeoutItem?.cancel()
        group.wait()

        let (stdoutData, stderrData, timedOut) = box.snapshot()
        return ProcessRunResult(
            exitCode: timedOut ? -2 : process.terminationStatus,
            stdoutData: stdoutData,
            stderrData: stderrData,
            timedOut: timedOut
        )
    }

    /// Terminates a process together with all of its descendant child processes so shell
    /// subcommands (e.g. `swift run`, `npm run dev`) never leak as orphaned processes.
    static func terminateProcessTree(rootPID: pid_t) {
        guard rootPID > 1 else { return }
        let descendants = descendantPIDs(of: rootPID)
        // Signal deepest children first, then the root shell process.
        for pid in descendants.reversed() {
            Darwin.kill(pid, SIGINT)
            Darwin.kill(pid, SIGTERM)
        }
        Darwin.kill(rootPID, SIGINT)
        Darwin.kill(rootPID, SIGTERM)
    }

    static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var bufferSize: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0) == 0, bufferSize > 0 else {
            return []
        }

        let count = bufferSize / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var actualSize = bufferSize
        guard sysctl(&mib, UInt32(mib.count), &procs, &actualSize, nil, 0) == 0 else {
            return []
        }
        let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for i in 0..<actualCount {
            let p = procs[i]
            let pid = p.kp_proc.p_pid
            let ppid = p.kp_eproc.e_ppid
            if pid > 0 {
                childrenByParent[ppid, default: []].append(pid)
            }
        }

        var result: [pid_t] = []
        var queue: [pid_t] = childrenByParent[rootPID] ?? []
        var visited = Set<pid_t>([rootPID])
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            guard visited.insert(current).inserted else { continue }
            result.append(current)
            if let next = childrenByParent[current] {
                queue.append(contentsOf: next)
            }
        }
        return result
    }
}
