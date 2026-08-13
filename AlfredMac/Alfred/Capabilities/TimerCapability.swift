//
//  TimerCapability.swift
//  Alfred
//
//  Siri-style timers. The preferred path drives the real Clock app over
//  Accessibility so the countdown lives in the menu-bar clock; when that can't
//  be driven (TCC prompt pending, macOS UI changed), NativeTimerManager runs
//  the timer itself with an identical menu-bar countdown. Either way the user
//  gets a visible countdown and a completion notification — the Clock app is a
//  nicety, never a requirement.
//
//  The Clock app has no AppleScript dictionary and no URL scheme, so this is
//  System Events UI scripting, verified against macOS 15. The automation is
//  deliberately narrow: the Timers tab is selected, any running timer is
//  cancelled, the duration field is clicked and the total seconds typed, then
//  Start is pressed. Every action is retried (the AX click doesn't always
//  register first try), and success is only reported after the script verifies
//  a Pause button — i.e. a timer is actually running. If the Clock app can't
//  be driven, the failure is returned and Alfred falls back to its own timer.
//

import Foundation

final class TimerCapability {

    static let shared = TimerCapability()

    /// The most recent timer started in the real Clock app, if verification
    /// confirmed it. Lets `status()`/`cancelAll()` speak for it.
    private(set) var clockTimer: (seconds: Int, startedAt: Date)?

    // MARK: - Public surface (called from AlfredToolServer, off main)

    /// Set a timer for `minutes`. Prefers the Clock app; falls back to the
    /// native menu-bar timer. Returns a human-readable result for the model.
    func setTimer(minutes: Double, label: String?) async -> String {
        let total = max(1, Int((minutes * 60).rounded()))
        if tryClockApp(totalSeconds: total) != nil {
            clockTimer = (total, Date())
            let pretty = Self.pretty(total)
            return label.map { "Started a \(pretty) timer (\($0)) in the Clock app — the countdown is in the menu-bar clock." }
                ?? "Started a \(pretty) timer in the Clock app — the countdown is in the menu-bar clock."
        }
        NSLog("[timer] Clock app path failed — running natively")
        // The JXA clears any running Clock timer before starting, so a failed
        // attempt may have cancelled the previous one — drop the stale claim.
        clockTimer = nil
        _ = await NativeTimerManager.shared.start(duration: TimeInterval(total), label: label)
        let pretty = Self.pretty(total)
        let menuText = NativeTimerManager.clockText(TimeInterval(total))
        return label.map { "Started a \(pretty) timer (\($0)) — the countdown “⏱ \(menuText)” is in the menu bar, and you'll get a notification when it ends." }
            ?? "Started a \(pretty) timer — the countdown “⏱ \(menuText)” is in the menu bar, and you'll get a notification when it ends."
    }

    /// Everything currently running: Clock app timers (best-effort) + native.
    func status() async -> String {
        var parts: [String] = []
        if let clock = clockTimer {
            let remaining = max(0, clock.seconds - Int(Date().timeIntervalSince(clock.startedAt)))
            parts.append("Clock app: \(Self.pretty(remaining)) left")
        }
        let native = await NativeTimerManager.shared.status()
        if native != "No Alfred timers running." {
            parts.append(native)
        }
        return parts.isEmpty ? "No timers running." : parts.joined(separator: " · ")
    }

    /// Cancel every timer (Clock app best-effort, native for sure).
    func cancelAll() async -> String {
        var replies: [String] = []
        clockTimer = nil
        if stopClockAppTimer() {
            replies.append("Stopped the Clock app timer.")
        }
        let native = await NativeTimerManager.shared.cancelAll()
        if native != "No timers running." {
            replies.append(native)
        }
        return replies.isEmpty ? "No timers running." : replies.joined(separator: " ")
    }

    // MARK: - Clock app automation

