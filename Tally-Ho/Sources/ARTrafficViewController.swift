//
//  ARTrafficViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//

import UIKit
import ARKit
import CoreLocation
import CoreMotion
import Combine

// MARK: - Selection State

private enum SelectionState: Equatable {
    case none
    case selected(nodeID: String)
}

// MARK: - Off-Screen Arrow View

/// Full-screen transparent overlay that draws directional edge chevrons pointing
/// toward off-screen targets (TCAS threats and the user-selected aircraft).
/// On-screen targets do not get an overlay arrow — the colored ring on the AR node
/// is already prominent enough, and removing the orbiting animation saves the
/// CADisplayLink + 60 Hz redraws that were a non-trivial RAM/CPU cost.
private final class OffScreenArrowView: UIView {

    private struct ArrowEntry {
        var angle: CGFloat
        var center: CGPoint
        var color: UIColor
    }

    /// Arrow for the user-selected node (white).
    private var selectionArrow: ArrowEntry?
    /// Arrows for TCAS threat aircraft (amber = TA, red = RA).
    private var tcasArrows: [ArrowEntry] = []

    // MARK: - Cached color (avoid per-frame allocations in draw(_:))
    private static let blackAlpha65 = UIColor.black.withAlphaComponent(0.65)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Selection arrow

    func hide() {
        guard selectionArrow != nil else { return }
        selectionArrow = nil
        setNeedsDisplay()
    }

    /// Show an edge chevron for an off-screen target.
    func show(angle: CGFloat, center: CGPoint) {
        selectionArrow = ArrowEntry(angle: angle, center: center, color: .white)
        setNeedsDisplay()
    }

    // MARK: TCAS arrows

    func setTCASArrows(_ arrows: [(angle: CGFloat, center: CGPoint, color: UIColor)]) {
        tcasArrows = arrows.map {
            ArrowEntry(angle: $0.angle, center: $0.center, color: $0.color)
        }
        setNeedsDisplay()
    }

    func clearTCASArrows() {
        guard !tcasArrows.isEmpty else { return }
        tcasArrows = []
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        let all: [ArrowEntry] = tcasArrows + (selectionArrow.map { [$0] } ?? [])
        guard !all.isEmpty else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for entry in all {
            drawEdgeChevron(ctx: ctx, entry: entry)
        }
    }

    /// Classic edge-pinned chevron for off-screen targets.
    private func drawEdgeChevron(ctx: CGContext, entry: ArrowEntry) {
        let size: CGFloat         = 48
        let half                  = size / 2
        let cornerRadius: CGFloat = 10
        let bgRect = CGRect(x: entry.center.x - half,
                            y: entry.center.y - half,
                            width: size, height: size)

        ctx.saveGState()
        ctx.setFillColor(OffScreenArrowView.blackAlpha65.cgColor)
        ctx.addPath(UIBezierPath(roundedRect: bgRect, cornerRadius: cornerRadius).cgPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: entry.center.x, y: entry.center.y)
        ctx.rotate(by: entry.angle)

        let armLen: CGFloat = 10
        let tipY: CGFloat   = -11
        let baseY: CGFloat  =   5

        ctx.setStrokeColor(entry.color.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        ctx.beginPath()
        ctx.move(to: CGPoint(x: -armLen, y: baseY))
        ctx.addLine(to: CGPoint(x: 0, y: tipY))
        ctx.addLine(to: CGPoint(x: armLen, y: baseY))
        ctx.strokePath()

        ctx.restoreGState()
    }
}

// MARK: - HUD Overlay

/// Modern-HUD-style overlay: a gravity-referenced horizon line with labeled
/// ±5°/±10° pitch rungs and a bank-angle scale (all tilt/move with device
/// attitude, computed from ARKit's camera transform — independent of the
/// compass/GPS bearing math used for aircraft markers, so it isn't affected
/// by the accuracy issues that affect bearing), plus speed/altitude tapes.
private final class HUDOverlayView: UIView {

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

        updateHeading(headingDeg: lastHeadingDeg)
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

/// Vertical scrolling PFD/HUD-style tape (speed or altitude): a scale of tick
/// marks and numbers that shifts as the value changes, with a bold current-value
/// readout box fixed at the vertical center. `isLeftTape` mirrors the layout so
/// the scale reads outward from the tape toward its own screen edge and the
/// numbers sit inward, near the tape's inner (screen-center-facing) edge —
/// matching the airspeed-left/altitude-right convention of real HUDs.
private final class HUDTapeView: UIView {

    private let tickSpacing: Double
    private let labelEvery: Double
    private let range: Double
    private let isLeftTape: Bool

    private let ticksLayer = CAShapeLayer()
    private var tickLabels: [UILabel] = []

    private let centerBox = UIView()
    private let valueLabel = UILabel()
    private let unitLabel = UILabel()

    private var currentValue: Double = 0

    init(unit: String, tickSpacing: Double, labelEvery: Double, range: Double, isLeftTape: Bool) {
        self.tickSpacing = tickSpacing
        self.labelEvery = labelEvery
        self.range = range
        self.isLeftTape = isLeftTape
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        ticksLayer.fillColor = nil
        ticksLayer.lineWidth = 1.5
        layer.addSublayer(ticksLayer)

        for _ in 0..<((Int(range / labelEvery) * 2) + 2) {
            let lbl = UILabel()
            lbl.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            lbl.textAlignment = isLeftTape ? .right : .left
            addSubview(lbl)
            tickLabels.append(lbl)
        }

        centerBox.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        centerBox.layer.borderColor = HUDOverlayView.hudGreen.cgColor
        centerBox.layer.borderWidth = 1.5
        centerBox.layer.cornerRadius = 4
        addSubview(centerBox)

        valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        valueLabel.textAlignment = .center
        centerBox.addSubview(valueLabel)

        unitLabel.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        unitLabel.textAlignment = .center
        unitLabel.text = unit
        centerBox.addSubview(unitLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        centerBox.frame = CGRect(x: 0, y: bounds.midY - 20, width: bounds.width, height: 40)
        valueLabel.frame = CGRect(x: 0, y: 2, width: centerBox.bounds.width, height: 22)
        unitLabel.frame = CGRect(x: 0, y: 24, width: centerBox.bounds.width, height: 14)
        rebuild()
    }

    func setValue(_ value: Double) {
        currentValue = value
        rebuild()
    }

    func setBrightness(_ b: HUDBrightness) {
        let color = HUDOverlayView.hudGreen.withAlphaComponent(b.alpha)
        ticksLayer.strokeColor = color.cgColor
        valueLabel.textColor = color
        unitLabel.textColor = color
        for lbl in tickLabels { lbl.textColor = color }
        centerBox.backgroundColor = UIColor.black.withAlphaComponent(0.25 * Double(b.alpha) / 0.7)
        rebuild()
    }

    /// Redraw the tick marks/numbers and the center readout for `currentValue`.
    /// Runs on the 0.25s status-update cadence, not per AR frame — cheap.
    private func rebuild() {
        guard bounds.height > 0 else { return }
        valueLabel.text = String(format: "%.0f", currentValue)

        let pxPerUnit = CGFloat(bounds.height / 2) / CGFloat(range)
        let anchorX: CGFloat = isLeftTape ? bounds.width - 4 : 4
        let dir: CGFloat = isLeftTape ? -1 : 1

        let path = CGMutablePath()
        var labelIndex = 0
        let lowestTick = (currentValue - range).rounded(toNearest: tickSpacing)
        var tickValue = lowestTick
        while tickValue <= currentValue + range {
            defer { tickValue += tickSpacing }
            let y = bounds.midY - CGFloat(tickValue - currentValue) * pxPerUnit
            guard y >= -10, y <= bounds.height + 10 else { continue }
            // Skip ticks (and their labels) that fall behind the center
            // readout box — the scale shouldn't render inside/through it.
            guard abs(y - bounds.midY) > 22 else { continue }
            let isLabeled = tickValue.truncatingRemainder(dividingBy: labelEvery) == 0
            let tickLen: CGFloat = isLabeled ? 12 : 6
            path.move(to: CGPoint(x: anchorX, y: y))
            path.addLine(to: CGPoint(x: anchorX + dir * tickLen, y: y))

            if isLabeled, labelIndex < tickLabels.count {
                let lbl = tickLabels[labelIndex]
                lbl.text = String(format: "%.0f", tickValue)
                lbl.sizeToFit()
                let labelX = isLeftTape ? anchorX + dir * tickLen - 4 - lbl.bounds.width : anchorX + dir * tickLen + 4
                lbl.frame = CGRect(x: labelX, y: y - 7, width: lbl.bounds.width, height: 14)
                lbl.isHidden = false
                labelIndex += 1
            }
        }
        for i in labelIndex..<tickLabels.count { tickLabels[i].isHidden = true }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ticksLayer.path = path
        CATransaction.commit()
    }
}

private extension Double {
    /// Rounds down to the nearest multiple of `step`.
    func rounded(toNearest step: Double) -> Double {
        (self / step).rounded(.down) * step
    }
}

// MARK: - GPS acceptance thresholds

/// Thresholds governing which CoreLocation fixes are allowed to move ownship.
///
/// The previous rule discarded any fix worse than the accuracy limit outright, which meant a
/// run of poor fixes left the app dead-reckoning indefinitely from an increasingly old
/// position. At cruise speed that grows error much faster than a degraded fix contributes, so
/// past a staleness limit a worse fix is preferred to an older one.
/// How the app decides whether the user is airborne.
///
/// MSL altitude cannot answer this on its own: an aircraft parked at a 5,400 ft field reads as
/// 5,400 ft, so a bare "altitude > 200 ft" test calls it airborne while it is still on the
/// stand. That mistake reaches further than it looks — it decided TCAS alerting, the GPS
/// accuracy gate, and whether the ±10,000 ft altitude band culled traffic — so this is
/// answered from height above the nearest known field instead, with motion as a fallback.
private enum AirborneEstimate {
    /// Only fields this close are treated as candidates for "the field we are at".
    static let fieldSearchRadiusNM: Double = 5.0
    /// Height above that field before the aircraft counts as flying. Comfortably above
    /// terrain variation around an airfield, comfortably below a circuit altitude.
    static let heightAboveFieldFt: Double = 500.0
    /// Used when no known field is close enough to judge by — nothing on the ground sustains
    /// this speed.
    static let groundSpeedKt: Double = 40.0
}

/// Signed difference between two compass angles, in −180…180.
///
/// Distinct from `smoothAngle`, which works in 0…360 compass space and is wrong for anything
/// signed — folding a −12.5° correction to 347.5° is what produced the misleading declination
/// readout fixed in build 4.
func angleDifferenceDeg(from: Double, to: Double) -> Double {
    var delta = to - from
    while delta >  180 { delta -= 360 }
    while delta < -180 { delta += 360 }
    return delta
}

private enum GPSGate {
    /// Once the last accepted fix is older than this, accept degraded fixes up to the ceiling.
    static let staleFixSeconds: TimeInterval = 10.0
    /// Absolute worst horizontal accuracy ever accepted, in metres.
    static let hardCeilingMeters: Double = 1_000.0
    /// Vertical accuracy limits, in metres. Altitude error tilts every target at once, so it
    /// is gated separately from horizontal accuracy.
    static let verticalCeilingGroundMeters: Double = 50.0
    static let verticalCeilingAirborneMeters: Double = 150.0
}

// MARK: - ARTrafficViewController

class ARTrafficViewController: UIViewController, UIAdaptivePresentationControllerDelegate {

    // MARK: - UI

    private var arSceneView: ARSCNView!
    private var statusLabel: UILabel!
    private var settingsButton: UIButton!
    private var mapButton: UIButton!
    private var backButton: UIButton!
    private var offScreenArrowView: OffScreenArrowView!
    private var hudOverlayView: HUDOverlayView!
    /// Ground speed from the phone's own GPS (knots), updated on every location
    /// fix. Used for the HUD speed readout when ADS-B ownship isn't available —
    /// mirrors the activeAltitude fallback pattern.
    private var gpsSpeedKt: Double = 0

    // Dynamic leading constraints on statusLabel
    private var statusLeadingToEdge: NSLayoutConstraint!
    private var statusLeadingToBack: NSLayoutConstraint!

    /// Full-screen border overlay driven by TCAS alerts.
    private var tcasOverlayView: UIView!
    private var lastAppliedTCASLevel: TCASAlertLevel = .none

    // MARK: - METAR Panel

    private var metarPanelView: UIView!
    private var metarLabel: UILabel!
    private var metarAgeLabel: UILabel!
    private var metarCloseButton: UIButton!
    private var metarSelectedICAO: String?
    private var metarFetchTask: URLSessionDataTask?
    /// Time of the METAR observation (parsed from raw string) or D-ATIS fetch time.
    private var metarObservationTime: Date?

    // MARK: - Info (status) toggle

    private var infoButton: UIButton!

    // MARK: - D-ATIS

    private struct DATISEntry: Decodable {
        let airport: String
        let type: String
        let datis: String
    }

    // MARK: - Core

    private var connectionLogic = ConnectionLogic()
    private var sceneManager: ARSceneManager?
    private var locationManager = CLLocationManager()

    // MARK: - State

    // Invalidate the scene manager's airport stable-set cache whenever the source
    // list changes (async CSV load or range refresh). Without this, airports loaded
    // after the first updateAirports() tick would be silently ignored because the
    // cache thinks "nothing nearby" is the correct answer for the current location.
    private var airports: [Airport] = [] {
        didSet { sceneManager?.lastAirportComputeLocation = nil }
    }
    private var currentTCASEvaluation: TCASEvaluation = .clear

    var seedLocation: CLLocation?

    /// Set by whoever presented the launch calibration screen when the user chose Skip.
    /// Suppresses the automatic calibration popup for the rest of this launch.
    var calibrationWasSkipped: Bool = false
    /// Airport CSV data parsed ahead of time during the calibration screen (see
    /// AppDelegate). Pure background-thread data — no ConnectionLogic/network
    /// involvement — kept deliberately isolated from ARSession/view-lifecycle
    /// timing after an earlier attempt at preloading ConnectionLogic itself
    /// froze the AR camera. nil-safe: loadAirports() falls back to its normal
    /// disk read if this hasn't finished (or wasn't started) in time.
    var preloadedAirports: [Airport]?
    /// Aircraft from one standalone adsb.lol fetch made during calibration (see
    /// AppDelegate.onEarlyLocation). Seeded into connectionLogic once in
    /// viewDidLoad via seedInternetAircraft() — connectionLogic itself is still
    /// constructed fresh, right here, exactly as without this preload.
    var preloadedAircraft: [Aircraft]?

    private var userLocation: CLLocationCoordinate2D?
    private var bestHorizontalAccuracy: CLLocationAccuracy = -1
    private var lastHorizontalAccuracy: CLLocationAccuracy = -1
    private var lastVerticalAccuracy: CLLocationAccuracy = -1
    private var userAltitude: Double = 0
    private var gpsMSLAltitudeFeet: Double = 0
    private var userHeading: Double = 0
    private var lastHeadingAccuracy: CLLocationDirectionAccuracy = -1
    private var arTrackingState: ARCamera.TrackingState = .notAvailable
    private var isCalibrationPopupShowing = false

    private var updateTimer: Timer?
    private var currentZoomScale: CGFloat = 1.0
    private var pinchStartScale: CGFloat = 1.0
    /// 1-finger pan offset while zoomed in, in final screen points (applied
    /// after scale — see applyZoomAndPanTransform()). Clamped in
    /// clampPanOffset() so panning never shows past the edge of the scaled
    /// Metal content.
    private var panOffset: CGPoint = .zero
    private var panStartOffset: CGPoint = .zero
    private var cancellables = Set<AnyCancellable>()

    private var lastAirportFilterLocation: CLLocationCoordinate2D?
    private var selectionState: SelectionState = .none
    private let gpsAccuracyThreshold: CLLocationAccuracy = 30.0

    /// Local magnetic declination (trueHeading − magneticHeading), recorded and displayed
    /// but deliberately NOT applied to anything.
    ///
    /// It used to be subtracted from every GPS bearing, on the premise that ARKit's
    /// `.gravityAndHeading` world is magnetic-north aligned. Flight-log measurement disproved
    /// that: ARKit's raw world azimuth tracks *true* heading, so the subtraction was rotating
    /// every marker clockwise by the declination — about 12.5° in New York. Kept as a
    /// diagnostic because it is still the right number to see next to the compass readings.
    private var magneticDeclinationDeg: Double = 0
    private var isFirstHeadingFix: Bool = true

    /// Gap between ARKit's raw camera azimuth and the compass's true heading, in degrees.
    /// **Diagnostic only — never applied to placement.**
    ///
    /// It was applied, in build 8, and it had to be taken straight back out. The premise was
    /// that `CLHeading` reports where the phone points, so the gap is ARKit's alignment error.
    /// In a cockpit `CLHeading` reports the aircraft's ground track instead: measured on two
    /// flights the phone rotated 523.6° while the compass rotated 59.9°, a regression slope of
    /// +0.018, with the median gap between compass and GPS course at 0.00°. So the "error" this
    /// measures is mostly the angle between the phone and the nose, and subtracting it swung the
    /// whole scene back toward the nose every time the user looked out of a side window.
    ///
    /// Which means this number does **not** measure ARKit's alignment error on its own, and the
    /// "17.7° at FL272" once quoted from it was really that error plus the phone-to-nose angle.
    /// ARKit's in-flight azimuth error is currently unmeasured. Still recorded, because paired
    /// with `compassResponse` it becomes interpretable: where the compass tracks the phone this
    /// is ARKit's error, and where it does not, it is not.
    private var worldYawErrorDeg: Double = 0
    /// Whether `worldYawErrorDeg` holds a real measurement yet, as opposed to a default zero.
    private var hasSeededWorldYawError = false
    /// Compass accuracy past which the heading is too poor to measure against. Deliberately
    /// loose: these logs run at a constant ±10°, and a tight gate inside a fuselage would
    /// silently record nothing at all.
    private let maxHeadingAccuracyForYawFix: Double = 25.0

    /// **The test build 8 should have run before trusting the compass.**
    ///
    /// Degrees the compass turns per degree the phone turns. Near 1 means the compass is
    /// measuring device azimuth and an alignment correction built on it would be sound; near 0
    /// means it is slaved to something else — the aircraft's ground track, in both flights
    /// measured so far — and any such correction is actively harmful.
    ///
    /// Driver is the phone (ARKit azimuth), response is the compass.
    /// 25 s at ~1 Hz. Sampled slowly on purpose — see AngularResponse: the slope's variance grows
    /// linearly with sampling rate, so the 10 Hz / 3 s version of this read a median +0.161 with
    /// excursions to +0.709 on a flight whose true slope was −0.039.
    private var compassResponseEstimator = AngularResponse(
        window: 25.0, minDriverRotationDeg: 40.0, minDriverExcursionDeg: 25.0, minPairs: 15)
    private var compassResponse: Double = .nan
    private var compassResponseR: Double = .nan
    private var lastCompassSampleTime: TimeInterval = 0

    /// **Is ARKit's world Earth-referenced, or does it ride with the cabin?**
    ///
    /// Degrees ARKit's azimuth turns per degree the aircraft's ground track turns. Inside a
    /// fuselage every visual feature ARKit tracks is cabin interior, which is aircraft-fixed,
    /// so this is genuinely open and the two answers demand different fixes:
    ///
    /// - **≈ 1, Earth-locked.** The gyro carries ARKit through the aircraft's turns, so its only
    ///   azimuth error is the seed taken at session start: one constant per session. A constant
    ///   is correctable, and cannot chase a pan the way build 8's term did.
    /// - **≈ 0, cabin-locked.** The frame rides with the aircraft and its error grows by every
    ///   degree flown after session start. No fixed offset can fix that.
    ///
    /// The user's panning is uncorrelated with the aircraft's turn rate, so it averages out of
    /// the regression rather than needing the phone held still. Needs an actual turn: a cruise
    /// leg holding one heading will never populate it.
    ///
    /// Driver is the aircraft (GPS ground track), response is ARKit's azimuth.
    /// 45 s at ~1 Hz, matching GPS course's own update rate. Sampling faster than the driver
    /// updates just fills the window with exactly-zero driver changes.
    /// 90 s so a turn early in a lift still counts later in it. The 8° minimum stays: lowering it
    /// is the tempting move and the wrong one, since Σ(Δdriver²) scales with rotation squared, so
    /// halving the required turn quadruples the estimate's variance.
    private var frameLockEstimator = AngularResponse(
        window: 90.0, minDriverRotationDeg: 8.0, minDriverExcursionDeg: 8.0, minPairs: 15)
    /// Track rotation seen in the current window, so the panel can say how close a turn came
    /// rather than showing a bare dash.
    private var frameLockTrackSwingDeg: Double = 0
    /// True when the estimator is collecting but the aircraft has not turned enough to publish —
    /// the normal state in cruise, and worth distinguishing from a broken measurement.
    private var frameLockAwaitingTurn = false
    private var frameLock: Double = .nan
    private var frameLockR: Double = .nan
    private var lastFrameLockSampleTime: TimeInterval = 0

