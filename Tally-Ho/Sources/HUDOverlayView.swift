//
//  HUDOverlayView.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The flight-HUD chrome: horizon ladder, heading tape and bank indicator.
//

import UIKit

// MARK: - HUD Overlay

/// Modern-HUD-style overlay: a gravity-referenced horizon line with labeled
/// ±5°/±10° pitch rungs and a bank-angle scale (all tilt/move with device
/// attitude, computed from ARKit's camera transform — independent of the
/// compass/GPS bearing math used for aircraft markers, so it isn't affected
/// by the accuracy issues that affect bearing), plus speed/altitude tapes.
final class HUDOverlayView: UIView {

    static let hudGreen = UIColor(red: 0.10, green: 1.0, blue: 0.30, alpha: 1.0)

    /// One pitch-ladder rung: its line layer plus (for non-horizon rungs) the
    /// two endpoint number labels.
    private struct Rung {
        let line: CAShapeLayer
        let labelLeft: UILabel?
        let labelRight: UILabel?
    }
    private var rungs: [Rung] = []

    // Bank-angle "rose": a tick-mark scale that rotates every frame to
    // show live roll, like a real HUD's conformal bank scale.
    private let bankArcLayer     = CAShapeLayer()
    private var bankPivot: CGPoint = .zero
    private let bankRadius: CGFloat = 60
    /// Neutral (roll = 0) tick endpoints, rebuilt on layout; rotated around
    /// bankPivot each frame in updateBank(rollDeg:) to animate the scale.
    private var bankNeutralTicks: [(inner: CGPoint, outer: CGPoint)] = []

    // Heading "half rose" at the bottom: a rotating compass card, like a
    // real magnetic/gyro compass rose — 12 ticks at fixed absolute compass
    // values (every 30°), each number permanently tied to its tick. The
    // whole assembly rotates around headingPivot as heading changes so the
    // current heading always sits under the fixed lubber-line pointer.
    // Each label's text is set once (a tick's value never changes); only
    // position/visibility update, on the ~0.25s readout cadence
    // (updateHeading(headingDeg:)) rather than per AR frame, since a
    // heading readout doesn't need 60Hz precision.
    private let headingArcLayer     = CAShapeLayer()
    private let headingPointerLayer = CAShapeLayer()
    private var headingPivot: CGPoint = .zero
    private let headingRadius: CGFloat = 60
    private struct HeadingTick {
        let absValue: Double
        let label: UILabel
    }
    private var headingTicks: [HeadingTick] = []
    private var lastHeadingDeg: Double = 0
    /// Whether the rose is currently blanked for want of a world alignment. Held so a layout pass,
    /// which re-runs the last heading, cannot bring an arbitrary rose back on screen.
    private var headingRoseHidden: Bool = false

    private static func headingLabelText(for value: Double) -> String {
        switch value {
        case 0:   return "N"
        case 90:  return "E"
        case 180: return "S"
        case 270: return "W"
        default:  return String(format: "%03d", Int(value))
        }
    }

    /// Fixed-position indicator shown when the pitch ladder's horizon line
    /// itself isn't visible on screen (phone pitched too far up/down) —
    /// points toward whichever edge the horizon has scrolled off, so the
    /// user has some attitude reference even when none of the ladder is
    /// in view. Unlike the ladder itself, this is a plain fixed screen
    /// position/shape (not 3D-projected) for robustness at extreme angles.
    enum HorizonArrowDirection { case up, down }
    private let horizonArrowLayer = CAShapeLayer()

    private let speedTape = HUDTapeView(unit: "KT", tickSpacing: 10, labelEvery: 20, range: 50, isLeftTape: true)
    private let altTape   = HUDTapeView(unit: "FT", tickSpacing: 100, labelEvery: 200, range: 500, isLeftTape: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        func makeRungLine(width: CGFloat, dashed: Bool) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.lineCap = .round
            l.lineWidth = width
            l.isHidden = true
            if dashed { l.lineDashPattern = [6, 5] }
            layer.addSublayer(l)
            return l
        }
        // Text is static per rung (e.g. always "10" for the +10 rung), so set
        // it and size the label once here rather than every frame in
        // updateLadder() — sizeToFit() involves text layout and doing it at
        // 60Hz for unchanging text was wasted work contributing to jank.
        func makeLabel(text: String) -> UILabel {
            let lbl = UILabel()
            lbl.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            lbl.textAlignment = .center
            lbl.text = text
            lbl.sizeToFit()
            lbl.isHidden = true
            addSubview(lbl)
            return lbl
        }

