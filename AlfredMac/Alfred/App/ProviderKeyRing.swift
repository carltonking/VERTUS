import Foundation

extension Notification.Name {
    /// Posted when the *active* key was removed — the agent must respawn on
    /// the next key so removed providers stop being used immediately.
    static let alfredActiveKeyRemoved = Notification.Name("alfred.activeKeyRemoved")
}

/// An LLM provider Alfred can hold credentials for, mirroring Hermes'
/// ProviderConfig registry (see hermes_cli/auth.py). The rawValue is the
/// hermes provider id used in `fallback_providers` chain entries.
enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case gemini
    case zai
    case kimi
    case minimax
    case deepseek
    case stepfun
    case alibaba
    case nvidia
    case puter
    case groq
    case openrouter
    case freellmpool

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Google AI Studio"
        case .zai: return "Z.AI / GLM"
        case .kimi: return "Kimi / Moonshot"
        case .minimax: return "MiniMax"
        case .deepseek: return "DeepSeek"
        case .stepfun: return "StepFun"
        case .alibaba: return "Qwen Cloud"
        case .nvidia: return "NVIDIA NIM"
        case .puter: return "Puter (free Hermes)"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter"
        case .freellmpool: return "FreeLLM Pool"
        }
    }

    /// Env var hermes' provider registry reads for this provider's API key.
    var apiKeyEnvVar: String {
        switch self {
        case .gemini: return "GEMINI_API_KEY"        // also accepts GOOGLE_API_KEY
        case .zai: return "GLM_API_KEY"              // also accepts ZAI_API_KEY
        case .kimi: return "KIMI_API_KEY"           // hermes id "kimi-coding"
        case .minimax: return "MINIMAX_API_KEY"
        case .deepseek: return "DEEPSEEK_API_KEY"
        case .stepfun: return "STEPFUN_API_KEY"
        case .alibaba: return "DASHSCOPE_API_KEY"
        case .nvidia: return "NVIDIA_API_KEY"
        case .puter: return "PUTER_AUTH_TOKEN"
        case .groq: return "GROQ_API_KEY"
        case .openrouter: return "OPENROUTER_API_KEY"
        case .freellmpool: return "FREELLMPOOL_PROXY_KEY"   // keyless local pool; harmless if unset
        }
    }

    /// The provider id hermes recognizes in `fallback_providers` chain
    /// entries. Mostly the same as rawValue, diverging where hermes ids
    /// differ from ours.
    var hermesProviderID: String {
        switch self {
        case .kimi: return "kimi-coding"
        case .puter: return "puter"
        case .groq: return "custom"   // no native registry entry — routed via base_url
        default: return rawValue
        }
    }

    /// Groq and friends are OpenAI-compatible hosts Hermes reaches through
    /// the generic `custom` route: the chain entry carries the base_url and
    /// Hermes derives the key env var from the host label (api.groq.com →
    /// GROQ_API_KEY). Nil for native registry providers.
    var fallbackBaseURL: String? {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1"
        case .freellmpool: return "http://127.0.0.1:8210/v1"
        default: return nil
        }
    }

    /// Env var the chain entry names via ``key_env``. Native registry
    /// providers don't need one — hermes maps the provider id to its own
    /// key resolution. ``custom``-routed endpoints have no registry entry,
    /// so the main-agent fallback path must be told where the key lives.
    var fallbackKeyEnv: String? {
        switch self {
        case .groq: return "GROQ_API_KEY"
        default: return nil
        }
    }

    /// Model id used when this provider appears in the hermes fallback
    /// chain. Best-effort free-tier defaults; a wrong id only makes that one
    /// chain entry fail for one request — hermes falls through to the next
    /// entry, so this degrades gracefully.
    var defaultFreeModel: String {
        switch self {
        case .gemini: return "gemini-flash-lite-latest"
        case .zai: return "glm-4.5-flash"
        case .kimi: return "kimi-latest"
        case .minimax: return "MiniMax-M2"
        case .deepseek: return "deepseek-chat"
        case .stepfun: return "step-3.5-flash"
        case .alibaba: return "qwen-flash"
        case .nvidia: return "deepseek-ai/deepseek-v4-flash"
        case .puter: return "anthropic:anthropic/claude-opus-5"
        case .groq: return "llama-3.1-8b-instant"
        case .openrouter: return "google/gemini-2.5-flash:free"
        case .freellmpool: return "fast"   // freellmpool router: fastest surviving free route
        }
    }
}

