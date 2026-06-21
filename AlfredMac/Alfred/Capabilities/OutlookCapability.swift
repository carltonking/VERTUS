import Foundation

// MARK: - OutlookCapability
//
// Reads recent Outlook / Microsoft 365 mail through the Microsoft Graph API, authorized by the
// device-code login in MicrosoftAuth. Read-only for v1 (Mail.Read). Talks only to graph.microsoft.com.
//
// Triggers:
//   "connect outlook" / "connect microsoft"  → starts the one-time browser login.
//   "read my outlook" / "check my outlook"    → lists recent received mail.

enum OutlookCapability {

    /// Returns a response when the query is a connect/read Outlook request, else nil (so other
    /// handlers/the LLM run). Async because both login and reading hit the network.
    static func handle(_ query: String) async -> String? {
        let q = query.lowercased()

        if isConnectRequest(q) {
            return await MicrosoftAuth.beginLogin()
        }
        if isReadRequest(q) {
            guard MicrosoftAuth.isConnected else {
                return MicrosoftAuth.hasClientID
                    ? "Outlook isn't connected yet — say \"connect outlook\" and finish the quick browser step."
                    : MicrosoftAuth.setupMessage
            }
            return await recentMail()
        }
        return nil
    }

    private static func isConnectRequest(_ q: String) -> Bool {
        let connects = ["connect outlook", "connect microsoft", "connect my outlook", "link outlook",
                        "link microsoft", "sign in to outlook", "log in to outlook", "set up outlook",
                        "setup outlook", "connect to outlook"]
        return connects.contains { q.contains($0) }
    }

    private static func isReadRequest(_ q: String) -> Bool {
        // Must mention outlook/microsoft so it doesn't collide with the Apple Mail reader.
        guard q.contains("outlook") || q.contains("microsoft email") || q.contains("microsoft mail") else { return false }
        let reads = ["read", "check", "show", "any", "new", "recent", "latest", "what", "my outlook", "unread"]
        return reads.contains { q.contains($0) }
    }

    /// Recent received messages, newest first: "Sender — Subject: preview".
    private static func recentMail(limit: Int = 10) async -> String {
        guard let token = await MicrosoftAuth.accessToken() else {
            return "Couldn't get a Microsoft token — your sign-in may have expired. Say \"connect outlook\" to reconnect."
        }
        var comps = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
        comps.queryItems = [
            URLQueryItem(name: "$top", value: String(limit)),
            URLQueryItem(name: "$select", value: "subject,from,receivedDateTime,bodyPreview,isRead"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else {
            return "Couldn't reach Outlook right now."
        }
        guard (200...299).contains(http.statusCode) else {
            return "Outlook request failed (HTTP \(http.statusCode)). Try \"connect outlook\" again if this keeps happening."
        }

        struct Resp: Decodable {
            struct Message: Decodable {
                struct From: Decodable { struct Addr: Decodable { let name: String?; let address: String? }; let emailAddress: Addr? }
                let subject: String?
                let from: From?
                let bodyPreview: String?
                let isRead: Bool?
            }
            let value: [Message]
        }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data), !decoded.value.isEmpty else {
            return "No recent Outlook mail."
        }

        let lines = decoded.value.map { msg -> String in
            let who = msg.from?.emailAddress?.name ?? msg.from?.emailAddress?.address ?? "Unknown"
            let subject = (msg.subject?.isEmpty == false ? msg.subject! : "(no subject)")
            let unread = (msg.isRead == false) ? "• " : "  "
            let preview = msg.bodyPreview?.replacingOccurrences(of: "\n", with: " ").prefix(80) ?? ""
            return "\(unread)\(who) — \(subject)" + (preview.isEmpty ? "" : ": \(preview)")
        }
        return "Recent Outlook mail:\n" + lines.joined(separator: "\n")
    }
}