        // Order: horizon, +10, +5, -5, -10.
        rungs = [
            Rung(line: makeRungLine(width: 2, dashed: false), labelLeft: nil, labelRight: nil),
            Rung(line: makeRungLine(width: 1.5, dashed: false), labelLeft: makeLabel(text: "10"), labelRight: makeLabel(text: "10")),
            Rung(line: makeRungLine(width: 1.5, dashed: false), labelLeft: makeLabel(text: "5"), labelRight: makeLabel(text: "5")),
            Rung(line: makeRungLine(width: 1.5, dashed: true),  labelLeft: makeLabel(text: "5"), labelRight: makeLabel(text: "5")),
            Rung(line: makeRungLine(width: 1.5, dashed: true),  labelLeft: makeLabel(text: "10"), labelRight: makeLabel(text: "10")),
        ]

        bankArcLayer.fillColor = nil
        bankArcLayer.lineWidth = 1.5
        bankArcLayer.lineCap = .round
        layer.addSublayer(bankArcLayer)

        headingArcLayer.fillColor = nil
        headingArcLayer.lineWidth = 1.5
        headingArcLayer.lineCap = .round
        layer.addSublayer(headingArcLayer)

        headingPointerLayer.strokeColor = nil
        layer.addSublayer(headingPointerLayer)
        headingPointerLayer.fillColor = Self.hudGreen.cgColor

        headingTicks = stride(from: 0.0, to: 360.0, by: 30.0).map { val in
            let lbl = UILabel()
            let isCardinal = val.truncatingRemainder(dividingBy: 90) == 0
            lbl.font = UIFont.monospacedDigitSystemFont(ofSize: isCardinal ? 13 : 12, weight: isCardinal ? .bold : .semibold)
            lbl.textAlignment = .center
            lbl.text = Self.headingLabelText(for: val)
            lbl.isHidden = true
            addSubview(lbl)
            return HeadingTick(absValue: val, label: lbl)
        }

        addSubview(speedTape)
        addSubview(altTape)

        // Added last so it's topmost in z-order — an off-screen-horizon
        // warning shouldn't ever be covered by another HUD element. Open
        // 2-line chevron (stroke, not fill) rather than a solid triangle.
        horizonArrowLayer.fillColor = nil
        horizonArrowLayer.lineWidth = 3
        horizonArrowLayer.lineCap = .round
        horizonArrowLayer.lineJoin = .round
        horizonArrowLayer.isHidden = true
        layer.addSublayer(horizonArrowLayer)

        setBrightness(.medium)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()

        let tapeSize = CGSize(width: 60, height: 220)
        // Capped at a fixed distance from center (matching roughly how far
        // out they sit in portrait) rather than pinned to the raw screen
        // edge — in landscape, a much wider screen would otherwise spread
        // them far apart with a large empty gap between them. Still
        // clamped to the safe area so a notch/Dynamic Island intruding
        // from a side never clips them.
        let refOffsetFromCenter: CGFloat = 195
        let speedX = max(safeAreaInsets.left + 8, bounds.midX - refOffsetFromCenter)
        let altX = min(bounds.width - safeAreaInsets.right - tapeSize.width - 8,
                        bounds.midX + refOffsetFromCenter - tapeSize.width)
        speedTape.frame = CGRect(x: speedX, y: bounds.midY - tapeSize.height / 2, width: tapeSize.width, height: tapeSize.height)
        altTape.frame   = CGRect(x: altX, y: bounds.midY - tapeSize.height / 2, width: tapeSize.width, height: tapeSize.height)

        // Proportional to the *safe area*, not raw bounds — a notch/Dynamic
        // Island intrudes from a side of the screen in landscape, which
        // becomes part of the vertical extent in this view's own unrotated
        // coordinate space. Positioning from raw bounds.height risked the
        // bank rose's tick arc (up to 60pt above its pivot) rendering
        // under/behind that housing, which would look exactly like "no arc
        // above the triangle" despite the geometry itself being correct.
        // 12%/88% (vs. a wider split) also gives the two roses a bit more
        // separation in landscape, now measured from the actually-usable
        // area instead of the raw screen edge.
        let safeTop = safeAreaInsets.top
        let safeHeight = bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
        bankPivot = CGPoint(x: bounds.midX, y: safeTop + safeHeight * 0.12)
        layoutBankRose()

