//
//  Theme.swift
//  Alfred
//
//  The palette is lifted from the Alfred website (website/index.html) so the phone,
//  the Mac app and the marketing site read as one product: deep navy ground, a single
//  blue accent, and text that steps down in weight rather than in colour count.
//

import SwiftUI

enum Theme {
    // Ground
    static let backgroundTop = Color(hex: 0x0D1220)
    static let backgroundBottom = Color(hex: 0x111829)

    // Raised surfaces (Alfred's bubbles, cards, the composer)
    static let surface = Color(hex: 0x1A2133)
    static let surfaceBorder = Color(hex: 0x2A3142)

    // Accent
    static let accent = Color(hex: 0x3B82F6)
    static let accentDeep = Color(hex: 0x2563EB)
    static let accentBright = Color(hex: 0x7AA6FF)
    static let accentSoft = Color(hex: 0x9CC0FF)

    // Type
    static let textPrimary = Color(hex: 0xE9EEFB)
    static let textSecondary = Color(hex: 0x8A93A8)
    static let textFaint = Color(hex: 0x5D6680)

    // States
    static let danger = Color(hex: 0xF87171)
    static let success = Color(hex: 0x4ADE80)

    /// The page background. Every screen sits on this so pushed views don't flash white.
    static var background: some View {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

extension Color {
    /// `Color(hex: 0x3B82F6)` — keeps the palette above readable as hex, the way the CSS has it.
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

/// Alfred's mark: a triangle outlined by a second triangle inset within it, matching Logos/.
/// Drawn as a shape rather than shipped as a bitmap so it stays crisp at every size it's used.
struct AlfredMark: View {
    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Triangle()
                .stroke(
                    LinearGradient(
                        colors: [Theme.accentSoft, Theme.accent],
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
