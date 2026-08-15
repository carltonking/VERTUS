import AppKit
import SwiftUI

/// What the menu-bar popover shows.
///
/// Deliberately small: the one setting that matters from the menu bar — which
/// model world Alfred answers from (cloud keys vs the Ollama models on this
/// Mac) — plus relaunch and quit. Every capability stays on by design.
@MainActor
struct SettingsPopoverView: View {
    let onRelaunch: () -> Void
    let onQuit: () -> Void
    /// Called when the user flips cloud/local. The app persists the choice,
    /// applies it to Hermes' config and respawns the session so the next turn
    /// runs under the new world.
    let onApplyModelMode: (ModelMode) -> Void

    /// The provider key ring, observed so the "which model" line follows the
    /// active key.
    @ObservedObject private var keyRing = ProviderKeyRing.shared

    /// Cloud vs local. Seeded from the persisted choice; the hosting
    /// controller is rebuilt every time the popover opens, so this always
    /// reflects the saved mode even when the companion app changed it.
    @State private var modelMode = ProviderKeyRing.persistedModelMode()

    static let width: CGFloat = 250

    /// How tall the scrollable settings region may grow before it scrolls.
    /// The rest of the popover (header is part of the scroll; the action row
    /// stays pinned) is fixed, so the popover keeps one stable size no matter
    /// how many settings or how long the model lines get — a tall popover
    /// would otherwise overrun short screens from the menu bar.
    static let scrollableMaxHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Alfred")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Picker("Model mode", selection: $modelMode) {
                            ForEach(ModelMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: modelMode) { _, mode in
                            onApplyModelMode(mode)
                        }

                        HStack(spacing: 5) {
                            Image(systemName: modelMode == .local ? "desktopcomputer" : "icloud")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(modelDetail.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if !modelDetail.subtitle.isEmpty {
                            // Wraps freely — the scroll region guarantees it is
                            // never clipped, so long fallback chains read whole.
                            Text(modelDetail.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: Self.scrollableMaxHeight)

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

    /// What's actually answering right now, per mode: the local brain for
    /// local mode, the active key's provider + model for cloud mode.
    private var modelDetail: (title: String, subtitle: String) {
        switch modelMode {
        case .local:
            return (
                "Ollama · \(LocalModels.brain)",
                "also on tap: \(LocalModels.vision) · \(LocalModels.reasoning) · \(LocalModels.small)"
            )
        case .cloud:
            guard let active = keyRing.activeKey else {
                return ("Auto · free-tier chain", "No API keys stored yet — add keys in Alfred Mac settings")
            }
            let fallbacks = keyRing.providers.filter { $0 != active.provider }
            let subtitle = fallbacks.isEmpty
                ? "no keyed fallbacks — FreeLLM pool as safety net"
                : "fallback: " + fallbacks.map(\.displayName).joined(separator: ", ")
            return ("\(active.provider.displayName) · \(active.provider.defaultFreeModel)", subtitle)
        }
    }
}
