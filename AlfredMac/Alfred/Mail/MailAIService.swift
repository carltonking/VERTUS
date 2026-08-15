//
//  MailAIService.swift
//  Alfred
//
//  The AI layer over the unified mail hub: classification, summaries, task
//  extraction, draft replies and natural-language search — every one routed
//  through the same long-lived `HermesSession` the bar uses, answered in a
//  single tool-free JSON turn (the pattern MailClassifier established for
//  triage).
//
//  Costs are real (each call spends model quota), so everything cheap is
//  cached: classification, summaries and task lists land in a `mail_ai_cache`
//  table beside the envelope cache and are served from there for 24 hours.
//  Drafts and search are never cached — they answer fresh questions.
//
//  Guard rails (inherited from MailClassifier):
//   * `isTurnActive` is checked before every model call. If the bar (or the
//     phone relay) is mid-response, each method degrades to nil/empty and
//     lets the next call pick the work up again — the mail copilot never cuts
//     across a conversation the owner is watching.
//   * Every prompt hard-bans tool use. The point is analysis, not action;
//     sending stays behind the explicit mail.send / mail.reply methods.
//

import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro, invisible to Swift; -1 tells SQLite to copy
// the bound string before the statement is finalized.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - AI results

/// How a message needs the owner's attention, from the model. `label` is the
/// wire value the phone maps to chips ("Needs reply", "Action item"). The
/// sweep fields (`importance`, `category`, `confidence`, `reason`) are optional
/// so older cached classifications still decode; the folder scan uses them to
/// rank what's worth surfacing.
struct MailClassification: Codable, Equatable, Sendable {
    let label: String
    let tone: String
    let summary: String
    var importance: Int?
    var category: String?
    var confidence: Double?
    var reason: String?
}

/// Bullet-point recap of a message (or its conversation) plus the tone to
/// read it in.
struct MailSummary: Codable, Equatable, Sendable {
    let bullets: [String]
    let tone: String
}

/// One action item extracted from a message.
struct MailTaskItem: Codable, Equatable, Sendable {
    let title: String
    let detail: String
}

/// A drafted reply — subject + body the owner can edit before sending.
struct MailDraft: Codable, Equatable, Sendable {
    let subject: String
    let body: String
}

/// The structured filter a natural-language query compiles into, plus the
/// one-line note shown above the results. `.empty` means "no structured
/// interpretation" — the caller falls back to plain LIKE search.
struct MailSearchIntent: Codable, Equatable, Sendable {
    let sender: String?
    let terms: [String]
    let unreadOnly: Bool
    let sinceDays: Int?
    let note: String

    static let empty = MailSearchIntent(
        sender: nil, terms: [], unreadOnly: false, sinceDays: nil, note: "")
}

// MARK: - Service

/// The AI copilot over MailManager. @MainActor like the managers it pairs
/// with; the slow parts (Hermes turns, Himalaya reads) are actor-hopped, so
/// awaiting a call never blocks the UI.
@MainActor
final class MailAIService {

    static let shared = MailAIService()

    /// The agent session to run the AI turns on. Set by AppDelegate at launch,
    /// exactly like MailWatcher.hermes.
    weak var hermes: HermesSession?

    /// How long cached analysis stays fresh before the model re-reads a message.
    static let cacheTTL: TimeInterval = 24 * 3600

    /// Hard cap on one model turn. A wedged session must not hold the gate open
    /// and stall every later copilot ask behind it — see `runPromptBounded`.
    static let turnTimeout: TimeInterval = 60

    nonisolated private static let databasePath = NSHomeDirectory() + "/.alfred/mail.db"
    nonisolated private static let cacheTable = "mail_ai_cache"

    /// Serializes the copilot's own model turns (see TurnGate). The single
    /// gate is shared by every method so classify + summarize + watcher turns
    /// queue instead of overlapping.
    private let turnGate = TurnGate()

    private init() {}

    // MARK: - Public API