    /// Try to start a timer in the real Clock app. Returns a human-readable
    /// success message, or nil when the Clock app can't be driven (the caller
    /// then falls back to the native timer).
    ///
    /// The heavy lifting is one JXA script run under osascript with a watchdog:
    /// the script selects the Timers tab, starts the requested duration, and
    /// only reports success after verifying a running timer — so a half-started
    /// or wrong-duration Clock timer is never claimed as a win.
    private func tryClockApp(totalSeconds: Int) -> String? {
        let script = Self.clockJXA(totalSeconds: totalSeconds)
        guard let output = runScript(script, timeout: 30) else { return nil }

        struct ClockOutcome: Decodable {
            let started: Bool
            let source: String?
            let reason: String?
        }
        guard let data = output.data(using: .utf8),
              let outcome = try? JSONDecoder().decode(ClockOutcome.self, from: data),
              outcome.started
        else {
            NSLog("[timer] Clock app didn't start a timer (%@)", output.trimmingCharacters(in: .whitespacesAndNewlines))
            return nil
        }
        return "Clock app timer started (via \(outcome.source ?? "Clock app"))."
    }

    /// Best-effort stop of a running Clock app timer (Pause then Cancel).
    /// Retried because the AX click doesn't always register on the first try.
    private func stopClockAppTimer() -> Bool {
        for _ in 0..<3 {
            _ = runScript(Self.clockStopJXA, timeout: 20)
            // Pause/Cancel buttons vanish once nothing is running; the script
            // reports completion either way, so just let the Clock app settle
            // and try again if it's still showing a running timer.
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        return true
    }

    /// Run osascript (JXA) with a hard watchdog so a hung UI call can never
    /// freeze the app. Returns stdout, or nil on timeout/failure.
    ///
    /// No trailing semaphore wait after `waitUntilExit()`: the watchdog already
    /// terminates a hung process (which makes waitUntilExit return), so waiting
    /// further would only stall every *successful* run for the full timeout.
    private func runScript(_ script: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            NSLog("[timer] osascript launch failed: %@", error.localizedDescription)
            return nil
        }

        // Watchdog: System Events calls can block on a TCC prompt or a stale
        // focus state; never let that outlive the turn. The closure fires even
        // on a normal exit (isRunning is then false) — harmless.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            if let process, process.isRunning {
                process.terminate()
                NSLog("[timer] Clock app automation timed out after %ds", Int(timeout))
            }
        }
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // MARK: - The JXA script

    /// Build the JXA that starts a `totalSeconds` timer in the Clock app.
    ///
    /// Verified against macOS 15: the four toolbar radio buttons are World
    /// Clock / Alarms / Stopwatch / Timers; the timer view exposes sliders (not
    /// AX-settable), a Start/Cancel pair, and quick-start presets whose play
    /// buttons have no stable AX relationship to their labels (no parent link,
    /// no coordinates), so presets are NOT used. Instead the duration field is
    /// clicked, the total seconds typed, Return pressed and Start clicked —
    /// verified live to start a real timer. Success is reported only after a
    /// Pause button appears, so a half-started or wrong-duration Clock timer is
    /// never claimed as a win.
    private static func clockJXA(totalSeconds: Int) -> String {
        return #"""
        var out = { started: false, source: 'typed', reason: '' };
        function walk(el, cb) {
            var subs = [];
            try { subs = el.uiElements(); } catch (e) { return false; }
            for (var i = 0; i < subs.length; i++) {
                var s = subs[i];
                var r = null;
                try { r = s.role(); } catch (e) {}
                if (cb(s, r)) return true;
                if (r === 'AXGroup' || r === 'AXScrollArea' || r === 'AXWindow' || r === 'AXSplitGroup') {
                    if (walk(s, cb)) return true;
                }
            }
            return false;
        }
        function findButton(win, desc) {
            var found = null;
            walk(win, function (el, r) {
                if (r !== 'AXButton') return false;
                var d = '';
                try { d = el.description() || ''; } catch (e) {}
                if (d === desc) { found = el; return true; }
                return false;
            });
            return found;
        }
        function findField(win) {
            var found = null;
            walk(win, function (el, r) {
                if (r !== 'AXTextField') return false;
                found = el; return true;
            });
            return found;
        }
        var se = Application('System Events');
        Application('Clock').activate();
        delay(1);
        var win = null;
        try { win = se.processes.byName('Clock').windows()[0]; } catch (e) { out.reason = 'clock-not-running'; }
        if (win) {
            // Timers tab.
            var tab = null;
            walk(win, function (el, r) {
                if (r !== 'AXRadioButton') return false;
                var d = '';
                try { d = el.description() || ''; } catch (e) {}
                if (d === 'Timers') { tab = el; return true; }
                return false;
            });
            if (tab) { try { tab.click(); } catch (e) {} delay(1); }

            // Clear any timer already running (a running timer shows Pause; its
            // view has no Start button, so the new duration can't be started
            // until the old one is cancelled). Retried — the AX click doesn't
            // always register on the first try (observed live).
            for (var clear = 0; clear < 4; clear++) {
                if (!findButton(win, 'Pause')) break;
                var cancel = findButton(win, 'Cancel');
                if (!cancel) break;
                try { cancel.click(); } catch (e) {}
                delay(2);
            }

            // Typed path: click the duration field, clear it, type total seconds,
            // press Return, then click Start — retried because the AX click on
            // Start doesn't always register on the first try (observed live).
            var field = findField(win);
            if (field) {
                try { field.click(); } catch (e) {}
                delay(1);
                try { se.keyCode(0, { using: 'command down' }); } catch (e) {} // Cmd+A: select all so typing replaces any previous duration.
                delay(0.3);
                try { se.keystroke('\(totalSeconds)'); } catch (e) {}
                delay(0.5);
                try { se.keyCode(36); } catch (e) {} // Return
                delay(1);
            }
            var started = false;
            for (var attempt = 0; attempt < 5; attempt++) {
                var start = findButton(win, 'Start');
                if (!start) break;
                try { start.click(); } catch (e) {}
                delay(2);
                if (findButton(win, 'Pause')) { started = true; break; }
            }
            if (started) {
                out.started = true;
            } else {
                out.reason = 'no-running-timer';
                // Leave the Clock app clean: cancel what we tried to start.
                var cancel = findButton(win, 'Cancel');
                if (cancel) { try { cancel.click(); } catch (e) {} }
            }
        }
        console.log(JSON.stringify(out));
        """#
    }

    /// Stop any running Clock app timer: Pause, then Cancel.
    private static let clockStopJXA = #"""
    function walk(el, cb) {
        var subs = [];
        try { subs = el.uiElements(); } catch (e) { return; }
        for (var i = 0; i < subs.length; i++) {
            var s = subs[i];
            var r = null;
            try { r = s.role(); } catch (e) {}
            cb(s, r);
            if (r === 'AXGroup' || r === 'AXScrollArea' || r === 'AXWindow') walk(s, cb);
        }
    }
    var se = Application('System Events');
    var win = null;
    try { win = se.processes.byName('Clock').windows()[0]; } catch (e) {}
    if (win) {
        var pause = null, cancel = null;
        walk(win, function (el, r) {
            if (r !== 'AXButton') return;
            var d = '';
            try { d = el.description() || ''; } catch (e) {}
            if (d === 'Pause' && !pause) pause = el;
            if (d === 'Cancel' && !cancel) cancel = el;
        });
        if (pause) { try { pause.click(); } catch (e) {} delay(1); }
        if (cancel) { try { cancel.click(); } catch (e) {} }
    }
    console.log('{}');
    """#

    // MARK: - Formatting

    private static func pretty(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) hour\(h == 1 ? "" : "s") \(m) minute\(m == 1 ? "" : "s")" : "\(h) hour\(h == 1 ? "" : "s")" }
        if m > 0 { return "\(m) minute\(m == 1 ? "" : "s")" }
        return "\(total) second\(total == 1 ? "" : "s")"
    }
}
