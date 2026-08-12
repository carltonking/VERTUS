import Foundation

// MARK: - Habit prediction

/// Predicts what the user is about to do from the passively learned behavior
/// profile — which app dominates the current hour, what typically follows it,
/// and the daily rhythm as app chains.
///
/// The model is deliberately a 2-state hourly Markov chain, not anything
/// heavier: `BehaviorProfile.appUsageByHour` tells us which app dominates each
/// hour, so "what comes next" is "whatever dominates the following hour".
/// Everything is pure and deterministic — same profile + same clock → same
/// answer — which keeps it testable and free of model calls.
///
/// Data safety: reads only the aggregated profile (bundle IDs and hour/day
/// buckets). No text, no paths, no individual events.
final class HabitPredictionService {

    static let shared = HabitPredictionService()
    private init() {}

    // MARK: - Conveniences (live profile)

    /// Which app is most likely to be frontmost around this time, with a
    /// confidence equal to its share of that hour's observations.
    func predictNextApp(at date: Date = Date()) -> (bundleID: String, confidence: Double)? {
        Self.predictNextApp(from: ActivityObserver.shared.currentProfile(), at: date)
    }

    /// A one-line prediction for what follows the app the user is in now,
    /// e.g. "After Xcode, you usually open Slack."
    func predictNextAction(currentApp: String, at date: Date = Date()) -> String? {
        Self.predictNextTransition(from: ActivityObserver.shared.currentProfile(), currentApp: currentApp, at: date)?.prediction
    }

    /// The transition with the confidence a tool handler can report: the
    /// successor's share of the following hour's observations (the Markov edge
    /// weight). `bundleID` lets the caller format the successor itself.
    func predictNextTransition(currentApp: String, at date: Date = Date()) -> (prediction: String, bundleID: String, confidence: Double)? {
        Self.predictNextTransition(from: ActivityObserver.shared.currentProfile(), currentApp: currentApp, at: date)
    }

    /// Common app sequences across the day, e.g. [Xcode → Slack → Safari].
    func getHabitChain(length: Int = 3, limit: Int = 6) -> [[String]] {
        Self.habitChains(from: ActivityObserver.shared.currentProfile(), length: length, limit: limit)
    }

    // MARK: - Pure prediction (testable)

    /// The dominant app at a given hour, weighted by how much that app is used
    /// on the same weekday. Confidence is the winner's share of the weighted
    /// score — a quiet hour with one app scores near 1.0, a contested hour
    /// (Xcode 85% vs Slack 60%) splits it.
    ///
    /// Validation (Mon–Fri, 9–10 heavy Xcode): predict at Mon 9:30 →
    /// Xcode with a high share; at 10:45 the hour is shared, so Xcode still
    /// leads but with a visibly lower confidence.
    static func predictNextApp(from profile: BehaviorProfile, at date: Date) -> (bundleID: String, confidence: Double)? {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let weekday = cal.component(.weekday, from: date) - 1  // 1=Sun → 0

        var scored: [(bundleID: String, score: Double)] = []
        var total = 0.0
        for (bundle, hourly) in profile.appUsageByHour {
            guard bundle != ActivityObserver.unknownBundleID else { continue }
            let atHour = hourly.indices.contains(hour) ? Double(hourly[hour]) : 0
            guard atHour > 0 else { continue }
            // Weekday affinity: an app used mostly Mon–Fri gets a boost on
            // weekdays and near-zero weight on the weekend.
            let dayCount = Double(profile.appUsageByDay[bundle]?[safe: weekday] ?? 0) + 1
            let score = atHour * dayCount
            scored.append((bundle, score))
            total += score
        }
        guard let best = scored.max(by: {
            $0.score != $1.score ? $0.score < $1.score : $0.bundleID > $1.bundleID
        }), total > 0 else { return nil }
        return (best.bundleID, best.score / total)
    }

    /// The one-liner: given the user is in `currentApp` around `date`, which
    /// app dominates the next hour? Anchors on the user's own hourly signal —
    /// if the profile shows them in `currentApp` at this hour, the next hour's
    /// dominant app is the prediction. If they're not usually in `currentApp`
    /// at this hour, no prediction (the transition isn't habitual).
    static func predictNextAction(from profile: BehaviorProfile, currentApp: String, at date: Date) -> String? {
        predictNextTransition(from: profile, currentApp: currentApp, at: date)?.prediction
    }

    /// The full transition behind `predictNextAction`: the sentence, the
    /// successor's bundle ID, and a confidence equal to the successor's share
    /// of the following hour's observations — the Markov edge weight.
    static func predictNextTransition(from profile: BehaviorProfile, currentApp: String, at date: Date) -> (prediction: String, bundleID: String, confidence: Double)? {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        guard hour < 23,
              let nowCount = profile.appUsageByHour[currentApp]?[safe: hour], nowCount > 0,
              let successor = dominantApp(in: profile, hour: hour + 1),
              successor != currentApp,
              successor != ActivityObserver.unknownBundleID,
              let succCount = profile.appUsageByHour[successor]?[safe: hour + 1], succCount > 0
        else { return nil }

        let nextHourTotal = profile.appUsageByHour.values.reduce(0) { total, counts in
            total + (counts.indices.contains(hour + 1) ? counts[hour + 1] : 0)
        }
        let confidence = nextHourTotal > 0 ? Double(succCount) / Double(nextHourTotal) : 0
        return (
            "After \(BehaviorProfile.friendlyName(for: currentApp)), you usually open \(BehaviorProfile.friendlyName(for: successor)).",
            successor,
            confidence)
    }

    /// The daily rhythm as app chains: the dominant app per hour, consecutive
    /// repeats collapsed, then slid into windows of `length`.
    static func habitChains(from profile: BehaviorProfile, length: Int = 3, limit: Int = 6) -> [[String]] {
        guard length >= 2 else { return [] }
        var sequence: [String] = []
        for hour in 0..<24 {
            guard let app = dominantApp(in: profile, hour: hour) else { continue }
            if sequence.last != app { sequence.append(app) }
        }
        guard sequence.count >= length else { return [] }

        var chains: [[String]] = []
        var seen = Set<String>()
        for i in 0...(sequence.count - length) {
            let chain = Array(sequence[i..<(i + length)])
            guard !chain.contains(ActivityObserver.unknownBundleID) else { continue }
            let key = chain.joined(separator: "→")
            guard seen.insert(key).inserted else { continue }
            chains.append(chain)
            if chains.count >= limit { break }
        }
        return chains
    }

    /// The app with the most observations in a given hour, excluding the
    /// "unknown" sentinel. Ties resolve alphabetically for determinism.
    static func dominantApp(in profile: BehaviorProfile, hour: Int) -> String? {
        var best: (bundleID: String, count: Int)?
        for (bundle, hourly) in profile.appUsageByHour {
            guard bundle != ActivityObserver.unknownBundleID,
                  hourly.indices.contains(hour), hourly[hour] > 0
            else { continue }
            if let current = best {
                if hourly[hour] > current.count || (hourly[hour] == current.count && bundle < current.bundleID) {
                    best = (bundle, hourly[hour])
                }
            } else {
                best = (bundle, hourly[hour])
            }
        }
        return best?.bundleID
    }
}

// MARK: - Safe indexing

private extension Array {
    /// nil for an out-of-range index instead of a crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
