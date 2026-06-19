import Foundation

/// Phase 6 — self-learning.
/// Turns user feedback on Alfred's last output (accept / reject / edit) into durable
/// PREFERENCE RULES that are injected into future drafts and agent actions. No
/// fine-tuning: this is retrieval + an evolving profile, which improves with use and
/// stays cheap on a 16GB machine. (`style-export` still tees up an eventual LoRA.)
struct Learning {
    let store: Store
    let ollama: OllamaClient

    /// Inject this into prompts so Alfred actually applies what it has learned.
    static func preferencesBlock(_ store: Store) -> String {
        let prefs = (try? store.preferences()) ?? []
        guard !prefs.isEmpty else { return "" }
        return "\nLEARNED PREFERENCES (apply these):\n" + prefs.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// 👍 — the last output was good. Reinforce it as a positive style exemplar.
    func accept() throws -> String {
        guard let last = try store.lastOutput() else { return "nothing to accept yet" }
        if last.kind == "draft" {
            _ = try store.addStyleSample(ts: now(), source: "accepted", text: last.output)
            return "reinforced — added to your style exemplars"
        }
        return "noted (accept applies mainly to drafts)"
    }

    /// 👎 with a reason — derive concise preference rules from the complaint.
    func reject(reason: String) async throws -> [String] {
        guard let last = try store.lastOutput() else { return [] }
        let system = """
        The user disliked an output. From their complaint, extract 1–3 SHORT, GENERAL preference
        rules to guide future outputs (e.g. "keep emails under 4 sentences", "no emojis in work
        messages", "always sign off with 'Carlton'"). Output a JSON array of strings only.
        """
        let user = "REQUEST: \(last.intent)\n\nOUTPUT:\n\(last.output)\n\nCOMPLAINT: \(reason)"
        return try await deriveAndStore(system: system, user: user)
    }

    /// ✏️ — user supplied an edited version. Learn what changed.
    func edit(edited: String) async throws -> [String] {
        guard let last = try store.lastOutput() else { return [] }
        // The edited text is itself a gold style sample.
        if last.kind == "draft" { _ = try? store.addStyleSample(ts: now(), source: "edited", text: edited) }
        let system = """
        Compare the user's EDIT to the ORIGINAL and infer 1–3 SHORT, GENERAL preference rules that
        explain the change, so future outputs match the edit without being told again. Output a
        JSON array of strings only.
        """
        let user = "REQUEST: \(last.intent)\n\nORIGINAL:\n\(last.output)\n\nEDITED:\n\(edited)"
        return try await deriveAndStore(system: system, user: user)
    }

    private func deriveAndStore(system: String, user: String) async throws -> [String] {
        let raw = try await ollama.chatJSON(system: system, user: "\(user)\n\nRespond as JSON: {\"rules\": [\"...\"]}")
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let rules = (obj["rules"] as? [String]) ?? (obj.values.first as? [String]) ?? []
        var stored: [String] = []
        for r in rules {
            let rule = r.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rule.count >= 4, rule.count <= 160 else { continue }
            try store.addPreference(rule, ts: now())
            stored.append(rule)
        }
        return stored
    }
}
