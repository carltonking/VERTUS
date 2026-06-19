import AppKit
import SwiftUI

final class BarWindow: NSPanel {

    static let notchWidth: CGFloat = 350
    static let collapsedHeight: CGFloat = 4
    static let inputAreaHeight: CGFloat = 74
    static let maxBarHeight: CGFloat = 480

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.notchWidth, height: Self.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        alphaValue = 0
    }

    // MARK: - Notch position

    private func notchFrame(height: CGFloat) -> NSRect {
        guard let screen = targetScreen() else { return .zero }
        let x = screen.visibleFrame.midX - Self.notchWidth / 2
        let topY = screen.visibleFrame.maxY
        return NSRect(x: x, y: topY - height, width: Self.notchWidth, height: height)
    }

    // MARK: - Collapse / Expand

    func showCollapsed() {
        let frame = notchFrame(height: Self.collapsedHeight)
        setFrame(frame, display: false)
        alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0.55
        }
    }

    func expand(toHeight height: CGFloat) {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        let target = notchFrame(height: height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.1, 0.4, 1.0)
            animator().alphaValue = 1.0
            animator().setFrame(target, display: true)
        }
    }

    @discardableResult
    func collapse(completion: (() -> Void)? = nil) -> Bool {
        guard isVisible else { return false }
        let target = notchFrame(height: Self.collapsedHeight)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0.55
            animator().setFrame(target, display: true)
        }, completionHandler: {
            completion?()
        })
        return true
    }

    func hideImmediately() {
        orderOut(nil)
    }

    // MARK: - Resize

    func resizeNotch(toHeight height: CGFloat) {
        let target = notchFrame(height: height)
        let diff = abs(frame.height - height)
        setFrame(target, display: true, animate: diff > 10)
    }

    // MARK: - Overrides

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Screen helper

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first
    }
}
