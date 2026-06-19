import Foundation

final class PrivacyManager: ObservableObject {
    @Published var mode: PrivacyMode {
        didSet { applyModeConstraints() }
    }

    @Published var behavioralLearningEnabled: Bool
    @Published var projectAwarenessEnabled: Bool
    @Published var personalContextEnabled: Bool
    @Published var screenMonitoringEnabled: Bool
    @Published var proactiveSuggestionsEnabled: Bool

    init(mode: PrivacyMode = .standard) {
        self.mode = mode
        self.behavioralLearningEnabled = true
        self.projectAwarenessEnabled = true
        self.personalContextEnabled = true
        self.screenMonitoringEnabled = false
        self.proactiveSuggestionsEnabled = false
        applyModeConstraints()
    }

    func setMode(_ newMode: PrivacyMode) {
        mode = newMode
    }

    private func applyModeConstraints() {
        switch mode {
        case .minimal:
            behavioralLearningEnabled = false
            projectAwarenessEnabled = false
            personalContextEnabled = false
            screenMonitoringEnabled = false
            proactiveSuggestionsEnabled = false
        case .standard:
            behavioralLearningEnabled = false
            projectAwarenessEnabled = true
            personalContextEnabled = false
            screenMonitoringEnabled = false
            proactiveSuggestionsEnabled = true
        case .personalized:
            behavioralLearningEnabled = true
            projectAwarenessEnabled = true
            personalContextEnabled = true
            // screenMonitoring and proactiveSuggestions remain at user preference
        }
    }
}
