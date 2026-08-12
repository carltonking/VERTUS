import AppKit
import CoreGraphics
import Foundation
import os

// MARK: - Screen monitoring

/// Periodic screen memory: every 45s, capture the screen, OCR it, and store
/// the JPEG + text in `screen_observations` (deduped by content hash inside
/// the store). Runs a 7-day retention prune hourly.
///
/// The capture path is `UndetectableScreenCapability` (CGDisplayCreateImage) —
/// NOT ScreenCaptureKit — so the persistent loop doesn't register an SCK
/// session that streaming apps can detect. On-demand screen queries keep using
/// SCK (`ScreenCapability`), which is fine for user-initiated captures.
///
/// The timer fires on the main run loop and hands each tick to a detached
/// Task, so capture/OCR/store never block the UI. A tick is guarded against
/// overlap, and every failure is logged — a tick never crashes Alfred. If
/// Screen Recording permission is missing, the first tick fails with a clear
/// log and the loop simply keeps trying (repeat logs are throttled so an
/// un-granted permission or an idle/blank screen can't spam the log).
final class ScreenMonitoringManager {

    static let shared = ScreenMonitoringManager()

    private static let tickInterval: TimeInterval = 45
    private static let pruneInterval: TimeInterval = 3600
    private static let retentionDays: TimeInterval = 7
    private static let maxStoredLongEdge = 1280
    private static let quietLogEvery = 20

    private enum MonitorError: LocalizedError {
        case captureUnavailable
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .captureUnavailable:
                return "screen capture unavailable — grant Alfred Screen Recording permission in System Settings"
            case .encodeFailed:
                return "could not encode captured frame as JPEG"
            }
        }
    }

    private struct State {
        var isTicking = false
        var lastPrune: Date?
        var consecutiveFailures = 0
        var noTextCount = 0
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private var timer: Timer?

    private init() {}

    // MARK: - Lifecycle

    /// Begin periodic captures. Idempotent — safe to call on every launch.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSLog("[screenmonitor] started (capture every %.0fs)", Self.tickInterval)
    }

    /// Cancel the timer and clear in-memory context. Safe to call repeatedly.
    func stop() {
        timer?.invalidate()
        timer = nil
        stateLock.withLock { state in
            state.isTicking = false
            state.lastPrune = nil
            state.consecutiveFailures = 0
            state.noTextCount = 0
        }
        // Quitting loses at most the last few minutes of usage counts.
        ActivityObserver.shared.persist()
    }

    // MARK: - Tick

    /// One capture → OCR → store pass. Never throws; a failed pass is logged
    /// and the next tick proceeds normally. Prune runs every tick regardless
    /// of whether this tick stored anything, so retention never stalls.
    func tick() async {
        // Claim the single capture slot atomically — a slow tick must not
        // overlap the next one.
        let claimed = stateLock.withLock { state -> Bool in
            guard !state.isTicking else { return false }
            state.isTicking = true
            return true
        }
        guard claimed else { return }
        defer { stateLock.withLock { state in state.isTicking = false } }

        do {
            // CGDisplayCreateImage — not SCK — so the loop runs undetected.
            guard let image = UndetectableScreenCapability.captureMainDisplay() else {
                throw MonitorError.captureUnavailable
            }
            stateLock.withLock { state in state.consecutiveFailures = 0 }

            // Downscaled to a 1280px long edge so a stored frame is the ~100 KB
            // the storage budget assumes; width/height always match the image.
            guard let encoded = Self.encodeJPEG(image, maxLongEdge: Self.maxStoredLongEdge) else {
                throw MonitorError.encodeFailed
            }

            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"

            // Passive behavior learning: which app was frontmost, at what time —
            // nothing content-shaped. Independent of OCR/insert success, so a
            // blank screen still counts as "using that app at this hour".
            ActivityObserver.shared.recordObservation(
                appBundleID: bundleID,
                timestamp: Date().timeIntervalSince1970)

            if let ocr = ScreenOCRCapability.recognizeText(inImageData: encoded.data) {
                try ScreenObservationStore.shared.insert(
                    capturedAt: Date().timeIntervalSince1970,
                    appBundleID: bundleID,
                    jpegData: encoded.data,
                    ocrText: ocr.text,
                    ocrConfidence: ocr.confidence,
                    width: encoded.width,
                    height: encoded.height)
                stateLock.withLock { state in state.noTextCount = 0 }
            } else {
                // No text on screen (blank/photo-only frame) is normal —
                // a throttled note, not a failure.
                logNoText()
            }
        } catch {
            logFailure(error.localizedDescription)
        }

        pruneIfDue()
    }

    // MARK: - JPEG encoding

    /// Downscale + JPEG-encode a captured frame, reusing ScreenCapability's
    /// own encoding helpers so there is exactly one implementation.
    private static func encodeJPEG(_ image: CGImage,
                                   maxLongEdge: Int) -> (data: Data, width: Int, height: Int)? {
        let resized = ScreenCapability.downscaled(image, maxLongEdge: maxLongEdge) ?? image
        guard let data = try? ScreenCapability.jpegData(from: resized) else { return nil }
        return (data, resized.width, resized.height)
    }

    // MARK: - Retention

    /// Prune once an hour (first tick prunes immediately, which is a cheap
    /// no-op on a fresh store). Best-effort — failures are logged.
    private func pruneIfDue() {
        let now = Date()
        let due = stateLock.withLock { state -> Bool in
            if let last = state.lastPrune, now.timeIntervalSince(last) < Self.pruneInterval {
                return false
            }
            state.lastPrune = now
            return true
        }
        guard due else { return }

        do {
            try ScreenObservationStore.shared.prune(retentionDays: Self.retentionDays)
        } catch {
            NSLog("[screenmonitor] prune failed: %@", error.localizedDescription)
        }
    }

    private func logFailure(_ message: String) {
        let count = stateLock.withLock { state -> Int in
            state.consecutiveFailures += 1
            return state.consecutiveFailures
        }
        guard count == 1 || count % Self.quietLogEvery == 0 else { return }
        NSLog("[screenmonitor] tick failed (%d consecutive): %@", count, message)
    }

    private func logNoText() {
        let count = stateLock.withLock { state -> Int in
            state.noTextCount += 1
            return state.noTextCount
        }
        guard count == 1 || count % Self.quietLogEvery == 0 else { return }
        NSLog("[screenmonitor] no text on this frame (%d consecutive) — nothing stored", count)
    }
}
