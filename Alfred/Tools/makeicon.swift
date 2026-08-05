// Renders Alfred's app icons from the same triangle mark the app draws in SwiftUI, so the icon and
// the in-app logo can't drift apart. Three variants, matching the slots iOS asks for.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// The mark: an equilateral-ish triangle, stroked thickly so it reads as the nested-outline logo.
func trianglePath(inset: CGFloat) -> CGPath {
    let width = size - inset * 2
    let height = width * 0.88
    let originY = (size - height) / 2
    let path = CGMutablePath()
    path.move(to: CGPoint(x: size / 2, y: originY + height))
    path.addLine(to: CGPoint(x: inset + width, y: originY))
    path.addLine(to: CGPoint(x: inset, y: originY))
    path.closeSubpath()
    return path
}

func render(to url: URL, background: (UInt32, UInt32)?, strokeTop: UInt32, strokeBottom: UInt32) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("context") }

    if let background {
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [rgb(background.0), rgb(background.1)] as CFArray,
            locations: [0, 1]
        )!
        // Top-to-bottom, matching the app's own background gradient.
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    let path = trianglePath(inset: 232)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(34)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let strokeGradient = CGGradient(
        colorsSpace: space,
        colors: [rgb(strokeTop), rgb(strokeBottom)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        strokeGradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("encode") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.lastPathComponent)")
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

// Default: the icon as seen on a normal home screen.
render(
    to: outDir.appendingPathComponent("AppIcon.png"),
    background: (0x05060A, 0x140F0A),
    strokeTop: 0xFDE68A,
    strokeBottom: 0xF5A524
)

// Dark: iOS dims the wallpaper behind it, so the ground goes deeper and the mark brighter.
render(
    to: outDir.appendingPathComponent("AppIcon-Dark.png"),
    background: (0x000000, 0x0C0906),
    strokeTop: 0xFEF3C7,
    strokeBottom: 0xFCD34D
)

// Tinted: iOS supplies the colour and expects greyscale, so ship luminance only.
render(
    to: outDir.appendingPathComponent("AppIcon-Tinted.png"),
    background: (0x000000, 0x000000),
    strokeTop: 0xFFFFFF,
    strokeBottom: 0x9A9A9A
)