    /// Diagnostic only, never applied. ARKit's corrected azimuth minus GPS ground track, which
    /// is meaningful solely when the phone happens to point along the aircraft's nose. It is
    /// the one error `worldYawErrorDeg` is blind to — a cockpit whose magnetic field biases the
    /// compass and ARKit together, leaving their difference at zero while both are wrong.
    /// Recorded so that case is visible in a future log rather than invisible.
    ///
    /// A plain `Double` carrying `.nan` for "no reading", not an `Optional<Double>`: this is
    /// written on the SceneKit render thread and read on main, and an Optional is two words, so
    /// a torn read could yield a payload that never existed. One word matches what the
    /// heading terms here have always done across that boundary.
    private var courseResidualDeg: Double = .nan
    private var lastGPSCourseDeg: Double = -1
    private var lastGPSCourseAccuracy: Double = -1
    private var lastGPSSpeedKt: Double = 0

    /// Single source of truth for ownship position, velocity and altitude. Fed by the ADS-B
    /// receiver (off its own queue, with its own timestamps) and by CoreLocation.
    private let ownshipEstimator = OwnshipEstimator()

    /// Newest compass samples, kept for the flight log rather than for placement.
    private var lastMagneticHeading: Double = -1
    private var lastTrueHeading: Double = -1

    /// Raw vertical references from the phone, recorded each fix.
    private var gpsEllipsoidalAltitudeFeet: Double = 0
    private var geoidSeparationFeet: Double?
    /// Cabin pressure altitude from the phone's barometer. Diagnostic only — it never feeds
    /// `userAltitude`, which stays GPS-derived (see startDiagnosticAltimeterIfNeeded).
    private var cabinPressureAltitudeFeet: Double?

    /// Timestamp of the last position fix that passed the accuracy gate.
    private var lastAcceptedFixTime: Date = .distantPast
    /// Whether any GPS altitude has been accepted yet. Until one has, a fix is taken even if
    /// its vertical accuracy is poor — an approximate altitude beats none.
    private var hasAcceptedGPSAltitude = false
    /// Time constant for the ownship altitude blend, in seconds. Chosen to reproduce the old
    /// 0.15-per-fix behaviour at the nominal 1 Hz fix rate, without inheriting its dependence on
    /// how often fixes actually arrive.
    private let altitudeSmoothingTimeConstant: TimeInterval = 6.7

    /// Per-lift markers: the app is used in seconds-long glances, so time-to-first-target is
    /// measured from each foreground rather than once per launch.
    private var liftStartTime: Date?
    private var hasLoggedFirstTargetThisLift = false

    /// Throttle for the 1 Hz flight-recorder sample, driven off the existing 4 Hz tick.
    private var lastRecorderSampleTime: Date = .distantPast

    /// Whether the user is currently judged to be flying, refreshed each 4 Hz tick.
    /// Stored rather than computed on demand because the nearest-field search walks the
    /// loaded airport list, and several call sites read it per fix.
    private var isAirborneEstimate: Bool = false
    private var airborneBasis: String = "unknown"

    /// Most recent measured pressure-to-geometric offset, for display. Not applied to
    /// placement — that is the next phase.
    private var latestDatumOffset: AltitudeDatumOffset.Estimate?

    /// Reads absolute pressure only, so the cabin-versus-GPS altitude gap is measurable.
    /// Deliberately not part of the altitude chain: build 28 removed barometric fusion
    /// because a cabin barometer measures cabin pressure, and that decision stands.
    private let diagnosticAltimeter = CMAltimeter()

    /// Device motion, used for one thing only: an independent measure of the phone's true yaw
    /// rate, so ARKit's drift can be told apart from the user turning the phone.
    ///
    /// It has to be independent, because ARKit's yaw is the quantity under test. Pitch and roll
    /// are gravity-referenced and cannot drift, which makes them look like a free stillness test
    /// — but a pure yaw rotation of the wrist leaves both unchanged, and scanning for traffic is
    /// exactly that. Only the gyro sees it.
    private let motionManager = CMMotionManager()
    /// Latest yaw rate about the *vertical* axis, in degrees per second, or NaN when unknown.
    /// Written on the motion queue, read on the render thread — one word, matching what the
    /// other cross-thread scalars here do.
    private var verticalYawRateDps: Double = .nan

    /// How fast ARKit's azimuth drifts while the phone is genuinely still — the one alignment
    /// measurement obtainable in cruise, needing neither a compass nor a turn.
    private var yawDrift = YawDriftAccumulator()
    private var yawDriftDps: Double = .nan
    private var yawDriftSeconds: Double = .nan
    /// Largest gyro-measured net rotation across any banked run. Near zero means the phone really
    /// did end up where it started, so the drift figure beside it is clean.
    private var yawDriftGyroDeg: Double = .nan

    /// The phone's physical roll about the viewing axis, from the session camera's own frame,
    /// which is independent of the interface orientation. Written on the render thread, read when
    /// a sample is built. NaN when the phone is too close to flat for the angle to mean anything.
    private var imageRollDeg: Double = .nan
    /// The same angle taken from the point-of-view node, which carries the interface rotation —
    /// how far the picture is turned on screen. Near zero means the interface matches the phone.
    /// Diagnostic only; nothing acts on it.
    private var onScreenRollDeg: Double = .nan
    /// Follows the phone's physical orientation so the interface can be asked to match it, rather
    /// than waiting for an iOS heuristic that a rotation lock switches off entirely.
    private var orientationFollower = ScreenOrientationFollower()
    /// Render-thread throttle: the decision touches UIKit and the reading changes far slower than
    /// 60 Hz, so it is dispatched to main at about 5 Hz.
    private var lastOrientationCheck: TimeInterval = 0
    /// Main-thread throttle on the geometry request itself, so a request still in flight cannot
    /// turn into a retry storm.
    private var lastOrientationRequest: TimeInterval = 0
    private var lastOrientationRequested: UIInterfaceOrientation = .unknown
    /// How many geometry requests iOS has refused. After a few, asking again is pointless — the
    /// answer will not change — and continuing would fill the log with the same line every second.
    private var orientationRequestsRefused = 0
    /// So the follower giving up is recorded once rather than at 5 Hz for the rest of the flight.
    private var loggedOrientationDisabled = false
    /// Which interface orientation CoreLocation's heading reference is currently set for, so it is
    /// written only when it actually changes.
    private var headingOrientationSetFor: UIInterfaceOrientation = .unknown

    // MARK: - Flight-direction anchor

    /// The capture in progress, if any. See FlightDirectionAnchor for why this is airborne-only.
    private var flightAnchor = FlightDirectionAnchor()
    /// ARKit world north minus true north, applied to every bearing. Written by exactly two
    /// sources — the flight anchor below, and the ground compass correction — which are mutually
    /// exclusive by construction: see `worldYawSource`.
    private(set) var appliedWorldYawOffsetDeg: Double = 0
    private var hasFlightAnchor = false

    /// Which measurement the current offset came from, for the log and for the precedence rule.
    enum WorldYawSource: String {
        case none
        case ground
        case anchor
    }
    /// The anchor outranks the ground correction and is never overwritten by it: it is measured
    /// airborne against ground track, which is the only azimuth reference that works in a cabin.
    private var worldYawSource: WorldYawSource = .none

    /// Carries whichever offset is in force through the aircraft's heading changes. See
    /// TrackFollowingYawOffset: ARKit's world rides with the fuselage through slow turns, so an
    /// offset measured once decays at exactly the rate the aircraft turns.
    private var yawFollower = TrackFollowingYawOffset()
    /// Set when the ground correction is ready to seed the follower but the track is not yet usable
    /// — the airborne transition can fire a moment before GPS course settles.
    private var pendingGroundSeed = false
    /// The follower's state before the last anchor capture, so a mis-aimed capture is one tap away
    /// from being undone. A value type, so this is the whole prior state and not a reference to it.
    private var followerBeforeAnchor: TrackFollowingYawOffset?
    /// Beyond this a new anchor and the followed offset are telling different stories, and the user
    /// is shown the number rather than having it applied silently.
    private static let anchorDisagreementDeg: Double = 15.0

    /// When to say out loud that the alignment is on offer and has not been taken. See
    /// AlignPromptScheduler: two flights offered it continuously and neither took it.
    private var alignPrompts = AlignPromptScheduler()

    /// Gyro-integrated azimuth, for measuring how much of the aircraft's turn ARKit actually
    /// follows. Logged only in build 25 — see GyroAzimuthIntegrator for why it beats frame_lock.
    private var gyroAzimuth = GyroAzimuthIntegrator()
    /// Driver is the aircraft's track; response is (gyro azimuth − ARKit azimuth). The slope is the
    /// share of the aircraft's turn that ARKit fails to follow: 1 = cabin-locked, 0 = Earth-locked.
    /// Same window and thresholds as frameLockEstimator, since it consumes the same driver.
    private var followGainEstimator = AngularResponse(
        window: 90.0, minDriverRotationDeg: 8.0, minDriverExcursionDeg: 8.0, minPairs: 15)
    private var followGain: Double = .nan
    private var followGainR: Double = .nan
    /// Render-thread throttle for feeding the capture: hand wobble is correlated over about a
    /// second, so 60 Hz would just be 60 copies of the same look.
    private var lastAnchorSampleTime: TimeInterval = 0
    /// Whether a capture is running, as one word the render thread can read. `flightAnchor` itself
    /// holds an array that the main thread mutates, and the other cross-thread scalars in this
    /// file are handled the same way.
    private var anchorCaptureActive = false
    private var alignButton: UIButton!
    private var alignBannerLabel: UILabel!

    /// Ground speed below which the anchor is refused even when the airborne estimate says
    /// otherwise. The whole method rests on ground track being a real direction; taxiing at 20 kt
    /// with `gps_course_acc_deg` in the tens of degrees is not that.
    private static let minAnchorGroundSpeedKt: Double = 80

    /// Whether the anchor may be offered at all. Airborne, moving properly, tracking healthy, and
    /// with a GPS course accurate enough to be worth anchoring to.
    private var canCaptureFlightAnchor: Bool {
        isAirborneEstimate
            && lastGPSSpeedKt >= ARTrafficViewController.minAnchorGroundSpeedKt
            && lastGPSCourseDeg >= 0
            && lastGPSCourseAccuracy >= 0 && lastGPSCourseAccuracy <= 5
            && worldIsUsableForDisplay(arTrackingState)
    }
    /// Whether a barometer subscription is live, so the start can be attempted from several
    /// points without stacking subscriptions. Cleared again if the stream errors.
    private var altimeterStarted = false
    /// Last Motion authorisation state written to the log, so a repeated start attempt records
    /// only genuine changes rather than one row per attempt.
    private var lastLoggedMotionAuth: String?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true

        setupUI()
        setupARScene()
        setupLocation()
        setupObservers()
        setupGestures()
        loadAirports()

        if let saved = ARVisualizationSettings.load() {
            sceneManager?.settings = saved
            connectionLogic.updateInternetQueryRadius(saved.aircraftMaxDistance)
        }

        // Both collaborators read and write the one ownship estimate.
        connectionLogic.ownshipEstimator = ownshipEstimator
        sceneManager?.ownshipEstimator   = ownshipEstimator
        // The barometer is deliberately not started here — see
        // startDiagnosticAltimeterIfNeeded for why requesting Motion during launch loses the
        // race against the camera and location prompts. Device motion is different: it needs no
        // authorisation, so it raises no prompt to lose the race with.
        startYawRateUpdates()

        if let seed = seedLocation {
            userLocation        = seed.coordinate
            gpsMSLAltitudeFeet  = seed.altitude * CalculationsLogic.metersToFeet
            userAltitude        = gpsMSLAltitudeFeet
            lastHorizontalAccuracy   = seed.horizontalAccuracy
            bestHorizontalAccuracy   = seed.horizontalAccuracy
            lastAcceptedFixTime      = seed.timestamp
            ownshipEstimator.ingestPhoneLocation(
                coordinate: seed.coordinate,
                horizontalAccuracyM: seed.horizontalAccuracy,
                groundSpeedKt: nil,
                trackDeg: nil,
                timestamp: seed.timestamp
            )
            ownshipEstimator.ingestPhoneAltitude(fusedMSLFt: userAltitude)
            connectionLogic.updateLocation(seed.coordinate, altitudeFeet: userAltitude)
        }

        connectionLogic.startListening()

        if let preloadedAircraft, !preloadedAircraft.isEmpty {
            connectionLogic.seedInternetAircraft(preloadedAircraft)
        }

        sceneManager?.onSelectionInvalidated = { [weak self] in
            self?.clearSelection()
        }
    }

    /// Start device motion, purely to sample the phone's true yaw rate.
    ///
    /// Device motion needs no Motion & Fitness authorisation — that gates CMAltimeter and the
    /// activity APIs, not the raw gyro — so this is deliberately independent of the altimeter's
    /// permission dance, and keeps working when that is denied.
    ///
    /// The yaw rate wanted is the one about the *vertical* axis, which is the component of the
    /// rotation rate along gravity. Both come from CMDeviceMotion in the same device frame, so it
    /// is a dot product. Using `rotationRate.z` instead would only be the vertical axis while the
    /// phone lay flat, and this phone is held up at every attitude.
    private func startYawRateUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            FlightRecorder.shared.record(event: "device_motion_unavailable")
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let rate = motion.rotationRate
            let gravity = motion.gravity
            let aboutVertical = rate.x * gravity.x + rate.y * gravity.y + rate.z * gravity.z
            self.verticalYawRateDps = aboutVertical * 180.0 / Double.pi
        }
    }

    /// Human-readable CoreMotion authorisation state, for the log and the info panel.
    ///
    /// The error code alone does not distinguish the cases: a flight log showed CMErrorDomain
    /// 105 while the app did not appear in Settings → Privacy & Security → Motion & Fitness at
    /// all — and an app is listed there only once iOS has recorded a decision for it. So
    /// "denied for this app", "never actually asked", and "Fitness Tracking switched off
    /// system-wide, which denies every app and hides the list" all look identical from the
    /// callback. This separates them outright.
    private var motionAuthDescription: String {
        switch CMAltimeter.authorizationStatus() {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        @unknown default:    return "unknown"
        }
    }

