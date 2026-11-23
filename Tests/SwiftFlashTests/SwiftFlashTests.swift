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
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/config.json")), .json)
        XCTAssertEqual(CodeLanguage.detect(from: URL(fileURLWithPath: "/tmp/README.md")), .markdown)
    }
}
