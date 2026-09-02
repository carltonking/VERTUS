import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Expansion state (shared between AppDelegate and the view)

final class ExpansionState: ObservableObject {
    /// 0 = fully retracted into the notch; 1 = fully grown out.
    @Published var progress: CGFloat = 0
    /// Current widget height in pt: just the prompt bar while idle,
    /// bar + output pane once ALFRED is answering.
    @Published var widgetHeight: CGFloat = NotchPanelMetrics.idleHeight()
    var isExpanded: Bool { progress > 0.6 }
}

// MARK: - Notch panel geometry
// Body measured from the reference screenshot (4112×2658 px @2x → 2056×1329 pt):
// 316×127 pt body, 329 pt top edge, chamfered 6.5 pt per side, 17 pt bottom radius.
// The output pane sits above the prompt bar; the whole widget grows out of the notch.

enum NotchPanelMetrics {
    static let topWidth: CGFloat = 329          // widest row (flush with screen top)
    static let bodyWidth: CGFloat = 316         // straight sides
    // Layout, top to bottom: [notch band with icons] [chat scroll window,
    // clipped between band and divider] [divider] [prompt strip].
    /// Fallback top band (no camera notch detected / hidden menu bar).
    static let notchBand: CGFloat = 26          // icons/logo row; window clips below it
    static let windowGap: CGFloat = 6           // chat window bottom → divider
    static let idleGap: CGFloat = 16            // idle: notch band → divider (empty row)
    // Prompt strip: a 3-line editor — text wraps to the next line, and once
    // it passes three lines the editor scrolls inside the fixed strip.
    static let promptFontSize: CGFloat = 13.4
    /// The layout manager's own line height for our font (16.0) — must match
    /// the editor's real line fragments exactly, or the 1-line count drifts
    /// to 2 (16.0 / 15.78 rounds up).
    static let promptLineHeight: CGFloat =
        NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: promptFontSize))
    static let promptMaxLines: CGFloat = 3
    static let promptTopPad: CGFloat = 8
    static let promptBottomPad: CGFloat = 10

    /// Strip height for a given number of visible prompt lines (clamped to
    /// 1…3): one line by default — the strip only grows once the text in
    /// the editor actually wraps past a single line.
    static func promptStripHeight(lines: CGFloat) -> CGFloat {
        let visible = min(max(lines, 1), promptMaxLines)
        return promptTopPad + visible * promptLineHeight + promptBottomPad
    }
    static let chatTopPad: CGFloat = 4          // breathing room inside the window
    static let outputBottomInset: CGFloat = 10
    static let outputLineHeight: CGFloat = 16.5
    static let maxOutputLines = 10
    /// Chat window max: 10 wrapped lines + inner padding. The window ends
    /// where the prompt bar starts — text never overlaps the bar.
    static let maxScrollWindowHeight =
        chatTopPad + CGFloat(maxOutputLines) * outputLineHeight + outputBottomInset

    /// Where the real camera notch ends (distance from the top of the
    /// screen), measured from the menu-bar auxiliary areas; falls back to
    /// `notchBand` when there's no notch. Chat text never renders above this.
    static var topBandHeight: CGFloat {
        guard let screen = NSScreen.main else { return notchBand }
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              left.maxX < right.minX else { return notchBand }
        // The auxiliary areas' bottom edge is the notch's bottom edge
        // (screen coords are y-up, so distance from the top = maxY - minY).
        return max(notchBand, screen.frame.maxY - left.minY)
    }

    /// Active base height: top band + window gap + prompt strip.
    static func height(promptLines: CGFloat = 1) -> CGFloat {
        topBandHeight + windowGap + promptStripHeight(lines: promptLines)
    }
    /// Idle height: top band + idle empty row + prompt strip.
    static func idleHeight(promptLines: CGFloat = 1) -> CGFloat {
        topBandHeight + idleGap + promptStripHeight(lines: promptLines)
    }
    /// Maximum total widget height (top band + full 10-line window + strip).
    static func maxWidgetHeight(promptLines: CGFloat = 1) -> CGFloat {
        topBandHeight + windowGap + promptStripHeight(lines: promptLines) + maxScrollWindowHeight
    }
    static let cornerRadius: CGFloat = 17
    /// Corner control-point distance, fitted so the rendered corner matches
    /// the reference's row profile within ~1 px.
    static let cornerControl: CGFloat = 7.2
    /// Chamfer is two straight segments: a steep 2:1 cut then a shallow 1:4.3
    /// knee to the body (fitted to the reference outline).
    static let chamferKneeInset: CGFloat = 5
    static let chamferKneeHeight: CGFloat = 2.5
    static let chamferInset: CGFloat = 6.5      // top edge wider than body, per side
    static let chamferHeight: CGFloat = 6
    /// Resting (hidden) shape: a small notch nub.
    static let nubWidth: CGFloat = 106
    static let nubHeight: CGFloat = 26
    static let nubCornerRadius: CGFloat = 13
    /// Window chrome size. Slightly wider than the panel so the transparent
    /// window barely overlaps the menu bar; height follows the widget.
    static let windowWidth: CGFloat = 331
}

