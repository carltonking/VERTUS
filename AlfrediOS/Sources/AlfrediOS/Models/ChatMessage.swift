import Foundation

/// UI-level chat message. Roles mirror the `LLMMessage` roles used by
/// AlfredCore ("user" / "assistant" / "system").
struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: String
    var content: String
    let date = Date()

    init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    var isUser: Bool { role == "user" }
}
