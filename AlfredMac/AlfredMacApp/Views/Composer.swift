//
//  Composer.swift
//  AlfredMacApp
//
//  Ported from the iOS app (Alfred/Alfred/Views/Composer.swift), with the
//  macOS adaptation the task asked for: the send arrow carries a Cmd+Enter
//  keyboard shortcut (the vertical-axis field keeps Enter for newlines).
//

import SwiftUI

struct Composer: View {
    @Environment(\.palette) private var palette

    @Binding var text: String
    let isThinking: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Alfred…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .font(.system(size: 16))
                .foregroundStyle(palette.textPrimary)
                .tint(palette.accentBright)
                .focused($isFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canSend ? .white : palette.textFaint)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(canSend ? AnyShapeStyle(palette.accentGradient) : AnyShapeStyle(palette.surface))
                    )
            }
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .animation(.easeInOut(duration: 0.15), value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
