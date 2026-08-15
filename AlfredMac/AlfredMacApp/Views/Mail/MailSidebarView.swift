//
//  MailSidebarView.swift
//  AlfredMacApp
//
//  The left pane: where mail lives. Unified Inbox, the two smart folders
//  (Unread, Flagged), then one row per account with its unread badge — the
//  same hierarchy Mail shows, backed by the Mac's accounts over the socket.
//  Ported from the iOS app (Alfred/Alfred/Views/Mail/MailSidebarView.swift).
//
//  Selecting a row only updates `selection`; the list pane observes the scope
//  and reloads. Folder-level navigation beyond the inbox isn't offered because
//  the Mac caches only each account's inbox envelopes.
//

import SwiftUI

struct MailSidebarView: View {
    @Binding var selection: MailSidebarItem
    var onCompose: () -> Void

    @Environment(\.palette) private var palette

    private var store: MacMailStore { .shared }

    var body: some View {
        List {
            Section {
                row(.inbox, icon: "tray.fill", label: "All Inboxes", badge: store.totalUnread)
                row(.unread, icon: "envelope.badge", label: "Unread")
                row(.flagged, icon: "star", label: "Flagged")
            } header: {
                Text("Mailboxes")
            }

            if !store.accounts.isEmpty {
                Section {
                    ForEach(store.accounts) { account in
                        row(.account(account.id), icon: account.icon, label: account.shortLabel, badge: account.unread)
                    }
                } header: {
                    Text("Accounts")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationTitle("Mailboxes")
        .safeAreaInset(edge: .bottom) {
            Button(action: onCompose) {
                Label("New Message", systemImage: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.backgroundTop)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(palette.accentBright)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .task {
            if !store.hasLoaded { await store.load() }
        }
    }

    private func row(_ item: MailSidebarItem, icon: String, label: String, badge: Int? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.accentBright)
                .frame(width: 24)

            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(palette.textPrimary)

            Spacer(minLength: 0)

            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.surfaceBorder.opacity(0.6))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 3)
        .tag(item)
        .listRowBackground(selection == item ? palette.accent.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = item
        }
    }
}
