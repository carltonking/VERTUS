import Foundation

// MARK: - Home dir (platform split)
// macOS: the real ~ (token file + shared UI state live there). iOS: the app
// sandbox home — the token file never exists there (Keychain holds it) and
// the UI-state dir is per-app, which is exactly right for the phone's own
// stream cursor. One resolver so nothing else needs an #if.
public enum VertusHome {
    public static var directory: URL {
        #if os(iOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .deletingLastPathComponent()  // the sandbox container root
        #else
        FileManager.default.homeDirectoryForCurrentUser
        #endif
    }
}

// MARK: - Server config
// Token resolution order (unchanged from the old bar): UserDefaults override
// ("vertus.token" / "vertus.baseURL"), else ~/.vertus/token.

public struct ServerConfig: Equatable {
    public var baseURL: String
    public var token: String

    public init(baseURL: String, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Base URL resolution precedence: VERTUS_HUB_URL (env, dev builds and
    /// launchd-smoke runs point at a temp hub) > UserDefaults "vertus.baseURL"
    /// > http://127.0.0.1:8787. Token resolution is unchanged below.
    public static func load() -> ServerConfig {
        load(environment: ProcessInfo.processInfo.environment)
    }

    /// Testable core: the env dictionary is injectable so the precedence chain
    /// can be asserted without mutating the real process environment.
    static func load(environment: [String: String]) -> ServerConfig {
        let defaults = UserDefaults.standard
        let base = environment["VERTUS_HUB_URL"]
            ?? defaults.string(forKey: "vertus.baseURL")
            ?? "http://127.0.0.1:8787"
        var token = defaults.string(forKey: "vertus.token") ?? ""
        if token.isEmpty {
            let path = VertusHome.directory
                .appendingPathComponent(".vertus/token")
            token = (try? String(contentsOf: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ServerConfig(baseURL: base, token: token)
    }

    public var isConfigured: Bool { !token.isEmpty }
}

// MARK: - Shared UI state files
// VertusBar and VertusFleet are separate processes, so cross-app UI state is
// exchanged through small JSON files under ~/.vertus/ui/ (UserDefaults is
// per-bundle and unreliable for bare executables).

public enum SharedUIState {
    /// VERTUS_UI_DIR overrides the shared-state dir (the test suite points
    /// it at a temp dir so cursors/mutes never touch the real ~/.vertus).
    public static var uiDir: URL {
        if let override = ProcessInfo.processInfo.environment["VERTUS_UI_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return VertusHome.directory
            .appendingPathComponent(".vertus/ui", isDirectory: true)
    }

    private static func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        let url = uiDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to name: String) {
        try? FileManager.default.createDirectory(at: uiDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: uiDir.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Foreground agent
    // The app whose window currently shows an agent writes its id here; the
    // notification service suppresses completion alerts for that agent.

    public static func foregroundAgentID() -> String? {
        read("foreground-agent.json", as: String.self)
    }

    public static func setForegroundAgentID(_ id: String?) {
        write(id ?? "", to: "foreground-agent.json")
    }

    // MARK: Per-agent mute

    public static func mutedAgentIDs() -> Set<String> {
        Set(read("muted-agents.json", as: [String].self) ?? [])
    }

    public static func setMuted(_ muted: Bool, agentID: String) {
        var ids = mutedAgentIDs()
        if muted { ids.insert(agentID) } else { ids.remove(agentID) }
        write(Array(ids).sorted(), to: "muted-agents.json")
    }
}

// MARK: - Stream cursor
// Each app keeps its own monotonic last-seen seq (the fleet `seq` is a
// global cursor across all agents; a per-process file means a slow consumer
// never drags a fast one backwards).

public final class StreamCursor {
    private let url: URL
    private var value: Int

    public init(processName: String) {
        url = SharedUIState.uiDir.appendingPathComponent("cursor-\(processName).json")
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } catch {
            value = 0
            NSLog("[vertus-stream] cursor read failed for %@: %@", url.path,
                  (error as NSError).localizedDescription)
        }
        NSLog("[vertus-stream] cursor url=%@ value=%d", url.path, value)
    }

    /// Last seq the consuming process has fully applied (0 = never saw one).
    public var lastSeq: Int { value }

    /// Persist a new high-water mark (monotonic: never moves backwards).
    public func advance(to seq: Int) {
        guard seq > value else { return }
        value = seq
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(value)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// True when the process has never consumed an event (first launch).
    public var hasSeenEvents: Bool { value > 0 }
}