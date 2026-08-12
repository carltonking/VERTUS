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
    // Ground
    let backgroundTop: Color
    let backgroundBottom: Color

    // Raised surfaces (Alfred's bubbles, cards, the composer)
    let surface: Color
    let surfaceBorder: Color

    // Accent
    let accent: Color
    let accentDeep: Color
    let accentBright: Color
    let accentSoft: Color

    // Type
    let textPrimary: Color
    let textSecondary: Color
    let textFaint: Color

    // States. These stay tinted even in the monochrome theme: a red that reads as grey stops
    // being a warning, and losing that costs more than the theme's purity is worth.
    let danger: Color
    let success: Color

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
    /// Alfred's single theme. The state colours (danger/success) stay tinted
    /// even in monochrome: a red that reads as grey stops being a warning, and
    /// losing that costs more than the theme's purity is worth.
    static let mono = Palette(
        backgroundTop: Color(hex: 0x080808),
        backgroundBottom: Color(hex: 0x151515),
        surface: Color(hex: 0x1F1F1F),
        surfaceBorder: Color(hex: 0x333333),
        accent: Color(hex: 0x9A9A9A),
        accentDeep: Color(hex: 0x6E6E6E),
        accentBright: Color(hex: 0xD8D8D8),
        accentSoft: Color(hex: 0xEDEDED),
        textPrimary: Color(hex: 0xF2F2F2),
        textSecondary: Color(hex: 0x9C9C9C),
        textFaint: Color(hex: 0x6A6A6A),
        danger: Color(hex: 0xC97A7A),
        success: Color(hex: 0x9FC4A0)
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
