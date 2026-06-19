import SwiftUI

struct LearningControlsView: View {
    @ObservedObject var privacyManager: PrivacyManager
    let appState: AppState
    let onForgetProject: (String) -> Void
    let onForgetInterest: (String) -> Void
    let onClearMemory: () -> Void
    let onResetProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy & Learning")
                .font(.headline)

            Picker("Privacy Mode", selection: $privacyManager.mode) {
                ForEach(PrivacyMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading) {
                        Text(mode.label)
                        Text(mode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Divider()

            Text("Feature Toggles")
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Behavioral Learning", isOn: $privacyManager.behavioralLearningEnabled)
                    .disabled(privacyManager.mode != .personalized)
                Toggle("Project Awareness", isOn: $privacyManager.projectAwarenessEnabled)
                    .disabled(privacyManager.mode == .minimal)
                Toggle("Personal Context", isOn: $privacyManager.personalContextEnabled)
                    .disabled(privacyManager.mode != .personalized)
                Toggle("Screen Monitoring", isOn: $privacyManager.screenMonitoringEnabled)
                    .disabled(privacyManager.mode == .minimal)
                Toggle("Proactive Suggestions", isOn: $privacyManager.proactiveSuggestionsEnabled)
                    .disabled(privacyManager.mode == .minimal)
            }

            Divider()

            Text("Forget")
                .font(.subheadline)

            Button("Forget All Learned Interests") {
                onClearMemory()
            }
            .buttonStyle(.bordered)

            Button("Reset Profile to Defaults") {
                onResetProfile()
            }
            .buttonStyle(.bordered)
        }
    }
}
