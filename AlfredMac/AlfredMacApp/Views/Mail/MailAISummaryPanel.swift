//
//  MailAISummaryPanel.swift
//  AlfredMacApp
//
//  The collapsible ✨ AI Summary at the top of the reader: what this email (or
//  its conversation) is about in 2-3 bullets, plus the tone to read it in.
//  Collapsed by default — the header row carries the tone so there's a reason
//  to open it — and the toggle lives right on it.
//  Ported from the iOS app (Alfred/Alfred/Views/Mail/MailAISummaryPanel.swift).
//

import SwiftUI

struct MailAISummaryPanel: View {
    @Environment(\.palette) private var palette

    let summary: MailSummaryPayload
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.accentBright)

                    Text("AI Summary")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)

                    if !summary.tone.isEmpty {
                        Text(summary.tone)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(palette.surfaceBorder.opacity(0.6))
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textFaint)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse AI summary" : "Expand AI summary")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(summary.bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 9))
                                .foregroundStyle(palette.accentBright)
                                .padding(.top, 4)
                            Text(bullet)
                                .font(.system(size: 14))
                                .foregroundStyle(palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }
}
