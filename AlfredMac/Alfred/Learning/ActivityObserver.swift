import Foundation

// MARK: - Activity observer

/// Passively learns the user's routine from the screen-observation loop: which
/// app is frontmost at which hour of which weekday, and when the day is
/// active. Aggregates only — never content, URLs, paths or individual events.
///
/// Data safety is structural: the profile stores bundle identifiers, hour/day
/// buckets and (in future) file extensions. Nothing text-shaped ever touches
/// it, and `recordObservation` is O(1) — a few dictionary increments per 45s
/// tick.
///
/// Threading: all mutation runs on a dedicated serial queue. The monitor tick
/// calls in from a background task while prompt building reads a snapshot, so
/// the queue serializes both without holding a spinlock across the work.
final class ActivityObserver {

    static let shared = ActivityObserver()

    private let storageKey = "alfred.behavior_profile"

    /// Flush the profile to UserDefaults every N observations (~15 minutes at
    /// the 45s tick cadence) rather than on every tick — UserDefaults writes
    /// are cheap but pointless 1,920 times a day.
    private let persistEvery = 20

    /// All mutation + snapshot reads. A serial queue, not a lock: the tick
    /// fires every 45s, so sync work here is trivially uncontended.
    private let queue = DispatchQueue(label: "alfred.activity-observer", qos: .utility)

    // MARK: State

    /// Bundle ID → per-hour counts (indices 0–23).
    private var appByHour: [String: [Int]] = [:]
    /// Bundle ID → per-weekday counts (indices 0–6, 0 = Sunday).
    private var appByDay: [String: [Int]] = [:]
    /// Hour → raw total observations across all apps. Source of truth for
    /// `timeOfDayActivity`; also the reconstruction path after a relaunch
    /// (summed back from `appByHour`).
    private var hourTotals: [Int: Int] = [:]
    /// File extension → access count. Stays empty until a file-access source
    /// exists (see `updateFromFileAccess`).
    private var fileTypes: [String: Int] = [:]
    /// Observations since the last persist.
    private var sincePersist = 0
    /// One-time note that the file-access hook fired with no source wired.
    private var fileAccessWarned = false

    private init() {
        if let profile = Self.load() {
            apply(profile)
        }
    }

    // MARK: - Recording

    /// Fold one observation into the aggregates: app frontmost at a timestamp.
    /// O(1) — four dictionary operations, no allocation beyond the calendar
    /// lookup. Safe to call from any thread.
    func recordObservation(appBundleID: String, timestamp: TimeInterval) {
        let date = Date(timeIntervalSince1970: timestamp)
        let hour = Calendar.current.component(.hour, from: date)
        let weekday = Calendar.current.component(.weekday, from: date) - 1  // 1=Sun → 0

        queue.sync {
            // The "unknown" sentinel (no frontmost app — lock screen, app
            // switcher) still counts toward time-of-day activity, but is not
            // a real app: never rank it.
            if !appBundleID.isEmpty, appBundleID != Self.unknownBundleID {
                appByHour[appBundleID, default: Array(repeating: 0, count: 24)][hour] += 1
                appByDay[appBundleID, default: Array(repeating: 0, count: 7)][weekday] += 1
            }
            hourTotals[hour, default: 0] += 1
            sincePersist += 1
            if sincePersist >= persistEvery {
                persistLocked()
            }
        }
    }

    /// The bundle ID the screen monitor uses when no app is frontmost.
    static let unknownBundleID = "unknown"

    /// Record a file-type access attributed to an app. No file-access source is
    /// wired into Alfred yet — the screen monitor captures app + OCR text only,
    /// never paths — so this is a no-op that logs once, kept as the seam a
    /// future file-access watcher calls into. Fabricating extensions here would
    /// violate the profile's data-safety contract.
    func updateFromFileAccess(bundleID: String) {
        queue.sync {
            guard !fileAccessWarned else { return }
            fileAccessWarned = true
            NSLog("[activity] updateFromFileAccess called (bundle %@) but no file-access source is wired — ignored", bundleID)
        }
    }

    // MARK: - Profile

    /// A snapshot of the learned routine for prompt injection or persistence.
    /// Computes top apps, normalizes hourly activity to 0–100, and infers the
    /// work window — all pure math over the raw counts.
    func currentProfile() -> BehaviorProfile {
        queue.sync { profileLocked() }
    }