        headingPivot = CGPoint(x: bounds.midX, y: safeTop + safeHeight * 0.88)
        layoutHeadingRose()
    }

    /// Rebuild the neutral (roll = 0) tick positions. Only depends on
    /// bounds, so it only needs to run from layoutSubviews, not per-frame —
    /// updateBank(rollDeg:) does the per-frame work of rotating the ticks
    /// around bankPivot.
    private func layoutBankRose() {
        // Ticks at 0/±10/±20/±30/±45/±60°, measured from straight up at the
        // pivot. point = pivot + R*(sin(rad), -cos(rad)) puts the 0° tick
        // highest (smallest y) and the ±60° ticks lower — the arc bulges
        // upward above bankPivot, a "sad face" ⌢ shape (confirmed against
        // reference photos: level flight shows a centered sad-face arc over
        // a plain triangle). Per-frame roll rotation (updateBank(rollDeg:)
        // below) tilts this whole arc to either side around bankPivot,
        // driven by the horizon line's own on-screen slope (see
        // updateHUDLadder()) so the direction always matches how the
        // horizon itself tilts.
        let tickAngles: [Double] = [-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60]
        bankNeutralTicks = tickAngles.map { deg in
            let rad = deg * .pi / 180
            let isMajor = [0, 30, 60, -30, -60].contains(deg)
            let outerR = bankRadius
            let innerR = bankRadius - (isMajor ? 10 : 6)
            let sinR = CGFloat(sin(rad)), cosR = CGFloat(cos(rad))
            let outer = CGPoint(x: bankPivot.x + outerR * sinR, y: bankPivot.y - outerR * cosR)
            let inner = CGPoint(x: bankPivot.x + innerR * sinR, y: bankPivot.y - innerR * cosR)
            return (inner, outer)
        }

        updateBank(rollDeg: lastRollDeg)
    }

    private var lastRollDeg: Double = 0

    /// Rotate the bank rose (tick scale) to the current roll angle (degrees,
    /// positive = right wing down) by rotating each neutral tick point
    /// around bankPivot.
    func updateBank(rollDeg: Double) {
        lastRollDeg = rollDeg
        guard !bankNeutralTicks.isEmpty else { return }
        let rad = rollDeg * .pi / 180
        let c = CGFloat(cos(rad)), s = CGFloat(sin(rad))
        func rotated(_ p: CGPoint) -> CGPoint {
            let dx = p.x - bankPivot.x, dy = p.y - bankPivot.y
            return CGPoint(x: bankPivot.x + dx * c - dy * s, y: bankPivot.y + dx * s + dy * c)
        }

        let arcPath = CGMutablePath()
        for tick in bankNeutralTicks {
            arcPath.move(to: rotated(tick.inner))
            arcPath.addLine(to: rotated(tick.outer))
        }
        // Also called from layoutBankRose() (a different context than the
        // per-frame dispatch block below), so this needs its own action-
        // disabling transaction rather than relying on an outer one —
        // nested CATransactions are cheap (only the outermost commit
        // actually flushes), so this doesn't add meaningful overhead when
        // called from within the caller's own transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bankArcLayer.path = arcPath
        CATransaction.commit()
    }

    /// Build the heading rose's fixed lubber-line pointer, then position the
    /// (already-built, static-text) ticks for the last known heading — only
    /// depends on bounds, so it only runs from layoutSubviews; per-heading
    /// updates go through updateHeading(headingDeg:) below.
    private func layoutHeadingRose() {
        // Fixed lubber-line triangle pointing up into the arc from the
        // pivot — marks "this is your current heading". Never moves; the
        // rose (tick scale) is what rotates around it, mirroring the bank
        // rose's fixed-pointer/rotating-scale relationship.
        let tip = CGPoint(x: headingPivot.x, y: headingPivot.y - headingRadius + 12)
        let pointerPath = CGMutablePath()
        pointerPath.move(to: CGPoint(x: tip.x - 5, y: tip.y + 8))
        pointerPath.addLine(to: tip)
        pointerPath.addLine(to: CGPoint(x: tip.x + 5, y: tip.y + 8))
        pointerPath.closeSubpath()
        headingPointerLayer.path = pointerPath

        if headingRoseHidden {
            hideHeading()
        } else {
            updateHeading(headingDeg: lastHeadingDeg)
        }
    }

    /// Rotate the heading rose to the current true heading — like a real
    /// magnetic/gyro compass card, the whole assembly (ticks + their
    /// permanently-attached numbers) rotates around headingPivot so the
    /// current heading always sits under the fixed pointer above. Only
    /// position/visibility change here; each label's text was set once at
    /// construction and never touched again. Called on the ~0.25s
    /// status-readout cadence, not per AR frame.
    func updateHeading(headingDeg: Double) {
        lastHeadingDeg = headingDeg
        headingRoseHidden = false
        guard !headingTicks.isEmpty else { return }
        let visibleHalfRangeDeg = 100.0  // slight overscan past the nominal ±90° window

        let arcPath = CGMutablePath()
        for tick in headingTicks {
            var rel = (tick.absValue - headingDeg).truncatingRemainder(dividingBy: 360)
            if rel > 180 { rel -= 360 }
            if rel < -180 { rel += 360 }
            guard abs(rel) <= visibleHalfRangeDeg else {
                tick.label.isHidden = true
                continue
            }
            let rad = rel * .pi / 180
            let isCardinal = tick.absValue.truncatingRemainder(dividingBy: 90) == 0
            let outerR = headingRadius
            let innerR = headingRadius - (isCardinal ? 10 : 6)
            let sinR = CGFloat(sin(rad)), cosR = CGFloat(cos(rad))
            let outer = CGPoint(x: headingPivot.x + outerR * sinR, y: headingPivot.y - outerR * cosR)
            let inner = CGPoint(x: headingPivot.x + innerR * sinR, y: headingPivot.y - innerR * cosR)
            arcPath.move(to: inner)
            arcPath.addLine(to: outer)

            let labelR = outerR + 14
            let labelCenter = CGPoint(x: headingPivot.x + labelR * sinR, y: headingPivot.y - labelR * cosR)
            tick.label.frame = CGRect(x: labelCenter.x - 16, y: labelCenter.y - 7, width: 32, height: 14)
            tick.label.isHidden = false
        }
        headingArcLayer.path = arcPath
        headingPointerLayer.isHidden = false
    }

    /// Blank the heading rose entirely — ticks, numbers and lubber line.
    ///
    /// Used while the AR world has no alignment yet. A `.gravity` world's north is wherever the
    /// session started, so an uncorrected rose is not roughly right, it is arbitrary; showing
    /// nothing says "not yet" where showing a number says "this way", and only one of those is
    /// true. Mirrors the target fade, which build 34 tied to the same condition.
    func hideHeading() {
        headingRoseHidden = true
        headingArcLayer.path = nil
        headingPointerLayer.isHidden = true
        headingTicks.forEach { $0.label.isHidden = true }
    }

    /// Update the horizon/pitch-ladder lines. Each pair is (leftEndpoint, rightEndpoint)
    /// in this view's coordinate space, already projected from 3D world points.
    /// `plus10`/`minus10` are optional since they can be nil near vertical look angles.
    func updateLadder(
        horizon: (CGPoint, CGPoint),
        plus5: (CGPoint, CGPoint), minus5: (CGPoint, CGPoint),
        plus10: (CGPoint, CGPoint)?, minus10: (CGPoint, CGPoint)?
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let pairs: [(Rung, (CGPoint, CGPoint)?)] = [
            (rungs[0], horizon),
            (rungs[1], plus10),
            (rungs[2], plus5),
            (rungs[3], minus5),
            (rungs[4], minus10),
        ]
        for (rung, pair) in pairs {
            guard let pair else {
                rung.line.isHidden = true
                rung.labelLeft?.isHidden = true
                rung.labelRight?.isHidden = true
                continue
            }
            rung.line.path = linePath(pair.0, pair.1)
            rung.line.isHidden = false
            if let ll = rung.labelLeft, let lr = rung.labelRight {
                // Position labels along the line's own direction, extended
                // past each endpoint — tracks the line's actual on-screen
                // tilt (e.g. during roll) instead of a fixed horizontal
                // offset, so the labels stay attached to the line itself
                // rather than sitting at a screen-relative position.
                let dx = pair.1.x - pair.0.x, dy = pair.1.y - pair.0.y
                let len = sqrt(dx * dx + dy * dy)
                let offset: CGFloat = 44
                if len > 0.01 {
                    let ux = dx / len, uy = dy / len
                    ll.center = CGPoint(x: pair.0.x - ux * offset, y: pair.0.y - uy * offset)
                    lr.center = CGPoint(x: pair.1.x + ux * offset, y: pair.1.y + uy * offset)
                    // Tilt the label text itself to match the line's
                    // on-screen angle (e.g. during roll), not just its
                    // position — both labels share the same line, so the
                    // same rotation applies to both. Normalize into
                    // (-90°, 90°] first — the raw atan2 can land near
                    // ±180° depending on which end of the line is "first"
                    // (harmless for a plain line segment, but would flip
                    // the text fully upside down instead of just tilting).
                    var angle = atan2(uy, ux)
                    if angle > .pi / 2 { angle -= .pi }
                    if angle < -.pi / 2 { angle += .pi }
                    let rotation = CGAffineTransform(rotationAngle: angle)
                    ll.transform = rotation
                    lr.transform = rotation
                } else {
                    ll.center = pair.0
                    lr.center = pair.1
                    ll.transform = .identity
                    lr.transform = .identity
                }
                ll.isHidden = false
                lr.isHidden = false
            }
        }
        CATransaction.commit()
    }

    /// Hide the ladder lines only (e.g. device pointed nearly straight up/down,
    /// where the horizontal-forward direction is undefined). Tapes stay visible.
    func hideLadder() {
        for rung in rungs {
            rung.line.isHidden = true
            rung.labelLeft?.isHidden = true
            rung.labelRight?.isHidden = true
        }
    }

    /// Show/hide the fixed off-screen-horizon arrow. `nil` hides it. Width
    /// matches the pitch-ladder line marks (~14pt); fixed screen position
    /// (not 3D-projected) so it stays reliable at the extreme pitch angles
    /// where the ladder itself can't be projected sensibly.
    func updateHorizonArrow(direction: HorizonArrowDirection?) {
        guard let direction else {
            horizonArrowLayer.isHidden = true
            return
        }
        let halfWidth: CGFloat = 12
        let height: CGFloat = 18
        // Noticeably closer to center than just past the safe area, per
        // feedback that the previous 0.15 fraction still read as "at the
        // edge" — still not all the way to screen center.
        let margin = max(safeAreaInsets.top, safeAreaInsets.bottom) + bounds.height * 0.25
        let cx = bounds.midX
        // Open 2-line chevron (not a closed/filled triangle): two strokes
        // meeting at the tip, pointing toward the horizon.
        let path = CGMutablePath()
        switch direction {
        case .up:
            let tipY = margin
            path.move(to: CGPoint(x: cx - halfWidth, y: tipY + height))
            path.addLine(to: CGPoint(x: cx, y: tipY))
            path.addLine(to: CGPoint(x: cx + halfWidth, y: tipY + height))
        case .down:
            let tipY = bounds.height - margin
            path.move(to: CGPoint(x: cx - halfWidth, y: tipY - height))
            path.addLine(to: CGPoint(x: cx, y: tipY))
            path.addLine(to: CGPoint(x: cx + halfWidth, y: tipY - height))
        }
        horizonArrowLayer.path = path
        horizonArrowLayer.isHidden = false
    }

    func updateReadouts(speedKt: Double, altitudeFt: Double) {
        speedTape.setValue(speedKt)
        altTape.setValue(altitudeFt)
    }

    /// Apply a brightness preset (alpha only) to every HUD element so the
    /// overlay stays legible without fully hiding aircraft markers underneath.
    func setBrightness(_ b: HUDBrightness) {
        let color = Self.hudGreen.withAlphaComponent(b.alpha).cgColor
        for rung in rungs {
            rung.line.strokeColor = color
            rung.labelLeft?.textColor = Self.hudGreen.withAlphaComponent(b.alpha)
            rung.labelRight?.textColor = Self.hudGreen.withAlphaComponent(b.alpha)
        }
        bankArcLayer.strokeColor = color
        headingArcLayer.strokeColor = color
        headingPointerLayer.fillColor = color
        for tick in headingTicks { tick.label.textColor = Self.hudGreen.withAlphaComponent(b.alpha) }
        horizonArrowLayer.strokeColor = color
        speedTape.setBrightness(b)
        altTape.setBrightness(b)
    }

    private func linePath(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }
}
