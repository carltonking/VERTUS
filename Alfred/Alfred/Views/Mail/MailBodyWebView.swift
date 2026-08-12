//
//  MailBodyWebView.swift
//  Alfred
//
//  Renders an email's HTML.
//
//  Email HTML is hostile input: it arrives from strangers, and its images are routinely tracking
//  pixels that report back the moment a message is opened. So this starts with *all* remote loads
//  blocked and JavaScript off, exactly like Mail's "Load Remote Images" default, and only fetches
//  anything if the reader explicitly asks. That's also why links open in Safari rather than in here —
//  a navigation inside this view would be an untrusted page wearing Alfred's chrome.
//

import SwiftUI
import WebKit

struct MailBodyWebView: UIViewRepresentable {
    let html: String
    /// Flipped by the "Load Remote Content" button. Changing it rebuilds the rule list and reloads.
    let allowsRemoteContent: Bool
    let palette: Palette
    /// Reported back so the body can size itself inside the outer ScrollView, giving the screen one
    /// scroll rather than a small scrolling box inside a scrolling page.
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // The outer ScrollView does the scrolling; this one only reports how tall it wants to be.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false

        context.coordinator.observe(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let document = Self.document(html: html, palette: palette)
        guard context.coordinator.needsReload(document: document, allowsRemote: allowsRemoteContent) else { return }

        context.coordinator.applyBlocking(to: webView, allowsRemote: allowsRemoteContent) {
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    // MARK: - Document

    private static func hex(_ color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Wraps the message in a document that fits a phone and matches the app's theme.
    ///
    /// `!important` on the colours is deliberate: marketing mail ships its own palette assuming a
    /// white page, and dark text on Alfred's dark background is unreadable. Backgrounds are forced
    /// transparent for the same reason.
    static func document(html: String, palette: Palette) -> String {
        """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body {
            margin: 0; padding: 0 16px 16px;
            background: transparent !important;
            color: \(hex(palette.textPrimary)) !important;
            font: -apple-system-body;
            font-family: -apple-system, system-ui, sans-serif;
            -webkit-text-size-adjust: 100%;
            word-break: break-word;
          }
          * { background-color: transparent !important; color: inherit !important; max-width: 100% !important; }
          img { max-width: 100% !important; height: auto !important; }
          a { color: \(hex(palette.accentBright)) !important; }
          blockquote {
            margin: 0 0 0 8px; padding-left: 10px;
            border-left: 2px solid \(hex(palette.surfaceBorder));
            color: \(hex(palette.textSecondary)) !important;
          }
          pre, code { white-space: pre-wrap; font-family: ui-monospace, monospace; }
          table { max-width: 100% !important; width: auto !important; }
        </style>
        </head><body>\(html)</body></html>
        """
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: MailBodyWebView
        private var observation: NSKeyValueObservation?
        private var loadedDocument: String?
        private var loadedAllowsRemote: Bool?

        init(_ parent: MailBodyWebView) {
            self.parent = parent
        }

        func needsReload(document: String, allowsRemote: Bool) -> Bool {
            document != loadedDocument || allowsRemote != loadedAllowsRemote
        }

        /// Height comes from KVO rather than JavaScript, because JavaScript is switched off — and
        /// leaving it on to measure a box would hand untrusted mail a scripting engine.
        func observe(_ webView: WKWebView) {
            observation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                guard let self else { return }
                let measured = scrollView.contentSize.height
                Task { @MainActor in
                    // Ignore sub-pixel churn; a feedback loop here shows up as a flickering message.
                    if abs(self.parent.height - measured) > 1 { self.parent.height = measured }
                }
            }
        }

        func stopObserving() {
            observation?.invalidate()
            observation = nil
        }

        func applyBlocking(to webView: WKWebView, allowsRemote: Bool, then load: @escaping () -> Void) {
            loadedDocument = MailBodyWebView.document(html: parent.html, palette: parent.palette)
            loadedAllowsRemote = allowsRemote

            webView.configuration.userContentController.removeAllContentRuleLists()
            guard !allowsRemote else {
                load()
                return
            }

            let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: "alfred-mail-block-remote",
                encodedContentRuleList: rules
            ) { list, _ in
                if let list { webView.configuration.userContentController.add(list) }
                // Load regardless: failing to compile a blocklist must not leave a blank message. The
                // fallback is still safe-ish because the delegate refuses non-about: navigations.
                load()
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // Leaving for Safari makes the destination visible in a real address bar, which a link
                // rendered inside the message never is.
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}