    /// Subscribe to the barometer purely to record cabin pressure altitude.
    ///
    /// Barometric fusion was removed from the altitude chain deliberately: inside a
    /// pressurized cabin the sensor measures cabin pressure, not outside static, so GPS is the
    /// only meaningful altitude source. That stands — nothing here touches `userAltitude`.
    /// What the reading is still good for is the comparison itself: the gap between cabin
    /// pressure altitude and GPS geometric altitude is what identifies a pressurized cabin.
    /// It also matters more than it looks: in an *unpressurized* aircraft with no receiver, the
    /// phone's barometer is the only source of ownship pressure altitude there is, and so the
    /// only way to place traffic against the same alt_baro datum the targets report.
    ///
    /// Deliberately **not** called from `viewDidLoad`. Doing so put the Motion request into the
    /// same launch window as the camera prompt and two location prompts (the calibration screen
    /// raises one, `setupLocation` another). iOS presents privacy alerts one at a time, and a
    /// CoreMotion request made while another alert is already up can fail to register at all —
    /// which is exactly the state the FL272 flight ended in: an error reading as "denied" with
    /// no Settings entry to correct it. It is now started from points where the competing
    /// prompts have already resolved.
    ///
    /// Safe to call repeatedly; `altimeterStarted` keeps it to one live subscription.
    private func startDiagnosticAltimeterIfNeeded(trigger: String) {
        guard !altimeterStarted else { return }

        let status = CMAltimeter.authorizationStatus()
        // Only on a change. This is reached from every transition to .normal tracking and from
        // every foreground — the FL272 flight alone had 14 tracking transitions in 38 seconds —
        // and an unchanged status logged each time would flood the 10,000-row ring buffer and
        // push out the placement data it exists to hold.
        let description = motionAuthDescription
        if description != lastLoggedMotionAuth {
            lastLoggedMotionAuth = description
            FlightRecorder.shared.record(
                event: "altimeter_auth",
                detail: "trigger=\(trigger) status=\(description) "
                      + "available=\(CMAltimeter.isRelativeAltitudeAvailable())"
            )
        }

        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        // Only these two states can lead anywhere. A denied or restricted request can produce
        // nothing but another 105, so don't burn one — and don't re-nag a user who genuinely
        // said no every time they foreground the app. Leaving altimeterStarted false means a
        // later foreground re-checks, which is what lets a permission granted in Settings take
        // effect without reinstalling.
        guard status == .notDetermined || status == .authorized else { return }

        altimeterStarted = true
        diagnosticAltimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }
            if let error {
                let nsError = error as NSError
                FlightRecorder.shared.record(
                    event: "altimeter_error",
                    detail: "domain=\(nsError.domain) code=\(nsError.code) "
                          + "status=\(self.motionAuthDescription)"
                )
                // Tear the dead subscription down and clear the flag, so a later foreground
                // re-evaluates instead of the app holding a stream that only ever errors. The
                // status guard above is what stops that becoming a retry loop: after a denial
                // the status is no longer .notDetermined, so the retry returns immediately.
                self.diagnosticAltimeter.stopRelativeAltitudeUpdates()
                self.altimeterStarted = false
                return
            }
            guard let data else { return }
            let hectopascals = data.pressure.doubleValue * 10.0   // CoreMotion reports kPa
            self.cabinPressureAltitudeFeet =
                CalculationsLogic.pressureAltitudeFeet(hectopascals: hectopascals)
            self.ownshipEstimator.ingestPhoneVerticalReferences(
                pressureAltitudeFt: self.cabinPressureAltitudeFeet,
                geoidSeparationFt: self.geoidSeparationFeet
            )
        }
    }

    /// Start a new measurement segment for this glance. Time-to-first-target and the ARKit
    /// tracking states that follow are attributed to this lift.
    private func beginLiftSession(reason: String) {
        liftStartTime = Date()
        hasLoggedFirstTargetThisLift = false
        FlightRecorder.shared.beginLift(reason: reason)
        // The world reset itself is logged by startARSession(), which records every reset
        // whatever triggered it. Marking the glance and resetting the world are different
        // events and no longer share one log line.
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        startARSession(reason: "viewWillAppear")
        beginLiftSession(reason: "viewWillAppear")

        // The map is presented .fullScreen, so viewWillDisappear fires while it is shown
        // (pausing the AR session, invalidating the timer). Restart everything here so
        // the AR view is fully live again when it reappears.

        // Restart the 4 Hz update loop if it was invalidated while we were away.
        if !(updateTimer?.isValid ?? false) {
            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.updateVisualization()
            }
        }
    }

    // MARK: - Memory pressure

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // iOS calls this before resorting to a jetsam kill. Prune airport nodes and
        // hidden aircraft nodes immediately to free SceneKit texture memory.
        sceneManager?.pruneForMemoryPressure()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pauseARSession()
        updateTimer?.invalidate()
        FlightRecorder.shared.endLift(reason: "viewWillDisappear")
    }

    /// Answered here rather than left to the Info.plist.
    ///
    /// The plist already declares all three for iPhone, and eight geometry requests in one build-16
    /// run succeeded — then one was refused with "Supported: portrait", naming *the view
    /// controller* as the limiter. I could not tell from the log what narrowed it partway through,
    /// so rather than guess, the view controller now answers for itself and the question does not
    /// arise. A request for an orientation outside this set is refused, which is why
    /// ScreenOrientationFollower holds an undeclared orientation instead of chasing it.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        [.portrait, .landscapeLeft, .landscapeRight]
    }

    /// Rotation is not a routine layout pass here: both the AR view and the HUD carry a
    /// `CGAffineTransform` whenever the user is zoomed in (see applyZoomAndPanTransform), and
    /// autoresizing a transformed view across a bounds change is the one combination UIKit gets
    /// wrong — it derives the new bounds by inverting the transform, so a zoomed view comes out of
    /// a rotation the wrong size. Dropping to identity for the duration and re-applying afterwards
    /// avoids the question entirely.
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        guard isViewLoaded else {
            super.viewWillTransition(to: size, with: coordinator)
            return
        }
        arSceneView.transform = .identity
        hudOverlayView.transform = .identity
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.arSceneView.frame = self.view.bounds
            self.hudOverlayView.frame = self.view.bounds
            self.clampPanOffset()
            self.applyZoomAndPanTransform()
        }
    }

    deinit {
        UIApplication.shared.isIdleTimerDisabled = false
        connectionLogic.stopListening()
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .black

        arSceneView = ARSCNView(frame: view.bounds)
        arSceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arSceneView)

        offScreenArrowView = OffScreenArrowView(frame: view.bounds)
        offScreenArrowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(offScreenArrowView)

        hudOverlayView = HUDOverlayView(frame: view.bounds)
        hudOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hudOverlayView.isHidden = !(sceneManager?.settings.showHUD ?? true)
        hudOverlayView.setBrightness(sceneManager?.settings.hudBrightness ?? .medium)
        view.addSubview(hudOverlayView)

        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        statusLabel.textColor = .white
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.textAlignment = .left
        statusLabel.isUserInteractionEnabled = false
        statusLabel.isHidden = true
        view.addSubview(statusLabel)

        // Back button
        backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(UIImage(systemName: "arrow.left"), for: .normal)
        backButton.tintColor = .white
        backButton.titleLabel?.font = UIFont.systemFont(ofSize: 22, weight: .medium)
        backButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        backButton.layer.cornerRadius = 24
        backButton.isHidden = true
        backButton.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        view.addSubview(backButton)

        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            backButton.widthAnchor.constraint(equalToConstant: 48),
            backButton.heightAnchor.constraint(equalToConstant: 48)
        ])

        statusLeadingToEdge = statusLabel.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: 12)
        statusLeadingToBack = statusLabel.leadingAnchor.constraint(
            equalTo: backButton.trailingAnchor, constant: 8)
        statusLeadingToEdge.isActive = true

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -68)
        ])

        // Settings button (bottom right)
        settingsButton = UIButton(type: .system)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setTitle("⚙️", for: .normal)
        settingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 26)
        settingsButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        settingsButton.layer.cornerRadius = 24
        settingsButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        view.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            settingsButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            settingsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            settingsButton.widthAnchor.constraint(equalToConstant: 48),
            settingsButton.heightAnchor.constraint(equalToConstant: 48)
        ])

        // Map button (top right, round)
        mapButton = UIButton(type: .system)
        mapButton.translatesAutoresizingMaskIntoConstraints = false
        mapButton.setImage(UIImage(systemName: "map.fill"), for: .normal)
        mapButton.tintColor = .white
        mapButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        mapButton.layer.cornerRadius = 24
        mapButton.addTarget(self, action: #selector(showMap), for: .touchUpInside)
        view.addSubview(mapButton)

        NSLayoutConstraint.activate([
            mapButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            mapButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            mapButton.widthAnchor.constraint(equalToConstant: 48),
            mapButton.heightAnchor.constraint(equalToConstant: 48)
        ])

        // Info button (toggles status label)
        infoButton = UIButton(type: .system)
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.setImage(UIImage(systemName: "info.circle.fill"), for: .normal)
        infoButton.tintColor = .white
        infoButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        infoButton.layer.cornerRadius = 24
        infoButton.addTarget(self, action: #selector(infoButtonTapped), for: .touchUpInside)
        view.addSubview(infoButton)

        NSLayoutConstraint.activate([
            infoButton.topAnchor.constraint(equalTo: mapButton.bottomAnchor, constant: 8),
            infoButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            infoButton.widthAnchor.constraint(equalToConstant: 48),
            infoButton.heightAnchor.constraint(equalToConstant: 48)
        ])

        // Align button — the flight-direction anchor. Hidden entirely unless the anchor is
        // available, which is airborne only: on the ground ARKit is already anchored correctly by
        // a compass that works there, so offering this would let the user replace a good reference
        // with a worse one.
        alignButton = UIButton(type: .system)
        alignButton.translatesAutoresizingMaskIntoConstraints = false
        alignButton.setImage(UIImage(systemName: "location.north.line.fill"), for: .normal)
        alignButton.tintColor = .white
        alignButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        alignButton.layer.cornerRadius = 24
        alignButton.isHidden = true
        alignButton.addTarget(self, action: #selector(alignButtonTapped), for: .touchUpInside)
        view.addSubview(alignButton)

        NSLayoutConstraint.activate([
            alignButton.topAnchor.constraint(equalTo: infoButton.bottomAnchor, constant: 8),
            alignButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            alignButton.widthAnchor.constraint(equalToConstant: 48),
            alignButton.heightAnchor.constraint(equalToConstant: 48)
        ])

        // Instruction banner shown only while a capture is running or reporting its result.
        alignBannerLabel = UILabel()
        alignBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        alignBannerLabel.numberOfLines = 0
        alignBannerLabel.textAlignment = .center
        alignBannerLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        alignBannerLabel.textColor = .white
        alignBannerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        alignBannerLabel.layer.cornerRadius = 10
        alignBannerLabel.layer.masksToBounds = true
        alignBannerLabel.isHidden = true
        // Tappable only while an undo is offered — see offerAnchorUndo. A banner that swallows taps
        // the rest of the time would eat them over the scene for no reason.
        alignBannerLabel.isUserInteractionEnabled = false
        alignBannerLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(alignBannerTapped)))
        view.addSubview(alignBannerLabel)

        NSLayoutConstraint.activate([
            alignBannerLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            alignBannerLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            alignBannerLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8)
        ])

        // TCAS border overlay
        tcasOverlayView = UIView(frame: view.bounds)
        tcasOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tcasOverlayView.isUserInteractionEnabled = false
        tcasOverlayView.layer.borderWidth = 8
        tcasOverlayView.layer.borderColor = UIColor.clear.cgColor
        tcasOverlayView.backgroundColor = .clear
        view.insertSubview(tcasOverlayView, aboveSubview: arSceneView)

        // METAR panel (hidden by default, shown when airport selected)
        setupMetarPanel()

        // Keep the off-screen arrow overlay on top of all other views so chevrons
        // are never obscured by the status label, buttons, or METAR panel.
        view.bringSubviewToFront(offScreenArrowView)
    }

    private func setupMetarPanel() {
        metarPanelView = UIView()
        metarPanelView.translatesAutoresizingMaskIntoConstraints = false
        metarPanelView.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        metarPanelView.layer.cornerRadius = 12
        metarPanelView.isHidden = true
        view.addSubview(metarPanelView)

        metarLabel = UILabel()
        metarLabel.translatesAutoresizingMaskIntoConstraints = false
        metarLabel.textColor = .white
        metarLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        metarLabel.numberOfLines = 0
        metarLabel.textAlignment = .left
        metarPanelView.addSubview(metarLabel)

        metarCloseButton = UIButton(type: .system)
        metarCloseButton.translatesAutoresizingMaskIntoConstraints = false
        metarCloseButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        metarCloseButton.tintColor = UIColor.white.withAlphaComponent(0.7)
        metarCloseButton.addTarget(self, action: #selector(closeMetar), for: .touchUpInside)
        metarPanelView.addSubview(metarCloseButton)

        metarAgeLabel = UILabel()
        metarAgeLabel.translatesAutoresizingMaskIntoConstraints = false
        metarAgeLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        metarAgeLabel.textColor = .systemGreen
        metarAgeLabel.textAlignment = .right
        metarAgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        metarPanelView.addSubview(metarAgeLabel)

        NSLayoutConstraint.activate([
            metarPanelView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            metarPanelView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            metarPanelView.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -12),

            metarCloseButton.topAnchor.constraint(equalTo: metarPanelView.topAnchor, constant: 8),
            metarCloseButton.trailingAnchor.constraint(equalTo: metarPanelView.trailingAnchor, constant: -8),
            metarCloseButton.widthAnchor.constraint(equalToConstant: 28),
            metarCloseButton.heightAnchor.constraint(equalToConstant: 28),

            metarAgeLabel.centerYAnchor.constraint(equalTo: metarCloseButton.centerYAnchor),
            metarAgeLabel.trailingAnchor.constraint(equalTo: metarCloseButton.leadingAnchor, constant: -8),

            metarLabel.topAnchor.constraint(equalTo: metarPanelView.topAnchor, constant: 10),
            metarLabel.leadingAnchor.constraint(equalTo: metarPanelView.leadingAnchor, constant: 12),
            metarLabel.trailingAnchor.constraint(equalTo: metarAgeLabel.leadingAnchor, constant: -4),
            metarLabel.bottomAnchor.constraint(equalTo: metarPanelView.bottomAnchor, constant: -10)
        ])
    }

    private func setupARScene() {
        arSceneView.delegate = self
        arSceneView.showsStatistics = false
        sceneManager = ARSceneManager(sceneView: arSceneView)
    }

    private func setupLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .airborne
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = kCLHeadingFilterNone
        // Seed only. It has to track the interface from here on — see followScreenOrientation.
        // The comment that used to sit here claimed pinning this to .portrait "fixes 90° offset in
        // landscape". That was true while the app only ever rendered portrait; once build 16 let
        // the interface rotate, pinning it became the cause of exactly that offset.
        locationManager.headingOrientation = .portrait
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    private func setupObservers() {
        connectionLogic.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusLabel() }
            .store(in: &cancellables)

        connectionLogic.$isInternetAvailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusLabel() }
            .store(in: &cancellables)
        // Note: $detectedAircraft is NOT observed here — updateStatusLabel() is
        // already called every 250ms by updateVisualization(). Subscribing to
        // $detectedAircraft caused a Combine storm (500+ events per merge) that
        // jammed the main run loop on the first internet fetch.

        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateVisualization()
        }

        // Safety net: pause the ARSession the moment the app is backgrounded,
        // regardless of whether viewWillDisappear was called first.
        // ARKit running in the background causes a silent watchdog kill (no crash report).
        NotificationCenter.default.addObserver(
            forName: .appDidBackground, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pauseARSession()
            self?.updateTimer?.fireDate = .distantFuture   // suspend the 4 Hz tick too
            // No point running the gyro with no ARKit azimuth to compare it against, and an
            // open drift run must not be credited with time spent backgrounded.
            self?.motionManager.stopDeviceMotionUpdates()
            self?.verticalYawRateDps = .nan
            self?.yawDrift.closeRun()
            FlightRecorder.shared.endLift(reason: "background")
        }
        NotificationCenter.default.addObserver(
            forName: .appWillForeground, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.startARSession(reason: "foreground")
            self.updateTimer?.fireDate = Date()            // resume immediately
            self.beginLiftSession(reason: "foreground")
            // Returning from Settings is the moment a Motion permission just granted there
            // becomes usable, and the moment a user who switched the system-wide Fitness
            // Tracking toggle on comes back expecting it to work. Without this the column
            // stays empty until the app is reinstalled.
            self.startDiagnosticAltimeterIfNeeded(trigger: "foreground")
            self.startYawRateUpdates()
        }
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arSceneView.addGestureRecognizer(tap)

        // Pinch is added to self.view (not arSceneView) so that ARKit's internal
        // touch handling cannot swallow the two-finger event before we see it.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        // 1-finger pan, only effective while zoomed in (see handlePan) — same
        // reasoning as pinch for being on view rather than arSceneView.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
    }

    // MARK: - Airport Loading

    private var allAirports: [Airport] = []

    private func loadAirports() {
        // Use the user's configured airport range, with a small safety margin so that
        // airports just outside the display range are still available as the user moves.
        // This keeps allAirports small — previously it always held every airport within
        // 200 NM even when the user had set the display range to 10 NM.
        let rangeNM = (sceneManager?.settings.airportMaxDistance ?? 40) * 1.25

        if let preloaded = preloadedAirports {
            allAirports = preloaded
            filterNearbyAirports(from: preloaded, rangeNM: rangeNM)
            return
        }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let parsed = AirportDataParser.loadAirportsFromCSV() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.allAirports = parsed
                self.filterNearbyAirports(from: parsed, rangeNM: rangeNM)
            }
        }
    }

    private func filterNearbyAirports(from parsed: [Airport], rangeNM: Double) {
        let loc = self.userLocation ?? self.activeLocation
        if let loc = loc {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let nearby = CalculationsLogic.filterAirportsInRange(
                    airports: parsed,
                    userCoord: loc,
                    maxRangeNauticalMiles: rangeNM
                )
                DispatchQueue.main.async {
                    self?.airports = nearby
                    self?.lastAirportFilterLocation = loc
                    self?.updateStatusLabel()
                }
            }
        } else {
            self.updateStatusLabel()
        }
    }

    private func refreshNearbyAirports() {
        guard let loc = userLocation ?? activeLocation else { return }
        // Same 25% safety margin as loadAirports() — keeps the working set tight
        // while ensuring airports at the edge of the display radius are included.
        let rangeNM = (sceneManager?.settings.airportMaxDistance ?? 40) * 1.25
        // Capture allAirports on the main thread before hopping to the background.
        // Accessing self.allAirports directly on the background thread is a data race:
        // the main thread writes it in loadAirports() and any concurrent read on the
        // background risks an EXC_BAD_ACCESS via Swift's non-atomic COW bookkeeping.
        let snapshot = allAirports
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let nearby = CalculationsLogic.filterAirportsInRange(
                airports: snapshot,
                userCoord: loc,
                maxRangeNauticalMiles: rangeNM
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.airports = nearby
                self.updateStatusLabel()
            }
        }
    }

    /// Shortest gap allowed between world resets.
    ///
    /// A reset takes ARKit a second or more to work through: tracking drops to
    /// `.limited(.initializing)` and the camera feed stalls until it recovers. Called faster
    /// than it can complete, the session never finishes initialising and the feed simply stops
    /// — the UI keeps running, so it presents as a frozen camera rather than a hung app. That
    /// is what a heading callback firing resets at CoreLocation's ~10 Hz did.
    private static let minARSessionRestartInterval: TimeInterval = 3.0
    private var lastARSessionStart: Date = .distantPast

    /// Whether the session is currently paused. A paused session only resumes by being run
    /// again, so the rate limit must never suppress that call — the app pauses whenever the
    /// map or Settings is shown, and returning from either within the interval would otherwise
    /// leave the camera stopped: the very failure this limit exists to prevent.
    private var isARSessionPaused = true

    /// Opacity the AR content is held at while ARKit has no established world.
    ///
    /// A fade rather than a hide. Blanking the sky for the 1.4 s of `limited:initializing` at every
    /// app open would undo the readiness work that got `first_target` down to 0.25 s, and a faded
    /// marker still says "the traffic is there, the picture is settling" — which is true. What it
    /// stops is the marker being read as a *position* while the transform it is drawn from is
    /// meaningless.
    private static let unusableWorldOpacity: CGFloat = 0.25

    /// Fade the scene to match whether its world is usable. Runs from the tracking-state callback.
    ///
    /// `rootNode.opacity` propagates down the scene graph, so this covers aircraft and airports in
    /// one line with no per-node bookkeeping — and deliberately does not touch `isHidden`, which
    /// the TCAS RA filter and the label settings already own. It also cannot disturb
    /// `renderedAircraftCount`, which is set in updateAircraft rather than in the tick.
    ///
    /// The HUD is a UIKit overlay and is untouched.
    private func applyWorldUsabilityFade() {
        let target: CGFloat = worldIsUsableForDisplay(arTrackingState)
            ? 1.0 : ARTrafficViewController.unusableWorldOpacity
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded else { return }
            let root = self.arSceneView.scene.rootNode
            guard abs(root.opacity - target) > 0.001 else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.2
            root.opacity = target
            SCNTransaction.commit()
        }
    }

    /// Pause the session, recording that it is paused so the next `startARSession(reason:)`
    /// is never throttled away and left stopped.
    private func pauseARSession() {
        arSceneView.session.pause()
        isARSessionPaused = true
    }

    /// Whether a world has ever been built in this view, so the very first start always resets.
    private var hasStartedARSession = false

    /// When the last start ran and whether it reset, so the wait for tracking to come back is
    /// attributable to one or the other. Cleared once `.normal` arrives.
    private var lastRecoveryStart: Date?
    private var lastStartWasReset = false

    /// Rolling median of ARKit's azimuth minus the compass — the only continuous read there is on
    /// the alignment error. Reported beside every reset decision as `drift=`, and no longer used to
    /// make one: build 20 branched on it, and the measurement that motivated the branch turned out
    /// to point the other way. See AlignmentDriftMonitor for why it means nothing in the air.
    private var alignmentDrift = AlignmentDriftMonitor()

    /// The same median, applied on the ground. See GroundYawCorrection for the gates.
    private var groundYaw = GroundYawCorrection()
    /// Render-thread throttle for handing that median to the main thread. The correction itself
    /// updates at most once a second; checking faster than twice a second just queues work.
    private var lastGroundYawCheck: TimeInterval = 0
    /// So a refusal is logged when the reason *changes*, not at 2 Hz for the whole flight.
    private var lastLoggedGroundYawRefusal: String?

    /// Why this start is re-anchoring, or nil if it is resuming — the reset decision itself, and
    /// the reason recorded in the log so a reset is never just something that happened.
    ///
    /// A reset re-asks the compass which way north is — and in the cabin the compass answers with
    /// the *aircraft's ground track*, not with where the phone is pointing (`compass_response`
    /// 0.018 across four flights, against 1.00 on the ground). So every airborne reset hands the
    /// scene a fresh, arbitrary rotation equal to the angle between the phone and the nose at that
    /// instant. The user confirmed both halves directly: the error is a single constant shift of
    /// everything, and reopening the app changes it.
    ///
    /// Resuming is now the default at any altitude, not just airborne. A reset costs about a
    /// second of `limited:initializing` with the camera stalled — measured on all four returns in
    /// the build-19 ground log — which is a real price in an app built around a five-second
    /// glance. On the ground it buys back the ~4°/min ARKit yaw drift, so it is worth paying when
    /// the compass says the alignment has actually gone off, and not otherwise. In the air it buys
    /// nothing at all.
    ///
    /// This decides only how the four existing lifecycle call sites behave; it never triggers a
    /// reset by itself. A spontaneous reset path is what produced the reset storm that once froze
    /// the camera, and `minARSessionRestartInterval` should not be the only thing preventing a
    /// repeat.
    private var resetReason: String? {
        guard hasStartedARSession else { return "first_start" }
        guard arSceneView.session.currentFrame != nil else { return "no_frame" }
        if case .notAvailable = arTrackingState { return "tracking_lost" }
        // On the ground, always re-anchor. Build 20 tried deciding this from measured drift, on the
        // assumption that resuming was the cheaper option; the ground log measured the opposite.
        // Resuming makes ARKit relocalize against the world map it already had, which took 5.0 s
        // against 1.4 s for a fresh reset, with cam_yaw swinging through 176.9 -> -108.3 -> -65.3
        // while the transform settled. On the ground that is 3.5x slower for no benefit at all,
        // because a ground reset re-anchors to a compass that genuinely measures the phone.
        //
        // In the air the same five seconds are worth paying: relocalizing preserves the alignment,
        // where a reset would hand the scene a brand-new arbitrary rotation.
        guard isAirborneEstimate else { return "ground" }
        return nil
    }

    /// Start or resume the ARKit world. Rate-limited in here rather than at the call sites, so no
    /// future caller can reintroduce a reset storm.
    private func startARSession(reason: String) {
        let now = Date()
        let sinceLast = now.timeIntervalSince(lastARSessionStart)
        // A paused session always gets its run: throttling that would strand the camera.
        guard isARSessionPaused
                || sinceLast >= ARTrafficViewController.minARSessionRestartInterval else {
            FlightRecorder.shared.record(
                event: "ar_session_reset_suppressed",
                detail: String(format: "reason=%@ since_last=%.2fs", reason, sinceLast)
            )
            return
        }
        lastARSessionStart = now
        isARSessionPaused = false

        // Named to avoid shadowing the `reason` parameter, which names the *call site*, not the
        // reset decision — the log carries both and they answer different questions.
        let whyReset = resetReason
        let resetting = whyReset != nil
        let driftAtDecision = alignmentDrift.medianErrorDeg
        hasStartedARSession = true
        lastRecoveryStart = now
        lastStartWasReset = resetting

        // Logged here rather than at any one call site, so every world reset is recorded
        // whatever triggered it. Without this the reset storm that froze the camera left no
        // trace in the flight log at all.
        //
        // The anchor's full context goes in the detail because a reset *is* the moment the scene's
        // rotation is decided, and until now the only thing recorded about it was that it
        // happened. Every log so far shows heading_acc=-1 here — the compass had no valid heading
        // at all when the world was anchored — which is worth being able to see.
        FlightRecorder.shared.record(
            event: "ar_session_start",
            detail: String(format: "reason=%@ reset=%d why=%@ drift=%.1f airborne=%d gs=%.0fkt track=%.0f hdg=%.0f heading_acc=%.0f declination=%.1f",
                           reason, resetting ? 1 : 0, whyReset ?? "resumed",
                           driftAtDecision ?? Double.nan, isAirborneEstimate ? 1 : 0,
                           lastGPSSpeedKt, lastGPSCourseDeg, lastTrueHeading,
                           lastHeadingAccuracy, magneticDeclinationDeg)
        )

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.providesAudioData = false
        let options: ARSession.RunOptions = resetting ? [.resetTracking, .removeExistingAnchors] : []
        arSceneView.session.run(config, options: options)

        // Everything below undoes state that only a *re-anchored* world invalidates. A resume
        // keeps the same world, the same alignment and the same measurements, so none of it
        // applies — clearing it would throw away readings that are still describing the frame the
        // scene is actually drawn in.
        guard resetting else { return }

        // After a session reset the ARKit world is re-anchored to the current
        // compass heading, so apply the next heading fix directly rather than
        // blending it in from the previous session's smoothed state.
        isFirstHeadingFix = true
        arSceneView.transform = .identity
        hudOverlayView.transform = .identity
        currentZoomScale = 1.0
        panOffset = .zero
        // A restart re-anchors ARKit's world to a fresh compass snapshot, so the previous
        // alignment's measurements describe nothing. Tracking state is cleared with them: it is
        // only ever written from the delegate callback, so without this it keeps reporting the
        // dead session's .normal until ARKit gets round to saying otherwise — which is how a
        // world-yaw sample was once taken 0.32 s before ARKit reported "unavailable".
        //
        // Deliberately not done on the resume path: the delegate only fires on a *change*, so a
        // session paused at .normal and resumed at .normal may never call back, and a state forced
        // to .notAvailable here would stay there — silently stopping placement correction, both
        // response estimators and the orientation follower for the rest of the flight.
        arTrackingState = .notAvailable
        // The delegate fires a moment later with .limited(.initializing), but the scene should not
        // spend that moment drawing markers against a world that has just been thrown away.
        applyWorldUsabilityFade()
        hasSeededWorldYawError = false
        worldYawErrorDeg = 0
        // Without this the large readings that *caused* a ground re-anchor would still be in the
        // window afterwards, and the very next return would re-anchor again on evidence describing
        // a world that no longer exists.
        alignmentDrift.reset()
        // The offset describes one ARKit world. A reset builds a different one, so carrying the
        // number across would apply a correction measured against a frame that no longer exists.
        if hasFlightAnchor {
            FlightRecorder.shared.record(
                event: "anchor_cleared",
                detail: String(format: "offset=%.1f reason=world_reset", appliedWorldYawOffsetDeg)
            )
        }
        hasFlightAnchor = false
        appliedWorldYawOffsetDeg = 0
        sceneManager?.worldYawOffsetDeg = 0
        // Same reasoning for the ground correction and the followed offset: both describe the frame
        // that just ended. The follower especially — its base was measured against ARKit's old
        // azimuth, and following it into a freshly seeded world would carry that error forward.
        groundYaw.reset()
        clearYawFollower(reason: "world_reset")
        pendingGroundSeed = false
        // A new world needs its own alignment, so it gets its own asking.
        alignPrompts.reset()
        worldYawSource = .none
        lastLoggedGroundYawRefusal = nil
        // The gain regression pairs ARKit's azimuth against the gyro's. A reset jumps one and not
        // the other, so a window spanning it would fit that discontinuity as if it were a turn.
        gyroAzimuth.reset()
        followGainEstimator.reset()
        followGain = .nan
        followGainR = .nan
        flightAnchor.cancel()
        anchorCaptureActive = false
        courseResidualDeg = .nan
        compassResponse = .nan
        compassResponseR = .nan
        compassResponseEstimator.reset()
        // The frame-lock *window* is cleared but its published value is kept. A restart re-seeds
        // ARKit's world yaw, so its azimuth jumps arbitrarily while the ground track does not; a
        // window spanning that discontinuity pairs a large response change against a near-zero
        // driver change, and if the restart lands during a turn it feeds a spurious term straight
        // into the numerator of the one measurement this build exists to get right. Keeping the
        // value means a reading earned before a foreground still shows, which was the real reason
        // for not resetting it at all — that reason applies to the answer, not to the window.
        frameLockEstimator.reset()
        frameLockAwaitingTurn = false
        frameLockTrackSwingDeg = 0
        // Drift is a property of the ARKit frame that just ended, so its runs do not carry over.
        yawDrift.reset()
        yawDriftDps = .nan
        yawDriftSeconds = .nan
        yawDriftGyroDeg = .nan
    }

    /// Re-present the launch-time calibration screen as a full-screen popup when
    /// GPS or compass accuracy degrades past the warning threshold while on the
    /// ground. Ground-only (see call sites): recalibrating can't fix compass/GPS
    /// degradation that's normal in flight, and a full-screen popup would block
    /// the live AR traffic view exactly when it's needed most.
    /// Never re-presented once the user has skipped a calibration screen this launch.
    /// Skipping means the sensors never reached calibration's thresholds (GPS ≤ 10 m,
    /// compass ≤ 13°) — and the triggers here fire on *looser* ones (30 m, 20°) detected as
    /// edges, so accuracy that merely wobbles across 20° re-presents the screen the user just
    /// dismissed, over and over.
    private func presentCalibrationPopupIfNeeded() {
        guard !calibrationWasSkipped else { return }
        guard !isCalibrationPopupShowing, presentedViewController == nil else { return }
        isCalibrationPopupShowing = true
        let calibration = CalibrationViewController()
        calibration.modalPresentationStyle = .fullScreen
        calibration.onComplete = { [weak self, weak calibration] _, wasSkipped in
            calibration?.dismiss(animated: true)
            self?.isCalibrationPopupShowing = false
            // Skipping the popup suppresses later ones too, or the same loop just repeats
            // inside the AR session instead of across the launch transition.
            if wasSkipped { self?.calibrationWasSkipped = true }
        }
        present(calibration, animated: true)
    }

    // MARK: - Actions

    @objc private func showSettings() {
        guard let settings = sceneManager?.settings else { return }

        // Collect callsigns of nearby aircraft so the picker offers meaningful options.
        // Offered whenever there is no ADS-B receiver to identify the aircraft for us,
        // airborne or not: identifying your own aircraft is now the only thing that hides
        // it, so it has to be possible to do that on the ramp before departure.
        let wifiMode = !usingADSBGPS
        var nearbyCallsigns: [String] = []
        if wifiMode, let loc = activeLocation {
            nearbyCallsigns = connectionLogic.detectedAircraft.values
                .filter { CalculationsLogic.distanceInNauticalMiles(from: loc, to: $0.coordinate) < 5.0 }
                .map { $0.callsign }
                .filter { !$0.isEmpty && $0 != "OWNSHIP" }
                .sorted()
        }

        // When connected via ADS-B, surface the ownship callsign as a read-only
        // display so the user can confirm which aircraft the receiver identified.
        let adsbCallsign: String? = usingADSBGPS
            ? connectionLogic.ownshipData?.callsign
            : nil

        let vc = SettingsViewController(
            settings: settings,
            allowsOwnshipSelection: wifiMode,
            nearbyCallsigns: nearbyCallsigns,
            adsbOwnshipCallsign: adsbCallsign
        ) { [weak self] updated in
            guard let self else { return }
            self.resumeARIfPaused()
            let old = self.sceneManager?.settings
            var updatedSettings = updated
            updatedSettings.updateFilter()
            self.sceneManager?.settings = updatedSettings
            updatedSettings.save()
            self.connectionLogic.updateInternetQueryRadius(updatedSettings.aircraftMaxDistance)
            self.hudOverlayView.isHidden = !updatedSettings.showHUD
            self.hudOverlayView.setBrightness(updatedSettings.hudBrightness)

            // Selectively clear only what changed — never wipe aircraft when only
            // airport settings changed, and vice versa.

            let airportSettingsChanged =
                updatedSettings.airportMaxDistance  < (old?.airportMaxDistance ?? 0) ||
                updatedSettings.showLargeAirports  != old?.showLargeAirports  ||
                updatedSettings.showMediumAirports != old?.showMediumAirports ||
                updatedSettings.showSmallAirports  != old?.showSmallAirports  ||
                updatedSettings.showAirportDistance != old?.showAirportDistance

            let aircraftSettingsChanged =
                updatedSettings.showAircraft        != old?.showAircraft       ||
                updatedSettings.aircraftMaxDistance  < (old?.aircraftMaxDistance ?? 0) ||
                updatedSettings.callsignFilter      != old?.callsignFilter      ||
                updatedSettings.showGroundAircraft  != old?.showGroundAircraft  ||  // ON or OFF → rebuild to avoid flood
                updatedSettings.showAircraftAltitude != old?.showAircraftAltitude || // label-only toggles — rebuild so
                updatedSettings.showAircraftSpeed   != old?.showAircraftSpeed   ||  // createAircraftMarker re-evaluates
                updatedSettings.showAircraftDistance != old?.showAircraftDistance || // showAircraftLabels correctly
                updatedSettings.showCallsign        != old?.showCallsign        ||
                updatedSettings.showAircraftType    != old?.showAircraftType    ||
                updatedSettings.wifiOwnshipCallsign != old?.wifiOwnshipCallsign

            if airportSettingsChanged {
                self.sceneManager?.clearAirports()
            }
            if aircraftSettingsChanged {
                self.sceneManager?.clearAircraft()
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        // .formSheet doesn't hide the presenting view, so unlike .fullScreen
        // (map, calibration) it never fires viewWillDisappear/viewWillAppear
        // on us — meaning the AR session and HUD update loop would otherwise
        // keep running full tilt underneath the sheet. Pause explicitly here
        // and resume in presentationControllerDidDismiss(_:), which fires for
        // both the Done button and an interactive swipe-down dismiss.
        pauseARSession()
        updateTimer?.invalidate()
        nav.presentationController?.delegate = self
        present(nav, animated: true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        resumeARIfPaused()
    }

    /// Resumes the AR session/update timer after Settings closes. Called
    /// from both presentationControllerDidDismiss(_:) (covers an
    /// interactive swipe-down dismiss) and the Settings onDismiss closure
    /// below (covers the Done button) since it's not guaranteed which of
    /// those fires for any given dismissal — resuming twice is harmless
    /// (startARSession() just resets tracking again).
    private func resumeARIfPaused() {
        guard !(updateTimer?.isValid ?? false) else { return }
        startARSession(reason: "resumeAfterModal")
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateVisualization()
        }
    }

    /// Returns the aircraft list to show on the 2D map.
    /// Applies the WiFi ownship callsign filter (same as the AR view) so the user's
    /// own aircraft is not shown on the map once they have identified it in Settings.
    /// Nothing else is hidden here: the map is used specifically to identify nearby
    /// aircraft, so close traffic always appears.
    private func mapFilteredAircraft() -> [Aircraft] {
        var list = Array(connectionLogic.detectedAircraft.values)
        if let ownCallsign = sceneManager?.settings.wifiOwnshipCallsign {
            list = list.filter { $0.callsign != ownCallsign }
        }
        return list
    }

    @objc private func showMap() {
        guard let loc = activeLocation else { return }
        let settings = sceneManager?.settings ?? ARVisualizationSettings()

        // Apply the same WiFi ownship filter used in the AR view so the user's own
        // aircraft (identified via the "I'm Flying" setting) is hidden on the map too.
        let aircraft = mapFilteredAircraft()

        let vc = MapViewController(
            userLocation: loc,
            userHeading: userHeading,
            aircraft: aircraft,
            airports: airports,
            settings: settings
        )

        // Provide fresh data every live-update tick, applying the same ownship filter.
        vc.dataProvider = { [weak self] in
            guard let self, let loc = self.activeLocation else { return nil }
            return (
                aircraft: self.mapFilteredAircraft(),
                airports: self.airports,
                location: loc,
                heading: self.userHeading
            )
        }

        // When the user taps an item on the map, dismiss the map and select it in the AR view
        vc.onSelect = { [weak self] nodeID in
            self?.applySelection(nodeID: nodeID)
        }

        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    @objc private func backButtonTapped() {
        clearSelection()
    }

    @objc private func closeMetar() {
        hideMetarPanel()
    }

    @objc private func infoButtonTapped() {
        statusLabel.isHidden.toggle()
    }

    // MARK: - Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = currentZoomScale
        case .changed:
            let scale = pinchStartScale * gesture.scale
            currentZoomScale = max(1.0, min(4.0, scale))
            clampPanOffset()
            applyZoomAndPanTransform()
        default:
            break
        }
    }

    /// 1-finger pan, active only while zoomed in — lets the user look
    /// around the magnified view instead of only being able to un-zoom.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard currentZoomScale > 1.0 else { return }
        switch gesture.state {
        case .began:
            panStartOffset = panOffset
        case .changed:
            let t = gesture.translation(in: view)
            panOffset = CGPoint(x: panStartOffset.x + t.x, y: panStartOffset.y + t.y)
            clampPanOffset()
            applyZoomAndPanTransform()
        default:
            break
        }
    }

    /// Keeps panOffset from ever showing past the edge of the scaled Metal
    /// content — the visible viewport can shift by at most half the extra
    /// (zoomed - unzoomed) width/height in either direction.
    private func clampPanOffset() {
        let maxPanX = (currentZoomScale - 1) * view.bounds.width / 2
        let maxPanY = (currentZoomScale - 1) * view.bounds.height / 2
        panOffset = CGPoint(
            x: max(-maxPanX, min(maxPanX, panOffset.x)),
            y: max(-maxPanY, min(maxPanY, panOffset.y))
        )
    }

    /// Digital zoom: scale the AR view layer in the compositor, with the
    /// pan offset applied after (in final screen points, so a given finger
    /// drag distance moves the content the same amount regardless of zoom
    /// level). ARKit owns the camera's projectionTransform and resets it
    /// every frame, so adjusting fieldOfView has no effect — a UIView
    /// transform scales the already-rendered Metal content at composite
    /// time, which is the only reliable way to achieve full-scene digital
    /// zoom in ARKit.
    private func applyZoomAndPanTransform() {
        var t = CGAffineTransform(scaleX: currentZoomScale, y: currentZoomScale)
        t.tx = panOffset.x
        t.ty = panOffset.y
        arSceneView.transform = t
        // HUD content is drawn at raw (unzoomed) projected screen coordinates;
        // applying the same transform keeps the horizon/ladder aligned with the
        // now-magnified AR content beneath it.
        hudOverlayView.transform = t
    }

    // MARK: - Hit Testing / Selection

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let touchPoint = gesture.location(in: arSceneView)
        let hits = arSceneView.hitTest(touchPoint, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true
        ])
        if let hit = hits.first, let nid = containerNodeID(for: hit.node) {
            if case .selected(let current) = selectionState, current == nid {
                clearSelection()
            } else {
                applySelection(nodeID: nid)
            }
        } else {
            clearSelection()
        }
    }

    private func containerNodeID(for node: SCNNode) -> String? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name,
               (name.hasPrefix("aircraft_") || name.hasPrefix("airport_")) {
                return name
            }
            current = n.parent
        }
        return nil
    }

    private func applySelection(nodeID: String) {
        selectionState = .selected(nodeID: nodeID)
        sceneManager?.setSelection(nodeID: nodeID)
        updateSelectionUI(active: true)

        // If an airport was tapped, fetch and show its METAR
        if nodeID.hasPrefix("airport_") {
            let icao = String(nodeID.dropFirst("airport_".count))
            showMetarPanel(for: icao)
        } else {
            hideMetarPanel()
        }
    }

    private func clearSelection() {
        selectionState = .none
        sceneManager?.setSelection(nodeID: nil)
        offScreenArrowView.hide()
        updateSelectionUI(active: false)
        hideMetarPanel()
    }

    private func updateSelectionUI(active: Bool) {
        backButton.isHidden = !active
        statusLeadingToEdge.isActive = !active
        statusLeadingToBack.isActive = active
    }

    // MARK: - METAR / D-ATIS Panel

    private func showMetarPanel(for icao: String) {
        metarSelectedICAO = icao
        metarObservationTime = nil
        metarAgeLabel.text = nil
        metarLabel.text = "\(icao): fetching…"
        metarPanelView.isHidden = false
        fetchWeather(for: icao)
    }

    private func hideMetarPanel() {
        metarFetchTask?.cancel()
        metarFetchTask = nil
        metarPanelView.isHidden = true
        metarSelectedICAO = nil
        metarObservationTime = nil
    }

    /// Entry point: tries D-ATIS for US airports (ICAO starts with K), falls back to METAR.
    private func fetchWeather(for icao: String) {
        metarFetchTask?.cancel()
        if icao.hasPrefix("K") {
            fetchDATIS(for: icao)
        } else {
            fetchMETAROnly(for: icao)
        }
    }

    /// Attempts to retrieve D-ATIS from datis.clowd.io. Falls back to METAR on any failure
    /// or when no D-ATIS is available for the station.
    private func fetchDATIS(for icao: String) {
        guard let url = URL(string: "https://datis.clowd.io/api/\(icao)") else {
            fetchMETAROnly(for: icao)
            return
        }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, self.metarSelectedICAO == icao else { return }
                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    self.fetchMETAROnly(for: icao)
                    return
                }
                guard let data else { self.fetchMETAROnly(for: icao); return }
                if let entries = try? JSONDecoder().decode([DATISEntry].self, from: data),
                   !entries.isEmpty {
                    let text = entries.map { "D-ATIS \($0.type)\n\($0.datis)" }.joined(separator: "\n\n")
                    self.metarLabel.text = text
                    // Parse the HHMMZ issuance time from the D-ATIS body so the age
                    // label reflects when the ATIS was *issued*, not when we fetched it.
                    let rawText = entries.map(\.datis).joined(separator: " ")
                    self.metarObservationTime = self.parseDATISObservationTime(from: rawText) ?? Date()
                } else {
                    // No D-ATIS at this airport, try METAR
                    self.fetchMETAROnly(for: icao)
                }
            }
        }
        metarFetchTask = task
        task.resume()
    }

    private func fetchMETAROnly(for icao: String) {
        metarFetchTask?.cancel()
        let urlStr = "https://aviationweather.gov/api/data/metar?ids=\(icao)&format=raw&hours=2"
        guard let url = URL(string: urlStr) else { return }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, self.metarSelectedICAO == icao else { return }
                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    self.metarLabel.text = "METAR \(icao): unavailable"
                    return
                }
                guard let data,
                      let raw = String(data: data, encoding: .utf8)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else {
                    self.metarLabel.text = "METAR \(icao): no report available"
                    return
                }
                // The API may return multiple METAR lines (oldest…newest); keep only the latest
                let latestMETAR = raw
                    .components(separatedBy: .newlines)
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                    ?? raw
                self.metarLabel.text = "METAR\n\(latestMETAR)"
                self.metarObservationTime = self.parseMetarObservationTime(from: latestMETAR)
            }
        }
        metarFetchTask = task
        task.resume()
    }

    /// Parses the DDHHMM Z observation time from a raw METAR string and returns it as a Date.
    /// METAR format: `ICAO DDHHMM Z ...` – the time group is 7 chars ending in Z.
    private func parseMetarObservationTime(from metar: String) -> Date? {
        let tokens = metar.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
        guard let timeToken = tokens.first(where: {
            $0.count == 7 && $0.hasSuffix("Z") && $0.dropLast().allSatisfy({ $0.isNumber })
        }) else { return nil }
        guard let day    = Int(timeToken.prefix(2)),
              let hour   = Int(timeToken.dropFirst(2).prefix(2)),
              let minute = Int(timeToken.dropFirst(4).prefix(2)) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        comps.day    = day
        comps.hour   = hour
        comps.minute = minute
        comps.second = 0
        guard let date = cal.date(from: comps) else { return nil }
        // If the computed date is in the future the METAR is from last month
        if date > Date() {
            return cal.date(byAdding: .month, value: -1, to: date)
        }
        return date
    }

    /// Parses the HHMMZ issuance time from a D-ATIS text string and returns it as a Date.
    /// D-ATIS text contains a 5-character Zulu time token such as "2345Z".
    /// Falls back to nil if no matching token is found, in which case callers use Date().
    private func parseDATISObservationTime(from text: String) -> Date? {
        let tokens = text.uppercased().components(separatedBy: .whitespacesAndNewlines)
        guard let timeToken = tokens.first(where: {
            $0.count == 5 && $0.hasSuffix("Z") && $0.dropLast().allSatisfy({ $0.isNumber })
        }) else { return nil }
        guard let hour   = Int(timeToken.prefix(2)),
              let minute = Int(timeToken.dropFirst(2).prefix(2)),
              hour < 24, minute < 60 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = hour
        comps.minute = minute
        comps.second = 0
        guard let date = cal.date(from: comps) else { return nil }
        // If the time is more than 1 hour in the future the issuance was yesterday UTC
        if date.timeIntervalSinceNow > 3600 {
            return cal.date(byAdding: .day, value: -1, to: date)
        }
        return date
    }

    // MARK: - Update Loop

    /// Current ownship estimate. Every consumer of position/altitude reads this, so the
    /// renderer, the HUD, TCAS, the map and the traffic query can never disagree about where
    /// we are — and each source's own timestamp and velocity drive its own extrapolation.
    private var ownship: OwnshipSnapshot { ownshipEstimator.snapshot() }

    private var activeLocation: CLLocationCoordinate2D? {
        let snapshot = ownship
        return snapshot.hasPosition ? snapshot.coordinate : nil
    }

    private var activeAltitude: Double { ownship.displayAltitudeFt }

    /// Ground speed in knots for the HUD readout, from whichever source is authoritative.
    private var activeGroundSpeedKt: Double {
        let snapshot = ownship
        return snapshot.hasVelocity ? snapshot.groundSpeedKt : gpsSpeedKt
    }

    private var usingADSBGPS: Bool { ownship.source == .adsb }

    /// TCAS is only meaningful when airborne. Suppress it below 200 ft to avoid
    /// false alerts from ground traffic and to reduce memory pressure on the ground.
    /// Uses ADS-B ownship altitude when connected, iPhone GPS altitude otherwise.
    private var tcasEnabled: Bool {
        isAirborneEstimate
    }

    /// Height above the nearest known airfield, when one is close enough to plausibly be the
    /// field we are at. Nil when no field is near enough to judge by.
    private var heightAboveNearestFieldFt: Double? {
        guard let loc = activeLocation else { return nil }
        var nearestDistNM = Double.greatestFiniteMagnitude
        var nearestElevationFt: Double?
        for airport in airports {
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: loc, to: airport.coordinate)
            guard distNM <= AirborneEstimate.fieldSearchRadiusNM, distNM < nearestDistNM else { continue }
            nearestDistNM = distNM
            nearestElevationFt = airport.elevation
        }
        guard let elevation = nearestElevationFt else { return nil }
        return activeAltitude - elevation
    }

    /// Best available answer to "are we flying", recomputed each tick.
    private func computeIsAirborne() -> (airborne: Bool, basis: String) {
        // A receiver states it outright, in the GDL90 Misc airborne bit.
        if usingADSBGPS, let report = connectionLogic.ownshipData {
            return (!report.isOnGround, "adsb")
        }
        if let heightAboveField = heightAboveNearestFieldFt {
            return (heightAboveField > AirborneEstimate.heightAboveFieldFt,
                    String(format: "agl%.0f", heightAboveField))
        }
        // Nowhere near a known field, so judge by motion instead.
        let speedKt = activeGroundSpeedKt
        return (speedKt > AirborneEstimate.groundSpeedKt, String(format: "gs%.0f", speedKt))
    }

    private func updateVisualization() {
        // One snapshot drives the whole tick. Reading the estimator repeatedly would give
        // each consumer a slightly different dead-reckoned position within the same frame.
        let state = ownshipEstimator.snapshot()
        guard state.hasPosition else { return }
        let loc = state.coordinate
        let altitude = state.displayAltitudeFt

        // Refreshed here so every consumer this tick — culling, TCAS, the node cap and the
        // GPS gate — agrees on whether we are flying.
        let previousAirborne = isAirborneEstimate
        let estimate = computeIsAirborne()
        isAirborneEstimate = estimate.airborne
        airborneBasis      = estimate.basis
        if previousAirborne != estimate.airborne {
            FlightRecorder.shared.record(
                event: "airborne_changed",
                detail: String(format: "%@ basis=%@ alt=%.0f",
                               estimate.airborne ? "airborne" : "ground", estimate.basis, altitude)
            )
            if estimate.airborne {
                // The ARKit world survives takeoff (build 21 only resets on the ground), so the
                // ground compass correction is a valid absolute anchor for the whole flight. This is
                // what makes the correction automatic: a gate-to-gate flight needs no gesture.
                pendingGroundSeed = true
            } else {
                // Landed. The ground correction takes over again, measuring rather than following.
                clearYawFollower(reason: "landed")
            }
        }
        let airborne = isAirborneEstimate

        // Carry the offset through the aircraft's heading change. Ahead of the placement below so
        // this tick's markers are drawn with the offset this tick's heading calls for.
        updateYawFollowing()

        // Pre-filter by distance and basic visibility before touching SceneKit.
        // This keeps the loop in updateAircraft small (≤ maxDistance aircraft)
        // rather than iterating all stored aircraft on the main thread every tick.
        let currentSettings = sceneManager?.settings ?? ARVisualizationSettings()
        let maxDist = currentSettings.aircraftMaxDistance
        let showGround = currentSettings.showGroundAircraft
        // Only the user's own aircraft is ever hidden, and only once they have identified it.
        // Blanket-hiding everything within 2 NM used to stand in for that, but nearby traffic
        // is the traffic that matters most — suppressing it to mask one aircraft costs far
        // more than it saves, and it hid close targets before the user had any way to choose.
        let ownCallsign = currentSettings.wifiOwnshipCallsign
        let aircraftList = connectionLogic.detectedAircraft.values.filter { ac in
            guard showGround || !ac.isGroundTraffic else { return false }
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: loc, to: ac.coordinate)
            guard distNM <= maxDist else { return false }
            if let ownCallsign, ac.callsign == ownCallsign { return false }
            return true
        }

        let cameraPos: SCNVector3
        if let pov = arSceneView.pointOfView {
            let t = pov.worldTransform
            cameraPos = SCNVector3(t.m41, t.m42, t.m43)
        } else {
            cameraPos = .init()
        }

        // Evaluate TCAS only when airborne (> 200 ft). On the ground the proximity
        // of parked/taxiing aircraft would cause constant false TA/RA alerts.
        let tcas: TCASEvaluation
        if airborne {
            // Use the estimator's own velocity so the alerting geometry matches the geometry
            // the markers are drawn with, whichever source is currently authoritative.
            tcas = TCASSystem.evaluate(
                aircraft: aircraftList,
                userLocation: loc,
                userAltitude: altitude,
                userTrack: state.hasVelocity ? state.trackDeg : userHeading,
                userGroundSpeed: state.hasVelocity ? state.groundSpeedKt : 0,
                userVerticalRate: state.verticalRateFpm
            )
        } else {
            // Ground mode — clear any active TCAS alert and pass empty evaluation
            tcas = .clear
        }
        currentTCASEvaluation = tcas
        applyTCASOverlay(tcas)

        sceneManager?.updateAircraft(
            aircraftList,
            userLocation: loc,
            userAltitude: altitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraPos,
            tcasEvaluation: tcas,
            onGround: !airborne
        )
        sceneManager?.updateAirports(
            airports,
            userLocation: loc,
            userAltitude: altitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraPos
        )
        connectionLogic.updateLocation(loc, altitudeFeet: altitude)

        updateAlignButtonVisibility()
        noteFirstTargetIfNeeded(renderedCount: sceneManager?.renderedAircraftCount ?? 0)
        recordFlightSampleIfDue(state: state, aircraft: aircraftList)

        // Update off-screen arrows at 4 Hz alongside the rest of the visualization.
        // Previously these ran at 60 Hz inside renderer(_:updateAtTime:); at 4 Hz
        // the arrow positions are more than accurate enough (aircraft move < 0.1 NM
        // between ticks) and this saves a significant chunk of CPU/RAM each second.
        if case .selected(let nodeID) = selectionState {
            updateOffScreenArrow(for: nodeID)
        }
        updateTCASArrows()
        updateMetarAgeLabel()
        updateStatusLabel()
    }

    // MARK: - Flight Recorder

    /// Log how long this glance took to put a target on screen. The app is used in
    /// seconds-long lifts, so this is measured per lift rather than once per launch.
    private func noteFirstTargetIfNeeded(renderedCount: Int) {
        guard !hasLoggedFirstTargetThisLift, renderedCount > 0 else { return }
        hasLoggedFirstTargetThisLift = true
        let elapsed = liftStartTime.map { Date().timeIntervalSince($0) } ?? -1
        let staleCount = connectionLogic.detectedAircraft.values
            .filter { CalculationsLogic.isStale($0) }.count
        FlightRecorder.shared.record(
            event: "first_target",
            detail: String(format: "t=%.2fs rendered=%d stale=%d ar=%@ faded=%d",
                           elapsed, renderedCount, staleCount, arTrackingStateDescription,
                           worldIsUsableForDisplay(arTrackingState) ? 0 : 1)
        )
    }

    /// Emit one flight-recorder row per second, driven off the existing 4 Hz tick so no
    /// additional timer is needed.
    private func recordFlightSampleIfDue(state: OwnshipSnapshot, aircraft: [Aircraft]) {
        let now = Date()
        guard now.timeIntervalSince(lastRecorderSampleTime) >= 1.0 else { return }
        lastRecorderSampleTime = now
        FlightRecorder.shared.record(currentFlightSample(state: state, aircraft: aircraft))
    }

    private func currentFlightSample(state: OwnshipSnapshot, aircraft: [Aircraft]) -> FlightRecorder.Sample {
        var sample = FlightRecorder.Sample()
        sample.ownship = state

        sample.gpsMSLFt              = gpsMSLAltitudeFeet
        sample.gpsHAEFt              = gpsEllipsoidalAltitudeFeet
        sample.verticalAccuracyM     = lastVerticalAccuracy >= 0 ? lastVerticalAccuracy : nil
        sample.gpsCourseDeg          = lastGPSCourseDeg >= 0 ? lastGPSCourseDeg : nil
        sample.gpsCourseAccuracyDeg  = lastGPSCourseAccuracy >= 0 ? lastGPSCourseAccuracy : nil
        sample.cabinPressureAltitudeFt = cabinPressureAltitudeFeet

        sample.adsbPressureAltitudeFt = connectionLogic.ownshipData.map { $0.altitude }
        sample.adsbHAEFt              = connectionLogic.ownshipGeometricAltitudeFt

        sample.headingMagneticDeg = lastMagneticHeading >= 0 ? lastMagneticHeading : nil
        sample.headingTrueDeg     = lastTrueHeading     >= 0 ? lastTrueHeading     : nil
        sample.headingAccuracyDeg = lastHeadingAccuracy >= 0 ? lastHeadingAccuracy : nil
        sample.declinationDeg     = magneticDeclinationDeg
        // The correction actually being applied to placement this tick, and the GPS-course
        // residual that would expose a cabin bias shared by the compass and ARKit.
        sample.worldYawCorrectionDeg = hasSeededWorldYawError ? worldYawErrorDeg : nil
        sample.compassResponse       = compassResponse.isNaN  ? nil : compassResponse
        sample.compassResponseR      = compassResponseR.isNaN ? nil : compassResponseR
        sample.frameLock             = frameLock.isNaN        ? nil : frameLock
        sample.frameLockR            = frameLockR.isNaN       ? nil : frameLockR
        sample.yawDriftDps           = yawDriftDps.isNaN      ? nil : yawDriftDps
        sample.yawDriftSeconds       = yawDriftSeconds.isNaN  ? nil : yawDriftSeconds
        sample.yawDriftGyroDeg       = yawDriftGyroDeg.isNaN  ? nil : yawDriftGyroDeg
        sample.courseResidualDeg     = courseResidualDeg.isNaN ? nil : courseResidualDeg
        sample.anchorOffsetDeg       = worldYawSource == .none ? nil : appliedWorldYawOffsetDeg
        sample.yawSource             = worldYawSource.rawValue
        sample.yawFollowedDeg        = yawFollower.hasSeed ? yawFollower.followedDeg : nil
        sample.followGain            = followGain.isNaN  ? nil : followGain
        sample.followGainR           = followGainR.isNaN ? nil : followGainR

        // ARKit's raw alignment error: how far the frame the scene is drawn in sits from the
        // live compass, before correction. Deliberately uncorrected — a corrected heading would
        // match the compass by construction and this column would always read zero.
        if let rawAzimuth = currentARFrameRawAzimuthDeg {
            sample.arHeadingDeg = rawAzimuth
            if lastTrueHeading >= 0 {
                sample.headingDeltaDeg = angleDifferenceDeg(from: rawAzimuth, to: lastTrueHeading)
            }
        }

        if let frame = arSceneView.session.currentFrame {
            let angles = frame.camera.eulerAngles
            sample.cameraPitchDeg = Double(angles.x) * 180.0 / .pi
            sample.cameraYawDeg   = Double(angles.y) * 180.0 / .pi
            sample.cameraRollDeg  = Double(angles.z) * 180.0 / .pi
        }
        sample.imageRollDeg    = imageRollDeg.isNaN    ? nil : imageRollDeg
        sample.onScreenRollDeg = onScreenRollDeg.isNaN ? nil : onScreenRollDeg
        // Read from the window scene rather than from the follower's own idea of the orientation,
        // so this column says what is actually on screen. The follower's belief matching reality
        // is precisely what a refused geometry request would break, and a column sourced from the
        // follower could not show it.
        if let scene = view.window?.windowScene {
            sample.interfaceOrientation = ScreenOrientationFollower.describe(scene.interfaceOrientation)
        }
        sample.arTrackingState = arTrackingStateDescription
        sample.airborne        = isAirborneEstimate
        sample.airborneBasis   = airborneBasis

        // Always recorded, including zero: an empty sky at the start of a lift is precisely
        // the readiness signal worth capturing, not a missing value.
        sample.aircraftCount        = aircraft.count
        sample.adsbAircraftCount    = connectionLogic.detectedAircraft.values.filter { $0.source == .adsb }.count
        // Counted from the store here rather than read from ConnectionLogic.internetAircraftCount,
        // which is only recomputed inside the fetch *success* path. In the FL340 log every fetch
        // failed for the last hundred seconds, so that counter froze at its last good value and
        // this column reported 7 aircraft held while the store was demonstrably empty
        // (internet_fetch_failed ... stored=0). A column that says traffic is held when it is not
        // is worse than no column, and n_adsb on the line above already counts the honest way.
        sample.internetAircraftCount = connectionLogic.detectedAircraft.values.filter { $0.source == .internet }.count
        sample.staleAircraftCount   = connectionLogic.detectedAircraft.values.filter { CalculationsLogic.isStale($0) }.count
        sample.renderedNodeCount    = sceneManager?.renderedAircraftCount

        // Measured from the traffic actually on display, so the offset comes from aircraft
        // sharing this air mass rather than from the whole fetch radius.
        sample.targetsWithPressureAltitude  = aircraft.filter { $0.pressureAltitudeFt  != nil }.count
        sample.targetsWithGeometricAltitude = aircraft.filter { $0.geometricAltitudeFt != nil }.count
        sample.datumOffset = AltitudeDatumOffset.estimate(from: aircraft)
        latestDatumOffset  = sample.datumOffset

        return sample
    }

    /// The heading ARKit's world frame is working in, for a camera forward vector.
    ///
    /// This is the frame targets are actually placed in, so it is what the HUD rose shows and
    /// what the flight recorder logs — one function for both, so the rose and the traffic can
    /// never disagree about north.
    ///
    /// No correction is applied, and that is deliberate twice over. It keeps the rose honest
    /// about the frame the markers really live in, including ARKit's own world-alignment error;
    /// and it keeps `heading_delta_deg` measuring something. A corrected heading would equal the
    /// compass by construction, so that column would read zero forever and the alignment error
    /// would become invisible in exactly the log used to diagnose it.
    private func arFrameRawAzimuthDeg(forward: SIMD3<Float>) -> Double {
        let deg = Double(atan2(forward.x, -forward.z)) * 180.0 / Double.pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// ARKit's raw, uncorrected world azimuth for the current frame — what the AR world thinks
    /// north is, before `worldYawErrorDeg` is applied. Logged as `ar_heading_deg`, and against
    /// the compass as `heading_delta_deg`, so a flight log still shows how far off ARKit's own
    /// alignment was even though placement now compensates for it.
    ///
    /// Computed here rather than read from a value the HUD caches, because `updateHUDLadder`
    /// returns early when the HUD is switched off — reading its cache would silently stop
    /// recording this whenever the user hides the HUD. Uses the camera's forward vector rather
    /// than `eulerAngles.y`, since Euler yaw degenerates at steep pitch, which is exactly the
    /// attitude someone holds the phone at to look at traffic.
    private var currentARFrameRawAzimuthDeg: Double? {
        // Before tracking starts the camera transform is still identity, whose forward vector
        // is (0, 0, −1): a perfectly plausible-looking due-north reading that sails through the
        // horizontal-magnitude check below at magnitude 1.0. Recording that would contaminate
        // the alignment measurement with rows that mean nothing, so an untracked frame yields
        // no value at all — a blank column is honest, a confident wrong number is not.
        guard case .normal = arTrackingState else { return nil }
        guard let transform = arSceneView.session.currentFrame?.camera.transform else { return nil }
        let forward = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
        // Near-vertical camera: the horizontal component vanishes and the azimuth is noise.
        guard sqrt(forward.x * forward.x + forward.z * forward.z) > 0.2 else { return nil }
        return arFrameRawAzimuthDeg(forward: forward)
    }

    /// Short label for the current ARKit tracking state, shared by the log and the info panel.
    private var arTrackingStateDescription: String {
        switch arTrackingState {
        case .normal:        return "normal"
        case .notAvailable:  return "unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing:         return "limited:initializing"
            case .relocalizing:         return "limited:relocalizing"
            case .excessiveMotion:      return "limited:motion"
            case .insufficientFeatures: return "limited:features"
            @unknown default:           return "limited:other"
            }
        @unknown default:    return "unknown"
        }
    }

    private func updateMetarAgeLabel() {
        guard !metarPanelView.isHidden, let obsTime = metarObservationTime else { return }
        let ageMin = Int(-obsTime.timeIntervalSinceNow / 60)
        metarAgeLabel.text = "\(ageMin)m ago"
        if ageMin >= 80 {
            metarAgeLabel.textColor = .systemRed
        } else if ageMin >= 60 {
            metarAgeLabel.textColor = .systemOrange
        } else {
            metarAgeLabel.textColor = .systemGreen
        }
    }

    // MARK: - Off-Screen Arrow

    private func updateOffScreenArrow(for nodeID: String) {
        // Prefer the live AR SceneKit node (exact 3D position already in world space).
        // Fall back to computing the AR world position from GPS coordinates so that
        // targets selected from the 2D map still get a directional arrow even when
        // they have no AR node (e.g. outside aircraftMaxDistance, filtered from scene).
        let cameraPos: SCNVector3
        if let pov = arSceneView.pointOfView {
            let t = pov.worldTransform
            cameraPos = SCNVector3(t.m41, t.m42, t.m43)
        } else {
            cameraPos = .init()
        }

        let worldPos: SCNVector3
        if let node = sceneManager?.node(forID: nodeID), !node.isHidden {
            worldPos = node.worldPosition
        } else if let loc = activeLocation {
            // No AR node — derive direction from GPS.
            let targetCoord: CLLocationCoordinate2D?
            let targetAlt: Double
            if nodeID.hasPrefix("aircraft_") {
                let id = String(nodeID.dropFirst("aircraft_".count))
                if let ac = connectionLogic.detectedAircraft[id] {
                    targetCoord = ac.coordinate
                    targetAlt   = ac.altitude
                } else { targetCoord = nil; targetAlt = 0 }
            } else if nodeID.hasPrefix("airport_") {
                let icao = String(nodeID.dropFirst("airport_".count))
                if let ap = airports.first(where: { $0.icao == icao }) {
                    targetCoord = ap.coordinate
                    targetAlt   = ap.elevation
                } else { targetCoord = nil; targetAlt = 0 }
            } else { targetCoord = nil; targetAlt = 0 }

            guard let coord = targetCoord else { offScreenArrowView.hide(); return }
            let rawPos = CalculationsLogic.calculateARPosition(
                targetCoord:      coord,
                targetAltitude:   targetAlt,
                userCoord:        loc,
                userAltitude:     activeAltitude,
                userHeading:      userHeading,
                cameraWorldPosition: cameraPos,
                worldYawOffsetDeg: appliedWorldYawOffsetDeg
            )
            worldPos = ARComponentFactory.scaledPosition(rawPos, relativeTo: cameraPos)
        } else {
            offScreenArrowView.hide()
            return
        }

        let projected  = arSceneView.projectPoint(worldPos)
        let screenSize = arSceneView.bounds.size

        // Determine behind-camera via dot product: SCNView.projectPoint returns
        // undefined z values for behind-camera points (can be < 1.0 on Metal),
        // so we use the sign of (cameraForward · toTarget) instead.
        let toTargetVec = SIMD3<Float>(
            worldPos.x - cameraPos.x,
            worldPos.y - cameraPos.y,
            worldPos.z - cameraPos.z
        )
        let camForwardSel: SIMD3<Float>
        if let t = arSceneView.session.currentFrame?.camera.transform {
            // ARKit camera looks along its local -Z; that axis in world space is
            // the negative of the third column of the camera-to-world transform.
            camForwardSel = SIMD3<Float>(-t.columns.2.x, -t.columns.2.y, -t.columns.2.z)
        } else {
            camForwardSel = SIMD3<Float>(0, 0, -1)
        }
        let behindCamera = simd_dot(camForwardSel, toTargetVec) <= 0

        let onScreen = !behindCamera
            && projected.x >= 0 && CGFloat(projected.x) <= screenSize.width
            && projected.y >= 0 && CGFloat(projected.y) <= screenSize.height

        // When the target is already visible on screen, no overlay arrow is needed —
        // the TCAS ring on the 3D node is sufficient indication.
        if onScreen {
            offScreenArrowView.hide()
            return
        }

        let (edgePoint, angle) = screenEdgePoint(
            projected: CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
            isBehindCamera: behindCamera,
            screenSize: screenSize,
            margin: 40
        )
        offScreenArrowView.show(angle: angle, center: edgePoint)
    }

    /// Exponential moving average for angles, handling the 0°/360° wraparound.
    /// `alpha` is the weight of the new sample (0 < alpha ≤ 1).
    private func smoothAngle(current: Double, new: Double, alpha: Double) -> Double {
        var diff = new - current
        while diff >  180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        var result = current + alpha * diff
        result = result.truncatingRemainder(dividingBy: 360)
        if result < 0 { result += 360 }
        return result
    }

    private func screenEdgePoint(
        projected: CGPoint,
        isBehindCamera: Bool,
        screenSize: CGSize,
        margin: CGFloat
    ) -> (point: CGPoint, angle: CGFloat) {

        let cx = screenSize.width  / 2
        let cy = screenSize.height / 2

        var dir: CGPoint
        if isBehindCamera {
            dir = CGPoint(x: cx - projected.x, y: cy - projected.y)
        } else {
            dir = CGPoint(x: projected.x - cx, y: projected.y - cy)
        }

        if dir.x == 0 && dir.y == 0 { dir = CGPoint(x: 0, y: -1) }

        let angle = atan2(dir.y, dir.x)

        let left   = margin
        let right  = screenSize.width  - margin
        let top    = margin
        let bottom = screenSize.height - margin

        var t = CGFloat.greatestFiniteMagnitude
        if dir.x > 0 { t = min(t, (right  - cx) / dir.x) }
        else if dir.x < 0 { t = min(t, (left   - cx) / dir.x) }
        if dir.y > 0 { t = min(t, (bottom - cy) / dir.y) }
        else if dir.y < 0 { t = min(t, (top    - cy) / dir.y) }

        let edgePoint = CGPoint(x: cx + dir.x * t, y: cy + dir.y * t)
        let uiAngle = angle + .pi / 2

        return (edgePoint, uiAngle)
    }

    // MARK: - TCAS Off-Screen Arrows

    /// For every active TCAS threat that is not the auto-selected node,
    /// draws a colored edge chevron when the aircraft is off-screen.
    /// On-screen threats already have a colored TCAS ring; no overlay needed.
    /// Called from the 4 Hz update loop — not the 60 Hz renderer callback.
    private func updateTCASArrows() {
        let tcas = currentTCASEvaluation
        guard tcas.overallLevel != .none else {
            offScreenArrowView.clearTCASArrows()
            return
        }

        let screenSize = arSceneView.bounds.size
        var arrowData: [(angle: CGFloat, center: CGPoint, color: UIColor)] = []

        for (id, level) in tcas.threats {
            let nodeID = "aircraft_\(id)"
            // Skip the auto-selected node — its arrow is handled by updateOffScreenArrow
            if case .selected(let sel) = selectionState, sel == nodeID { continue }

            guard let node = sceneManager?.node(forID: nodeID), !node.isHidden else { continue }

            let projected = arSceneView.projectPoint(node.worldPosition)

            // Behind-camera via dot product (see updateOffScreenArrow for rationale).
            let camPos = arSceneView.pointOfView?.worldPosition ?? SCNVector3Zero
            let nodePos = node.worldPosition
            let toNodeVec = SIMD3<Float>(
                nodePos.x - camPos.x,
                nodePos.y - camPos.y,
                nodePos.z - camPos.z
            )
            let camFwdTCAS: SIMD3<Float>
            if let t = arSceneView.session.currentFrame?.camera.transform {
                camFwdTCAS = SIMD3<Float>(-t.columns.2.x, -t.columns.2.y, -t.columns.2.z)
            } else {
                camFwdTCAS = SIMD3<Float>(0, 0, -1)
            }
            let behindCamera = simd_dot(camFwdTCAS, toNodeVec) <= 0

            let onScreen = !behindCamera
                && projected.x >= 0 && CGFloat(projected.x) <= screenSize.width
                && projected.y >= 0 && CGFloat(projected.y) <= screenSize.height

            // On-screen threats don't need an overlay — the ring is enough.
            guard !onScreen else { continue }

            let color: UIColor = level == .resolutionAdvisory
                ? UIColor(red: 1.0, green: 0.15, blue: 0.0, alpha: 1.0)  // RA — vivid red
                : UIColor(red: 1.0, green: 0.6,  blue: 0.0, alpha: 1.0)  // TA — amber

            let (edgePoint, angle) = screenEdgePoint(
                projected: CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
                isBehindCamera: behindCamera,
                screenSize: screenSize,
                margin: 40
            )
            arrowData.append((angle: angle, center: edgePoint, color: color))
        }

        offScreenArrowView.setTCASArrows(arrowData)
    }

    // MARK: - TCAS Overlay

    private func applyTCASOverlay(_ tcas: TCASEvaluation) {
        let newLevel = tcas.overallLevel
        let levelChanged = newLevel != lastAppliedTCASLevel
        lastAppliedTCASLevel = newLevel

        switch newLevel {
        case .none:
            tcasOverlayView.layer.borderColor = UIColor.clear.cgColor
            // Returning to normal — restore all aircraft visibility and clear auto-selection
            if levelChanged {
                sceneManager?.setRAFilterActive(false, threatIDs: [])
                clearSelection()
            }

        case .trafficAdvisory:
            tcasOverlayView.layer.borderColor =
                UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.85).cgColor
            // Restore full aircraft visibility (RA isolation may have been active)
            if levelChanged {
                sceneManager?.setRAFilterActive(false, threatIDs: [])
                // Auto-select the primary (closest) TA threat aircraft
                if let primaryID = tcas.threats.keys.first {
                    applySelection(nodeID: "aircraft_\(primaryID)")
                }
            }

        case .resolutionAdvisory:
            tcasOverlayView.layer.borderColor = UIColor.red.cgColor
            // Hide all non-threat aircraft — show only RA/TA targets
            let threatIDs = Set(tcas.threats.keys)
            sceneManager?.setRAFilterActive(true, threatIDs: threatIDs)
            if levelChanged {
                // Auto-select the primary RA threat
                if let primaryID = tcas.threats.first(where: { $0.value == .resolutionAdvisory })?.key
                    ?? tcas.threats.keys.first {
                    applySelection(nodeID: "aircraft_\(primaryID)")
                }
            }
        }
    }

    // MARK: - HUD

    private func updateStatusLabel() {
        if sceneManager?.settings.showHUD == true {
            hudOverlayView.updateReadouts(speedKt: activeGroundSpeedKt, altitudeFt: activeAltitude)
            // Heading-rose updates happen in updateHUDLadder()'s per-frame
            // dispatch block now, not here — it's a visibly rotating
            // element, so it needs the same per-frame cadence as the
            // ladder/bank rose rather than this 0.25s readout timer (was a
            // visible ~4Hz step-jump before).
        }

        var lines: [String] = []

        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            lines.append("🔖 Build \(build)")
        }

        switch connectionLogic.connectionStatus {
        case .receiving:     lines.append("📡 ADS-B: Receiving")
        case .searching:     lines.append("📡 ADS-B: Searching…")
        case .notAvailable:  lines.append("📡 ADS-B: Unavailable")
        case .disconnected:  lines.append("📡 ADS-B: Off")
        }

        lines.append(connectionLogic.isInternetAvailable ? "🌐 Internet: Online" : "🌐 Internet: Offline")

        let displayLoc = activeLocation
        let displayAlt = activeAltitude
        let state = ownshipEstimator.snapshot()
        let gpsSource  = usingADSBGPS ? "ADS-B GPS" : "iPhone GPS"
        if let loc = displayLoc {
            let gpsAccStr: String
            if lastHorizontalAccuracy < 0 {
                gpsAccStr = "?"
            } else if lastHorizontalAccuracy > gpsAccuracyThreshold {
                gpsAccStr = String(format: "⚠️ ±%.0fm", lastHorizontalAccuracy)
            } else {
                gpsAccStr = String(format: "±%.0fm", lastHorizontalAccuracy)
            }
            lines.append(String(format: "📍 %.4f°  %.4f°  (\(gpsSource)  \(gpsAccStr))", loc.latitude, loc.longitude))

            let compassAccStr: String
            if lastHeadingAccuracy < 0 {
                compassAccStr = "?"
            } else if lastHeadingAccuracy > 20 {
                compassAccStr = "⚠️calibrate"
            } else {
                compassAccStr = String(format: "±%.0f°", lastHeadingAccuracy)
            }
            // Declination and ARKit's measured alignment error. Both diagnostic — neither is
            // applied. "—" means no valid sample yet, which differs from a measured 0.
            let yawStr = hasSeededWorldYawError
                ? String(format: "%+.1f°", worldYawErrorDeg)
                : "—"
            let corrStr = String(format: "%+.1f°/%@", magneticDeclinationDeg, yawStr)
            let altAccStr = lastVerticalAccuracy > 0
                ? String(format: "±%.0fft", lastVerticalAccuracy * CalculationsLogic.metersToFeet)
                : "?"
            lines.append(String(format: "✈️ %.0f ft (GPS %@)   🧭 %.0f° (%@)  Δ%@", displayAlt, altAccStr, userHeading, compassAccStr, corrStr))

            // GPS course/speed, and the residual between the corrected AR heading and that
            // course. The residual is only meaningful while the phone points near the nose, but
            // a large one that persists across many orientations is the signature of a cabin
            // magnetic bias shared by the compass and ARKit — the one error the world-yaw
            // correction cannot see, because a shared bias cancels out of it.
            let courseStr = lastGPSCourseAccuracy >= 0
                ? String(format: "%.0f°±%.0f°", lastGPSCourseDeg, lastGPSCourseAccuracy)
                : "invalid"
            let residualStr = courseResidualDeg.isNaN
                ? "—"
                : String(format: "%+.0f°", courseResidualDeg)
            // How much the compass turns per degree the phone turns. ~1 means it is measuring
            // the phone; ~0 means it is reporting something else and no alignment correction
            // may be built on it. "—" until the phone has been turned enough to tell.
            let responseStr = compassResponse.isNaN
                ? "—"
                : String(format: "%.2f", compassResponse)
            // Degrees ARKit's azimuth turns per degree the aircraft turns. A cruise leg never
            // populates it, so say which kind of nothing this is: waiting on the aircraft to
            // turn reads differently from no data at all, and only one is worth chasing.
            let lockStr: String
            if !frameLock.isNaN {
                lockStr = String(format: "%.2f", frameLock)
            } else if frameLockAwaitingTurn {
                lockStr = String(format: "—(no turn, %.1f°)", frameLockTrackSwingDeg)
            } else {
                lockStr = "—"
            }
            // ARKit's drift while the phone is still: the alignment measurement that needs
            // neither a compass nor a turn, and the one that says whether a one-time alignment
            // could survive a glance at all.
            let driftStr = yawDriftDps.isNaN
                ? "—"
                : String(format: "%+.2f°/s over %.0fs", yawDriftDps, yawDriftSeconds)
            lines.append(String(format: "🛩️ %.0fkt  course %@  resid %@  cmp %@  lock %@",
                                lastGPSSpeedKt, courseStr, residualStr, responseStr, lockStr))
            lines.append(String(format: "🌀 ARKit drift %@", driftStr))

            // ── Vertical datums ───────────────────────────────────────────────────────
            // The gap between cabin pressure altitude and GPS geometric altitude is the
            // signature of a pressurized cabin: on an unpressurized aircraft the two track
            // each other to within the local QNH and temperature error, while in a jet the
            // cabin stays near 8,000 ft as the aircraft climbs past it.
            if let cabin = cabinPressureAltitudeFeet, state.hasGeometricAltitude {
                let delta = cabin - state.geometricAltitudeFt
                let verdict = abs(delta) > PressurizationHeuristic.maxPlausibleDeltaFeet
                    ? "PRESSURIZED"
                    : "ambient"
                lines.append(String(format: "🎚 cabin %.0f ft  geo %.0f ft  Δ%+.0f ft (%@)",
                                    cabin, state.geometricAltitudeFt, delta, verdict))
            } else {
                // Say *why* there is no cabin reading. A blank line here cost three rounds of
                // guessing after the FL272 flight: an empty column looks the same whether the
                // sensor is missing, the permission was refused, or the request never landed.
                lines.append("🎚 cabin — (motion: \(motionAuthDescription))")
            }

            // Measured pressure-to-geometric conversion from nearby traffic. Displayed only;
            // it does not yet move any target.
            if let offset = latestDatumOffset {
                lines.append(String(format: "📊 datum offset %+.0f ft  (n=%d, IQR %.0f ft)",
                                    offset.medianFt, offset.sampleCount, offset.spreadFt))
            }
            if state.hasGeoidSeparation {
                lines.append(String(format: "📐 geoid %+.0f ft", state.geoidSeparationFt))
            }
            if state.wasDeadReckoned {
                lines.append(String(format: "⏱ coasting %.1fs on %@", state.fixAge, state.source.rawValue))
            }
        } else {
            lines.append("📍 GPS: Acquiring…")
        }

        // ARKit tracking state
        let arStateStr: String
        switch arTrackingState {
        case .normal:
            arStateStr = "AR: ✓"
        case .limited(let reason):
            switch reason {
            case .initializing:   arStateStr = "AR: Initializing…"
            case .relocalizing:   arStateStr = "AR: Relocalizing…"
            case .excessiveMotion: arStateStr = "AR: ⚠️ Motion"
            case .insufficientFeatures: arStateStr = "AR: ⚠️ Features"
            @unknown default:     arStateStr = "AR: Limited"
            }
        case .notAvailable:
            arStateStr = "AR: Not available"
        @unknown default:
            arStateStr = "AR: Unknown"
        }
        lines.append("📷 \(arStateStr)")

        // TCAS status
        switch currentTCASEvaluation.overallLevel {
        case .none:
            break
        case .trafficAdvisory:
            let count = currentTCASEvaluation.threats.count
            lines.append("⚠️ TCAS TA: \(count) aircraft")
        case .resolutionAdvisory:
            let raCount = currentTCASEvaluation.threats.values.filter { $0 == .resolutionAdvisory }.count
            lines.append("🔴 TCAS RA: \(raCount) aircraft")
        }

        // Traffic
        let total   = connectionLogic.detectedAircraft.count
        let adsbCnt = connectionLogic.detectedAircraft.values.filter { $0.source == .adsb }.count
        let netCnt  = connectionLogic.internetAircraftCount
        var trafficLine = "🛩 Aircraft: \(total)"
        var parts: [String] = []
        if adsbCnt > 0 { parts.append("ADS-B:\(adsbCnt)") }
        if netCnt  > 0 { parts.append("Net:\(netCnt)") }
        if !parts.isEmpty { trafficLine += " (\(parts.joined(separator: " ")))" }
        if let lastUpdate = connectionLogic.detectedAircraft.values
            .max(by: { $0.lastUpdate < $1.lastUpdate })?.lastUpdate {
            let ageSec = Int(-lastUpdate.timeIntervalSinceNow)
            trafficLine += "  [\(ageSec)s ago]"
        }
        lines.append(trafficLine)

        // Receiver link health. A non-zero reject count with ADS-B connected means frames are
        // arriving corrupted, which used to surface as targets that jump rather than as a
        // number anyone could see.
        let counters = FlightRecorder.shared.gdl90Counters()
        if counters.valid > 0 || counters.crcFailures > 0 || counters.malformed > 0 {
            lines.append(String(format: "📶 GDL90 ok:%d  rejected:%d (%.1f%%)",
                                counters.valid,
                                counters.crcFailures + counters.malformed,
                                counters.rejectionRate * 100))
        }

        lines.append("🛫 Airports loaded: \(airports.count)")

        let newText = lines.map { "  \($0)  " }.joined(separator: "\n")
        guard newText != statusLabel.text else { return }
        statusLabel.text = newText
    }
}

