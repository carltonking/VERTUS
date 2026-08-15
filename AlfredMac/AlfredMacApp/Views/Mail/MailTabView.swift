//
//  MailTabView.swift
//  AlfredMacApp
//
//  The Email tab's shell — Apple Mail's three panes, ported from the iOS app
//  (Alfred/Alfred/Views/Mail/MailTabView.swift). The phone toggles between a
//  split view (iPad) and a stack with a sidebar sheet (iPhone); macOS has no
//  compact size class and windows are always wide, so the companion renders
//  the NavigationSplitView — sidebar (mailboxes), content (the list), detail
//  (the reader) — unconditionally.
//
//  The whole tab is Mac-driven (MacMailStore over the socket): this app reads
//  the Mac's cached inbox and sends actions back as mail.* JSON-RPC.
//

import SwiftUI

/// What the sidebar can select. `.account` filters to one account's inbox;
/// `.unread` / `.flagged` are the smart folders over the unified inbox.
enum MailSidebarItem: Hashable {
    case inbox
    case unread
    case flagged
    case account(String)
}

struct MailTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    @State private var sidebarItem: MailSidebarItem = .inbox
    @State private var selectedMessage: MacMailMessage?
    @State private var showingCompose = false

    var body: some View {
        NavigationSplitView {
            MailSidebarView(selection: $sidebarItem, onCompose: { showingCompose = true })
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            MailListView(scope: sidebarItem, selection: $selectedMessage)
        } detail: {
            if let selectedMessage {
                MailReaderView(message: selectedMessage)
            } else {
                readerPlaceholder
            }
        }
        .sheet(isPresented: $showingCompose) {
            MacComposeView()
        }
    }

    private var readerPlaceholder: some View {
        ZStack {
            palette.background
            VStack(spacing: 10) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(palette.textFaint)
                Text("Select a message")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .toolbarBackground(palette.backgroundTop, for: .windowToolbar)
    }
}
