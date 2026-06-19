import Foundation

struct FactorContribution: Identifiable, Equatable {
    let id: String
    let name: String
    let value: Double
    let description: String

    var barWidth: Double { max(0, min(1, value)) }
}

struct SuggestionExplanation: Identifiable, Equatable {
    let id: String
    let suggestion: ProactiveSuggestion
    let confidence: Double
    let source: String
    let factors: [FactorContribution]

    var confidencePercent: String {
        "\(Int(round(confidence * 100)))%"
    }
}
