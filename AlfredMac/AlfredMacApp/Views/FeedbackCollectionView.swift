//
//  FeedbackCollectionView.swift
//  AlfredMacApp
//
//  Ported from the iOS app (Alfred/Alfred/Views/FeedbackCollectionView.swift).
//  The 1–5 star rating Alfred shows after each AI output. One quick tap, and
//  the prompt + output + rating ride over the live link to the Mac's
//  optimization loop, which folds them into the weekly DSPy compile pass.
//

import SwiftUI

struct FeedbackCollectionView: View {
    @Environment(\.palette) private var palette

    /// The domain's rawValue ("code", "email", …), or nil to let the Mac
    /// classify from the prompt.
    let kind: String?
    /// The user's request this output answered.
    let prompt: String
    /// What Alfred produced.
    let output: String
    /// Extra context (recipient, project) folded into the training example.
    var context: String? = nil

    @State private var rating = 0
    @State private var submitted = false

    var body: some View {
        HStack(spacing: 8) {
            Text(submitted ? "Thanks — that teaches Alfred." : "How was this?")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textFaint)

            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        select(value)
                    } label: {
                        Image(systemName: value <= rating ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(value <= rating ? palette.accentBright : palette.textFaint)
                    }
                    .buttonStyle(.plain)
                    .disabled(submitted)
                    .accessibilityLabel("Rate \(value) star\(value == 1 ? "" : "s")")
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.15), value: rating)
    }

    private func select(_ value: Int) {
        guard !submitted else { return }
        rating = value
        submitted = true
        Task {
            _ = await AlfredWebSocketClient.shared.submitFeedback(
                kind: kind,
                prompt: prompt,
                output: output,
                rating: value,
                edited: false,
                context: context)
        }
    }
}
