import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO

actor ScreenCapability {

    // MARK: - Public API

    func captureScreen() async throws -> Data {
        try jpegData(from: try await captureCGImage())
    }

    /// The raw screenshot as a `CGImage` — used by on-device OCR (Vision) so callers don't pay a JPEG
    /// round-trip.
    func captureCGImage() async throws -> CGImage {
        let content = try await fetchShareableContent()

        guard let display = content.displays.first else {
            throw LLMError.networkError("No display found")
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

    // MARK: - Private

    private func fetchShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let nsError = error as NSError
            // SCK error 1 = permission denied (kSCStreamErrorUserDeclined)
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamError" && nsError.code == -3801 {
                throw LLMError.networkError(
                    "Screen Recording permission denied. Grant access in System Settings → Privacy & Security → Screen Recording."
                )
            }
            throw LLMError.networkError("ScreenCaptureKit error: \(error.localizedDescription)")
        }
    }

    private func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw LLMError.networkError("Failed to create image destination")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.75]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw LLMError.networkError("Failed to encode screenshot as JPEG")
        }
        return data as Data
    }
}
