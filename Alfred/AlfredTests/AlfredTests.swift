//
//  AlfredTests.swift
//  AlfredTests
//
//  Created by Carlton King on 8/4/26.
//

import Foundation
import Testing
@testable import Alfred

/// The address field is the one place a user can silently misconfigure the app, and every shape
/// below is something a person plausibly pastes. These run against the shipping normaliser.
@Suite("Endpoint normalisation")
struct EndpointTests {
    private let canonical = "https://alfredassistant.vercel.app/api/app"

    @Test("A bare hostname gets https and the API path")
    func bareHost() {
        #expect(AppSettings.endpoint(forHost: "alfredassistant.vercel.app")?.absoluteString == canonical)
    }

    @Test("Every URL shape of the same deployment resolves identically", arguments: [
        "https://alfredassistant.vercel.app",
        "https://alfredassistant.vercel.app/",
        "https://alfredassistant.vercel.app/api/app",
        "  alfredassistant.vercel.app  ",
        "https://alfredassistant.vercel.app/api/app?x=1",
    ])
    func equivalentShapes(_ input: String) {
        #expect(AppSettings.endpoint(forHost: input)?.absoluteString == canonical)
    }

    @Test("localhost over http is allowed, for running against `vercel dev`")
    func localDevelopment() {
        #expect(AppSettings.endpoint(forHost: "http://localhost:3000")?.absoluteString == "http://localhost:3000/api/app")
    }

    /// Anything unusable must produce nil so the app stays in its "not connected" state rather than
    /// showing a chat box that can only ever fail.
    @Test("Unusable input yields no endpoint", arguments: ["", "   ", "notahost", "ftp://example.com"])
    func rejected(_ input: String) {
        #expect(AppSettings.endpoint(forHost: input) == nil)
    }
}

/// Transcript rows are persisted as JSON, so a change to `Message` that breaks decoding would
/// silently wipe someone's history on next launch.
@Suite("Message persistence")
struct MessageTests {
    @Test("A message survives an encode/decode round trip")
    func roundTrip() throws {
        let original = Message(role: .error, text: "boom", failedPrompt: "what's the weather?")
        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(original))

        #expect(decoded == original)
        #expect(decoded.failedPrompt == "what's the weather?")
    }

    @Test("Retry context is absent on ordinary turns")
    func noRetryContextOnNormalTurns() {
        #expect(Message(role: .user, text: "hi").failedPrompt == nil)
        #expect(Message(role: .alfred, text: "hello").failedPrompt == nil)
    }
}
