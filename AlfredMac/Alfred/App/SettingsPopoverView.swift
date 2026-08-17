import AppKit
import SwiftUI

/// What the menu-bar popover shows.
///
/// Deliberately small: the menu-bar settings surface keeps only the
/// relaunch/quit actions. The Mac settings window stays minimal.
@MainActor
struct SettingsPopoverView: View {
    let onRelaunch: () -> Void
    let onQuit: () -> Void

    static let width: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Alfred")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
            }
            .padding(14)

            Divider()

            HStack {
                Button("Relaunch", action: onRelaunch)
                Spacer()
                Button("Quit", action: onQuit)
            }
            .padding(14)
        }
        .frame(width: Self.width)
    }
}
