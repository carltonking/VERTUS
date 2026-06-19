import AppKit
import Foundation

struct PDFExportCapability {
    private let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let margin: CGFloat = 54

    func write(content: String, title: String?, to url: URL) throws {
        guard url.pathExtension.lowercased() == "pdf" else {
            throw LLMError.networkError("PDF export requires a .pdf destination.")
        }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw LLMError.networkError("Could not create PDF renderer.")
        }

        let attributed = renderableContent(from: content, fallbackTitle: title)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var currentRange = CFRange(location: 0, length: 0)
        let textRect = CGRect(
            x: margin,
            y: margin,
            width: pageRect.width - margin * 2,
            height: pageRect.height - margin * 2
        )
        let textPath = CGPath(rect: textRect, transform: nil)

        repeat {
            context.beginPDFPage([kCGPDFContextMediaBox as String: pageRect] as CFDictionary)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 0, y: pageRect.height)
            context.scaleBy(x: 1, y: -1)

            let frame = CTFramesetterCreateFrame(framesetter, currentRange, textPath, nil)
            CTFrameDraw(frame, context)

            context.restoreGState()
            context.endPDFPage()

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            currentRange.location += visibleRange.length
        } while currentRange.location < attributed.length

        context.closePDF()
        try data.write(to: url, options: .atomic)
    }

    private func renderableContent(from content: String, fallbackTitle: String?) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)

        if let fallbackTitle, !fallbackTitle.isEmpty, !startsWithHeading(lines) {
            append(fallbackTitle, to: output, style: .title)
            append("\n", to: output, style: .body)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("# ") {
                append(String(trimmed.dropFirst(2)), to: output, style: .title)
                append("\n", to: output, style: .body)
            } else if trimmed.hasPrefix("## ") {
                append(String(trimmed.dropFirst(3)), to: output, style: .heading)
                append("\n", to: output, style: .body)
            } else if trimmed.hasPrefix("### ") {
                append(String(trimmed.dropFirst(4)), to: output, style: .subheading)
                append("\n", to: output, style: .body)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                append("• \(trimmed.dropFirst(2))", to: output, style: .bullet)
                append("\n", to: output, style: .body)
            } else if trimmed.isEmpty {
                append("\n", to: output, style: .body)
            } else {
                append(line, to: output, style: .body)
                append("\n", to: output, style: .body)
            }
        }

        return output
    }

    private func startsWithHeading(_ lines: [String]) -> Bool {
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return false
        }
        return first.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
    }

    private enum Style {
        case title
        case heading
        case subheading
        case body
        case bullet
    }

    private func append(_ text: some StringProtocol, to output: NSMutableAttributedString, style: Style) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = style == .body ? 8 : 10
        paragraph.firstLineHeadIndent = style == .bullet ? 16 : 0
        paragraph.headIndent = style == .bullet ? 16 : 0

        let font: NSFont
        switch style {
        case .title:
            font = .boldSystemFont(ofSize: 24)
        case .heading:
            font = .boldSystemFont(ofSize: 18)
        case .subheading:
            font = .boldSystemFont(ofSize: 15)
        case .body, .bullet:
            font = .systemFont(ofSize: 12)
        }

        output.append(NSAttributedString(
            string: String(text),
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        ))
    }
}
