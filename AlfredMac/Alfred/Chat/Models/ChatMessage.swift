import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var role: String
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    
    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }
    
    var llmMessage: LLMMessage {
        switch role {
        case "user":      return .user(content)
        case "assistant": return .assistant(content)
        case "system":    return .system(content)
        default:          return .user(content)
        }
    }
    
    static func from(_ llmMessage: LLMMessage) -> ChatMessage {
        ChatMessage(role: llmMessage.role, content: llmMessage.content)
    }
}
