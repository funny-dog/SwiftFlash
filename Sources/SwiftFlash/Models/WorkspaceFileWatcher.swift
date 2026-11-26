import CoreServices
import Foundation

// MARK: - FSEvents Workspace File Watcher

struct WorkspaceFileChangeBatch: Equatable, Sendable {
    var structureChanged: Bool = false
    var gitChanged: Bool = false
    var modifiedFilePaths: Set<String> = []

    var isEmpty: Bool {
        !structureChanged && !gitChanged && modifiedFilePaths.isEmpty
    }
}

final class WorkspaceFileWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.swiftflash.fsevents", qos: .utility)
    private let lock = NSLock()
    private var streamRef: FSEventStreamRef?
    private var watchedRootPath: String = ""
    private var pendingBatch = WorkspaceFileChangeBatch()
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private let onBatch: @Sendable (WorkspaceFileChangeBatch) -> Void

    init(
        debounceInterval: TimeInterval = 0.25,
        onBatch: @escaping @Sendable (WorkspaceFileChangeBatch) -> Void
    ) {
        self.debounceInterval = max(0.05, debounceInterval)
        self.onBatch = onBatch
    }

    deinit {
        stop()
    }

    func start(watching rootURL: URL) {
        stop()

        let resolvedPath = rootURL.resolvingSymlinksInPath().standardized.path
        guard FileManager.default.fileExists(atPath: resolvedPath) else { return }

        lock.lock()
        watchedRootPath = resolvedPath
        pendingBatch = WorkspaceFileChangeBatch()
        lock.unlock()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [resolvedPath] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.12,
            flags
        ) else {
            return
        }

        lock.lock()
        streamRef = stream
        lock.unlock()

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        lock.lock()
        let stream = streamRef
        streamRef = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingBatch = WorkspaceFileChangeBatch()
        lock.unlock()

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Pure classifier exposed for deterministic unit testing.
    static func classifyEvent(
        path: String,
        flags: FSEventStreamEventFlags,
        rootPath: String
    ) -> (structure: Bool, git: Bool, modifiedFilePath: String?) {
        let stdPath = URL(fileURLWithPath: path).standardized.path
        let relative: String
        if stdPath == rootPath {
            relative = ""
        } else if stdPath.hasPrefix(rootPath + "/") {
            relative = String(stdPath.dropFirst(rootPath.count + 1))
        } else {
            relative = stdPath
        }

        let components = relative.split(separator: "/").map(String.init)
        if components.contains(".git") {
            // Only care about meaningful git metadata changes, not noisy pack/object writes.
            if relative == ".git"
                || relative.hasPrefix(".git/HEAD")
                || relative.hasPrefix(".git/index")
                || relative.hasPrefix(".git/refs")
                || relative.hasPrefix(".git/MERGE_HEAD")
                || relative.hasPrefix(".git/packed-refs") {
                return (false, true, nil)
            }
            return (false, false, nil)
        }

        for segment in components {
            if FileItem.ignoredNames.contains(segment) {
                return (false, false, nil)
            }
        }

        let rescanFlag = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )
        if (flags & rescanFlag) != 0 {
            return (true, true, nil)
        }

        let structureFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed
        )
        let isStructure = (flags & structureFlags) != 0
        let isFile = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)) != 0
        let isModified = (flags & FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemInodeMetaMod
                | kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRenamed
        )) != 0

        if isFile && isModified {
            return (isStructure, true, stdPath)
        }
        return (isStructure, isStructure, nil)
    }

    private func handleRawEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        lock.lock()
        let rootPath = watchedRootPath
        var didUpdate = false

        for idx in 0..<min(paths.count, flags.count) {
            let classified = Self.classifyEvent(path: paths[idx], flags: flags[idx], rootPath: rootPath)
            if classified.structure {
                pendingBatch.structureChanged = true
                didUpdate = true
            }
            if classified.git {
                pendingBatch.gitChanged = true
                didUpdate = true
            }
            if let filePath = classified.modifiedFilePath {
                pendingBatch.modifiedFilePaths.insert(filePath)
                didUpdate = true
            }
        }

        guard didUpdate else {
            lock.unlock()
            return
        }

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingBatch()
        }
        debounceWorkItem = work
        let delay = debounceInterval
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushPendingBatch() {
        lock.lock()
        let batch = pendingBatch
        pendingBatch = WorkspaceFileChangeBatch()
        debounceWorkItem = nil
        lock.unlock()

        guard !batch.isEmpty else { return }
        onBatch(batch)
    }

    private static let eventCallback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
        guard let info = clientCallBackInfo, numEvents > 0 else { return }
        let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue()
        guard let cfArray = unsafeBitCast(eventPaths, to: CFArray?.self) else { return }

        var paths: [String] = []
        paths.reserveCapacity(numEvents)
        var flags: [FSEventStreamEventFlags] = []
        flags.reserveCapacity(numEvents)

        for i in 0..<numEvents {
            if let rawPtr = CFArrayGetValueAtIndex(cfArray, i) {
                let cfStr = unsafeBitCast(rawPtr, to: CFString.self)
                paths.append(cfStr as String)
                flags.append(eventFlags[i])
            }
        }
        watcher.handleRawEvents(paths: paths, flags: flags)
    }
}
