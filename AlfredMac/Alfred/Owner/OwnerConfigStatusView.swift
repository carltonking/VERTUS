import SwiftUI

// MARK: - OwnerConfigStatusView (OCS §13, read-only slice)
//
// A status and inspection surface, deliberately NOT an editor. This package's job is to make the
// configuration observable and restorable; the full field-by-field editor is later work.
//
// Two things it must get right:
//  • Show the owner exactly what the cloud would receive, so the projection is auditable by the
//    person it describes rather than only by an engineer reading a whitelist.
//  • Never render a secret value. Only references are ever stored, so the preview is safe by
//    construction — but the preview is labelled so that stays obvious.

struct OwnerConfigStatusView: View {
    @ObservedObject var appState: AppState

    /// Injected so previews and tests can point at a temporary directory.
    let store: OwnerConfigStore

    @State private var snapshot: OwnerConfigSnapshot?
    @State private var historyRevisions: [Int] = []
    @State private var showConfigPreview = false
    @State private var showProjectionPreview = false
    @State private var restoreTarget: Int?
    @State private var actionMessage: String?

    init(appState: AppState, store: OwnerConfigStore = .shared) {
        self.appState = appState
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OWNER CONFIGURATION")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)

            if !appState.ownerConfigEnabled {
                disabledState
            } else if let snapshot {
                enabledState(snapshot)
            } else {
                notYetCreatedState
            }

            if let actionMessage {
                Text(actionMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: appState.ownerConfigEnabled) { _, _ in refresh() }
        .confirmationDialog(
            restoreTarget.map { "Restore revision \($0)?" } ?? "Restore",
            isPresented: Binding(get: { restoreTarget != nil },
                                 set: { if !$0 { restoreTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore as a new revision") { performRestore() }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: {
            Text("The current configuration is kept in history. Restoring writes a new revision — it never rewinds the counter.")
        }
    }

    // MARK: - States

    private var disabledState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Off — Alfred is using the legacy owner name and persona.",
                  systemImage: "person.crop.circle.badge.questionmark")
                .font(.system(size: 11)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Use owner configuration", isOn: $appState.ownerConfigEnabled)
                .font(.system(size: 12)).toggleStyle(.switch)
            Text("Requires a restart. Alfred will create a configuration from your current name, then ask for the rest.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notYetCreatedState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Enabled, but no configuration exists yet.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.orange).labelStyle(.titleAndIcon)
            Text("Finish onboarding to create one. Until then Alfred falls back to the legacy persona.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(store.paths.configFile.path)
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func enabledState(_ snapshot: OwnerConfigSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            validationRow(snapshot.validation)

            VStack(alignment: .leading, spacing: 3) {
                infoRow("Revision", "\(snapshot.revision)")
                infoRow("Config ID", String(snapshot.configId.uuidString.prefix(8)))
                infoRow("Schema", "v\(snapshot.config.schemaVersion)")
                infoRow("Updated", Self.timestamp.string(from: snapshot.config.updatedAt)
                        + " · " + snapshot.config.updatedBy.rawValue)
                infoRow("Template", "v\(PersonaTemplate.templateVersion)")
                if restartRequired {
                    infoRow("Restart", "needed to apply the feature switch", tint: .orange)
                }
            }

            Text(store.paths.configFile.path)
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)

            HStack(spacing: 8) {
                Button(showConfigPreview ? "Hide configuration" : "View configuration") {
                    showConfigPreview.toggle()
                }.controlSize(.small)
                Button(showProjectionPreview ? "Hide cloud preview" : "What the cloud sees") {
                    showProjectionPreview.toggle()
                }.controlSize(.small)
            }

            if showConfigPreview { preview(store.configurationPreview(), label: "Configuration") }
            if showProjectionPreview {
                preview(store.projectionPreview(),
                        label: "Cloud projection — this is the ONLY configuration the cloud assistant receives")
            }

            if !historyRevisions.isEmpty { historySection }
        }
    }

    // MARK: - Pieces

    private func validationRow(_ validation: OwnerConfigValidation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if validation.isValid && validation.warnings.isEmpty {
                Label("Valid", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11)).foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else if validation.isValid {
                Label("Valid — \(validation.warnings.count) note\(validation.warnings.count == 1 ? "" : "s")",
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            } else {
                Label("\(validation.errors.count) problem\(validation.errors.count == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange).labelStyle(.titleAndIcon)
            }
            // Show field paths and explanations — never the offending values.
            ForEach(Array((validation.errors + validation.warnings).prefix(4).enumerated()), id: \.offset) { _, issue in
                Text("\(issue.path) — \(issue.message)")
                    .font(.system(size: 10))
                    .foregroundStyle(issue.severity == .error ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !validation.disabledFeatures.isEmpty {
                Text("Disabled until fixed: "
                     + validation.disabledFeatures.map(\.rawValue).sorted().joined(separator: ", "))
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 2)
            Text("History").font(.system(size: 11, weight: .semibold))
            ForEach(historyRevisions.prefix(8), id: \.self) { revision in
                HStack {
                    Text("Revision \(revision)").font(.system(size: 11))
                    Spacer()
                    Button("Restore") { restoreTarget = revision }
                        .controlSize(.small).buttonStyle(.plain)
                        .foregroundStyle(.tint).font(.system(size: 11))
                }
            }
        }
    }

    private func preview(_ text: String?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text ?? "(unavailable)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Secret values are never stored in the configuration — only references to the Keychain or environment.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    /// The flag is read once at launch, so toggling it needs a restart to take effect.
    private var restartRequired: Bool {
        appState.ownerConfigEnabled && AppDelegate.shared?.ownerConfigStore == nil
    }

    private func refresh() {
        guard appState.ownerConfigEnabled else {
            snapshot = nil
            historyRevisions = []
            return
        }
        snapshot = store.reload()
        historyRevisions = store.historyRevisions()
    }

    private func performRestore() {
        guard let revision = restoreTarget else { return }
        restoreTarget = nil
        do {
            let result = try store.restore(revision: revision)
            actionMessage = "Restored revision \(revision) as revision \(result.snapshot.revision)."
            refresh()
        } catch {
            actionMessage = "Couldn't restore: \(error.localizedDescription)"
        }
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