// MARK: - The panel shape

/// Shape of the notch widget. `progress` morphs it from a notch-sized nub
/// (0) into the full widget (1), anchored at the top edge and centered
/// horizontally, so it appears to grow out of the notch. `expandedHeight`
/// animates too: idle is just the prompt bar, active grows the output pane.
struct NotchPanelShape: Shape {
    var progress: CGFloat
    var expandedHeight: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, expandedHeight) }
        set {
            progress = newValue.first
            expandedHeight = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }

        let topW  = lerp(NotchPanelMetrics.nubWidth, NotchPanelMetrics.topWidth)
        let bodyW = lerp(NotchPanelMetrics.nubWidth, NotchPanelMetrics.bodyWidth)
        let h     = lerp(NotchPanelMetrics.nubHeight, expandedHeight)
        let r     = min(lerp(NotchPanelMetrics.nubCornerRadius, NotchPanelMetrics.cornerRadius), h / 2)
        let k     = NotchPanelMetrics.cornerControl * (r / NotchPanelMetrics.cornerRadius)
        // Chamfer bends (lerp from the nub where they are degenerate).
        let kx = lerp(0, NotchPanelMetrics.chamferKneeInset)
        let ky = lerp(0, NotchPanelMetrics.chamferKneeHeight)
        let cx = lerp(0, NotchPanelMetrics.chamferInset)
        let cy = lerp(0, NotchPanelMetrics.chamferHeight)

        let midX  = rect.midX
        let topL  = midX - topW / 2
        let topR  = midX + topW / 2
        let bodyL = midX - bodyW / 2
        let bodyR = midX + bodyW / 2
        let tangent = lerp(NotchPanelMetrics.nubHeight - r, expandedHeight - r - 0.4)

        var path = Path()
        path.move(to: CGPoint(x: topL, y: 0))
        path.addLine(to: CGPoint(x: topR, y: 0))
        // Right chamfer (steep cut, then shallow knee), fitted to the reference.
        path.addLine(to: CGPoint(x: topR - kx, y: ky))
        path.addLine(to: CGPoint(x: bodyR, y: cy))
        // Right side.
        path.addLine(to: CGPoint(x: bodyR, y: tangent))
        // Bottom-right corner (cubic, fitted to the reference's soft corner).
        path.addCurve(
            to: CGPoint(x: bodyR - r, y: h),
            control1: CGPoint(x: bodyR, y: tangent + k),
            control2: CGPoint(x: bodyR - r + k, y: h)
        )
        path.addLine(to: CGPoint(x: bodyL + r, y: h))
        // Bottom-left corner.
        path.addCurve(
            to: CGPoint(x: bodyL, y: tangent),
            control1: CGPoint(x: bodyL + r - k, y: h),
            control2: CGPoint(x: bodyL, y: tangent + k)
        )
        // Left side and chamfer back to the top edge.
        path.addLine(to: CGPoint(x: bodyL, y: cy))
        path.addLine(to: CGPoint(x: topL + kx, y: ky))
        path.closeSubpath()
        return path
    }
}

// MARK: - The notch panel

