//
//  MessageBubble.swift
//  Alfred
//

import Combine  // Timer.publish(…).autoconnect() below
import SwiftUI

struct MessageBubble: View {
    @Environment(\.palette) private var palette

    let message: Message
    var onRetry: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 44)
            } else {
                avatar
            }

            Text(rendered)
                .font(.system(size: 15.5))
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .lineSpacing(6)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: palette.bubbleRadius, style: .continuous))

            if message.role == .error {
                Button(action: onRetry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accentBright)
            }

            if message.role != .user {
                Spacer(minLength: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .alfredEntrance()
    }

    /// A small accent circle with Alfred's triangle — enough to mark the
    /// speaker without calling attention away from the message itself.
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(palette.accentGradient)
            AlfredMark(lineWidth: 1.4)
                .padding(6)
        }
        .frame(width: 20, height: 20)
    }

    /// Alfred writes in light markdown (the Telegram side has always rendered it). Parse inline
    /// syntax but keep the line breaks, which the default parser would otherwise collapse.
    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.text)
    }

    private var foreground: Color {
        switch message.role {
        case .user: return .white
        case .alfred: return palette.textPrimary
        case .error: return palette.danger
        }
    }

    @ViewBuilder private var background: some View {
        switch message.role {
        case .user:
            LinearGradient(
                colors: [palette.accent, palette.accentDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .alfred:
            palette.surface.opacity(0.85)
        case .error:
            palette.danger.opacity(0.12)
        }
    }
}

/// Shown while a request is in flight. Replies can take the better part of a minute (calendar read,
/// then a model call), so after a few seconds it says so rather than leaving the user to wonder
/// whether the tap registered.
struct ThinkingIndicator: View {
    @Environment(\.palette) private var palette

    @State private var phase = 0
    @State private var ticks = 0

    private let tick = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// ~10s at 0.4s a tick. Long enough that a normal answer never trips it, short enough that a
    /// genuinely slow one stops looking like a hang.
    private static let reassureAfterTicks = 25

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(palette.accentBright)
                        .frame(width: 7, height: 7)
                        .opacity(phase == index ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.3), value: phase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if ticks > Self.reassureAfterTicks {
                Text("still working…")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textFaint)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .onReceive(tick) { _ in
            phase = (phase + 1) % 3
            // Stop counting once the message is showing — an indicator left up for minutes
            // shouldn't keep incrementing an integer forever.
            if ticks <= Self.reassureAfterTicks { ticks += 1 }
        }
        .animation(.easeInOut, value: ticks > Self.reassureAfterTicks)
        .accessibilityLabel("Alfred is thinking")
    }
}
