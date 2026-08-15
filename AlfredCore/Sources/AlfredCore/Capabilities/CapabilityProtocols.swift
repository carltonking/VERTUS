import Foundation

// MARK: - Platform-agnostic base

/// The base protocol every Alfred capability conforms to. Compiles on macOS
/// and iOS — anything a capability does that touches the OS lives in a
/// capability-specific protocol, and the macOS-only ones (screen capture,
/// accessibility, shell) are declared under `#if os(macOS)` below.
public protocol Capability: Sendable {
    /// Stable identifier used for registration and routing (e.g. "screen").
    var id: String { get }
    /// Human-readable name for settings/UI (e.g. "Screen Capture").
    var displayName: String { get }
    /// True when the capability needs a TCC permission grant (Screen
    /// Recording, Accessibility, …) before it can work.
    var requiresPermission: Bool { get }
}

// MARK: - macOS-only capabilities

/// These protocols reference macOS-only frameworks (ScreenCaptureKit,
/// ApplicationServices, and Foundation's Process-based shell), so they are
/// only declared — and only usable — on macOS. The iOS app never sees them.
#if os(macOS)
import ScreenCaptureKit
import ApplicationServices

/// macOS-only: captures the display. Backed by ScreenCaptureKit.
public protocol ScreenCaptureCapability: Capability {
    /// The capture configuration describing what ScreenCaptureKit should
    /// record (display, quality, frame rate).
    var captureConfiguration: SCStreamConfiguration { get }

    /// Captures the current main-display frame as encoded image data (PNG by
    /// default). Throws when Screen Recording permission is missing or denied.
    func captureScreen() async throws -> Data
}

/// macOS-only: reads the accessibility tree. Backed by the AXUIElement
/// (ApplicationServices) API.
public protocol AccessibilityCapability: Capability {
    /// Whether the app has been granted Accessibility permission (checked via
    /// `AXIsProcessTrusted`).
    var isTrusted: Bool { get }

    /// Serialized accessibility tree of the frontmost app, ready to feed to an
    /// LLM as context. Throws when the app is not trusted.
    func accessibilityTree() async throws -> String
}

/// macOS-only: runs shell commands. Backed by Foundation's `Process`/`Pipe`.
public protocol ShellExecuting: Capability {
    /// Runs `command` in a shell and returns its combined stdout+stderr.
    @discardableResult
    func runShell(_ command: String) async throws -> String
}
#endif