// MARK: - Model mode (cloud vs local)

/// Which model world the assistant runs in. The settings window offers exactly
/// these two options — there is deliberately no per-model picker: cloud uses
/// the key ring + fallback chain, local uses the Ollama models on this Mac.
/// Persisted in UserDefaults (`alfred.modelMode`) so the choice survives a
/// relaunch.
enum ModelMode: String, CaseIterable, Identifiable, Sendable {
    case cloud
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloud: return "Cloud"
        case .local: return "Local"
        }
    }
}

/// The local models Alfred knows about — the ones the owner downloaded through
/// Ollama. Local mode always drives the session with `brain`: qwen3 4B, native
/// tool calling (real structured `tool_calls`), 32K context, ~2.5 GB — the
/// largest model that fits this 16 GB Mac alongside the OS and the 63+ MCP
/// tools without memory pressure. The 3.1B builds (alfred-brain, alfred-coder)
/// and qwen2.5:7b only narrate tool calls as JSON text or fumble hermes'
/// deferred-tool bridge, and qwen3:8b @ 32K blows past 16 GB RAM (thrash), so
/// neither is the default. The others stay listed in the provider entry Hermes
/// writes, so `hermes model` sees them.
enum LocalModels {
    /// Ollama's OpenAI-compatible endpoint, which is how Hermes' generic
    /// `custom` provider reaches the local server.
    static let ollamaBaseURL = "http://127.0.0.1:11434/v1"

    /// The default local brain: qwen3 4B (Q4 ~2.5 GB), native function calling.
    /// Pulled via `ollama pull`.
    static let brain = "qwen3:4b"
    static let coder = "alfred-coder:latest"
    static let vision = "alfred-vision:latest"
    static let small = "qwen2.5-coder:1.5b"

    /// Every model the user has, for the provider entry Hermes writes.
    static let all: [String] = [brain, coder, vision, small]

    /// How much context Hermes is allowed to build against the local model.
    /// qwen3's native window is far larger; 32,768 is Hermes' hard minimum
    /// and leaves room for the KV cache, so a small window wins here.
    static let contextLength = 32_768
}

/// Keeps the local brain resident in Ollama so the first turn of the day is as
/// fast as every other one. A tiny keep-alive completion runs at launch, then
/// refreshes just before the model's idle-eviction window, in local mode only.
enum LocalWarmup {
    /// Minutes the model stays loaded after a request (Ollama default is 5).
    static let keepAliveMinutes = 30

    /// One-token ping that forces model load (or refreshes the timer) without
    /// spending meaningful compute.
    static func ping() async {
        guard ProviderKeyRing.persistedModelMode() == .local else { return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": LocalModels.brain,
            "messages": [["role": "user", "content": "ping"]],
            "stream": false,
            "keep_alive": "\(keepAliveMinutes)m",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = (try? await URLSession.shared.data(for: request)) ?? (Data(), nil)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            NSLog("[model] warmup ping failed: HTTP %d %@",
                  http.statusCode,
                  String(data: data, encoding: .utf8) ?? "?")
        }
    }

    /// Refresh the keep-alive timer until the mode leaves local or the app
    /// stops. Errors are swallowed — the model loads lazily on first use
    /// anyway, so a failed prewarm only costs a few seconds once.
    static func runForever() async {
        while !Task.isCancelled {
            await ping()
            try? await Task.sleep(nanoseconds: UInt64((keepAliveMinutes - 5)) * 60_000_000_000)
        }
    }
}

/// One provider API key, as saved by the user in Settings. Keys live in
/// `~/.alfred/gemini-keys.json` (0600) so the plaintext never lands in
/// Alfred's logs, vault, or anywhere else readable.
struct ProviderKey: Codable, Identifiable, Equatable {
    var id = UUID()
    var provider: LLMProvider
    var label: String
    var key: String

