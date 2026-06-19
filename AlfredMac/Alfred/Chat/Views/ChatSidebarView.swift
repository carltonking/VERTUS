import SwiftUI

struct ChatSidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    
    var body: some View {
        List(selection: $viewModel.selectedConversationId) {
            ForEach(viewModel.conversations) { conversation in
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(conversation.updatedAt, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .tag(conversation.id)
                .contextMenu {
                    Button(role: .destructive) {
                        viewModel.deleteConversation(id: conversation.id)
                    } label: {
                        Text("Delete")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack {
                Button {
                    viewModel.createConversation()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
            }
            .padding()
        }
    }
}
