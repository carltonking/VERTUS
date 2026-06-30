import AppKit
import Foundation

enum InboundChannel { case email, text }

/// OPT-IN, low-frequency watcher for new inbound mail/texts. For each genuinely new message it asks
/// the LLM "does this need a personal reply?"; if so, it posts an actionable notification
/// ("Sarah texted you — want me to respond?"). Tapping Respond routes into the Phase-1 drafting brain.
///
/// SAFETY: deliberately mirrors `ScreenMonitoringManager` — a `Task { while !cancelled { … sleep } }`
/// loop with NO stored `Timer`/`DispatchSource`, and this class is NOT one of the three the
/// `SafetyAuditEngine` scans (TaskEngine/TaskDashboardService/ActionSelectionEngine), so the startup
/// audit stays green. It NEVER sends anything itself — it only surfaces a notification the user taps.
@MainActor
final class InboundWatcher: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status = "Inbound monitoring is off."
    @Published private(set) var lastCheckAt: Date?

    private let router: LLMRouter
    private let emailReader = EmailReadService()
    private let interval: TimeInterval
    private let maxNotifyPerCycle = 5
    private var monitorTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private let kLastTextRowID = "inbound.lastTextRowID"
    private let kSeenEmail = "inbound.seenEmailKeys"
    private let kBaselined = "inbound.baselined"

    init(router: LLMRouter, interval: TimeInterval = 150) {
        self.router = router
        self.interval = interval
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        status = "Watching for messages that need a reply."
        monitorTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        isActive = false
        status = "Inbound monitoring is off."
    }

    // MARK: - Loop

    private func runLoop() async {
        // Baseline once so we never notify about the backlog that existed before the user opted in.
        if !defaults.bool(forKey: kBaselined) {
            await baseline()
            defaults.set(true, forKey: kBaselined)
        }
        while !Task.isCancelled {
            await checkOnce()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func baseline() async {
        if let maxID = MessagesReadCapability.maxReceivedRowID() {
            defaults.set(Int(maxID), forKey: kLastTextRowID)
        }
        // Seed the seen-set with the WHOLE current unread backlog (large cap), so the first cycle
        // never notifies about mail that arrived before the user opted in.
        if let unread = try? await emailReader.fetchRecentUnread(limit: 500) {
            defaults.set(unread.map { Self.emailKey($0) }, forKey: kSeenEmail)
        }
    }

    private func checkOnce() async {
        lastCheckAt = Date()
        var notified = 0
        var triaged = 0
        let maxTriage = 12   // bound LLM cost per cycle (separate from the notify cap)

        // --- Texts (stable ROWID cursor) ---
        // Advance the cursor ONLY past messages we actually handled, so a burst larger than the
        // per-cycle budget isn't silently skipped — the remainder is picked up next cycle.
        let lastRow = Int64(defaults.integer(forKey: kLastTextRowID))
        var lastHandledRow = lastRow
        for msg in MessagesReadCapability.recentReceived(afterRowID: lastRow, limit: 10) {
            if notified >= maxNotifyPerCycle || triaged >= maxTriage { break }
            lastHandledRow = msg.rowid
            guard !msg.text.isEmpty, msg.text != "[attachment]" else { continue }
            triaged += 1
            if let t = await triage(channel: .text, sender: msg.name, subject: nil, preview: msg.text), t.needsReply {
                await postNotification(channel: "text", sender: msg.name, handle: msg.handle,
                                       subject: nil, preview: msg.text, summary: t.summary,
                                       id: "inbound.text.\(msg.rowid)")
                notified += 1
            }
        }
        if lastHandledRow > lastRow { defaults.set(Int(lastHandledRow), forKey: kLastTextRowID) }

        // --- Email (no stable id → dedup on sender|subject|date) ---
        if let unread = try? await emailReader.fetchRecentUnread(limit: 30, includeBody: true) {
            let seen = Set(defaults.stringArray(forKey: kSeenEmail) ?? [])
            var handled: [String] = []   // only keys we decided on this cycle get marked seen
            for mail in unread {
                let key = Self.emailKey(mail)
                if seen.contains(key) { continue }
                // Out of budget → leave UNSEEN so it's retried next cycle (never dropped).
                if notified >= maxNotifyPerCycle || triaged >= maxTriage { continue }
                let senderRaw = mail.metadata["sender"] ?? mail.subtitle
                let subject = mail.metadata["subject"] ?? mail.title
                let body = mail.metadata["body"] ?? ""
                handled.append(key)
                // Cheap prefilter: skip obvious automated senders without spending an LLM call.
                if Self.isAutomated(senderRaw) { continue }
                triaged += 1
                if let t = await triage(channel: .email, sender: Self.displayName(senderRaw),
                                        subject: subject, preview: subject), t.needsReply {
                    await postNotification(channel: "email", sender: Self.displayName(senderRaw),
                                           handle: Self.extractEmail(senderRaw), subject: subject,
                                           preview: body.isEmpty ? subject : body, summary: t.summary,
                                           id: "inbound.email.\(UInt(bitPattern: key.hashValue))")
                    notified += 1
                }
            }
            // Persist newest-last and capped; un-handled keys stay out so they aren't lost.
            let prior = (defaults.stringArray(forKey: kSeenEmail) ?? []).filter { !handled.contains($0) }
            defaults.set(Array((prior + handled).suffix(1000)), forKey: kSeenEmail)
        }

        status = "Last checked \(Self.time(Date()))."
    }

    // MARK: - Triage

    private struct Triage { let needsReply: Bool; let summary: String }

    private func triage(channel: InboundChannel, sender: String, subject: String?, preview: String) async -> Triage? {
        let kind = channel == .email ? "email" : "text message"
        let system = """
        You triage an incoming \(kind) for a busy person. Decide whether it needs a PERSONAL reply \
        from them. Automated mail, newsletters, receipts, promotions, system notifications, no-reply \
        senders, and spam do NOT need a reply. Respond with ONE line of JSON only, no prose: \
        {"needsReply": true|false, "summary": "<8 words max, what it is about>"}
        """
        var user = "From: \(sender)\n"
        if let subject, !subject.isEmpty { user += "Subject: \(subject)\n" }
        user += "Message: \(String(preview.prefix(400)))"

        // NOTE: LLMRouter is a shared, non-Sendable class already driven from several executors
        // (the main-actor bar path and the AssistantCore actor). Its `lastEgressSummary` write is
        // unsynchronized — a pre-existing latent race this watcher adds one more caller to, not a
        // new one. Proper fix (make LLMRouter an actor / @MainActor) is a separate plumbing change.
        guard let raw = try? await router.complete(prompt: user, system: system) else { return nil }
        return Self.parseTriage(raw)
    }

    /// Lenient parse: default to needsReply=false unless the boolean right after "needsReply" is true.
    private static func parseTriage(_ s: String) -> Triage {
        let lower = s.lowercased()
        var needs = false
        if let r = lower.range(of: "needsreply") {
            needs = lower[r.upperBound...].prefix(16).contains("true")
        }
        var summary = ""
        if let r = s.range(of: "\"summary\"") {
            let after = s[r.upperBound...]
            if let q1 = after.range(of: "\""), let q2 = after[q1.upperBound...].range(of: "\"") {
                summary = String(after[q1.upperBound..<q2.lowerBound])
            }
        }
        return Triage(needsReply: needs, summary: summary)
    }

    // MARK: - Notification

    private func postNotification(channel: String, sender: String, handle: String,
                                  subject: String?, preview: String, summary: String, id: String) async {
        let verb = channel == "email" ? "emailed" : "texted"
        let title = "\(sender) \(verb) you"
        let body = summary.isEmpty ? "Want me to respond?" : "\(summary) — want me to respond?"
        var info: [String: String] = [
            "channel": channel, "sender": sender, "handle": handle,
            "preview": String(preview.prefix(1000)),
        ]
        if let subject { info["subject"] = subject }
        _ = try? await NotificationManager.shared.sendActionable(title: title, body: body,
                                                                 identifier: id, userInfo: info)
    }

    // MARK: - Helpers

    /// Cheap, no-LLM prefilter for obviously automated senders, so newsletters/receipts/no-reply
    /// addresses don't each cost a triage call.
    static func isAutomated(_ sender: String) -> Bool {
        let s = sender.lowercased()
        return s.contains("no-reply") || s.contains("noreply") || s.contains("donotreply")
            || s.contains("do-not-reply") || s.contains("mailer-daemon") || s.contains("postmaster@")
            || s.contains("notifications@") || s.contains("notification@") || s.contains("automated")
    }

    static func emailKey(_ r: IntegrationSearchResult) -> String {
        let s = r.metadata["sender"] ?? r.subtitle
        let subj = r.metadata["subject"] ?? r.title
        let d = r.metadata["date"] ?? ""
        return "\(s)|\(subj)|\(d)"
    }

    /// "Sarah Chen <sarah@x.com>" → "sarah@x.com"; a bare address is returned as-is.
    static func extractEmail(_ sender: String) -> String {
        if let lt = sender.range(of: "<"), let gt = sender.range(of: ">"), lt.upperBound <= gt.lowerBound {
            return String(sender[lt.upperBound..<gt.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return sender.trimmingCharacters(in: .whitespaces)
    }

    /// "Sarah Chen <sarah@x.com>" → "Sarah Chen"; a bare address is returned as-is.
    static func displayName(_ sender: String) -> String {
        if let lt = sender.range(of: "<") {
            let name = String(sender[sender.startIndex..<lt.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !name.isEmpty { return name }
        }
        return sender.trimmingCharacters(in: .whitespaces)
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: d)
    }
}
