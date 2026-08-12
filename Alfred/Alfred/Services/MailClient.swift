//
//  MailClient.swift
//  Alfred
//
//  Everything the mail UI asks the server for.
//
//  A second client alongside AlfredClient rather than an extension of it, because the two speak
//  different languages: /api/app returns one prose string written for a chat bubble, and a message
//  list can't render prose into rows. /api/mail answers in structured JSON instead.
//

import Foundation

struct MailClient {
    /// IMAP is not fast — several accounts, each a TLS handshake plus a fetch. The server function is
    /// capped at 60s, so allow a margin past it: a slow-but-alive sync shouldn't be killed by the
    /// phone a second before the messages land.
    private static let requestTimeout: TimeInterval = 75

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case notConfigured
        case unauthorized
        case tokenMissingOnServer
        case notDeployed
        case server(String)
        case http(Int)
        case offline
        case timedOut
        case transport(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Alfred isn't connected yet. Add your address and token in Settings."
            case .unauthorized:
                return "That token was rejected. Check it in Settings — it has to match APP_TOKEN on the server."
            case .tokenMissingOnServer:
                return "The server has no APP_TOKEN set, so it's refusing every request."
            case .notDeployed:
                return "This deployment has no /api/mail yet. Deploy the current version of Alfred and try again."
            case .server(let message):
                return message
            case .http(let code):
                return "Alfred's server answered \(code)."
            case .offline:
                return "No internet connection."
            case .timedOut:
                return "Your mail server took too long to answer. Pull down to try again."
            case .transport(let message):
                return message
            case .malformedResponse:
                return "Alfred sent something this app couldn't read."
            }
        }
    }

    // MARK: - Endpoint

    /// Built from the `/api/app` URL the user already configured, so adding mail didn't need a second
    /// address field in Settings — one deployment, two doors.
    static func endpoint(from appEndpoint: URL?) -> URL? {
        guard let appEndpoint else { return nil }
        return appEndpoint.deletingLastPathComponent().appendingPathComponent("mail")
    }

    // MARK: - Transport

    private struct Envelope: Decodable {
        let ok: Bool
        let error: String?
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = MailDate.parse(raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO-8601 date: \(raw)")
                )
            }
            return date
        }
        return d
    }()

    private func perform<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw Failure.offline
            case .timedOut:
                throw Failure.timedOut
            default:
                throw Failure.transport(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        let envelope = try? Self.decoder.decode(Envelope.self, from: data)

        switch http.statusCode {
        case 200:
            guard envelope?.ok == true else {
                throw Failure.server(envelope?.error ?? "Alfred couldn't complete that.")
            }
            do {
                return try Self.decoder.decode(T.self, from: data)
            } catch {
                throw Failure.malformedResponse
            }
        case 401:
            throw Failure.unauthorized
        case 404:
            // The one 404 worth explaining: an older deployment that predates the mail endpoint.
            throw Failure.notDeployed
        case 503:
            throw Failure.tokenMissingOnServer
        default:
            if let message = envelope?.error, !message.isEmpty { throw Failure.server(message) }
            throw Failure.http(http.statusCode)
        }
    }

    private func get<T: Decodable>(_ action: String, _ query: [String: String] = [:], endpoint: URL?, token: String) async throws -> T {
        guard let endpoint, !token.isEmpty else { throw Failure.notConfigured }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw Failure.notConfigured
        }
        components.queryItems = ([("action", action)] + query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw Failure.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(request, as: T.self)
    }

    private func post<T: Decodable>(_ body: [String: Any], endpoint: URL?, token: String) async throws -> T {
        guard let endpoint, !token.isEmpty else { throw Failure.notConfigured }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request, as: T.self)
    }

    /// For calls whose only interesting outcome is "did it work" — the envelope already carries that.
    private struct Ack: Decodable {}

    // MARK: - Accounts

    func accounts(endpoint: URL?, token: String) async throws -> AccountsPayload {
        try await get("accounts", endpoint: endpoint, token: token)
    }

    // MARK: - Google sign-in

    /// Asks the server for a Google consent URL. Opening it in a browser and coming back is what
    /// adds a Google account — no password is ever typed or stored on the phone.
    struct GoogleLoginPayload: Decodable {
        let url: String
    }

    func googleLoginURL(endpoint: URL?, token: String) async throws -> String {
        let payload: GoogleLoginPayload = try await get("googleLogin", endpoint: endpoint, token: token)
        return payload.url
    }

    func addAccount(
        provider: String,
        address: String,
        password: String,
        label: String?,
        imapHost: String?,
        smtpHost: String?,
        endpoint: URL?,
        token: String
    ) async throws -> AddAccountPayload {
        var body: [String: Any] = [
            "action": "addAccount",
            "provider": provider,
            "address": address,
            "password": password,
        ]
        if let label, !label.isEmpty { body["label"] = label }
        if let imapHost, !imapHost.isEmpty { body["imapHost"] = imapHost }
        if let smtpHost, !smtpHost.isEmpty { body["smtpHost"] = smtpHost }
        return try await post(body, endpoint: endpoint, token: token)
    }

    func removeAccount(id: String, endpoint: URL?, token: String) async throws {
        let _: Ack = try await post(["action": "removeAccount", "id": id], endpoint: endpoint, token: token)
    }

    // MARK: - Reading

    func mailboxes(endpoint: URL?, token: String) async throws -> MailboxesPayload {
        try await get("mailboxes", endpoint: endpoint, token: token)
    }

    /// `cursor` pages backwards — Mail's "load more" as you reach the bottom.
    ///
    /// Deliberately opaque, and issued by the server rather than derived here. All Inboxes spans
    /// several accounts, and an IMAP UID only means something within one mailbox, so a single cursor
    /// has to carry one position *per account*. A date can't do that job: IMAP's BEFORE is
    /// day-granular, which on a busy day pages to the same place forever.
    func messages(
        account: String?,
        mailbox: String?,
        limit: Int,
        cursor: String?,
        search: String?,
        unreadOnly: Bool,
        flaggedOnly: Bool,
        vipOnly: Bool,
        endpoint: URL?,
        token: String
    ) async throws -> MessagesPayload {
        var query: [String: String] = ["limit": String(limit)]
        if let account { query["account"] = account }
        if let mailbox { query["mailbox"] = mailbox }
        if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        if let search, !search.isEmpty { query["search"] = search }
        if unreadOnly { query["unread"] = "1" }
        if flaggedOnly { query["flagged"] = "1" }
        if vipOnly { query["vips"] = "1" }
        return try await get("messages", query, endpoint: endpoint, token: token)
    }

    func message(account: String, mailbox: String, uid: Int, endpoint: URL?, token: String) async throws -> MessagePayload {
        try await get(
            "message",
            ["account": account, "mailbox": mailbox, "uid": String(uid)],
            endpoint: endpoint,
            token: token
        )
    }

    // MARK: - VIP

    struct VipsPayload: Decodable {
        let vips: [String]
    }

    func vips(endpoint: URL?, token: String) async throws -> [String] {
        let payload: VipsPayload = try await get("vips", endpoint: endpoint, token: token)
        return payload.vips
    }

    /// Adds (`set: true`) or removes a sender from the VIP list. The mailbox it belongs to doesn't
    /// matter — a VIP is who the mail came from, not where it sits.
    func setVip(address: String, set: Bool, endpoint: URL?, token: String) async throws {
        let _: Ack = try await post(
            ["action": "vip", "address": address, "set": set],
            endpoint: endpoint,
            token: token
        )
    }

    // MARK: - Acting on messages

    func setFlags(
        account: String,
        mailbox: String,
        uids: [Int],
        seen: Bool?,
        flagged: Bool?,
        endpoint: URL?,
        token: String
    ) async throws {
        var body: [String: Any] = ["action": "flags", "account": account, "mailbox": mailbox, "uids": uids]
        if let seen { body["seen"] = seen }
        if let flagged { body["flagged"] = flagged }
        let _: Ack = try await post(body, endpoint: endpoint, token: token)
    }

    /// Moves rather than deletes. Apple Mail's trash button is a move to the Trash mailbox, and an
    /// IMAP EXPUNGE would be genuinely unrecoverable — the wrong default for a swipe gesture.
    func move(
        account: String,
        mailbox: String,
        uids: [Int],
        to role: String,
        endpoint: URL?,
        token: String
    ) async throws {
        let _: Ack = try await post(
            ["action": "move", "account": account, "mailbox": mailbox, "uids": uids, "to": role],
            endpoint: endpoint,
            token: token
        )
    }

    // MARK: - Writing

    /// Alfred writes the reply; the user always sees it before it goes. Same draft-and-confirm rule
    /// the Telegram flow follows.
    func draftReply(
        account: String,
        mailbox: String,
        uid: Int,
        instruction: String,
        endpoint: URL?,
        token: String
    ) async throws -> DraftPayload {
        try await post(
            [
                "action": "draft",
                "account": account,
                "mailbox": mailbox,
                "uid": uid,
                "instruction": instruction,
            ],
            endpoint: endpoint,
            token: token
        )
    }

    func send(
        account: String,
        to: String,
        cc: String,
        subject: String,
        body: String,
        inReplyTo: String?,
        endpoint: URL?,
        token: String
    ) async throws {
        var payload: [String: Any] = [
            "action": "send",
            "account": account,
            "to": to,
            "subject": subject,
            "body": body,
        ]
        if !cc.isEmpty { payload["cc"] = cc }
        if let inReplyTo { payload["inReplyTo"] = inReplyTo }
        let _: Ack = try await post(payload, endpoint: endpoint, token: token)
    }
}
