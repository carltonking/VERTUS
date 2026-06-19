import Foundation
import Vision
import CoreGraphics
import ImageIO
import AppKit

/// Alfred's own capture path — Apple Vision OCR over a screen frame.
/// This is the real Phase 0 capture de-risk: prove we can read the screen's text
/// on-device, for free, storing text only (frames are discarded immediately).
enum NativeCapture {

    /// Run Vision text recognition on a CGImage. Returns recognized lines + confidence.
    static func ocr(_ cgImage: CGImage) throws -> [(text: String, confidence: Float)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return (top.string, top.confidence)
        }
    }

    /// Load a CGImage from a file path (no permissions needed — proves OCR alone).
    static func loadImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Grab the current screen to a temp PNG via the system `screencapture` tool,
    /// then OCR it. Requires Screen Recording permission for the host process.
    /// (ScreenCaptureKit is the production path; this proves the end-to-end pipeline
    /// with the least ceremony for a Phase 0 spike.)
    static func grabScreenAndOCR() throws -> (frameWritten: Bool, lines: [(text: String, confidence: Float)]) {
        let tmp = NSTemporaryDirectory() + "alfred_frame.png"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-t", "png", tmp]   // -x = no sound
        try proc.run()
        proc.waitUntilExit()

        guard FileManager.default.fileExists(atPath: tmp),
              let img = loadImage(path: tmp) else {
            return (false, [])
        }
        let lines = try ocr(img)
        // Discard the frame immediately — Alfred stores text, never pixels.
        try? FileManager.default.removeItem(atPath: tmp)
        return (true, lines)
    }
}
