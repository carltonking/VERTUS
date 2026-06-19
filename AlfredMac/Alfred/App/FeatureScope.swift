import Foundation

/// v1 scope gates.
///
/// `v1_Blueprint.md` deliberately cuts the learning/personalization stack and
/// unrestricted computer control from v1 (deferred to Phase 2/3). These flags
/// quarantine that out-of-scope code so the core execution-engine spine
/// (dispatch → policy → redact → execute → audit) runs clean, without deleting
/// the existing implementations. Flip a flag to `true` to re-enable later.
enum FeatureScope {

    /// Behavioral learning, relationship/reflection memory, habits, reflections,
    /// proactive suggestions, plus the background learning timers/observers.
    /// Blueprint v1: OFF.
    static let learningEnabled = false

    /// Writing-style personalization ONLY (a narrow slice of the learning stack,
    /// independent of `learningEnabled`): record the user's messages on-device to
    /// build a style profile, and inject a short style summary into the prompt so
    /// responses match the user's voice. Recording never leaves the Mac; injection
    /// flows through `LLMRouter.guardEgress` like any other prompt content (redacted +
    /// shown in the Activity log when the active provider is cloud). Blueprint v1
    /// amendment (2026-06-10): personalization brought into scope, cloud-capable.
    static let personalizationEnabled = true

    /// Accessibility-driven computer control (CGEvent mouse/keyboard automation).
    /// Blueprint v1: gated Phase 2 capability, OFF by default.
    static let computerControlEnabled = false
}