    /// Classify one message (needs reply / action item / fyi). Cached.
    func classify(account: String, mailbox: String, uid: String) async -> MailClassification? {
        let key = Self.cacheKey(kind: "classify", account: account, mailbox: mailbox, uid: uid)
        if let cached: MailClassification = cached(key: key) { return cached }
        guard let parts = try? await readBody(account: account, mailbox: mailbox, uid: uid) else { return nil }

        let instruction = classificationInstruction
        guard let obj = await runJSON(instruction, text: parts.text),
              let label = obj["label"] as? String,
              let tone = obj["tone"] as? String
        else { return nil }
        let result = Self.classification(from: obj, label: label, tone: tone)
        store(result, key: key)
        return result
    }

    /// Cheap sweep classification from envelope fields only — no body read.
    /// Used by the folder scan so Junk and unread mail get judged without a
    /// Himalaya read per message. Cached under its own kind like the full
    /// classify, so the 24h TTL applies to the sweep too.
    func classifyEnvelope(account: String, mailbox: String, uid: String,
                          fromName: String, fromAddress: String,
                          subject: String, snippet: String) async -> MailClassification? {
        let key = Self.cacheKey(kind: "classify-env", account: account, mailbox: mailbox, uid: uid)
        if let cached: MailClassification = cached(key: key) { return cached }
        let envelope = """
        From: \(fromName.isEmpty ? fromAddress : "\(fromName) <\(fromAddress)>")
        Subject: \(subject)
        \(snippet.isEmpty ? "" : "Preview: \(snippet)")
        """
        guard let obj = await runJSON(classificationInstruction, text: envelope),
              let label = obj["label"] as? String,
              let tone = obj["tone"] as? String
        else { return nil }
        let result = Self.classification(from: obj, label: label, tone: tone)
        store(result, key: key)
        return result
    }

    /// The triage contract shared by the reader classify and the sweep. The
    /// sweep fields rank "worth interrupting for" — importance drives the
    /// scan's important/spam_miss lists; confidence orders them.
    private var classificationInstruction: String {
        """
        You triage one email. Respond with JSON only — no prose, no markdown fences, no tools.
        {"label": "needs_reply" | "action_item" | "fyi" | "low_priority", "tone": "short reading tone, e.g. Friendly, Urgent", "summary": "one short phrase (under 10 words) naming what the sender wants", "importance": 1-5, "category": "important" | "needs_action" | "fyi" | "spam_miss" | "newsletter" | "receipt" | "personal" | "work" | "academic", "confidence": 0.0-1.0, "reason": "one short phrase"}
        - needs_reply: the sender expects the owner to reply back.
        - action_item: the owner must do something (approve, sign, review, decide) but no reply is demanded.
        - fyi: informational but worth reading.
        - low_priority: spam, receipts, statements, newsletters, marketing, automatic notifications.
        - importance: how urgently the owner should see this. 5 = deadline/decision today, 4 = important (professor, registrar, bank), 3 = normal, 1-2 = low.
        - category: what kind of mail this is.
        - confidence: how sure you are of the whole judgment.
        - reason: why it does or doesn't need the owner's attention.
        """
    }

    private static func classification(from obj: [String: Any], label: String, tone: String)
        -> MailClassification {
        MailClassification(
            label: label,
            tone: tone,
            summary: obj["summary"] as? String ?? "",
            importance: obj["importance"] as? Int,
            category: obj["category"] as? String,
            confidence: obj["confidence"] as? Double,
            reason: obj["reason"] as? String)
    }

    /// Summarize a message and (when detectable) its conversation. Cached.
    func summarize(account: String, mailbox: String, uid: String) async -> MailSummary? {
        let key = Self.cacheKey(kind: "summary", account: account, mailbox: mailbox, uid: uid)
        if let cached: MailSummary = cached(key: key) { return cached }
        guard let parts = try? await readBody(account: account, mailbox: mailbox, uid: uid) else { return nil }

        let conversation = Self.conversationText(
            for: parts, in: MailManager.shared.inbox(accountID: nil),
            excluding: (account, mailbox, uid))
        let instruction = """
        You summarize an email for its owner. Respond with JSON only — no prose, no markdown fences, no tools.
        {"bullets": ["..."], "tone": "how to read it, e.g. Friendly, Urgent"}
        - bullets: 2-3 short bullets covering what the email is about and the key facts the owner must know.
        - If the email is part of a conversation, summarize the whole conversation, not just the latest message.
        """
        guard let obj = await runJSON(instruction, text: conversation),
              let bullets = obj["bullets"] as? [String], !bullets.isEmpty
        else { return nil }
        let result = MailSummary(bullets: bullets, tone: obj["tone"] as? String ?? "")
        store(result, key: key)
        return result
    }

