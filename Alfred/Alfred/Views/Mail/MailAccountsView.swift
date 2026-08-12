//
//  MailAccountsView.swift
//  Alfred
//
//  Adding and removing mailboxes, laid out like iOS's own "Add Account": pick who it's with, then
//  hand over an address and an app-specific password.
//
//  The password goes to Alfred's server and never stays on the phone. That's deliberate — the
//  Telegram flow, the morning briefing and this app all have to see the same mailboxes, and
//  credentials that lived only on the handset would leave Alfred blind everywhere else.
//

import SafariServices
import SwiftUI

struct MailAccountsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let store: MailStore

    @State private var adding: MailProviderInfo?
    @State private var pickingProvider = false
    @State private var removing: MailAccountInfo?
    @State private var error: String?
    @State private var startingGoogle = false
    @State private var googleURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                List {
                    Section {
                        if store.accounts.isEmpty {
                            Text("No accounts yet.")
                                .font(.system(size: 15))
                                .foregroundStyle(palette.textSecondary)
                        }

                        ForEach(store.accounts) { account in
                            accountRow(account)
                        }
                    } header: {
                        Text("Accounts")
                    } footer: {
                        Text("Accounts marked “On server” are configured in Alfred's deployment environment. They can be changed there, but not from the app.")
                    }

                    Section {
                        Button {
                            Task { await googleSignIn() }
                        } label: {
                            if startingGoogle {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Opening Google…")
                                        .foregroundStyle(palette.textSecondary)
                                }
                            } else {
                                Label("Sign in with Google", systemImage: "globe")
                                    .foregroundStyle(palette.accentBright)
                            }
                        }
                        .disabled(startingGoogle)
                        .accessibilityIdentifier("mail.googleSignIn")
                    } header: {
                        Text("Google")
                    } footer: {
                        Text("Each Google sign-in adds one more email address to Alfred's inbox. No app passwords needed.")
                    }

                    Section {
                        Button {
                            pickingProvider = true
                        } label: {
                            Label("Add Account with app-specific password", systemImage: "plus.circle.fill")
                                .foregroundStyle(palette.accentBright)
                        }
                        .accessibilityIdentifier("mail.addAccount")
                    }

                    if let error {
                        Section { MailErrorRow(text: error) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Mail Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Add Account", isPresented: $pickingProvider, titleVisibility: .visible) {
                ForEach(store.providers.filter { !$0.oauth }) { provider in
                    Button(provider.name) { adding = provider }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $adding) { provider in
                AddMailAccountView(store: store, provider: provider)
            }
            .sheet(
                isPresented: Binding(get: { googleURL != nil }, set: { if !$0 { googleURL = nil } }),
                onDismiss: {
                    // Google redirects back to Alfred's server, which stores the mailbox — a refresh
                    // is all it takes for the new account (or an error, if the sign-in failed) to appear.
                    Task { await store.refresh(settings: settings) }
                }
            ) {
                if let url = googleURL {
                    SafariView(url: url)
                }
            }
            .alert(
                "Remove account?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
            ) {
                Button("Remove", role: .destructive) {
                    if let account = removing { Task { await remove(account) } }
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text("\(removing?.address ?? "") will stop appearing in Alfred. The mailbox itself isn't touched.")
            }
            .task {
                if !store.hasLoaded { await store.refresh(settings: settings) }
            }
        }
    }

    private func accountRow(_ account: MailAccountInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: account.provider))
                .font(.system(size: 17))
                .foregroundStyle(palette.accentBright)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.address)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(account.label)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            }

            Spacer(minLength: 0)

            if !account.removable {
                Text("On server")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.surface)
                    .clipShape(Capsule())
            }
        }
        .swipeActions(edge: .trailing) {
            if account.removable {
                Button(role: .destructive) {
                    removing = account
                } label: {
                    Label("Remove", systemImage: "trash.fill")
                }
            }
        }
    }

    private func icon(for provider: String) -> String {
        store.providers.first { $0.id == provider }?.icon ?? "envelope.fill"
    }

    private func remove(_ account: MailAccountInfo) async {
        removing = nil
        do {
            try await store.removeAccount(account, settings: settings)
            error = nil
        } catch {
            self.error = MailStore.message(for: error)
        }
    }

    private func googleSignIn() async {
        startingGoogle = true
        defer { startingGoogle = false }

        do {
            if let url = try await store.googleLoginURL(settings: settings) {
                googleURL = url
            }
        } catch {
            self.error = MailStore.message(for: error)
        }
    }
}

/// A full in-app browser for the Google consent screen — the same chrome Safari shows, so the
/// "redirecting back to <your address>" hand-off to Alfred's server looks natural.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Adding one

struct AddMailAccountView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let store: MailStore
    let provider: MailProviderInfo

    @State private var address = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var smtpHost = ""
    @State private var isVerifying = false
    @State private var error: String?
    @State private var warning: String?

    private var canSubmit: Bool {
        address.contains("@") && !password.isEmpty && !isVerifying
            && (!provider.needsHostnames || !imapHost.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                Form {
                    Section {
                        TextField("you@\(provider.id == "custom" ? "example.com" : provider.name.lowercased() + ".com")", text: $address)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("account.address")

                        SecureField("App-specific password", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityIdentifier("account.password")
                    } header: {
                        Text(provider.name)
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(provider.passwordHint)
                            if let help = provider.helpUrl, let url = URL(string: help) {
                                Button("Create one") { openURL(url) }
                                    .font(.system(size: 13, weight: .medium))
                            }
                        }
                    }

                    if provider.needsHostnames {
                        Section {
                            TextField("imap.example.com", text: $imapHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(palette.textPrimary)
                            TextField("smtp.example.com (optional)", text: $smtpHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .foregroundStyle(palette.textPrimary)
                        } header: {
                            Text("Servers")
                        } footer: {
                            Text("IMAP on port 993, SMTP on 587. Leave SMTP blank and Alfred will guess it from the IMAP host.")
                        }
                    }

                    if let error {
                        Section { MailErrorRow(text: error) }
                    }

                    if let warning {
                        Section {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add \(provider.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isVerifying {
                        ProgressView()
                    } else {
                        Button("Sign In") { Task { await submit() } }
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("account.submit")
                    }
                }
            }
        }
    }

    /// The server proves the credentials by logging in before it stores them, so a typo fails here
    /// rather than turning into an inbox that's silently always empty.
    private func submit() async {
        isVerifying = true
        defer { isVerifying = false }

        do {
            let warning = try await store.addAccount(
                provider: provider.id,
                address: address.trimmingCharacters(in: .whitespaces),
                password: password,
                label: nil,
                imapHost: imapHost.isEmpty ? nil : imapHost,
                smtpHost: smtpHost.isEmpty ? nil : smtpHost,
                settings: settings
            )
            if let warning {
                self.warning = warning
            } else {
                dismiss()
            }
        } catch {
            self.error = MailStore.message(for: error)
        }
    }
}
