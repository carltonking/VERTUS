import Foundation
import AppKit

/// Phase 4 — the action gateway (trust core).
/// Every state-changing action Alfred takes goes through here. Two independent protections:
///  1. SOURCE ISOLATION: only `.user`-originated requests may act. Anything derived from
///     screen/OCR/memory is `.screen` and is REFUSED — this kills prompt injection
///     (threat-model T1) with zero friction on the user's own commands.
///  2. RISK GATING: contained/reversible actions run freely; irreversible or outward-facing
///     ones (delete, overwrite, network/destructive shell) require explicit confirmation.
/// Everything — allowed, blocked, or denied — is written to an append-only audit log (T3).
struct ActionGateway {

    enum Origin { case user, screen }

    enum Action {
        case createFile(path: String, contents: String)
        case appendFile(path: String, contents: String)
        case openApp(String)
        case runShell(String)
        case deleteFile(path: String)
        case clickUI(title: String)
        case typeText(String)
    }

    // UI button titles that are irreversible or outward-facing → confirm before clicking.
    static let dangerousButtons = [
        "send", "delete", "remove", "discard", "trash", "pay", "buy", "purchase",
        "transfer", "post", "publish", "submit", "confirm", "place order", "unsubscribe",
        "block", "report", "archive", "move to"
    ]

    enum Risk { case free, confirm(reason: String) }

    enum Outcome: CustomStringConvertible {
        case done(String)
        case blocked(String)     // refused by source isolation
        case denied(String)      // user declined confirmation
        case failed(String)
        var description: String {
            switch self {
            case .done(let s):    return "done: \(s)"
            case .blocked(let s): return "BLOCKED: \(s)"
            case .denied(let s):  return "denied: \(s)"
            case .failed(let s):  return "failed: \(s)"
            }
        }
    }

    /// When true, irreversible/outward actions run WITHOUT prompting (full autonomy).
    /// Source isolation + audit log still apply; audit becomes the review-after net.
    var autonomous: Bool = false

    /// Confirmer is injected so tests/headless runs can auto-answer; CLI uses stdin.
    var confirm: (_ prompt: String) -> Bool

    private let auditPath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alfred", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.log").path
    }()

    // MARK: classification

    // Shell tokens that are irreversible or send data off the machine.
    static let dangerousShell = [
        "rm ", "rm -", "rmdir", "unlink", " dd ", "mkfs", "shutdown", "reboot", ":(){",
        "curl", "wget", "scp", "rsync", "ssh ", " nc ", "ncat", "telnet", "ftp",
        "git push", "npm publish", "osascript", "mail ", "sendmail", "shred", "diskutil",
        "sudo", "chmod 777", "launchctl", "crontab", "> /", "killall"
    ]

    func classify(_ action: Action) -> Risk {
        switch action {
        case .createFile(let path, _):
            return FileManager.default.fileExists(atPath: path)
                ? .confirm(reason: "would OVERWRITE existing file \(path)")
                : .free
        case .appendFile:
            return .free
        case .openApp:
            return .free
        case .runShell(let cmd):
            let lower = cmd.lowercased()
            if let hit = Self.dangerousShell.first(where: { lower.contains($0) }) {
                return .confirm(reason: "shell command contains irreversible/outward op '\(hit.trimmingCharacters(in: .whitespaces))'")
            }
            return .free
        case .deleteFile(let path):
            return .confirm(reason: "would permanently DELETE \(path)")
        case .clickUI(let title):
            let lower = title.lowercased()
            if let hit = Self.dangerousButtons.first(where: { lower.contains($0) }) {
                return .confirm(reason: "clicking '\(title)' is irreversible/outward (matches '\(hit)')")
            }
            return .free
        case .typeText:
            return .free   // typing is reversible; the dangerous part is the button that submits it
        }
    }

    // MARK: execute

    func perform(_ action: Action, origin: Origin) -> Outcome {
        let label = describe(action)

        // Protection 1 — source isolation. State-changing + not user-authorized → refuse.
        guard origin == .user else {
            let o = Outcome.blocked("screen-/memory-originated action is never executed: \(label)")
            audit(action: label, origin: origin, decision: "blocked")
            return o
        }

        // Protection 2 — risk gating. Autonomous mode auto-approves but still records it.
        if case .confirm(let reason) = classify(action) {
            if autonomous {
                audit(action: label, origin: origin, decision: "auto-approved")
            } else if !confirm("⚠️  \(reason)\n    Action: \(label)\n    Proceed?") {
                audit(action: label, origin: origin, decision: "denied")
                return .denied(label)
            }
        }

        do {
            let result = try run(action)
            audit(action: label, origin: origin, decision: "done")
            return .done(result)
        } catch {
            audit(action: label, origin: origin, decision: "failed:\(error)")
            return .failed("\(error)")
        }
    }

    private func run(_ action: Action) throws -> String {
        switch action {
        case .createFile(let path, let contents), .appendFile(let path, let contents):
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if case .appendFile = action, FileManager.default.fileExists(atPath: path) {
                let h = try FileHandle(forWritingTo: url); try h.seekToEnd()
                try h.write(contentsOf: Data(contents.utf8)); try h.close()
            } else {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            return path
        case .openApp(let name):
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", name]; try p.run(); p.waitUntilExit()
            return "opened \(name)"
        case .runShell(let cmd):
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", cmd]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return "exit \(p.terminationStatus)\n\(out)"
        case .deleteFile(let path):
            try FileManager.default.removeItem(atPath: path)
            return "deleted \(path)"
        case .clickUI(let title):
            guard UIControl.isTrusted() else { throw Err("Accessibility permission not granted") }
            guard UIControl.click(title: title) else { throw Err("no clickable element titled '\(title)'") }
            return "clicked '\(title)'"
        case .typeText(let text):
            guard UIControl.isTrusted() else { throw Err("Accessibility permission not granted") }
            guard UIControl.type(text) else { throw Err("type failed") }
            return "typed \(text.count) chars"
        }
    }

    struct Err: Error, CustomStringConvertible { let m: String; init(_ m: String) { self.m = m }; var description: String { m } }

    private func describe(_ action: Action) -> String {
        switch action {
        case .createFile(let p, _): return "createFile \(p)"
        case .appendFile(let p, _): return "appendFile \(p)"
        case .openApp(let n):       return "openApp \(n)"
        case .runShell(let c):      return "runShell `\(c)`"
        case .deleteFile(let p):    return "deleteFile \(p)"
        case .clickUI(let t):       return "clickUI '\(t)'"
        case .typeText(let t):      return "typeText (\(t.count) chars)"
        }
    }

    // MARK: audit (append-only)

    private func audit(action: String, origin: Origin, decision: String) {
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: now()),
            "action": action,
            "origin": origin == .user ? "user" : "screen",
            "decision": decision
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: auditPath) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data((line + "\n").utf8)); try? h.close()
        } else {
            try? (line + "\n").write(toFile: auditPath, atomically: true, encoding: .utf8)
        }
    }

    func recentAudit(_ n: Int = 20) -> [String] {
        guard let content = try? String(contentsOfFile: auditPath, encoding: .utf8) else { return [] }
        return Array(content.split(separator: "\n").map(String.init).suffix(n))
    }

    var auditLogPath: String { auditPath }
}