    /// Extract action items from a message. Cached; empty when nothing is asked.
    func extractTasks(account: String, mailbox: String, uid: String) async -> [MailTaskItem] {
        let key = Self.cacheKey(kind: "tasks", account: account, mailbox: mailbox, uid: uid)
        if let cached: [MailTaskItem] = cached(key: key) { return cached }
        guard let parts = try? await readBody(account: account, mailbox: mailbox, uid: uid) else { return [] }

        let instruction = """
        You extract action items from an email. Respond with JSON only — no prose, no markdown fences, no tools.
        {"tasks": [{"title": "short imperative action", "detail": "who/what/when it involves"}]}
        - Only real requests on the owner: reply to X, approve by Friday, review the doc, decide between options.
        - Skip newsletters, notices and anything the owner doesn't need to do.
        - An empty list when nothing is asked of the owner.
        """
        guard let obj = await runJSON(instruction, text: parts.text),
              let raw = obj["tasks"] as? [[String: Any]]
        else { return [] }
        let tasks = raw.compactMap { dict -> MailTaskItem? in
            guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
            return MailTaskItem(title: title, detail: dict["detail"] as? String ?? "")
        }
        store(tasks, key: key)
        return tasks
    }

    /// Draft a reply in the owner's learned voice, at the chosen tone. Never
    /// cached. `tone` overrides the settings default; the signature block is
    /// appended deterministically so it always lands.
    func draftReply(account: String, mailbox: String, uid: String, tone: String? = nil) async -> MailDraft? {
        guard let parts = try? await readBody(account: account, mailbox: mailbox, uid: uid) else { return nil }
        let settings = MailSettingsStore.shared.current
        let chosen = tone ?? settings.draftTone
        let signature = settings.signatures[account] ?? ""
        let style = WritingStyleService.shared.currentProfile.toPromptInjection()
        let instruction = """
        You draft a reply to this email for its owner. Respond with JSON only — no prose, no markdown fences, no tools.
        {"subject": "Re: ...", "body": "the reply, ready to send"}
        - Address what the sender asked; answer their questions or ask for what you need.
        - Keep it concise and natural, not corporate boilerplate.
        - Tone: \(Self.toneDescription(chosen)).
        - Match the owner's voice: \(style.isEmpty ? "professional but warm" : style)
        \(signature.isEmpty ? "" : "- The owner's signature is: \n\(signature)")
        """
        guard let obj = await runJSON(instruction, text: parts.text, compresses: false),
              let body = obj["body"] as? String, !body.isEmpty
        else { return nil }
        let subject = obj["subject"] as? String
            ?? (parts.subject.hasPrefix("Re:") ? parts.subject : "Re: " + parts.subject)
        // Taste pass: when the draft reads generic, rewrite it with specificity
        // and the owner's voice (tied to the email's subject). Gated on a
        // deterministic boringness check, so a good draft skips the extra turn.
        // The turn is bounded tighter (30s) because the draft already waited on
        // its own model turn — the phone shouldn't sit through two full waits.
        let polished = await TasteSkillManager.shared.polishIfNeeded(
            body, scope: .emails, context: parts.subject, turnTimeoutOverride: 30)
        return MailDraft(subject: subject, body: Self.withSignature(polished, signature: signature))
    }

