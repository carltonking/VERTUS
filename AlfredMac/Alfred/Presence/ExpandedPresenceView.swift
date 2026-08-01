import AppKit
import SwiftUI

/// Full notch-native bar with input, streaming response, and adaptive suggestions.
///
/// Layout (350 px wide):
/// ┌──────────────────────────────┐
/// │  [logo]  [  Ask anything…  ] │
/// │  ─────────────────────────── │
/// │  ● Suggestion ● Suggestion   │
/// │  ─────────────────────────── │
/// │  Response text scrolls here  │
/// │  ...                        │
/// └──────────────────────────────┘
struct ExpandedPresenceView: View {
    @Binding var responseText: String
    @Binding var isProcessing: Bool
    @Binding var suggestions: [ProactiveSuggestion]
    @Binding var pendingConfirmation: PendingControlConfirmation?
    let activeProject: String?
    let contextLabel: String
    let contextStatus: String
    let focusToken: Int
    let onSubmit: (String) -> Void
    let onSuggestionTap: (ProactiveSuggestion) -> Void
    let onEscape: () -> Void

    @State private var inputText: String = ""
    @State private var mathResult: String?
    @FocusState private var inputFocused: Bool
    @State private var didCopy = false

    static let barWidth: CGFloat = 350

    static let inputRowHeight: CGFloat = 64
    static let loadingRowHeight: CGFloat = 44
    // Output window grows with the response but caps at ~5 lines, then scrolls inside.
    // 5 lines × 20pt line height + 24pt vertical padding.
    static let maxResponseHeight: CGFloat = 124
    static let suggestionRowHeight: CGFloat = 32
    /// Scrollable action list inside the confirmation.
    static let confirmationScrollHeight: CGFloat = 96
    /// Header + buttons + padding around `confirmationScrollHeight`.
    static let confirmationChromeHeight: CGFloat = 78

    static func responseHeight(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 44 }
        let textWidth: CGFloat = 310
        let charWidth: CGFloat = 7.5
        let charsPerLine = max(Int(textWidth / charWidth), 1)
        let lineCount = max(text.count / charsPerLine, 1)
        let lineHeight: CGFloat = 20
        let verticalPadding: CGFloat = 24
        return min(CGFloat(lineCount) * lineHeight + verticalPadding, maxResponseHeight)
    }

    private let cornerRadius: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            inputRow
                .frame(height: Self.inputRowHeight)

            if !suggestions.isEmpty && responseText.isEmpty && !isProcessing {
                suggestionRow
                    .frame(height: Self.suggestionRowHeight)
            }

            // A pending confirmation outranks everything else in the bar — it is
            // the only state where Alfred is blocked waiting on the user.
            if let confirmation = pendingConfirmation {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                confirmationArea(confirmation)
            } else if isProcessing || !responseText.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.08))

                if responseText.isEmpty {
                    loadingRow
                        .frame(height: Self.loadingRowHeight)
                } else {
                    responseArea
                        .frame(minHeight: 44, maxHeight: Self.maxResponseHeight)
                }
            }
        }
        .padding(.top, 4)
        .frame(width: Self.barWidth)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.black.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear { focusInput() }
        .onChange(of: focusToken) { _, _ in focusInput() }
        .onKeyPress(.escape) {
            onEscape()
            return .handled
        }
    }

    // MARK: - Suggestion row

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions.prefix(6), id: \.id) { suggestion in
                    Button(action: {
                        onSuggestionTap(suggestion)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: chipIcon(for: suggestion))
                                .font(.system(size: 9))
                            Text(suggestion.title)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(inputFocused ? 0.15 : 0.08))
                if let logo = Self.logoImage {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "sparkle")
                        .foregroundStyle(.white.opacity(0.85))
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 30, height: 30)

            TextField("Ask Alfred anything…", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .focused($inputFocused)
                .onSubmit { submit() }
                .onChange(of: inputText) { _, newValue in
                    mathResult = MathEvaluator.evaluate(newValue)
                }
                .tint(.white)

            // Spotlight-style instant answer: appears live as you type a math expression,
            // no Enter, no model. Enter copies it (see submit()).
            if let mathResult {
                Text("= \(mathResult)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }

            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 18, height: 18)
            } else if !inputText.isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.white.opacity(0.85))
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 14)
        .animation(.easeInOut(duration: 0.15), value: inputText.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: isProcessing)
    }

    // MARK: - Computer-control confirmation

    /// Approval prompt for computer control, drawn in the bar rather than as a
    /// system modal.
    ///
    /// Shows the *resolved actions* — what Alfred parsed and will actually run —
    /// not the model's raw script, so a mismatch between what was asked for and
    /// what will happen is visible before approving.
    ///
    /// "Don't Run" is the default focus and Esc also denies, so the low-effort
    /// response is the safe one. Nothing here approves on a timeout; the broker
    /// denies after 90s.
    private func confirmationArea(_ confirmation: PendingControlConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Alfred wants to control your Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }

            ScrollView {
                Text(confirmation.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: Self.confirmationScrollHeight)

            HStack(spacing: 8) {
                Button("Don't Run") {
                    ControlConfirmationBroker.shared.resolve(false, source: "bar-button-dont-run")
                }
                .keyboardShortcut(.cancelAction)

                Button("Run") {
                    ControlConfirmationBroker.shared.resolve(true, source: "bar-button-run")
                }
                .keyboardShortcut(.defaultAction)
                .tint(.orange)

                Spacer()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Loading row

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
            Text("Working…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Response area

    private var responseArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.linkified(responseText))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))
                        .tint(Color(red: 0.4, green: 0.7, blue: 1.0))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: responseText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: copyResponse) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(didCopy ? Color.green : .white.opacity(0.55))
                    .padding(5)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(didCopy ? "Copied!" : "Copy")
            .padding(8)
        }
    }

    /// Focus the input so the user can type immediately on activation. A programmatically-shown
    /// NSPanel isn't key yet when `onAppear` fires, so an immediate set is dropped — re-assert a
    /// beat later once the panel is key.
    private func focusInput() {
        inputFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { inputFocused = true }
    }

    private func copyResponse() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(responseText, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
    }

    // Built once and reused; linkified() runs per streamed token as the answer grows.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Detects URLs in the response and makes them clickable links (open in the default browser).
    static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let nsText = text as NSString
        guard nsText.length > 0, let detector = linkDetector
        else { return result }
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upper = AttributedString.Index(stringRange.upperBound, within: result)
            else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }

    // MARK: - Actions

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // If an inline math answer is showing, Enter copies it instead of asking the model.
        if let mathResult {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mathResult, forType: .string)
            inputText = ""
            self.mathResult = nil
            return
        }
        inputText = ""
        onSubmit(text)
    }

    private func chipIcon(for suggestion: ProactiveSuggestion) -> String {
        if !suggestion.icon.isEmpty { return suggestion.icon }
        if suggestion.title.contains("Continue") { return "arrow.trianglehead.forward" }
        if suggestion.title.contains("Review") { return "doc.text.magnifyingglass" }
        if suggestion.title.contains("Debug") { return "ladybug" }
        if suggestion.title.contains("Write") { return "pencil" }
        return "sparkle"
    }

    private static let logoImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "alfred-small-logo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
