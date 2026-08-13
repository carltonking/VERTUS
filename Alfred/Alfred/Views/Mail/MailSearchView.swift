//
//  MailSearchView.swift
//  Alfred
//
//  The AI search bar pinned to the top of the list — Apple Mail's search, with
//  a sparkle. A plain keyword query still works (the Mac falls back to LIKE
//  search), but a natural-language ask ("emails from Sarah about budget",
//  "show me receipts from last week") routes to Hermes on the Mac, which
//  compiles it into a real filter over the cached inbox and returns a one-line
//  description of what it did — shown as the note chip beneath the field.
//

import SwiftUI

struct MailSearchView: View {
    @Environment(\.palette) private var palette

    @Binding var text: String
    var isSearching: Bool
    /// The Mac's one-line description of the AI search results, if any.
    var note: String?
    var onSubmit: () -> Void
    var onClearNote: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isSearching ? "sparkles" : "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSearching ? palette.accentBright : palette.textFaint)

                TextField("Search or ask Alfred…", text: $text)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .accessibilityIdentifier("mail.aiSearch")

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.accentBright)
                } else if !text.isEmpty {
                    Button {
                        text = ""
                        onClearNote()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textFaint)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(palette.surface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1))

            if let note, !note.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.accentBright)
                    Text(note)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button(action: onClearNote) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.textFaint)
                    }
                    .accessibilityLabel("Clear AI search note")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(palette.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
