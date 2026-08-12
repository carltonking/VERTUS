// Renders Alfred's app icons from the brand logo PNG (Logos/small logo.png), so the icon and
// the website never drift apart. Three variants, matching the slots iOS asks for.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0

/// Loads the brand logo, scaled to fit the square icon canvas.
func loadLogo(from url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fatalError("could not load logo: \(url.path)") }
    return image
}

func render(_ source: CGImage, to url: URL, greyscale: Bool = false) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("context") }

    let width = source.width
    let height = source.height
    let scale = min(size / Double(width), size / Double(height))
    let w = Double(width) * scale
    let h = Double(height) * scale
    ctx.interpolationQuality = .high
    ctx.draw(
        source,
        in: CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)
    )

    guard var image = ctx.makeImage() else { fatalError("makeImage") }

    if greyscale {
        // iOS supplies the colour for the tinted slot; ship luminance only.
        let greySpace = CGColorSpaceCreateDeviceGray()
        guard let greyCtx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width,
            space: greySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { fatalError("grey context") }
        greyCtx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let grey = greyCtx.makeImage() else { fatalError("grey image") }
        image = grey
    }

    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("encode") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.lastPathComponent)")
}

let sourceURL: URL
if CommandLine.arguments.count > 1 {
    sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
} else {
    let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    sourceURL = scriptDir
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Logos/small logo.png")
}
let logo = loadLogo(from: sourceURL)

let outDir = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent()

render(logo, to: outDir.appendingPathComponent("AppIcon.png"))
render(logo, to: outDir.appendingPathComponent("AppIcon-Dark.png"))
render(logo, to: outDir.appendingPathComponent("AppIcon-Tinted.png"), greyscale: true)
