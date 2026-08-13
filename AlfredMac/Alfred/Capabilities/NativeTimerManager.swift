//
//  NativeTimerManager.swift
//  Alfred
//
//  Alfred's own timers — the guaranteed fallback when the Clock app path
//  (TimerCapability) can't be driven. The countdown shows in the menu bar the
//  same way the Clock app's does (a "⏱ 9:31" status item appears only while a
//  timer runs), and a notification fires when one ends.
//
//  Main-actor isolated: it owns an NSStatusItem and a 1s ticker, both of which
//  belong on the main thread.
//

import AppKit
import UserNotifications

@MainActor
final class NativeTimerManager {

    static let shared = NativeTimerManager()

    struct ActiveTimer {
        let id: UUID
        let label: String?
        let total: TimeInterval
        let endsAt: Date
    }

    private(set) var timers: [ActiveTimer] = []

    private var ticker: Timer?
    private var statusItem: NSStatusItem?

    private init() {}

    // MARK: - Lifecycle

    /// Start a timer that ends `duration` seconds from now. Idempotent wiring:
    /// the status item and ticker appear on the first timer and go away with
    /// the last.
    ///
    /// The completion notification is scheduled NOW (not when the ticker sees
    /// the timer end): UNUserNotificationCenter requests survive app
    /// termination, so the alarm still fires if Alfred is quit or suspended.
    /// cancelAll() removes the pending request, so cancelling stays clean.
    @discardableResult
    func start(duration: TimeInterval, label: String?) -> ActiveTimer {
        let timer = ActiveTimer(
            id: UUID(),
            label: label,
            total: duration,
            endsAt: Date().addingTimeInterval(duration))
        timers.append(timer)
        scheduleCompletionNotification(timer)
        ensureStatusItem()
        ensureTicker()
        NSLog("[timer] native timer started: %@%@",
              Self.pretty(duration),
              label.map { " (“\($0)”)" } ?? "")
        return timer
    }

    /// Stop every running timer, hide the menu-bar item, and remove pending
    /// notifications. Returns a human-readable summary.
    func cancelAll() -> String {
        guard !timers.isEmpty else { return "No timers running." }
        let count = timers.count
        let center = UNUserNotificationCenter.current()
        for t in timers {
            center.removePendingNotificationRequests(withIdentifiers: ["alfred-timer-\(t.id.uuidString)"])
        }
        timers.removeAll()
        teardownStatusItem()
        ticker?.invalidate()
        ticker = nil
        return count == 1
            ? "Timer cancelled."
            : "\(count) timers cancelled."
    }

    /// One line per running timer for the model: label, remaining time.
    func status() -> String {
        guard !timers.isEmpty else { return "No Alfred timers running." }
        let now = Date()
        return timers.map { t in
            let remaining = max(0, t.endsAt.timeIntervalSince(now))
            let name = t.label.map { "“\($0)” " } ?? ""
            return "\(name)\(Self.pretty(remaining)) left"
        }.joined(separator: " · ")
    }

    // MARK: - Ticker

    private func ensureTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = Date()
        var finished: [ActiveTimer] = []
        timers.removeAll { t in
            if t.endsAt <= now { finished.append(t); return true }
            return false
        }
        for t in finished {
            NSLog("[timer] finished: %@", t.label ?? "untitled")
        }
        updateStatusItem()
        if timers.isEmpty {
            ticker?.invalidate()
            ticker = nil
            teardownStatusItem()
        }
    }

    /// Fire the completion notification at `endsAt`. Called once at start so
    /// the system delivers it even if Alfred isn't running at that moment.
    private func scheduleCompletionNotification(_ t: ActiveTimer) {
        let content = UNMutableNotificationContent()
        content.title = t.label.map { "\($0) — timer finished" } ?? "Timer finished"
        content.body = "⏱ Time's up."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(0.5, t.endsAt.timeIntervalSinceNow),
            repeats: false)
        let request = UNNotificationRequest(
            identifier: "alfred-timer-\(t.id.uuidString)",
            content: content,
            trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Menu bar item

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        item.button?.title = Self.pretty(0)
        statusItem = item
        updateStatusItem()
    }

    private func teardownStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func updateStatusItem() {
        guard let statusItem, let button = statusItem.button else { return }
        guard let soonest = timers.min(by: { $0.endsAt < $1.endsAt }) else {
            button.title = ""
            return
        }
        let remaining = max(0, soonest.endsAt.timeIntervalSinceNow)
        button.title = "⏱ \(Self.clockText(remaining))"
    }

    // MARK: - Formatting

    /// "10 minutes" / "1 hour 5 minutes" — for logging and replies.
    static func pretty(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return m > 0 ? "\(h) hour\(h == 1 ? "" : "s") \(m) minute\(m == 1 ? "" : "s")" : "\(h) hour\(h == 1 ? "" : "s")" }
        if m > 0 { return "\(m) minute\(m == 1 ? "" : "s")" }
        return "\(s) second\(s == 1 ? "" : "s")"
    }

    /// "9:31" under an hour, "1:02:03" over — the menu-bar clock format.
    nonisolated static func clockText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
