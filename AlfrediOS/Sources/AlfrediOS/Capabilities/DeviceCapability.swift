import Foundation
import UIKit
import AlfredCore

/// An iOS-safe capability: reports device info via `UIDevice`. This is the
/// kind of capability the iOS app can hand to an agent — no AppKit, no
/// ScreenCaptureKit, nothing macOS-only. The macOS-only capability protocols
/// in AlfredCore (`ScreenCaptureCapability`, `AccessibilityCapability`,
/// `ShellExecuting`) simply don't exist on iOS.
struct DeviceCapability: Capability {
    let id = "device"
    let displayName = "Device Info"
    let requiresPermission = false

    /// e.g. "iPhone • 18.5" — safe for the agent's context window.
    var summary: String {
        let device = UIDevice.current
        return "\(device.model) • \(device.systemName) \(device.systemVersion)"
    }
}
