//
//  VoiceView.swift
//  AlfredMacApp
//
//  Stub for the iOS VoiceView (voice input). The Chat tab's mic button opens
//  this until a voice pipeline is wired up on macOS.
//

import SwiftUI

struct VoiceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 30))
                .foregroundStyle(palette.textFaint)

            Text("Voice is coming soon")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)

            Text("The Mac app doesn't listen yet. Type your message in Chat for now.")
                .font(.system(size: 14))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 340, height: 240)
        .background(palette.background)
        .preferredColorScheme(.dark)
    }
}
