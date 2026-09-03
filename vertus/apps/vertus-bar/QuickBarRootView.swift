import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Expansion state (shared between AppDelegate and the view)

final class ExpansionState: ObservableObject {
    /// 0 = fully retracted into the notch; 1 = fully grown out.
    @Published var progress: CGFloat = 0
    /// Current widget height in pt: just the prompt bar while idle,
    /// bar + output pane once VERTUS is answering.
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

// MARK: - Calculator panel metrics

/// The live calculator chip (shown while the prompt parses as math).
/// Fixed output-window height: room for the dimmed expression row, the
/// big result, and breathing room around the chip.
enum MathPreviewMetrics {
    static let windowHeight: CGFloat = 88
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

/// The prompt widget: output pane on top (only while VERTUS is answering),
/// prompt bar below, clipped by `NotchPanelShape` so the whole thing visually
/// grows out of the notch.
struct NotchPanelContent: View {
    var progress: CGFloat
    var widgetHeight: CGFloat
    /// The VERTUS "A" glyph (white art) — tints white on the dark bar.
    var logo: NSImage?
    @ObservedObject var model: QuickBarViewModel
    var onPickFile: () -> Void
    var onSend: (String) -> Void
    var onNewSession: () -> Void
    /// The prompt has started parsing as a live math expression → the bar
    /// needs room for the calculator output window (and vice versa).
    var onMathChange: (Bool) -> Void

    @State private var prompt = ""

    /// When the whole prompt parses as math, this is its live result —
    /// recomputed from scratch on every keystroke so the answer appears
    /// with no Enter needed. Nil for normal chat text.
    private var mathPreview: MathEvaluator.Result? {
        MathEvaluator.evaluate(prompt)
    }

    /// The output window is needed when there's a live math result, a math
    /// expression in progress, or an existing conversation; idle+plain-text
    /// = no window.
    private var showOutputWindow: Bool {
        mathPreview != nil || isMathInProgress || !model.transcript.isEmpty
    }

    /// The prompt is shaping up into a math expression but doesn't fully
    /// parse yet ("9+", "sqrt(9") — the calculator is engaged.
    private var isMathInProgress: Bool {
        MathEvaluator.isMathInProgress(prompt)
    }

    // Chat auto-follow: while pinned at the bottom, new streamed text
    // keeps the view scrolled to the latest line. ANY upward scroll by
    // the user switches this off instantly (the programmatic follow
    // scroll only ever moves down, so upward motion is always the user
    // reading), and scrolling back to the very bottom switches it on
    // again. That way VERTUS's answer can be read while it's still
    // typing.
    @State private var followLatest = true
    /// Last measured chat content-top offset (named-space y of the
    /// transcript's top edge; 0 at the top, negative as you scroll down).
    @State private var lastTopOffset: CGFloat = 0
    /// Cumulative upward scroll distance since the last downward motion —
    /// a slow drag only unpins once it has really moved this far.
    @State private var upwardMotion: CGFloat = 0
    /// Back within this many points of the true bottom → follow again.
    private let reFollowZone: CGFloat = 8
    /// Cumulative upward motion (points) that counts as "the user scrolled
    /// up to read" and disables the follow.
    private let unpinThreshold: CGFloat = 6
    private static let scrollSpaceName = "chatScroll"

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

    /// Height of the output pane above the bar (0 while idle). The slash
    /// dropdown's reserved bottom space is excluded, so the extra room the
    /// widget gains when the menu opens stays BELOW the prompt strip instead
    /// of being absorbed into the chat pane.
    private var outputHeight: CGFloat {
        max(0, widgetHeight - NotchPanelMetrics.height(promptLines: model.promptLines) - model.slashMenuSpace)
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
            slashSuggestionsOverlay
        }
        .frame(width: NotchPanelMetrics.topWidth, height: widgetHeight)
        .mask(NotchPanelShape(progress: progress, expandedHeight: widgetHeight))
        .clipped()
        .onChange(of: prompt) { _ in
            // Live calculator: growing/shrinking the output window as the
            // prompt enters/leaves "math mode" (Enter is not involved).
            onMathChange(mathPreview != nil || isMathInProgress)
            // '/'-command autocomplete: suggest while the text is a bare
            // /token, exactly like the vertus CLI's slash menu.
            model.updateSlashSuggestions(for: prompt)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vertusAppendPrompt)) { note in
            guard let path = note.object as? String else { return }
            appendPath(path)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDroppedProviders(providers)
            return true
        }
    }

    // MARK: Top bar — VERTUS logo (click to attach a file), white dots (right).

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

