//
//  AccountsCalendarsView.swift
//  Alfred
//
//  The Accounts & Calendars screen, opened from the Calendar tab's toolbar.
//
//  Two halves, matching what iOS itself allows:
//  • Accounts & Calendars — every calendar EventKit can see, grouped by the account it came from
//    (iCloud, Google, Exchange, On My iPhone…), each with a visibility toggle. Accounts
//    themselves are added in iOS Settings, the one place Apple lets that happen.
//  • Subscriptions — feeds (webcal:// or .ics) that Alfred fetches on the backend and mirrors
//    into an EventKit calendar, since iOS has no public API for an app to subscribe to a feed.
//

import SwiftUI
import UIKit

struct AccountsCalendarsView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL

    let store: CalendarStore
    @State private var subscriptions = SubscriptionStore()

    @State private var isAddSheetPresented = false
    @State private var showSettingsHint = false

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    accountsSection
                    subscriptionsSection
                    addAccountSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Calendars & Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { store.refreshCalendars() }
        .sheet(isPresented: $isAddSheetPresented) {
            SubscriptionEditorView(subscriptions: subscriptions, settings: settings) {
                Task { await subscriptions.syncAll(endpoint: settings.endpoint, token: settings.token) }
            }
        }
    }

    // MARK: Accounts

    private var accountsSection: some View {
        Section {
            ForEach(store.accounts) { account in
                accountGroup(account)
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Every calendar on this phone appears here, wherever it came from. Turn one off and it hides from every Alfred view — Home briefing included.")
        }
    }

    private func accountGroup(_ account: CalendarAccount) -> some View {
        Section {
            ForEach(account.calendars) { cal in
                calendarRow(cal)
            }
        } header: {
            Text(account.title)
                .textCase(nil)
                .foregroundStyle(palette.textSecondary)
                .font(.system(size: 14, weight: .semibold))
        }
    }

    private func calendarRow(_ cal: AppCalendar) -> some View {
        let hidden = store.isCalendarHidden(cal.id)
        return HStack(spacing: 12) {
            Circle()
                .fill(cal.colorHex.map { Color(calendarHex: $0) } ?? palette.accent)
                .frame(width: 12, height: 12)

            Text(cal.title)
                .font(.system(size: 16))
                .foregroundStyle(hidden ? palette.textFaint : palette.textPrimary)

            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { !hidden },
                set: { store.setCalendarHidden(cal.id, !$0) }
            ))
            .labelsHidden()
            .tint(palette.accent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cal.title)
        .accessibilityValue(hidden ? "Hidden" : "Visible")
    }

    // MARK: Subscriptions

    private var subscriptionsSection: some View {
        Section {
            if subscriptions.subscriptions.isEmpty {
                Text("No subscriptions yet — add a webcal:// or .ics feed and its events appear here like any other calendar.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textFaint)
                    .padding(.vertical, 4)
            } else {
                ForEach(subscriptions.subscriptions) { sub in
                    subscriptionRow(sub)
                }
                .onDelete { offsets in
                    for index in offsets {
                        subscriptions.remove(subscriptions.subscriptions[index])
                    }
                }
            }

            Button {
                isAddSheetPresented = true
            } label: {
                Label("Add Subscription…", systemImage: "plus")
                    .foregroundStyle(palette.accentBright)
            }

            if !subscriptions.subscriptions.isEmpty {
                Button {
                    Task { await subscriptions.syncAll(endpoint: settings.endpoint, token: settings.token) }
                } label: {
                    HStack {
                        if subscriptions.isSyncingAll {
                            ProgressView()
                                .tint(palette.accent)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(subscriptions.isSyncingAll ? "Syncing…" : "Sync Now")
                    }
                    .foregroundStyle(palette.accentBright)
                }
                .disabled(subscriptions.isSyncingAll)
            }
        } header: {
            Text("Subscriptions")
        } footer: {
            Text("Alfred's server fetches each feed and the app mirrors it into an \"Alfred Subscriptions\" calendar on this phone. Sync pulls the feed fresh; events removed from the feed are removed here.")
        }
    }

    private func subscriptionRow(_ sub: CalendarSubscription) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.name)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.textPrimary)
                Text(sub.url)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            switch subscriptions.syncStates[sub.id] ?? .idle {
            case .idle:
                EmptyView()
            case .syncing:
                ProgressView()
                    .tint(palette.accent)
            case .synced(let date):
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            case .failed(let message):
                Button {
                    Task { await subscriptions.sync(sub, endpoint: settings.endpoint, token: settings.token) }
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(palette.danger)
                }
                .accessibilityLabel("Sync failed: \(message). Tap to retry.")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                subscriptions.remove(sub)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    // MARK: Add account

    private var addAccountSection: some View {
        Section {
            Button {
                showSettingsHint = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.accentBright)
                    Text("Add Account…")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.textPrimary)
                    Spacer(minLength: 0)
                }
            }
        } footer: {
            Text("Accounts are added in iOS Settings — Alfred can't create them itself, but everything you add there appears here automatically.")
        }
        .alert("Add in Settings", isPresented: $showSettingsHint) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iOS only lets accounts be added from Settings → Mail & Calendar → Accounts → Add Account. Do that once, and every calendar it brings (iCloud, Google, Exchange…) shows up in Alfred.")
        }
    }
}

// MARK: - Subscription editor

private struct SubscriptionEditorView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let subscriptions: SubscriptionStore
    let settings: AppSettings
    /// Runs after a successful add, so the new feed is fetched immediately.
    let onAdded: () -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case validating
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    Section {
                        TextField("Name (e.g. School Holidays)", text: $name)
                            .foregroundStyle(palette.textPrimary)
                        TextField("webcal:// or https://…ics", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .foregroundStyle(palette.textPrimary)
                    } header: {
                        Text("Feed")
                    } footer: {
                        Text("A subscription calendar URL — the kind a school, sports team, or public holiday calendar shares. You can usually find it as \"Subscribe\" or \"Copy feed URL\" on the source website.")
                    }

                    if case .failed(let message) = status {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.danger)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                        .disabled(status == .validating)
                }
            }
        }
    }

    private func add() {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmedURL), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "webcal" else {
            status = .failed("That doesn't look like a feed URL. It should start with webcal:// or https://.")
            return
        }

        status = .validating
        subscriptions.add(name: name, url: trimmedURL)
        // The add-sheet hands off to a full sync in the parent view after dismissal.
        onAdded()
        dismiss()
    }
}