    /// Show only the tail so the list stays glanceable without leaking keys.
    var redacted: String { "…" + key.suffix(4) }

    init(id: UUID = UUID(), provider: LLMProvider, label: String, key: String) {
        self.id = id
        self.provider = provider
        self.label = label
        self.key = key
    }

    /// Pre-ring keys (label + key only, no provider) decode as gemini.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        provider = try c.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? .gemini
        label = try c.decode(String.self, forKey: .label)
        key = try c.decode(String.self, forKey: .key)
    }
}

/// The provider key ring behind the "API keys" section of the popover.
///
/// The user can hold free-tier keys across several LLM companies to multiply
/// quota. One key is active; when a request fails with a quota marker (HTTP
/// 429 / "usage limit"), Alfred advances the ring and respawns the agent so
/// the next turn runs on a fresh key. Alfred also mirrors every stored
/// provider into hermes' own `fallback_providers` chain, so hermes quietly
/// moves on to the next provider mid-session when the primary hits a limit.
final class ProviderKeyRing: ObservableObject {
    static let shared = ProviderKeyRing()

    @Published private(set) var keys: [ProviderKey] = []
    @Published private(set) var activeKeyID: UUID?

    private static let storeURL = "\(NSHomeDirectory())/.alfred/gemini-keys.json"

    /// The venv python hermes uses; drives the fallback-chain sync.
    static let hermesPython = "\(NSHomeDirectory())/.hermes/hermes-agent/venv/bin/python3"

    private init() { load() }

    // MARK: - Queries

    var activeKey: ProviderKey? {
        keys.first { $0.id == activeKeyID }
    }

    var activeKeyIDString: String? {
        activeKeyID?.uuidString
    }

    /// Distinct providers present in the ring, in ring order.
    var providers: [LLMProvider] {
        var seen: Set<LLMProvider> = []
        return keys.compactMap { key in
            guard seen.insert(key.provider).inserted else { return nil }
            return key.provider
        }
    }

    /// First ring key for the given provider (the provider's effective key).
    func key(for provider: LLMProvider) -> ProviderKey? {
        keys.first { $0.provider == provider }
    }

    /// Ring-advance to the next key; returns the newly active key's label.
    /// No-op (returns the same key) when only one key is stored.
    @discardableResult
    func advance() -> ProviderKey? {
        guard keys.count > 1 else { return activeKey }
        guard let current = activeKeyID,
              let index = keys.firstIndex(where: { $0.id == current })
        else {
            activeKeyID = keys.first?.id
            save()
            return activeKey
        }
        let next = keys[(index + 1) % keys.count].id
        activeKeyID = next
        save()
        NSLog("[keys] rotated to \(activeKey?.label ?? "?")")
        return activeKey
    }

    // MARK: - Mutations

