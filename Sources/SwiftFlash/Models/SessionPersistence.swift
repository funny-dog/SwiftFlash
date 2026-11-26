import Foundation

// MARK: - Persistent Project Session & Window Layout

struct PersistedTabRecord: Codable, Equatable, Sendable {
    let path: String
    let cursorLine: Int
    let cursorColumn: Int
    let scrollOffsetY: Double?
}

struct PersistedProjectSession: Codable, Equatable, Sendable {
    let projectPath: String
    let openTabs: [PersistedTabRecord]
    let activeFilePath: String?
    let secondaryFilePath: String?
    let isSplitEditorActive: Bool
    let isSidebarVisible: Bool
    let isTerminalVisible: Bool
    let sidebarModeRaw: String
    let bottomPanelTabRaw: String
    let updatedAt: TimeInterval
}

struct PersistedWindowFrame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum SessionPersistence {
    private static let sessionsKey = "swiftflash.persistedProjectSessions.v1"
    private static let windowFrameKey = "swiftflash.persistedWindowFrame.v1"
    private static let maxPersistedProjects = 24

    static func loadSession(for projectURL: URL, userDefaults: UserDefaults) -> PersistedProjectSession? {
        let key = projectURL.standardized.path
        let map = loadAllSessions(userDefaults: userDefaults)
        return map[key]
    }

    static func saveSession(_ session: PersistedProjectSession, userDefaults: UserDefaults) {
        var map = loadAllSessions(userDefaults: userDefaults)
        map[session.projectPath] = session

        if map.count > maxPersistedProjects {
            let sorted = map.values.sorted { $0.updatedAt > $1.updatedAt }
            var trimmed: [String: PersistedProjectSession] = [:]
            for item in sorted.prefix(maxPersistedProjects) {
                trimmed[item.projectPath] = item
            }
            map = trimmed
        }

        if let data = try? JSONEncoder().encode(map) {
            userDefaults.set(data, forKey: sessionsKey)
        }
    }

    static func loadAllSessions(userDefaults: UserDefaults) -> [String: PersistedProjectSession] {
        guard let data = userDefaults.data(forKey: sessionsKey),
              let decoded = try? JSONDecoder().decode([String: PersistedProjectSession].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func saveWindowFrame(_ frame: PersistedWindowFrame, userDefaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(frame) {
            userDefaults.set(data, forKey: windowFrameKey)
        }
    }

    static func loadWindowFrame(userDefaults: UserDefaults = .standard) -> PersistedWindowFrame? {
        guard let data = userDefaults.data(forKey: windowFrameKey),
              let frame = try? JSONDecoder().decode(PersistedWindowFrame.self, from: data) else {
            return nil
        }
        return frame
    }
}
