import SwiftUI

/// The VERTUS logo as a loading spinner, drawn programmatically from the
/// logo's exact geometry (measured from the PNG: a pointy-top/bottom hexagon
/// with an inscribed black triangle — the three white regions are exact
/// triangles that tile the hexagon around the center).
///
/// While `isBusy`, the whole logo spins continuously (1.6 s/rev) and the
/// three white triangles drift outward along their own radial axes with a
/// gentle per-revolution wobble — reading as centrifugal force, with a thin
/// hexagon frame fading in behind them. When `isBusy` flips false, the spin
/// eases out to a full revolution while the triangles spring back into
/// place; the resting state is the assembled logo, geometrically identical
/// to the static asset.
struct LogoSpinner: View {
    /// True while VERTUS is working — the logo spins and separates. On the
    /// flip to false it eases to a stop and reassembles.
    var isBusy: Bool
    /// Logo size in points (hexagon height, tip to tip).
    var size: CGFloat = 14
    /// Triangle / frame color.
    var tint: Color = .white

    // Settling (stopped) state: while busy, angle and separation are derived
    // from the wall clock; once busy ends they are frozen into these @State
    // values and animated home (withAnimation), so the stop is exact.
    @State private var settlingAngle: Double = 0
    @State private var settlingSeparation: CGFloat = 0
    @State private var settlingTarget: Double = 0
    @State private var isSettling = false
    // Busy-state time references. On a restart mid-settle they are rebuilt
    // from the settling values, so the animation never jumps.
    @State private var spinStart: Date = .now
    @State private var busySince: Date = .now

    /// Seconds per full revolution while busy.
    private static let revDuration = 1.6
    /// Seconds for the separation to ramp from 0 to full.
    private static let rampDuration = 0.7
    /// Max outward travel of each triangle, as a fraction of R (half the
    /// hexagon's height).
    private static let maxSeparation = 0.30
    /// ± amplitude of the per-revolution wobble (fraction of max travel).
    private static let wobbleAmplitude = 0.06

    /// The timeline only needs to run while something is moving: busy, or
    /// still settling from a stop. At rest it pauses, so a settled logo
    /// costs no per-frame renders.
    private var isPaused: Bool {
        if isBusy { return false }
        if !isSettling { return true }
        return abs(settlingSeparation) < 0.001 && abs(settlingAngle - settlingTarget) < 0.5
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { context in
            logo(at: context.date)
        }
        .frame(width: size, height: size)
        .onAppear {
            if isBusy { startSpinning() }
        }
        .onChange(of: isBusy) { busy in
            if busy { startSpinning() } else { stopSpinning() }
        }
    }

    // MARK: - State machine

    /// Begin the busy animation. If a previous stop is still settling, pick
    /// up from where it currently is so there's no jump.
    private func startSpinning() {
        if isSettling {
            // Angular continuity: resume the time-driven spin from the angle
            // the settle animation is currently at.
            spinStart = .now.addingTimeInterval(-(settlingAngle / 360) * Self.revDuration)
            // Ramp continuity for the separation core (the wobble follows
            // the spin phase, which is continuous by construction).
            let u = min(max(Double(settlingSeparation) / Self.maxSeparation, 0), 1)
            busySince = .now.addingTimeInterval(-u * Self.rampDuration)
            isSettling = false
        } else {
            spinStart = .now
            busySince = .now
        }
    }

    /// End the busy animation: freeze the current angle/separation, then
    /// ease out to the next full revolution while the pieces spring home.
    private func stopSpinning() {
        settlingAngle = spinAngle(at: .now)
        settlingSeparation = busySeparation(at: .now)
        let r = Date.now.timeIntervalSince(spinStart) / Self.revDuration
        let frac = r - floor(r)
        // If we're already (almost) at a full revolution, stop right at it
        // instead of doing a full extra turn.
        settlingTarget = (frac > 0.98 ? floor(r) : floor(r) + 1) * 360
        isSettling = true
        withAnimation(.easeOut(duration: 0.6)) { settlingAngle = settlingTarget }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { settlingSeparation = 0 }
    }

