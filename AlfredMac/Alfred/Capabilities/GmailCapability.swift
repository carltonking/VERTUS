import Foundation

// MARK: - GmailCapability
//
// Reads recent Gmail through the Gmail REST API, authorized by GoogleAuth's loopback login.
// Read-only (gmail.readonly). Talks only to googleapis.com.
//
// Triggers:
//   "connect gmail" / "connect google" → one-time browser login.
//   "read my gmail" / "check gmail"     → lists recent inbox mail.

enum GmailCapability {

    static func handle(_ query: String) async -> String? {
        let q = query.lowercased()

        if isConnectRequest(q) {
            return await GoogleAuth.beginLogin()
        }
        if isReadRequest(q) {
            guard GoogleAuth.isConnected else {
                return GoogleAuth.hasCredentials
                    ? "Gmail isn't connected yet — say \"connect gmail\" and finish the quick browser step."
                    : GoogleAuth.setupMessage
            }
            return await recentMail()
        }
        return nil
    }

    private static func isConnectRequest(_ q: String) -> Bool {
        ["connect gmail", "connect google", "link gmail", "link google", "sign in to gmail",
         "log in to gmail", "set up gmail", "setup gmail", "connect my gmail"].contains { q.contains($0) }
    }

    private static func isReadRequest(_ q: String) -> Bool {
        guard q.contains("gmail") || q.contains("google mail") else { return false }
        return ["read", "check", "show", "any", "new", "recent", "latest", "what", "unread", "my"].contains { q.contains($0) }
    }

    /// Recent inbox messages, newest first: "Sender — Subject: snippet".
    private static func recentMail(limit: Int = 10) async -> String {
        guard let token = await GoogleAuth.accessToken() else {
            return "Couldn't get a Google token — your sign-in may have expired. Say \"connect gmail\" to reconnect."
        }

        // 1. List recent inbox message IDs.
        var listComps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        listComps.queryItems = [
            URLQueryItem(name: "maxResults", value: String(limit)),
            URLQueryItem(name: "labelIds", value: "INBOX"),
        ]
        guard let listData = try? await get(listComps.url!, token: token) else {
            return "Couldn't reach Gmail right now."
        }
        struct ListResp: Decodable { struct Ref: Decodable { let id: String }; let messages: [Ref]? }
        guard let ids = (try? JSONDecoder().decode(ListResp.self, from: listData))?.messages, !ids.isEmpty else {
            return "No recent Gmail in your inbox."
        }

        // 2. Fetch each message's headers + snippet, concurrently, preserving order.
        let summaries = await withTaskGroup(of: (Int, String?).self) { group -> [String] in
            for (i, ref) in ids.enumerated() {
                group.addTask { (i, await messageLine(id: ref.id, token: token)) }
            }
            var collected = Array<String?>(repeating: nil, count: ids.count)
            for await (i, line) in group { collected[i] = line }
            return collected.compactMap { $0 }
        }

        guard !summaries.isEmpty else { return "Couldn't read your Gmail messages." }
        return "Recent Gmail:\n" + summaries.joined(separator: "\n")
    }

