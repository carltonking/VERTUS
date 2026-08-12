import Foundation

/// Estimated free-tier usage meter, one entry per stored API key.
///
/// No LLM vendor exposes a "quota remaining" endpoint, so the percentage is
/// always an *estimate*, built from three signals:
///   1. Request counts the app actually made today (measured).
///   2. hermes `usage_update` frames, when it reports a daily used/size pair.
///   3. Hard quota failures (HTTP 402/429 / "no usage left") → shown as 0%.
///
/// The per-provider daily budgets below are free-tier rough figures from
/// vendor docs; a wrong cap only shifts the estimate for that key. Percent
/// resets at midnight (local day key) because free tiers reset daily — except
/// vendors that cap weekly/monthly, which the 0% state covers until it clears.
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    struct Entry: Codable {
        var day: String
        var requests: Int
        var tokensHint: Int            // provider-reported daily used, if any
        var tokenDailyCap: Int         // provider budget estimate (0 = unknown)
        var quotaExhausted: Bool       // last call failed with a quota marker
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    /// Last hermes day (used, size) pair, most likely belonging to the ring's
    /// active provider at the time the frame arrived.
    @Published private(set) var hermesUsage: (used: Int, size: Int)?

    private static let storeURL = "\(NSHomeDirectory())/.alfred/usage.json"

    private init() { load() }

    // MARK: - Recording

    /// One request consumed quota on `provider`.
    func record(provider: LLMProvider) {
        guard let key = ProviderKeyRing.shared.key(for: provider) else { return }
        var entry = entryFor(key.id, provider: provider)
        entry.requests += 1
        entries[key.id] = entry
        save()
    }

    /// hermes reported its daily (used, size) — prefer those numbers for the
    /// provider that is active right now.
    func recordHermesUsage(used: Int, size: Int) {
        hermesUsage = (used, size)
        guard let provider = ProviderKeyRing.shared.activeKey?.provider,
              let key = ProviderKeyRing.shared.key(for: provider)
        else { return }
        var entry = entries[key.id] ?? entryFor(key.id, provider: provider)
        entry.tokensHint = used
        if size > 0 { entry.tokenDailyCap = size }
        entry.quotaExhausted = false
        entries[key.id] = entry
        save()
    }

    /// A turn failed with a quota/rate-limit marker → that key reads 0% until
    /// the day resets or the vendor window clears.
    func recordQuotaHit(message: String) {
        let provider = Self.providerFromMessage(message)
            ?? ProviderKeyRing.shared.activeKey?.provider
        guard let provider, let key = ProviderKeyRing.shared.key(for: provider) else { return }
        var entry = entries[key.id] ?? entryFor(key.id, provider: provider)
        entry.quotaExhausted = true
        entries[key.id] = entry
        save()
    }

    // MARK: - Estimates

    /// "~64%" / "0%" / "…" plus the color key. `isEstimate` is always true —
    /// no provider exposes real remaining quota; the text carries "· est".
    func usage(for key: ProviderKey) -> (percent: Int?, text: String, isEstimate: Bool) {
        let today = Self.dayKey(Date())
        var entry = entries[key.id] ?? entryFor(key.id, provider: key.provider)
        if entry.day != today {
            entry = Entry(day: today, requests: 0, tokensHint: 0,
                          tokenDailyCap: Self.dailyRequestBudget[key.provider] ?? 0,
                          quotaExhausted: false)
            entries[key.id] = entry
            save()
        }

        // Prefer hermes' own daily (used, size) when available for the active
        // provider; otherwise our request counter against the budget estimate.
        var used = entry.requests
        var cap = entry.tokenDailyCap > 0 ? entry.tokenDailyCap
                  : (Self.dailyRequestBudget[key.provider] ?? 0)
        if key.id == ProviderKeyRing.shared.activeKeyID,
           let hermes = hermesUsage, hermes.size > 0 {
            used = max(used, hermes.used)
            cap = hermes.size
        }

        guard cap > 0 else { return (nil, "…", true) }

        let exhausted = entry.quotaExhausted
        let fraction = exhausted ? 1.0 : min(1.0, Double(used) / Double(cap))
        let percentLeft = max(0, Int((1.0 - fraction) * 100))
        return (percentLeft, "~\(percentLeft)% · est", true)
    }

    /// Which provider a failure message names, if any (puter has the most
    /// distinctive wording: "no usage left" / "insufficient_funds").
    private static func providerFromMessage(_ message: String) -> LLMProvider? {
        let lower = message.lowercased()
        let markers: [(String, LLMProvider)] = [
            ("puter", .puter), ("no usage left", .puter), ("insufficient_funds", .puter),
            ("generativelanguage", .gemini), ("gemini", .gemini),
            ("glm", .zai), ("z.ai", .zai),
            ("moonshot", .kimi), ("kimi", .kimi),
            ("minimax", .minimax),
            ("groq", .groq),
        ]
        for (needle, provider) in markers where lower.contains(needle) { return provider }
        return nil
    }

    /// Free-tier daily request budgets, request/day. Estimates only.
    static let dailyRequestBudget: [LLMProvider: Int] = [
        .gemini: 1500,
        .zai: 600,
        .kimi: 500,
        .minimax: 400,
        .deepseek: 500,
        .stepfun: 500,
        .alibaba: 400,
        .nvidia: 1000,
        .puter: 800,
        .groq: 3500,
        .openrouter: 200,
    ]

    // MARK: - Persistence

    private func entryFor(_ keyID: UUID, provider: LLMProvider) -> Entry {
        entries[keyID] ?? Entry(day: Self.dayKey(Date()), requests: 0, tokensHint: 0,
                                tokenDailyCap: Self.dailyRequestBudget[provider] ?? 0,
                                quotaExhausted: false)
    }

    private static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: Self.storeURL),
              let decoded = try? JSONDecoder().decode([UUID: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: Self.storeURL), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: Self.storeURL)
        } catch {
            NSLog("[usage] save failed: \(error.localizedDescription)")
        }
    }
}