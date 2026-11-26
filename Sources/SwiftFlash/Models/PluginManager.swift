import CryptoKit
import Foundation

// MARK: - Plugin Storage Paths

enum PluginStorage {
    static var pluginsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("SwiftFlash", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
            .standardizedFileURL
    }

    static func validatedPluginDirectory(id: String) -> URL? {
        guard PluginManager.isValidPluginID(id) else { return nil }
        let root = pluginsDirectory.standardizedFileURL
        let candidate = root.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    static func validatedRelativeFile(_ relativePath: String, inside directory: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let base = directory.standardizedFileURL
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}

// MARK: - Plugin Manifest & Registry Models

enum PluginType: String, Codable, Sendable {
    case language
    case theme
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PluginType(rawValue: raw) ?? .unknown
    }
}

struct LocalizationContribution: Codable, Equatable, Sendable {
    let languageCode: String
    let nativeName: String
    let stringsFile: String
}

struct PluginContributions: Codable, Equatable, Sendable {
    let localization: LocalizationContribution?
}

struct PluginManifest: Codable, Identifiable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let name: String
    let englishName: String?
    let version: String
    let type: PluginType
    let author: String?
    let description: String?
    let minAppVersion: String?
    let contributes: PluginContributions?
}

struct RemotePluginEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let englishName: String?
    let description: String?
    let version: String
    let author: String?
    let type: PluginType
    let languageCode: String?
    let nativeName: String?
    let minAppVersion: String?
    let archiveURL: String
    let manifestURL: String?
    let sha256: String?
}

struct PluginRegistryIndex: Codable, Sendable {
    let schemaVersion: Int
    let updatedAt: String?
    let plugins: [RemotePluginEntry]
}

struct InstalledPlugin: Identifiable, Equatable, Sendable {
    let id: String
    let manifest: PluginManifest
    let installURL: URL
}

// MARK: - PluginManager

