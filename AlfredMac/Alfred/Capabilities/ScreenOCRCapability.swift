import CoreGraphics
import Foundation
import Vision

/// Reads text out of the screen's PIXELS with Apple's Vision framework (free, on-device). Complements
/// `ScreenTextCapability` (Accessibility text): OCR catches event details that live inside images —
/// flyers, Instagram posts, screenshots — which the accessibility tree can't see.
struct ScreenOCRCapability {
    private let screen = ScreenCapability()

    /// Screenshots the screen and returns the recognized text, or nil if capture/OCR yields nothing
    /// (e.g. Screen Recording not granted). Never throws.
    func recognizeScreenText() async -> String? {
        guard let cgImage = try? await screen.captureCGImage() else { return nil }
        return await Self.recognize(cgImage)
    }

    private static func recognize(_ image: CGImage) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                    let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: text.isEmpty ? nil : text)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
