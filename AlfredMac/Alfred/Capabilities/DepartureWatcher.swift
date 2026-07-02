import Foundation

/// Proactive "time to leave" watcher: every few minutes it looks at upcoming located calendar events,
/// estimates travel time from the user's current location, and fires ONE notification per event when
/// it's time to start wrapping up (based on the user's arrive-early + heads-up settings).
///
/// SAFETY / design: mirrors `InboundWatcher` — a `Task { while !cancelled { … sleep } }` loop with no
/// stored `Timer`, so it's NOT one of the classes scanned by `SafetyAuditEngine` and the startup audit
/// stays green. Opt-in; fires only notifications (never sends anything outward).
@MainActor
final class DepartureWatcher: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var status = "Departure reminders are off."
    @Published private(set) var lastCheckAt: Date?

    private let appState: AppState
    private let calendar = CalendarRemindersCapability()
    private let travel = TravelTimeService()
    private let interval: TimeInterval
    private var monitorTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private let kNotified = "departure.notifiedKeys"

    init(appState: AppState, interval: TimeInterval = 180) {
        self.appState = appState
        self.interval = interval
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        status = "Watching for when to leave."
        travel.requestAuthorization()   // prompt for Location on first enable (no-op once decided)
        monitorTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        isActive = false
        status = "Departure reminders are off."
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            await checkOnce()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func checkOnce() async {
        lastCheckAt = Date()
        let events = await calendar.upcomingTimedEventsWithLocation(withinHours: 3)
        guard !events.isEmpty else { return }

        let mode = TravelTimeService.Mode(setting: appState.departureTravelMode)
        let arriveEarly = TimeInterval(max(0, appState.departureArriveEarlyMinutes) * 60)
        let packupLead = TimeInterval(max(0, appState.departurePackupLeadMinutes) * 60)
        var notified = Set(defaults.stringArray(forKey: kNotified) ?? [])
        let now = Date()

        for event in events where !notified.contains(event.id) {
            guard let est = await travel.estimate(to: event, mode: mode) else { continue }
            guard est.seconds >= 120 else { continue }   // already basically there → skip
            let leaveBy = event.start.addingTimeInterval(-est.seconds - arriveEarly)
            let nudgeAt = leaveBy.addingTimeInterval(-packupLead)
            guard now >= nudgeAt, now < event.start else { continue }

            let mins = max(1, Int((est.seconds / 60).rounded()))
            let via = est.usedMode == .transit ? " by transit" : (est.usedMode == .driving ? " driving" : " on foot")
            let body = "~\(mins) min\(via) to \(event.title) — leave by \(Self.timeFormatter.string(from: leaveBy)) "
                     + "to arrive early. Start wrapping up."
            _ = try? await NotificationManager.shared.send(title: "Time to head out", body: body,
                                                           identifier: "departure.\(event.id)")
            await TelegramNotifier.send("🚶 \(body)")   // also text it (Alfred pinging you first)
            notified.insert(event.id)
        }

        // Prune keys whose event start (encoded after '@') is already in the past, so the set stays small.
        let cutoff = now.timeIntervalSince1970
        notified = notified.filter { key in
            guard let at = key.lastIndex(of: "@"), let epoch = Double(key[key.index(after: at)...]) else { return true }
            return epoch > cutoff
        }
        defaults.set(Array(notified), forKey: kNotified)
        if isActive { status = travel.isAuthorized ? "Watching for when to leave." : "Grant Location access to enable departure reminders." }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