    // MARK: - Busy-state animation curves (pure functions of time)

    /// Current rotation angle in degrees (0…360).
    private func spinAngle(at date: Date) -> Double {
        let t = date.timeIntervalSince(spinStart)
        guard t > 0 else { return 0 }
        let r = t / Self.revDuration
        return (r - floor(r)) * 360
    }

    /// Current separation (0…1): ramps in smoothly after the turn starts,
    /// with a gentle wobble once per revolution.
    private func busySeparation(at date: Date) -> CGFloat {
        let t = date.timeIntervalSince(busySince)
        let u = min(max(t / Self.rampDuration, 0), 1)
        let eased = u * u * (3 - 2 * u)                      // smoothstep
        let phase = date.timeIntervalSince(spinStart) / Self.revDuration
        let wobble = 1 + Self.wobbleAmplitude * sin(2 * .pi * phase)
        return CGFloat(Self.maxSeparation * Double(eased) * wobble)
    }

    private func logo(at date: Date) -> some View {
        let a: Double
        let s: CGFloat
        if isSettling {
            a = settlingAngle
            s = settlingSeparation
        } else {
            a = spinAngle(at: date)
            s = busySeparation(at: date)
        }
        return LogoArt(angle: a, separation: s, size: size, tint: tint)
    }
}

// MARK: - The art

/// The three white triangles tiling the hexagon around the black center
/// triangle, rotated by `angle` and with each triangle pushed out along its
/// own radial axis by `separation` (0 = assembled). A thin hexagon frame
/// fades in behind the pieces as they separate.
private struct LogoArt: View {
    var angle: Double
    var separation: CGFloat
    var size: CGFloat
    var tint: Color

    /// √3/2 — horizontal extent of a pointy-top hexagon vertex.
    private static let s3: CGFloat = 0.8660254037844386
    /// Unit radial axes per piece: left flank, right flank, bottom.
    private static let axes: [(CGFloat, CGFloat)] = [
        (-s3, -0.5),
        (s3, -0.5),
        (0, 1),
    ]

    var body: some View {
        let R = size / 2
        let s = Self.s3 * R
        let h = R / 2
        let off = separation * 0.30 * R
        let pieces: [Path] = [
            Self.poly([CGPoint(x: 0, y: -R), CGPoint(x: -s, y: -h), CGPoint(x: -s, y: h)])
                .offsetBy(dx: -Self.s3 * off, dy: -0.5 * off),
            Self.poly([CGPoint(x: 0, y: -R), CGPoint(x: s, y: -h), CGPoint(x: s, y: h)])
                .offsetBy(dx: Self.s3 * off, dy: -0.5 * off),
            Self.poly([CGPoint(x: -s, y: h), CGPoint(x: s, y: h), CGPoint(x: 0, y: R)])
                .offsetBy(dx: 0, dy: off),
        ]
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                pieces[i].fill(tint)
            }
            // The center triangle (black on the real logo) — invisible on
            // the black panel, drawn so the component is self-contained on
            // any background.
            Self.poly([CGPoint(x: 0, y: -R), CGPoint(x: -s, y: h), CGPoint(x: s, y: h)])
                .fill(Color.black)
            // The original hexagon frame — fades in as the pieces pull away.
            Self.hexagon(R: R)
                .stroke(tint.opacity(0.35 * Double(separation)),
                        lineWidth: max(0.5, size * 0.05))
        }
        .offset(x: size / 2, y: size / 2)
        .rotationEffect(.degrees(angle))
        .frame(width: size, height: size)
    }

    private static func poly(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }

    private static func hexagon(R: CGFloat) -> Path {
        let s = s3 * R
        let h = R / 2
        return poly([
            CGPoint(x: 0, y: -R),
            CGPoint(x: s, y: -h),
            CGPoint(x: s, y: h),
            CGPoint(x: 0, y: R),
            CGPoint(x: -s, y: h),
            CGPoint(x: -s, y: -h),
        ])
    }
}