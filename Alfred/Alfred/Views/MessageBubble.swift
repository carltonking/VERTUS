//
//  MessageBubble.swift
//  Alfred
//

import SwiftUI

struct MessageBubble: View {
    let message: Message
    var onRetry: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 44) }

            VStack(alignment: .leading, spacing: 8) {
                Text(rendered)
                    .font(.system(size: 16))
                    .foregroundStyle(foreground)
                    .textSelection(.enabled)

                if message.role == .error {
                    Button(action: onRetry) {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentBright)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )

            if message.role != .user { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
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
        case .alfred: return Theme.textPrimary
        case .error: return Theme.danger
        }
    }

    @ViewBuilder private var background: some View {
        switch message.role {
        case .user:
            LinearGradient(
                colors: [Theme.accent, Theme.accentDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .alfred:
            Theme.surface
        case .error:
            Theme.danger.opacity(0.12)
        }
    }

    private var border: Color {
        switch message.role {
        case .user: return .clear
        case .alfred: return Theme.surfaceBorder
        case .error: return Theme.danger.opacity(0.35)
        }
    }
}

/// Shown while a request is in flight. Replies can take the better part of a minute (calendar read,
/// then a model call), so after a few seconds it says so rather than leaving the user to wonder
/// whether the tap registered.
struct ThinkingIndicator: View {
    @State private var phase = 0
    @State private var elapsed = 0

    private let tick = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Theme.accentBright)
                        .frame(width: 7, height: 7)
                        .opacity(phase == index ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.3), value: phase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.surfaceBorder, lineWidth: 1)
            )

            if elapsed > 12 {
                Text("still working…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textFaint)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .onReceive(tick) { _ in
            phase = (phase + 1) % 3
            elapsed += 1
        }
        .animation(.easeInOut, value: elapsed > 12)
        .accessibilityLabel("Alfred is thinking")
    }
}
