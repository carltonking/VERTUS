//
//  EmptyState.swift
//  AlfredMacApp
//
//  Ported from the iOS app (Alfred/Alfred/Views/EmptyState.swift).
//  What Chat shows when there's nothing in it yet, and what it shows when the
//  app has nowhere to send a message.
//
//  AlfredMark + Triangle also live here — the shell's Theme.swift carries the
//  palette but not the mark, and the empty states need it.
//

import SwiftUI

struct ConversationEmptyState: View {
    @Environment(\.palette) private var palette

    let onPick: (String) -> Void

    /// Not decoration — these are capabilities the Mac brain has today, so
    /// tapping one always reaches something real.
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

                // The Hermes-intro treatment: a wide-tracked uppercase headline
                // in the accent, glowing off the black ground.
                AlfredWordmark(text: "Ask Me Anything", size: 24)
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

/// Shown instead of the composer until the live link is up — a chat box that can only
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

            Text("You can type below — Alfred just won't answer until the live link to your Mac is up. Add the Mac's address in Settings, or let discovery find it.")
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

// MARK: - The mark

/// Alfred's mark: a triangle outlined by a second triangle inset within it, matching Logos/.
/// Drawn as a shape rather than shipped as a bitmap so it stays crisp at every size, and so it
/// takes the current theme's accent instead of being locked to one colour.
struct AlfredMark: View {
    @Environment(\.palette) private var palette

    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Triangle()
                .stroke(
                    LinearGradient(
                        colors: [palette.accentSoft, palette.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round)
                )
                .frame(width: side, height: side * 0.88)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
