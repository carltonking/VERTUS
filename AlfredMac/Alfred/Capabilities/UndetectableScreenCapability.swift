import CoreGraphics
import Foundation

// MARK: - Undetectable screen capture

/// Captures the main display via Core Graphics (`CGDisplayCreateImage`) instead
/// of ScreenCaptureKit. SCK registers a capture session that DRM-aware apps can
/// detect and respond to (e.g. streaming sites blacking out protected content);
/// the CG path uses the window server's snapshot API and does not go through
/// SCK, so it avoids that detection.
///
/// Tradeoff: this path still requires the Screen Recording TCC grant — without
/// it `CGDisplayCreateImage` silently returns nil (no permission prompt is
/// shown, nothing is registered). FairPlay-protected content can still be
/// blanked at the window-server level, exactly as SCK captures are.
struct UndetectableScreenCapability {

    private static let quietLogEvery = 20
    private static var consecutiveFailures = 0

    /// The main display's current frame, or nil when capture is unavailable.
    /// The caller owns JPEG-encoding (and downscaling) — this stays a bare
    /// CGImage wrapper. Never throws.
    ///
    /// Failure logs are throttled (1st, then every 20th): the monitoring loop
    /// calls this every 45s, so an un-granted Screen Recording permission must
    /// not produce ~1,920 log lines a day.
    static func captureMainDisplay() -> CGImage? {
        let displayID = CGMainDisplayID()
        guard displayID != 0 else {
            logFailure("no main display")
            return nil
        }
        guard let image = CGDisplayCreateImage(displayID) else {
            logFailure("Screen Recording permission missing?")
            return nil
        }
        consecutiveFailures = 0
        return image
    }

    private static func logFailure(_ detail: String) {
        consecutiveFailures += 1
        guard consecutiveFailures == 1 || consecutiveFailures % Self.quietLogEvery == 0 else { return }
        NSLog("[screen] CGDisplayCreateImage failed — %@ (%d consecutive)", detail, consecutiveFailures)
    }
}