// MARK: - ARSCNViewDelegate

extension ARTrafficViewController: ARSCNViewDelegate {

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let pov = arSceneView.pointOfView else { return }
        let t = pov.worldTransform
        let cam = SCNVector3(t.m41, t.m42, t.m43)
        // Before the position ticks, so this frame's markers are placed with this frame's
        // alignment. Deliberately not inside updateHUDLadder: that returns early when the HUD
        // is switched off, which would silently disable placement correction for anyone who
        // hides the HUD.
        updateWorldYawError(pov: pov, at: time)
        // Frozen while ARKit has no established world, so no garbage positions are written during
        // the window the markers are faded out for. At 60 Hz the first tick after recovery puts
        // everything right within one frame.
        if worldIsUsableForDisplay(arTrackingState) {
            sceneManager?.tickAircraftPositions(cameraWorldPosition: cam)
            sceneManager?.tickAirportPositions(cameraWorldPosition: cam)
        }
        // Deliberately still runs: the ladder and bank rose are derived from gravity, which was
        // never the thing ARKit gets wrong here, so they stay live and at full strength.
        updateHUDLadder(pov: pov)
    }

    /// Measure how far ARKit's world frame sits from the compass, and whether the compass is
    /// measuring the phone at all. **Both are recorded; neither is applied.**
    ///
    /// Runs on the SceneKit rendering thread, like the position ticks it precedes.
    private func updateWorldYawError(pov: SCNNode, at time: TimeInterval) {
        // ARKit's azimuth is meaningless outside healthy tracking. This gate is common to
        // everything below, because everything below is measured against that azimuth.
        guard case .normal = arTrackingState else { return }

        let camTransform = simd_float4x4(pov.worldTransform)

        // Which way up the phone physically is.
        //
        // Taken from the *session camera*, never from `pov`. ARSCNView bakes the interface
        // orientation into the point-of-view node, so the node's roll is the phone's roll measured
        // relative to whatever orientation the app happens to be rendering in — which is precisely
        // the quantity this is trying to establish, making it circular. Build 16 read the node and
        // oscillated: portrait showed −1.8°, the table read that as landscape-right, rotating there
        // made the same still phone show −91.3°, the table read that as portrait, and round it
        // went fifteen times in twenty-two seconds. The log measured the two frames differing by
        // exactly 90.000° in portrait and exactly 0.000° in landscape-right, seventeen rows out of
        // seventeen, which is what a pure interface rotation looks like.
        //
        // World up is (0, 1, 0) under .gravityAndHeading, so its dot product with a camera axis is
        // that axis's y component — columns 0 and 1 being the camera's right and up axes.
        //
        // Deliberately ahead of the near-vertical guard below: a flat phone must feed the follower
        // an explicit "unknown" so a half-served dwell is discarded, rather than the whole function
        // returning and the follower resuming a decision the phone has since abandoned.
        var screenRoll: Double?
        if let deviceTransform = arSceneView.session.currentFrame?.camera.transform {
            screenRoll = ScreenOrientationFollower.imageRollDeg(
                cameraRightY: Double(deviceTransform.columns.0.y),
                cameraUpY:    Double(deviceTransform.columns.1.y)
            )
            imageRollDeg = screenRoll ?? .nan
        } else {
            imageRollDeg = .nan
        }

        // The same angle from the pov node — how far the picture is rotated *on screen*. Near zero
        // whenever the interface matches the phone, near ±90 when it does not, so it says directly
        // whether following is working. Recorded only; the decision above never reads it.
        let onScreenRoll = ScreenOrientationFollower.imageRollDeg(
            cameraRightY: Double(camTransform.columns.0.y),
            cameraUpY:    Double(camTransform.columns.1.y)
        )
        onScreenRollDeg = onScreenRoll ?? .nan

        if time - lastOrientationCheck >= 0.2 {
            lastOrientationCheck = time
            let roll = screenRoll
            DispatchQueue.main.async { [weak self] in
                self?.followScreenOrientation(imageRollDeg: roll, at: time)
            }
        }

        let forward = SIMD3<Float>(-camTransform.columns.2.x,
                                   -camTransform.columns.2.y,
                                   -camTransform.columns.2.z)
        // Near-vertical camera: the horizontal component vanishes and the azimuth is noise.
        guard sqrt(forward.x * forward.x + forward.z * forward.z) > 0.2 else { return }

        let rawAzimuthDeg = Double(atan2(forward.x, -forward.z)) * 180.0 / Double.pi

        // The compass gate applies only to the compass-derived values. frame_lock compares ARKit
        // against GPS ground track and never touches the compass, so gating it on compass health
        // would be able to starve the one measurement that does not depend on the compass —
        // exactly when a bad compass makes it most worth having.
        let compassUsable = lastTrueHeading >= 0
            && lastHeadingAccuracy >= 0
            && lastHeadingAccuracy <= maxHeadingAccuracyForYawFix
        if compassUsable {
            worldYawErrorDeg = angleDifferenceDeg(from: rawAzimuthDeg, to: lastTrueHeading)
            hasSeededWorldYawError = true
            // Fed unconditionally, read only on the ground: the airborne gate belongs at the
            // decision (see resetReason), not here, so a lift that lands still has a populated
            // window instead of having to refill one.
            alignmentDrift.add(errorDeg: worldYawErrorDeg, at: time)
        }

        updateResponseEstimators(arDeg: rawAzimuthDeg, compassUsable: compassUsable, at: time)

        // Apply that median on the ground. Read here on the render thread, decided and applied on
        // main, because the offset it writes is consumed by the position ticks.
        if time - lastGroundYawCheck >= 0.5 {
            lastGroundYawCheck = time
            let median = alignmentDrift.medianErrorDeg
            DispatchQueue.main.async { [weak self] in
                self?.updateGroundYawCorrection(medianErrorDeg: median, at: time)
            }
        }

        // Feed a running anchor capture with the same *uncorrected* azimuth the estimators use.
        // Uncorrected on purpose: the offset being captured is exactly the correction, so feeding
        // a corrected azimuth would be measuring a correction against itself.
        if anchorCaptureActive {
            DispatchQueue.main.async { [weak self] in
                self?.updateFlightAnchorCapture(arAzimuthDeg: rawAzimuthDeg, at: time)
            }
        }

        // ARKit's drift while the phone is not being turned. Gated on the gyro, never on ARKit's
        // own attitude — see YawDriftAccumulator. A NaN rate means device motion has not reported
        // yet; passing it through lets the accumulator end the run rather than guess.
        // Integrated here rather than in the device-motion callback so it shares the render clock
        // with the ARKit azimuth it is compared against. The rate itself updates at 20 Hz and is
        // held between updates, which is more than enough resolution for a 90 s regression.
        gyroAzimuth.add(yawRateDps: verticalYawRateDps, at: time)

        yawDrift.add(azimuthDeg: rawAzimuthDeg,
                     gyroYawRateDps: verticalYawRateDps,
                     isTracking: true,
                     at: time)
        if let drift = yawDrift.estimate {
            yawDriftDps      = drift.degreesPerSecond
            yawDriftSeconds  = drift.totalStillSeconds
            yawDriftGyroDeg  = drift.worstGyroNetDeg
        }

        // Diagnostic only — see courseResidualDeg.
        if lastGPSSpeedKt >= 20 && lastGPSCourseAccuracy >= 0 && lastGPSCourseDeg >= 0 {
            courseResidualDeg = angleDifferenceDeg(from: rawAzimuthDeg, to: lastGPSCourseDeg)
        } else {
            courseResidualDeg = .nan
        }
    }

    // MARK: - Ground compass correction

    /// Fold the ARKit-minus-compass median into the applied offset, on the ground only.
    ///
    /// The gates all live in `GroundYawCorrection`; this is the wiring plus the precedence rule.
    /// The flight anchor outranks this outright: once one has been captured, this stops writing for
    /// the life of that world, so the two can never fight over the same variable.
    private func updateGroundYawCorrection(medianErrorDeg: Double?, at time: TimeInterval) {
        guard !hasFlightAnchor else { return }

        let outcome = groundYaw.update(
            medianErrorDeg: medianErrorDeg,
            compassResponse: compassResponse,
            compassResponseR: compassResponseR,
            headingAccuracyDeg: lastHeadingAccuracy,
            airborne: isAirborneEstimate,
            worldUsable: worldIsUsableForDisplay(arTrackingState),
            at: time
        )

        switch outcome {
        case .applied(let offset):
            appliedWorldYawOffsetDeg = offset
            sceneManager?.worldYawOffsetDeg = offset
            worldYawSource = .ground
            lastLoggedGroundYawRefusal = nil
            FlightRecorder.shared.record(
                event: "ground_yaw_applied",
                detail: String(format: "offset=%.2f median=%.2f response=%.2f r=%.2f hdg_acc=%.1f",
                               offset, medianErrorDeg ?? Double.nan,
                               compassResponse, compassResponseR, lastHeadingAccuracy)
            )

        case .refused(let reason):
            // The interesting refusals are the ones that mean the *sensor* is not trustworthy;
            // rate limiting and the deadband are the correction working normally and are not worth
            // a line. Logged on change only, so this reads as a state history rather than a stream.
            switch reason {
            case .rateLimited, .withinDeadband:
                return
            default:
                break
            }
            guard lastLoggedGroundYawRefusal != reason.rawValue else { return }
            lastLoggedGroundYawRefusal = reason.rawValue
            FlightRecorder.shared.record(
                event: "ground_yaw_refused",
                detail: String(format: "reason=%@ median=%.2f response=%.2f r=%.2f hdg_acc=%.1f airborne=%d",
                               reason.rawValue, medianErrorDeg ?? Double.nan,
                               compassResponse, compassResponseR, lastHeadingAccuracy,
                               isAirborneEstimate ? 1 : 0)
            )
        }
    }

    // MARK: - Track following

    /// Whether the aircraft's course is a direction worth integrating right now. Same thresholds the
    /// anchor uses, because the anchor rests on the same quantity.
    private var trackIsUsableForFollowing: Bool {
        lastGPSCourseDeg >= 0
            && lastGPSCourseAccuracy >= 0 && lastGPSCourseAccuracy <= 5
            && lastGPSSpeedKt >= ARTrafficViewController.minAnchorGroundSpeedKt
    }

    /// Advance the followed offset by the heading change since the last tick, and push the result to
    /// placement. Called from the visualisation tick on the main thread.
    private func updateYawFollowing() {
        let now = CACurrentMediaTime()

        if pendingGroundSeed { seedFollowerFromGroundCorrection(at: now) }

        yawFollower.update(trackDeg: lastGPSCourseDeg,
                           courseAccuracyDeg: lastGPSCourseAccuracy,
                           groundSpeedKt: lastGPSSpeedKt,
                           at: now)

        guard let offset = yawFollower.offsetDeg else { return }
        appliedWorldYawOffsetDeg = offset
        sceneManager?.worldYawOffsetDeg = offset
    }

    /// Hand the ground correction to the follower at takeoff. Refused — and left pending — until the
    /// track is a real direction, since the airborne transition can fire a moment before GPS course
    /// settles at climb speed.
    private func seedFollowerFromGroundCorrection(at time: TimeInterval) {
        // An anchor is a better measurement than a ground correction carried through a takeoff, and
        // must never be clobbered by one.
        guard !hasFlightAnchor else { pendingGroundSeed = false; return }
        guard groundYaw.hasOffset else { pendingGroundSeed = false; return }
        guard isAirborneEstimate, trackIsUsableForFollowing else { return }

        pendingGroundSeed = false
        yawFollower.seed(offsetDeg: groundYaw.appliedOffsetDeg,
                         trackDeg: lastGPSCourseDeg,
                         source: .ground,
                         at: time)
        worldYawSource = .ground
        FlightRecorder.shared.record(
            event: "yaw_follow_seeded",
            detail: String(format: "src=ground offset=%.1f track=%.0f gs=%.0fkt",
                           groundYaw.appliedOffsetDeg, lastGPSCourseDeg, lastGPSSpeedKt)
        )
    }

    private func clearYawFollower(reason: String) {
        guard yawFollower.hasSeed else { return }
        FlightRecorder.shared.record(
            event: "yaw_follow_cleared",
            detail: String(format: "reason=%@ offset=%.1f followed=%.1f",
                           reason, yawFollower.offsetDeg ?? Double.nan, yawFollower.followedDeg)
        )
        yawFollower.clear()
        followerBeforeAnchor = nil
        hideAnchorUndo()
    }

    // MARK: - Flight-direction anchor

    /// Start a capture. Refused unless the anchor is available at all — see canCaptureFlightAnchor.
    @objc private func alignButtonTapped() {
        guard canCaptureFlightAnchor else {
            showAlignBanner("Not available — needs steady flight", clearAfter: 2.5)
            return
        }
        guard !anchorCaptureActive else { return }
        // The hold starts on the *render* clock, at the first sample, rather than from a wall clock
        // here: begin() and add() must share one timebase or the progress fraction is nonsense, and
        // the render callback's `time` is the only one both sides can see.
        anchorCaptureActive = true
        alignButton.tintColor = .systemYellow
        showAlignBanner("Point the phone along the direction of flight and hold still", clearAfter: nil)
        FlightRecorder.shared.record(
            event: "anchor_capture_begin",
            detail: String(format: "gs=%.0fkt track=%.0f course_acc=%.1f prior_offset=%.1f prior_src=%@",
                           lastGPSSpeedKt, lastGPSCourseDeg, lastGPSCourseAccuracy,
                           worldYawSource == .none ? Double.nan : appliedWorldYawOffsetDeg,
                           worldYawSource.rawValue)
        )
    }

    /// Feed and close a running capture. Called on the main thread from the render dispatch.
    ///
    /// Samples at ~5 Hz rather than 60: hand wobble is correlated over about a second, so the extra
    /// readings are copies of the same look and only make the median look better-founded than it is.
    private func updateFlightAnchorCapture(arAzimuthDeg: Double, at time: TimeInterval) {
        guard anchorCaptureActive else { return }
        if !flightAnchor.isCapturing { flightAnchor.begin(at: time) }

        // The conditions that made the capture available must hold for its whole duration. Losing
        // tracking or having the aircraft slow down mid-hold invalidates the samples already taken.
        guard canCaptureFlightAnchor else {
            flightAnchor.cancel()
            anchorCaptureActive = false
            finishAlignUI(message: "Alignment cancelled — flight data unsteady")
            FlightRecorder.shared.record(event: "anchor_capture_failed", detail: "reason=conditions_lost")
            return
        }

        if time - lastAnchorSampleTime >= 0.2 {
            lastAnchorSampleTime = time
            flightAnchor.add(arAzimuthDeg: arAzimuthDeg, trackDeg: lastGPSCourseDeg, at: time)
        }

        guard flightAnchor.progress(at: time) >= 1.0 else { return }
        anchorCaptureActive = false

        switch flightAnchor.finish(at: time) {
        case .success(let estimate):
            // How far this capture sits from what following predicts, measured *before* the seed
            // replaces the old state. Nil when nothing was being followed yet.
            let disagreement = yawFollower.disagreementDeg(with: estimate.offsetDeg)
            let predicted = yawFollower.offsetDeg
            followerBeforeAnchor = yawFollower.hasSeed ? yawFollower : nil

            appliedWorldYawOffsetDeg = estimate.offsetDeg
            hasFlightAnchor = true
            // Takes over from any ground correction still in force and locks the ground path out
            // for the life of this world — the anchor is the better measurement in the air.
            worldYawSource = .anchor
            groundYaw.reset()
            pendingGroundSeed = false
            // Seeded, not just applied: an anchor is accurate at the moment it is taken and decays
            // at the rate the aircraft turns. See TrackFollowingYawOffset.
            yawFollower.seed(offsetDeg: estimate.offsetDeg,
                             trackDeg: lastGPSCourseDeg,
                             source: .anchor,
                             at: CACurrentMediaTime())
            sceneManager?.worldYawOffsetDeg = estimate.offsetDeg
            FlightRecorder.shared.record(
                event: "anchor_captured",
                detail: String(format: "offset=%.1f n=%d secs=%.1f az_spread=%.1f track_spread=%.1f world_yaw_corr=%.1f",
                               estimate.offsetDeg, estimate.sampleCount, estimate.seconds,
                               estimate.azimuthSpreadDeg, estimate.trackSpreadDeg, worldYawErrorDeg)
            )

            // A capture the follower disagrees with is the shape of the FL317 mis-aim: the phone was
            // held rock steady 50° off the nose, every gate passed, and 39° of pure error was
            // applied. It is still applied — the user asked for it, and the *old* offset may be the
            // wrong one — but the number is shown and one tap puts it back.
            if let disagreement, abs(disagreement) > ARTrafficViewController.anchorDisagreementDeg {
                FlightRecorder.shared.record(
                    event: "anchor_disagrees",
                    detail: String(format: "captured=%.1f predicted=%.1f delta=%.1f",
                                   estimate.offsetDeg, predicted ?? Double.nan, disagreement)
                )
                offerAnchorUndo(shiftDeg: disagreement)
            } else {
                followerBeforeAnchor = nil
                finishAlignUI(message: String(format: "Aligned — traffic shifted %.0f°", estimate.offsetDeg))
            }
        case .failure(let reason):
            let message: String
            switch reason {
            case .phoneMoved:      message = "Hold the phone steadier and try again"
            case .aircraftTurning: message = "Wait until the turn is finished"
            case .tooFewSamples:   message = "Tracking dropped out — try again"
            case .tooShort:        message = "Hold a moment longer"
            }
            finishAlignUI(message: message)
            FlightRecorder.shared.record(event: "anchor_capture_failed",
                                         detail: "reason=\(reason.rawValue)")
        }
    }

    private func finishAlignUI(message: String) {
        alignButton.tintColor = hasFlightAnchor ? .systemGreen : .white
        showAlignBanner(message, clearAfter: 3.0)
    }

    /// Show the disagreement and make the banner a one-tap undo for a while.
    ///
    /// Longer on screen than an ordinary message: this one is asking the user to judge something,
    /// and three seconds is not enough to look up, compare against the window, and decide.
    private func offerAnchorUndo(shiftDeg: Double) {
        alignButton.tintColor = .systemGreen
        alignBannerLabel.isUserInteractionEnabled = true
        showAlignBanner(String(format: "Traffic shifted %.0f° — tap to undo", shiftDeg),
                        clearAfter: 10.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.hideAnchorUndo()
        }
    }

    private func hideAnchorUndo() {
        // Optional-chained: a world reset clears the follower, and the first one runs from
        // viewWillAppear, which can precede the banner existing.
        alignBannerLabel?.isUserInteractionEnabled = false
        followerBeforeAnchor = nil
    }

    /// Put the previous offset back. Only ever armed while `followerBeforeAnchor` holds one.
    @objc private func alignBannerTapped() {
        guard let prior = followerBeforeAnchor else { return }
        yawFollower = prior
        hasFlightAnchor = prior.source == .anchor
        worldYawSource = prior.source == .anchor ? .anchor : .ground
        if let offset = yawFollower.offsetDeg {
            appliedWorldYawOffsetDeg = offset
            sceneManager?.worldYawOffsetDeg = offset
        }
        FlightRecorder.shared.record(
            event: "anchor_undone",
            detail: String(format: "restored=%.1f src=%@",
                           yawFollower.offsetDeg ?? Double.nan, prior.source?.rawValue ?? "none")
        )
        hideAnchorUndo()
        alignButton.tintColor = hasFlightAnchor ? .systemGreen : .white
        showAlignBanner("Previous alignment restored", clearAfter: 2.5)
    }

    private func showAlignBanner(_ text: String, clearAfter: TimeInterval?) {
        alignBannerLabel.text = "  \(text)  "
        alignBannerLabel.isHidden = false
        guard let clearAfter else { return }
        let shown = text
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) { [weak self] in
            guard let self, self.alignBannerLabel.text == "  \(shown)  " else { return }
            self.alignBannerLabel.isHidden = true
        }
    }

    /// Show or hide the button as the flight state changes, draw attention to it while a flight is
    /// unaligned, and occasionally say so in words. Called from the 4 Hz tick.
    ///
    /// Two flights offered this button on every healthy-tracking row and it was never tapped, so
    /// both flew with `yaw_src=none` and no correction at all. Everything the app can do about
    /// azimuth in the air depends on that one tap — see AlignPromptScheduler.
    private func updateAlignButtonVisibility() {
        let shouldShow = canCaptureFlightAnchor || anchorCaptureActive
        if alignButton.isHidden == shouldShow { alignButton.isHidden = !shouldShow }

        let unaligned = shouldShow && worldYawSource == .none && !anchorCaptureActive
        setAlignButtonPulsing(unaligned)

        let now = CACurrentMediaTime()
        guard alignPrompts.shouldPrompt(available: canCaptureFlightAnchor,
                                        hasOffset: worldYawSource != .none,
                                        capturing: anchorCaptureActive,
                                        at: now)
        else { return }
        // Says what to do, not that something is wrong: the app is working, it just cannot know
        // which way the nose points until it is told once.
        showAlignBanner("Tap ➤ to line traffic up with the aircraft", clearAfter: 6.0)
        FlightRecorder.shared.record(
            event: "align_hint_shown",
            detail: String(format: "n=%d secs_since_available=%.0f",
                           alignPrompts.promptCount, alignPrompts.secondsAvailable(at: now))
        )
    }

    /// Removed rather than left running at zero alpha, so an aligned flight has a completely still
    /// button and the animation cannot survive as an invisible cost on every frame.
    private func setAlignButtonPulsing(_ pulsing: Bool) {
        guard alignButton != nil else { return }
        let key = "alignPulse"
        if pulsing {
            guard alignButton.layer.animation(forKey: key) == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            alignButton.layer.add(pulse, forKey: key)
        } else {
            alignButton.layer.removeAnimation(forKey: key)
        }
    }

    /// Ask the interface to match the way the phone is actually being held.
    ///
    /// `ARSCNView` builds both its projection matrix and its camera-background transform from the
    /// *interface* orientation. When the phone is turned and the interface does not follow, the
    /// entire scene — camera image, target markers, pitch ladder, bank rose — is drawn a quarter
    /// turn off from the user's eyes. Out of an aircraft window the image is near-featureless sky,
    /// so the only part that visibly reads wrong is the HUD, which is exactly how this was
    /// reported: "after turning, the HUD showed like it was 90 degrees sideways".
    ///
    /// iOS would normally have rotated the interface itself. It did not, and the likeliest reason
    /// is the phone's rotation lock — which the app cannot read, and which is not a reasonable
    /// thing to ask a pilot to think about mid-glance. `requestGeometryUpdate` rotates regardless
    /// of the lock, provided the target orientation is one the view controller declares — see the
    /// `supportedInterfaceOrientations` override, which answers for itself rather than leaving it
    /// to be inferred from the Info.plist.
    ///
    /// The angle it acts on must come from the session camera, not from the pov node — see
    /// `ScreenOrientationFollower.imageRollDeg`, and build 16's oscillation.
    ///
    /// Runs on the main thread, dispatched from the render thread at about 5 Hz.
    private func followScreenOrientation(imageRollDeg roll: Double?, at time: TimeInterval) {
        guard let scene = view.window?.windowScene else { return }

        // Adopt any rotation iOS managed on its own first, so the follower never fights a change
        // it already agrees with — and so `current` is never a stale idea of what is on screen.
        orientationFollower.sync(to: scene.interfaceOrientation)

        // Keep the compass referenced to the orientation actually on screen. Deliberately driven
        // from the observed interface rather than from our own requests: the ground test rotated
        // back to portrait without us asking — iOS did it, with no orientation_changed event — and
        // a compass left pointing at the old reference would have gone unnoticed. This runs at
        // 5 Hz, ahead of every guard below, so it keeps working even once following has given up.
        if scene.interfaceOrientation != headingOrientationSetFor {
            headingOrientationSetFor = scene.interfaceOrientation
            let clOrientation = ScreenOrientationFollower.headingOrientation(for: scene.interfaceOrientation)
            locationManager.headingOrientation = clOrientation
            FlightRecorder.shared.record(
                event: "heading_orientation",
                detail: String(format: "ui=%@ cl_raw=%d",
                               ScreenOrientationFollower.describe(scene.interfaceOrientation),
                               clOrientation.rawValue)
            )
        }

        // Three refusals in a row means iOS is not going to allow this, and asking once a second
        // for the rest of the flight would bury the log under a line that says nothing new.
        guard orientationRequestsRefused < 3 else { return }

        let target = orientationFollower.update(imageRollDeg: roll, at: time)

        // The follower gives up on its own if its decisions start oscillating. Record that once:
        // a screen flipping in the pilot's hand is the worst thing this feature can do, and the
        // log has to say plainly that following stopped rather than leaving it to be inferred.
        if let reason = orientationFollower.disabledReason, !loggedOrientationDisabled {
            loggedOrientationDisabled = true
            FlightRecorder.shared.record(
                event: "orientation_following_disabled",
                detail: String(format: "reason=%@ img_roll=%.1f ui_orient=%@",
                               reason, roll ?? Double.nan,
                               ScreenOrientationFollower.describe(scene.interfaceOrientation))
            )
        }

        guard let target,
              target != scene.interfaceOrientation,
              time - lastOrientationRequest >= 1.0
        else { return }
        // A request already in flight lands within a few tenths of a second, during which the
        // follower still sees the old orientation and will happily re-decide. Repeating the *same*
        // target that soon is that echo, not a new intent.
        guard target != lastOrientationRequested || time - lastOrientationRequest >= 5.0 else { return }
        lastOrientationRequest = time
        lastOrientationRequested = target

        let from = scene.interfaceOrientation
        FlightRecorder.shared.record(
            event: "orientation_changed",
            detail: String(format: "from=%@ to=%@ img_roll=%.1f",
                           ScreenOrientationFollower.describe(from),
                           ScreenOrientationFollower.describe(target),
                           roll ?? Double.nan)
        )

        // UIInterfaceOrientationMask is defined as 1 << orientation.rawValue. Building it that way
        // rather than by name sidesteps the long-standing confusion between the device and
        // interface senses of "landscape left" — getting that backwards would rotate the picture
        // the wrong way, which is worse than not rotating it at all.
        let mask = UIInterfaceOrientationMask(rawValue: 1 << UInt(target.rawValue))
        // supportedInterfaceOrientations above is a constant, but UIKit caches the answer, and one
        // build-16 request was refused naming the view controller as the limiter. Asking it to
        // re-read costs nothing and removes that as a possible explanation next time.
        setNeedsUpdateOfSupportedInterfaceOrientations()
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(preferences) { [weak self] error in
            guard let self else { return }
            // A silently refused request looks identical, on screen and in the log, to the bug
            // this exists to fix — so it is recorded, and the count says whether following has
            // been abandoned for the rest of the session.
            self.orientationRequestsRefused += 1
            FlightRecorder.shared.record(
                event: "orientation_request_failed",
                detail: String(format: "to=%@ refused=%d error=%@",
                               ScreenOrientationFollower.describe(target),
                               self.orientationRequestsRefused,
                               error.localizedDescription)
            )
        }
    }

    /// Feed both response estimators. Neither result is applied to anything; both exist to say
    /// which alignment fixes are possible before one is written.
    private func updateResponseEstimators(arDeg: Double, compassUsable: Bool, at time: TimeInterval) {

        // Both estimators sample at roughly 1 Hz, deliberately far below the rate either sensor
        // can supply. Sensor noise arrives per sample while the rotation being measured arrives
        // per degree, so oversampling piles up jitter against a shrinking Σ(Δdriver²) and widens
        // the estimate — see AngularResponse for the derivation and the numbers. Gating on "the
        // compass produced a new reading" is what pushed the first version to ~10 Hz, which is
        // precisely the wrong end of that trade.
        //
        // A compass frozen solid still produces pairs here, with zero response, and correctly
        // drives the slope to zero. That matters: it is the case being hunted, and a version
        // that published nothing for it would report "no data" where the honest answer is zero.
        if compassUsable, time - lastCompassSampleTime >= 1.0 {
            lastCompassSampleTime = time
            compassResponseEstimator.add(driver: arDeg, response: lastTrueHeading, at: time)
        }
        if let estimate = compassResponseEstimator.estimate {
            compassResponse  = estimate.slope
            compassResponseR = estimate.correlation
        }

        // ARKit vs the aircraft's ground track. Same 1 Hz, which is also what GPS course itself
        // updates at; anything faster only adds pairs whose driver change is exactly zero.
        if lastGPSCourseDeg >= 0, lastGPSCourseAccuracy >= 0, lastGPSSpeedKt >= 20,
           time - lastFrameLockSampleTime >= 1.0 {
            lastFrameLockSampleTime = time
            frameLockEstimator.add(driver: lastGPSCourseDeg, response: arDeg, at: time)
            if let estimate = frameLockEstimator.estimate {
                frameLock  = estimate.slope
                frameLockR = estimate.correlation
                frameLockAwaitingTurn = false
                frameLockTrackSwingDeg = estimate.driverExcursionDeg
            } else {
                // Inside the 1 Hz gate rather than every frame: these walk the whole window, and
                // this runs on the render thread.
                frameLockAwaitingTurn = frameLockEstimator.isWaitingForRotation
                // Excursion, not summed rotation: the summed figure read 12° on a flight whose
                // track never left a 0.4° band, which is exactly what made this publish garbage.
                frameLockTrackSwingDeg = frameLockEstimator.driverExcursionDeg
            }

            // The same driver, against an inertial response instead of ARKit's own. A pan moves the
            // gyro and ARKit together and cancels out of (gyro − ARKit), so unlike frame_lock this
            // does not need the phone held still — which is why frame_lock read 0.225 at r=0.05 on
            // the flight where the long baseline said 0.0. Logged only in build 25.
            if gyroAzimuth.hasSamples {
                followGainEstimator.add(driver: lastGPSCourseDeg,
                                        response: gyroAzimuth.azimuthDeg - arDeg,
                                        at: time)
                if let gain = followGainEstimator.estimate {
                    followGain  = gain.slope
                    followGainR = gain.correlation
                }
            }
        }
    }

    /// Compute and push the HUD horizon/pitch-ladder geometry for this frame.
    /// Runs on the SceneKit rendering thread (like the aircraft/airport ticks
    /// above — see the tickNodeSnapshot thread-safety comment on ARSceneManager);
    /// only the final view/layer update is dispatched to main.
    ///
    /// Takes the same `pov` (and its worldTransform) already used for the
    /// aircraft/airport ticks in renderer(_:updateAtTime:), rather than a
    /// separate arSceneView.session.currentFrame?.camera.transform lookup —
    /// the two can be a slightly different snapshot in time, which showed up
    /// as position jitter in the projected horizon/ladder (very visible for a
    /// thin precise line) while barely perturbing angle-only values like
    /// rollDeg/heading (computed from two points sharing the same common-mode
    /// offset, or from an axis already discarded by the horizontal flatten
    /// below) — hence bank/heading already read smooth while the ladder didn't.
    private func updateHUDLadder(pov: SCNNode) {
        guard sceneManager?.settings.showHUD == true else {
            DispatchQueue.main.async { [weak self] in
                self?.hudOverlayView.hideLadder()
                self?.hudOverlayView.updateHorizonArrow(direction: nil)
            }
            return
        }
        let camTransform = simd_float4x4(pov.worldTransform)

        let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
        // ARKit looks along local -Z; that axis in world space is the negative of
        // the transform's third column (same convention used for the off-screen
        // arrow's behind-camera check elsewhere in this file).
        let forwardRaw = SIMD3<Float>(-camTransform.columns.2.x, -camTransform.columns.2.y, -camTransform.columns.2.z)

        // Direction for the fixed off-screen-horizon arrow, if the horizon
        // line itself turns out not to be visible below: forwardRaw.y < 0
        // means the camera is pitched down (looking toward the ground), so
        // the true horizon is above the current view — arrow points up —
        // and vice versa.
        let arrowDirection: HUDOverlayView.HorizonArrowDirection = forwardRaw.y < 0 ? .up : .down

        // Flatten to the world-horizontal plane — ARKit's .gravityAndHeading aligns
        // world Y to true gravity, so this ladder is purely attitude-referenced,
        // independent of the compass/declination math used for aircraft bearing.
        let horizLen = sqrt(forwardRaw.x * forwardRaw.x + forwardRaw.z * forwardRaw.z)
        guard horizLen > 0.05 else {   // looking nearly straight up/down
            DispatchQueue.main.async { [weak self] in
                self?.hudOverlayView.hideLadder()
                self?.hudOverlayView.updateHorizonArrow(direction: arrowDirection)
            }
            return
        }
        // Raw, unfiltered per-frame direction — same approach already used for
        // aircraft/airport node tracking (tickAircraftPositions/tickAirportPositions
        // in renderer(_:updateAtTime:) above), which reads as smooth without any
        // extra smoothing or throttling.
        let forward = SIMD3<Float>(forwardRaw.x / horizLen, 0, forwardRaw.z / horizLen)
        let right = SIMD3<Float>(forward.z, 0, -forward.x)

        let distance: Float = 50
        let center = camPos + forward * distance
        let rise5:  Float = distance * Float(tan(5.0  * Double.pi / 180.0))
        let rise10: Float = distance * Float(tan(10.0 * Double.pi / 180.0))

        func projectedPair(yOffset: Float, halfWidth: Float) -> (CGPoint, CGPoint)? {
            let c  = SIMD3<Float>(center.x, center.y + yOffset, center.z)
            let p1 = c - right * halfWidth
            let p2 = c + right * halfWidth
            // Behind-camera guard via dot product (projectPoint's z is unreliable
            // for this — same technique used for the off-screen arrow elsewhere).
            guard simd_dot(forwardRaw, p1 - camPos) > 0, simd_dot(forwardRaw, p2 - camPos) > 0 else { return nil }
            let sp1 = arSceneView.projectPoint(SCNVector3(p1.x, p1.y, p1.z))
            let sp2 = arSceneView.projectPoint(SCNVector3(p2.x, p2.y, p2.z))
            return (CGPoint(x: CGFloat(sp1.x), y: CGFloat(sp1.y)), CGPoint(x: CGFloat(sp2.x), y: CGFloat(sp2.y)))
        }

        // Short, compact center instrument — 10° rungs drawn longer than the
        // 5° ones (both still shorter than the horizon) so they read as the
        // "bigger" graduation.
        guard let horizon = projectedPair(yOffset: 0, halfWidth: 7) else {
            DispatchQueue.main.async { [weak self] in
                self?.hudOverlayView.hideLadder()
                self?.hudOverlayView.updateHorizonArrow(direction: arrowDirection)
            }
            return
        }
        let plus5   = projectedPair(yOffset: rise5,   halfWidth: 4)
        let minus5  = projectedPair(yOffset: -rise5,  halfWidth: 4)
        let plus10  = projectedPair(yOffset: rise10,  halfWidth: 6)
        let minus10 = projectedPair(yOffset: -rise10, halfWidth: 6)

        // Bank (roll) angle, for the top-of-screen bank-angle rose — derived
        // from the horizon line's own on-screen slope (computed just above)
        // rather than a separate camera-vector formula, so the rose's
        // rotation is guaranteed to match the direction the horizon line
        // itself tilts (already correct/user-confirmed) instead of risking
        // an independent sign bug. When banked right, the horizon's right
        // point renders lower (larger y) than its left point, giving a
        // positive angle — matches updateBank(rollDeg:)'s "positive = right
        // wing down" convention.
        let rollDeg = Double(atan2(horizon.1.y - horizon.0.y, horizon.1.x - horizon.0.x)) * 180.0 / Double.pi

        // Heading, for the bottom-of-screen compass rose — a 2D screen instrument like the bank
        // rose above, computed from the same forward vector as the pitch ladder, and corrected
        // by the same world-yaw term the markers are placed with, so the rose and the traffic
        // agree about which way is north.
        //
        // The GPS-course interference learner that used to sit here is gone. It drove the
        // *camera's* azimuth toward the *aircraft's* ground track, which only holds when the
        // phone points along the nose — looking out a side window it is ~90° wrong. Its own
        // premise was that camera pointing averages onto the nose "over many minutes", but it
        // was reset to zero at every session start and this app is built for a five-second
        // glance, so that average never had a chance to form. In the FL272 log it wandered
        // 0 → +6.1° → −1.7° in 38 seconds, chasing ARKit's own convergence. worldYawErrorDeg
        // now measures that convergence error directly instead of learning around it; the
        // course residual survives as a diagnostic in the flight log.
        let trueHeadingDeg = arFrameRawAzimuthDeg(forward: forward)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // One transaction for all three updates (was two separate
            // transactions before the heading rose moved here) — fewer
            // Core Animation commits per update.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let plus5, let minus5 {
                self.hudOverlayView.updateLadder(horizon: horizon, plus5: plus5, minus5: minus5, plus10: plus10, minus10: minus10)
            } else {
                self.hudOverlayView.hideLadder()
            }
            self.hudOverlayView.updateBank(rollDeg: rollDeg)
            self.hudOverlayView.updateHeading(headingDeg: trueHeadingDeg)
            // The horizon line projected successfully above, but at a
            // steep-but-not-extreme pitch it can still land outside the
            // visible area — show the same fixed arrow in that case too.
            let margin: CGFloat = 20
            let visibleRange = -margin...(self.hudOverlayView.bounds.height + margin)
            if visibleRange.contains(horizon.0.y) || visibleRange.contains(horizon.1.y) {
                self.hudOverlayView.updateHorizonArrow(direction: nil)
            } else {
                self.hudOverlayView.updateHorizonArrow(direction: arrowDirection)
            }
            CATransaction.commit()
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) { }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        arTrackingState = camera.trackingState
        applyWorldUsabilityFade()
        // How long the world took to become usable after the last start, and whether that start
        // reset or resumed. This is the number that decided build 21: a ground resume relocalized
        // in 5.0 s against 1.4 s for a fresh reset. The airborne resume has never been measured,
        // and it is the one whose cost is being defended, so record it rather than assume it.
        var recovery = ""
        if case .normal = camera.trackingState, let started = lastRecoveryStart {
            recovery = String(format: " relocalize_secs=%.2f reset=%d",
                              Date().timeIntervalSince(started), lastStartWasReset ? 1 : 0)
            lastRecoveryStart = nil
        }
        // Logged per transition: the first seconds of every lift are spent in a limited
        // state, and how long that lasts is the thing the readiness work has to move.
        let elapsedSinceLift = liftStartTime.map { Date().timeIntervalSince($0) } ?? -1
        FlightRecorder.shared.record(
            event: "ar_tracking_state",
            detail: String(format: "%@ t=%.2fs targets_faded=%d%@", arTrackingStateDescription,
                           elapsedSinceLift,
                           worldIsUsableForDisplay(camera.trackingState) ? 0 : 1, recovery)
        )
        DispatchQueue.main.async {
            self.updateStatusLabel()
            // The best serialization point available for the Motion request. Tracking reaching
            // .normal proves the camera permission was granted and its alert is gone, and by
            // then the launch screen's location prompt has been answered too — so the Motion
            // alert gets the screen to itself instead of being raised behind another one.
            if case .normal = camera.trackingState {
                self.startDiagnosticAltimeterIfNeeded(trigger: "tracking_normal")
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("AR error: \(error.localizedDescription)")
    }
    func sessionWasInterrupted(_ session: ARSession) { }
    func sessionInterruptionEnded(_ session: ARSession) {
        startARSession(reason: "interruptionEnded")
    }
}

