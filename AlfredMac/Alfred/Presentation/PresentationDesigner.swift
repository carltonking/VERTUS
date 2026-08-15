import Foundation
import WebKit

// MARK: - Design styles
//
// A presentation style is a named theme: colors, typography and layout rules.
// The same style drives both export formats — the HTML/PDF deck (rich CSS) and
// the PPTX theme + slide colors — so "design consistency" holds by construction.

struct PresentationStyle: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String

    // Colors (hex, no '#') — the PDF palette and the PPTX slide palette.
    let background: String
    let surface: String        // card/panel color
    let text: String
    let mutedText: String
    let accent: String
    let accent2: String

    /// Title font for PPTX (a name PowerPoint knows). PDF uses richer CSS.
    let pptxTitleFont: String
    let pptxBodyFont: String

    /// Academic uses a serif; the rest stay on the modern sans stack.
    let htmlTitleFont: String
    let htmlBodyFont: String

    /// Where the title sits on content slides.
    enum TitlePlacement: String, Codable { case top, left, centered }
    let titlePlacement: TitlePlacement

    static let all: [PresentationStyle] = [modern, minimal, colorful, academic]

    static let modern = PresentationStyle(
        id: "modern", displayName: "Modern",
        background: "0F172A", surface: "1E293B", text: "F1F5F9",
        mutedText: "94A3B8", accent: "38BDF8", accent2: "818CF8",
        pptxTitleFont: "Calibri Light", pptxBodyFont: "Calibri",
        htmlTitleFont: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
        htmlBodyFont: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
        titlePlacement: .top)

    static let minimal = PresentationStyle(
        id: "minimal", displayName: "Minimal",
        background: "FFFFFF", surface: "F8FAFC", text: "0F172A",
        mutedText: "64748B", accent: "0F172A", accent2: "94A3B8",
        pptxTitleFont: "Calibri Light", pptxBodyFont: "Calibri",
        htmlTitleFont: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
        htmlBodyFont: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
        titlePlacement: .top)

    static let colorful = PresentationStyle(
        id: "colorful", displayName: "Colorful",
        background: "4F46E5", surface: "6D28D9", text: "FFFFFF",
        mutedText: "E0E7FF", accent: "FDE047", accent2: "F472B6",
        pptxTitleFont: "Calibri", pptxBodyFont: "Calibri",
        htmlTitleFont: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
        htmlBodyFont: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
        titlePlacement: .top)

    static let academic = PresentationStyle(
        id: "academic", displayName: "Academic",
        background: "F8F5F0", surface: "FFFFFF", text: "1F2937",
        mutedText: "6B7280", accent: "9F1239", accent2: "1E3A5F",
        pptxTitleFont: "Georgia", pptxBodyFont: "Calibri",
        htmlTitleFont: "Georgia, 'Times New Roman', serif",
        htmlBodyFont: "Georgia, 'Times New Roman', serif",
        titlePlacement: .centered)

    static func style(named name: String?) -> PresentationStyle {
        let id = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == id } ?? .modern
    }
}

// MARK: - HTML deck builder

/// Builds the slide deck as HTML (the PDF source, and a `.html` artifact next
/// to the exports). One `<section class="slide">` per slide; CSS `@page` makes
/// each slide exactly one 1280×720 PDF page.
enum DeckHTML {

    static let slideWidth = 1280
    static let slideHeight = 720

