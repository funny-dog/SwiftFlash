import XCTest
@testable import SwiftFlash

final class SwiftFlashTests: XCTestCase {
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
        let suite = "dev.swiftflash.tests.\(UUID().uuidString)"
        suiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTempDirectory(name: String = UUID().uuidString) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftflash-tests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    @MainActor
    func testEmptyInitialLaunchHasNoOpenWorkspace() {
        let defaults = makeIsolatedDefaults()
        let state = WorkspaceState(initialURL: nil, userDefaults: defaults)

        XCTAssertFalse(state.hasWorkspaceOpen)
        XCTAssertTrue(state.rootItems.isEmpty)
        XCTAssertTrue(state.allWorkspaceFiles.isEmpty)
        XCTAssertTrue(state.recentProjects.isEmpty)
        XCTAssertTrue(state.windowProjects.isEmpty)
    }

    @MainActor
    func testOpenInitialFolderPersistsWithoutSeedingSiblings() throws {
        let parent = try makeTempDirectory(name: "parent-\(UUID().uuidString)")
        let targetDir = parent.appendingPathComponent("ProjectA", isDirectory: true)
        let siblingDir = parent.appendingPathComponent("SiblingB", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)

        let defaults = makeIsolatedDefaults()
        let state = WorkspaceState(initialURL: targetDir, userDefaults: defaults)

        XCTAssertTrue(state.hasWorkspaceOpen)
        XCTAssertEqual(state.rootURL.standardized.path, targetDir.standardized.path)
        XCTAssertEqual(state.recentProjects.map { $0.standardized.path }, [targetDir.standardized.path])
        XCTAssertFalse(state.recentProjects.contains { $0.standardized.path == siblingDir.standardized.path })

        let saved = defaults.stringArray(forKey: "swiftflash.recentProjects") ?? []
        XCTAssertEqual(saved, [targetDir.standardized.path])
    }

    @MainActor
    func testRestoresLastSavedProjectOnSubsequentLaunch() throws {
        let projectDir = try makeTempDirectory(name: "saved-\(UUID().uuidString)")
        let defaults = makeIsolatedDefaults()

        let firstLaunch = WorkspaceState(initialURL: projectDir, userDefaults: defaults)
        XCTAssertTrue(firstLaunch.hasWorkspaceOpen)

        let secondLaunch = WorkspaceState(initialURL: nil, userDefaults: defaults)
        XCTAssertTrue(secondLaunch.hasWorkspaceOpen)
        XCTAssertEqual(secondLaunch.rootURL.standardized.path, projectDir.standardized.path)
    }

