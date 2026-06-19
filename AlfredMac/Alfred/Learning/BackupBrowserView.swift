import SwiftUI

struct BackupBrowserView: View {
    let backupService: MemoryBackupService
    @State private var backups: [BackupMetadata] = []
    @State private var selectedBackup: BackupMetadata?
    @State private var showRestoreConfirm = false
    @State private var restoreTarget: BackupMetadata?
    @State private var showMergeOptions = false
    @State private var mergeTarget: BackupMetadata?
    @State private var mergeStrategy: MergeStrategy = .replace
    @State private var statusMessage: String?
    @State private var isStatusError = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if let msg = statusMessage {
                HStack {
                    Image(systemName: isStatusError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(isStatusError ? .red : .green)
                    Text(msg)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { statusMessage = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(isStatusError ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
            }

          header
            Divider()
            backupList
            Divider()
            actionBar
        }
        .frame(width: 680, height: 420)
        .onAppear(perform: reloadBackups)
    }

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.clock")
                .foregroundStyle(.secondary)
            Text("Backup Manager")
                .font(.headline)
            Spacer()
            Text("\(backups.count) backup(s)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var backupList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(backups) { backup in
                    BackupRow(
                        backup: backup,
                        isSelected: selectedBackup?.id == backup.id,
                        onSelect: { selectedBackup = backup },
                        byteFormatter: byteFormatter,
                        dateFormatter: dateFormatter
                    )
                }

                if backups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No backups found")
                            .foregroundStyle(.secondary)
                        Text("Create a backup from the dashboard or menu")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 60)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var actionBar: some View {
        HStack {
            if let backup = restoreTarget ?? selectedBackup {
                Text("Selected: \(backup.filename)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a backup to manage")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Reveal in Finder") {
                revealInFinder()
            }
            .disabled(selectedBackup == nil)

            Button("Delete") {
                deleteSelected()
            }
            .foregroundColor(.red)
            .disabled(selectedBackup == nil)

            Button("Restore…") {
                showMergeOptions = true
            }
            .disabled(selectedBackup == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Restore from Backup",
            isPresented: $showMergeOptions,
            titleVisibility: .visible
        ) {
            Button("Replace – Delete current data and restore backup") {
                performRestore(strategy: .replace)
            }
            Button("Merge – Combine backup with existing data") {
                performRestore(strategy: .merge)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let target = selectedBackup {
                Text("Restore backup from \(dateFormatter.string(from: target.createdAt))?\nCurrent memories and reflections will be merged or replaced.")
            }
        }
    }

    private func reloadBackups() {
        backups = backupService.listBackups()
    }

    private func revealInFinder() {
        guard let backup = selectedBackup else { return }
        let fileURL = backupService.backupDirectory.appending(path: backup.filename, directoryHint: .notDirectory)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func deleteSelected() {
        guard let backup = selectedBackup else { return }
        backupService.deleteBackup(filename: backup.filename)
        selectedBackup = nil
        reloadBackups()
        statusMessage = nil
    }

    private func performRestore(strategy: MergeStrategy) {
        guard let backup = selectedBackup else { return }
        let fileURL = backupService.backupDirectory.appending(path: backup.filename, directoryHint: .notDirectory)

        switch strategy {
        case .replace:
            let success = backupService.restoreFromBackup(url: fileURL)
            statusMessage = success ? "Restore complete: backup loaded successfully" : "Restore failed: unable to load backup"
            isStatusError = !success
        case .merge:
            let result = backupService.mergeFromBackup(url: fileURL, strategy: .merge)
            if let r = result {
                statusMessage = "Merge complete: \(r.addedCount) added, \(r.updatedCount) updated, \(r.skippedCount) skipped"
                isStatusError = false
            } else {
                statusMessage = "Merge failed: unable to process backup"
                isStatusError = true
            }
        }
        reloadBackups()
    }
}

// MARK: - Backup Row

private struct BackupRow: View {
    let backup: BackupMetadata
    let isSelected: Bool
    let onSelect: () -> Void
    let byteFormatter: ByteCountFormatter
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: backup.encrypted ? "lock.shield" : "doc")
                .foregroundStyle(backup.encrypted ? .green : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(backup.filename)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                Text(dateFormatter.string(from: backup.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(byteFormatter.string(fromByteCount: backup.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60)

            if backup.encrypted {
                Text("Encrypted")
                    .font(.caption.bold())
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(4)
                    .frame(width: 80)
            } else {
                Text("Plain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60)
            }

            Text("\(backup.memoryCount) mem")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50)

            Text("\(backup.reflectionCount) ref")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50)

            Text("v\(backup.version)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 28)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
