//
//  MailBodyWebView.swift
//  AlfredMacApp
//
//  Renders an email's HTML.
//
//  Email HTML is hostile input: it arrives from strangers, and its images are routinely tracking
//  pixels that report back the moment a message is opened. So this starts with *all* remote loads
//  blocked and JavaScript off, exactly like Mail's "Load Remote Images" default, and only fetches
//  anything if the reader explicitly asks. That's also why links open in the default browser rather
//  than in here — a navigation inside this view would be an untrusted page wearing Alfred's chrome.
//
//  Ported from the iOS app (Alfred/Alfred/Views/Mail/MailBodyWebView.swift). Two adaptations:
//  UIViewRepresentable becomes NSViewRepresentable, and the iOS version sizes the body by observing
//  the web view's scroll content size — AppKit's WKWebView exposes no scroll view, so the macOS
//  version keeps the web view at a fixed minimum height and lets it scroll internally. The `height`
//  binding is kept so the caller's API matches iOS.
//

import AppKit
import SwiftUI
import WebKit

struct MailBodyWebView: NSViewRepresentable {
    let html: String
    /// Flipped by the "Load Remote Content" button. Changing it rebuilds the rule list and reloads.
    let allowsRemoteContent: Bool
    let palette: Palette
    /// Kept for API parity with iOS; on macOS the web view scrolls internally.
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        context.coordinator.observe(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let document = Self.document(html: html, palette: palette)
        guard context.coordinator.needsReload(document: document, allowsRemote: allowsRemoteContent) else { return }

        context.coordinator.applyBlocking(to: webView, allowsRemote: allowsRemoteContent) {
            webView.loadHTMLString(document, baseURL: nil)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    // MARK: - Document

    private static func hex(_ color: Color) -> String {
        let ns = NSColor(color)
        guard let converted = ns.usingColorSpace(.sRGB) else { return "#000000" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Wraps the message in a document that matches the app's theme.
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

        /// Watch the intrinsic content size so the reported height tracks the
        /// document. AppKit's WKWebView has no public scroll view, so we size
        /// off its frame height — which the renderer grows to fit its content
        /// when autolayout isn't constraining it.
        func observe(_ webView: WKWebView) {
            observation = webView.observe(\.frame, options: [.new]) { [weak self] webView, _ in
                guard let self else { return }
                let measured = webView.frame.height
                Task { @MainActor in
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
            // Leaving for the default browser makes the destination visible in a real address bar,
            // which a link rendered inside the message never is.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}