    /// Three replies in different tones for the review screen's "Show
    /// alternatives". Never cached — it answers a fresh ask.
    func draftAlternatives(account: String, mailbox: String, uid: String) async -> [MailDraft] {
        guard let parts = try? await readBody(account: account, mailbox: mailbox, uid: uid) else { return [] }
        let settings = MailSettingsStore.shared.current
        let signature = settings.signatures[account] ?? ""
        let style = WritingStyleService.shared.currentProfile.toPromptInjection()
        let instruction = """
        You draft 3 replies to this email for its owner. Respond with JSON only — no prose, no markdown fences, no tools.
        {"alternatives": [{"tone": "formal", "subject": "...", "body": "..."}, {"tone": "casual", "subject": "...", "body": "..."}, {"tone": "match-context", "subject": "...", "body": "..."}]}
        - Each reply addresses what the sender asked.
        - formal: polished, full sentences. casual: friendly, relaxed. match-context: the register of the sender's own message.
        - Match the owner's voice: \(style.isEmpty ? "professional but warm" : style)
        \(signature.isEmpty ? "" : "- The owner's signature is: \n\(signature)")
        """
        guard let obj = await runJSON(instruction, text: parts.text, compresses: false),
              let raw = obj["alternatives"] as? [[String: Any]]
        else { return [] }
        var drafts: [MailDraft] = []
        for dict in raw {
            guard let body = dict["body"] as? String, !body.isEmpty else { continue }
            let subject = dict["subject"] as? String
                ?? (parts.subject.hasPrefix("Re:") ? parts.subject : "Re: " + parts.subject)
            let polished = await TasteSkillManager.shared.polishIfNeeded(
                body, scope: .emails, context: parts.subject, turnTimeoutOverride: 30)
            drafts.append(MailDraft(subject: subject, body: Self.withSignature(polished, signature: signature)))
        }
        return drafts
    }

    /// Revise a draft in place from a natural-language instruction ("make it
    /// shorter", "say we'll meet Tuesday"). Never cached.
    func reviseDraft(account: String, mailbox: String, uid: String,
                     currentSubject: String, currentBody: String,
                     instruction: String) async -> MailDraft? {
        guard let parts = try? await readBody(account: account, mailbox: mailbox, uid: uid) else { return nil }
        let settings = MailSettingsStore.shared.current
        let signature = settings.signatures[account] ?? ""
        let revision = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = """
        You revise a draft reply. Respond with JSON only — no prose, no markdown fences, no tools.
        {"subject": "...", "body": "the revised reply, ready to send"}
        - Apply exactly this change: \(revision.isEmpty ? "improve the draft" : revision)
        - Keep the sender's intent and your previous substance; change only what was asked.
        - Tone: \(Self.toneDescription(settings.draftTone)).
        - Match the owner's voice.
        \(signature.isEmpty ? "" : "- The owner's signature is: \n\(signature)")
        """
        let material = """
        Original email:
        \(String(parts.text.prefix(2000)))

        Current draft:
        Subject: \(currentSubject)
        \(currentBody)
        """
        guard let obj = await runJSON(rules, text: material, compresses: false),
              let body = obj["body"] as? String, !body.isEmpty
        else { return nil }
        let subject = obj["subject"] as? String ?? currentSubject
        return MailDraft(subject: subject, body: Self.withSignature(body, signature: signature))
    }

    /// "formal" → a one-line tone instruction for the draft prompts.
    nonisolated static func toneDescription(_ tone: String) -> String {
        switch tone {
        case "formal": return "formal and polished"
        case "casual": return "casual and friendly"
        default: return "the register the sender used in their message"
        }
    }

    /// Append the signature block once, deterministically — the model may or
    /// may not have included it, and the review screen must show the final
    /// sendable body.
    nonisolated static func withSignature(_ body: String, signature: String) -> String {
        let trimmed = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !body.contains(trimmed) else { return body }
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + trimmed
    }

    /// Natural-language search over the cached inbox. The model compiles the
    /// query into a structured filter (sender, terms, unread, recency) plus a
    /// one-line note; the filter runs locally over the cache, so results are
    /// instant. When the model is busy or the answer won't parse, degrades to
    /// plain LIKE search with an empty note — never fails the search itself.
    func search(query: String, accountID: String?) async -> (messages: [MailMessage], note: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let manager = MailManager.shared
        guard !trimmed.isEmpty else { return (manager.inbox(accountID: accountID), "") }

        let intent = await compileSearchIntent(trimmed)
        let messages = intent == .empty
            ? manager.search(query: trimmed, accountID: accountID)
            : Self.filter(manager.inbox(accountID: accountID), intent: intent)
        return (messages, intent.note)
    }

