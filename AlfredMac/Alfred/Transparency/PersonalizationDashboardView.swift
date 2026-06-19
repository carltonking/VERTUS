import SwiftUI

struct SuggestionFactorBar: View {
    let factor: FactorContribution

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(factor.name)
                    .font(.caption)
                Spacer()
                Text("\(Int(round(factor.value * 100)))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(factor.value > 0.4 ? Color.green : factor.value > 0.1 ? Color.orange : Color.gray)
                        .frame(width: geo.size.width * factor.barWidth, height: 6)
                }
            }
            .frame(height: 6)
            Text(factor.description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct WhyThisSuggestionView: View {
    let explanation: SuggestionExplanation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(explanation.suggestion.title)
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderless)
            }

            HStack {
                Text("Confidence")
                    .foregroundStyle(.secondary)
                Text(explanation.confidencePercent)
                    .fontWeight(.semibold)
            }

            row(label: "Source", value: explanation.source)

            Divider()

            Text("Contributing Factors")
                .font(.subheadline)

            ForEach(explanation.factors) { factor in
                SuggestionFactorBar(factor: factor)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

struct PersonalizationDashboardView: View {
    let activeProjects: [Project]
    let topInterests: [String]
    let preferredTypes: [String]
    let recentEvents: [LearningEvent]
    let personalContext: PersonalContext?
    let onShowExplanation: (SuggestionExplanation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personalization Dashboard")
                .font(.headline)

            if let context = personalContext {
                GroupBox("Personal Context") {
                    VStack(alignment: .leading, spacing: 6) {
                        row(label: "Identity", value: context.identitySummary)
                        if !context.currentFocuses.isEmpty {
                            row(label: "Focuses", value: context.currentFocuses.joined(separator: ", "))
                        }
                        if !context.preferredHelpTypes.isEmpty {
                            row(label: "Preferred Help", value: context.preferredHelpTypes.joined(separator: ", "))
                        }
                    }
                }
            }

            GroupBox("Active Projects") {
                if activeProjects.isEmpty {
                    Text("No active projects detected")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(activeProjects.prefix(5)) { project in
                        HStack {
                            Text(project.displayName)
                            Spacer()
                            Text("\(Int(project.confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            GroupBox("Top Interests") {
                if topInterests.isEmpty {
                    Text("No interests learned yet")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(topInterests, id: \.self) { interest in
                        Text(interest)
                            .font(.caption)
                    }
                }
            }

            GroupBox("Recent Learning Signals") {
                if recentEvents.isEmpty {
                    Text("No recent learning activity")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(recentEvents.suffix(10)) { event in
                        HStack {
                            Text(event.type.label)
                                .font(.caption)
                            Spacer()
                            Text(event.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
    }
}