/// The prompt widget: output pane on top (only while ALFRED is answering),
/// prompt bar below, clipped by `NotchPanelShape` so the whole thing visually
/// grows out of the notch.
struct NotchPanelContent: View {
    var progress: CGFloat
    var widgetHeight: CGFloat
    /// The ALFRED "A" glyph (white art) — tints white on the dark bar.
    var logo: NSImage?
    @ObservedObject var model: QuickBarViewModel
    var onPickFile: () -> Void
    var onSend: (String) -> Void
    var onNewSession: () -> Void

    @State private var prompt = ""

    /// Horizontal center of the logo (ZStack coords): centered between the
    /// window's left end and the notch, so it sits in the left shoulder.
    /// Falls back to the reference-fitted position on non-notched displays.
    private var logoCenterX: CGFloat {
        guard let screen = NSScreen.main,
              let left = screen.auxiliaryTopLeftArea,
              screen.auxiliaryTopRightArea != nil else { return 16.5 }
        let windowLeft = screen.frame.midX - NotchPanelMetrics.windowWidth / 2
        let mid = (windowLeft + left.maxX) / 2
        return max(16.5, mid - windowLeft - 1)
    }

    /// Horizontal center of the new-session button (ZStack coords): mirror of
    /// the logo — centered between the window's right end and the notch.
    private var pencilCenterX: CGFloat {
        guard let screen = NSScreen.main,
              let right = screen.auxiliaryTopRightArea,
              screen.auxiliaryTopLeftArea != nil else { return 308.25 }
        let windowLeft = screen.frame.midX - NotchPanelMetrics.windowWidth / 2
        let mid = (screen.frame.midX + NotchPanelMetrics.windowWidth / 2 + right.minX) / 2
        return min(308.25, mid - windowLeft - 1)
    }

    /// 0 → 1 as the panel finishes growing out of the notch.
    private var contentReveal: CGFloat {
        min(1, max(0, (progress - 0.55) / 0.25))
    }

    /// Height of the output pane above the bar (0 while idle).
    private var outputHeight: CGFloat {
        max(0, widgetHeight - NotchPanelMetrics.height(promptLines: model.promptLines))
    }