    // MARK: - Private

    /// Ask the model to compile a query into a filter. Any failure → `.empty`,
    /// which makes `search` fall back to the plain LIKE path.
    private func compileSearchIntent(_ query: String) async -> MailSearchIntent {
        let instruction = """
        You translate a natural-language mail search into a structured filter. Respond with JSON only — no prose, no markdown fences, no tools.
        {"sender": "name-or-address fragment, or null", "terms": ["content keywords"], "unread_only": bool, "since_days": int-or-null, "note": "one short line describing the results, e.g. 6 emails from Sarah about budget"}
        - sender: only when a person or address is named.
        - terms: content keywords (about X, receipts, invoices...).
        - unread_only: true only when unread/urgent/pending is asked.
        - since_days: recency (last week → 7), or null.
        - note: a natural summary of what was asked, under 15 words.
        """
        guard let obj = await runJSON(instruction, text: query),
              let note = obj["note"] as? String
        else { return .empty }
        return MailSearchIntent(
            sender: obj["sender"] as? String,
            terms: (obj["terms"] as? [String] ?? []).filter { !$0.isEmpty },
            unreadOnly: obj["unread_only"] as? Bool ?? false,
            sinceDays: obj["since_days"] as? Int,
            note: note)
    }

    private func readBody(account: String, mailbox: String, uid: String) async throws
        -> EmailCapability.MessageParts {
        try await MailManager.shared.messageParts(account: account, mailbox: mailbox, uid: uid)
    }

    /// One tool-free model turn answered in a single JSON object. Returns nil
    /// when the session is busy (don't cut across a conversation the owner is
    /// watching) or the answer isn't parseable JSON.
    ///
    /// The turn runs inside the shared gate. `HermesSession` is single-turn: a
    /// second concurrent prompt would overwrite the first's event sink and
    /// interleave the streams, so the gate queues parallel asks sequentially.
    /// `isTurnActive` is checked *at run time*, just before prompting — two asks
    /// could both pass a single early check before either turn starts (TOCTOU),
    /// and a user turn that began while this ask sat in the queue must win.
    /// One tool-free model turn answered in a single JSON object. `compresses`
    /// routes long bodies through Headroom before they enter the prompt: the
    /// model sees the same content in fewer tokens (the mail copilot's calls
    /// are cached analysis — classification, summaries, tasks). Drafting paths
    /// pass `false` because the model must reproduce the sender's exact
    /// wording there, and compression is lossy-by-design.
    private func runJSON(_ instruction: String, text: String, compresses: Bool = true)
        async -> [String: Any]? {
        guard let session = hermes else { return nil }
        let room = 4000
        var trimmed = String(text.prefix(room))
        if compresses {
            trimmed = await HeadroomMCPClient.shared.compressForContext(trimmed)
        }
        let prompt = instruction + "\n\nEmail:\n" + trimmed
        return await turnGate.enqueue {
            // Re-check immediately before prompting. If the owner started a turn
            // while this ask was queued, defer — never prompt over them.
            guard !(await session.isTurnActive) else { return nil }
            return await Self.runPromptBounded(session, prompt: prompt)
        }
    }

