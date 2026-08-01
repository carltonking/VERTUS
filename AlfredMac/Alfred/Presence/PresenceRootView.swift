import SwiftUI

/// Top-level view that renders the correct SwiftUI content for each presence state.
///
/// States:
///   - hidden     → EmptyView (window is ordered out)
///   - collapsed  → invisible 4 px strip (window is just a thin line, no SwiftUI content)
///   - expanded   → ExpandedPresenceView (350 × variable)
///   - listening  → placeholder (future)
///   - thinking   → ExpandedPresenceView with loading state
///   - responding → ExpandedPresenceView with streaming response
struct PresenceRootView: View {
    @Binding var presenceState: AssistantPresenceState
    @ObservedObject var barState: BarState
    let activeProject: String?
    let contextLabel: String
    let contextStatus: String
    let onSubmit: (String) -> Void
    let onSuggestionTap: (ProactiveSuggestion) -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        switch presenceState {
        case .hidden:
            EmptyView()

        case .collapsed:
            Color.clear
                .frame(height: 4)

        case .expanded, .thinking, .responding:
            ExpandedPresenceView(
                responseText: $barState.responseText,
                isProcessing: $barState.isProcessing,
                suggestions: $barState.suggestions,
                pendingConfirmation: $barState.pendingConfirmation,
                activeProject: activeProject,
                contextLabel: contextLabel,
                contextStatus: contextStatus,
                focusToken: barState.focusToken,
                onSubmit: onSubmit,
                onSuggestionTap: onSuggestionTap,
                onEscape: onCollapse
            )
            .transition(.opacity)

        case .listening:
            listeningPlaceholder
                .transition(.opacity)
        }
    }

    // MARK: - Listening placeholder (future voice mode)

    private var listeningPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.6))

            Text("Listening…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 320, height: 120)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.black.opacity(0.78))
        )
    }
}
