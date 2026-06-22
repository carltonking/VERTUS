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
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: jpegData, options: [:])
            guard (try? handler.perform([request])) != nil else { return "" }

            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            return String(lines.joined(separator: "\n").prefix(maxChars))
        }.value
    }
}