    func testPluginRegistryAndManifestDecoding() throws {
        let registryJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-11-23T07:12:42Z",
          "plugins": [
            {
              "id": "com.swiftflash.lang.zh-cn",
              "name": "简体中文语言包",
              "englishName": "Simplified Chinese Language Pack",
              "description": "将 SwiftFlash 切换为简体中文界面。",
              "version": "1.0.0",
              "author": "SwiftFlash",
              "type": "language",
              "languageCode": "zh-CN",
              "nativeName": "简体中文",
              "minAppVersion": "1.0",
              "archiveURL": "releases/com.swiftflash.lang.zh-cn-1.0.0-c603f09c.zip",
              "manifestURL": "plugins/com.swiftflash.lang.zh-cn/manifest.json",
              "sha256": "c603f09c7b52a61c3ceb49e7fa3b2b080e6b1d7ff1ce05a8eb63e802ef9d3732"
            }
          ]
        }
        """

        let registry = try JSONDecoder().decode(PluginRegistryIndex.self, from: Data(registryJSON.utf8))
        XCTAssertEqual(registry.schemaVersion, 1)
        XCTAssertEqual(registry.plugins.count, 1)
        let entry = try XCTUnwrap(registry.plugins.first)
        XCTAssertEqual(entry.id, "com.swiftflash.lang.zh-cn")
        XCTAssertEqual(entry.type, .language)
        XCTAssertEqual(entry.version, "1.0.0")

        let manifestJSON = """
        {
          "schemaVersion": 1,
          "id": "com.swiftflash.lang.zh-cn",
          "name": "简体中文语言包",
          "englishName": "Simplified Chinese Language Pack",
          "version": "1.0.0",
          "type": "language",
          "author": "SwiftFlash",
          "minAppVersion": "1.0",
          "contributes": {
            "localization": {
              "languageCode": "zh-CN",
              "nativeName": "简体中文",
              "stringsFile": "zh-cn.json"
            }
          }
        }
        """

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON.utf8))
        XCTAssertEqual(manifest.id, "com.swiftflash.lang.zh-cn")
        XCTAssertEqual(manifest.contributes?.localization?.languageCode, "zh-CN")
        XCTAssertEqual(manifest.contributes?.localization?.stringsFile, "zh-cn.json")
    }

    @MainActor
    func testLocalizationManagerBuiltInStrings() {
        XCTAssertEqual(L10n("menu.file.openFolder"), "Open Folder...")
        XCTAssertEqual(L10n("status.switchedToFormat", "DemoProject"), "Switched to DemoProject")
        XCTAssertEqual(L10n("unknown.missing.key"), "unknown.missing.key")
    }

    func testCodeLanguageDetection() {
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/App.swift")), .swift)
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/main.rs")), .rust)
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/index.ts")), .typescript)
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/script.py")), .python)
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/main.go")), .go)
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/config.json")), .json)
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/README.md")), .markdown)
    }

    func testEditorFindEngineSearchAndReplace() {
        let text = "let foo = 1\nlet Foo = 2\nlet foobar = foo + Foo"
        let insensitive = EditorFindEngine.findMatches(in: text, query: "foo", isCaseSensitive: false, isRegex: false)
        XCTAssertEqual(insensitive.count, 5)

        let sensitive = EditorFindEngine.findMatches(in: text, query: "foo", isCaseSensitive: true, isRegex: false)
        XCTAssertEqual(sensitive.count, 3)

        let regexMatches = EditorFindEngine.findMatches(in: text, query: #"\b[Ff]oo\b"#, isCaseSensitive: true, isRegex: true)
        XCTAssertEqual(regexMatches.count, 4)

        let replaced = EditorFindEngine.replaceAll(
            in: text,
            query: #"\bfoo\b"#,
            replacement: "bar",
            isCaseSensitive: true,
            isRegex: true
        )
        XCTAssertEqual(replaced.count, 2)
        XCTAssertEqual(replaced.updatedText, "let bar = 1\nlet Foo = 2\nlet foobar = bar + Foo")
    }

    func testLSPMessageFramerHandlesChunkedAndMultiByteFrames() throws {
        var framer = LSPMessageFramer()
        let msg1 = Data(#"{"jsonrpc":"2.0","id":1,"result":{"msg":"你好世界"}}"#.utf8)
        let msg2 = Data(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#.utf8)

        var stream = LSPMessageFramer.encode(msg1)
        stream.append(LSPMessageFramer.encode(msg2))

        // Split across header and multi-byte body boundaries
        let partA = stream.subdata(in: 0..<10)
        let partB = stream.subdata(in: 10..<25)
        let partC = stream.subdata(in: 25..<stream.count)

        XCTAssertTrue(framer.append(partA).isEmpty)
        XCTAssertTrue(framer.append(partB).isEmpty)
        let decoded = framer.append(partC)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0], msg1)
        XCTAssertEqual(decoded[1], msg2)
    }

    func testLSPPayloadParserDiagnosticsCompletionsAndLocations() {
        let diagParams: [String: Any] = [
            "uri": "file:///tmp/Demo.swift",
            "diagnostics": [
                [
                    "range": ["start": ["line": 3, "character": 4], "end": ["line": 3, "character": 10]],
                    "severity": 1,
                    "source": "sourcekit",
                    "message": "Cannot find 'missingVar' in scope"
                ]
            ]
        ]
        let parsedDiags = LSPPayloadParser.parseDiagnostics(from: diagParams)
        XCTAssertEqual(parsedDiags?.uri, "file:///tmp/Demo.swift")
        XCTAssertEqual(parsedDiags?.diagnostics.count, 1)
        XCTAssertEqual(parsedDiags?.diagnostics.first?.severity, .error)
        XCTAssertEqual(parsedDiags?.diagnostics.first?.range.start.line, 3)

        let rawCompletions: [[String: Any]] = [
            [
                "label": "print(_:)",
                "kind": 3,
                "detail": "Swift.print",
                "insertText": "print(${1:items})"
            ]
        ]
        let completions = LSPPayloadParser.parseCompletionItems(from: rawCompletions)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.insertText, "print(items)")
        XCTAssertEqual(completions.first?.kind, .function)

        let rawLocations: [[String: Any]] = [
            [
                "targetUri": "file:///tmp/Target.swift",
                "targetSelectionRange": [
                    "start": ["line": 12, "character": 2],
                    "end": ["line": 12, "character": 8]
                ]
            ]
        ]
        let locs = LSPPayloadParser.parseLocations(from: rawLocations)
        XCTAssertEqual(locs.count, 1)
        XCTAssertEqual(locs.first?.uri, "file:///tmp/Target.swift")
        XCTAssertEqual(locs.first?.range.start.line, 12)
    }

    func testLocalCompletionMergesAndRanksLSPFirst() {
        let code = "func computeAlpha() {}\nlet computeBeta = 1\ncom"
        let ns = code as NSString
        let range = LocalCompletionProvider.identifierPrefixRange(in: ns, at: ns.length)
        XCTAssertEqual(ns.substring(with: range), "com")

        let lspItem = LSPCompletionItem(
            label: "computeGamma()",
            kind: .function,
            detail: "LSP",
            documentation: nil,
            insertText: "computeGamma()",
            filterText: "computeGamma",
            sortText: "0001",
            isLocalFallback: false
        )
        let merged = LocalCompletionProvider.mergeAndRank(
            prefix: "com",
            language: .swift,
            documentText: code,
            lspItems: [lspItem]
        )
        XCTAssertEqual(merged.first?.label, "computeGamma()")
        XCTAssertTrue(merged.contains { $0.label == "computeAlpha" })
        XCTAssertTrue(merged.contains { $0.label == "computeBeta" })
    }

    func testProjectTaskDetectorAndOutputLocationParser() throws {
        let dir = try makeTempDirectory(name: "tasks-\(UUID().uuidString)")
        let srcDir = dir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let mainSwift = srcDir.appendingPathComponent("main.swift")
        try "print(\"hi\")\n".write(to: mainSwift, atomically: true, encoding: .utf8)
        try "// swift-tools-version: 6.0\n".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let tasks = ProjectTaskDetector.detectTasks(in: dir, activeFileURL: mainSwift)
        XCTAssertTrue(tasks.contains { $0.command == "swift run" && $0.kind == .run })
        XCTAssertTrue(tasks.contains { $0.command == "swift test" && $0.kind == .test })

        let swiftErr = "Sources/main.swift:12:5: error: cannot find 'x' in scope"
        let parsedSwift = OutputLocationParser.parseLocation(from: swiftErr, workspaceRoot: dir)
        XCTAssertEqual(parsedSwift?.url.standardized.path, mainSwift.standardized.path)
        XCTAssertEqual(parsedSwift?.line, 12)
        XCTAssertEqual(parsedSwift?.column, 5)

        let pyErr = #"  File "\#(mainSwift.path)", line 42, in <module>"#
        let parsedPy = OutputLocationParser.parseLocation(from: pyErr, workspaceRoot: dir)
        XCTAssertEqual(parsedPy?.url.standardized.path, mainSwift.standardized.path)
        XCTAssertEqual(parsedPy?.line, 42)
    }

    @MainActor
    func testLSPAutoSelectionByFileType() {
        let mgr = LSPManager.shared
        XCTAssertEqual(mgr.serverDefinition(for: .swift, url: URL(fileURLWithPath: "/tmp/App.swift"))?.id, "sourcekit-lsp")
        XCTAssertEqual(mgr.serverDefinition(for: .rust, url: URL(fileURLWithPath: "/tmp/lib.rs"))?.id, "rust-analyzer")
        XCTAssertEqual(mgr.serverDefinition(for: .python, url: URL(fileURLWithPath: "/tmp/app.py"))?.id, "pyright")
        XCTAssertEqual(mgr.serverDefinition(for: .typescript, url: URL(fileURLWithPath: "/tmp/App.tsx"))?.id, "typescript-language-server")
        XCTAssertEqual(mgr.serverDefinition(for: .javascript, url: URL(fileURLWithPath: "/tmp/index.jsx"))?.id, "typescript-language-server")
        XCTAssertEqual(mgr.serverDefinition(for: .go, url: URL(fileURLWithPath: "/tmp/main.go"))?.id, "gopls")
        XCTAssertNil(mgr.serverDefinition(for: .markdown, url: URL(fileURLWithPath: "/tmp/README.md")))

        XCTAssertEqual(mgr.lspLanguageID(for: .typescript, url: URL(fileURLWithPath: "/tmp/App.tsx")), "typescriptreact")
        XCTAssertEqual(mgr.lspLanguageID(for: .javascript, url: URL(fileURLWithPath: "/tmp/index.jsx")), "javascriptreact")
        XCTAssertEqual(mgr.lspLanguageID(for: .c, url: URL(fileURLWithPath: "/tmp/main.cpp")), "cpp")
        XCTAssertEqual(mgr.lspLanguageID(for: .c, url: URL(fileURLWithPath: "/tmp/View.mm")), "objective-cpp")
    }

    @MainActor
    func testComputeLSPPositionUTF16() {
        let text = "import os\nfrom colle" as NSString
        let pos = HighPerformanceEditorContainerView.computeLSPPosition(in: text, at: text.length)
        XCTAssertEqual(pos.line, 1)
        XCTAssertEqual(pos.character, 10)

        let endOfFirst = HighPerformanceEditorContainerView.computeLSPPosition(in: text, at: 9)
        XCTAssertEqual(endOfFirst.line, 0)
        XCTAssertEqual(endOfFirst.character, 9)
    }

    func testCompletionStrictPrefixFilteringAndKeywordRanking() {
        let noisyLSPItems = [
            LSPCompletionItem(
                label: "get_image_info",
                kind: .variable,
                detail: nil,
                documentation: nil,
                insertText: "get_image_info",
                filterText: "get_image_info",
                sortText: "04.0000.get_image_info",
                isLocalFallback: false
            ),
            LSPCompletionItem(
                label: "ImportError",
                kind: .class,
                detail: nil,
                documentation: nil,
                insertText: "ImportError",
                filterText: "ImportError",
                sortText: "12.9999.ImportError",
                isLocalFallback: false
            ),
            LSPCompletionItem(
                label: "NotImplemented",
                kind: .variable,
                detail: nil,
                documentation: nil,
                insertText: "NotImplemented",
                filterText: "NotImplemented",
                sortText: "12.9999.NotImplemented",
                isLocalFallback: false
            ),
            LSPCompletionItem(
                label: "dataframe",
                kind: .variable,
                detail: nil,
                documentation: nil,
                insertText: "dataframe",
                filterText: "dataframe",
                sortText: "05.0000.dataframe",
                isLocalFallback: false
            ),
            LSPCompletionItem(
                label: "frozenset",
                kind: .class,
                detail: nil,
                documentation: nil,
                insertText: "frozenset",
                filterText: "frozenset",
                sortText: "12.9999.frozenset",
                isLocalFallback: false
            ),
            LSPCompletionItem(
                label: "from",
                kind: .keyword,
                detail: nil,
                documentation: nil,
                insertText: "from",
                filterText: "from",
                sortText: "08.9999.from",
                isLocalFallback: false
            )
        ]

        let results = LocalCompletionProvider.mergeAndRank(
            prefix: "fr",
            language: .python,
            documentText: "fr",
            lspItems: noisyLSPItems
        )

        XCTAssertEqual(results.map(\.label), ["from", "frozenset"])
        XCTAssertFalse(results.contains { $0.label == "ImportError" || $0.label == "NotImplemented" || $0.label == "get_image_info" || $0.label == "dataframe" })
    }

    func testPythonContextCompletionImportMembersAndCleanIdentifiers() {
        let doc = """
        # hex color "#ff0055" "#ff007f" should never leak into identifiers
        color = "#ff0055"
        dq = collections.deque()
        """
        XCTAssertTrue(LocalCompletionProvider.collectDocumentIdentifiers(in: doc, excluding: "", language: .python).allSatisfy {
            !$0.hasPrefix("ff00")
        })

        let importMods = LocalCompletionProvider.mergeAndRank(
            prefix: "col",
            language: .python,
            documentText: doc,
            lspItems: [],
            beforeCursorOnLine: "from col"
        )
        XCTAssertEqual(importMods.first?.label, "collections")
        XCTAssertFalse(importMods.contains { $0.kind == .keyword })

        let importMembers = LocalCompletionProvider.mergeAndRank(
            prefix: "de",
            language: .python,
            documentText: doc,
            lspItems: [],
            beforeCursorOnLine: "from collections import de"
        )
        XCTAssertEqual(importMembers.map(\.label), ["defaultdict", "deque"])

        let dqMembers = LocalCompletionProvider.mergeAndRank(
            prefix: "app",
            language: .python,
            documentText: doc,
            lspItems: [],
            beforeCursorOnLine: "dq.app"
        )
        XCTAssertEqual(dqMembers.map(\.label), ["append", "appendleft"])
    }

    @MainActor
    func testEditorTypingFrTriggersFromCompletionWithUpdatedCursor() throws {
        let dir = try makeTempDirectory(name: "py-typing-\(UUID().uuidString)")
        let pyURL = dir.appendingPathComponent("demo.py")
        try "color = \"#ff0055\"\n".write(to: pyURL, atomically: true, encoding: .utf8)

        let defaults = makeIsolatedDefaults()
        let workspace = WorkspaceState(initialURL: dir, userDefaults: defaults)
        workspace.openFile(url: pyURL)

        let container = HighPerformanceEditorContainerView(workspace: workspace)
        container.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        container.syncWithTab(workspace.activeTab)

        // Move cursor to end of document and simulate typing "fr"
        let endOffset = container.textView.textStorage.length
        container.textView.selectionManager.setSelectedRange(NSRange(location: endOffset, length: 0))
        container.textView.insertText("f", replacementRange: NSRange(location: NSNotFound, length: 0))
        container.textView.insertText("r", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(container.textView.selectionManager.textSelections.first?.range.location, endOffset + 2)
        XCTAssertTrue(container.completionState.isVisible)
        XCTAssertEqual(container.completionState.items.first?.label, "from")
        XCTAssertFalse(container.completionState.items.contains { $0.label == "ff0055" || $0.label == "color" })
    }

    @MainActor
    func testEditorTypingFromCollAboveChineseLineShowsCollectionsNotKeywords() throws {
        let dir = try makeTempDirectory(name: "py-from-coll-\(UUID().uuidString)")
        let pyURL = dir.appendingPathComponent("demo.py")
        try "\n# 导入\nfrom \n".write(to: pyURL, atomically: true, encoding: .utf8)

        let defaults = makeIsolatedDefaults()
        let workspace = WorkspaceState(initialURL: dir, userDefaults: defaults)
        workspace.openFile(url: pyURL)

        let container = HighPerformanceEditorContainerView(workspace: workspace)
        container.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        container.syncWithTab(workspace.activeTab)

        container.textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        for ch in ["f", "r", "o", "m", " ", "c", "o", "l", "l"] {
            container.textView.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        XCTAssertEqual(container.textView.selectionManager.textSelections.first?.range.location, 9)
        XCTAssertTrue(container.completionState.isVisible)
        XCTAssertEqual(container.completionState.items.map(\.label), ["collections"])
        XCTAssertFalse(container.completionState.items.contains { $0.label == "finally" || $0.label == "for" })
    }
}
