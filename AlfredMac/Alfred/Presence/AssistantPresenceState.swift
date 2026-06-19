import Foundation

/// The five states of Alfred's notch presence.
///
/// ```
/// hidden ──→ collapsed ──→ expanded ──→ collapsed
///   │                          │
///   └── (hotkey) ──→ expanded ──┘
///
/// expanded ←→ thinking ←→ responding
/// ```
enum AssistantPresenceState: Equatable {
    /// Window is ordered out completely.
    case hidden

    /// 3 px strip just below the menu bar, centered at the notch.
    /// Triggered by cursor entering the top‑center hover zone.
    case collapsed

    /// Full bar with input, streaming response, suggestions.
    /// Triggered by clicking the collapsed strip, or hotkey.
    case expanded

    /// Voice transcription in progress (future).
    case listening

    /// Waiting for LLM response (spun up from expanded when query is sent).
    case thinking

    /// Streaming tokens into the response area.
    case responding

    // MARK: - Queries

    var isVisible: Bool { self != .hidden }

    var isCompact: Bool { self == .collapsed }

    var showsInput: Bool {
        switch self {
        case .expanded, .listening, .thinking, .responding: true
        case .hidden, .collapsed: false
        }
    }
}
