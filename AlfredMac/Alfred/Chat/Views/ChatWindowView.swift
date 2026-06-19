import SwiftUI

struct ChatWindowView: View {
    @ObservedObject var viewModel: ChatViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Alfred Chat")
                .font(.largeTitle)
            Text("Conversations: \(viewModel.conversations.count)")
                .font(.title2)
            Text("Selected: \(viewModel.selectedConversation?.title ?? "None")")
                .font(.title3)
        }
        .frame(width: 900, height: 700)
        .background(Color.red.opacity(0.3))
    }
}