            // New session: small square with a pencil; clears VERTUS's
            // output and starts a fresh session.
            Button(action: onNewSession) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("New session (clears Vertus's output)")
            .frame(width: 14, height: 14)
            .position(x: pencilCenterX, y: 13.75)
        }
    }

    // MARK: Output pane — chat transcript: your prompts and VERTUS's answers
    // as bubbles, capped at ten visible lines; scrolls beyond that. Shown
    // above the prompt bar from the first message on.

    private var outputPane: some View {
        Group {
            if let math = mathPreview {
                mathPane(math)          // live calculator chip wins
            } else if isMathInProgress {
                pendingMathPane         // mid-expression: keep the window
            } else if !model.transcript.isEmpty {
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
        .opacity(showOutputWindow && outputHeight > 0 ? contentReveal : 0)
        .allowsHitTesting(showOutputWindow && outputHeight > 0 && contentReveal > 0.5)
    }

    /// Dimmed echo of the raw prompt while the user is mid-expression and
    /// no complete result exists yet — keeps the output window put instead
    /// of shutting it between keystrokes.
    private var pendingMathPane: some View {
        ZStack {
            Color.clear
            Text(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13, weight: .regular))
                .italic()
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(white: 0.12))
                )
        }
    }

    /// Calculator display: the answer, centered in the chat window. A dimmed
    /// normalized form of the expression sits above the big result; a lone
    /// number just shows the number itself.
    private func mathPane(_ result: MathEvaluator.Result) -> some View {
        let formatted = MathEvaluator.format(result.value)
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let showExpression = formatted != raw
        return ZStack {
            Color.clear
            VStack(spacing: 6) {
                if showExpression {
                    Text(result.rendered)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                Text(formatted)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.16))
            )
        }
    }

    /// Scrollable chat: one bubble per transcript entry; the newest text is
    /// always followed. A "thinking" bubble with animated dots sits at the
    /// bottom while VERTUS is working on a reply that hasn't produced text.
    private var chatPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.transcript) { entry in
                        TranscriptBubbleView(entry: entry).id(entry.id)
                    }
                    if model.isThinking {
                        thinkingBubble.id("thinking")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, NotchPanelMetrics.chatTopPad)
                .padding(.bottom, NotchPanelMetrics.outputBottomInset)
                .background(scrollMeasurer)
            }
            .coordinateSpace(name: Self.scrollSpaceName)
            .onPreferenceChange(ChatScrollMetricsKey.self) { metrics in
                trackScroll(metrics)
            }
            .onChange(of: model.transcriptText) { _ in
                // Only follow while the user is still pinned to the bottom —
                // if they've scrolled up to read, leave their place alone.
                guard followLatest else { return }
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

    /// Zero-size geometry reader pinned behind the whole transcript: it
    /// reports the content's top offset inside the scroll view and its
    /// total (padded) height, re-evaluated on every scroll frame and on
    /// every layout change — that's what `trackScroll` decides from.
    private var scrollMeasurer: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ChatScrollMetricsKey.self,
                value: ChatScrollMetrics(
                    topOffset: geo.frame(in: .named(Self.scrollSpaceName)).minY,
                    contentHeight: geo.size.height
                )
            )
        }
    }

    /// Receives the chat's scroll/layout metrics on every change and
    /// maintains the follow-the-latest flag:
    /// - while following, any real upward motion disables it instantly —
    ///   the programmatic follow scroll only ever moves down, so upward
    ///   motion is always the user scrolling away to read;
    /// - while not following, arriving back within `reFollowZone` of the
    ///   true bottom re-enables it, so the view tracks the newest text
    ///   again once the user returns to the live edge.
    private func trackScroll(_ metrics: ChatScrollMetrics) {
        let maxOffset = max(0, metrics.contentHeight - outputHeight)
        let delta = metrics.topOffset - lastTopOffset
        lastTopOffset = metrics.topOffset
        if delta > 0 {
            upwardMotion += delta
        } else {
            upwardMotion = 0
        }
        if followLatest {
            if upwardMotion > unpinThreshold {
                followLatest = false
                vertusTrace("chat follow disabled — user scrolled up")
            }
        } else if metrics.topOffset + maxOffset <= reFollowZone {
            followLatest = true
            vertusTrace("chat follow enabled — back at the bottom")
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

    // MARK: Slash suggestions — compact menu floating just below the prompt
    // strip while the prompt is a bare '/token' (or '/'). Click to complete;
    // it hides itself once a space or non-slash text is typed.

    private var slashSuggestionsOverlay: some View {
        Group {
            if !model.slashSuggestions.isEmpty {
                // Fixed 4-row scrollable dropdown directly below the prompt
                // bar: all matches stay reachable while the menu itself never
                // exceeds four rows. Auto-scrolls back to the top whenever
                // the match list changes (typing re-filters it).
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.slashSuggestions) { cmd in
                                Button {
                                    prompt = model.completeSlash(cmd)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(cmd.name)
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.white)
                                        Text(":")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.35))
                                        Text(cmd.description)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.55))
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .frame(height: slashRowHeight, alignment: .center)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(cmd.name)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(width: 300, height: slashMenuWindowHeight)
                    .onChange(of: model.slashSuggestions) { _ in
                        // Typing re-filters the list — reset to the top so
                        // the best (first) match is always the one showing.
                        if let first = model.slashSuggestions.first {
                            proxy.scrollTo(first.name, anchor: .top)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(white: 0.13, opacity: 0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Below the prompt strip, inside the widget's reserved
                // bottom space (see slashMenuSpace / outputHeight).
                .offset(x: 12, y: slashMenuTopY)
                .transition(.opacity)
                .allowsHitTesting(true)
            }
        }
    }

    /// Top edge for the suggestion menu: anchored to the widget's bottom
    /// edge (6pt margin), inside the reserved band below the prompt strip.
    /// Bottom-anchoring makes the placement immune to divider/gap math: the
    /// widget reserves exactly `slashMenuSpace` under the strip, and the menu
    /// fills the top of that band — so it is ALWAYS below the prompt bar.
    private var slashMenuTopY: CGFloat {
        widgetHeight - 6 - slashMenuWindowHeight
    }

    /// One dropdown row's fixed height (shared with the widget sizing).
    private var slashRowHeight: CGFloat { model.slashRowHeight }

    /// The scrollable dropdown window: exactly 4 rows plus vertical padding —
    /// never taller, regardless of how many skills match.
    private var slashMenuWindowHeight: CGFloat {
        min(CGFloat(model.slashSuggestions.count), 4) * slashRowHeight + 8
    }

    // MARK: Input row — multi-line prompt editor (3 visible lines, scrolls
    // beyond), no send button; Return sends, Shift+Return inserts a newline.

    private var inputRow: some View {
        return ZStack(alignment: .topLeading) {
            // Idle placeholder — slightly faded; hides as soon as the user types.
            if prompt.isEmpty {
                Text("Ask Vertus anything...")
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
        vertusTrace("submit: '\(text)'")
        prompt = ""
        // Sending a new message returns to the live bottom — the message
        // and the reply stream follow from there.
        followLatest = true
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
}

// MARK: - Root view

struct QuickBarRootView: View {
    /// The VERTUS logo shown in the top-left of the bar (click = attach file).
    var logo: NSImage?
    @ObservedObject var expansionState: ExpansionState

    @StateObject private var model = QuickBarViewModel()
    /// True while the prompt currently parses as a live math expression —
    /// the bar shows the result chip instead of (or dimming) the chat.
    @State private var mathActive = false

    var body: some View {
        NotchPanelContent(
            progress: expansionState.progress,
            widgetHeight: expansionState.widgetHeight,
            logo: logo,
            model: model,
            onPickFile: pickFile,
            onSend: { text in
                // Sending appends to the conversation — past prompts and
                // VERTUS's replies stay visible above; the pencil icon
                // explicitly starts a fresh session.
                model.send(text)
            },
            onNewSession: {
                vertusTrace("new session via toolbar icon")
                model.newSession()
            },
            onMathChange: { active in
                if mathActive != active {
                    mathActive = active
                    refreshWidgetHeight()
                }
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
        .onChange(of: model.transcriptText) { _ in refreshWidgetHeight() }
        .onChange(of: model.promptLines) { _ in refreshWidgetHeight() }
        .onChange(of: model.slashSuggestions) { _ in refreshWidgetHeight() }
        .onAppear {
            let args = CommandLine.arguments
            if args.contains("--verify-output") || args.contains("--demo-output") {
                vertusTrace("seeding demo output")
                model.seedDemoOutput()
            } else if args.contains("--demo-long") || args.contains("--verify-long") {
                vertusTrace("seeding long demo output")
                model.seedLongOutput()
            }
        }
    }

    /// Idle → just the prompt bar; from the first message on, the chat pane
    /// grows in above it — sized to the transcript, capped at ten visible
    /// lines. Cleared by a new session.
    ///
    /// The size SNAPS — never animates — so the bar can't visibly drift or
    /// jitter on screen.
    ///
    /// While VERTUS is streaming with output on screen the widget only ever
    /// GROWS: every new chunk of answer text raises the target, so the bar
    /// reaches its full (ten-line) size as the answer arrives — no toggle
    /// off/on needed. A mid-stream SHRINK is ignored (that per-chunk churn
    /// was the jitter); the shrink is applied the moment the turn ends.
    private func refreshWidgetHeight() {
        // The slash dropdown lives BELOW the prompt strip: the widget adds a
        // reserved band under the strip (menu height + breathing room) in
        // both idle and chatting states, so the strip floats above the
        // dropdown instead of the menu being clipped by the panel edge.
        let menuExtra = model.slashMenuSpace
        let active = mathActive || !model.transcript.isEmpty
        let lines = model.promptLines
        let target = (active
            ? NotchPanelMetrics.height(promptLines: lines) + desiredOutputHeight()
            : NotchPanelMetrics.idleHeight(promptLines: lines)) + menuExtra
        vertusTrace("refreshWidgetHeight active=\(active) current=\(expansionState.widgetHeight) target=\(target)")
        guard expansionState.widgetHeight != target else { return }
        // Mid-stream the widget only grows; shrinking waits for the turn to
        // end (isStreaming flips false) so chunk updates can't churn layout.
        if model.isStreaming && model.hasOutput, target < expansionState.widgetHeight { return }
        expansionState.widgetHeight = target
    }

    /// Chat-window height (the scrollable area between the notch band and
    /// the prompt strip): fits the chat exactly — measured with the same font
    /// metrics the bubbles render with — capped at ten visible lines;
    /// anything larger scrolls inside the fixed-size window.
    private func desiredOutputHeight() -> CGFloat {
        // Live calculator: a fixed window sized for the centered chip.
        if mathActive { return MathPreviewMetrics.windowHeight }
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
        vertusTrace("pickFile: activating and presenting open panel")
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
                name: .vertusAppendPrompt,
                object: url.path
            )
            // Bring the bar back to the front and refocus the input so the
            // selected path is ready to send.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .vertusFocusInput, object: nil)
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

// MARK: - Chat scroll metrics

/// Where the chat content sits inside its scroll view: `topOffset` is the
/// distance from the viewport's top edge to the content's top edge (0 at
/// the top, negative as you scroll toward the bottom) and `contentHeight`
/// is the full (padded) height of the transcript. Fed to the follow-the-
/// latest scroll behavior via `ChatScrollMetricsKey`.
private struct ChatScrollMetrics: Equatable {
    var topOffset: CGFloat = 0
    var contentHeight: CGFloat = 0
}

private struct ChatScrollMetricsKey: PreferenceKey {
    static var defaultValue = ChatScrollMetrics()
    static func reduce(value: inout ChatScrollMetrics, nextValue: () -> ChatScrollMetrics) {
        value = nextValue()
    }
}

// MARK: - Chat bubble

/// One transcript message as a rounded bubble — white with black text for
/// your prompts (right side, classic messenger style), dark gray with white
/// text for VERTUS's replies (left side). VERTUS's replies carry a small
/// always-present copy button (brighter on hover) that puts the reply's
/// text on the pasteboard and briefly flashes a checkmark; the text itself
/// also stays selectable for the usual Cmd+C path.
struct TranscriptBubbleView: View {
    var entry: TranscriptEntry

    @State private var hovering = false
    @State private var justCopied = false

    private var isYou: Bool { entry.role == "you" }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            bubble
            if !isYou {
                copyButton
            }
        }
        .onHover { hovering = $0 }
    }

    /// The message bubble itself: hugging text in a rounded rect, full-row
    /// frame so prompts sit right-aligned and replies left-aligned.
    private var bubble: some View {
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

    /// Small copy button pinned to the right of each reply; copies the
    /// reply's text to the pasteboard and flashes a checkmark. Always
    /// visible at low opacity so the affordance is discoverable, brighter
    /// on hover, and it needs no menu bar — it works on tap, period.
    private var copyButton: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(entry.text, forType: .string)
            justCopied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                justCopied = false
            }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.4))
        }
        .buttonStyle(.plain)
        .help("Copy reply")
        .padding(.top, 7)
        .animation(.easeOut(duration: 0.15), value: justCopied)
    }

    /// Markdown-rendered Text for VERTUS's replies (inline syntax only,
    /// whitespace preserved — same rendering as before).
    private func renderedMarkdown(_ text: String) -> Text {
        Text((try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text))
    }
}

// MARK: - Prompt editor

/// Multi-line prompt field backed by NSTextView: white text that wraps to
/// the next line (no send button to run under), capped at three visible
/// lines — anything longer scrolls inside the strip. Return submits,
/// Shift+Return inserts a newline, and the editor refocuses when the bar
/// grows out of the notch (`.vertusFocusInput`).
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
                name: .vertusFocusInput, object: nil
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