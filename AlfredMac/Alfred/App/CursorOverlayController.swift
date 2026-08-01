import AppKit
import QuartzCore

/// The visual "Alfred cursor" — the Clicky-style helper hand that appears when Alfred takes an
/// action on your screen. It's a transparent, click-through overlay window (so it never steals
/// focus or blocks your clicks) that floats above every app. The cursor is the Alfred logo tinted
/// #1d2434; it emerges from the menu-bar icon, glides to each target Alfred is about to act on,
/// pulses a ripple when it clicks, and retreats back into the menu-bar icon when the task is done.
///
/// This layer is purely cosmetic: the real input events are posted by `ComputerControlCapability`.
/// The overlay just tells the *story* of what Alfred is doing, in sync with those events.
///
/// The overlay-window setup and the arcing "swoop" glide follow the approach in Clicky
/// (github.com/farzaa/clicky, MIT © 2026 Farza): a per-... transparent, click-through, all-spaces
/// panel at `.screenSaver` level, and a quadratic-Bézier flight with a distance-scaled duration and
/// a mid-flight scale pulse. Re-implemented here in Alfred's idioms and branded (red Alfred logo).
@MainActor
final class CursorOverlayController {

    /// Alfred's cursor color: a bold red so it's easy to spot on any screen.
    static let cursorColor = NSColor(srgbRed: 0xE5 / 255.0, green: 0x1B / 255.0, blue: 0x22 / 255.0, alpha: 1.0)

    private let cursorSize: CGFloat = 64

    private var panel: NSPanel?
    private var cursorLayer: CALayer?

    /// Menu-bar icon center, in global AppKit (bottom-left origin) coordinates. Set on `wake`.
    private var anchorAppKit: CGPoint = .zero
    private var isAwake = false

    /// Whether the cursor is currently out and visible.
    var isVisible: Bool { isAwake }

    // MARK: - Public API

    /// Bring the cursor out of the menu-bar icon. `anchor` is the icon's center in global AppKit
    /// (bottom-left origin) coordinates — typically the status-item button window's center. Idempotent:
    /// if the cursor is already out, this just refreshes the anchor and returns (no re-intro).
    func wake(from anchor: CGPoint) async {
        ensurePanel()
        anchorAppKit = anchor
        guard let panel, let cursorLayer else { return }
        if isAwake { return }

        let start = viewPoint(fromGlobalAppKit: anchor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = start
        cursorLayer.opacity = 0
        cursorLayer.transform = CATransform3DMakeScale(0.15, 0.15, 1)
        CATransaction.commit()

        panel.orderFrontRegardless()
        isAwake = true

        await runAnimations {
            self.addAnim(cursorLayer, keyPath: "opacity", to: 1.0, duration: 0.32, timing: .easeOut)
            self.addAnim(cursorLayer, keyPath: "transform.scale", to: 1.0, duration: 0.38, timing: .init(controlPoints: 0.3, 1.4, 0.5, 1.0))
        }
    }

    /// Glide the cursor to a point given in global CG (top-left origin) coordinates — the same space
    /// `ComputerControlCapability` uses for clicks. Duration scales with distance so short hops feel
    /// snappy and long sweeps feel deliberate.
    func move(toGlobalCG cgPoint: CGPoint) async {
        guard isAwake, let cursorLayer else { return }
        let target = viewPoint(fromGlobalAppKit: globalAppKit(fromGlobalCG: cgPoint))
        let from = cursorLayer.presentation()?.position ?? cursorLayer.position
        let distance = hypot(target.x - from.x, target.y - from.y)
        let duration = min(max(Double(distance) / 1400.0, 0.28), 0.85)
        await runAnimations {
            self.addAnim(cursorLayer, keyPath: "position", to: NSValue(point: target), duration: duration, timing: .init(name: .easeInEaseOut))
        }
    }

    /// Point at a spot the way Clicky's buddy does: glide along an upward-arcing quadratic Bézier
    /// curve, swelling at mid-flight for a "swoop", and settle on the target (no click — this is
    /// pure guidance). `cgPoint` is in global CG (top-left origin) coordinates.
    func point(toGlobalCG cgPoint: CGPoint) async {
        guard isAwake, let cursorLayer else { return }
        let target = viewPoint(fromGlobalAppKit: globalAppKit(fromGlobalCG: cgPoint))
        let from = cursorLayer.presentation()?.position ?? cursorLayer.position

        let distance = hypot(target.x - from.x, target.y - from.y)
        let duration = min(max(Double(distance) / 1400.0, 0.35), 0.9)

        // A single clean straight-line ease-in-out glide — no arc, no scale pulse. With the layer's
        // implicit actions disabled, this is the ONLY animation on position, so the motion is smooth
        // and predictable, landing exactly on the target.
        await runAnimations {
            let glide = CABasicAnimation(keyPath: "position")
            glide.fromValue = NSValue(point: from)
            glide.toValue = NSValue(point: target)
            glide.duration = duration
            glide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cursorLayer.position = target
            cursorLayer.add(glide, forKey: "position")
        }
    }

    /// A click flourish at the cursor's current spot: a quick squash on the cursor plus an expanding
    /// ripple ring. Cosmetic only — the real click is posted separately.
    func tap() async {
        guard isAwake, let cursorLayer, let host = panel?.contentView?.layer else { return }
        let center = cursorLayer.presentation()?.position ?? cursorLayer.position
        emitRipple(at: center, in: host)
        await runAnimations {
            let squash = CAKeyframeAnimation(keyPath: "transform.scale")
            squash.values = [1.0, 0.78, 1.0]
            squash.keyTimes = [0, 0.4, 1]
            squash.duration = 0.24
            squash.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cursorLayer.add(squash, forKey: "tap")
        }
    }

    /// Retreat into the menu-bar icon and hide. Safe to call more than once.
    func sleep() async {
        guard isAwake, let panel, let cursorLayer else { return }
        let home = viewPoint(fromGlobalAppKit: anchorAppKit)
        await runAnimations {
            self.addAnim(cursorLayer, keyPath: "position", to: NSValue(point: home), duration: 0.42, timing: .init(name: .easeInEaseOut))
        }
        await runAnimations {
            self.addAnim(cursorLayer, keyPath: "opacity", to: 0.0, duration: 0.26, timing: .easeIn)
            self.addAnim(cursorLayer, keyPath: "transform.scale", to: 0.15, duration: 0.26, timing: .easeIn)
        }
        panel.orderOut(nil)
        isAwake = false
    }

    // MARK: - Panel & cursor construction

    private func ensurePanel() {
        guard panel == nil else { return }

        let frame = Self.virtualScreenFrame()
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true                 // click-through: never blocks the user
        panel.level = .screenSaver                        // above normal app windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        panel.contentView = host

        let cursor = CALayer()
        // Disable IMPLICIT animations: otherwise every `layer.position = …` fires Core Animation's
        // default 0.25s straight-line move that fights our explicit arc, producing jittery/random
        // motion. With these nulled, only the animations we add drive the cursor.
        cursor.actions = [
            "position": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull(),
            "bounds": NSNull(),
            "contents": NSNull(),
        ]
        cursor.bounds = CGRect(x: 0, y: 0, width: cursorSize, height: cursorSize)
        let image = Self.cursorImage()
        AgentDebugLog.log("cursor overlay: panel=\(frame) image=\(image == nil ? "nil" : "ok")")
        cursor.contents = image
        cursor.contentsScale = panel.backingScaleFactor
        cursor.contentsGravity = .resizeAspect
        cursor.shadowColor = NSColor.black.cgColor
        cursor.shadowOpacity = 0.35
        cursor.shadowRadius = 6
        cursor.shadowOffset = CGSize(width: 0, height: -2)
        cursor.opacity = 0
        host.layer?.addSublayer(cursor)

        self.panel = panel
        self.cursorLayer = cursor
    }

    private func emitRipple(at center: CGPoint, in host: CALayer) {
        let diameter = cursorSize * 1.7
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter), transform: nil)
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ring.position = center
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Self.cursorColor.withAlphaComponent(0.7).cgColor
        ring.lineWidth = 2
        host.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        ring.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    // MARK: - Coordinate conversion