// MARK: - CLLocationManagerDelegate

extension ARTrafficViewController: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        let hAcc = loc.horizontalAccuracy
        let airborne = isAirborneEstimate

        // Ground-only: prompt recalibration if GPS accuracy crosses from good to
        // bad (same threshold as the status-bar ⚠️ warning), before it's overwritten
        // below. Not applied in flight — GPS is expected to degrade there.
        let wasGoodGPS = lastHorizontalAccuracy >= 0 && lastHorizontalAccuracy <= gpsAccuracyThreshold
        if !airborne && wasGoodGPS && hAcc > gpsAccuracyThreshold {
            presentCalibrationPopupIfNeeded()
        }

        // Inside a fuselage the signal is attenuated and accuracy degrades to 30–150 m, so the
        // strict ground threshold would reject every fix in flight.
        let preferredThreshold = airborne ? 500.0 : gpsAccuracyThreshold

        // A degraded fix still beats coasting on an old one. Once the last accepted fix is
        // older than this, accept anything up to the hard ceiling: dead reckoning at cruise
        // speed accumulates error far faster than the extra scatter in a poor fix.
        let staleFixAge = Date().timeIntervalSince(lastAcceptedFixTime)
        let acceptDegraded = staleFixAge > GPSGate.staleFixSeconds
        let ceiling = acceptDegraded ? GPSGate.hardCeilingMeters : preferredThreshold

        guard hAcc > 0, hAcc <= ceiling else {
            if hAcc > 0 { lastHorizontalAccuracy = hAcc }
            updateStatusLabel()
            return
        }
        if acceptDegraded && hAcc > preferredThreshold {
            FlightRecorder.shared.record(
                event: "gps_degraded_accepted",
                detail: String(format: "h_acc=%.0fm last_fix_age=%.1fs", hAcc, staleFixAge)
            )
        }

        // Captured before lastAcceptedFixTime is overwritten: how long the app went without an
        // accepted fix is what decides whether the altitude it is holding still means anything.
        let gapSinceLastFix = staleFixAge
        lastAcceptedFixTime = loc.timestamp
        lastHorizontalAccuracy = hAcc
        if bestHorizontalAccuracy < 0 || hAcc < bestHorizontalAccuracy {
            bestHorizontalAccuracy = hAcc
        }

        let isFirstFix = (userLocation == nil)
        userLocation = loc.coordinate

        // ── Altitude ──────────────────────────────────────────────────────────────────
        // GPS altitude is used directly rather than fused with the phone's barometer — the
        // barometer measures whatever pressure environment it is physically in, which inside
        // a pressurized cabin is cabin pressure, not the outside static air the aircraft's own
        // altimeter reads. GPS is satellite-based and unaffected by cabin pressurization,
        // making it the only sensor still meaningful here.
        //
        // Vertical accuracy gates the update separately from horizontal: the two degrade
        // independently, and a bad altitude tilts every target up or down at once.
        lastVerticalAccuracy = loc.verticalAccuracy
        let verticalCeiling = airborne ? GPSGate.verticalCeilingAirborneMeters
                                       : GPSGate.verticalCeilingGroundMeters
        let verticalWithinCeiling = loc.verticalAccuracy > 0 && loc.verticalAccuracy <= verticalCeiling
        // Bootstrap: some fixes report no vertical accuracy at all. Rejecting every one of
        // those would leave the app with no altitude, which is worse than an approximate one.
        let verticalUsable = verticalWithinCeiling || !hasAcceptedGPSAltitude

        if verticalUsable {
            if !verticalWithinCeiling {
                FlightRecorder.shared.record(
                    event: "gps_altitude_bootstrap",
                    detail: String(format: "v_acc=%.1fm", loc.verticalAccuracy)
                )
            }
            hasAcceptedGPSAltitude = true

            let newGPSFeet = loc.altitude * CalculationsLogic.metersToFeet
            gpsMSLAltitudeFeet = newGPSFeet

            // The phone reports orthometric (MSL) and ellipsoidal altitude for the same fix,
            // so their difference is the local geoid separation — what converts an ADS-B
            // geometric altitude, which is ellipsoid-referenced, into the MSL frame.
            gpsEllipsoidalAltitudeFeet = loc.ellipsoidalAltitude * CalculationsLogic.metersToFeet
            geoidSeparationFeet = gpsEllipsoidalAltitudeFeet - newGPSFeet

            // Light smoothing — GPS vertical accuracy is inherently noisier than horizontal
            // (worse satellite geometry on the vertical axis, further degraded by reduced sky
            // visibility inside a fuselage), so a single fix can swing the displayed altitude
            // by a large amount.
            //
            // But a held altitude only deserves smoothing while it is still roughly true. After a
            // gap it is not: one log resumed after 5.7 minutes during which the aircraft had
            // descended 2,131 ft, and because fixes had been received earlier in the session this
            // blended a five-minute-stale value toward truth at 0.15 per fix — twenty seconds of a
            // 2,131 ft error, which at 5 NM is 4° of vertical misplacement across the whole
            // glance. A stale value has to be replaced, not eased into; the same snap-versus-blend
            // distinction the world-yaw seeding makes.
            let staleAltitude = gapSinceLastFix > GPSGate.staleFixSeconds
            if isFirstFix || staleAltitude {
                if !isFirstFix {
                    FlightRecorder.shared.record(
                        event: "altitude_snapped",
                        detail: String(format: "gap=%.0fs from=%.0fft to=%.0fft",
                                       gapSinceLastFix, userAltitude, newGPSFeet)
                    )
                }
                userAltitude = newGPSFeet
            } else {
                // Time-based rather than per-fix. At the nominal ~1 Hz these agree, but a
                // coefficient per *sample* makes the response depend on how often fixes happen to
                // arrive — the same frame-rate dependence already fixed once in the yaw filter.
                //
                // Note this lags a sustained climb or descent by rate x tau: at 1,200 fpm and the
                // ~6.7 s time constant below that is about 130 ft, which matched the 113 ft
                // plateau measured in descent. Worth knowing; small enough (0.2° at 5 NM) to
                // leave, since shortening it trades that for more vertical noise.
                let dt = max(0.1, min(5.0, gapSinceLastFix))
                let alpha = 1 - exp(-dt / altitudeSmoothingTimeConstant)
                userAltitude += (newGPSFeet - userAltitude) * alpha
            }

            ownshipEstimator.ingestPhoneAltitude(fusedMSLFt: userAltitude)
            ownshipEstimator.ingestPhoneVerticalReferences(
                pressureAltitudeFt: cabinPressureAltitudeFeet,
                geoidSeparationFt: geoidSeparationFeet
            )
        }

        // For the HUD speed readout — speed magnitude validity doesn't depend on
        // course accuracy, unlike the velocity push below.
        if loc.speed >= 0 {
            gpsSpeedKt = loc.speed * 1.944
            lastGPSSpeedKt = gpsSpeedKt
        }
        // Cached for updateHUDLadder() (SceneKit render thread) to read — the GPS-course
        // heading-bias learning needs the same course/accuracy validity signal.
        lastGPSCourseDeg = loc.course
        lastGPSCourseAccuracy = loc.courseAccuracy

        // ── Position and velocity into the single estimator ───────────────────────────
        // Pushed with this fix's own timestamp, so extrapolation between fixes is anchored to
        // when the fix was taken rather than when it was processed. The estimator replaces the
        // scene manager's own dead-reckoning state, which used to mix this timestamp with an
        // ADS-B position written by a different code path.
        let courseUsable = loc.speed >= 0 && loc.courseAccuracy >= 0 && loc.courseAccuracy < 30
        ownshipEstimator.ingestPhoneLocation(
            coordinate: loc.coordinate,
            horizontalAccuracyM: hAcc,
            groundSpeedKt: courseUsable ? loc.speed * 1.944 : nil,   // m/s → knots
            trackDeg: courseUsable ? loc.course : nil,
            timestamp: loc.timestamp
        )

        connectionLogic.updateLocation(loc.coordinate, altitudeFeet: activeAltitude)

        if isFirstFix {
            updateVisualization()
        }

        let needsRefresh: Bool
        if let last = lastAirportFilterLocation {
            needsRefresh = CalculationsLogic.distanceInNauticalMiles(
                from: last, to: loc.coordinate) > 50
        } else {
            needsRefresh = true
        }
        if needsRefresh && !allAirports.isEmpty {
            lastAirportFilterLocation = loc.coordinate
            refreshNearbyAirports()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }

        let accuracy = newHeading.headingAccuracy

        // Degraded compass accuracy prompts recalibration on the ground, but deliberately
        // does NOT reset the ARKit world any more.
        //
        // Resetting cannot improve compass accuracy: it re-anchors ARKit's north to the
        // current sample, which this very condition has just established is a bad one. It also
        // discards the learned interference correction and drops tracking back to
        // initialising. And because this is an edge detector re-armed every time accuracy dips
        // back under the threshold, a compass wobbling around 20° — the exact state that makes
        // a user reach for Skip — fired it at CoreLocation's ~10 Hz. ARKit could never finish
        // initialising between resets, so the camera feed stalled while the UI kept running.
        if !tcasEnabled
            && lastHeadingAccuracy >= 0
            && lastHeadingAccuracy <= 20
            && accuracy > 20 {
            presentCalibrationPopupIfNeeded()
        }

        lastHeadingAccuracy = accuracy
        lastMagneticHeading = newHeading.magneticHeading
        lastTrueHeading     = newHeading.trueHeading
        let trueNorth = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        // Smooth the displayed heading to eliminate sensor noise that causes the
        // compass to appear to spin while flying straight and level.  alpha=0.3
        // gives ~0.3 s response at 10 Hz — responsive to turns, quiet at rest.
        userHeading = isFirstHeadingFix
            ? trueNorth
            : smoothAngle(current: userHeading, new: trueNorth, alpha: 0.3)

        // Magnetic declination = trueHeading − magneticHeading.
        // CLHeading.trueHeading = magneticHeading + WMM geographic lookup-table declination,
        // so their difference is the pure geographic declination — camera-orientation
        // independent and unaffected by in-aircraft EMF (the lookup table is keyed on
        // device location, not on the raw magnetometer).  This replaces the previous
        // GPS-track-based correction which was only valid when the camera faced forward.
        if newHeading.trueHeading >= 0 && newHeading.magneticHeading >= 0 {
            var decl = newHeading.trueHeading - newHeading.magneticHeading
            while decl >  180 { decl -= 360 }
            while decl < -180 { decl += 360 }
            // Smooth the north correction heavily (alpha=0.15, ~0.7 s time constant)
            // so that magnetometer noise doesn't shift every AR node on each callback.
            // Geographic declination changes only over tens of miles, so this lag is
            // imperceptible in practice.
            // smoothAngle works in compass space and returns 0…360, which is wrong for a
            // signed correction: a declination of −12.5° came back as 347.5° and was
            // displayed that way. Placement is unaffected because the bearing arithmetic is
            // modular, but anything that reasons about the size of the correction would be,
            // so it is folded back to −180…180 here.
            let smoothed = isFirstHeadingFix
                ? decl
                : smoothAngle(current: magneticDeclinationDeg, new: decl, alpha: 0.15)
            magneticDeclinationDeg = smoothed > 180 ? smoothed - 360 : smoothed
        }

        isFirstHeadingFix = false

        updateStatusLabel()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
            locationManager.startUpdatingHeading()
        case .denied, .restricted:
            let alert = UIAlertController(
                title: "Location Required",
                message: "TallyOh needs your location to show nearby traffic.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        default:
            break
        }
    }
}