    @discardableResult
    func add(provider: LLMProvider, label: String? = nil, key: String) -> ProviderKey? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelText = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let count = keys.filter { $0.provider == provider }.count
        let entry = ProviderKey(
            provider: provider,
            label: labelText.isEmpty ? "\(provider.displayName) \(count + 1)" : labelText,
            key: trimmed
        )
        keys.append(entry)
        if activeKeyID == nil { activeKeyID = entry.id }
        save()
        Task.detached { ProviderKeyRing.shared.syncHermesFallbackChain() }
        return entry
    }

    func remove(id: UUID) {
        let wasActive = activeKeyID == id
        keys.removeAll { $0.id == id }
        if activeKeyID == id {
            activeKeyID = keys.first?.id
        }
        save()
        Task.detached { ProviderKeyRing.shared.syncHermesFallbackChain() }
        if wasActive {
            // The provider hermes is currently running on just vanished — tell
            // the app so it can respawn the agent on the next key.
            NotificationCenter.default.post(name: .alfredActiveKeyRemoved, object: nil)
        }
    }

    func setActive(id: UUID) {
        guard keys.contains(where: { $0.id == id }) else { return }
        activeKeyID = id
        save()
        Task.detached { ProviderKeyRing.shared.syncHermesFallbackChain() }
    }

    // MARK: - Hermes fallback chain

    /// Mirror the stored providers into hermes' `fallback_providers` chain so
    /// hermes automatically rotates to another free-tier provider when the
    /// primary hits a limit mid-request. Also points hermes' *primary*
    /// provider at the active key's provider — without that, the ring's active
    /// key is only cosmetic and hermes keeps sending every turn to whatever
    /// provider was last configured (e.g. a spent free tier → "HTTP 402"). The
    /// provider of the active key is excluded from the chain — hermes already
    /// pays it as primary, and chaining it back on top of itself is a no-op.
    /// Uses hermes' own config loader, so the YAML is always round-tripped
    /// safely.
    func syncHermesFallbackChain(contextLength: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        // In local mode the assistant runs on Ollama; the ring still powers the
        // coding agent, but a ring rotation must not flip the assistant's
        // config back to cloud. Re-assert the local config instead.
        if Self.persistedModelMode() == .local {
            applyLocalModelConfig(completion: completion)
            return
        }
        let python = Self.hermesPython
        guard FileManager.default.isExecutableFile(atPath: python) else {
            NSLog("[keys] hermes venv python missing at %@", python)
            completion?(false)
            return
        }
        let chainProviders = providers.filter { $0 != activeKey?.provider }
        var payload = chainProviders.map { provider -> [String: String] in
            var entry = ["provider": provider.hermesProviderID, "model": provider.defaultFreeModel]
            if let baseURL = provider.fallbackBaseURL {
                entry["base_url"] = baseURL
            }
            if let keyEnv = provider.fallbackKeyEnv {
                entry["key_env"] = keyEnv
            }
            return entry
        }
        // The local FreeLLM pool is always up and needs no key — keep it as the
        // final safety net after every keyed provider. Skipping a duplicate when
        // the user already ringed it keeps the chain tidy.
        if !payload.contains(where: { $0["provider"] == "freellmpool" }) {
            payload.append(["provider": "freellmpool", "model": "fast"])
        }
        let primary: [String: String]
        if let key = activeKey {
            primary = ["provider": key.provider.hermesProviderID,
                       "model": key.provider.defaultFreeModel,
                       "base_url": key.provider.fallbackBaseURL ?? ""]
        } else {
            primary = ["provider": "auto"]
        }
        guard let chainJSON = try? JSONSerialization.data(withJSONObject: payload),
              let primaryJSON = try? JSONSerialization.data(withJSONObject: primary)
        else {
            completion?(false)
            return
        }
        let script = """
        import json, sys
        from hermes_cli.config import load_config, save_config
        cfg = load_config()
        chain = json.loads(sys.argv[1])
        primary = json.loads(sys.argv[2])
        cfg["model"]["provider"] = primary["provider"]
        if "model" in primary:
            cfg["model"]["default"] = primary["model"]
        if "base_url" in primary:
            if primary["base_url"]:
                cfg["model"]["base_url"] = primary["base_url"]
            else:
                cfg["model"].pop("base_url", None)
        pri = primary["provider"].strip().lower()
        if pri and pri != "auto":
            chain = [e for e in chain if str(e.get("provider") or "").strip().lower() != pri]
        cfg["fallback_providers"] = chain
        # Keyless web (DuckDuckGo) — ships in both model modes so the agent
        # always spawns with web_search, without the broken npx Hound inject.
        cfg["web"] = {"backend": "ddgs", "search_backend": "ddgs"}
        if sys.argv[3]:
            cfg["model"]["context_length"] = int(sys.argv[3])
        save_config(cfg)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", script,
                          String(data: chainJSON, encoding: .utf8) ?? "[]",
                          String(data: primaryJSON, encoding: .utf8) ?? "{}",
                          contextLength.map(String.init) ?? ""]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            NSLog("[keys] fallback chain synced: %@", chainProviders.map { $0.displayName }.joined(separator: ", "))
            completion?(proc.terminationStatus == 0)
        } catch {
            NSLog("[keys] fallback sync failed: \(error.localizedDescription)")
            completion?(false)
        }
    }

    // MARK: - Model mode (cloud vs local)

    /// The UserDefaults key for the persisted cloud/local choice.
    static let modelModeKey = "alfred.modelMode"

    /// The saved model mode; cloud is the default (today's behavior).
    static func persistedModelMode() -> ModelMode {
        let raw = UserDefaults.standard.string(forKey: modelModeKey)
        return raw.flatMap(ModelMode.init(rawValue:)) ?? .cloud
    }

    /// Point Hermes at the selected model world. The caller restarts the
    /// session afterwards so the next turn picks it up.
    func applyModelMode(_ mode: ModelMode, completion: ((Bool) -> Void)? = nil) {
        switch mode {
        case .local:
            applyLocalModelConfig(completion: completion)
        case .cloud:
            // Existing behavior, with the generous context length restored
            // (local mode shrinks it to fit the on-device model).
            syncHermesFallbackChain(contextLength: 131_072, completion: completion)
        }
    }

    /// Write Hermes' config for local mode: primary provider is Ollama's
    /// OpenAI-compatible endpoint, the default model is alfred-brain, and the
    /// fallback chain is emptied so a quota blip can never hand a local-mode
    /// turn to the cloud. Uses hermes' own config loader, so the YAML is
    /// always round-tripped safely.
    private func applyLocalModelConfig(completion: ((Bool) -> Void)? = nil) {
        let python = Self.hermesPython
        guard FileManager.default.isExecutableFile(atPath: python) else {
            NSLog("[model] hermes venv python missing at %@", python)
            completion?(false)
            return
        }
        let modelsJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: LocalModels.all) {
            modelsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } else {
            modelsJSON = "[]"
        }
        let script = """
        import json, sys
        from hermes_cli.config import load_config, save_config
        cfg = load_config()
        cfg["model"]["provider"] = "custom"
        cfg["model"]["default"] = sys.argv[1]
        cfg["model"]["base_url"] = sys.argv[2]
        cfg["model"]["context_length"] = int(sys.argv[3])
        # The brain's native window exceeds 32K; this pins the per-request
        # context Hermes actually asks for.
        cfg["model"]["ollama_num_ctx"] = int(sys.argv[3])
        cfg["model"].setdefault("api_key", "")
        cfg["model"]["max_tokens"] = 2048
        cfg["fallback_providers"] = []
        # Keyless web (DuckDuckGo) for local mode too — no cloud key needed.
        cfg["web"] = {"backend": "ddgs", "search_backend": "ddgs"}
        cfg.setdefault("providers", {})["ollama-launch"] = {
            "name": "Ollama (local)",
            "api": sys.argv[2],
            "default_model": sys.argv[1],
            "models": json.loads(sys.argv[4]),
        }
        save_config(cfg)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", script,
                          LocalModels.brain,
                          LocalModels.ollamaBaseURL,
                          String(LocalModels.contextLength),
                          modelsJSON]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            NSLog("[model] hermes config → local (%@)", LocalModels.brain)
            completion?(proc.terminationStatus == 0)
        } catch {
            NSLog("[model] local config write failed: \(error.localizedDescription)")
            completion?(false)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = FileManager.default.contents(atPath: Self.storeURL),
              let decoded = try? JSONDecoder().decode(StoredRing.self, from: data)
        else { return }
        keys = decoded.keys
        // If the stored active key is gone or nil, promote the first key —
        // otherwise a ring full of keys with no active one would stay dead.
        if let active = decoded.activeKeyID, keys.contains(where: { $0.id == active }) {
            activeKeyID = active
        } else {
            activeKeyID = keys.first?.id
            if decoded.activeKeyID == nil && !keys.isEmpty { save() }
        }
    }

    private func save() {
        let payload = StoredRing(keys: keys, activeKeyID: activeKeyID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: Self.storeURL), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.storeURL
            )
        } catch {
            NSLog("[keys] failed to save key ring: \(error.localizedDescription)")
        }
    }
}

private struct StoredRing: Codable {
    var keys: [ProviderKey]
    var activeKeyID: UUID?
}
