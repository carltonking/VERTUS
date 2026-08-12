//
//  MessageRow.swift
//  Alfred
//
//  One row of the message list, laid out the way Mail lays it out: unread dot, sender, date on the
//  right, subject, then two lines of preview.
//
//  The preview is two lines rather than one because that's usually the difference between deciding
//  whether a message needs opening and having to open it to find out.
//

import SwiftUI

struct MessageRow: View {
    @Environment(\.palette) private var palette

    let message: MailMessage
    /// Shown only in All Inboxes, where "which address did this arrive at" is a real question.
    let showsAccount: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Holds the row's left gutter open whether or not there's a dot, so subjects stay aligned.
            Circle()
                .fill(message.seen ? Color.clear : palette.accentBright)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.displayName)
                        .font(.system(size: 16, weight: message.seen ? .regular : .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(MailDate.listLabel(message.date))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textFaint)
                }

                HStack(spacing: 6) {
                    Text(message.subject)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)

                    if message.flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.accent)
                    }

                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                    }

                    Spacer(minLength: 0)
                }

                if !message.snippet.isEmpty {
                    Text(message.snippet)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if showsAccount {
                    Text(message.account)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textFaint)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // One spoken sentence instead of six fragments, and it leads with unread — the thing that
        // decides whether the rest matters.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenDescription)
    }

    /// Assembled as an explicit String: concatenating interpolated literals inline lets the compiler
    /// resolve the argument as a LocalizedStringKey instead, which then fails to type-check.
    private var spokenDescription: String {
        var parts: [String] = []
        if !message.seen { parts.append("Unread") }
        parts.append(message.displayName)
        parts.append(message.subject)
        parts.append(MailDate.listLabel(message.date))
        if message.flagged { parts.append("Flagged") }
        if message.hasAttachments { parts.append("Has attachment") }
        return parts.joined(separator: ". ") + "."
    }
}
