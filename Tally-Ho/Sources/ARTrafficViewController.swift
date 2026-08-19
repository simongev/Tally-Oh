//
//  ARTrafficViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//

import UIKit
import ARKit
import CoreLocation
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

    private var arKitNorthCorrectionDeg: Double = 0
    private var isFirstHeadingFix: Bool = true

    // Second, independent heading correction layered on top of
    // arKitNorthCorrectionDeg (which only covers geographic magnetic
    // declination). Cockpit magnetic interference can bias ARKit's own
    // world-alignment heading by tens of degrees at session start, and
    // declination correction can't touch that (it cancels out of the
    // raw-magnetometer terms by construction). This term instead learns
    // that bias continuously from GPS ground track, at a very slow rate,
    // regardless of which way the camera currently points — no "hold the
    // phone still" gate. The premise: the user's camera-pointing angle
    // relative to the nose averages toward zero over many samples across
    // a flight (no persistent directional bias in how they look around),
    // so a slow enough average converges on the one thing every sample
    // has in common — the constant interference bias — without ever
    // needing to freeze or delay the displayed heading.
    private var interferenceBiasCorrectionDeg: Double = 0
    private var lastGPSCourseDeg: Double = -1
    private var lastGPSCourseAccuracy: Double = -1
    private var lastGPSSpeedKt: Double = 0

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

        if let seed = seedLocation {
            userLocation        = seed.coordinate
            gpsMSLAltitudeFeet  = seed.altitude * CalculationsLogic.metersToFeet
            userAltitude        = gpsMSLAltitudeFeet
            lastHorizontalAccuracy   = seed.horizontalAccuracy
            bestHorizontalAccuracy   = seed.horizontalAccuracy
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        startARSession()
        sceneManager?.arKitNorthCorrectionDeg = arKitNorthCorrectionDeg

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
        arSceneView.session.pause()
        updateTimer?.invalidate()
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
        locationManager.headingOrientation = .portrait   // fixes 90° offset in landscape: always report heading of physical top (camera axis)
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
            self?.arSceneView.session.pause()
            self?.updateTimer?.fireDate = .distantFuture   // suspend the 4 Hz tick too
        }
        NotificationCenter.default.addObserver(
            forName: .appWillForeground, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.startARSession()
            self.updateTimer?.fireDate = Date()            // resume immediately
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

    private func startARSession() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.providesAudioData = false
        arSceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        // After a session reset the ARKit world is re-anchored to the current
        // compass heading, so apply the next heading fix directly rather than
        // blending it in from the previous session's smoothed state.
        isFirstHeadingFix = true
        arSceneView.transform = .identity
        hudOverlayView.transform = .identity
        currentZoomScale = 1.0
        panOffset = .zero
        // A fresh ARKit world alignment needs its own interference-bias
        // learning restarted — a value learned for the previous alignment
        // isn't valid for this one.
        interferenceBiasCorrectionDeg = 0
    }

    /// Re-present the launch-time calibration screen as a full-screen popup when
    /// GPS or compass accuracy degrades past the warning threshold while on the
    /// ground. Ground-only (see call sites): recalibrating can't fix compass/GPS
    /// degradation that's normal in flight, and a full-screen popup would block
    /// the live AR traffic view exactly when it's needed most.
    private func presentCalibrationPopupIfNeeded() {
        guard !isCalibrationPopupShowing, presentedViewController == nil else { return }
        isCalibrationPopupShowing = true
        let calibration = CalibrationViewController()
        calibration.modalPresentationStyle = .fullScreen
        calibration.onComplete = { [weak self, weak calibration] _ in
            calibration?.dismiss(animated: true)
            self?.isCalibrationPopupShowing = false
        }
        present(calibration, animated: true)
    }

    // MARK: - Actions

    @objc private func showSettings() {
        guard let settings = sceneManager?.settings else { return }

        // Collect callsigns of aircraft within 2 NM so the picker offers meaningful
        // options. We look at the raw (unfiltered) aircraft dictionary so the user
        // can see their own aircraft even when the 2 NM exclusion zone hides it.
        let wifiMode = wifiInAir
        var nearbyCallsigns: [String] = []
        if wifiMode, let loc = activeLocation {
            nearbyCallsigns = connectionLogic.detectedAircraft.values
                .filter { CalculationsLogic.distanceInNauticalMiles(from: loc, to: $0.coordinate) < 2.0 }
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
            wifiInAir: wifiMode,
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
        arSceneView.session.pause()
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
        startARSession()
        sceneManager?.arKitNorthCorrectionDeg = arKitNorthCorrectionDeg
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateVisualization()
        }
    }

    /// Returns the aircraft list to show on the 2D map.
    /// Applies the WiFi ownship callsign filter (same as the AR view) so the user's
    /// own aircraft is not shown on the map once they have identified it in Settings.
    /// The 2 NM exclusion zone is intentionally NOT applied here — the map is used
    /// specifically to identify nearby aircraft, and hiding close traffic would defeat
    /// that purpose.
    private func mapFilteredAircraft() -> [Aircraft] {
        var list = Array(connectionLogic.detectedAircraft.values)
        if wifiInAir, let ownCallsign = sceneManager?.settings.wifiOwnshipCallsign {
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

    private var activeLocation: CLLocationCoordinate2D? {
        if connectionLogic.connectionStatus == .receiving,
           let ownship = connectionLogic.ownshipData,
           ownship.latitude != 0 || ownship.longitude != 0 {
            return ownship.coordinate
        }
        return userLocation
    }

    private var activeAltitude: Double {
        if connectionLogic.connectionStatus == .receiving,
           let ownship = connectionLogic.ownshipData,
           ownship.altitude > -1000 {
            return ownship.altitude
        }
        return userAltitude
    }

    /// Ground speed in knots for the HUD readout — prefers ADS-B ownship (more
    /// precise) over phone GPS, mirroring activeAltitude's fallback pattern.
    private var activeGroundSpeedKt: Double {
        if connectionLogic.connectionStatus == .receiving,
           let ownship = connectionLogic.ownshipData,
           ownship.groundSpeed > 0 {
            return ownship.groundSpeed
        }
        return gpsSpeedKt
    }

    private var usingADSBGPS: Bool {
        guard connectionLogic.connectionStatus == .receiving,
              let ownship = connectionLogic.ownshipData else { return false }
        return ownship.latitude != 0 || ownship.longitude != 0
    }

    /// TCAS is only meaningful when airborne. Suppress it below 200 ft to avoid
    /// false alerts from ground traffic and to reduce memory pressure on the ground.
    /// Uses ADS-B ownship altitude when connected, iPhone GPS altitude otherwise.
    private var tcasEnabled: Bool {
        activeAltitude > 200
    }

    /// True when ADS-B is connected AND ownship altitude is at or below 200 ft.
    /// Used to tighten the node cap so ground traffic doesn't fill VRAM while taxiing.
    private var userIsOnGroundWithADSB: Bool {
        usingADSBGPS && activeAltitude <= 200
    }

    /// True when the user is airborne on a WiFi-only connection (no ADS-B device).
    /// In this mode the app cannot auto-identify the user's aircraft, so we either
    /// hide all traffic within 2 NM (default) or hide only the chosen callsign.
    private var wifiInAir: Bool {
        tcasEnabled && !usingADSBGPS
    }

    private func updateVisualization() {
        guard let loc = activeLocation else { return }

        // Pre-filter by distance and basic visibility before touching SceneKit.
        // This keeps the loop in updateAircraft small (≤ maxDistance aircraft)
        // rather than iterating all stored aircraft on the main thread every tick.
        let currentSettings = sceneManager?.settings ?? ARVisualizationSettings()
        let maxDist = currentSettings.aircraftMaxDistance
        let showGround = currentSettings.showGroundAircraft
        let wifiMode = wifiInAir
        let wifiOwnshipCallsign = currentSettings.wifiOwnshipCallsign
        let aircraftList = connectionLogic.detectedAircraft.values.filter { ac in
            guard showGround || ac.altitude > 50 else { return false }
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: loc, to: ac.coordinate)
            guard distNM <= maxDist else { return false }
            if wifiMode {
                if let selected = wifiOwnshipCallsign {
                    // User identified their plane: hide only that callsign, show everything else.
                    if ac.callsign == selected { return false }
                } else {
                    // No plane identified: hide all traffic within 2 NM to mask own aircraft.
                    if distNM < 2.0 { return false }
                }
            }
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
        if tcasEnabled {
            let ownship = connectionLogic.ownshipData
            tcas = TCASSystem.evaluate(
                aircraft: aircraftList,
                userLocation: loc,
                userAltitude: activeAltitude,
                userTrack: ownship?.track ?? userHeading,
                userGroundSpeed: ownship?.groundSpeed ?? 0,
                userVerticalRate: ownship?.verticalRate ?? 0
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
            userAltitude: activeAltitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraPos,
            tcasEvaluation: tcas,
            onGround: userIsOnGroundWithADSB
        )
        sceneManager?.updateAirports(
            airports,
            userLocation: loc,
            userAltitude: activeAltitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraPos
        )
        connectionLogic.updateLocation(loc, altitudeFeet: activeAltitude)

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
                northCorrectionDeg:  arKitNorthCorrectionDeg
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
            let corrStr = String(format: "%+.1f°/%+.1f°", arKitNorthCorrectionDeg, interferenceBiasCorrectionDeg)
            let altAccStr = lastVerticalAccuracy > 0
                ? String(format: "±%.0fft", lastVerticalAccuracy * CalculationsLogic.metersToFeet)
                : "?"
            lines.append(String(format: "✈️ %.0f ft (GPS %@)   🧭 %.0f° (%@)  Δ%@", displayAlt, altAccStr, userHeading, compassAccStr, corrStr))

            // GPS course/speed feeding the interference-bias learner above —
            // surfaced so a "compass still off" report can be diagnosed
            // directly instead of guessing whether confidentCourseFix is
            // ever actually true for this device/flight.
            let courseStr = lastGPSCourseAccuracy >= 0
                ? String(format: "%.0f°±%.0f°", lastGPSCourseDeg, lastGPSCourseAccuracy)
                : "invalid"
            lines.append(String(format: "🛩️ %.0fkt  course %@", lastGPSSpeedKt, courseStr))
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
        sceneManager?.tickAircraftPositions(cameraWorldPosition: cam)
        sceneManager?.tickAirportPositions(cameraWorldPosition: cam)
        updateHUDLadder(pov: pov)
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

        // Heading, for the bottom-of-screen compass rose — a 2D screen
        // instrument like the bank rose above, computed from the same
        // forward vector as the pitch ladder. Same world-frame
        // convention as CalculationsLogic.calculateARPosition's bearing
        // math (world -Z = ARKit's raw-magnetic north); add back the
        // declination correction so the rose reads *true* heading,
        // consistent with how aircraft bearings are corrected elsewhere.
        let rawHeadingDeg = Double(atan2(forward.x, -forward.z)) * 180.0 / Double.pi

        // Learn and cancel out cockpit magnetic interference in ARKit's own
        // world-alignment heading (arKitNorthCorrectionDeg only covers
        // geographic declination, which is a different, EMF-immune
        // correction — see the property doc comment). Always-on, no
        // "hold the phone still" gate: fed continuously whenever GPS
        // course is trustworthy, at a per-frame gain small enough that no
        // single sample (regardless of which way the camera happens to be
        // pointed at that instant) meaningfully moves the estimate — only
        // the average over many minutes and many camera orientations does,
        // and the constant interference bias is the one thing every sample
        // has in common. This keeps rawHeadingDeg's display fully
        // responsive (matches on-ground behavior) while the correction
        // drifts smoothly toward the right value in the background.
        func angleDiff(_ a: Double, _ b: Double) -> Double {
            var d = b - a
            while d >  180 { d -= 360 }
            while d < -180 { d += 360 }
            return d
        }
        let confidentCourseFix = lastGPSSpeedKt >= 20 && lastGPSCourseAccuracy >= 0
        if confidentCourseFix {
            // GPS course is a shakier estimate of true track at low
            // groundspeed, more reliable as speed increases — ramp the
            // correction's influence smoothly rather than a hard cutoff.
            let speedWeight = max(0, min(1, (lastGPSSpeedKt - 20) / 60))  // 0 at 20kt, 1 by 80kt
            // Same reasoning for course accuracy: a passenger's phone deep in
            // a pressurized fuselage (away from a window's sky view) may
            // rarely or never get a course reading tight enough for a hard
            // cutoff at 30° to ever pass, silently disabling this correction
            // entirely. Ramp it out gradually instead — a degraded-but-not-
            // terrible reading still contributes a little, just discounted.
            let accuracyWeight = max(0, min(1, 1 - lastGPSCourseAccuracy / 90))  // 1 at 0°, 0 by 90°
            let currentEstimate = rawHeadingDeg + arKitNorthCorrectionDeg + interferenceBiasCorrectionDeg
            let residual = angleDiff(currentEstimate, lastGPSCourseDeg)
            interferenceBiasCorrectionDeg = max(-60, min(60,
                interferenceBiasCorrectionDeg + residual * 0.0006 * speedWeight * accuracyWeight))
        }

        let trueHeadingDeg = (rawHeadingDeg + arKitNorthCorrectionDeg + interferenceBiasCorrectionDeg + 360)
            .truncatingRemainder(dividingBy: 360)

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
        DispatchQueue.main.async { self.updateStatusLabel() }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("AR error: \(error.localizedDescription)")
    }
    func sessionWasInterrupted(_ session: ARSession) { }
    func sessionInterruptionEnded(_ session: ARSession) { startARSession() }
}

// MARK: - CLLocationManagerDelegate

extension ARTrafficViewController: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        let hAcc = loc.horizontalAccuracy
        // Ground-only: prompt recalibration if GPS accuracy crosses from good to
        // bad (same threshold as the status-bar ⚠️ warning), before it's overwritten
        // below. Not applied in flight — GPS is expected to degrade there.
        let wasGoodGPS = lastHorizontalAccuracy >= 0 && lastHorizontalAccuracy <= gpsAccuracyThreshold
        if !tcasEnabled && wasGoodGPS && hAcc > gpsAccuracyThreshold {
            presentCalibrationPopupIfNeeded()
        }

        // Inside an aircraft fuselage the GPS signal is attenuated; accuracy
        // typically degrades to 30–150 m, which would make the strict ground
        // threshold (30 m) reject every fix.  In flight (tcasEnabled = altitude
        // > 200 ft) allow up to 500 m — aircraft are separated by > 1 NM so
        // this is still well within useful precision for AR positioning.
        let effectiveThreshold = tcasEnabled ? 500.0 : gpsAccuracyThreshold
        guard hAcc > 0 && hAcc <= effectiveThreshold else {
            if hAcc > 0 { lastHorizontalAccuracy = hAcc }
            updateStatusLabel()
            return
        }

        lastHorizontalAccuracy = hAcc
        if bestHorizontalAccuracy < 0 || hAcc < bestHorizontalAccuracy {
            bestHorizontalAccuracy = hAcc
        }

        let isFirstFix = (userLocation == nil)
        userLocation = loc.coordinate

        // GPS altitude is used directly rather than fused with the phone's
        // barometer — the barometer measures whatever pressure environment
        // it's physically in, which inside a pressurized aircraft cabin is
        // cabin pressure, not the outside static air the aircraft's own
        // altimeter reads. GPS is satellite-based and unaffected by cabin
        // pressurization, making it the only sensor still meaningful here.
        let newGPSFeet = loc.altitude * CalculationsLogic.metersToFeet
        gpsMSLAltitudeFeet = newGPSFeet
        lastVerticalAccuracy = loc.verticalAccuracy
        // Light smoothing — GPS vertical accuracy is inherently noisier than
        // horizontal (worse satellite geometry on the vertical axis, further
        // degraded by reduced sky visibility inside an aircraft fuselage),
        // so a single fix can swing the displayed altitude by a large
        // amount. This reduces frame-to-frame jitter from transient noise;
        // it won't fully correct a sustained bias from consistently poor
        // vertical geometry, which lastVerticalAccuracy (surfaced in the
        // diagnostic panel) helps distinguish from a software bug.
        userAltitude = isFirstFix ? newGPSFeet : userAltitude + (newGPSFeet - userAltitude) * 0.15

        connectionLogic.updateLocation(loc.coordinate, altitudeFeet: userAltitude)

        // For the HUD speed readout — speed magnitude validity doesn't depend on
        // course accuracy, unlike the dead-reckoning velocity push below.
        if loc.speed >= 0 {
            gpsSpeedKt = loc.speed * 1.944
            lastGPSSpeedKt = gpsSpeedKt
        }
        // Cached for updateHUDLadder() (SceneKit render thread) to read — the
        // GPS-course heading-bias learning below needs the same course/accuracy
        // validity signal already used for the dead-reckoning velocity push.
        lastGPSCourseDeg = loc.course
        lastGPSCourseAccuracy = loc.courseAccuracy

        // Push velocity state immediately (not throttled to the 4 Hz timer) so the
        // 60 Hz dead-reckoning tick has the freshest possible baseline. At 500 kt
        // this eliminates ≈62 m of positional error that accumulates between 4 Hz ticks.
        // courseAccuracy < 30° is a loose guard; the dead-reckoner further requires
        // speed > 5 kt before extrapolating, so no harm if the course is slightly noisy.
        if loc.speed >= 0, loc.courseAccuracy >= 0, loc.courseAccuracy < 30 {
            sceneManager?.updateUserVelocity(
                speedKt:   loc.speed * 1.944,   // m/s → knots
                course:    loc.course,
                location:  loc.coordinate,
                timestamp: loc.timestamp
            )
        }

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

        // Only restart ARKit when on the ground. In flight, compass accuracy commonly
        // degrades due to aircraft magnetic interference and can bounce around the 20°
        // threshold, triggering repeated ARKit world resets that disrupt AR tracking.
        // Since target positions are recalculated every frame from GPS relative to the
        // camera, a session restart doesn't improve accuracy — it only causes disruption.
        if !tcasEnabled
            && lastHeadingAccuracy >= 0
            && lastHeadingAccuracy <= 20
            && accuracy > 20 {
            startARSession()
            presentCalibrationPopupIfNeeded()
        }

        lastHeadingAccuracy = accuracy
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
            arKitNorthCorrectionDeg = isFirstHeadingFix
                ? decl
                : smoothAngle(current: arKitNorthCorrectionDeg, new: decl, alpha: 0.15)
            sceneManager?.arKitNorthCorrectionDeg = arKitNorthCorrectionDeg
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