    /// Convert a global CG point (top-left origin) to a global AppKit point (bottom-left origin).
    /// The flip pivots on the primary screen's height, which is how the two spaces relate globally.
    private func globalAppKit(fromGlobalCG p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Convert a global AppKit point into the overlay content view's coordinates.
    private func viewPoint(fromGlobalAppKit p: CGPoint) -> CGPoint {
        guard let origin = panel?.frame.origin else { return p }
        return CGPoint(x: p.x - origin.x, y: p.y - origin.y)
    }

    private static func virtualScreenFrame() -> NSRect {
        NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
    }

    // MARK: - Animation helper

    /// Add an explicit animation to `layer` and commit the model value, so the layer ends *at* the
    /// target (no snap-back). `runAnimations` wraps a batch in a transaction whose completion resumes
    /// the async caller, so callers can `await` the animation finishing.
    private func addAnim(_ layer: CALayer, keyPath: String, to value: Any, duration: Double, timing: CAMediaTimingFunction) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        anim.toValue = value
        anim.duration = duration
        anim.timingFunction = timing
        layer.add(anim, forKey: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
    }

    private func runAnimations(_ build: () -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            CATransaction.setCompletionBlock { cont.resume() }
            build()
            CATransaction.commit()
        }
    }

    // MARK: - Cursor image (logo tinted #1d2434)

    private static func cursorImage() -> CGImage? {
        if let base = loadLogo() {
            let size = base.size == .zero ? NSSize(width: 64, height: 64) : base.size
            let tinted = NSImage(size: size)
            tinted.lockFocus()
            base.draw(in: NSRect(origin: .zero, size: size))
            cursorColor.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceIn)   // recolor to brand navy, keep the silhouette
            tinted.unlockFocus()
            if let cg = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        }
        // Fallback so the cursor is NEVER invisible if the logo asset can't be found: a navy triangle
        // (Clicky-style pointer) drawn in the brand color.
        return fallbackTriangle()
    }

    /// The logo ships inside the SwiftPM resource bundle (`Bundle.module`), not the app's main bundle,
    /// so `Bundle.main` returns nil — try the module bundle first, then main as a fallback.
    private static func loadLogo() -> NSImage? {
        let candidates: [Bundle] = [.module, .main]
        for bundle in candidates {
            if let url = bundle.url(forResource: "alfred-small-logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    private static func fallbackTriangle() -> CGImage? {
        let side: CGFloat = 64
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        cursorColor.set()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: side * 0.5, y: side))   // apex (top)
        path.line(to: NSPoint(x: side, y: 0))            // bottom-right
        path.line(to: NSPoint(x: 0, y: 0))               // bottom-left
        path.close()
        path.fill()
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

private extension CAMediaTimingFunction {
    static let easeOut = CAMediaTimingFunction(name: .easeOut)
    static let easeIn = CAMediaTimingFunction(name: .easeIn)
}
