//
//  EmptyState.swift
//  Alfred
//
//  What Chat shows when there's nothing in it yet, and what it shows when the app has nowhere
//  to send a message.
//

import SwiftUI

struct ConversationEmptyState: View {
    @Environment(\.palette) private var palette

    let onPick: (String) -> Void

    /// Not decoration — these are capabilities the cloud brain has today (api/_lib/route.ts),
    /// so tapping one always reaches something real.
    private let suggestions = [
        ("calendar", "What's on my calendar tomorrow?"),
        ("calendar.badge.plus", "Put dentist Friday 15:00 on my calendar"),
        ("newspaper", "What's in the news today?"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AlfredMark(lineWidth: 1.5)
                    .frame(width: 58, height: 58)
                    .opacity(0.9)
                    .padding(.top, 40)

                Text("Ask me anything")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.top, 16)

                Text("Or start with one of these.")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.top, 6)

                VStack(spacing: 10) {
                    ForEach(suggestions, id: \.1) { icon, prompt in
                        Button {
                            onPick(prompt)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon)
                                    .font(.system(size: 15))
                                    .foregroundStyle(palette.accentBright)
                                    .frame(width: 22)
                                Text(prompt)
                                    .font(.system(size: 15))
                                    .foregroundStyle(palette.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
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
                .padding(.top, 26)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Shown instead of the composer until an address and token are saved — a chat box that can only
/// ever fail is worse than an honest notice.
struct NotConnectedNotice: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            AlfredMark(lineWidth: 1.5)
                .frame(width: 70, height: 70)
                .opacity(0.5)

            Text("Not connected")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)

            Text("You can type below — Alfred just won't answer until you add your address and app token in Settings.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)

            Spacer()
            Spacer()
        }
    }
}
