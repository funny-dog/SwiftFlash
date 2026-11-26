import AppKit
import CoreServices
import XCTest
@testable import SwiftFlash

final class IDEFeaturesTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for suite in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        suiteNames.removeAll()

        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "dev.swiftflash.ide-tests.\(UUID().uuidString)"
        suiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTempDirectory(name: String = UUID().uuidString) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftflash-ide-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    // MARK: - 1. VT100 Emulator & Real PTY Process

    func testVT100EmulatorHandlesSGRCursorAlternateScreenAndOSC() {
        let emu = VT100TerminalEmulator(cols: 40, rows: 6)

        emu.feed(string: "\u{1B}]2;MyShell\u{07}")
        emu.feed(string: "\u{1B}]7;file:///tmp\u{07}")
        emu.feed(string: "\u{1B}[32;1mHello\u{1B}[0m 中文\r\nLine2")

        XCTAssertEqual(emu.title, "MyShell")
        XCTAssertEqual(emu.reportedWorkingDirectory?.path, "/tmp")
        XCTAssertEqual(emu.grid[0][0].char, "H")
        XCTAssertEqual(emu.grid[0][0].attrs.fg, .ansi(2))
        XCTAssertTrue(emu.grid[0][0].attrs.bold)
        // Wide CJK char occupies 2 cells
        XCTAssertEqual(emu.grid[0][6].char, "中")
        XCTAssertEqual(emu.grid[0][6].width, 2)
        XCTAssertEqual(emu.grid[0][7].width, 0)
        XCTAssertTrue(emu.plainScreenText().contains("Hello 中文"))
        XCTAssertTrue(emu.plainScreenText().contains("Line2"))

        // Alternate screen switch preserves main grid
        emu.feed(string: "\u{1B}[?1049hALT_CONTENT")
        XCTAssertTrue(emu.isUsingAlternateScreen)
        XCTAssertTrue(emu.plainScreenText().contains("ALT_CONTENT"))
        XCTAssertFalse(emu.plainScreenText().contains("Line2"))

        emu.feed(string: "\u{1B}[?1049l")
        XCTAssertFalse(emu.isUsingAlternateScreen)
        XCTAssertTrue(emu.plainScreenText().contains("Line2"))

        // TrueColor 24-bit SGR
        emu.feed(string: "\r\n\u{1B}[38;2;12;34;56mX")
        XCTAssertEqual(emu.grid[2][0].attrs.fg, .rgb(12, 34, 56))
    }

    func testRealPTYProcessPersistsShellSessionState() throws {
        let dir = try makeTempDirectory(name: "pty")
        let pty = PTYProcessController()
        let exp = expectation(description: "PTY receives persistent env output")

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var text = ""
            var fulfilled = false
            func append(_ data: Data) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                text += String(decoding: data, as: UTF8.self)
                if !fulfilled && text.contains("PTY_PERSIST_OK_42") {
                    fulfilled = true
                    return true
                }
                return false
            }
        }
        let collector = Collector()
        pty.onOutput = { data in
            if collector.append(data) {
                exp.fulfill()
            }
        }

        try pty.start(workingDirectory: dir, cols: 80, rows: 24)
        defer { pty.stop() }

        // Execute two separate commands to verify shell state persists across commands in real PTY
        pty.write(Data("export SF_PTY_VAR=PTY_PERSIST_OK_42\r".utf8))
        pty.write(Data("echo $SF_PTY_VAR\r".utf8))

        wait(for: [exp], timeout: 6.0)
    }

    // MARK: - 2. FSEvents Classifier & External File Conflict Handling

    func testFileWatcherEventClassifierFiltersNoisyDirectories() {
        let root = "/tmp/demo-repo"
        let modFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        let createFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated)

        let swiftMod = WorkspaceFileWatcher.classifyEvent(path: "\(root)/Sources/App.swift", flags: modFlags, rootPath: root)
        XCTAssertFalse(swiftMod.structure)
        XCTAssertTrue(swiftMod.git)
        XCTAssertEqual(swiftMod.modifiedFilePath, "\(root)/Sources/App.swift")

        let created = WorkspaceFileWatcher.classifyEvent(path: "\(root)/Sources/New.swift", flags: createFlags, rootPath: root)
        XCTAssertTrue(created.structure)
        XCTAssertEqual(created.modifiedFilePath, "\(root)/Sources/New.swift")

        let ignoredBuild = WorkspaceFileWatcher.classifyEvent(path: "\(root)/.build/debug/foo", flags: createFlags, rootPath: root)
        XCTAssertFalse(ignoredBuild.structure)
        XCTAssertNil(ignoredBuild.modifiedFilePath)

        let gitHead = WorkspaceFileWatcher.classifyEvent(path: "\(root)/.git/HEAD", flags: modFlags, rootPath: root)
        XCTAssertTrue(gitHead.git)
        XCTAssertFalse(gitHead.structure)

        let gitObj = WorkspaceFileWatcher.classifyEvent(path: "\(root)/.git/objects/ab/1234", flags: createFlags, rootPath: root)
        XCTAssertFalse(gitObj.git)
    }

    @MainActor
    func testExternalFileChangeAutoReloadsCleanTabAndFlagsConflictOnDirtyTab() throws {
        let dir = try makeTempDirectory(name: "watcher")
        let cleanFile = dir.appendingPathComponent("clean.swift")
        let dirtyFile = dir.appendingPathComponent("dirty.swift")
        try "let v = 1\n".write(to: cleanFile, atomically: true, encoding: .utf8)
        try "let x = 1\n".write(to: dirtyFile, atomically: true, encoding: .utf8)

        let defaults = makeIsolatedDefaults()
        let ws = WorkspaceState(initialURL: dir, userDefaults: defaults)
        defer { ws.teardownResources() }

        ws.openFile(url: cleanFile)
        ws.openFile(url: dirtyFile)
        ws.updateActiveTabContent("let x = 999 // local edit\n")

        // Simulate external edits on disk
        try "let v = 2\n".write(to: cleanFile, atomically: true, encoding: .utf8)
        try "let x = 2 // disk edit\n".write(to: dirtyFile, atomically: true, encoding: .utf8)

        ws.handleExternalFileChangeBatch(
            WorkspaceFileChangeBatch(
                structureChanged: false,
                gitChanged: true,
                modifiedFilePaths: [cleanFile.path, dirtyFile.path]
            )
        )

        let cleanTab = try XCTUnwrap(ws.openTabs.first { $0.url?.standardized.path == cleanFile.standardized.path })
        let dirtyTab = try XCTUnwrap(ws.openTabs.first { $0.url?.standardized.path == dirtyFile.standardized.path })

        XCTAssertEqual(cleanTab.content, "let v = 2\n")
        XCTAssertFalse(cleanTab.hasExternalConflict)

        XCTAssertEqual(dirtyTab.content, "let x = 999 // local edit\n")
        XCTAssertTrue(dirtyTab.hasExternalConflict)

        ws.reloadConflictedTab(id: dirtyTab.id)
        let reloadedDirty = try XCTUnwrap(ws.openTabs.first { $0.id == dirtyTab.id })
        XCTAssertEqual(reloadedDirty.content, "let x = 2 // disk edit\n")
        XCTAssertFalse(reloadedDirty.isDirty)
        XCTAssertFalse(reloadedDirty.hasExternalConflict)
    }

    // MARK: - 3. LSP Hover, Formatting TextEdits & DocumentSymbols

    func testLSPPayloadParserHoverTextEditsAndDocumentSymbols() throws {
        let hoverPayload: [String: Any] = [
            "contents": ["kind": "markdown", "value": "```swift\nfunc greet(name: String) -> String\n```\nGreets user."],
            "range": [
                "start": ["line": 2, "character": 5],
                "end": ["line": 2, "character": 10]
            ]
        ]
        let hover = try XCTUnwrap(LSPPayloadParser.parseHover(from: hoverPayload))
        XCTAssertTrue(hover.contents.contains("func greet"))
        XCTAssertEqual(hover.range?.start.line, 2)

        let rawEdits: [[String: Any]] = [
            [
                "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]],
                "newText": "let"
            ],
            [
                "range": ["start": ["line": 1, "character": 4], "end": ["line": 1, "character": 7]],
                "newText": "world"
            ]
        ]
        let edits = LSPPayloadParser.parseTextEdits(from: rawEdits)
        let applied = LSPPayloadParser.applyTextEdits(edits, to: "var a = 1\n    foo()\n")
        XCTAssertEqual(applied, "let a = 1\n    world()\n")

        let rawSymbols: [[String: Any]] = [
            [
                "name": "Service",
                "kind": 5,
                "range": ["start": ["line": 0, "character": 0], "end": ["line": 10, "character": 1]],
                "selectionRange": ["start": ["line": 0, "character": 6], "end": ["line": 0, "character": 13]],
                "children": [
                    [
                        "name": "fetch()",
                        "kind": 6,
                        "range": ["start": ["line": 2, "character": 4], "end": ["line": 5, "character": 5]],
                        "selectionRange": ["start": ["line": 2, "character": 9], "end": ["line": 2, "character": 14]]
                    ]
                ]
            ]
        ]
        let symbols = LSPPayloadParser.parseDocumentSymbols(from: rawSymbols)
        XCTAssertEqual(symbols.count, 2)
        XCTAssertEqual(symbols[0].name, "Service")
        XCTAssertEqual(symbols[1].name, "fetch()")
        XCTAssertEqual(symbols[1].containerName, "Service")
        XCTAssertEqual(symbols[1].depth, 1)

        // Built-in JSON fallback formatter
        let formattedJSON = SymbolOutlineService.fallbackFormatDocument(content: "{\"b\":1,\"a\":2}", language: .json)
        XCTAssertNotNil(formattedJSON)
        XCTAssertTrue(formattedJSON?.contains("\n") == true)
    }

    // MARK: - 4. Navigation History (Back / Forward)

    @MainActor
    func testNavigationHistoryBackAndForward() {
        let history = NavigationHistory()
        let locA = NavigationLocation(url: URL(fileURLWithPath: "/tmp/A.swift"), line: 10, column: 1)
        let locB = NavigationLocation(url: URL(fileURLWithPath: "/tmp/B.swift"), line: 25, column: 4)
        let locC = NavigationLocation(url: URL(fileURLWithPath: "/tmp/C.swift"), line: 40, column: 2)

        history.record(locA)
        history.record(locB)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        let back1 = history.goBack(from: locC)
        XCTAssertEqual(back1, locB)
        XCTAssertTrue(history.canGoForward)

        let back2 = history.goBack(from: locB)
        XCTAssertEqual(back2, locA)
        XCTAssertFalse(history.canGoBack)

        let fwd1 = history.goForward(from: locA)
        XCTAssertEqual(fwd1, locB)
        let fwd2 = history.goForward(from: locB)
        XCTAssertEqual(fwd2, locC)
        XCTAssertFalse(history.canGoForward)
    }

    // MARK: - 5. Split Editor & Session Persistence

    @MainActor
    func testSplitEditorAndSessionPersistenceRoundTrip() throws {
        let dir = try makeTempDirectory(name: "session")
        let fileA = dir.appendingPathComponent("A.swift")
        let fileB = dir.appendingPathComponent("B.swift")
        try "let a = 1\nlet a2 = 2\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "let b = 1\nlet b2 = 2\n".write(to: fileB, atomically: true, encoding: .utf8)

        let defaults = makeIsolatedDefaults()
        let ws1 = WorkspaceState(initialURL: dir, userDefaults: defaults)
        ws1.openFile(url: fileA)
        ws1.openFile(url: fileB)
        ws1.toggleSplitEditor()
        XCTAssertTrue(ws1.isSplitEditorActive)
        XCTAssertNotNil(ws1.secondaryTabID)

        ws1.updateTabCursor(tabID: ws1.activeTabID!, line: 2, column: 5, range: NSRange(location: 10, length: 0), pane: .primary)
        ws1.persistCurrentProjectSession()
        ws1.teardownResources()

        // Reload in a fresh WorkspaceState sharing the same defaults
        let ws2 = WorkspaceState(initialURL: dir, userDefaults: defaults)
        defer { ws2.teardownResources() }

        XCTAssertEqual(ws2.openTabs.count, 2)
        XCTAssertTrue(ws2.isSplitEditorActive)
        XCTAssertEqual(ws2.activeTab?.url?.standardized.path, fileB.standardized.path)
        XCTAssertEqual(ws2.secondaryTab?.url?.standardized.path, fileA.standardized.path)
    }

    // MARK: - 6. Global Search Advanced Options & Workspace Replace

    @MainActor
    func testGlobalSearchOptionsAndWorkspaceReplace() throws {
        let dir = try makeTempDirectory(name: "search")
        let srcDir = dir.appendingPathComponent("Sources", isDirectory: true)
        let testDir = dir.appendingPathComponent("Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        let file1 = srcDir.appendingPathComponent("Alpha.swift")
        let file2 = testDir.appendingPathComponent("Beta.md")
        try "let foo = 1\nlet foobar = 2\nlet FOO = 3\n".write(to: file1, atomically: true, encoding: .utf8)
        try "foo in markdown\n".write(to: file2, atomically: true, encoding: .utf8)

        var opts = WorkspaceSearchOptions(
            caseSensitive: true,
            wholeWord: true,
            useRegex: false,
            includeGlob: "*.swift",
            excludeGlob: "Tests/**"
        )
        let matches = try WorkspaceSearchEngine.searchFallback(
            query: "foo",
            options: opts,
            files: [file1, file2],
            rootPath: dir.path
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.lineNumber, 1)

        // Replace in workspace files
        let defaults = makeIsolatedDefaults()
        let ws = WorkspaceState(initialURL: dir, userDefaults: defaults)
        defer { ws.teardownResources() }

        ws.openFile(url: file1)
        ws.searchCaseSensitive = true
        ws.searchWholeWord = true
        ws.searchQuery = "foo"
        ws.globalReplaceQuery = "baz"
        let summary = ws.replaceInWorkspaceFiles(urls: [file1])
        XCTAssertEqual(summary.filesModified, 1)
        XCTAssertEqual(summary.replacementsCount, 1)

        let updatedDisk = try String(contentsOf: file1, encoding: .utf8)
        XCTAssertEqual(updatedDisk, "let baz = 1\nlet foobar = 2\nlet FOO = 3\n")
        XCTAssertEqual(ws.activeTab?.content, updatedDisk)

        // Glob matching checks
        opts.includeGlob = "Sources/**"
        XCTAssertTrue(WorkspaceSearchEngine.matchesGlobs(relativePath: "Sources/Alpha.swift", rawGlobs: opts.includeGlob))
        XCTAssertFalse(WorkspaceSearchEngine.matchesGlobs(relativePath: "Tests/Beta.md", rawGlobs: opts.includeGlob))
    }

    // MARK: - 7. Local Symbol Outline & Active Breadcrumb

    func testLocalSymbolOutlineAndActiveSymbol() {
        let swiftCode = """
        struct UserModel {
            func fullName() -> String {
                return "SwiftFlash"
            }
        }
        """
        let symbols = SymbolOutlineService.extractLocalSymbols(from: swiftCode, language: .swift)
        XCTAssertEqual(symbols.map(\.name), ["UserModel", "fullName"])
        XCTAssertEqual(symbols[0].kind, .struct)
        XCTAssertEqual(symbols[1].kind, .function)

        let activeAtLine3 = SymbolOutlineService.activeSymbol(atLine: 3, in: symbols)
        XCTAssertEqual(activeAtLine3?.name, "fullName")
    }

    // MARK: - 8. FlashTextView Line Editing & Cmd+D Multi-Selection

    @MainActor
    func testFlashTextViewLineEditingAndMultiSelect() {
        let tv = FlashTextView(
            string: "alpha beta\nalpha gamma\ndelta",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: .white,
            lineHeightMultiplier: 1.3,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: nil
        )

        // Cmd+D: first selects "alpha", second adds next "alpha"
        tv.selectionManager.setSelectedRange(NSRange(location: 2, length: 0))
        tv.selectNextOccurrence()
        XCTAssertEqual(tv.selectionManager.textSelections.map(\.range), [NSRange(location: 0, length: 5)])
        tv.selectNextOccurrence()
        XCTAssertEqual(
            tv.selectionManager.textSelections.map(\.range),
            [NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)]
        )

        // Move line 1 down
        tv.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        tv.moveSelectedLines(up: false)
        XCTAssertEqual(tv.string, "alpha gamma\nalpha beta\ndelta")

        // Move it back up
        tv.moveSelectedLines(up: true)
        XCTAssertEqual(tv.string, "alpha beta\nalpha gamma\ndelta")

        // Duplicate line 1 down
        tv.duplicateSelectedLines(up: false)
        XCTAssertEqual(tv.string, "alpha beta\nalpha beta\nalpha gamma\ndelta")

        // Delete duplicated line
        tv.deleteSelectedLines()
        XCTAssertEqual(tv.string, "alpha beta\nalpha gamma\ndelta")

        // Insert line below preserving indent
        tv.setText("    let a = 1\n    let b = 2")
        tv.selectionManager.setSelectedRange(NSRange(location: 6, length: 0))
        tv.insertLine(above: false)
        XCTAssertEqual(tv.string, "    let a = 1\n    \n    let b = 2")
    }

    // MARK: - 9. Localization Format Specifier Parity

    @MainActor
    func testAllFallbackChineseStringsMatchEnglishFormatSpecifiers() {
        for (key, zhValue) in LocalizationManager.fallbackSimplifiedChineseStrings {
            guard let enValue = LocalizationManager.defaultEnglishStrings[key] else {
                XCTFail("Chinese fallback key missing in defaultEnglishStrings: \(key)")
                continue
            }
            XCTAssertTrue(
                LocalizationManager.hasMatchingFormatSpecifiers(zhValue, reference: enValue),
                "Format specifier mismatch for key '\(key)': zh='\(zhValue)' vs en='\(enValue)'"
            )
        }
    }
}
