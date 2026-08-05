//
//  ComingSoon.swift
//  Alfred
//
//  A page that isn't built yet says so, and says exactly what it's waiting on.
//
//  The alternative — mock rows of fake email and invented calendar entries — reads as working
//  software until you tap it, and it makes a half-finished app impossible to judge at a glance.
//

import SwiftUI

struct ComingSoon: View {
    @Environment(\.palette) private var palette

    let icon: String
    let title: String
    let promise: String
    let blockedOn: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [palette.accentSoft, palette.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 18)

            Text(promise)
                .font(.system(size: 16))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 36)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textFaint)
                Text(blockedOn)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textFaint)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(palette.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1)
            )
            .padding(.top, 28)
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
    }
}
