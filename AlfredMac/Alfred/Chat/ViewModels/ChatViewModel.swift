import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationId: UUID?
    @Published var isStreaming: Bool = false
    
    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationId }
    }
    
    private let llmRouter: LLMRouter
    private var saveTask: Task<Void, Never>?
    private let saveURL: URL
    
    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
        
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport
            .appendingPathComponent("Alfred/Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.saveURL = folder.appendingPathComponent("conversations.json")
        
        loadConversations()
        
        if conversations.isEmpty {
            createConversation()
        }
    }
    
    func createConversation() -> Conversation {
        let conv = Conversation()
        conversations.insert(conv, at: 0)
        selectedConversationId = conv.id
        save()
        return conv
    }
    
    func deleteConversation(id: UUID) {
        conversations.removeAll { $0.id == id }
        if selectedConversationId == id {
            selectedConversationId = conversations.first?.id
        }
        save()
    }
    
    func selectConversation(id: UUID) {
        selectedConversationId = id
    }
    
    func sendMessage(_ text: String, in conversationId: UUID) async {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        
        let userMsg = ChatMessage(role: "user", content: text)
        conversations[idx].messages.append(userMsg)
        conversations[idx].updatedAt = Date()
        save()
        
        let assistantId = UUID()
        let assistantMsg = ChatMessage(id: assistantId, role: "assistant", content: "", isStreaming: true)
        conversations[idx].messages.append(assistantMsg)
        
        let messages = conversations[idx].messages.map(\.llmMessage)
        
        isStreaming = true
        defer { isStreaming = false }
        
        do {
            _ = try await llmRouter.stream(messages: messages, system: "") { [weak self] token in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let cIdx = self.conversations.firstIndex(where: { $0.id == conversationId }),
                       let mIdx = self.conversations[cIdx].messages.firstIndex(where: { $0.id == assistantId }) {
                        self.conversations[cIdx].messages[mIdx].content += token
                    }
                }
            }
            
            if let cIdx = conversations.firstIndex(where: { $0.id == conversationId }),
               let mIdx = conversations[cIdx].messages.firstIndex(where: { $0.id == assistantId }) {
                conversations[cIdx].messages[mIdx].isStreaming = false
                conversations[cIdx].updatedAt = Date()
                
                if conversations[cIdx].title == "New Chat",
                   conversations[cIdx].messages.count >= 2 {
                    conversations[cIdx].title = String(text.prefix(30))
                }
            }
            save()
        } catch {
            if let cIdx = conversations.firstIndex(where: { $0.id == conversationId }),
               let mIdx = conversations[cIdx].messages.firstIndex(where: { $0.id == assistantId }) {
                conversations[cIdx].messages[mIdx].content = "Error: \(error.localizedDescription)"
                conversations[cIdx].messages[mIdx].isStreaming = false
            }
            save()
        }
    }
    
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self, !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(self.conversations)
                try data.write(to: self.saveURL)
            } catch {
                print("Failed to save conversations: \(error)")
            }
        }
    }
    
    private func loadConversations() {
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        do {
            let data = try Data(contentsOf: saveURL)
            conversations = try JSONDecoder().decode([Conversation].self, from: data)
            selectedConversationId = conversations.first?.id
        } catch {
            print("Failed to load conversations: \(error)")
        }
    }
}
