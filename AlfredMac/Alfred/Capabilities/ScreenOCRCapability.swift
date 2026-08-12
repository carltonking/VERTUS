import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads text out of PIXELS with Apple's Vision framework (free, on-device). Complements
/// `ScreenTextCapability` (Accessibility text): OCR catches event details that live inside images —
/// flyers, Instagram posts, screenshots — which the accessibility tree can't see. Works on the live
/// screen and on arbitrary image data (e.g. a photo sent to the Telegram bot).
@available(macOS 13.0, *)
struct ScreenOCRCapability {

    private let screen = ScreenCapability()

    /// Screenshots the screen and returns the recognized text, or nil if capture/OCR yields nothing
    /// (e.g. Screen Recording not granted). Never throws.
    func recognizeScreenText() async -> String? {
        guard let cgImage = try? await screen.captureCGImage() else { return nil }
        return Self.performOCR(on: cgImage)?.text
    }

    /// OCRs arbitrary image bytes (JPEG/PNG/etc.). Returns the extracted text plus the mean
    /// confidence of the recognized lines, or nil if the data isn't a decodable image or no text is
    /// found. Synchronous (Vision's perform blocks) — call off the main thread, e.g. from the
    /// monitoring tick's queue.
    static func recognizeText(inImageData data: Data) -> (text: String, confidence: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return performOCR(on: cgImage)
    }

    // MARK: - OCR core

    /// VNRecognizeTextRequest on the given image, synchronously. Returns the joined lines and the
    /// mean confidence of their top candidates, or nil when nothing is recognized. Never throws.
    private static func performOCR(on image: CGImage) -> (text: String, confidence: Double)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("[ocr] Vision request failed: %@", error.localizedDescription)
            return nil
        }

        let observations = request.results ?? []
        guard !observations.isEmpty else { return nil }

        var lines: [String] = []
        var totalConfidence: Double = 0
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(candidate.string)
            totalConfidence += Double(candidate.confidence)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, totalConfidence / Double(observations.count))
    }
}
