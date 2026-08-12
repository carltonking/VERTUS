import Foundation
import AppKit

// MARK: - Events
//
// What the bar renders. One case per `session/update` variant we care about;
// the rest of the ACP surface (plan, config_option_update, …) is dropped here
// rather than in the view, so the UI never sees protocol noise.

enum HermesEvent: Sendable {
    /// Incremental assistant text. Append, never replace.
    case text(String)
    /// Reasoning trace — rendered dim, or hidden.
    case thought(String)
    /// A tool run started. `title` is human-readable ("Run shell command").
    case toolStarted(id: String, title: String, kind: String?)
    /// A tool run changed state: pending → in_progress → completed / failed.
    case toolProgress(id: String, status: String?, title: String?)
    /// Context-window telemetry.
    case usage(used: Int, size: Int)
    /// Turn finished cleanly. `stopReason` is typically "end_turn".
    case finished(stopReason: String)
    /// Turn failed. Already human-readable.
    case failed(String)
}

// MARK: - Errors

/// A picture attached to a prompt — a screenshot, an invite, a photo of a
/// poster, whatever. Sent to Hermes as an ACP `image` content block (base64
/// inline), which the provider sees as a real image, not an OCR string.
struct ImageAttachment: Sendable, Equatable {
    let data: Data
    let mimeType: String

    var base64: String { data.base64EncodedString() }

    /// Normalize anything the picker/clipboard produced into a provider-safe
    /// lossless PNG. HEIC and TIFF never ship as-is — the model can't see them.
    static func png(from data: Data) -> ImageAttachment? {
        guard let nsImage = NSImage(data: data),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return ImageAttachment(data: png, mimeType: "image/png")
    }
}

/// Anything the user pins to a prompt: a picture the model can *see*, or a
/// local file it can *read*. Text-ish files ride as plain text blocks; images
/// ship as ACP image blocks. Binary files have no provider-safe representation
/// yet, so the picker still lets the user choose them but attach() rejects.
enum FileAttachment: Sendable, Equatable {
    case image(ImageAttachment)
    case text(name: String, contents: String)

    /// Decode a picked/dropped URL into an attachment, if it's usable.
    /// Images win first (any format the ImageIO layer can read), then UTF-8
    /// text up to `maxTextBytes` (a whole novel, but not a whole binary dump).
    static func decode(url: URL, maxTextBytes: Int = 512 * 1024) -> FileAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return from(data: data, name: url.lastPathComponent, maxTextBytes: maxTextBytes)
    }

    static func from(data: Data, name: String, maxTextBytes: Int = 512 * 1024) -> FileAttachment? {
        if let image = ImageAttachment.png(from: data) {
            return .image(image)
        }
        guard data.count <= maxTextBytes,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return .text(name: name, contents: text)
    }
}

// MARK: - Engines

/// Which agent a session spawns. `.hermes` is the general assistant;
/// `.opencode` is the forked coding agent (github.com/carltonking/opencode,
/// `alfred-integration` branch); `.primeAgent` is the self-improving RLM
/// coding agent (PrimeIntellect-ai/prime-agent, a pi fork); `.freebuff` is the
/// external agentic coding CLI launched in ACP mode (resolved from PATH — see
/// resolveFreebuff). All speak the same ACP wire protocol; they differ in
/// binary, model and posture.
enum AgentEngine: Sendable, Equatable {
    case hermes
    case opencode
    case primeAgent
    case freebuff
}

/// Permission posture for the opencode engine. `.task` lets the agent code
/// (bash carries only a destructive-pattern deny-list); `.readonly` denies
/// every mutating tool — analysis without side effects. Both are enforced by
/// opencode's own config-level permission rules (see docs/alfred in the fork),
/// injected via `OPENCODE_CONFIG_CONTENT`.
enum OpencodePosture: Sendable, Equatable {
    case task
    case readonly
}

enum HermesError: LocalizedError {
    case binaryNotFound
    /// The opencode coding agent couldn't be located or launched. Message is actionable.
    case codingAgentUnavailable(String)
    case launchFailed(String)
    case agentExited(Int32)
    case protocolError(String)
    /// The agent didn't answer a prompt within the turn deadline. Hermes can
    /// wedge upstream (Ollama scheduler races, MCP stdio stalls) without
    /// exiting; the turn watchdog treats this as a recoverable fault.
    case turnTimedOut
    /// Hermes has no `model.provider` set. Expected cold-start state, not a crash.
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Hermes isn't installed. Install it, then reopen Alfred."
        case .codingAgentUnavailable(let m):
            return "Alfred's coding agent isn't available: \(m)"
        case .launchFailed(let m):
            return "Couldn't start Hermes: \(m)"
        case .agentExited(let code):
            return "Hermes stopped unexpectedly (exit \(code))."
        case .protocolError(let m):
            return "Hermes sent something unexpected: \(m)"
        case .turnTimedOut:
            return "Hermes didn't answer within the turn deadline. The session restarted to recover."
        case .notConfigured(let m):
            return m
        }
    }
}

// MARK: - Session