    /// Empty band below the notch: a clear empty row when idle, a small gap
    /// under the chat window while chatting (spec: notch row, empty row,
    /// divider — the empty row is where the conversation grows).
    private var dividerY: CGFloat {
        let gap = outputHeight > 0
            ? NotchPanelMetrics.windowGap
            : NotchPanelMetrics.idleGap
        return outputHeight + NotchPanelMetrics.topBandHeight + gap
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            outputPane
            topBar
            divider
            inputRow
        }
        .frame(width: NotchPanelMetrics.topWidth, height: widgetHeight)
        .mask(NotchPanelShape(progress: progress, expandedHeight: widgetHeight))
        .clipped()
        .onReceive(NotificationCenter.default.publisher(for: .alfredAppendPrompt)) { note in
            guard let path = note.object as? String else { return }
            appendPath(path)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDroppedProviders(providers)
            return true
        }
    }

    // MARK: Top bar — ALFRED logo (click to attach a file), white dots (right).

    private var topBar: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onPickFile) {
                Group {
                    if let logo {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .foregroundStyle(.white)
                    } else {
                        // Fallback: attach icon.
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .regular))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Attach a file")
            .frame(width: 14, height: 14)
            .position(x: logoCenterX, y: 12.5)

            // New session: small square with a pencil; clears ALFRED's
            // output and starts a fresh session.
            Button(action: onNewSession) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("New session (clears Alfred's output)")
            .frame(width: 14, height: 14)
            .position(x: pencilCenterX, y: 13.75)
        }
    }

    // MARK: Output pane — chat transcript: your prompts and ALFRED's answers
    // as bubbles, capped at ten visible lines; scrolls beyond that. Shown
    // above the prompt bar from the first message on.

    private var outputPane: some View {
        Group {
            if !model.transcript.isEmpty {
                chatPane
            } else {
                Color.clear
            }
        }
        .frame(
            width: NotchPanelMetrics.bodyWidth,
            height: max(0, outputHeight),
            alignment: .top
        )
        // The window starts right underneath the (measured) notch, so
        // scrolling never sends text up into the icons/notch area.
        .offset(x: NotchPanelMetrics.chamferInset, y: NotchPanelMetrics.topBandHeight)
        .opacity(!model.transcript.isEmpty && outputHeight > 0 ? contentReveal : 0)
        .allowsHitTesting(!model.transcript.isEmpty && outputHeight > 0 && contentReveal > 0.5)
    }

    /// Scrollable chat: one bubble per transcript entry; the newest text is
    /// always followed. A "thinking" bubble with animated dots sits at the
    /// bottom while ALFRED is working on a reply that hasn't produced text.
    private var chatPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.transcript) { entry in
                        chatBubble(for: entry).id(entry.id)
                    }
                    if model.isThinking {
                        thinkingBubble.id("thinking")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, NotchPanelMetrics.chatTopPad)
                .padding(.bottom, NotchPanelMetrics.outputBottomInset)
            }
            .onChange(of: model.transcriptText) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(scrollAnchor(), anchor: .bottom)
                }
            }
            .onAppear {
                // Defer past the initial layout pass — scrollTo issued during
                // first layout is dropped by SwiftUI.
                DispatchQueue.main.async {
                    proxy.scrollTo(scrollAnchor(), anchor: .bottom)
                }
            }
        }
    }

    /// Which bubble to keep pinned at the bottom while chatting: the thinking
    /// bubble while waiting, otherwise the newest message entry (stable id).
    private func scrollAnchor() -> AnyHashable {
        if model.isThinking {
            return "thinking"
        }
        if let last = model.transcript.last {
            return last.id
        }
        return ""
    }

    /// One chat message in a rounded bubble — white with black text for
    /// your prompts (right side, classic messenger style), dark gray with
    /// white text for ALFRED's replies (left side).
    @ViewBuilder
    private func chatBubble(for entry: TranscriptEntry) -> some View {
        let isYou = entry.role == "you"
        Group {
            if isYou {
                Text(entry.text)
                    .foregroundStyle(.black)
            } else {
                renderedMarkdown(entry.text)
                    .foregroundStyle(.white)
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isYou ? Color.white : Color(white: 0.22))
        )
        .frame(maxWidth: .infinity, alignment: isYou ? .trailing : .leading)
    }

    /// "thinking" with three animated dots while the reply is still coming.
    private var thinkingBubble: some View {
        HStack(spacing: 6) {
            Text("working")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))
            TypingDots()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.22))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Divider — full-width 1.5 pt line at the top of the prompt bar.

    private var divider: some View {
        Rectangle()
            .fill(Color(white: 26.0 / 255.0))   // #1A1A1A
            .frame(width: NotchPanelMetrics.bodyWidth, height: 1.5)
            .offset(x: NotchPanelMetrics.chamferInset, y: dividerY)
    }

    // MARK: Input row — multi-line prompt editor (3 visible lines, scrolls
    // beyond), no send button; Return sends, Shift+Return inserts a newline.

    private var inputRow: some View {
        return ZStack(alignment: .topLeading) {
            // Idle placeholder — slightly faded; hides as soon as the user types.
            if prompt.isEmpty {
                Text("Ask Alfred anything...")
                    .font(.system(size: 13.4, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 280, height: 16, alignment: .leading)
                    .offset(x: 30.5, y: dividerY + NotchPanelMetrics.promptTopPad)
                    .allowsHitTesting(false)
            }
            // Wrapping text editor: text goes to the line below instead of
            // running under a button; the strip grows with it, capped at 3
            // visible lines — anything longer scrolls inside the editor.
            PromptTextEditor(text: $prompt, onSubmit: submit) { lines in
                if model.promptLines != lines { model.promptLines = lines }
            }
            .frame(
                width: 280,
                height: max(model.promptLines, 1) * NotchPanelMetrics.promptLineHeight,
                alignment: .topLeading
            )
            .offset(x: 27.5, y: dividerY + NotchPanelMetrics.promptTopPad)
        }
    }

    // MARK: - Actions

    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        alfredTrace("submit: '\(text)'")
        prompt = ""
        onSend(text)
    }

    private func appendPath(_ path: String) {
        prompt = prompt.isEmpty ? path : prompt + " " + path
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var path: String?
                if let url = item as? URL {
                    path = url.path
                } else if let data = item as? Data,
                          let str = String(data: data, encoding: .utf8) {
                    path = str
                }
                if let path {
                    DispatchQueue.main.async { self.appendPath(path) }
                }
            }
        }
    }

    private func renderedMarkdown(_ text: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
        return Text(attributed)
    }
}

