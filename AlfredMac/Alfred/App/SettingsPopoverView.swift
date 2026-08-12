import AppKit
import SwiftUI

/// What the menu-bar popover shows.
///
/// Settings are deliberately bare now: every capability is on by design and
/// stays on. Alfred can use the screen, the terminal, and the mail watcher
/// without toggles — the only choices are showing the bar, the API key
/// ring, and quitting.
@MainActor
final class SettingsModel: ObservableObject {
    let keys = ProviderKeyRing.shared

    @Published var newKey = ""
    @Published var newKeyLabel = ""
    @Published var newKeyProvider: LLMProvider = .gemini

    /// Cloud or local — the only model choice there is. Switching persists the
    /// choice, writes Hermes' config, and restarts the session so the next turn
    /// runs on the newly selected model world.
    @Published var modelMode: ModelMode {
        didSet {
            guard modelMode != oldValue else { return }
            UserDefaults.standard.set(modelMode.rawValue, forKey: ProviderKeyRing.modelModeKey)
            ProviderKeyRing.shared.applyModelMode(modelMode)
            Task { @MainActor in
                await AppDelegate.shared?.hermes.restart()
            }
        }
    }

    init() {
        modelMode = ProviderKeyRing.persistedModelMode()
    }

    var activeLabel: String {
        guard let key = keys.activeKey else { return "none — using Hermes defaults" }
        return "\(key.provider.displayName): \(key.label)"
    }

    /// One-line summary shown at the right of the MODEL header.
    var modeSummary: String {
        switch modelMode {
        case .cloud:
            return keys.activeKey.map { "\($0.provider.displayName): \($0.label)" }
                ?? "Hermes defaults"
        case .local:
            return LocalModels.brain
        }
    }

    /// The explanatory line under the toggle.
    var modeDetail: String {
        switch modelMode {
        case .cloud:
            return "Uses the API keys below, with automatic fallback across them."
        case .local:
            return "Runs entirely on this Mac through Ollama. alfred-brain decides within each turn which tools and local models to use — no cloud calls, no keys needed."
        }
    }
}

struct SettingsPopoverView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var usage = UsageTracker.shared

    let onShowBar: () -> Void
    let onRelaunch: () -> Void
    let onQuit: () -> Void

    /// Whether the API key rows and the "Add" form are shown. The key ring
    /// collapses to just the "API KEYS" header so the popover stays compact
    /// once everything is configured.
    @State private var isKeysExpanded = false

    /// Lets the "API KEYS" header show it is clickable without restyling the row.
    @State private var isKeysHovering = false

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            Text("Alfred is always on: computer control, terminal access, and "
                 + "mail alerts are enabled.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            modelSection

            Divider()

            keysSection

            Divider()

            HStack {
                Button("Show Alfred", action: onShowBar)
                Text("⌘⇧J")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Relaunch", action: onRelaunch)
                Button("Quit", action: onQuit)
            }
        }
        .padding(14)
        .frame(width: Self.width)
    }

    // MARK: - Model (cloud vs local)

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                Text("MODEL")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.modeSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Picker("Model", selection: $model.modelMode) {
                ForEach(ModelMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.modeDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - API keys

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isKeysExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isKeysExpanded ? 90 : 0))
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 11))
                    Text("API KEYS")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(model.activeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isKeysHovering ? Color.primary.opacity(0.06) : .clear)
            )
            .onHover { hovering in isKeysHovering = hovering }
            .help(isKeysExpanded ? "Collapse the key ring" : "Show the key ring")

            if isKeysExpanded {
                ForEach(model.keys.keys) { key in
                    KeyRow(key: key, onSetActive: { model.keys.setActive(id: key.id) },
                           onRemove: { model.keys.remove(id: key.id) })
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Provider", selection: $model.newKeyProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 11))

                    HStack(spacing: 6) {
                        TextField("Label (optional)", text: $model.newKeyLabel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        TextField("Paste API key", text: $model.newKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button("Add") {
                            model.keys.add(provider: model.newKeyProvider,
                                           label: model.newKeyLabel,
                                           key: model.newKey)
                            model.newKey = ""
                            model.newKeyLabel = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Alfred Settings")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }

    private func color(forPercent percent: Int) -> Color {
        switch percent {
        case ..<20: return .red
        case 20..<50: return .orange
        default: return .green
        }
    }
}

/// One key row: active marker, provider chip, label, usage meter, remove.
private struct KeyRow: View {
    let key: ProviderKey
    let onSetActive: () -> Void
    let onRemove: () -> Void

    private var isActive: Bool { key.id == ProviderKeyRing.shared.activeKeyID }
    private var meter: (percent: Int?, text: String, isEstimate: Bool) {
        UsageTracker.shared.usage(for: key)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSetActive) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .green : .secondary)
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Use this key")

            Text(key.provider.displayName)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(key.provider == .gemini ? Color.green.opacity(0.15)
                          : Color.blue.opacity(0.15))
                .clipShape(Capsule())
                .lineLimit(1)

            Text(key.label)
                .font(.system(size: 11))
                .lineLimit(1)

            Spacer()

            Text(meter.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(meter.percent.map { color(for: $0) } ?? .secondary)
                .frame(minWidth: 52, alignment: .trailing)
                .help(meter.isEstimate
                      ? "Rough estimate from requests + hermes usage today"
                      : "Quota reported by the provider")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this key")
        }
    }

    private func color(for percent: Int) -> Color {
        switch percent {
        case ..<20: return .red
        case 20..<50: return .orange
        default: return .green
        }
    }
}