/// Owns one long-lived `hermes acp` subprocess and speaks ACP (JSON-RPC 2.0 over
/// stdio) to it.
///
/// Contract verified live against hermes-agent 0.19.0 — see
/// `scratchpad/ACP_CONTRACT.md`. The parts that bite:
///
///   * **stdout is protocol only.** Hermes logs to stderr. Parsing stderr as
///     JSON produces phantom failures, so the two pipes are read separately.
///   * **`session/prompt` resolves only when the whole turn ends.** Streaming
///     text arrives out-of-band as `session/update` notifications, so the
///     response and the notifications must be consumed concurrently.
///   * **The agent calls back into us.** `session/request_permission` arrives
///     mid-turn and the turn *deadlocks* until answered.
///   * `ping`/`health` answer with JSON-RPC -32601 by design — not an error.
actor HermesSession {

    // MARK: Configuration

    /// Answer `session/request_permission` automatically.
    ///
    /// Phase 1 ships `true` so the loop runs unattended. Every request is still
    /// surfaced as a `.toolStarted` event, so nothing happens silently. The
    /// confirm affordance in the bar (Phase 2) flips this to `false` and routes
    /// the decision to the user — that is the natural home for the destructive
    /// and secret guards already in `ComputerControlCapability`.
    private let autoApprovePermissions: Bool

    /// Which agent this session runs — hermes or the forked opencode coding agent.
    private let engine: AgentEngine
    /// Permission posture for the opencode engine (ignored for hermes).
    private let posture: OpencodePosture

    private let workingDirectory: String

    // MARK: Process

    private var process: Process?
    private var stdinPipe: Pipe?
    private var sessionID: String?

    /// Accumulates stdout across reads — a JSON frame can span several chunks,
    /// and a single chunk can carry several frames.
    private var readBuffer = Data()

    /// Hard ceiling for one turn's prompt round-trip. Hermes wedges upstream
    /// (Ollama scheduler races, MCP stdio stalls) without exiting; the turn
    /// watchdog restarts the session and retries once instead of hanging.
    static let turnDeadline: TimeInterval = 180

    /// This session's own deadline. Defaults to `turnDeadline`; the remote code
    /// manager raises it for coding sessions, where a generation can legitimately
    /// run several minutes before the first answer.
    private let turnDeadline: TimeInterval

    /// True while the agent process is frozen by a `pause` (SIGSTOP). The turn
    /// watchdog keeps re-arming instead of firing, so a paused session isn't
    /// killed by its own deadline — it's suspended, not stuck.
    private var isSuspended = false

    // MARK: JSON-RPC

    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Sink for the turn currently streaming. Only one turn runs at a time.
    private var eventSink: AsyncStream<HermesEvent>.Continuation?

    /// True while a `session/prompt` turn is in flight. Background watchers (the
    /// mail alert triager) check this before starting a turn of their own, so a
    /// background classification never silently hijacks the single shared
    /// agent session the user is talking to.
    private(set) var isTurnActive = false

    /// The text of the turn currently streaming, accumulated chunk by chunk so
    /// the finished reply can be handed to agentmemory (observed verbatim, and
    /// run through the local alfred-coder extractor for the memory graph).
    /// Reset at the top of every turn; only read after the turn resolves.
    private var turnTextBuffer = ""

    init(engine: AgentEngine = .hermes,
         posture: OpencodePosture = .task,
         workingDirectory: String = NSHomeDirectory(),
         autoApprovePermissions: Bool = true,
         turnDeadline: TimeInterval? = nil) {
        self.engine = engine
        self.posture = posture
        self.workingDirectory = workingDirectory
        self.autoApprovePermissions = autoApprovePermissions
        self.turnDeadline = turnDeadline ?? Self.turnDeadline
    }

    // MARK: - Binary resolution

    /// Resolve the agent binary and the argv to launch it with.
    ///
    /// Hermes: venv binary first, then the shell wrapper and usual bins, then a
    /// login-shell `command -v` (a GUI app launched by Finder or launchd
    /// inherits a minimal `PATH` that usually excludes `~/.local/bin`, so PATH
    /// alone fails exactly when the app is used normally).
    ///
    /// Opencode (the coding agent fork): an explicit `ALFRED_OPENCODE_BIN`
    /// wins, then a compiled `opencode` on the usual user bins (the production
    /// path once the fork is built), then the dev path — bun running the fork's
    /// source (`bun run --cwd <fork>/packages/opencode --conditions=browser
    /// src/index.ts acp`). The dev path needs the fork checked out at
    /// `~/02 - REPOS/opencode` (override with `ALFRED_OPENCODE_REPO`) and bun
    /// on the usual bins.
    ///
    /// Prime-agent (the self-improving RLM coding agent): a global npm install
    /// (`~/.npm-global/bin/prime-agent`), launched in ACP mode. `--offline`
    /// skips startup network checks; `--provider`/`--model` are pinned to a
    /// ringed provider so the agent never defaults to one Alfred can't
    /// authenticate (verified live: it reads GEMINI_API_KEY/GROQ_API_KEY/…
    /// straight from the env Alfred already injects).
    private static func resolveLauncher(for engine: AgentEngine) -> (binary: String, arguments: [String])? {
        switch engine {
        case .hermes:
            return resolveHermes().map { ($0, ["acp"]) }
        case .opencode:
            return resolveOpencode()
        case .primeAgent:
            return resolvePrimeAgent()
        case .freebuff:
            return resolveFreebuff()
        }
    }

    private static func resolveHermes() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.hermes/hermes-agent/venv/bin/hermes",
            "\(home)/.local/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: ask a login shell, which does source the user's profile.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "command -v hermes"]
        let out = Pipe()
        which.standardOutput = out
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        } catch { /* fall through */ }
        return nil
    }

    private static func resolveOpencode() -> (binary: String, arguments: [String])? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()

        // 1. Explicit override.
        if let bin = env["ALFRED_OPENCODE_BIN"],
           FileManager.default.isExecutableFile(atPath: bin) {
            return (bin, ["acp"])
        }
        // 2. Compiled binary on the usual bins (production path once built).
        for path in ["\(home)/.local/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"] {
            if FileManager.default.isExecutableFile(atPath: path) { return (path, ["acp"]) }
        }
        // 3. Dev path: bun running the fork's source.
        let repo = env["ALFRED_OPENCODE_REPO"] ?? "\(home)/02 - REPOS/opencode"
        guard FileManager.default.isReadableFile(atPath: "\(repo)/packages/opencode/src/index.ts") else { return nil }
        let bunCandidates = ["\(home)/.local/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
        guard let bun = bunCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return (bun, ["run", "--cwd", "\(repo)/packages/opencode", "--conditions=browser", "src/index.ts", "acp"])
    }

    /// Resolve prime-agent (the self-improving RLM coding agent) and its argv.
    ///
    /// Installed as a global npm package (`~/.npm-global/bin/prime-agent`), or
    /// found on the usual bins. The ACP mode is `--mode acp`; `--offline`
    /// skips the startup network/version checks (faster, and deterministic
    /// under a GUI launch). The provider and model are pinned to what the
    /// keyring can actually serve — prime-agent's default model can point at a
    /// provider Alfred has no key for, which surfaces as a 401 at turn time.
    private static func resolvePrimeAgent() -> (binary: String, arguments: [String])? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.npm-global/bin/prime-agent",
            "\(home)/.local/bin/prime-agent",
            "/opt/homebrew/bin/prime-agent",
            "/usr/local/bin/prime-agent",
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        let model = primeAgentModelSelection()
        guard let (provider, modelID) = model else {
            // No ringed provider prime-agent can serve. Still launch — the
            // agent will answer with its own no-provider error at turn time,
            // which is more honest than refusing to spawn. Log it: a silent
            // launch without provider/model is the first thing to suspect
            // when prime answers with a 401 out of the blue.
            NSLog("[hermes] prime-agent launching with no ringed provider it can serve — add a gemini/groq key")
            return (binary, ["--mode", "acp", "--offline"])
        }
        return (binary, ["--mode", "acp", "--offline", "--provider", provider, "--model", modelID])
    }

    /// Resolve the external freebuff CLI (the agentic coding product) in ACP
    /// mode. `ALFRED_FREEBUFF_BIN` wins, then the usual user bins, then a
    /// login-shell `command -v` so a GUI launch still finds it. Not present →
    /// nil; the manager reports that clearly rather than silently failing at
    /// prompt time.
    private static func resolveFreebuff() -> (binary: String, arguments: [String])? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        if let bin = env["ALFRED_FREEBUFF_BIN"],
           FileManager.default.isExecutableFile(atPath: bin) {
            return (bin, ["acp"])
        }
        for path in ["\(home)/.local/bin/freebuff", "/opt/homebrew/bin/freebuff", "/usr/local/bin/freebuff"] {
            if FileManager.default.isExecutableFile(atPath: path) { return (path, ["acp"]) }
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "command -v freebuff"]
        let out = Pipe()
        which.standardOutput = out
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return (path, ["acp"]) }
        } catch { /* fall through */ }
        return nil
    }

    /// Map a ring provider to prime-agent's provider id (the names its
    /// credential resolver reads env keys for: `google` → GEMINI_API_KEY,
    /// `groq` → GROQ_API_KEY, …). Providers with no native prime-agent
    /// registry entry are skipped — an unused auth entry is inert.
    static func primeAgentProviderID(for provider: LLMProvider) -> String? {
        switch provider {
        case .gemini: return "google"
        case .zai: return "zai"
        case .kimi: return "moonshotai"
        case .minimax: return "minimax"
        case .deepseek: return "deepseek"
        case .groq: return "groq"
        case .openrouter: return "openrouter"
        case .nvidia: return "nvidia"
        case .stepfun, .alibaba, .puter, .freellmpool: return nil
        }
    }

    /// A model id prime-agent's registry knows, per ringed provider, on the
    /// free tier where one exists. Picks are the same free-friendly models the
    /// opencode mapping uses, spelled the way prime-agent's registry names
    /// them (verified against its models.generated.js).
    static func primeAgentModel(for provider: LLMProvider) -> String? {
        switch provider {
        case .gemini: return "google/gemini-3-flash"
        case .zai: return "zai/glm-4.5-air"
        case .kimi: return "moonshotai/kimi-k2.5"
        case .minimax: return "minimax/minimax-m2"
        case .deepseek: return "deepseek/deepseek-chat"
        case .groq: return "groq/llama-3.1-8b-instant"
        case .openrouter: return "openrouter/free"
        case .nvidia: return "nvidia/nemotron-3-nano-30b-a3b"
        case .stepfun, .alibaba, .puter, .freellmpool: return nil
        }
    }

    /// Pick the model for the prime-agent session: the active key's provider
    /// first, then the first ringed provider prime-agent can serve. Nil when
    /// the ring holds no prime-compatible key — the agent then fails at prompt
    /// time with its own no-provider error, which is honest.
    static func primeAgentModelSelection() -> (provider: String, model: String)? {
        let ring = ProviderKeyRing.shared
        if let active = ring.activeKey,
           let provider = primeAgentProviderID(for: active.provider),
           let model = primeAgentModel(for: active.provider) {
            return (provider, model)
        }
        for provider in ring.providers {
            if let pid = primeAgentProviderID(for: provider), let model = primeAgentModel(for: provider) {
                return (pid, model)
            }
        }
        return nil
    }

    /// Environment for spawned agent processes: the app's own env with the
    /// usual user bins prepended to PATH (see start()). For the opencode
    /// engine, the coding agent's credentials, permission posture and journal
    /// destination are injected here too (see the opencode helpers below).
    /// Rebuilt on every start(), so a provider-ring rotation is picked up on
    /// the next spawn.
    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = "\(home)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        env["PATH"] = "\(extra):\(env["PATH"] ?? "/usr/bin:/bin")"
        // Each stored provider key powers hermes' matching provider
        // (GEMINI_API_KEY → gemini, GLM_API_KEY → zai, ...). Hermes picks its
        // primary provider from its own config; these env vars let the
        // fallback_providers chain (synced by ProviderKeyRing) authenticate
        // every stored provider. None stored → the agent falls back to its
        // own defaults.
        for provider in LLMProvider.allCases {
            if let key = ProviderKeyRing.shared.key(for: provider) {
                env[provider.apiKeyEnvVar] = key.key
            } else {
                env.removeValue(forKey: provider.apiKeyEnvVar)
            }
        }
        // Opencode credentials/config. Hermes authenticates from its own
        // credential pool (~/.hermes); the fork has no such pool, so Alfred is
        // its keyring — injected as OPENCODE_AUTH_CONTENT (ProviderKeyRing,
        // mapped to opencode provider ids) plus the posture config and journal
        // path. The journaling plugin in the fork is env-gated on ALFRED_JOURNAL.
        if engine == .opencode {
            if let auth = Self.opencodeAuthContent() { env["OPENCODE_AUTH_CONTENT"] = auth }
            if let model = Self.opencodeModelSelection() {
                env["OPENCODE_CONFIG_CONTENT"] = Self.opencodeConfigContent(posture: posture, model: model)
            }
            env["ALFRED_JOURNAL"] = Self.opencodeJournalPath()
            env["ALFRED_MODE"] = posture == .readonly ? "readonly" : "task"
        }
        if engine == .hermes || engine == .primeAgent {
            if let initRecord = hermesInitRecord() { env["ALFRED_INIT"] = initRecord }
        }
        return env
    }

    /// `ALFRED_INIT` — the session-init contract record (see
    /// docs/session-init-contract.md). Declarative today: hermes does not read
    /// it yet, so an ignored record degrades to BOT exactly as the contract
    /// requires. When obs/helm modes land, this env var is what switches the
    /// spawned session's mode and readonly guarantees.
    private func hermesInitRecord() -> String? {
        let engineID = engine == .primeAgent ? "prime-agent" : "hermes"
        let mode: String
        switch posture {
        case .readonly: mode = "obs"
        case .task: mode = "BOT"
        }
        let record: [String: Any] = [
            "schema": 1,
            "mode": mode,
            "engine": engineID,
            "model": "",
            "toolsets": [],
            "session_id": sessionID ?? "",
            "readonly": posture == .readonly,
            "initiated_at": Self.isoNow(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Opencode engine environment

    /// Map a ring provider to opencode's provider id. Providers with no native
    /// registry entry in the fork (stepfun, alibaba, puter, freellmpool) are
    /// skipped — an unused auth entry is inert, but a wrong id is misleading.
    static func opencodeProviderID(for provider: LLMProvider) -> String? {
        switch provider {
        case .gemini: return "google"
        case .zai: return "zai"
        case .kimi: return "moonshotai"
        case .minimax: return "minimax"
        case .deepseek: return nil     // no native deepseek provider in the fork
        case .stepfun: return nil      // no native stepfun provider in the fork
        case .alibaba: return nil      // no native alibaba/qwen provider in the fork
        case .nvidia: return "nvidia"
        case .groq: return "groq"
        case .openrouter: return "openrouter"
        case .puter, .freellmpool: return nil
        }
    }

    /// A model id verified in the fork's runtime registry (the ACP model
    /// select at this opencode version — note it differs from the live
    /// models.dev API: there is no native deepseek/stepfun/alibaba provider,
    /// so those ring keys have no paid route here). Free-tier-friendly picks,
    /// mirroring the ring's `defaultFreeModel` where the id exists.
    static func opencodeModel(for provider: LLMProvider) -> String? {
        switch provider {
        case .gemini: return "google/gemini-flash-lite-latest"
        case .zai: return "zai/glm-4.5-flash"
        case .kimi: return "moonshotai/kimi-k2.5"
        case .minimax: return "minimax/MiniMax-M2"
        // Zen free tier — always available, no key needed. The ring's
        // DeepSeek key has no native provider to spend on in this fork.
        case .deepseek: return "opencode/deepseek-v4-flash-free"
        case .groq: return "groq/llama-3.1-8b-instant"
        case .openrouter: return "openrouter/google/gemini-2.5-flash"
        case .nvidia: return "nvidia/deepseek-ai/deepseek-v4-flash"
        case .stepfun, .alibaba, .puter, .freellmpool: return nil
        }
    }

    /// Pick the model for the coding session: the active key's provider first,
    /// then the first ringed provider opencode can serve. Nil when the ring
    /// holds no opencode-compatible key — the session then fails at prompt time
    /// with the agent's own no-provider error, which is honest.
    static func opencodeModelSelection() -> String? {
        let ring = ProviderKeyRing.shared
        if let active = ring.activeKey, let model = opencodeModel(for: active.provider) { return model }
        for provider in ring.providers {
            if let model = opencodeModel(for: provider) { return model }
        }
        return nil
    }

    /// `OPENCODE_AUTH_CONTENT` — the ProviderKeyRing as opencode's auth store:
    /// `{ "<opencode provider id>": { "type": "api", "key": "..." }, ... }`.
    /// A record of every ringed provider opencode knows; built fresh on each
    /// spawn, so ring rotations are picked up on the next process start.
    static func opencodeAuthContent(ring: ProviderKeyRing = .shared) -> String? {
        let entries: [(LLMProvider, String)] = LLMProvider.allCases.compactMap { provider in
            guard opencodeProviderID(for: provider) != nil,
                  let key = ring.key(for: provider) else { return nil }
            return (provider, key.key)
        }
        return opencodeAuthContent(entries: entries)
    }

    /// Build `OPENCODE_AUTH_CONTENT` from (provider, key) pairs. Pure, so the
    /// mapping is unit-testable without touching the key file on disk.
    static func opencodeAuthContent(entries: [(LLMProvider, String)]) -> String? {
        var auth: [String: Any] = [:]
        for (provider, key) in entries {
            guard let opencodeID = opencodeProviderID(for: provider) else { continue }
            auth[opencodeID] = ["type": "api", "key": key]
        }
        guard !auth.isEmpty, let data = try? JSONSerialization.data(withJSONObject: auth) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `OPENCODE_CONFIG_CONTENT` — the posture (permission) config with the
    /// model resolved from the ring. opencode merges this as a *local* source,
    /// so it wins over any global `~/.config/opencode/opencode.json`.
    static func opencodeConfigContent(posture: OpencodePosture, model: String) -> String {
        let permission: String
        switch posture {
        case .task: permission = Self.taskPermissionJSON
        case .readonly: permission = Self.readonlyPermissionJSON
        }
        return "{\n  \"model\": \"\(model)\",\n  \"permission\": \(permission)\n}"
    }

    /// Journal destination for the fork's journaling plugin (env-gated on
    /// `ALFRED_JOURNAL`): an append-only JSONL file inside the Obsidian vault.
    static func opencodeJournalPath() -> String {
        let vault = AlfredConfig.vaultPath() as NSString
        return vault.appendingPathComponent("PKM/My Life/Projects/Alfred Coding Agent Log.md")
    }

    // Keep these permission objects in sync with docs/alfred/opencode.json and
    // docs/alfred/opencode.readonly.json in the fork — they are the same rules,
    // embedded so the app is self-contained.
    private static let taskPermissionJSON = #"""
    {
      "bash": {
        "rm -rf /": "deny",
        "rm -rf /*": "deny",
        "rm -rf ~": "deny",
        "rm -rf ~/*": "deny",
        "sudo *": "deny",
        "sudo rm *": "deny",
        "git push --force*": "deny",
        "git push -f*": "deny",
        "git reset --hard*": "deny",
        "git clean -fdx*": "deny",
        "curl * | sh": "deny",
        "curl * | bash": "deny",
        "wget * | sh": "deny",
        "wget * | bash": "deny",
        "sh <(curl *": "deny",
        "bash <(curl *": "deny",
        "diskutil *": "deny",
        "mkfs*": "deny",
        "dd if=* of=/dev/*": "deny",
        "shutdown*": "deny",
        "reboot*": "deny",
        "killall -9 *": "deny",
        "chmod -R 777 *": "deny",
        "launchctl unload *": "deny",
        "launchctl remove *": "deny",
        "* && sudo *": "deny",
        "*; sudo *": "deny",
        "* | sudo *": "deny",
        "* && rm -rf /": "deny",
        "*; rm -rf /": "deny",
        "* && rm -rf ~": "deny",
        "*; rm -rf ~": "deny",
        "* && git push --force*": "deny",
        "*; git push --force*": "deny",
        "* && curl * | sh": "deny",
        "*; curl * | sh": "deny",
        "* && curl * | bash": "deny",
        "*; curl * | bash": "deny",
        "* && wget * | sh": "deny",
        "*; wget * | sh": "deny"
      },
      "read": "allow",
      "edit": "allow",
      "glob": "allow",
      "grep": "allow",
      "list": "allow",
      "webfetch": "allow",
      "websearch": "allow"
    }
    """#

    private static let readonlyPermissionJSON = #"""
    {
      "bash": "deny",
      "edit": "deny",
      "task": "deny",
      "todowrite": "deny",
      "lsp": "deny",
      "read": "allow",
      "glob": "allow",
      "grep": "allow",
      "list": "allow",
      "webfetch": "allow",
      "websearch": "allow"
    }
    """#

    // MARK: - Lifecycle

    /// Spawn the agent and complete the ACP handshake. Idempotent.
    func start() async throws {
        guard process == nil else { return }
        guard let launcher = Self.resolveLauncher(for: engine) else {
            switch engine {
            case .opencode:
                throw HermesError.codingAgentUnavailable(
                    "opencode binary not found. Build the fork, install it on PATH, or set ALFRED_OPENCODE_BIN.")
            case .primeAgent:
                throw HermesError.codingAgentUnavailable(
                    "prime-agent not found. Install it globally: npm install -g <prime-agent release tarball>.")
            case .freebuff:
                throw HermesError.codingAgentUnavailable(
                    "freebuff not found. Install it on PATH, or set ALFRED_FREEBUFF_BIN.")
            case .hermes:
                throw HermesError.binaryNotFound
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher.binary)
        proc.arguments = launcher.arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Hermes picks its model and provider from its own config and
        // credential pool (~/.hermes), so Alfred does not inject keys. The
        // opencode engine gets its credentials, posture config and journal
        // path through env (OPENCODE_AUTH_CONTENT / OPENCODE_CONFIG_CONTENT /
        // ALFRED_JOURNAL — see the opencode helpers). Either way the
        // subprocess inherits this process's environment — except PATH: a GUI
        // app launched by Finder or launchd inherits a minimal PATH
        // (/usr/bin:/bin) that lacks Homebrew, and the agents need their
        // tooling to even boot. Prepend the usual bins.
        proc.environment = childEnvironment()

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // stdout: protocol frames.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }

        // stderr: logs. Drained so the pipe buffer can't fill and wedge the
        // agent, but never parsed as protocol.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8) else { return }
            if line.contains("ERROR") || line.contains("Traceback") || line.contains("CRITICAL") {
                NSLog("[hermes] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { await self?.handleTermination(p.terminationStatus, processID: p.processIdentifier) }
        }

        do {
            try proc.run()
        } catch {
            throw HermesError.launchFailed(error.localizedDescription)
        }

        process = proc
        stdinPipe = inPipe

        // The ACP handshake is atomic: if initialize or session/new throws, the
        // process is already spawned but sessionID is still nil. Left alone that
        // is a half-started session — start() guards on `process`, so every later
        // prompt would no-op past it and fail with "no active session" until the
        // app restarts. Tear down on any handshake failure so the next start()
        // is a clean spawn.
        do {
            // 1. initialize — advertise no filesystem capability; Alfred reaches
            //    the Mac through its own MCP tools (Phase 2), not through ACP's
            //    fs hooks.
            _ = try await request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
                "clientInfo": ["name": "alfred", "version": Self.appVersion],
            ])

            // 2. session/new, injecting Alfred's macOS tools for this session
            //    only, plus any external capability bridges declared in
            //    ~/.alfred/agent-servers.json.
            //
            // Per-session registration rather than `hermes mcp add`: it leaves
            // ~/.hermes untouched, keeps the bar self-contained, and means a
            // Hermes run started from anywhere else doesn't inherit control of
            // this Mac.
            let session = try await request("session/new", [
                "cwd": workingDirectory,
                "mcpServers": Self.sessionMCPServers(),
            ])
            guard let sid = session["sessionId"] as? String else {
                throw HermesError.protocolError("session/new returned no sessionId")
            }
            sessionID = sid
        } catch {
            NSLog("[hermes] session handshake failed — tearing down: %@", error.localizedDescription)
            shutdown()
            throw error
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// The `McpServerStdio` entry describing Alfred's own tool server, or nil if
    /// the shim isn't in the bundle (e.g. running the bare SwiftPM binary rather
    /// than the assembled .app).
    ///
    /// ⚠️ Registration silently no-ops unless the optional `mcp` SDK is present in
    /// Hermes' venv. Without it, `tools.mcp_tool` logs "mcp package not installed"
    /// at DEBUG (invisible at default INFO) while the adapter still reports
    /// "refreshed tool surface after ACP MCP registration" — which reads like
    /// success. The symptom is the model ignoring these tools and improvising.
    ///
    ///     ~/.hermes/hermes-agent/venv/bin/python -m pip install "mcp==1.26.0"
    ///
    /// Re-check after any `hermes update`; it is not a core dependency, so it can
    /// vanish and take Alfred's macOS tools with it. Verify without spending model
    /// quota using scratchpad/mcp_register_probe.py.
    private static var alfredMCPServer: [String: Any]? {
        guard let shim = Bundle.main.url(forAuxiliaryExecutable: "alfred-mcp")?.path
                ?? Bundle.main.executableURL?
                    .deletingLastPathComponent()
                    .appendingPathComponent("alfred-mcp").path,
              FileManager.default.isExecutableFile(atPath: shim)
        else {
            NSLog("[hermes] alfred-mcp not found in bundle — macOS tools unavailable this session")
            return nil
        }
        return ["name": "alfred", "command": shim, "args": [], "env": []]
    }

    /// Every MCP server handed to Hermes for the session: Alfred's own macOS
    /// tools first, then whatever `~/.alfred/agent-servers.json` declares
    /// (external capability bridges like odysseus, omp, openswarm).
    ///
    /// Web search is deliberately NOT injected as an MCP server: the keyless
    /// Hound package (@houndmcp/hound-mcp-pi) stopped shipping a `bin` and now
    /// fails every spawn with "npm error could not determine executable to
    /// run", stalling session start with connection retries. Web instead rides
    /// Hermes' native backend — ddgs (DuckDuckGo, no key) is enabled in the
    /// config both model modes write, so web_search is available with no extra
    /// process.
    private static func sessionMCPServers() -> [[String: Any]] {
        var servers: [[String: Any]] = []
        if let alfred = alfredMCPServer { servers.append(alfred) }
        servers.append(contentsOf: externalMCPServers())
        return servers
    }

    /// Load `~/.alfred/agent-servers.json` — the ACP `McpServerStdio` list:
    ///
    ///     { "servers": [
    ///         { "name": "graphiti",
    ///           "command": "node",
    ///           "args": ["/path/to/mcp-server/index.js"],
    ///           "env": [{"name": "KEY", "value": "val"}] }
    ///     ] }
    ///
    /// `env` may be omitted or empty. A missing or malformed file is not an
    /// error — the session just runs without external servers.
    private static func externalMCPServers() -> [[String: Any]] {
        let path = "\(NSHomeDirectory())/.alfred/agent-servers.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = json["servers"] as? [[String: Any]]
        else { return [] }
        return servers.compactMap { server in
            guard let name = server["name"] as? String, !name.isEmpty,
                  let command = server["command"] as? String, !command.isEmpty
            else { return nil }
            var out: [String: Any] = ["name": name, "command": command]
            out["args"] = server["args"] as? [String] ?? []
            out["env"] = server["env"] as? [[String: Any]] ?? []
            return out
        }
    }

    /// Terminate the agent and end any running turn's stream. Safe to call repeatedly.
    func shutdown() {
        eventSink?.finish()
        eventSink = nil
        teardownProcess()
    }

    /// Kill the subprocess and drop session state *without* touching the running
    /// turn's stream. Used when a turn is about to retry against a fresh session
    /// (watchdog timeout, lost session): the caller keeps streaming into the same
    /// continuation, so the retried answer still reaches the UI.
    private func teardownProcess() {
        for (_, cont) in pending { cont.resume(throwing: HermesError.agentExited(0)) }
        pending.removeAll()
        stdinPipe?.fileHandleForWriting.closeFile()
        // A paused process ignores SIGTERM until it's continued — un-freeze it
        // first so the teardown actually lands.
        if isSuspended, let process, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGCONT)
            isSuspended = false
        }
        // Clear `process` before terminating so the termination handler sees a
        // mismatch and skips (a rebuild's stale handler must not clear the fresh
        // session). Terminate via the captured reference.
        let oldProcess = process
        process = nil
        stdinPipe = nil
        sessionID = nil
        readBuffer.removeAll()
        oldProcess?.terminate()
    }

    /// Drop the conversation and start a clean one.
    ///
    /// Tears the process down rather than reusing the session: Hermes keeps
    /// per-session context server-side, so "clear" has to reach that too or the
    /// old thread keeps colouring replies.
    func restart() async {
        shutdown()
        try? await start()
    }

    /// The session id to prompt with, spawning the agent if it isn't running or
    /// rebuilding if the running process has no session (a failed handshake).
    /// Throws only when the agent genuinely can't be started.
    private func activeSessionID() async throws -> String {
        if let sid = sessionID, process != nil { return sid }
        return try await rebuildSession()
    }

    /// Tear down the current process (without ending the running turn's stream)
    /// and spawn a fresh session, returning its id.
    private func rebuildSession() async throws -> String {
        teardownProcess()
        try await start()
        guard let sid = sessionID else {
            throw HermesError.protocolError("no active session")
        }
        return sid
    }

    /// True when a protocol error means the session id Alfred holds is no longer
    /// valid on the agent's side — the recoverable "the session went away"
    /// class, distinct from prompt-level failures (permission, tool errors).
    ///
    /// Hermes phrases this variously ("no active session", "Session c8f… is no
    /// longer active", "session does not exist", …) and can surface it in
    /// either the error `message` or the richer `data.details` — match the
    /// family, not one spelling.
    static func sessionLost(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("no active session")
            || m.contains("session not found")
            || m.contains("no such session")
            || m.contains("invalid session")
            || m.contains("session is not active")
            || m.contains("no longer active")
            || m.contains("does not exist")
            || m.contains("session inactive")
    }

    private func handleTermination(_ status: Int32, processID: Int32) {
        // Only the *current* process's death ends the turn. A rebuild tears the
        // old process down while a fresh one is spawning; the stale handler must
        // not clear the new session or finish its stream.
        guard process?.processIdentifier == processID else { return }
        eventSink?.yield(.failed(HermesError.agentExited(status).localizedDescription))
        eventSink?.finish()
        eventSink = nil
        for (_, cont) in pending { cont.resume(throwing: HermesError.agentExited(status)) }
        pending.removeAll()
        process = nil
        sessionID = nil
    }

    // MARK: - Prompting

    /// Send a prompt and stream the turn.
    ///
    /// The stream finishes on `.finished` or `.failed`; the caller does not need
    /// to inspect the `session/prompt` result separately.
    ///
    /// `capture` controls whether this exchange is logged for fine-tuning.
    /// True for real user turns (bar queries, iOS relay messages); false for
    /// internal system turns (memory reflection, mail triage, email-rewrite)
    /// that would pollute the training set with non-user content.
    func prompt(_ text: String, attachment: FileAttachment? = nil, capture: Bool = true) -> AsyncStream<HermesEvent> {
        AsyncStream { continuation in
            Task {
                await self.runTurn(text, attachment: attachment, into: continuation, capture: capture)
            }
        }
    }

    private func runTurn(_ text: String, attachment: FileAttachment? = nil, into continuation: AsyncStream<HermesEvent>.Continuation, capture: Bool = true) async {
        isTurnActive = true
        defer { isTurnActive = false }
        // Ensure a live session before prompting. Rebuilds if the agent isn't
        // running or a previous handshake left no session behind — a bare guard
        // failure here would otherwise surface to the user as a permanent
        // "no active session" until the app restarts.
        let sid: String
        do {
            sid = try await activeSessionID()
        } catch {
            continuation.yield(.failed(error.localizedDescription))
            continuation.finish()
            return
        }

        eventSink = continuation
        turnTextBuffer = ""

        // Intercept: every processed user request lands in the unified memory
        // graph. The local extractor (alfred-coder, on-device) pulls people,
        // organizations and communication preferences out of the text and
        // writes each as an entity/relation frame straight into the unified
        // layer — the on-device replacement for the decommissioned
        // agentmemory engine. Best-effort; never blocks the turn.
        UnifiedMemoryLayer.shared.observeTurn(text, source: "user")
        // …and the writing style profile folds this message into the learned
        // voice. Cheap (pure counting, no model calls), so it runs inline.
        WritingStyleService.shared.saveProfileFromQuery(text)

        var blocks: [[String: Any]] = [["type": "text", "text": await Self.groundedPrompt(text)]]
        if let attachment {
            switch attachment {
            case .image(let image):
                blocks.append(["type": "image", "data": image.base64, "mimeType": image.mimeType])
                // The model only sees the picture if it's told why it's there.
                blocks.append(["type": "text", "text":
                    "The user attached an image to this request. "
                    + "If it shows an event, meeting, invitation or appointment, extract the details and add it to their calendar (calendar_add)."])
            case .text(let name, let contents):
                // Local text files ride as plain text; cap length so a huge file
                // can't blow the provider's context window.
                let body = contents.count > 60_000 ? String(contents.prefix(60_000)) + "\n…[truncated]" : contents
                blocks.append(["type": "text", "text":
                    "The user attached the file “\(name)”. Its contents are below; use them to answer the request.\n\n---\n\(body)\n---"])
            }
        }
        do {
            // Prompt with a turn deadline. On timeout, tear down and rebuild
            // the agent (fresh process, fresh connection pools) and retry the
            // same prompt once — the common hiatus causes (wedged keepalive
            // connection, Ollama load stall) clear with a restart.
            let result: [String: Any]
            do {
                result = try await request("session/prompt", [
                    "sessionId": sid,
                    "prompt": blocks,
                ], timeout: turnDeadline)
            } catch HermesError.turnTimedOut {
                NSLog("[hermes] turn watchdog: no response in \(Int(turnDeadline))s — restarting session and retrying")
                let freshSID = try await rebuildSession()
                result = try await request("session/prompt", [
                    "sessionId": freshSID,
                    "prompt": blocks,
                ], timeout: turnDeadline)
            } catch let HermesError.protocolError(message) where Self.sessionLost(message) {
                // Hermes dropped or expired the session server-side, so the
                // prompt came back "no active session". Rebuild and retry the
                // same prompt once instead of handing the user the raw error.
                NSLog("[hermes] session lost (\"%@\") — rebuilding and retrying", message)
                let freshSID = try await rebuildSession()
                result = try await request("session/prompt", [
                    "sessionId": freshSID,
                    "prompt": blocks,
                ], timeout: turnDeadline)
            }
            let stop = result["stopReason"] as? String ?? "end_turn"
            continuation.yield(.finished(stopReason: stop))
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }

        // Intercept: the reply Alfred actually produced goes back into the
        // graph, so the connection matrix is built from both sides of the
        // conversation — user requests in, Alfred replies out. The same local
        // extraction runs on the reply, for facts Alfred itself surfaced.
        let reply = turnTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty {
            UnifiedMemoryLayer.shared.observeTurn(reply, source: "alfred")

            // Intercept: log this exchange for the fine-tuning loop. The new
            // message arriving now is a follow-up to the previous one — if it
            // isn't a rejection, that earlier reply was implicitly accepted.
            if capture {
                ConversationStore.shared.inferAcceptance(followingUserMessage: text)
                ConversationStore.shared.addCapture(
                    userMessage: text,
                    assistantResponse: reply,
                    timestamp: Date().timeIntervalSince1970)
            }
        }

        eventSink = nil
        continuation.finish()
    }

    /// Prepend the most relevant vault, personal and graph memories to every
    /// prompt, so each turn starts knowing what Alfred already knows about the
    /// subject. The learned writing style rides along as its own bracketed
    /// block, so replies match the user's register rather than the model's
    /// default voice. No matches → the prompt goes through untouched.
    private static func groundedPrompt(_ text: String) async -> String {
        // The unified memory graph: entities, vault notes, conversations and
        // screen observations ranked by relevance to this request. One call,
        // one source of truth — the replacement for the old vault + personal
        // + graph three-way grounding.
        let memoryContext = UnifiedMemoryLayer.shared.groundingText(for: text, limit: 6)
        var context = ""
        if !memoryContext.isEmpty {
            context = "[memory context: \(memoryContext)]"
        }
        let styleLine = WritingStyleService.shared.currentProfile.toPromptInjection()
        if !styleLine.isEmpty {
            context += context.isEmpty ? "" : "\n\n"
            context += "[writing style: \(styleLine)]"
        }
        let behaviorLine = ActivityObserver.shared.currentProfile().toPromptInjection()
        if !behaviorLine.isEmpty {
            context += context.isEmpty ? "" : "\n\n"
            context += "[routine: \(behaviorLine)]"
        }
        let peopleLine = UnifiedMemoryLayer.shared.getRelationshipSummary()
        if !peopleLine.isEmpty {
            context += context.isEmpty ? "" : "\n\n"
            context += "[people: \(peopleLine)]"
        }
        let habitLine = Self.habitInjectionLine()
        if !habitLine.isEmpty {
            context += context.isEmpty ? "" : "\n\n"
            context += "[habits: \(habitLine)]"
        }
        guard !context.isEmpty else { return text }
        return "\(context)\n\n\(text)"
    }

    /// One proactive sentence from the learned routine: what the user is
    /// typically doing around this hour and what usually follows. Empty until
    /// the behavior profile has signal.
    private static func habitInjectionLine() -> String {
        let svc = HabitPredictionService.shared
        let now = Date()
        guard let (bundle, _) = svc.predictNextApp(at: now),
              let next = svc.predictNextAction(currentApp: bundle, at: now)
        else { return "" }
        return "The user is typically in \(BehaviorProfile.friendlyName(for: bundle)) now; \(next)"
    }

    /// Interrupt the running turn. Wired to Esc in the bar.
    ///
    /// Hermes and prime-agent implement `session/cancel`. Opencode's ACP does
    /// not, so for the coding engine the subprocess is torn down — the next
    /// prompt respawns it fresh (start() is re-entered at the top of every
    /// turn), and the turn ends with a "stopped" failure that the bar renders
    /// as an interruption.
    func cancel() async {
        guard let sid = sessionID else { return }
        if engine == .opencode {
            shutdown()
            return
        }
        notify("session/cancel", ["sessionId": sid])
    }

    /// Whether the agent subprocess is up (spawned and not torn down). Remote
    /// code sessions check this before reporting "paused" — a suspend before
    /// spawn is a no-op and must not claim a state it can't hold.
    func isProcessRunning() -> Bool {
        process?.isRunning ?? false
    }

    // MARK: - Pause / resume (SIGSTOP / SIGCONT)

    /// Freeze the agent process so it stops consuming CPU/RAM without losing
    /// its state. Used by the remote code manager's pause: the subprocess
    /// (and its model context) stays alive, generation simply halts. The turn
    /// watchdog keeps re-arming while suspended, so a long pause never trips
    /// the deadline.
    func suspend() {
        guard let process, process.isRunning, !isSuspended else { return }
        isSuspended = true
        Darwin.kill(process.processIdentifier, SIGSTOP)
        NSLog("[hermes] session suspended (SIGSTOP)")
    }

    /// Unfreeze a paused process. Idempotent; resuming an already-running
    /// session is a no-op.
    func resume() {
        guard let process, process.isRunning, isSuspended else { return }
        Darwin.kill(process.processIdentifier, SIGCONT)
        isSuspended = false
        NSLog("[hermes] session resumed (SIGCONT)")
    }

    // MARK: - JSON-RPC plumbing

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        nextRequestID += 1
        let id = nextRequestID
        let frame: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try write(frame)
            } catch {
                pending[id] = nil
                cont.resume(throwing: error)
            }
            guard let timeout else { return }
            // Hermes can wedge on a prompt (upstream Ollama/MCP stalls) without
            // exiting or answering. Bound the wait so the turn never hangs the
            // bar forever; the caller restarts and retries on this error. While
            // the process is paused (SIGSTOP), re-arm instead of firing — a
            // paused turn is suspended, not stuck.
            func armWatchdog() {
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let cont = self.pending.removeValue(forKey: id) else { return }
                    if self.isSuspended {
                        self.pending[id] = cont
                        armWatchdog()
                        return
                    }
                    cont.resume(throwing: HermesError.turnTimedOut)
                }
            }
            armWatchdog()
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        try? write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func respond(id: Any, result: [String: Any]) {
        try? write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ frame: [String: Any]) throws {
        guard let handle = stdinPipe?.fileHandleForWriting else {
            throw HermesError.protocolError("agent stdin closed")
        }
        var data = try JSONSerialization.data(withJSONObject: frame)
        data.append(0x0A)  // newline-delimited
        try handle.write(contentsOf: data)
    }

    // MARK: - Reading

    /// Split the stdout byte stream into newline-delimited JSON frames.
    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<nl]
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handle(frame: obj)
        }
    }

    private func handle(frame: [String: Any]) {
        let method = frame["method"] as? String

        // Server → client request: must be answered or the turn deadlocks.
        if let method, frame["id"] != nil {
            handleAgentRequest(method: method, frame: frame)
            return
        }

        // Notification.
        if let method {
            if method == "session/update",
               let params = frame["params"] as? [String: Any],
               let update = params["update"] as? [String: Any] {
                handle(update: update)
            }
            return
        }

        // Response to one of ours.
        guard let id = frame["id"] as? Int, let cont = pending.removeValue(forKey: id) else { return }
        if let error = frame["error"] as? [String: Any] {
            cont.resume(throwing: Self.decode(error: error))
        } else {
            cont.resume(returning: frame["result"] as? [String: Any] ?? [:])
        }
    }

    /// Turn a JSON-RPC error into something worth showing a person.
    private static func decode(error: [String: Any]) -> HermesError {
        let detail = (error["data"] as? [String: Any])?["details"] as? String
        let message = error["message"] as? String ?? "unknown error"
        guard let detail else { return .protocolError(message) }
        // Cold start: no provider picked yet. Not a failure — a setup prompt.
        if detail.contains("No LLM provider configured") {
            return .notConfigured("Alfred needs an AI provider. Run `hermes model` in Terminal to pick one.")
        }
        return .protocolError(detail)
    }

    private func handleAgentRequest(method: String, frame: [String: Any]) {
        guard let id = frame["id"] else { return }

        guard method.hasSuffix("request_permission") else {
            // Unknown client method — answer so the agent isn't left blocking.
            respond(id: id, result: [:])
            return
        }

        let params = frame["params"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []

        guard autoApprovePermissions,
              let chosen = Self.allowOption(from: options),
              let optionID = chosen["optionId"] as? String else {
            respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
            return
        }
        respond(id: id, result: ["outcome": ["outcome": "selected", "optionId": optionID]])
    }

    /// Pick the permissive option, preferring an explicit allow over position.
    private static func allowOption(from options: [[String: Any]]) -> [String: Any]? {
        func mentionsAllow(_ o: [String: Any]) -> Bool {
            let kind = (o["kind"] as? String ?? "").lowercased()
            let id = (o["optionId"] as? String ?? "").lowercased()
            return kind.contains("allow") || id.contains("allow")
        }
        return options.first(where: mentionsAllow) ?? options.first
    }

    // MARK: - Update fan-out

    private func handle(update: [String: Any]) {
        guard let kind = update["sessionUpdate"] as? String else { return }

        switch kind {
        case "agent_message_chunk":
            if let t = Self.text(in: update) {
                turnTextBuffer += t
                eventSink?.yield(.text(t))
            }

        case "agent_thought_chunk":
            if let t = Self.text(in: update) { eventSink?.yield(.thought(t)) }

        case "tool_call":
            guard let id = update["toolCallId"] as? String else { return }
            eventSink?.yield(.toolStarted(
                id: id,
                title: update["title"] as? String ?? "Working…",
                kind: update["kind"] as? String))

        case "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            eventSink?.yield(.toolProgress(
                id: id,
                status: update["status"] as? String,
                title: update["title"] as? String))

        case "usage_update":
            let used = update["used"] as? Int ?? 0
            let size = update["size"] as? Int ?? 0
            eventSink?.yield(.usage(used: used, size: size))

        default:
            // plan / available_commands_update / current_mode_update /
            // config_option_update / session_info_update — not surfaced in v1.
            break
        }
    }

    /// Content blocks are `{type, text}`; non-text blocks (image, audio) have no
    /// text and are skipped rather than rendered as an empty string.
    private static func text(in update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              let text = content["text"] as? String,
              !text.isEmpty else { return nil }
        return text
    }
}
