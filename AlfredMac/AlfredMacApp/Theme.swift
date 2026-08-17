//
//  Theme.swift
//  AlfredMacApp
//
//  Alfred's one palette: monochrome. Colour is resolved through the environment
//  rather than static constants, so the app could re-render everything that draws
//  with it — a `static let` would be read once and never invalidate a view.
//
//  Ported verbatim from the iOS app (Alfred/Alfred/Support/Theme.swift) so the
//  companion surface and the phone render identically.
//

import SwiftUI

// MARK: - The palette a view draws with

struct Palette: Equatable {
    // Ground — neutral gray
    let backgroundTop: Color
    let backgroundBottom: Color

    // The side panel's own ground, one step below the page background so the
    // rail reads as a distinct column. RGB(10, 10, 10).
    let sidebarBackground: Color

    // Raised surfaces (Alfred's bubbles, cards, the composer)
    let surface: Color
    let surfaceBorder: Color

    // Structure, not decoration: the 1px stroke that separates stacked chrome
    // (Hermes' `--ui-stroke-*` token family). Dividers read as layout, never as
    // framed boxes — one hairline, then whitespace.
    let hairline: Color

    // The accent family — neutral grays, never a colour. Active buttons,
    // focus states, highlights, the send control, and the selected sidebar row
    // all draw with this family and nothing else.
    let accent: Color
    let accentDeep: Color
    let accentBright: Color
    let accentSoft: Color

    // Type
    let textPrimary: Color
    let textSecondary: Color
    let textFaint: Color

    // States. These stay tinted even on the deep-black theme: a red that reads
    // as grey stops being a warning, and losing that costs more than the
    // system's purity is worth. Success leans neon-mint so it never collides
    // with the orange accent.
    let danger: Color
    let success: Color

    // Uniform radius language. Cards and containers share `cardRadius`; message
    // bubbles are a touch rounder with `bubbleRadius`; the composer is a pill.
    let cardRadius: CGFloat
    let bubbleRadius: CGFloat
    let composerRadius: CGFloat

    /// The page background. Every screen sits on this so a pushed view never flashes a wrong colour.
    var background: some View {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - The one palette

extension Palette {
    /// Alfred's single theme: a dark gray ground, neutral gray accents, and no
    /// coloured states. Sidebar/tab chrome is RGB(10, 10, 10); every page
    /// background is solid RGB(30, 30, 30); text is white; radii are sharp (0).
    static let mono = Palette(
        backgroundTop: Color(red: 30/255, green: 30/255, blue: 30/255),
        backgroundBottom: Color(red: 30/255, green: 30/255, blue: 30/255),
        sidebarBackground: Color(red: 10/255, green: 10/255, blue: 10/255),
        surface: Color(white: 0.08),
        surfaceBorder: Color(white: 0.12),
        hairline: Color.white.opacity(0.06),
        accent: Color(white: 0.3),
        accentDeep: Color(white: 0.2),
        accentBright: Color(white: 0.5),
        accentSoft: Color(white: 0.7),
        textPrimary: .white,
        textSecondary: Color.white.opacity(0.7),
        textFaint: Color.white.opacity(0.45),
        danger: Color(white: 0.5),
        success: Color(white: 0.5),
        cardRadius: 0,
        bubbleRadius: 0,
        composerRadius: 0
    )
}

// MARK: - Environment plumbing

extension EnvironmentValues {
    @Entry var palette: Palette = .mono
}

// MARK: - Colour helper

extension Color {
    /// `Color(hex: 0xF5A524)` — keeps the palettes above readable as hex.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Entrance animation

/// The app's one entrance vocabulary: a gentle fade-in with a short slide up.
/// Attached to message bubbles, cards, and anything that arrives into a stream,
/// it replaces abrupt layout snapping with a soft, tactile reveal. Each bubble
/// animates on its own first appearance, so late-arriving replies rise in as
/// they land rather than pop.
private struct AlfredEntrance: ViewModifier {
    var delay: Double = 0

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .animation(
                .spring(response: 0.38, dampingFraction: 0.82).delay(delay),
                value: shown
            )
            .onAppear { shown = true }
    }
}

extension View {
    /// Fade + slide-up on first appearance. Use on bubbles and cards entering a
    /// scroll stream so nothing ever snaps into place.
    func alfredEntrance(delay: Double = 0) -> some View {
        modifier(AlfredEntrance(delay: delay))
    }
}
