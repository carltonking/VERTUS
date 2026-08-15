//
//  Chrome.swift
//  AlfredMacApp
//
//  Hermes-inspired shell chrome, distilled from the Hermes desktop app's
//  design system (apps/desktop DESIGN.md + shell components):
//
//  - StatusBarView: the persistent bottom strip. Hermes keeps a thin statusbar
//    under everything (statusbar-controls.tsx) — connection state, host, and a
//    live signal. Alfred's mirror: socket state + the Mac's address + unread
//    mail. One hairline on top; the page chrome floats above it.
//  - SectionCaption: the small uppercase tracked label + hairline rule Hermes
//    uses to bucket sidebar content (SidebarDateDivider). Groups content with
//    whitespace and a single stroke — flat, never boxed.
//  - AlfredWordmark: the display wordmark for intro/empty states — uppercase,
//    wide tracking, accent-tinted, plus-lighter blend (Hermes' Intro wordmark).
//

import SwiftUI

// MARK: - Status bar

/// The thin strip pinned to the window's bottom edge. Left: the live link to
/// the Mac (socket state + address). Right: unread mail when there's any.
/// Deliberately quiet — 11pt text, one hairline — so the floating tab bar and
/// page content stay the loudest things on screen.
struct StatusBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    private var socket: AlfredWebSocketClient { .shared }

    var body: some View {
        HStack(spacing: 10) {
            statusDot

            Text(statusLine)
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if MacMailStore.shared.totalUnread > 0 {
                Label("\(MacMailStore.shared.totalUnread)", systemImage: "envelope.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textFaint)
                    .accessibilityLabel("\(MacMailStore.shared.totalUnread) unread messages")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 22)
        .background(palette.backgroundBottom.opacity(0.85))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)
        }
    }

    /// The socket state's colour, visible at a glance: green when the link is
    /// up, accent while negotiating, red on a terminal failure.
    private var statusDot: some View {
        let color: Color = {
            switch socket.state {
            case .connected: return palette.success
            case .connecting, .reconnecting: return palette.accentBright
            case .failed: return palette.danger
            case .idle: return palette.textFaint
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    /// "Connected · 192.168.1.20:8766", or an honest account of where the link
    /// is instead of a spinner that never settles.
    private var statusLine: String {
        switch socket.state {
        case .connected:
            let host = settings.socketHost.isEmpty ? "your Mac" : settings.socketHost
            return "Connected · \(host):\(settings.socketPort)"
        case .connecting:
            return "Connecting…"
        case .reconnecting(let attempt):
            return "Reconnecting… (attempt \(attempt))"
        case .failed(let reason):
            return "Connection failed — \(reason)"
        case .idle:
            return "Not connected"
        }
    }
}

// MARK: - Section caption

/// The uppercase tracked label + hairline rule Hermes uses to group sidebar
/// content. Place above a cluster of rows to read as a section boundary —
/// caption on the left, one stroke filling the rest of the line.
struct SectionCaption: View {
    @Environment(\.palette) private var palette

    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(palette.textFaint)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)
        }
    }
}

// MARK: - Wordmark

/// The display wordmark for intro states — "ALFRED" or a page's name set in
/// uppercase with wide tracking, tinted by the accent and blended plus-lighter
/// so it glows off the black ground. Mirrors Hermes' Intro wordmark treatment.
struct AlfredWordmark: View {
    @Environment(\.palette) private var palette

    let text: String
    var size: CGFloat = 40

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.09)
            .foregroundStyle(palette.accentBright.opacity(0.92))
            .blendMode(.plusLighter)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}
