//
//  Composer.swift
//  Alfred
//

import SwiftUI

struct Composer: View {
    @Binding var text: String
    let isThinking: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Alfred…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accentBright)
                .focused($isFocused)
                // No .submitLabel(.send): with a vertical-axis field the return key inserts a
                // newline and never submits, so labelling the key "send" would promise something
                // that doesn't happen. The arrow button is the send affordance.
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(isFocused ? Theme.accent.opacity(0.6) : Theme.surfaceBorder, lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.15), value: isFocused)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(
                            canSend
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [Theme.accent, Theme.accentDeep],
                                    startPoint: .top,
                                    endPoint: .bottom
                                  ))
                                : AnyShapeStyle(Theme.surface)
                        )
                    )
                    .overlay(
                        Circle().strokeBorder(canSend ? .clear : Theme.surfaceBorder, lineWidth: 1)
                    )
            }
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.15), value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.surfaceBorder).frame(height: 0.5)
        }
    }
}
