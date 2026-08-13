//
//  MailScanSummaryView.swift
//  Alfred
//
//  The scan header at the top of the mail list — the payoff of the Mac's
//  folder sweep. One glance answers "did I miss anything?": unread and flagged
//  totals, a folder strip to drill into any mailbox, and the two findings the
//  sweep exists for — important mail surfaced even though it's not at the top
//  of the inbox, and important mail that landed in Junk, with a one-tap
//  "Move to Inbox" rescue.
//
//  Everything renders from the Mac's last sweep (MailScanSummaryPayload). The
//  Mac pushes fresh sweeps as `mail.scan_complete`; pull-to-refresh here asks
//  for a live one.
//

import SwiftUI

struct MailScanSummaryView: View {
    @Environment(\.palette) private var palette

    /// Tapping a folder drills the list into it ("By Folder").
    var onOpenFolder: (MailFolderStatPayload) -> Void
    /// Tapping a finding opens that message in the reader.
    var onOpenItem: (MailScanItemPayload) -> Void

    private var store: MacMailStore { .shared }

    @State private var expanded = true
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if expanded, let scan = store.scanSummary {
                if !scan.folders.isEmpty {
                    folderStrip(scan.folders)
                }
                if !scan.spamMiss.isEmpty {
                    sectionLabel("In Junk — worth a look", icon: "exclamationmark.triangle.fill")
                    ForEach(scan.spamMiss) { item in
                        spamRow(item)
                    }
                }
                if !scan.important.isEmpty {
                    sectionLabel("Important", icon: "star.fill")
                    ForEach(scan.important) { item in
                        itemRow(item)
                    }
                }
                if scan.folders.isEmpty && scan.important.isEmpty && scan.spamMiss.isEmpty {
                    waitingRow
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        .task { await store.loadScanSummary() }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accentBright)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email Scan")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                    Text(summaryLine)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if refreshing {
                    ProgressView().controlSize(.small).tint(palette.accentBright)
                } else {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rescan mail")
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textFaint)
            }
        }
        .buttonStyle(.plain)
    }

    private var summaryLine: String {
        guard let scan = store.scanSummary, scan.scannedAt > 0 else {
            return "Waiting for Alfred's first scan…"
        }
        var parts: [String] = []
        if scan.unreadTotal > 0 { parts.append("\(scan.unreadTotal) unread") }
        if scan.flaggedTotal > 0 { parts.append("\(scan.flaggedTotal) flagged") }
        if !scan.spamMiss.isEmpty { parts.append("\(scan.spamMiss.count) in Junk") }
        if parts.isEmpty { return "Inbox zero ✨" }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sections

    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(palette.textFaint)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .padding(.top, 2)
    }

    private func folderStrip(_ folders: [MailFolderStatPayload]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(folders) { folder in
                    Button {
                        onOpenFolder(folder)
                    } label: {
                        HStack(spacing: 5) {
                            Text(folder.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.textPrimary)
                            if folder.unseen > 0 {
                                Text("\(folder.unseen)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(palette.accentBright)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(palette.accent.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.backgroundTop.opacity(0.6))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(palette.surfaceBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 1)
    }

    private func spamRow(_ item: MailScanItemPayload) -> some View {
        HStack(spacing: 10) {
            Button {
                onOpenItem(item)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(item.subject)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                    Text(item.reason.isEmpty ? "\(item.confidencePercent)% important" : "\(item.reason) · \(item.confidencePercent)%")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.accentBright)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Button {
                Task {
                    await store.moveToInbox(item: item)
                    // Drop it from the header so the rescue doesn't re-offer.
                    store.dismissScanItem(id: item.id)
                }
            } label: {
                Label("Inbox", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent.opacity(0.9))
            .accessibilityLabel("Move to Inbox")
        }
        .padding(10)
        .background(palette.danger.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func itemRow(_ item: MailScanItemPayload) -> some View {
        Button {
            onOpenItem(item)
        } label: {
            HStack(spacing: 10) {
                Text(item.initials)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 28, height: 28)
                    .background(palette.accent.opacity(0.16))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(item.subject)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(item.confidencePercent)%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.accentBright)
            }
            .padding(10)
            .background(palette.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var waitingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(palette.accentBright)
            Text("Checking every folder for mail that matters…")
                .font(.system(size: 13))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await store.refreshScan()
    }
}

private extension MailScanItemPayload {
    var initials: String {
        let name = displayName
        let parts = name.split(separator: " ").prefix(2)
        guard !parts.isEmpty else { return "?" }
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
