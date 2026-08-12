//
//  VoiceView.swift
//  Alfred
//
//  Talking to Alfred out loud — full-duplex voice with the Mac's Moshi-MLX bridge. Shown as a
//  full-screen sheet from Chat so the tab bar isn't in the way and the mic owns the screen.
//

import SwiftUI

struct VoiceView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var voice = VoiceStore()

    var body: some View {
        ZStack {
            palette.background

            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                Spacer(minLength: 0)

                mark

                equalizer
                    .padding(.top, 14)
                    .opacity(voice.isResponding ? 1 : 0.35)

                statusLine
                    .padding(.top, 14)

                transcript
                    .padding(.top, 18)

                Spacer(minLength: 0)

                controls
                    .padding(.bottom, 34)
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer()
            Button {
                voice.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(palette.surface.opacity(0.6), in: Circle())
            }
            .accessibilityLabel("Close voice")
        }
    }

    // MARK: - Mark + status

    private var mark: some View {
        AlfredMark(lineWidth: 2.5)
            .frame(width: 96, height: 96)
            .shadow(color: palette.accent.opacity(0.4), radius: isStreaming ? 26 : 8)
            .animation(.easeInOut(duration: 0.8), value: isStreaming)
            .opacity(voice.phase == .streaming ? 1 : 0.55)
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(palette.textSecondary)
            .multilineTextAlignment(.center)
    }

    // MARK: - Equalizer

    private var equalizer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !voice.isResponding)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: 5, height: barHeight(at: t, bar: index))
                }
            }
            .frame(height: 40)
            .animation(.easeInOut(duration: 0.12), value: voice.isResponding)
        }
    }

    private func barHeight(at t: TimeInterval, bar: Int) -> CGFloat {
        let phase = Double(bar) * 0.65 + t * 5.2
        let wave = (sin(phase) + 1) / 2
        let base: CGFloat = voice.isResponding ? 6 : 10
        let amp: CGFloat = voice.isResponding ? 26 : 3
        return base + amp * CGFloat(wave)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if voice.transcript.isEmpty {
            Text(transcriptEmptyText)
                .font(.system(size: 14))
                .foregroundStyle(palette.textFaint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
        } else {
            ScrollView {
                Text(voice.transcript)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.textPrimary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 18) {
            if settings.voiceHost.isEmpty {
                Button {
                    dismiss()
                } label: {
                    Text("Set the Mac's address in Settings first")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(palette.surface.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                if isStreaming {
                    voice.stop()
                } else {
                    start()
                }
            } label: {
                Image(systemName: isStreaming ? "stop.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .modifier(PowerBackground(streaming: isStreaming, palette: palette))
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isStreaming ? "Stop talking" : "Start talking")
        }
    }

    // MARK: - Helpers

    private var isStreaming: Bool {
        voice.phase == .streaming
    }

    private var statusText: String {
        switch voice.phase {
        case .idle: return "Tap to talk to Alfred"
        case .connecting: return "Talking to the Mac…"
        case .streaming: return "Listening — Alfred hears you"
        case .failed(let detail): return detail
        }
    }

    private var transcriptEmptyText: String {
        switch voice.phase {
        case .connecting: return "Tuning up…"
        case .streaming: return "Say something — Alfred is listening."
        default: return ""
        }
    }

    private func start() {
        guard !settings.voiceHost.isEmpty else { return }
        Task { await voice.start(host: settings.voiceHost) }
    }
}

/// The stop/start knob: a solid danger fill while streaming, the accent gradient otherwise.
private struct PowerBackground: ViewModifier {
    let streaming: Bool
    let palette: Palette

    @ViewBuilder
    func body(content: Content) -> some View {
        if streaming {
            content.background(palette.danger, in: Circle())
        } else {
            content.background(palette.accentGradient, in: Circle())
        }
    }
}