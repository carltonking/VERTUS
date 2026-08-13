//
//  MailTabView.swift
//  Alfred
//
//  The Email tab's shell — Apple Mail's three panes, adapted to the phone.
//
//    iPad (regular width):  NavigationSplitView — sidebar (mailboxes), content
//                           (the list), detail (the reader). Selecting in the
//                           list drives the reader without a push.
//    iPhone (compact):      NavigationStack — the list is the root, the reader
//                           pushes onto it, and the sidebar collapses into a
//                           sheet behind the leading toolbar button, exactly
//                           like Mail's "back to mailboxes" affordance.
//
//  The whole tab is Mac-driven (MacMailStore over the socket) — the phone
//  reads the Mac's cached inbox and sends actions back as mail.* JSON-RPC.
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    @State private var sidebarItem: MailSidebarItem = .inbox
    @State private var selectedMessage: MacMailMessage?
    @State private var showingSidebar = false
    @State private var showingCompose = false

    var body: some View {
        Group {
            if sizeClass == .regular {
                splitView
            } else {
                phoneView
            }
        }
        .sheet(isPresented: $showingCompose) {
            MacComposeView()
        }
    }

    // MARK: - iPad: three panes

    private var splitView: some View {
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
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
    }

    // MARK: - iPhone: stack + sidebar sheet

    private var phoneView: some View {
        NavigationStack {
            MailListView(scope: sidebarItem, selection: nil)
                .navigationDestination(for: MacMailMessage.self) { message in
                    MailReaderView(message: message)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSidebar = true
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .accessibilityLabel("Mailboxes")
                    }
                }
                .sheet(isPresented: $showingSidebar) {
                    NavigationStack {
                        MailSidebarView(selection: $sidebarItem, onCompose: {
                            showingSidebar = false
                            showingCompose = true
                        })
                    }
                    .presentationDetents([.medium, .large])
                }
        }
    }
}
