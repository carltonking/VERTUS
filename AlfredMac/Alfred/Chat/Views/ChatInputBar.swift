import SwiftUI

struct ChatInputBar: View {
    @ObservedObject var viewModel: ChatViewModel
    let conversationId: UUID
    
    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            TextField("Message Alfred...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .focused($isFocused)
                .onSubmit { send() }
            
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(text.isEmpty ? .secondary : .accentColor)
            }
            .disabled(text.isEmpty || viewModel.isStreaming)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = ""
        Task {
            await viewModel.sendMessage(trimmed, in: conversationId)
        }
    }
}
