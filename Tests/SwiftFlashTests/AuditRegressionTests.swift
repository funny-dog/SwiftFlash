import AppKit
import XCTest
@testable import SwiftFlash

final class AuditRegressionTests: XCTestCase {
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
        let suite = "dev.swiftflash.audit-tests.\(UUID().uuidString)"
        suiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTempDirectory(name: String = UUID().uuidString) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftflash-audit-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    // MARK: - 1. IncrementalLineDecoder (UTF-8 chunk boundary & CRLF)

    func testIncrementalLineDecoderHandlesSplitMultiByteUTF8AndCRLF() {
        var decoder = IncrementalLineDecoder()
        let raw = Data("第一行🚀\r\n第二行中文\n尾行无换行".utf8)

        var collected: [String] = []
        // Feed 1 byte at a time to stress every possible multi-byte UTF-8 boundary
        for i in 0..<raw.count {
            let chunk = raw.subdata(in: i..<(i + 1))
            collected.append(contentsOf: decoder.append(chunk))
        }
        collected.append(contentsOf: decoder.flush())

        XCTAssertEqual(collected, ["第一行🚀", "第二行中文", "尾行无换行"])
    }

    // MARK: - 2. ProcessRunner (Large stdout+stderr without deadlock & timeout)

    func testProcessRunnerReadsLargeStdoutAndStderrWithoutDeadlock() {
        // Generate > 128 KB on both stdout and stderr simultaneously (exceeds macOS 64 KB pipe buffer)
        let script = """
        python3 -c 'import sys; sys.stdout.write("O" * 150000); sys.stderr.write("E" * 150000)'
        """
        let result = ProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            timeoutSeconds: 10
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutData.count, 150_000)
        XCTAssertEqual(result.stderrData.count, 150_000)
    }

    func testProcessRunnerEnforcesTimeout() {
        let result = ProcessRunner.run(
            executablePath: "/bin/sleep",
            arguments: ["10"],
            timeoutSeconds: 0.35
        )
        XCTAssertTrue(result.timedOut)
    }

    // MARK: - 3. LSPMessageFramer (Oversized / Negative / Corrupt Content-Length)

    func testLSPMessageFramerRecoversFromNegativeAndOversizedContentLength() {
        var framer = LSPMessageFramer()
        let validBody = Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)
        let validFrame = LSPMessageFramer.encode(validBody)

        var stream = Data()
        stream.append(Data("Content-Length: -5\r\n\r\n".utf8))
        stream.append(Data("Content-Length: 999999999999\r\n\r\n".utf8))
        stream.append(Data("Content-Length: notanumber\r\n\r\n".utf8))
        stream.append(validFrame)

        let decoded = framer.append(stream)
        XCTAssertEqual(decoded, [validBody])
    }

    // MARK: - 4. LSPPayloadParser Snippet Sanitization

    func testLSPPayloadParserSanitizesSnippetPlaceholders() {
        XCTAssertEqual(LSPPayloadParser.sanitizeSnippetPlaceholders("foo(${1:bar}, ${2|a,b,c|})$0"), "foo(bar, a)")
        XCTAssertEqual(LSPPayloadParser.sanitizeSnippetPlaceholders("print($1)"), "print()")
    }

    // MARK: - 5. ANSITextParser (Non-SGR CSI & OSC should not swallow normal text)

    func testANSITextParserPreservesNormalTextAfterNonSGRSequences() {
        let input = "\u{1B}[?25l\u{1B}[32mPASS\u{1B}[K normal text\u{1B}[0m done\u{1B}]0;Window Title\u{07}!"
        let spans = ANSITextParser.parseSpans(input, defaultRole: .plain)

        let combined = spans.map(\.text).joined()
        XCTAssertEqual(combined, "PASS normal text done!")
        XCTAssertEqual(spans.first?.role, .string)
        XCTAssertEqual(spans.last?.role, .plain)
    }

    // MARK: - 6. TerminalSession Standalone `cd` Parsing

    func testTerminalStandaloneCDTargetParsing() {
        XCTAssertEqual(TerminalSession.parseStandaloneCDTarget(from: "cd"), "")
        XCTAssertEqual(TerminalSession.parseStandaloneCDTarget(from: "cd -"), "-")
        XCTAssertEqual(TerminalSession.parseStandaloneCDTarget(from: #"cd "my folder/sub dir""#), "my folder/sub dir")
        XCTAssertEqual(TerminalSession.parseStandaloneCDTarget(from: "cd 'single quoted'"), "single quoted")
        // Compound shell commands MUST NOT be intercepted as standalone cd
        XCTAssertNil(TerminalSession.parseStandaloneCDTarget(from: "cd foo && ls"))
        XCTAssertNil(TerminalSession.parseStandaloneCDTarget(from: "cd foo; pwd"))
        XCTAssertNil(TerminalSession.parseStandaloneCDTarget(from: "cd foo | cat"))
        XCTAssertNil(TerminalSession.parseStandaloneCDTarget(from: "echo cd"))
    }

    // MARK: - 7. SyntaxHighlighter Lexical String vs Comment Precedence

    func testSyntaxHighlighterStringsAreNotCorruptedByCommentMarkers() {
        let palette = ThemePalette.palette(for: .zedOneDark)

        // Swift URL inside string must stay string-colored, never overwritten by `//` comment color
        let swiftCode = #"let url = "https://example.com/path" // real comment"#
        let swiftTokens = SyntaxHighlighter.shared.tokenize(
            slice: swiftCode,
            baseOffset: 0,
            language: .swift,
            palette: palette
        )
        let nsSwift = swiftCode as NSString
        let urlStringRange = nsSwift.range(of: #""https://example.com/path""#)
        let commentRange = nsSwift.range(of: "// real comment")

        XCTAssertTrue(swiftTokens.contains { $0.range == urlStringRange && $0.colorHex == palette.stringHex })
        XCTAssertTrue(swiftTokens.contains { $0.range == commentRange && $0.colorHex == palette.commentHex })
        XCTAssertFalse(swiftTokens.contains {
            $0.colorHex == palette.commentHex && NSIntersectionRange($0.range, urlStringRange).length > 0
        })

        // Python `#` inside string must NOT start a comment
        let pyCode = ##"color = "#ff0055" # hex color"##
        let pyTokens = SyntaxHighlighter.shared.tokenize(
            slice: pyCode,
            baseOffset: 0,
            language: .python,
            palette: palette
        )
        let nsPy = pyCode as NSString
        let pyStrRange = nsPy.range(of: ##""#ff0055""##)
        XCTAssertTrue(pyTokens.contains { $0.range == pyStrRange && $0.colorHex == palette.stringHex })
        XCTAssertFalse(pyTokens.contains {
            $0.colorHex == palette.commentHex && NSIntersectionRange($0.range, pyStrRange).length > 0
        })

        // Apostrophe inside comment must NOT start a runaway string
        let commentWithQuote = "// don't break\nlet value = 42"
        let quoteTokens = SyntaxHighlighter.shared.tokenize(
            slice: commentWithQuote,
            baseOffset: 0,
            language: .swift,
            palette: palette
        )
        let nsQuote = commentWithQuote as NSString
        let letRange = nsQuote.range(of: "let")
        XCTAssertTrue(quoteTokens.contains { $0.range == letRange && $0.colorHex == palette.keywordHex })
    }

    // MARK: - 8. Unicode Case-Expanding Safety (QuickOpen & Completion)

    func testUnicodeCaseExpandingCharactersDoNotCrashFuzzyScoreOrCompletion() {
        // 'İ' (U+0130) expands to 2 code points on lowercased(); matching after 'İ' must never crash
        XCTAssertNotNil(QuickOpenModalView.fuzzyScore(query: "app", candidate: "İstanbul/App.swift"))
        XCTAssertNotNil(QuickOpenModalView.fuzzyScore(query: "İst", candidate: "İstanbul/App.swift"))
        XCTAssertNil(QuickOpenModalView.fuzzyScore(query: "zzz", candidate: "İstanbul/Straße.swift"))

        let source = "let myValue = 1\n"
        let unicodeLSP = LSPCompletionItem(
            label: "İstanbulService",
            kind: .class,
            detail: nil,
            documentation: nil,
            insertText: "İstanbulService",
            filterText: "İstanbulService",
            sortText: "0001",
            isLocalFallback: false
        )
        let results = LocalCompletionProvider.mergeAndRank(
            prefix: "is",
            language: .swift,
            documentText: source,
            lspItems: [unicodeLSP]
        )
        // Must not crash on Unicode case-expanding characters ('İ')
        XCTAssertNotNil(results)
    }

    func testPythonTripleQuotedStringsDoNotInvertCompletionContext() {
        let source = """
        \"\"\"
        doc_secret_word = 123
        \"\"\"
        real_symbol = 42
        real_
        """
        let results = LocalCompletionProvider.mergeAndRank(
            prefix: "real_",
            language: .python,
            documentText: source,
            lspItems: []
        )
        XCTAssertTrue(results.contains { $0.label == "real_symbol" })
        let docIds = LocalCompletionProvider.collectDocumentIdentifiers(in: source, excluding: "", language: .python)
        XCTAssertFalse(docIds.contains("doc_secret_word"))
    }

    // MARK: - 9. EditorFindEngine Regex Template Expansion & Plain Replace

    func testEditorFindEngineSingleRegexReplacementExpandsCaptureGroups() {
        let text = "user_42 = 100"
        let matches = EditorFindEngine.findMatches(in: text, query: #"user_(\d+)"#, isCaseSensitive: true, isRegex: true)
        XCTAssertEqual(matches.count, 1)

        let expanded = EditorFindEngine.replacementString(
            in: text,
            matchRange: matches[0],
            query: #"user_(\d+)"#,
            replacement: "id_$1",
            isCaseSensitive: true,
            isRegex: true
        )
        XCTAssertEqual(expanded, "id_42")
    }

    func testEditorFindEngineReplaceAllHandlesZeroWidthRegexSafely() {
        let text = "ab"
        let matches = EditorFindEngine.findMatches(in: text, query: "a*", isCaseSensitive: true, isRegex: true)
        let replaced = EditorFindEngine.replaceAll(
            in: text,
            query: "a*",
            replacement: "X",
            isCaseSensitive: true,
            isRegex: true
        )
        XCTAssertEqual(replaced.count, matches.count)
        XCTAssertFalse(replaced.updatedText.isEmpty)
    }

    // MARK: - 10. Plugin Security (Path Traversal Prevention)

    func testPluginIDAndStoragePathTraversalRejection() {
        XCTAssertTrue(PluginManager.isValidPluginID("com.swiftflash.lang.zh-cn"))
        XCTAssertFalse(PluginManager.isValidPluginID(""))
        XCTAssertFalse(PluginManager.isValidPluginID("."))
        XCTAssertFalse(PluginManager.isValidPluginID(".."))
        XCTAssertFalse(PluginManager.isValidPluginID("../evil"))
        XCTAssertFalse(PluginManager.isValidPluginID("foo/bar"))
        XCTAssertFalse(PluginManager.isValidPluginID("foo\\bar"))

        XCTAssertNil(PluginStorage.validatedPluginDirectory(id: "../etc"))
        let validDir = PluginStorage.validatedPluginDirectory(id: "com.swiftflash.lang.zh-cn")
        XCTAssertNotNil(validDir)

        if let dir = validDir {
            XCTAssertNotNil(PluginStorage.validatedRelativeFile("zh-cn.json", inside: dir))
            XCTAssertNil(PluginStorage.validatedRelativeFile("../../etc/passwd", inside: dir))
            XCTAssertNil(PluginStorage.validatedRelativeFile("/etc/passwd", inside: dir))
        }
    }

    // MARK: - 11. TaskRunner Shell Command Injection Protection

    func testProjectTaskDetectorQuotesMaliciousPackageJSONScriptName() throws {
        let dir = try makeTempDirectory(name: "npm-inject-\(UUID().uuidString)")
        let pkgJSON = """
        {
          "name": "demo",
          "scripts": {
            "build; touch /tmp/pwned": "echo hi"
          }
        }
        """
        try pkgJSON.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let tasks = ProjectTaskDetector.detectTasks(in: dir, activeFileURL: nil)
        let npmTask = try XCTUnwrap(tasks.first { $0.command.hasPrefix("npm run ") })
        XCTAssertEqual(npmTask.command, "npm run 'build; touch /tmp/pwned'")
    }

    // MARK: - 12. Binary File Rejection & Workspace Path / Tab Sync

    func testBinaryFileDetectionAndTextDecoding() {
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        XCTAssertTrue(WorkspaceState.isLikelyBinaryData(pngHeader))
        XCTAssertNil(WorkspaceState.decodeTextFile(pngHeader))

        let utf8Text = Data("Hello 世界\nLine 2".utf8)
        XCTAssertFalse(WorkspaceState.isLikelyBinaryData(utf8Text))
        XCTAssertEqual(WorkspaceState.decodeTextFile(utf8Text), "Hello 世界\nLine 2")

        // UTF-16 LE BOM contains NUL bytes for ASCII chars, yet must still decode cleanly as text
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append("Hi".data(using: .utf16LittleEndian)!)
        XCTAssertFalse(WorkspaceState.isLikelyBinaryData(utf16Data))
        XCTAssertEqual(WorkspaceState.decodeTextFile(utf16Data), "Hi")
    }

    @MainActor
    func testWorkspaceRejectsTraversalAndSyncsTabsOnRenameAndDelete() throws {
        let dir = try makeTempDirectory(name: "ws-ops-\(UUID().uuidString)")
        let fileA = dir.appendingPathComponent("notes.txt")
        let fileB = dir.appendingPathComponent("notes.swift")
        try "let x = 1\n".write(to: fileA, atomically: true, encoding: .utf8)

        let state = WorkspaceState(initialURL: dir, userDefaults: makeIsolatedDefaults())
        // Path traversal must be rejected
        XCTAssertNil(state.validatedRelativeURL(named: "../escape.txt", inside: dir))
        XCTAssertNil(state.validatedRelativeURL(named: "/etc/passwd", inside: dir))
        XCTAssertNotNil(state.validatedRelativeURL(named: "sub/file.swift", inside: dir))

        // Open fileA (.plainText), then simulate rename to .swift
        state.openFile(url: fileA)
        XCTAssertEqual(state.activeTab?.language, .plainText)
        let prevRev = state.activeTab?.externalReloadRevision ?? 0

        try FileManager.default.moveItem(at: fileA, to: fileB)
        state.updateOpenTabsForRenamedItem(from: fileA, to: fileB, isDirectory: false)
        XCTAssertEqual(state.activeTab?.url?.standardized.path, fileB.standardized.path)
        XCTAssertEqual(state.activeTab?.language, .swift)
        XCTAssertGreaterThan(state.activeTab?.externalReloadRevision ?? 0, prevRev)

        // Delete closes the open tab
        state.closeOpenTabsForDeletedItem(at: fileB, isDirectory: false)
        XCTAssertTrue(state.openTabs.isEmpty)
        XCTAssertNil(state.activeTabID)
    }

    // MARK: - 13. GitService Quoted Path & Porcelain Parsing

    func testGitServiceUnquotesAndParsesRenamedQuotedPaths() {
        let repo = URL(fileURLWithPath: "/tmp/demo-repo")
        let porcelain = [
            " M \"dir with space/hello.swift\"",
            "R  \"old name.txt\" -> \"new \\\"quoted\\\" name.swift\"",
            "?? untracked.md"
        ].joined(separator: "\n")

        let items = GitService.parseGitStatus(porcelain, repoTopLevel: repo)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].relativePath, "dir with space/hello.swift")
        XCTAssertEqual(items[1].relativePath, "new \"quoted\" name.swift")
        XCTAssertTrue(items[1].isStaged)
        XCTAssertEqual(items[2].relativePath, "untracked.md")
        XCTAssertTrue(items[2].isUntracked)
    }

    // MARK: - 14. LocalizationManager Format Specifier Validation

    func testLocalizationFormatSpecifierValidationRejectsMismatchedTypes() {
        XCTAssertTrue(LocalizationManager.hasMatchingFormatSpecifiers("已替换 %d 处", reference: "Replaced %d occurrences"))
        XCTAssertTrue(LocalizationManager.hasMatchingFormatSpecifiers("100%% 完成：%@", reference: "100%% done: %@"))
        XCTAssertFalse(LocalizationManager.hasMatchingFormatSpecifiers("已替换 %@ 处", reference: "Replaced %d occurrences"))
        XCTAssertFalse(LocalizationManager.hasMatchingFormatSpecifiers("缺少参数", reference: "Opened %@"))
        XCTAssertFalse(LocalizationManager.hasMatchingFormatSpecifiers("%d %d %d", reference: "%d %d"))
    }

    // MARK: - 15. FlashTextView CRLF Toggle Comment & Single-Line Backtab

    @MainActor
    func testFlashTextViewCRLFCommentAndSingleLineBacktab() {
        let tv = FlashTextView(
            string: "    let a = 1\r\n    let b = 2\r\n",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: .white,
            lineHeightMultiplier: 1.4,
            wrapLines: false,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            useSystemCursor: false,
            delegate: nil
        )
        tv.currentLanguage = .swift

        // Single-line backtab with empty selection (caret at offset 8 inside line 1)
        tv.selectionManager.setSelectedRange(NSRange(location: 8, length: 0))
        tv.handleSmartBacktab()
        XCTAssertTrue(tv.string.hasPrefix("let a = 1\r\n"))
        // Caret should remain collapsed (length 0), not select the entire line
        let afterBacktab = tv.selectionManager.textSelections.first?.range
        XCTAssertEqual(afterBacktab?.length, 0)

        // Toggle comment on CRLF two lines preserves CRLF line endings
        tv.selectionManager.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length - 2))
        tv.toggleComment()
        XCTAssertTrue(tv.string.contains("// let a = 1\r\n"))
        XCTAssertTrue(tv.string.contains("//     let b = 2\r\n") || tv.string.contains("    // let b = 2\r\n"))
    }
}
