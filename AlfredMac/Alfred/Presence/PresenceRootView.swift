import SwiftUI

/// Renders the correct content for each presence state.
///
/// States:
///   - hidden     → EmptyView (window is ordered out)
///   - collapsed  → invisible 4 px strip
///   - expanded   → ExpandedPresenceView (350 × variable)
///   - thinking   → ExpandedPresenceView with loading state
///   - responding → ExpandedPresenceView streaming a response
struct PresenceRootView: View {
    @Binding var presenceState: AssistantPresenceState
    @ObservedObject var barState: BarState
    let onSubmit: (String) -> Void
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
                pendingConfirmation: $barState.pendingConfirmation,
                focusToken: barState.focusToken,
                onSubmit: onSubmit,
                onEscape: onCollapse
            )
            .transition(.opacity)

        case .listening:
            // Voice input is Hermes' concern, not the bar's. The state is kept so
            // the enum still matches BarWindow's sizing switch.
            EmptyView()
        }
    }
}
