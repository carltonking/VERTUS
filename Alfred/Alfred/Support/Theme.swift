//
//  Theme.swift
//  Alfred
//
//  Alfred's one palette: monochrome. Colour is resolved through the environment
//  rather than static constants, so the app could re-render everything that draws
//  with it — a `static let` would be read once and never invalidate a view.
//

import SwiftUI

// MARK: - The palette a view draws with

struct Palette: Equatable {
    // Ground — strict OLED deep black
    let backgroundTop: Color
    let backgroundBottom: Color

    // Raised surfaces (Alfred's bubbles, cards, the composer)
    let surface: Color
    let surfaceBorder: Color

    // The single energetic accent — orange. Active buttons, focus
    // states, highlights, the send control, and the selected tab pill all draw
    // with this family and nothing else.
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
    /// Alfred's single theme: OLED black ground, one orange accent, and
    /// warm-tinted state colours. The surface tint is a hair lighter and bluer
    /// than pure black so cards lift off the ground without a hard line.
    static let mono = Palette(
        backgroundTop: Color(hex: 0x000000),
        backgroundBottom: Color(hex: 0x07070C),
        surface: Color(hex: 0x14141A),
        surfaceBorder: Color(hex: 0x2A2A36),
        accent: Color(hex: 0xFF7A3D),
        accentDeep: Color(hex: 0xE06020),
        accentBright: Color(hex: 0xFFB380),
        accentSoft: Color(hex: 0xFFE8D6),
        textPrimary: Color(hex: 0xF4F4F7),
        textSecondary: Color(hex: 0x9D9DA8),
        textFaint: Color(hex: 0x6F6F7B),
        danger: Color(hex: 0xFF6B6B),
        success: Color(hex: 0x42D982),
        cardRadius: 16,
        bubbleRadius: 20,
        composerRadius: 28
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

// MARK: - The mark

/// Alfred's mark: a triangle outlined by a second triangle inset within it, matching Logos/.
/// Drawn as a shape rather than shipped as a bitmap so it stays crisp at every size, and so it
/// takes the current theme's accent instead of being locked to one colour.
struct AlfredMark: View {
    @Environment(\.palette) private var palette

    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Triangle()
                .stroke(
                    LinearGradient(
                        colors: [palette.accentSoft, palette.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round)
                )
                .frame(width: side, height: side * 0.88)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
