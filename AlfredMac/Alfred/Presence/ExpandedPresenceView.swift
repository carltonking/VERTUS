import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Foundation

/// Full notch-native bar: input, streaming response, and the computer-control
/// confirmation. Suggestion chips were removed with Alfred's proactive engine —
/// Hermes does not emit them.
///
/// Layout (350 px wide):
/// ┌──────────────────────────────┐
/// │  [logo]  [  Ask anything…  ] │
/// │  ─────────────────────────── │
/// │  Response text scrolls here  │
/// │  ...                        │
/// └──────────────────────────────┘
// MARK: - Alfred logo

/// The alfred-menubar logo (template) reused everywhere the bar shows itself,
/// sized to the input row's small controls. Falls back to doc if missing.
private var alfredLogo: Image {
    if let url = Bundle.module.url(forResource: "alfred-menubar", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
        image.isTemplate = true
        return Image(nsImage: image)
    }
    return Image(systemName: "doc")
}

struct ExpandedPresenceView: View {
    @Binding var responseText: String
    @Binding var isProcessing: Bool
    @Binding var pendingConfirmation: PendingControlConfirmation?
    @Binding var pendingEmailReply: PendingEmailReply?
    let focusToken: Int
    let onSubmit: (String, FileAttachment?) -> Void
    let onEscape: () -> Void

    @State private var inputText: String = ""
    @State private var mathResult: String?
    @FocusState private var inputFocused: Bool
    @State private var didCopy = false
    /// A file the user attached on purpose (picker or drag-drop): a picture the
    /// model sees or a local text file the model reads.
    @State private var attachedFile: FileAttachment?
    @State private var attachedThumbnail: NSImage?
    @State private var isDropTarget = false

    static let barWidth: CGFloat = 350

    static let inputRowHeight: CGFloat = 64
    static let loadingRowHeight: CGFloat = 44
    // Output window grows with the response but caps at ~5 lines, then scrolls inside.
    // 5 lines × 20pt line height + 24pt vertical padding.
    static let maxResponseHeight: CGFloat = 124
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

    /// The placeholder switches when an email alert is waiting: typing here means
    /// "send this as my reply", not "ask me something".
    private var placeholder: String {
        if pendingEmailReply != nil { return "Reply to \(pendingEmailReply!.senderName)…" }
        if attachedFile != nil { return "Ask about the attached file…" }
        return "Ask Alfred anything…"
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow
                .frame(height: Self.inputRowHeight)

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

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 10) {
            // Attach a file (or drop one onto the bar): a screenshot, a poster,
            // a document, code — anything Alfred should *see* or *read*.
            if let attachedFile {
                attachChip(attachment: attachedFile)
            } else {
                Button(action: openFilePicker) {
                    alfredLogo
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 21, height: 21)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Attach a file (or drop one here)")
            }

            TextField(placeholder, text: $inputText)
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
            } else if !inputText.isEmpty || attachedFile != nil {
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
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return attach(contentsOf: url)
        } isTargeted: { isTargeted in
            isDropTarget = isTargeted
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTarget ? Color.white.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }

    /// The attached file: a thumbnail for images, a doc icon + name for text
    /// files, both with a remove affordance. Clicking it re-opens the picker.
    private func attachChip(attachment: FileAttachment) -> some View {
        HStack(spacing: 4) {
            Button {
                openFilePicker()
            } label: {
                if case .image = attachment, let attachedThumbnail {
                    Image(nsImage: attachedThumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if case .text(let name, _) = attachment {
                    Text(name)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: 90)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .buttonStyle(.plain)
            .help("Replace file")

            Button {
                attachedFile = nil
                attachedThumbnail = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Remove file")
        }
    }

    // MARK: - File attachment

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Attach a file for Alfred"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if !attach(contentsOf: url) {
                // Keep the panel-centered contract: a binary Alfred can't read is
                // silently refused for now (it stays visible, so the user can swap).
            }
            focusInput()
        }
    }

    /// Decode any picked/dropped file: images become PNG attachments the model
    /// sees, UTF-8 text rides as readable content. Returns false when the file
    /// is neither an image nor decodable text.
    private func attach(contentsOf url: URL) -> Bool {
        guard let attachment = FileAttachment.decode(url: url) else { return false }
        attachedFile = attachment
        attachedThumbnail = (try? Data(contentsOf: url)).flatMap { NSImage(data: $0) }
        return true
    }

    /// The upload-less flow: user copied a picture (⌘⇧4 crop, a photo, an invite)
    /// and typed something calendar-ish. Alfred attaches the clipboard image.
    private static let calendarIntent = #"(?i)\b(calendar|appointments?|meeting|invite|invitation|rsvp|schedule|shift|booking|reservation|event)\b"#

    private func attachClipboardImageIfCalendarish() {
        guard attachedFile == nil else { return }
        let text = inputText
        guard text.range(of: Self.calendarIntent, options: .regularExpression) != nil else { return }
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let attachment = ImageAttachment.png(from: data)
        else { return }
        self.attachedFile = .image(attachment)
        attachedThumbnail = NSImage(data: data)
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
                .keyboardShortcut(.defaultAction)
                // The default-action (Return) shortcut is deliberately bound to
                // "Don't Run": a stray Return while the panel has key must deny,
                // never approve. Approving requires an explicit mouse click, so
                // nothing typeless or timed-out can send a message or touch the
                // Mac by accident.

                Button("Run") {
                    ControlConfirmationBroker.shared.resolve(true, source: "bar-button-run")
                }

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
                    Text(Self.linkified(Self.plainText(responseText)))
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

    /// Strips the markdown crust a model can leave on its answers — asterisks,
    /// backticks, header hashes, bullet markers — so the bar reads like plain
    /// conversation, not a rendered document. Runs on every streamed chunk, so
    /// it stays regex-only and allocation-light.
    static func plainText(_ text: String) -> String {
        var result = text
        // Emphasis and inline code: drop *, **, *** and backticks entirely.
        result = result.replacingOccurrences(of: #"\*+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "`", with: "")

        // Line-level furniture: headers, blockquotes, bullets, rules.
        let lines = result.components(separatedBy: "\n").map { line -> String in
            var out = line
            for pattern in [#"^#{1,6}\s+"#, #"^>\s+"#, #"^[-*•◦▪]\s+"#, #"^\s*[-*_]{3,}\s*$"#] {
                out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
        result = lines.joined(separator: "\n")
        // Collapse runs of blank lines so a list-shaped answer still reads once.
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result
    }

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
        // If an inline math answer is showing, Enter copies it instead of asking the model.
        if let mathResult, attachedFile == nil {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mathResult, forType: .string)
            inputText = ""
            self.mathResult = nil
            return
        }
        guard !text.isEmpty || attachedFile != nil else { return }

        // No explicit attachment yet? If an image is sitting in the clipboard and
        // the request sounds calendar-ish ("add this to my calendar"), attach it.
        attachClipboardImageIfCalendarish()

        let attachment = attachedFile
        attachedFile = nil
        attachedThumbnail = nil
        inputText = ""
        self.mathResult = nil
        onSubmit(text, attachment)
    }
}
