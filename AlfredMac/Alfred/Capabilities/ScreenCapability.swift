import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO

/// Errors from screen capture.
///
/// Previously these threw `LLMError.networkError`, which was never accurate — it
/// came from Alfred's own LLM layer, deleted when Hermes took over the model
/// path. Capture failures are local and have nothing to do with a network.
enum ScreenCaptureError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let why): return why
        }
    }
}

actor ScreenCapability {

    // MARK: - Public API

    func captureScreen() async throws -> Data {
        try Self.jpegData(from: try await captureCGImage())
    }

    /// The raw screenshot as a `CGImage` — used by on-device OCR (Vision) so callers don't pay a JPEG
    /// round-trip.
    func captureCGImage() async throws -> CGImage {
        let content = try await fetchShareableContent()

        guard let display = content.displays.first else {
            throw ScreenCaptureError.failed("No display found")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .nominal
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    func captureScreenAsBase64() async throws -> String {
        let data = try await captureScreen()
        return data.base64EncodedString()
    }

    /// A screenshot plus its pixel dimensions — the guidance ("point at my screen") feature needs the
    /// size so it can map the model's screenshot-space coordinates back to on-screen points.
    struct Screenshot: Sendable {
        let base64: String
        let mediaType: String
        let width: Int
        let height: Int
    }

    func captureForVision() async throws -> Screenshot {
        let full = try await captureCGImage()
        // Downscale to a max 1280px long edge (Clicky does the same): a smaller image uploads and
        // infers much faster, and vision models tend to ground coordinates at least as well on it.
        // The returned width/height are the DOWNSCALED pixel size, which the caller scales back to
        // display points — so accuracy is unaffected.
        let image = Self.downscaled(full, maxLongEdge: 1280) ?? full
        let data = try Self.jpegData(from: image)
        return Screenshot(base64: data.base64EncodedString(),
                          mediaType: "image/jpeg",
                          width: image.width,
                          height: image.height)
    }

    static func downscaled(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { return image }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let w = Int((Double(image.width) * scale).rounded())
        let h = Int((Double(image.height) * scale).rounded())
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Private

    private func fetchShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let nsError = error as NSError
            // SCK error 1 = permission denied (kSCStreamErrorUserDeclined)
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamError" && nsError.code == -3801 {
                throw ScreenCaptureError.failed(
                    "Screen Recording permission denied. Grant access in System Settings → Privacy & Security → Screen Recording."
                )
            }
            throw ScreenCaptureError.failed("ScreenCaptureKit error: \(error.localizedDescription)")
        }
    }

    // Internal (not private): the screen-monitoring loop reuses these two
    // helpers to encode its own captures without duplicating the ImageIO code.
    static func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw ScreenCaptureError.failed("Failed to create image destination")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.75]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScreenCaptureError.failed("Failed to encode screenshot as JPEG")
        }
        return data as Data
    }
}
