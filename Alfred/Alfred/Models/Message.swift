//
//  Message.swift
//  Alfred
//

import Foundation

/// One turn in the conversation.
///
/// `failedPrompt` is carried on `.error` rows only: when a send fails the user's text has already
/// been committed to the transcript, so retry needs to know what to re-send without the user
/// having to retype it.
struct Message: Identifiable, Codable, Hashable {
    enum Role: String, Codable {
        case user
        case alfred
        case error
    }

    let id: UUID
    let role: Role
    var text: String
    let date: Date
    var failedPrompt: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        date: Date = Date(),
        failedPrompt: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.failedPrompt = failedPrompt
    }
}
