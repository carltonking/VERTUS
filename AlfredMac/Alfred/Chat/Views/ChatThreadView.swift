import SwiftUI

struct ChatThreadView: View {
    @ObservedObject var viewModel: ChatViewModel
    let conversation: Conversation
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(conversation.messages) { message in
                            ChatMessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: conversation.messages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.isStreaming) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }
            
            ChatInputBar(viewModel: viewModel, conversationId: conversation.id)
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let last = conversation.messages.last else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