// MARK: - Root view

struct QuickBarRootView: View {
    /// The ALFRED logo shown in the top-left of the bar (click = attach file).
    var logo: NSImage?
    @ObservedObject var expansionState: ExpansionState

    @StateObject private var model = QuickBarViewModel()

    var body: some View {
        NotchPanelContent(
            progress: expansionState.progress,
            widgetHeight: expansionState.widgetHeight,
            logo: logo,
            model: model,
            onPickFile: pickFile,
            onSend: { text in
                // Sending appends to the conversation — past prompts and
                // ALFRED's replies stay visible above; the pencil icon
                // explicitly starts a fresh session.
                model.send(text)
            },
            onNewSession: {
                alfredTrace("new session via toolbar icon")
                model.newSession()
            }
        )
        .frame(
            width: NotchPanelMetrics.windowWidth,
            height: expansionState.widgetHeight,
            alignment: .top
        )
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .onChange(of: model.sentAtLeastOnce) { _ in refreshWidgetHeight() }
        .onChange(of: model.isStreaming) { _ in refreshWidgetHeight() }
        .onChange(of: model.transcript.count) { _ in refreshWidgetHeight() }
        .onChange(of: model.promptLines) { _ in refreshWidgetHeight() }
        .onAppear {
            let args = CommandLine.arguments
            if args.contains("--verify-output") || args.contains("--demo-output") {
                alfredTrace("seeding demo output")
                model.seedDemoOutput()
            } else if args.contains("--demo-long") || args.contains("--verify-long") {
                alfredTrace("seeding long demo output")
                model.seedLongOutput()
            }
        }
    }

    /// Idle → just the prompt bar; from the first message on, the chat pane
    /// grows in above it — sized to the transcript, capped at ten visible
    /// lines. Cleared by a new session.
    ///
    /// The size SNAPS — never animates — so the bar can't visibly drift or
    /// jitter on screen. Sizes change only once per turn (at send, and again
    /// at done); while ALFRED is streaming with output the size stays frozen,
    /// so per-chunk text updates can't churn the layout.
    private func refreshWidgetHeight() {
        let active = !model.transcript.isEmpty
        let lines = model.promptLines
        let target = active
            ? NotchPanelMetrics.height(promptLines: lines) + desiredOutputHeight()
            : NotchPanelMetrics.idleHeight(promptLines: lines)
        alfredTrace("refreshWidgetHeight active=\(active) current=\(expansionState.widgetHeight) target=\(target)")
        guard expansionState.widgetHeight != target else { return }
        // Freeze while the answer streams in: the pane resizes at send and
        // at done, never mid-stream (that per-chunk churn was the jitter).
        guard !model.isStreaming || !model.hasOutput else { return }
        expansionState.widgetHeight = target
    }

    /// Chat-window height (the scrollable area between the notch band and
    /// the prompt strip): fits the chat exactly — measured with the same font
    /// metrics the bubbles render with — capped at ten visible lines;
    /// anything larger scrolls inside the fixed-size window.
    private func desiredOutputHeight() -> CGFloat {
        var content: CGFloat = 0
        for (index, entry) in model.transcript.enumerated() {
            if index > 0 { content += 8 }              // gap between bubbles
            content += bubbleHeight(for: entry.text)   // 13 pt text + padding
        }
        if model.isThinking {
            content += 8                               // gap before thinking
            content += thinkingBubbleHeight
        }
        let window = min(
            content + NotchPanelMetrics.chatTopPad + NotchPanelMetrics.outputBottomInset,
            NotchPanelMetrics.maxScrollWindowHeight
        )
        return max(window, NotchPanelMetrics.chatTopPad + NotchPanelMetrics.outputBottomInset)
    }

