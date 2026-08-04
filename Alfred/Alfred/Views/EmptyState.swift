//
//  EmptyState.swift
//  Alfred
//
//  The first thing you see on a fresh conversation. The prompts aren't decoration — they're the
//  capabilities the cloud brain actually has today (api/_lib/route.ts), so tapping one always works.
//

import SwiftUI

struct EmptyState: View {
    let onPick: (String) -> Void

    private let suggestions = [
        ("calendar", "What's on my calendar tomorrow?"),
        ("calendar.badge.plus", "Put dentist Friday 15:00 on my calendar"),
        ("newspaper", "What's in the news today?"),
        ("wave.3.right", "/models"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            AlfredMark(lineWidth: 1.5)
                .frame(width: 76, height: 76)
                .opacity(0.9)

            Text("Alfred")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 14)

            Text("Ask me anything, or start with one of these.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 32)

            VStack(spacing: 10) {
                ForEach(suggestions, id: \.1) { icon, prompt in
                    Button {
                        onPick(prompt)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.accentBright)
                                .frame(width: 22)
                            Text(prompt)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.surface.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.surfaceBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 28)
            .padding(.horizontal, 20)

            Spacer(minLength: 24)
        }
    }
}

/// Shown instead of the conversation until an address and token are saved — a chat box that can
/// only ever fail is worse than an honest door.
struct NotConnectedState: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            AlfredMark(lineWidth: 1.5)
                .frame(width: 76, height: 76)
                .opacity(0.5)

            Text("Connect to Alfred")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 16)

            Text("Point this app at your Alfred deployment and enter its app token.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)

            Button(action: onOpenSettings) {
                Text("Open Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentDeep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 26)

            Spacer()
            Spacer()
        }
    }
}
