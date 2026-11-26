import AppKit
import Foundation

// MARK: - Concurrent, Deadlock-Free Git Runner & Parsers

struct GitMetadataSnapshot: Sendable {
    let repoTopLevel: URL
    let branch: String
    let currentWorktreeName: String
    let worktrees: [GitWorktreeItem]
    let branches: [GitBranchItem]
    let changes: [GitChangedFileItem]
    let commitHistory: [GitCommitLogItem]
    let lastCommitShortHash: String
    let lastCommitSubject: String
    let aheadCount: Int
    let behindCount: Int
}

enum GitService {
    static func runGit(
        _ arguments: [String],
        in directory: URL,
        timeoutSeconds: TimeInterval = 20
    ) -> ProcessRunResult {
        ProcessRunner.run(
            executablePath: "/usr/bin/git",
            arguments: ["-C", directory.path] + arguments,
            environment: ToolchainEnvironment.augmentedEnvironment(
                extraVariables: [
                    "GIT_TERMINAL_PROMPT": "0",
                    "GCM_INTERACTIVE": "never"
                ]
            ),
            timeoutSeconds: timeoutSeconds
        )
    }

    static func fetchMetadataSnapshot(in root: URL) async -> GitMetadataSnapshot? {
        let isRepoRes = runGit(["rev-parse", "--is-inside-work-tree"], in: root, timeoutSeconds: 8)
        guard isRepoRes.exitCode == 0,
              isRepoRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }

        let topLevelRes = runGit(["rev-parse", "--show-toplevel"], in: root, timeoutSeconds: 8)
        let repoTopLevel = topLevelRes.exitCode == 0
            ? URL(fileURLWithPath: topLevelRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                .resolvingSymlinksInPath()
                .standardized
            : root.resolvingSymlinksInPath().standardized

        // Execute independent git queries concurrently instead of 9 serial subprocess launches.
        async let headBranchTask = Task.detached(priority: .utility) {
            let res = runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: root, timeoutSeconds: 8)
            var name = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "HEAD" || name.isEmpty {
                let shaRes = runGit(["rev-parse", "--short", "HEAD"], in: root, timeoutSeconds: 8)
                let sha = shaRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                name = sha.isEmpty ? "HEAD" : sha
            }
            return name
        }.value

        async let worktreeTask = Task.detached(priority: .utility) {
            let res = runGit(["worktree", "list", "--porcelain"], in: root, timeoutSeconds: 8)
            return parseWorktrees(res.stdout, currentRepoPath: repoTopLevel.path)
        }.value

        async let branchTask = Task.detached(priority: .utility) {
            let res = runGit(
                ["branch", "-a", "--format=%(refname)|%(refname:short)|%(HEAD)|%(objectname:short)"],
                in: root,
                timeoutSeconds: 8
            )
            return parseBranches(res.stdout)
        }.value

        async let statusTask = Task.detached(priority: .utility) {
            let res = runGit(["-c", "core.quotepath=false", "status", "--porcelain=v1", "-uall"], in: repoTopLevel, timeoutSeconds: 12)
            return parseGitStatus(res.stdout, repoTopLevel: repoTopLevel)
        }.value

        async let historyTask = Task.detached(priority: .utility) {
            let res = runGit(
                ["log", "-n", "40", "--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%ar"],
                in: repoTopLevel,
                timeoutSeconds: 10
            )
            return res.exitCode == 0 ? parseCommitHistory(res.stdout) : []
        }.value

