//
//  HomeView.swift
//  Alfred
//
//  The landing page: a greeting, and the shortest route into whatever you actually came to do.
//
//  It deliberately isn't the chat. Once Chat has a tab of its own, a Home that duplicated it would
//  leave two places showing the same transcript and no reason to prefer either.
//

import SwiftUI

struct HomeView: View {
    @Binding var selection: AlfredTab

    @Environment(AppSettings.self) private var settings
    @Environment(ChatStore.self) private var chat
    @Environment(\.palette) private var palette

    /// Hardcoded while Alfred has exactly one owner. It becomes a setting the moment a second
    /// person installs this.
    private let ownerName = "Carlton"

    private var shortcuts: [(icon: String, label: String, prompt: String)] {
        [
            ("calendar", "What's on today?", "What's on my calendar today?"),
            ("calendar.badge.plus", "Add an event", "Put dentist Friday 15:00 on my calendar"),
            ("newspaper", "Catch me up", "What's in the news today?"),
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background

                ScrollView {
                    VStack(spacing: 0) {
                        AlfredMark(lineWidth: 1.5)
                            .frame(width: 62, height: 62)
                            .padding(.top, 28)

                        Text("Welcome, \(ownerName)")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.textPrimary)
                            .padding(.top, 18)

                        Text(settings.isConfigured
                             ? "What can I take off your plate?"
                             : "Connect me to your deployment and I'll get to work.")
                            .font(.system(size: 16))
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                            .padding(.horizontal, 32)

                        if settings.isConfigured {
                            shortcutList
                        } else {
                            connectButton
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("")
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // No gear here: Settings has its own icon in the bottom bar.
        }
    }

    private var shortcutList: some View {
        VStack(spacing: 10) {
            ForEach(shortcuts, id: \.prompt) { shortcut in
                Button {
                    // Send it and follow it — landing on Chat with an empty screen while the
                    // answer arrives elsewhere would be worse than not offering the shortcut.
                    Task { await chat.send(shortcut.prompt, settings: settings) }
                    selection = .chat
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: shortcut.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(palette.accentBright)
                            .frame(width: 22)
                        Text(shortcut.label)
                            .font(.system(size: 16))
                            .foregroundStyle(palette.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textFaint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .background(palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.surfaceBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 30)
        .padding(.horizontal, 20)
    }

    private var connectButton: some View {
        Button {
            selection = .settings
        } label: {
            Text("Open Settings")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 13)
                .background(palette.accentGradient)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 28)
    }
}