    /// One bounded prompt turn. Races the model stream against `turnTimeout`
    /// and returns nil when the deadline wins, so a hung session degrades to
    /// "no analysis this round" instead of holding the gate open. The abandoned
    /// turn still owns the session until it settles — the next ask's run-time
    /// `isTurnActive` check keeps the queue from overlapping it.
    private static func runPromptBounded(_ session: HermesSession, prompt: String)
        async -> [String: Any]? {
        enum Outcome {
            case transcript(String)
            case timedOut
        }
        let turn = Task { () -> String in
            var transcript = ""
            for await event in await session.prompt(prompt, capture: false) {
                if case let .text(chunk) = event { transcript.append(chunk) }
                if case .failed = event { break }
            }
            return transcript
        }
        let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { .transcript(await turn.value) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.turnTimeout * 1_000_000_000))
                turn.cancel()
                return .timedOut
            }
            guard let first = await group.next() else { return .timedOut }
            group.cancelAll()
            return first
        }
        switch outcome {
        case .timedOut:
            NSLog("[mail-ai] model turn timed out after \(Int(Self.turnTimeout))s; degrading")
            return nil
        case .transcript(let transcript):
            let cleaned = transcript
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = cleaned.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    // MARK: - Cache

    private func cached<T: Codable>(key: String) -> T? {
        guard let db = try? Self.openDB() else { return nil }
        defer { sqlite3_close(db) }
        var payload: String?
        do {
            try Self.queryRows(db, sql: """
                SELECT payload FROM \(Self.cacheTable) WHERE key = ? AND at > ?
                """, args: [
                    .text(key),
                    .double(Date().timeIntervalSince1970 - Self.cacheTTL),
                ]) { stmt in
                payload = Self.textColumn(stmt, 0)
            }
        } catch { }
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func store(_ value: Codable, key: String) {
        guard let db = try? Self.openDB() else { return }
        defer { sqlite3_close(db) }
        guard let data = try? JSONEncoder().encode(value),
              let payload = String(data: data, encoding: .utf8) else { return }
        try? Self.exec(db, sql: """
            INSERT INTO \(Self.cacheTable) (key, kind, payload, at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, at = excluded.at
            """, args: [
                .text(key), .text(""), .text(payload),
                .double(Date().timeIntervalSince1970),
            ])
    }

    nonisolated private static func cacheKey(kind: String, account: String,
                                             mailbox: String, uid: String) -> String {
        "\(kind):\(account)|\(mailbox)|\(uid)"
    }

    // MARK: - Conversation builder (pure, tested)

    /// The current message plus its siblings in the same conversation (same
    /// sender, same normalized subject) from the cached inbox, oldest first.
    /// This is what "Summarize Thread" actually summarizes — a best-effort
    /// grouping, since the cache holds envelopes, not References headers.
    /// `current` identifies the message being read so its own envelope isn't
    /// counted as a sibling (it would otherwise match sender + subject).
    nonisolated static func conversationText(for parts: EmailCapability.MessageParts,
                                             in inbox: [MailMessage],
                                             excluding current: (account: String, mailbox: String, uid: String)? = nil)
        -> String {
        let siblings = conversationSiblings(
            sender: parts.fromAddress, subject: parts.subject, in: inbox, excluding: current)
        guard !siblings.isEmpty else { return parts.text }
        var lines = ["Conversation (\(siblings.count + 1) messages):"]
        for sibling in siblings {
            let when = sibling.date.map(Self.dateLabel) ?? ""
            let who = sibling.fromName.isEmpty ? sibling.fromAddress : sibling.fromName
            lines.append("— \(who)\(when.isEmpty ? "" : " · \(when)"): \(sibling.snippet)")
        }
        lines.append("— (latest) \(parts.subject):")
        lines.append(parts.text)
        return lines.joined(separator: "\n")
    }

    /// Siblings of a message in the same pseudo-thread, oldest first, capped at
    /// 6. Subject matching strips Re:/Fwd:/… so "Re: Budget" groups with
    /// "Budget"; sender matching is case-insensitive on the address. The
    /// current message's own envelope (matched by the account/mailbox/uid
    /// triple) is excluded — its full text is rendered as the latest message.
    nonisolated static func conversationSiblings(sender: String, subject: String,
                                                 in inbox: [MailMessage],
                                                 excluding current: (account: String, mailbox: String, uid: String)? = nil)
        -> [MailMessage] {
        let targetSubject = normalizedSubject(subject)
        let targetSender = sender.lowercased()
        return inbox
            .filter { message in
                guard message.fromAddress.lowercased() == targetSender
                    && normalizedSubject(message.subject) == targetSubject else { return false }
                if let current,
                   message.account == current.account,
                   message.mailbox == current.mailbox,
                   message.uid == current.uid {
                    return false
                }
                return true
            }
            .sorted { ($0.date ?? 0) < ($1.date ?? 0) }
            .prefix(6)
            .map { $0 }
    }

    /// Strip reply/forward prefixes ("Re:", "Fwd:", "Aw:", …) so a thread's
    /// messages group by their real subject. Repeats until stable, because
    /// chains can double up ("Re: Re: Budget").
    nonisolated static func normalizedSubject(_ raw: String) -> String {
        let prefixes = ["re:", "fwd:", "fw:", "aw:", "antw:", "sv:", "vs:", "答复:", "回复:"]
        var subject = raw.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where subject.lowercased().hasPrefix(prefix) {
                subject = String(subject.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return subject
    }

    // MARK: - Search filter (pure, tested)

    /// Apply a compiled intent to the cached inbox. All criteria AND together;
    /// terms match subject, snippet, sender name or address, case-insensitively.
    nonisolated static func filter(_ messages: [MailMessage], intent: MailSearchIntent) -> [MailMessage] {
        let sender = intent.sender?.lowercased()
        let since = intent.sinceDays.map {
            Date().addingTimeInterval(-Double($0) * 86_400).timeIntervalSince1970
        }
        return messages.filter { message in
            if let sender, !sender.isEmpty {
                let haystack = "\(message.fromName) \(message.fromAddress)".lowercased()
                guard haystack.contains(sender) else { return false }
            }
            if intent.unreadOnly, !message.isUnread { return false }
            if let since, let date = message.date, date < since { return false }
            if !intent.terms.isEmpty {
                let haystack = "\(message.subject) \(message.snippet) \(message.fromName) \(message.fromAddress)"
                    .lowercased()
                guard intent.terms.allSatisfy({ haystack.contains($0.lowercased()) }) else { return false }
            }
            return true
        }
    }

    nonisolated private static func dateLabel(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    // MARK: - SQLite plumbing (mirrors MailManager)

    nonisolated private static func openDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(databasePath, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let db else {
            throw NSError(domain: "Alfred.MailAI", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "could not open \(databasePath)"])
        }
        try exec(db, sql: """
            CREATE TABLE IF NOT EXISTS \(cacheTable) (
                key     TEXT PRIMARY KEY,
                kind    TEXT NOT NULL DEFAULT '',
                payload TEXT NOT NULL,
                at      REAL NOT NULL
            );
            """)
        return db
    }

    private enum Bind {
        case text(String)
        case double(Double)
        case int(Int)
    }

    nonisolated private static func exec(_ db: OpaquePointer, sql: String,
                                         args: [Bind] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "Alfred.MailAI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: Self.lastError(db)])
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "Alfred.MailAI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: Self.lastError(db)])
        }
    }

    nonisolated private static func queryRows(_ db: OpaquePointer, sql: String, args: [Bind] = [],
                                              row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "Alfred.MailAI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: Self.lastError(db)])
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            row(stmt)
            rc = sqlite3_step(stmt)
        }
        if rc != SQLITE_DONE {
            throw NSError(domain: "Alfred.MailAI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: Self.lastError(db)])
        }
    }

    nonisolated private static func bind(_ stmt: OpaquePointer, _ args: [Bind]) {
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            switch arg {
            case .text(let value): sqlite3_bind_text(stmt, i, value, -1, SQLITE_TRANSIENT)
            case .double(let value): sqlite3_bind_double(stmt, i, value)
            case .int(let value): sqlite3_bind_int64(stmt, i, Int64(value))
            }
        }
    }

    nonisolated private static func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    nonisolated private static func lastError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

// MARK: - Turn gate

/// Serializes the copilot's own model turns. `HermesSession` is single-turn:
/// a second concurrent `prompt` would overwrite the first's event sink and
/// interleave the two streams. `isTurnActive` is only a first-pass politeness
/// check — two asks can both pass it before either turn starts (TOCTOU) — so
/// every copilot turn (classify + summarize + watcher polls) runs through one
/// gate and lands sequentially, newest ask waiting on the previous one.
private actor TurnGate {
    private var previous: Task<[String: Any]?, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> [String: Any]?) async -> [String: Any]? {
        let prior = previous
        let task = Task { [prior] in
            _ = await prior?.value
            return await operation()
        }
        previous = task
        return await task.value
    }
}