    /// Build the profile from raw state. Caller must hold the queue — kept
    /// separate from `currentProfile()` so persistence can build the same
    /// snapshot without re-entering the queue (which would deadlock).
    private func profileLocked() -> BehaviorProfile {
        // Ranked totals: sum each app's hourly counts. Deterministic tiebreak
        // on bundle ID — Dictionary iteration order is randomized per process,
        // so equal-count apps would otherwise flip between runs.
        let totals = appByHour.mapValues { $0.reduce(0, +) }
        let top = totals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(20)
            .map { BehaviorProfile.AppUsage(bundleID: $0.key, count: $0.value) }

        // 0–100 scale: the busiest hour is 100, others proportional.
        let peak = hourTotals.values.max() ?? 0
        let activity: [Int: Int] = hourTotals.reduce(into: [:]) { result, pair in
            result[pair.key] = peak > 0 ? Int((Double(pair.value) / Double(peak) * 100).rounded()) : 0
        }

        let hours = Self.detectWorkHours(from: hourTotals)

        return BehaviorProfile(
            appUsageByHour: appByHour,
            appUsageByDay: appByDay,
            topApps: top,
            fileTypesAccessed: fileTypes,
            timeOfDayActivity: activity,
            primaryWorkHours: .init(start: hours.start, end: hours.end))
    }

    // MARK: - Work hours

    /// The user's inferred primary active window from current state.
    /// (0, 0) when there isn't enough signal yet.
    func detectWorkHours() -> (start: Int, end: Int) {
        queue.sync { Self.detectWorkHours(from: hourTotals) }
    }

    /// Infer the primary active window from hourly activity.
    ///
    /// An hour counts as "active" once it carries at least ~15% of the peak
    /// hour's load (and at least 2 observations) — so a couple of late-night
    /// Safari visits don't stretch the workday to 11pm. The longest contiguous
    /// run of active hours wins. Each of the 24 hours is tried as a run start
    /// and walked forward modulo 24, so a night worker's 22:00–02:00 window is
    /// found as a wrap. (0, 0) = not enough signal.
    static func detectWorkHours(from hourTotals: [Int: Int]) -> (start: Int, end: Int) {
        guard let peak = hourTotals.values.max(), peak >= 2 else { return (0, 0) }
        let threshold = max(2, Int(Double(peak) * 0.15))
        let active = (0..<24).map { hourTotals[$0, default: 0] >= threshold }

        var bestStart = -1
        var bestLen = 0
        for start in 0..<24 where active[start] {
            var len = 0
            var hour = start
            while len < 24 && active[hour % 24] {
                len += 1
                hour += 1
            }
            if len > bestLen {
                bestLen = len
                bestStart = start
            }
        }
        guard bestStart >= 0, bestLen >= 1 else { return (0, 0) }
        return (bestStart, (bestStart + bestLen - 1) % 24)
    }

    // MARK: - Lifecycle

    /// Wipe all learned patterns — a privacy reset (or test setup).
    func reset() {
        queue.sync {
            appByHour = [:]
            appByDay = [:]
            hourTotals = [:]
            fileTypes = [:]
            sincePersist = 0
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    /// Flush the current profile to UserDefaults. Called automatically every
    /// `persistEvery` observations and from the monitor's `stop()` so quitting
    /// Alfred never loses the last few minutes of counts.
    func persist() {
        queue.sync { persistLocked() }
    }

    private func persistLocked() {
        guard !appByHour.isEmpty else { return }
        let profile = profileLocked()
        guard let data = try? JSONEncoder().encode(profile) else {
            NSLog("[activity] persist encode failed — keeping in-memory profile")
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
        sincePersist = 0
    }

    /// Rebuild raw state from a saved profile. `hourTotals` is reconstructed
    /// by summing the per-app hour columns, so nothing is lost in the round
    /// trip even though `timeOfDayActivity` persisted normalized.
    private func apply(_ profile: BehaviorProfile) {
        appByHour = profile.appUsageByHour
        appByDay = profile.appUsageByDay
        fileTypes = profile.fileTypesAccessed
        hourTotals = [:]
        for counts in profile.appUsageByHour.values {
            for (hour, count) in counts.enumerated() {
                if count > 0 { hourTotals[hour, default: 0] += count }
            }
        }
        sincePersist = 0
    }

    private static func load() -> BehaviorProfile? {
        guard let data = UserDefaults.standard.data(forKey: "alfred.behavior_profile"),
              let profile = try? JSONDecoder().decode(BehaviorProfile.self, from: data)
        else { return nil }
        return profile
    }
}
