import Foundation
import Vision

/// On-device OCR via Apple's Vision framework. Used only as a fallback when the Accessibility
/// tree yields no text (canvas-rendered apps, PDFs in a browser, Electron with broken a11y,
/// remote desktop, images). No network, no dependency — Vision ships with macOS.
struct VisionOCRCapability {
    /// Recognize text in a JPEG. Runs off the main actor (Vision's `perform` is synchronous and
    /// CPU-bound). Returns "" on failure or empty result.
    func recognizeText(in jpegData: Data, maxChars: Int = 6000) async -> String {
        await Task.detached(priority: .utility) {
            Self.run(handler: VNImageRequestHandler(data: jpegData, options: [:]), maxChars: maxChars)
        }.value
    }

    /// Recognize text directly from a CGImage — avoids a JPEG encode+decode round-trip when the
    /// caller already holds the frame (e.g. ScreenCapability.captureCGImage()). Same config/cap.
    func recognizeText(in cgImage: CGImage, maxChars: Int = 6000) async -> String {
        await Task.detached(priority: .utility) {
            Self.run(handler: VNImageRequestHandler(cgImage: cgImage, options: [:]), maxChars: maxChars)
        }.value
    }

    private static func run(handler: VNImageRequestHandler, maxChars: Int) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        guard (try? handler.perform([request])) != nil else { return "" }

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(maxChars))
    }
}
