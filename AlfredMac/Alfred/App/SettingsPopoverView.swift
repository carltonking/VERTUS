import AppKit
import SwiftUI

/// What the menu-bar popover shows.
///
/// Deliberately minimal: no settings toggles — every capability is on by
/// design and stays on. The popover exists only to quit or relaunch Alfred.
@MainActor
struct SettingsPopoverView: View {
    let onRelaunch: () -> Void
    let onQuit: () -> Void

    static let width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                Text("Alfred")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            Divider()

            HStack {
                Button("Relaunch", action: onRelaunch)
                Spacer()
                Button("Quit", action: onQuit)
            }
        }
        .padding(14)
        .frame(width: Self.width)
    }
}
