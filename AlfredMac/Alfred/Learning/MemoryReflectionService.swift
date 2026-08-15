import Foundation
import AlfredCore

// MARK: - Reflection

/// Distills local observations + journal activity into vault concepts
/// (My Life/Projects, Goals, Topics, Key Elements) and structured personal
/// memories on a quiet schedule.
///
/// Where observation recording is heuristic and writes raw text, this pass
/// is the one place memory work actually spends model tokens: it feeds the
/// day's raw material to a disposable `hermes acp` subprocess and asks for a
/// strict JSON contract — structured facts only, never free-form prose. The
/// output is applied by Swift, not by the model, so the vault stays clean.
final class MemoryReflectionService {

    static let shared = MemoryReflectionService()

    private var timer: Timer?
    private var lastReflection: Date?
    private let dateKey = "alfred.lastReflection"

    private init() {
        if let stored = UserDefaults.standard.object(forKey: dateKey) as? Date {
            lastReflection = stored
        }
    }

    func start() {
        guard timer == nil else { return }
        // First pass 2 minutes after launch (lets a journal page exist), then
        // every 6 hours — reflective beats reactive.
        timer = Timer(fire: Date().addingTimeInterval(120), interval: 6 * 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.run() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        NSLog("[reflection] scheduled (first pass in 2m, then every 6h)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Pass

    /// One reflection pass. Never throws; a failed model call just means the
    /// pass is skipped until the next schedule slot.
    ///
    /// Runs through the shared chat session (HermesSession) rather than a
    /// fresh `hermes acp` subprocess: one long-lived agent boots once and
    /// stays warm, while spawning a second agent is slow and fragile. The
    /// pass is guarded against running mid-turn so it never hijacks the
    /// conversation the user is having.
    func run() async {
        let hermes: HermesSession? = await MainActor.run { AppDelegate.shared?.hermes }
        guard let hermes else {
            NSLog("[reflection] no session — skipping pass")
            return
        }
        guard await !hermes.isTurnActive else {
            NSLog("[reflection] user mid-turn — skipping pass")
            return
        }

        let store = MemoryStore.shared
        let personalStore = PersonalMemoryStore.shared
        let since = lastReflection ?? Date().addingTimeInterval(-24 * 3600)

        // Raw material: everything the store indexed, newest first, with the
        // window it covers.
        let raw = store.recent(limit: 40)
        let observations = personalStore.unprocessedObservations(limit: 60)
        guard !raw.isEmpty || !observations.isEmpty else {
            NSLog("[Hermes] vault empty — nothing to reflect on")
            return
        }

        let vaultMaterial = raw.prefix(25).map { note -> String in
            let date = Self.dateFormatter.string(from: note.date)
            let body = String(note.body.prefix(160))
            return "\(date) [\(note.category)] \(note.title)\n\(body)"
        }.joined(separator: "\n---\n")
        let personalMaterial = observations.prefix(40).map { observation -> String in
            let date = Self.dateFormatter.string(from: observation.observedAt)
            let app = observation.app.map { " app=\($0)" } ?? ""
            return "\(observation.id) \(date) [\(observation.source)\(app)] \(String(observation.text.prefix(260)))"
        }.joined(separator: "\n---\n")

        let prompt = """
        You are the quiet memory pass inside Alfred, a personal assistant. The user \
        never sees your answer — I apply it for them. So be concrete, not polite.

        Below is raw vault/journal material and local observations since \(Self.dateFormatter.string(from: since)). \
        Extract durable facts a human would want Alfred to remember.

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"facts":[{"category":"projects|goals|topics|keyelements","title":"short","body":"one-ish sentence, no quotes"}],"personal_memories":[{"kind":"person|communicationStyle|routine|classInfo|interest|passion|preference|project|goal|habit|lifeContext","title":"short stable name","summary":"one concrete sentence","keywords":["short"],"confidence":0.0,"importance":1,"source_observation_id":"id from OBSERVATIONS or empty","evidence_excerpt":"short supporting text"}],"preferences":[{"category":"preference|project_pattern|person|goal|learning|constraint","content":"one concise sentence","confidence":0.0}],"summary":"one line summarizing the window"}

        Rules:
        - category: projects = active build work; goals = ambitions, target habits; topics = concepts/tech the user is learning; keyelements = values/preferences, recurring patterns.
        - personal_memories should model the user: people, communication patterns, routines, interests, classes, passions, preferences, active projects, goals, habits, durable life context.
        - Only store high-signal observations that are likely to remain useful. Use low confidence for weak patterns; skip guesses about sensitive traits.
        - Skip ephemera: what day it is, trivially posts, UI noise.
        - 0-5 facts. 0-8 personal_memories. Title <=40 chars. Summaries one sentence.
        - confidence is 0.25 for a single weak signal, 0.5 for a plausible signal, 0.75+ only when repeated or explicit.
        - importance is 1-5.
        - summary: one plain sentence.

        VAULT:
        \(vaultMaterial)

        OBSERVATIONS:
        \(personalMaterial)
        """

        // Ask the live agent. The turn streams invisibly; only the text
        // matters. The reply also lands in Hermes' own session memory, which
        // is fine — it is a record of the reflection itself.
        var text = ""
        var failed = false
        // capture: false — this is a system pass, not a user exchange; it must
        // not feed the fine-tuning loop.
        for await event in await hermes.prompt(prompt, capture: false) {
            switch event {
            case .text(let chunk):
                text += chunk
            case .failed(let message):
                NSLog("[reflection] turn failed: %@", message)
                failed = true
            case .thought, .toolStarted, .toolProgress, .usage, .finished:
                break
            }
        }
        guard !failed, !text.isEmpty else {
            NSLog("[reflection] no output — skipping pass")
            return
        }

        // Models rarely return bare JSON. Tolerate prose, code fences and
        // wrapping text by hunting for the first balanced {...} object.
        let json = Self.extractJSONObject(from: text)
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("[hermes] reflection JSON unparsable — falling back to journal only")
            logFallback(text)
            persist()
            return
        }

        var applied = 0
        var appliedPersonal = 0

        // Durable facts → concept notes (append-only, never clobber).
        if let facts = obj["facts"] as? [[String: Any]] {
            for fact in facts {
                guard let category = fact["category"] as? String,
                      let title = fact["title"] as? String,
                      let body = fact["body"] as? String,
                      !title.isEmpty,
                      let concept = Self.concept(for: category) else { continue }
                if store.noteConcept(concept, title: title, body: body, append: true) != nil {
                    applied += 1
                } else {
                    NSLog("[hermes] concept write failed: %@/%@", category, title)
                }
            }
        }

        // A one-line window summary lands in the journal.
        if let summary = obj["summary"] as? String {
            store.logActivity(summary, source: "hermes-reflection", importance: 3)
            NSLog("[hermes] reflection summary: %@", summary)
        }

        // Durable learned preferences → MemPalaceManager (the confidence/decay
        // vault). The same quiet pass feeds both stores: facts and personal
        // memories are the graph, preferences are the long-lived "what I know
        // about the user" layer that grounds every future session.
        if let preferences = obj["preferences"] as? [[String: Any]] {
            for preference in preferences {
                guard let content = preference["content"] as? String,
                      !content.isEmpty else { continue }
                let category = (preference["category"] as? String)
                    .flatMap(MemoryCategory.init(rawValue:)) ?? .preference
                let confidence = preference["confidence"] as? Double ?? 0.5
                MemPalaceManager.shared.remember(content: content, category: category,
                                                 source: "reflection",
                                                 confidence: confidence)
            }
        }

        if let memories = obj["personal_memories"] as? [[String: Any]] {
            let observationsByID = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
            for memory in memories {
                guard let kindLabel = memory["kind"] as? String,
                      let kind = Self.personalKind(for: kindLabel),
                      let title = memory["title"] as? String,
                      let summary = memory["summary"] as? String,
                      !title.isEmpty, !summary.isEmpty else { continue }
                let keywords = memory["keywords"] as? [String] ?? []
                let confidence = memory["confidence"] as? Double ?? 0.4
                let importance = memory["importance"] as? Int ?? 2
                let sourceID = memory["source_observation_id"] as? String ?? ""
                let sourceObservation = observationsByID[sourceID]
                let evidenceExcerpt = (memory["evidence_excerpt"] as? String)
                    ?? sourceObservation?.text
                    ?? summary
                personalStore.upsert(PersonalMemoryCandidate(
                    kind: kind,
                    title: title,
                    summary: summary,
                    keywords: keywords,
                    confidence: confidence,
                    importance: importance,
                    evidenceSource: sourceObservation?.source ?? "hermes-reflection",
                    evidenceExcerpt: evidenceExcerpt,
                    observedAt: sourceObservation?.observedAt ?? Date(),
                    expiresAt: nil))
                appliedPersonal += 1
            }
        }

        personalStore.markObservationsProcessed(observations.map(\.id))
        persist()
        NSLog("[hermes] reflection done — %d facts, %d personal memories, %d notes indexed",
              applied, appliedPersonal, store.recent().count)
    }

    // MARK: Helpers

    private func persist() {
        lastReflection = Date()
        UserDefaults.standard.set(lastReflection, forKey: dateKey)
    }

    private func logFallback(_ text: String) {
        MemoryStore.shared.logActivity(text, source: "hermes-reflection", importance: 2)
    }

    /// Map the model's lowercase category labels onto vault folders.
    private static func concept(for label: String) -> Vault.Concept? {
        switch label {
        case "projects":    return .projects
        case "goals":       return .goals
        case "habits":      return .habits
        case "topics":      return .topics
        case "keyelements": return .keyElements
        default:            return nil
        }
    }

    private static func personalKind(for label: String) -> PersonalMemoryKind? {
        switch label {
        case "person": return .person
        case "communicationStyle": return .communicationStyle
        case "routine": return .routine
        case "classInfo": return .classInfo
        case "interest": return .interest
        case "passion": return .passion
        case "preference": return .preference
        case "project": return .project
        case "goal": return .goal
        case "habit": return .habit
        case "lifeContext": return .lifeContext
        default: return nil
        }
    }

    /// Pull the first balanced {...} object out of a model reply, even when
    /// it arrives wrapped in prose or markdown fences.
    private static func extractJSONObject(from raw: String) -> String {
        let chars = Array(raw)
        var depth = 0
        var inString = false
        var escaped = false
        var start = -1
        for (i, ch) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{":
                if start < 0 { start = i }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, start >= 0 {
                    return String(chars[start...i])
                }
            default:
                break
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