        async let revListTask = Task.detached(priority: .utility) { () -> (Int, Int) in
            let res = runGit(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: repoTopLevel, timeoutSeconds: 8)
            guard res.exitCode == 0 else { return (0, 0) }
            let counts = res.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace })
            if counts.count >= 2 {
                return (Int(counts[0]) ?? 0, Int(counts[1]) ?? 0)
            }
            return (0, 0)
        }.value

        let (currentBranch, worktrees, branches, changes, history, aheadBehind) = await (
            headBranchTask,
            worktreeTask,
            branchTask,
            statusTask,
            historyTask,
            revListTask
        )

        let resolvedWorktreeName: String = {
            if let activeWT = worktrees.first(where: { $0.isCurrent }) {
                if worktrees.first?.id == activeWT.id {
                    return activeWT.branch.isEmpty ? activeWT.name : activeWT.branch
                }
                return activeWT.name
            }
            return currentBranch
        }()

        return GitMetadataSnapshot(
            repoTopLevel: repoTopLevel,
            branch: currentBranch,
            currentWorktreeName: resolvedWorktreeName,
            worktrees: worktrees,
            branches: branches,
            changes: changes,
            commitHistory: history,
            lastCommitShortHash: history.first?.shortHash ?? "",
            lastCommitSubject: history.first?.subject ?? "",
            aheadCount: aheadBehind.0,
            behindCount: aheadBehind.1
        )
    }

    static func parseWorktrees(_ output: String, currentRepoPath: String) -> [GitWorktreeItem] {
        var items: [GitWorktreeItem] = []
        let blocks = output.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !lines.isEmpty else { continue }

            var path: String?
            var head = ""
            var branch = ""
            var isDetached = false

            for line in lines {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count).prefix(7))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                } else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst("branch ".count))
                } else if line == "detached" {
                    isDetached = true
                }
            }

            guard let path else { continue }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized
            let isCurrent = (url.path == currentRepoPath)
            let displayBranch = isDetached ? (head.isEmpty ? "detached" : head) : branch
            items.append(
                GitWorktreeItem(
                    id: url.path,
                    url: url,
                    name: url.lastPathComponent,
                    branch: displayBranch,
                    commitShort: head,
                    isCurrent: isCurrent,
                    isDetached: isDetached
                )
            )
        }
        return items
    }

    static func parseBranches(_ output: String) -> [GitBranchItem] {
        var branches: [GitBranchItem] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let fullRef = parts[0]
            let shortName = parts[1]
            let headFlag = parts[2]
            let commitShort = parts[3]

            if fullRef.hasSuffix("/HEAD") || shortName == "origin" { continue }
            let isRemote = fullRef.hasPrefix("refs/remotes/")
            let key = "\(isRemote ? "R" : "L"):\(shortName)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            branches.append(
                GitBranchItem(
                    id: key,
                    name: shortName,
                    isCurrent: headFlag == "*",
                    isCheckedOutElsewhere: headFlag == "+",
                    isRemote: isRemote,
                    commitShort: commitShort
                )
            )
        }
        return branches
    }

    static func parseGitStatus(_ output: String, repoTopLevel: URL) -> [GitChangedFileItem] {
        var items: [GitChangedFileItem] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count >= 4 else { continue }

            let x = String(line.prefix(1))
            let y = String(line.dropFirst(1).prefix(1))
            var relPath = String(line.dropFirst(3))

            if (x == "R" || x == "C"), let range = relPath.range(of: " -> ") {
                relPath = String(relPath[range.upperBound...])
            }
            relPath = unquoteGitPath(relPath)

            let isUntracked = (x == "?" && y == "?")
            let isStaged = !isUntracked && x != " " && x != "!"
            let hasUnstagedChanges = isUntracked || (y != " " && y != "!")

            let displayStatus: String
            if isUntracked {
                displayStatus = "?"
            } else if x == "U" || y == "U" {
                displayStatus = "!"
            } else if y != " " {
                displayStatus = y
            } else {
                displayStatus = x
            }

            let fileURL = repoTopLevel.appendingPathComponent(relPath)
            let fileName = (relPath as NSString).lastPathComponent
            items.append(
                GitChangedFileItem(
                    id: relPath,
                    url: fileURL,
                    relativePath: relPath,
                    fileName: fileName,
                    indexStatus: x,
                    worktreeStatus: y,
                    isStaged: isStaged,
                    hasUnstagedChanges: hasUnstagedChanges,
                    isUntracked: isUntracked,
                    displayStatus: displayStatus
                )
            )
        }
        return items
    }

    static func unquoteGitPath(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return raw }
        let inner = String(raw.dropFirst().dropLast())
        var result = ""
        result.reserveCapacity(inner.count)
        var escaped = false
        for ch in inner {
            if escaped {
                switch ch {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "t": result.append("\t")
                case "n": result.append("\n")
                default:
                    result.append("\\")
                    result.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                result.append(ch)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    static func parseCommitHistory(_ output: String) -> [GitCommitLogItem] {
        var items: [GitCommitLogItem] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = String(rawLine).components(separatedBy: "\u{1F}")
            guard parts.count >= 5 else { continue }
            items.append(
                GitCommitLogItem(
                    id: parts[0],
                    hash: parts[0],
                    shortHash: parts[1],
                    subject: parts[2],
                    author: parts[3],
                    relativeDate: parts[4]
                )
            )
        }
        return items
    }
}

// MARK: - WorkspaceState Git Integration

extension WorkspaceState {
    var filteredGitChanges: [GitChangedFileItem] {
        switch gitChangeFilter {
        case .all:
            return gitChanges
        case .staged:
            return gitChanges.filter { $0.isStaged }
        case .unstaged:
            return gitChanges.filter { $0.hasUnstagedChanges && !$0.isUntracked }
        case .untracked:
            return gitChanges.filter { $0.isUntracked }
        }
    }

    func refreshGitMetadata() {
        gitMetadataTask?.cancel()
        let root = rootURL.standardized
        gitMetadataTask = Task.detached(priority: .utility) {
            let snapshot = await GitService.fetchMetadataSnapshot(in: root)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.rootURL.standardized.path == root.path else { return }
                guard let snapshot else {
                    self.isGitRepository = false
                    self.gitRepoTopLevel = nil
                    self.gitBranch = "no-git"
                    self.currentWorktreeName = root.lastPathComponent
                    self.gitWorktrees = []
                    self.gitBranches = []
                    self.gitChanges = []
                    self.gitCommitHistory = []
                    self.lastCommitSubject = ""
                    self.lastCommitShortHash = ""
                    self.gitAheadCount = 0
                    self.gitBehindCount = 0
                    return
                }
                self.isGitRepository = true
                self.gitRepoTopLevel = snapshot.repoTopLevel
                self.gitBranch = snapshot.branch
                self.currentWorktreeName = snapshot.currentWorktreeName
                self.gitWorktrees = snapshot.worktrees
                self.gitBranches = snapshot.branches
                self.gitChanges = snapshot.changes
                self.gitCommitHistory = snapshot.commitHistory
                self.lastCommitShortHash = snapshot.lastCommitShortHash
                self.lastCommitSubject = snapshot.lastCommitSubject
                self.gitAheadCount = snapshot.aheadCount
                self.gitBehindCount = snapshot.behindCount
            }
        }
    }

    func switchWorktree(to item: GitWorktreeItem) {
        switchProject(to: item.url)
        statusMessage = L10n("status.worktreeSwitchedFormat", item.name, item.branch)
    }

    func createAndSwitchWorktree(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty, isGitRepository else { return }

        let sanitizedDirSuffix = name.replacingOccurrences(of: "/", with: "-")
        let baseRepoDir = gitWorktrees.first?.url ?? rootURL
        let targetURL = baseRepoDir.deletingLastPathComponent()
            .appendingPathComponent("\(baseRepoDir.lastPathComponent)-\(sanitizedDirSuffix)")
            .standardized

        if FileManager.default.fileExists(atPath: targetURL.path) {
            switchProject(to: targetURL)
            statusMessage = L10n("status.openedWorktreeFormat", targetURL.lastPathComponent)
            return
        }

        let currentRoot = rootURL.standardized
        let hasLocalBranch = gitBranches.contains { !$0.isRemote && $0.name == name }
        beginGitOperation()

        Task.detached(priority: .userInitiated) {
            let args: [String] = hasLocalBranch
                ? ["worktree", "add", targetURL.path, name]
                : ["worktree", "add", "-b", name, targetURL.path]
            let res = GitService.runGit(args, in: currentRoot, timeoutSeconds: 30)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == currentRoot.path else { return }
                if res.exitCode == 0 {
                    self.switchProject(to: targetURL)
                    self.statusMessage = L10n("status.createdWorktreeFormat", targetURL.lastPathComponent, name)
                } else {
                    let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = msg.isEmpty ? L10n("status.failedWorktree") : msg
                }
            }
        }
    }

    func switchGitBranch(to branchName: String, createNew: Bool = false, isRemote: Bool = false) {
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isGitRepository else { return }

        let currentRoot = rootURL.standardized
        beginGitOperation()

        Task.detached(priority: .userInitiated) {
            let args: [String]
            if createNew {
                args = ["checkout", "-b", trimmed]
            } else if isRemote {
                let localCandidate = trimmed.split(separator: "/", maxSplits: 1).last.map(String.init) ?? trimmed
                let checkLocal = GitService.runGit(["show-ref", "--verify", "--quiet", "refs/heads/\(localCandidate)"], in: currentRoot)
                if checkLocal.exitCode == 0 {
                    args = ["checkout", localCandidate]
                } else {
                    args = ["checkout", "--track", trimmed]
                }
            } else {
                args = ["checkout", trimmed]
            }

            let res = GitService.runGit(args, in: currentRoot, timeoutSeconds: 30)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == currentRoot.path else { return }
                if res.exitCode == 0 {
                    self.reloadWorkspace()
                    self.reloadUnmodifiedOpenTabs()
                    self.statusMessage = L10n("status.switchedBranchFormat", trimmed)
                    self.dismissOverlay()
                } else {
                    let errMsg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = errMsg.isEmpty ? L10n("status.gitCheckoutFailed") : errMsg
                }
            }
        }
    }

    func initializeGitRepository() {
        let currentRoot = rootURL.standardized
        beginGitOperation()
        Task.detached(priority: .userInitiated) {
            let res = GitService.runGit(["init"], in: currentRoot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == currentRoot.path else { return }
                if res.exitCode == 0 {
                    self.refreshGitMetadata()
                    self.statusMessage = L10n("status.initializedGitFormat", currentRoot.lastPathComponent)
                } else {
                    self.statusMessage = L10n("status.gitInitFailedFormat", res.stderr)
                }
            }
        }
    }

    func stageGitFile(_ item: GitChangedFileItem) {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        runGitMutation(["add", "--", item.relativePath], in: repoDir, successMessage: L10n("status.stagedFileFormat", item.fileName))
    }

    func unstageGitFile(_ item: GitChangedFileItem) {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let hasHead = !lastCommitShortHash.isEmpty
        let args = hasHead
            ? ["reset", "-q", "HEAD", "--", item.relativePath]
            : ["rm", "--cached", "-q", "--", item.relativePath]
        runGitMutation(args, in: repoDir, successMessage: L10n("status.unstagedFileFormat", item.fileName))
    }

    func toggleStageGitFile(_ item: GitChangedFileItem) {
        if item.isStaged && !item.hasUnstagedChanges {
            unstageGitFile(item)
        } else {
            stageGitFile(item)
        }
    }

    func stageAllGitChanges(trackedOnly: Bool = false) {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let args = trackedOnly ? ["add", "-u"] : ["add", "-A"]
        let msg = trackedOnly ? L10n("status.stagedAllTracked") : L10n("status.stagedAll")
        runGitMutation(args, in: repoDir, successMessage: msg)
    }

    func unstageAllGitChanges() {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let hasHead = !lastCommitShortHash.isEmpty
        let args = hasHead ? ["reset", "-q", "HEAD"] : ["rm", "-r", "--cached", "-q", "."]
        runGitMutation(args, in: repoDir, successMessage: L10n("status.unstagedAll"))
    }

    func discardGitFileChanges(_ item: GitChangedFileItem) {
        guard isGitRepository else { return }
        let alert = NSAlert()
        alert.messageText = L10n("alert.discardFile.titleFormat", item.fileName)
        alert.informativeText = item.isUntracked
            ? L10n("alert.discardFile.untrackedMsg")
            : L10n("alert.discardFile.modifiedMsg")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n("common.discard"))
        alert.addButton(withTitle: L10n("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let repoDir = gitRepoTopLevel ?? rootURL
        let expectedRoot = rootURL.standardized.path
        beginGitOperation()
        Task.detached(priority: .userInitiated) {
            let res: ProcessRunResult
            if item.isUntracked {
                res = GitService.runGit(["clean", "-fd", "--", item.relativePath], in: repoDir)
            } else if item.indexStatus == "A" {
                res = GitService.runGit(["rm", "-f", "--", item.relativePath], in: repoDir)
            } else {
                if item.isStaged {
                    _ = GitService.runGit(["reset", "-q", "HEAD", "--", item.relativePath], in: repoDir)
                }
                res = GitService.runGit(["checkout", "--", item.relativePath], in: repoDir)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == expectedRoot else { return }
                if res.exitCode == 0 {
                    self.reloadWorkspace()
                    self.reloadUnmodifiedOpenTabs()
                    self.statusMessage = L10n("status.discardedFileFormat", item.fileName)
                } else {
                    let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = msg.isEmpty ? L10n("status.failedDiscardFileFormat", item.fileName) : msg
                }
            }
        }
    }

    func discardAllUnstagedGitChanges() {
        guard isGitRepository else { return }
        let alert = NSAlert()
        alert.messageText = L10n("alert.discardAll.title")
        alert.informativeText = L10n("alert.discardAll.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n("common.discardAll"))
        alert.addButton(withTitle: L10n("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let repoDir = gitRepoTopLevel ?? rootURL
        let expectedRoot = rootURL.standardized.path
        let hasHead = !lastCommitShortHash.isEmpty
        beginGitOperation()
        Task.detached(priority: .userInitiated) {
            let checkoutRes: ProcessRunResult? = hasHead
                ? GitService.runGit(["checkout", "--", "."], in: repoDir)
                : nil
            let cleanRes = GitService.runGit(["clean", "-fd"], in: repoDir)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == expectedRoot else { return }
                let checkoutOK = (checkoutRes?.exitCode ?? 0) == 0
                if checkoutOK && cleanRes.exitCode == 0 {
                    self.reloadWorkspace()
                    self.reloadUnmodifiedOpenTabs()
                    self.statusMessage = L10n("status.discardedAll")
                } else {
                    let msg = ((checkoutRes?.stderr ?? "") + " " + cleanRes.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = msg.isEmpty ? L10n("status.failedDiscardAll") : msg
                }
            }
        }
    }

    func commitGitChanges() {
        guard isGitRepository else { return }
        let msg = gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty && gitCommitActionMode != .amend {
            statusMessage = L10n("status.enterCommitMessage")
            return
        }

        let repoDir = gitRepoTopLevel ?? rootURL
        let expectedRoot = rootURL.standardized.path
        let mode = gitCommitActionMode
        beginGitOperation()

        Task.detached(priority: .userInitiated) {
            let res: ProcessRunResult
            switch mode {
            case .commitTracked:
                res = GitService.runGit(["commit", "-a", "-m", msg], in: repoDir, timeoutSeconds: 30)
            case .commitStaged:
                res = GitService.runGit(["commit", "-m", msg], in: repoDir, timeoutSeconds: 30)
            case .commitAll:
                let addRes = GitService.runGit(["add", "-A"], in: repoDir, timeoutSeconds: 30)
                if addRes.exitCode != 0 {
                    res = addRes
                } else {
                    res = GitService.runGit(["commit", "-m", msg], in: repoDir, timeoutSeconds: 30)
                }
            case .amend:
                if msg.isEmpty {
                    res = GitService.runGit(["commit", "--amend", "--no-edit"], in: repoDir, timeoutSeconds: 30)
                } else {
                    res = GitService.runGit(["commit", "--amend", "-m", msg], in: repoDir, timeoutSeconds: 30)
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == expectedRoot else { return }
                if res.exitCode == 0 {
                    self.gitCommitMessage = ""
                    self.refreshGitMetadata()
                    let summary = msg.components(separatedBy: .newlines).first ?? mode.rawValue
                    self.statusMessage = L10n("status.committedFormat", summary.isEmpty ? L10n("status.amended") : summary)
                } else {
                    let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let out = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let combined = !err.isEmpty ? err : out
                    self.statusMessage = combined.isEmpty ? L10n("status.commitFailed") : combined
                }
            }
        }
    }

    func uncommitLastGitCommit() {
        guard isGitRepository, !lastCommitShortHash.isEmpty else {
            statusMessage = L10n("status.noCommitToUndo")
            return
        }

        let repoDir = gitRepoTopLevel ?? rootURL
        let expectedRoot = rootURL.standardized.path
        beginGitOperation()

        Task.detached(priority: .userInitiated) {
            let prevMsgRes = GitService.runGit(["log", "-1", "--pretty=format:%B"], in: repoDir)
            let prevMessage = prevMsgRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let hasParent = GitService.runGit(["rev-parse", "--verify", "--quiet", "HEAD~1"], in: repoDir).exitCode == 0
            let resetRes = hasParent
                ? GitService.runGit(["reset", "--soft", "HEAD~1"], in: repoDir)
                : GitService.runGit(["update-ref", "-d", "HEAD"], in: repoDir)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == expectedRoot else { return }
                if resetRes.exitCode == 0 {
                    if self.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prevMessage.isEmpty {
                        self.gitCommitMessage = prevMessage
                    }
                    self.refreshGitMetadata()
                    self.statusMessage = L10n("status.uncommittedLast")
                } else {
                    let err = resetRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = err.isEmpty ? L10n("status.failedUndoCommit") : err
                }
            }
        }
    }

    func generateDraftCommitMessage() {
        let stagedItems = gitChanges.filter { $0.isStaged }
        let targetItems = stagedItems.isEmpty ? gitChanges : stagedItems
        guard !targetItems.isEmpty else {
            statusMessage = L10n("status.noChangesForDraft")
            return
        }

        if targetItems.count == 1, let only = targetItems.first {
            let verb: String
            let prefix: String
            if only.isUntracked || only.indexStatus == "A" {
                prefix = "feat"
                verb = "add"
            } else if only.displayStatus == "D" {
                prefix = "chore"
                verb = "remove"
            } else {
                prefix = "chore"
                verb = "update"
            }
            gitCommitMessage = "\(prefix): \(verb) \(only.fileName)"
        } else {
            let names = targetItems.prefix(2).map(\.fileName).joined(separator: ", ")
            let suffix = targetItems.count > 2 ? " and \(targetItems.count - 2) more files" : ""
            let details = targetItems.prefix(8).map { "- \($0.displayStatus): \($0.relativePath)" }.joined(separator: "\n")
            gitCommitMessage = "chore: update \(names)\(suffix)\n\n\(details)"
        }
        statusMessage = L10n("status.generatedDraft")
    }

    func performGitRemoteAction(_ action: String) {
        guard isGitRepository else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let expectedRoot = rootURL.standardized.path
        let normalized = action.lowercased()
        let args: [String]
        switch normalized {
        case "fetch":
            args = ["fetch", "--prune"]
        case "pull":
            args = ["pull"]
        case "push":
            args = ["push"]
        default:
            return
        }

        beginGitOperation()
        statusMessage = L10n("status.runningGitFormat", normalized)

        Task.detached(priority: .userInitiated) {
            let res = GitService.runGit(args, in: repoDir, timeoutSeconds: 45)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == expectedRoot else { return }
                if res.timedOut {
                    self.statusMessage = L10n("status.gitTimedOutFormat", normalized)
                } else if res.exitCode == 0 {
                    if normalized == "pull" {
                        self.reloadWorkspace()
                        self.reloadUnmodifiedOpenTabs()
                    } else {
                        self.refreshGitMetadata()
                    }
                    self.statusMessage = L10n("status.gitCompletedFormat", normalized)
                } else {
                    let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = err.isEmpty ? L10n("status.gitFailedFormat", normalized) : err
                }
            }
        }
    }

    func openGitDiffInEditor(for item: GitChangedFileItem? = nil) {
        guard isGitRepository else {
            statusMessage = L10n("git.notARepo.title")
            return
        }

        let repoDir = gitRepoTopLevel ?? rootURL
        let expectedRoot = rootURL.standardized.path
        let hasHead = !lastCommitShortHash.isEmpty
        let snapshotChanges = gitChanges

        Task.detached(priority: .userInitiated) {
            var diffChunks: [String] = []
            if let item {
                if item.isUntracked {
                    let res = GitService.runGit(["diff", "--no-index", "--", "/dev/null", item.relativePath], in: repoDir)
                    if !res.stdout.isEmpty { diffChunks.append(res.stdout) }
                } else if hasHead {
                    let res = GitService.runGit(["diff", "HEAD", "--", item.relativePath], in: repoDir)
                    if !res.stdout.isEmpty { diffChunks.append(res.stdout) }
                } else {
                    let staged = GitService.runGit(["diff", "--cached", "--", item.relativePath], in: repoDir)
                    let unstaged = GitService.runGit(["diff", "--", item.relativePath], in: repoDir)
                    if !staged.stdout.isEmpty { diffChunks.append(staged.stdout) }
                    if !unstaged.stdout.isEmpty { diffChunks.append(unstaged.stdout) }
                }
            } else {
                if hasHead {
                    let res = GitService.runGit(["diff", "HEAD"], in: repoDir)
                    if !res.stdout.isEmpty { diffChunks.append(res.stdout) }
                } else {
                    let staged = GitService.runGit(["diff", "--cached"], in: repoDir)
                    let unstaged = GitService.runGit(["diff"], in: repoDir)
                    if !staged.stdout.isEmpty { diffChunks.append(staged.stdout) }
                    if !unstaged.stdout.isEmpty { diffChunks.append(unstaged.stdout) }
                }

                for untracked in snapshotChanges where untracked.isUntracked {
                    // Cap untracked diff size so binary files don't blow up editor memory.
                    let fileSize = (try? untracked.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard fileSize <= 1_000_000 else { continue }
                    let res = GitService.runGit(["diff", "--no-index", "--", "/dev/null", untracked.relativePath], in: repoDir)
                    if !res.stdout.isEmpty { diffChunks.append(res.stdout) }
                }
            }

            let combined = diffChunks.joined(separator: "\n")
            await MainActor.run { [weak self] in
                guard let self, self.rootURL.standardized.path == expectedRoot else { return }
                if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.statusMessage = item == nil ? L10n("status.noUncommittedDiff") : L10n("status.noFileDiffFormat", item!.fileName)
                    return
                }
                let key = item.map { "diff:\($0.relativePath)" } ?? "diff:uncommitted"
                let title = item.map { "Diff: \($0.fileName)" } ?? "Git Diff"
                self.openVirtualDiffTab(key: key, title: title, content: combined)
            }
        }
    }

    func openGitCommitDiffInEditor(commitHash: String, shortHash: String) {
        guard isGitRepository, !commitHash.isEmpty else { return }
        let repoDir = gitRepoTopLevel ?? rootURL
        let expectedRoot = rootURL.standardized.path

        Task.detached(priority: .userInitiated) {
            let res = GitService.runGit(["show", "--stat", "--patch", commitHash], in: repoDir, timeoutSeconds: 20)
            await MainActor.run { [weak self] in
                guard let self, self.rootURL.standardized.path == expectedRoot else { return }
                if res.exitCode == 0, !res.stdout.isEmpty {
                    self.openVirtualDiffTab(
                        key: "commit:\(commitHash)",
                        title: "Commit \(shortHash)",
                        content: res.stdout
                    )
                } else {
                    let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = err.isEmpty ? L10n("status.failedLoadCommitFormat", shortHash) : err
                }
            }
        }
    }

    func openVirtualDiffTab(key: String, title: String, content: String) {
        let displayContent = content.isEmpty ? "# No diff output\n" : content
        if let existingIdx = openTabs.firstIndex(where: { $0.virtualKey == key }) {
            openTabs[existingIdx].title = title
            openTabs[existingIdx].replaceBufferAndMarkSaved(displayContent)
            openTabs[existingIdx].language = .diff
            openTabs[existingIdx].externalReloadRevision += 1
            activeTabID = openTabs[existingIdx].id
        } else {
            let tab = EditorTab(
                id: UUID(),
                url: nil,
                virtualKey: key,
                title: title,
                content: displayContent,
                savedContent: displayContent,
                language: .diff
            )
            openTabs.append(tab)
            activeTabID = tab.id
        }
        statusMessage = title
        onFocusEditorRequested?()
    }

    private func runGitMutation(_ arguments: [String], in repoDir: URL, successMessage: String) {
        let expectedRoot = rootURL.standardized.path
        beginGitOperation()
        Task.detached(priority: .userInitiated) {
            let res = GitService.runGit(arguments, in: repoDir, timeoutSeconds: 20)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.endGitOperation()
                guard self.rootURL.standardized.path == expectedRoot else { return }
                if res.exitCode == 0 {
                    self.refreshGitMetadata()
                    self.statusMessage = successMessage
                } else {
                    let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = err.isEmpty ? L10n("status.gitOpFailed") : err
                }
            }
        }
    }
}
