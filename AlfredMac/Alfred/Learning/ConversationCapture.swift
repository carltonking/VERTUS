import Foundation

// MARK: - Conversation capture

/// One captured user → assistant exchange, the raw material for continuous
/// fine-tuning. Stored locally only; never leaves the Mac.
///
/// `accepted` starts false and flips true on explicit feedback (thumbs-up) or
/// inference (the user follows up rather than rejecting). Only accepted
/// captures feed training, so the model learns what the user actually wanted.
struct ConversationCapture: Codable, Equatable, Identifiable {

    /// Stable identity so feedback can find the exact capture.
    let id: UUID
    /// The user's message, sanitized of secrets before storage.
    var userMessage: String
    /// Alfred's reply, sanitized of secrets before storage.
    var assistantResponse: String
    /// When the exchange happened.
    let timestamp: TimeInterval
    /// True once the user accepted this reply (explicitly or by inference).
    var accepted: Bool
    /// How sure we are it was accepted: 1.0 explicit, 0.7 inferred.
    var confidence: Double
    /// Coarse topic bucket: "coding", "writing", "scheduling", … or "general".
    var topic: String

    init(id: UUID = UUID(),
         userMessage: String,
         assistantResponse: String,
         timestamp: TimeInterval,
         accepted: Bool = false,
         confidence: Double = 0,
         topic: String = "general") {
        self.id = id
        self.userMessage = userMessage
        self.assistantResponse = assistantResponse
        self.timestamp = timestamp
        self.accepted = accepted
        self.confidence = confidence
        self.topic = topic
    }
}