    private static func messageLine(id: String, token: String) async -> String? {
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
        ]
        guard let data = try? await get(comps.url!, token: token) else { return nil }
        struct Msg: Decodable {
            struct Payload: Decodable { struct Header: Decodable { let name: String; let value: String }; let headers: [Header] }
            let snippet: String?
            let payload: Payload?
            let labelIds: [String]?
        }
        guard let msg = try? JSONDecoder().decode(Msg.self, from: data) else { return nil }
        let headers = msg.payload?.headers ?? []
        let fromRaw = headers.first(where: { $0.name == "From" })?.value ?? "Unknown"
        let subject = headers.first(where: { $0.name == "Subject" })?.value ?? "(no subject)"
        let unread = (msg.labelIds?.contains("UNREAD") == true) ? "• " : "  "
        let snippet = (msg.snippet ?? "").replacingOccurrences(of: "\n", with: " ").prefix(80)
        return "\(unread)\(prettyFrom(fromRaw)) — \(subject)" + (snippet.isEmpty ? "" : ": \(snippet)")
    }

    /// "Carlton King <c@x.com>" → "Carlton King"; bare address stays as-is.
    private static func prettyFrom(_ raw: String) -> String {
        if let lt = raw.firstIndex(of: "<") {
            let name = raw[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
        }
        return raw
    }

    private static func get(_ url: URL, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.networkError("Gmail HTTP error")
        }
        return data
    }

    // MARK: - Sent-mail read (voice learning)

    struct SentEmail { let internalDate: Int64; let body: String }

    /// Lists recent SENT messages (newest first), fetches and cleans each body. `afterInternalDate`
    /// (epoch ms) narrows the server-side query for incremental runs; the precise watermark filter
    /// is applied by the caller via `emailsNewerThan`. Reuses `get()` for authorized requests.
    /// gmail.readonly already permits SENT — no re-auth.
    static func recentSentEmails(afterInternalDate: Int64, limit: Int) async -> [SentEmail] {
        guard let token = await GoogleAuth.accessToken() else { return [] }

        var listComps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        var q = "in:sent"
        if afterInternalDate > 0 { q += " after:\(afterInternalDate / 1000)" }   // Gmail `after:` is epoch SECONDS
        listComps.queryItems = [
            URLQueryItem(name: "maxResults", value: String(limit)),
            URLQueryItem(name: "q", value: q),
        ]
        guard let listData = try? await get(listComps.url!, token: token) else { return [] }
        struct ListResp: Decodable { struct Ref: Decodable { let id: String }; let messages: [Ref]? }
        guard let ids = (try? JSONDecoder().decode(ListResp.self, from: listData))?.messages, !ids.isEmpty else {
            return []
        }

        return await withTaskGroup(of: (Int, SentEmail?).self) { group -> [SentEmail] in
            for (i, ref) in ids.enumerated() {
                group.addTask { (i, await fetchSentBody(id: ref.id, token: token)) }
            }
            var collected = [SentEmail?](repeating: nil, count: ids.count)
            for await (i, email) in group { collected[i] = email }
            return collected.compactMap { $0 }
        }
    }

    private static func fetchSentBody(id: String, token: String) async -> SentEmail? {
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        comps.queryItems = [URLQueryItem(name: "format", value: "full")]
        guard let data = try? await get(comps.url!, token: token),
              let msg = try? JSONDecoder().decode(FullMessage.self, from: data),
              let internalMs = Int64(msg.internalDate ?? ""),
              let raw = extractPlainText(from: msg.payload), !raw.isEmpty else { return nil }

        let cleaned = EmailBodyCleaner.ownTextOnly(raw)
        guard !cleaned.isEmpty else { return nil }
        return SentEmail(internalDate: internalMs, body: cleaned)
    }

    private struct FullMessage: Decodable {
        let internalDate: String?
        let payload: Part?
    }
    private struct Part: Decodable {
        let mimeType: String?
        let body: Body?
        let parts: [Part]?
        struct Body: Decodable { let data: String? }
    }

    /// Pulls the first `text/plain` body out of the (possibly multipart) payload and base64url-decodes
    /// it. HTML-only messages are skipped (returns nil).
    private static func extractPlainText(from part: Part?) -> String? {
        guard let part else { return nil }
        if part.mimeType == "text/plain", let data = part.body?.data, let decoded = base64urlDecode(data) {
            return decoded
        }
        for sub in part.parts ?? [] {
            if let found = extractPlainText(from: sub) { return found }
        }
        return nil
    }

    static func base64urlDecode(_ s: String) -> String? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Watermark (pure, testable)

    /// Keep only emails strictly newer than the watermark (epoch ms) — the idempotency guarantee.
    static func emailsNewerThan(_ emails: [SentEmail], _ watermark: Int64) -> [SentEmail] {
        emails.filter { $0.internalDate > watermark }
    }

    /// New watermark = the latest imported internalDate (never moves backwards).
    static func newWatermark(_ emails: [SentEmail], current: Int64) -> Int64 {
        max(current, emails.map(\.internalDate).max() ?? current)
    }
}
