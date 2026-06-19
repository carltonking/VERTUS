import SwiftUI

struct ChatMessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 4) {
                        Circle().frame(width: 6, height: 6).opacity(0.4)
                        Circle().frame(width: 6, height: 6).opacity(0.4)
                        Circle().frame(width: 6, height: 6).opacity(0.4)
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(
                            message.role == "user"
                                ? Color.accentColor.opacity(0.15)
                                : Color.secondary.opacity(0.1)
                        )
                        .cornerRadius(12)
                }
            }
            
            if message.role == "assistant" {
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}