    /// AppKit line height (the iOS-only `lineHeight` doesn't exist here).
    private func lineHeight(of font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// Height of the "thinking" bubble (12 pt text + 7 pt padding each side).
    private var thinkingBubbleHeight: CGFloat {
        lineHeight(of: NSFont.systemFont(ofSize: 12)) + 14
    }

    /// Height of a 13 pt message wrapped at the bubble's text width, plus
    /// the bubble's vertical padding — mirrors the rendered chat bubble.
    private func bubbleHeight(for text: String) -> CGFloat {
        let width = NotchPanelMetrics.bodyWidth - 50  // 14 pane + 11 bubble padding/side
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        let textHeight = max(
            attributed.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height,
            lineHeight(of: NSFont.systemFont(ofSize: 13))
        )
        return textHeight + 14   // bubble vertical padding (7 pt top + bottom)
    }

    private func pickFile() {
        // The quick bar is a non-activating panel, so the app is never
        // frontmost when the logo is clicked. Activate explicitly before
        // presenting the open panel — otherwise the modal file dialog never
        // appears for the user. The completion-based API is more reliable
        // than runModal() for apps without a key window.
        alfredTrace("pickFile: activating and presenting open panel")
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.level = .screenSaver
        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else { return }
            // Pass the file into the panel prompt.
            NotificationCenter.default.post(
                name: .alfredAppendPrompt,
                object: url.path
            )
            // Bring the bar back to the front and refocus the input so the
            // selected path is ready to send.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .alfredFocusInput, object: nil)
            }
        }
    }
}

// MARK: - Transcript row

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let role: String
    var text: String
}

// MARK: - Prompt editor

/// Multi-line prompt field backed by NSTextView: white text that wraps to
/// the next line (no send button to run under), capped at three visible
/// lines — anything longer scrolls inside the strip. Return submits,
/// Shift+Return inserts a newline, and the editor refocuses when the bar
/// grows out of the notch (`.alfredFocusInput`).
struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: (String) -> Void
    var onLinesChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NotchPanelMetrics.promptFontSize)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 3
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        // External writes (dropped file paths appended by the panel) flow in.
        if textView.string != text {
            textView.string = text
            context.coordinator.publishLines()
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: PromptTextEditor
        weak var textView: NSTextView?

        init(_ parent: PromptTextEditor) {
            self.parent = parent
            super.init()
            // The app delegate posts this after the panel finishes growing
            // out of the notch — refocus the editor then.
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusInput),
                name: .alfredFocusInput, object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func focusInput() {
            DispatchQueue.main.async { [weak self] in
                guard let tv = self?.textView, tv.window != nil else { return }
                tv.window?.makeFirstResponder(tv)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            publishLines()
        }

        /// Recompute the visible (wrapped) line count and publish it — this
        /// grows/shrinks the prompt strip so it hugs the text (1 → 3 lines).
        func publishLines() {
            guard let tv = textView else { return }
            parent.onLinesChange(Self.visibleLineCount(of: tv))
        }

        /// Number of visible wrapped lines in the editor, clamped to the
        /// 3-line cap (the editor scrolls beyond that). Uses the layout
        /// manager's OWN line height so the count is exact (integer), never
        /// rounding a single line up to two.
        static func visibleLineCount(of textView: NSTextView) -> CGFloat {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  let font = textView.font else { return 1 }
            // Early layout passes can lay the editor out at ~0 width, which
            // makes every character wrap; ignore until the width is real.
            guard textView.frame.width >= 100 else { return 1 }
            let used = layoutManager.usedRect(for: container)
            let lh = layoutManager.defaultLineHeight(for: font)
            guard lh > 0 else { return 1 }
            let lines = (used.height / lh).rounded()
            return min(max(lines, 1), NotchPanelMetrics.promptMaxLines)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Plain Return sends; Shift+Return inserts a real newline.
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewline(nil)
                } else {
                    submit()
                }
                return true
            }
            return false
        }

        private func submit() {
            guard let tv = textView else { return }
            let trimmed = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            tv.string = ""
            parent.text = ""
            publishLines()
            parent.onSubmit(trimmed)
        }
    }
}

// MARK: - Typing indicator

/// Three small dots pulsing in sequence — the classic "typing…" indicator.
struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .scaleEffect(animating ? 0.55 : 1)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

#if DEBUG
#Preview {
    QuickBarRootView(expansionState: ExpansionState())
}
#endif