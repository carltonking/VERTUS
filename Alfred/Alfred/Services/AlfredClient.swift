//
//  AlfredClient.swift
//  Alfred
//
//  The whole network layer: one POST to Alfred's JSON front door (api/app.ts).
//
//      POST /api/app
//      Authorization: Bearer <APP_TOKEN>
//      { "text": "..." }
//      → { "ok": true, "reply": "..." } | { "ok": false, "error": "..." }
//

import Foundation

struct AlfredClient {
    /// The cloud function is capped at 60s (vercel.json). Allow a margin past that so a slow-but-
    /// alive request — Alfred reading the calendar, then calling a model — isn't killed by the phone
    /// a second before the answer lands.
    private static let requestTimeout: TimeInterval = 75

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    enum Failure: LocalizedError {
        case notConfigured
        case macUnreachable
        case unauthorized
        case tokenMissingOnServer
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
            case .macUnreachable:
                // The relay accepted the message but the Mac never claimed it. That is a
                // specific, fixable situation — say so rather than blaming the network.
                return "Your Mac didn't pick that up. Alfred only answers while your Mac is awake and running."
            case .unauthorized:
                return "That token was rejected. Check it in Settings — it has to match APP_TOKEN on the server."
            case .tokenMissingOnServer:
                return "The server has no APP_TOKEN set, so it's refusing every request. Set it in the Vercel project and redeploy."
            case .server(let message):
                return message
            case .http(let code):
                return "Alfred's server answered \(code)."
            case .offline:
                return "No internet connection."
            case .timedOut:
                return "Alfred took too long to answer. He may still be working — try again in a moment."
            case .transport(let message):
                return message
            case .malformedResponse:
                return "Alfred sent something this app couldn't read."
            }
        }
    }

    private struct Reply: Decodable {
        let ok: Bool
        let reply: String?
        let error: String?
    }

    func send(_ text: String, to endpoint: URL?, token: String) async throws -> String {
        guard let endpoint, !token.isEmpty else { throw Failure.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])

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
        let decoded = try? JSONDecoder().decode(Reply.self, from: data)

        switch http.statusCode {
        case 200:
            guard let reply = decoded?.reply, decoded?.ok == true else { throw Failure.malformedResponse }
            return reply
        case 202:
            // Queued, but no answer came back before the relay's hold expired.
            throw Failure.macUnreachable
        case 401:
            throw Failure.unauthorized
        case 503:
            throw Failure.tokenMissingOnServer
        default:
            // api/mac.ts deliberately returns its real reason on 500 — surface it rather than
            // flattening every failure into "something went wrong", which is unfixable from a phone.
            if let message = decoded?.error, !message.isEmpty { throw Failure.server(message) }
            throw Failure.http(http.statusCode)
        }
    }

    /// Settings' "Test connection".
    ///
    /// Sends a real message rather than probing a health endpoint, because the
    /// interesting failures are all downstream: the relay can be perfectly healthy
    /// while the Mac is asleep, or awake with Hermes misconfigured. A round trip
    /// proves the address, the token, that the Mac claimed it, and that the local
    /// model answered. It is slow for the same reason — that is the real latency.
    func testConnection(endpoint: URL?, token: String) async throws -> String {
        try await send("Reply with just: connected", to: endpoint, token: token)
    }
}