@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    static let officialRegistryURL = "https://raw.githubusercontent.com/funny-dog/swiftflash-plugins/refs/heads/main/index.json"

    private let registryURL: URL

    @Published private(set) var remotePlugins: [RemotePluginEntry] = []
    @Published private(set) var installedPlugins: [InstalledPlugin] = []
    @Published private(set) var isFetchingRegistry: Bool = false
    @Published private(set) var installingPluginIDs: Set<String> = []
    @Published var registryError: String?

    private init() {
        let envOverride = ProcessInfo.processInfo.environment["SWIFTFLASH_PLUGIN_REGISTRY_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envOverride, !envOverride.isEmpty, let overrideURL = URL(string: envOverride) {
            self.registryURL = overrideURL
        } else {
            self.registryURL = URL(string: Self.officialRegistryURL)!
        }

        try? FileManager.default.createDirectory(
            at: PluginStorage.pluginsDirectory,
            withIntermediateDirectories: true
        )
        reloadInstalledPlugins()
    }

    /// Strict allowlist for plugin identifiers to prevent path traversal (`..`, `/`, etc.).
    nonisolated static func isValidPluginID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, !id.contains(".."), !id.hasPrefix("."), !id.hasSuffix(".") else {
            return false
        }
        return id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)     // 0-9
                || (scalar.value >= 65 && scalar.value <= 90)  // A-Z
                || (scalar.value >= 97 && scalar.value <= 122) // a-z
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    var installedLanguagePlugins: [InstalledPlugin] {
        installedPlugins.filter { $0.manifest.type == .language }
    }

    var remoteLanguagePlugins: [RemotePluginEntry] {
        remotePlugins.filter { $0.type == .language }
    }

    func installedPlugin(id: String) -> InstalledPlugin? {
        installedPlugins.first { $0.id == id }
    }

    func reloadInstalledPlugins() {
        let fm = FileManager.default
        let root = PluginStorage.pluginsDirectory
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        guard let dirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            installedPlugins = []
            return
        }

        var loaded: [InstalledPlugin] = []
        let decoder = JSONDecoder()
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(PluginManifest.self, from: data),
                  Self.isValidPluginID(manifest.id) else {
                continue
            }
            loaded.append(InstalledPlugin(id: manifest.id, manifest: manifest, installURL: dir))
        }
        installedPlugins = loaded.sorted { $0.manifest.name < $1.manifest.name }
    }

    func fetchRemoteRegistry() async {
        isFetchingRegistry = true
        registryError = nil
        defer { isFetchingRegistry = false }

        do {
            let data = try await downloadData(from: registryURL)
            let decoded = try JSONDecoder().decode(PluginRegistryIndex.self, from: data)
            remotePlugins = decoded.plugins.filter { Self.isValidPluginID($0.id) }
        } catch let err as PluginError {
            registryError = err.localizedDescription
        } catch {
            registryError = error.localizedDescription
        }
    }

    @discardableResult
    func installPlugin(_ entry: RemotePluginEntry, activateIfLanguage: Bool = true) async -> Bool {
        guard Self.isValidPluginID(entry.id) else {
            registryError = PluginError.invalidPluginPackage("Invalid plugin ID: \(entry.id)").localizedDescription
            return false
        }
        guard !installingPluginIDs.contains(entry.id) else { return false }
        installingPluginIDs.insert(entry.id)
        registryError = nil
        defer { installingPluginIDs.remove(entry.id) }

        do {
            guard let archiveURL = URL(string: entry.archiveURL, relativeTo: registryURL)?.absoluteURL else {
                throw PluginError.invalidURL(entry.archiveURL)
            }

            let expectedSHA = entry.sha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !expectedSHA.isEmpty else {
                throw PluginError.missingChecksum(entry.id)
            }

            let archiveData = try await downloadData(from: archiveURL)
            let actualSHA = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
            guard actualSHA == expectedSHA else {
                throw PluginError.checksumMismatch(expected: expectedSHA, actual: actualSHA)
            }

            let expectedID = entry.id
            let manifest = try await Task.detached(priority: .userInitiated) {
                try Self.stageAndInstallZip(data: archiveData, expectedID: expectedID)
            }.value
            reloadInstalledPlugins()

            if activateIfLanguage && manifest.type == .language {
                LocalizationManager.shared.selectLanguagePlugin(id: manifest.id)
            }
            return true
        } catch let err as PluginError {
            registryError = err.localizedDescription
            return false
        } catch {
            registryError = error.localizedDescription
            return false
        }
    }

    func uninstallPlugin(id: String) {
        guard let targetDir = PluginStorage.validatedPluginDirectory(id: id) else { return }
        try? FileManager.default.removeItem(at: targetDir)
        reloadInstalledPlugins()

        if LocalizationManager.shared.selectedLanguagePluginID == id {
            LocalizationManager.shared.selectLanguagePlugin(id: LocalizationManager.builtInEnglishID)
        }
    }

    // MARK: - Networking

    private func downloadData(from url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw PluginError.httpStatus(http.statusCode, url.lastPathComponent)
            }
        }
        return data
    }

    // MARK: - Extraction & Validation

    private nonisolated static func stageAndInstallZip(data: Data, expectedID: String) throws -> PluginManifest {
        guard isValidPluginID(expectedID),
              let destDir = PluginStorage.validatedPluginDirectory(id: expectedID) else {
            throw PluginError.invalidPluginPackage("Invalid plugin ID: \(expectedID)")
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("swiftflash-plugin-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let zipURL = tempRoot.appendingPathComponent("plugin.zip")
        try data.write(to: zipURL)

        let extractDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let extractRes = ProcessRunner.run(
            executablePath: "/usr/bin/ditto",
            arguments: ["-xk", zipURL.path, extractDir.path],
            timeoutSeconds: 60
        )
        guard extractRes.exitCode == 0 else {
            throw PluginError.unzipFailed(extractRes.stderr)
        }

        // Locate manifest.json either at root or inside a single nested folder
        let pluginSourceDir: URL
        let directManifest = extractDir.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: directManifest.path) {
            pluginSourceDir = extractDir
        } else if let children = try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]),
                  children.count == 1,
                  fm.fileExists(atPath: children[0].appendingPathComponent("manifest.json").path) {
            pluginSourceDir = children[0]
        } else {
            throw PluginError.invalidPluginPackage("manifest.json not found")
        }

        let manifestData = try Data(contentsOf: pluginSourceDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        guard manifest.id == expectedID, isValidPluginID(manifest.id) else {
            throw PluginError.invalidPluginPackage("Plugin ID mismatch: \(manifest.id)")
        }

        if manifest.type == .language {
            guard let loc = manifest.contributes?.localization else {
                throw PluginError.invalidPluginPackage("Missing localization contribution")
            }
            guard let stringsURL = PluginStorage.validatedRelativeFile(loc.stringsFile, inside: pluginSourceDir) else {
                throw PluginError.invalidPluginPackage("Invalid stringsFile path: \(loc.stringsFile)")
            }
            guard let stringsData = try? Data(contentsOf: stringsURL),
                  (try? JSONDecoder().decode([String: String].self, from: stringsData)) != nil else {
                throw PluginError.invalidPluginPackage("Invalid \(loc.stringsFile)")
            }
        }

        let pluginsRoot = PluginStorage.pluginsDirectory
        try fm.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destDir.path) {
            try fm.removeItem(at: destDir)
        }
        try fm.moveItem(at: pluginSourceDir, to: destDir)
        return manifest
    }
}

enum PluginError: LocalizedError {
    case invalidURL(String)
    case httpStatus(Int, String)
    case missingChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    case unzipFailed(String)
    case invalidPluginPackage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .httpStatus(let code, let file):
            return "HTTP \(code) while downloading \(file)"
        case .missingChecksum(let id):
            return "Plugin package \(id) is missing required SHA-256 checksum"
        case .checksumMismatch:
            return "Plugin package SHA-256 verification failed"
        case .unzipFailed(let msg):
            return "Failed to extract plugin archive: \(msg)"
        case .invalidPluginPackage(let reason):
            return "Invalid plugin package: \(reason)"
        }
    }
}
