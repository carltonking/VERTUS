//
//  ProviderKeyRing.swift
//  AlfredMacApp
//
//  The provider key ring behind Settings' "API keys" section, and the
//  cloud/local model mode. Ported from the menu-bar app's
//  Alfred/App/ProviderKeyRing.swift so both surfaces share the same
//  `~/.alfred/gemini-keys.json` ring file and the same `alfred.modelMode`
//  UserDefaults key.
//
//  Scope note: this copy reads and edits the ring file only. The hermes-config
//  sync (fallback chain / local-mode config writes) stays the menu-bar app's
//  job — the companion's edits are picked up by the ring on the menu-bar side
//  when it next loads.
//

import Foundation

/// An LLM provider Alfred can hold credentials for. Same rawValues as the
/// menu-bar app's registry.
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
}

/// Which model world the assistant runs in — same rawValues and UserDefaults
/// key (`alfred.modelMode`) as the menu-bar app, so the choice is shared.
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

/// One provider API key, same Codable shape as the menu-bar app's ring file.
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

/// The provider key ring behind the companion's Settings section.
final class ProviderKeyRing: ObservableObject {
    static let shared = ProviderKeyRing()

    @Published private(set) var keys: [ProviderKey] = []
    @Published private(set) var activeKeyID: UUID?

    private static let storeURL = "\(NSHomeDirectory())/.alfred/gemini-keys.json"

    private init() { load() }

    // MARK: - Queries

    var activeKey: ProviderKey? {
        keys.first { $0.id == activeKeyID }
    }

    /// Distinct providers present in the ring, in ring order.
    var providers: [LLMProvider] {
        var seen: Set<LLMProvider> = []
        return keys.compactMap { key in
            guard seen.insert(key.provider).inserted else { return nil }
            return key.provider
        }
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
        return entry
    }

    func remove(id: UUID) {
        keys.removeAll { $0.id == id }
        if activeKeyID == id {
            activeKeyID = keys.first?.id
        }
        save()
    }

    func setActive(id: UUID) {
        guard keys.contains(where: { $0.id == id }) else { return }
        activeKeyID = id
        save()
    }

    // MARK: - Model mode

    /// The UserDefaults key for the persisted cloud/local choice — shared with
    /// the menu-bar app.
    static let modelModeKey = "alfred.modelMode"

    /// The saved model mode; cloud is the default.
    static func persistedModelMode() -> ModelMode {
        let raw = UserDefaults.standard.string(forKey: modelModeKey)
        return raw.flatMap(ModelMode.init(rawValue:)) ?? .cloud
    }

    /// Persist the choice. The menu-bar app applies it to Hermes' config when
    /// it runs its own applyModelMode; the companion just records the intent.
    static func persistModelMode(_ mode: ModelMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modelModeKey)
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
