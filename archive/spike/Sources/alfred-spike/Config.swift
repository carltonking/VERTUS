import Foundation

/// Persisted Alfred settings (Application Support/Alfred/config.json).
/// `autonomous` = act without confirmation prompts. Source isolation and the audit
/// log stay on regardless; in autonomous mode the audit log is the review-after safety net.
struct Config: Codable {
    var autonomous: Bool = false

    static var path: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alfred", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json").path
    }

    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: Self.path))
        }
    }
}