    /// Build the deck HTML. `images` maps slide index → base64 data URI
    /// (mime prefix included); `logoDataURI` stamps the title slide when set.
    static func build(content: SlideContent, style: PresentationStyle,
                      images: [Int: String], logoDataURI: String?) -> String {
        let slides = content.slides.enumerated().map { index, slide -> String in
            slideHTML(slide, index: index, total: content.slides.count,
                      deckTitle: content.title, subtitle: content.subtitle,
                      style: style,
                      image: images[index], logoDataURI: index == 0 ? logoDataURI : nil)
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        @page { size: \(slideWidth)px \(slideHeight)px; margin: 0; }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: \(style.htmlBodyFont); }
        .slide {
          width: \(slideWidth)px; height: \(slideHeight)px;
          background: #\(style.background);
          color: #\(style.text);
          position: relative; overflow: hidden;
          page-break-after: always;
          padding: 72px 84px;
          display: flex; flex-direction: column;
        }
        .slide.title-slide { justify-content: center; align-items: center; text-align: center; }
        .logo { max-height: 110px; margin-bottom: 40px; }
        .title {
          font-family: \(style.htmlTitleFont);
          font-size: 64px; line-height: 1.1; font-weight: 700;
          margin-bottom: 26px;
        }
        .title-slide .title { font-size: 88px; }
        .subtitle { font-size: 34px; color: #\(style.mutedText); font-weight: 400; }
        .title-rule {
          width: 96px; height: 8px; border-radius: 4px;
          background: linear-gradient(90deg, #\(style.accent), #\(style.accent2));
          margin-bottom: 30px;
        }
        .title-slide .title-rule { margin: 0 auto 30px; }
        .content { display: flex; gap: 56px; flex: 1; min-height: 0; }
        .bullets { flex: 1; display: flex; flex-direction: column; gap: 22px; justify-content: center; }
        ul { list-style: none; }
        li {
          font-size: 33px; line-height: 1.42; padding-left: 42px;
          position: relative; margin-bottom: 20px;
        }
        li::before {
          content: ""; position: absolute; left: 0; top: 17px;
          width: 15px; height: 15px; border-radius: 4px;
          background: linear-gradient(135deg, #\(style.accent), #\(style.accent2));
        }
        .slide-image { width: 460px; flex-shrink: 0; }
        .slide-image img {
          width: 100%; height: 100%; object-fit: cover; border-radius: 18px;
          border: 1px solid #\(style.surface);
        }
        footer {
          position: absolute; left: 84px; right: 84px; bottom: 40px;
          display: flex; justify-content: space-between;
          font-size: 20px; color: #\(style.mutedText); letter-spacing: 0.06em;
        }
        .accent-bar {
          position: absolute; top: 0; left: 0; right: 0; height: 10px;
          background: linear-gradient(90deg, #\(style.accent), #\(style.accent2));
        }
        </style>
        </head>
        <body>
        \(slides)
        </body>
        </html>
        """
    }

    private static func slideHTML(_ slide: Slide, index: Int, total: Int,
                                  deckTitle: String, subtitle: String, style: PresentationStyle,
                                  image: String?, logoDataURI: String?) -> String {
        let isTitle = index == 0
        let titleClass = isTitle ? "title-slide" : ""
        let accentBar = isTitle ? "" : "<div class=\"accent-bar\"></div>"

        let body: String
        if isTitle {
            let logo = logoDataURI.map { "<img class=\"logo\" src=\"\($0)\" alt=\"logo\">" } ?? ""
            body = """
                \(logo)
                <div class="title">\(escape(slide.title))</div>
                <div class="title-rule"></div>
                <div class="subtitle">\(escape(subtitle))</div>
                """
        } else {
            let bullets = slide.bullets.map { "<li>\(escape($0))</li>" }.joined(separator: "\n")
            let imageBlock: String
            if let image {
                imageBlock = "<div class=\"slide-image\"><img src=\"\(image)\" alt=\"\"></div>"
            } else {
                imageBlock = ""
            }
            body = """
                <div class="title">\(escape(slide.title))</div>
                <div class="title-rule"></div>
                <div class="content">
                  <div class="bullets"><ul>\(bullets)</ul></div>
                  \(imageBlock)
                </div>
                """
        }

        return """
        <section class="slide \(titleClass)">
        \(accentBar)
        \(body)
        <footer>
          <span>\(escape(deckTitle))</span>
          <span>\(index + 1) / \(total)</span>
        </footer>
        </section>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - PDF renderer

/// Renders the deck HTML to a PDF via WKWebView's `createPDF`. Offscreen
/// (the web view never appears), main-actor-bound, waits for the page (and a
/// beat for images) before printing.
@MainActor
enum PDFRenderer {

    /// Render the given HTML to PDF data. `navigation` is a helper the
    /// nav-delegate plumbing needs; the call waits for load + settle time.
    static func render(html: String, settleDelay: TimeInterval = 0.6) async throws -> Data {
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: DeckHTML.slideWidth, height: DeckHTML.slideHeight),
            configuration: WKWebViewConfiguration())

        // loadHTMLString with a fake base URL so it's treated as a real page
        // (relative resources resolve; data URIs need nothing).
        let loaded: Void = await withCheckedContinuation { continuation in
            let delegate = NavWaiter(continuation: continuation)
            objc_setAssociatedObject(webView, &NavWaiterKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = delegate
            webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
        _ = loaded
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))

        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0,
                                    width: CGFloat(DeckHTML.slideWidth),
                                    height: CGFloat(DeckHTML.slideHeight))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: configuration) { result in
                switch result {
                case .success(let pdfData): continuation.resume(returning: pdfData)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        guard !data.isEmpty else {
            throw PresentationError.exportFailed("PDF render came back empty.")
        }
        return data
    }

    private static var NavWaiterKey: UInt8 = 0

    /// Bridges WKNavigationDelegate callbacks into the async wait.
    private final class NavWaiter: NSObject, WKNavigationDelegate {
        let continuation: CheckedContinuation<Void, Never>

        init(continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation.resume()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation.resume()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            continuation.resume()
        }
    }
}
