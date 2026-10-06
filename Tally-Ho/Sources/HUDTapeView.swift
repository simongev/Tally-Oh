//
//  HUDTapeView.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Vertical scrolling PFD-style tape for speed and altitude.
//

import UIKit

/// Vertical scrolling PFD/HUD-style tape (speed or altitude): a scale of tick
/// marks and numbers that shifts as the value changes, with a bold current-value
/// readout box fixed at the vertical center. `isLeftTape` mirrors the layout so
/// the scale reads outward from the tape toward its own screen edge and the
/// numbers sit inward, near the tape's inner (screen-center-facing) edge —
/// matching the airspeed-left/altitude-right convention of real HUDs.
final class HUDTapeView: UIView {

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
    /// The value eased toward each new reading, frame by frame (#15).
    private var easing: TapeEasing
    /// What the scale and readout were last drawn for, so a frame that would draw the same picture
    /// draws nothing.
    private var drawnValue: Double?
    /// Fixed width for the scale's numbers, wide enough for the longest, so nothing is measured per
    /// redraw.
    private static let tickLabelWidth: CGFloat = 40

    init(unit: String, tickSpacing: Double, labelEvery: Double, range: Double, isLeftTape: Bool) {
        self.tickSpacing = tickSpacing
        self.labelEvery = labelEvery
        self.range = range
        self.isLeftTape = isLeftTape
        self.easing = TapeEasing(timeConstant: 0.25, snapDistance: range,
                                 settleEpsilon: tickSpacing * 0.005)
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
        rebuild(force: true)
    }

    /// Show `value` at once, with no easing.
    func setValue(_ value: Double) {
        easing.snap(to: value)
        currentValue = value
        rebuild()
    }

    /// A new reading to ease toward. Returns whether the tape now needs frames to get there.
    @discardableResult
    func setTarget(_ value: Double) -> Bool {
        easing.setTarget(value)
        if let shown = easing.value, shown != currentValue {
            currentValue = shown
            rebuild()
        }
        return !easing.isSettled
    }

    /// One display frame: move toward the target and redraw if the picture changed. Returns whether
    /// the tape still has somewhere to go.
    func step(dt: TimeInterval) -> Bool {
        guard let shown = easing.step(dt: dt) else { return false }
        currentValue = shown
        rebuild()
        return !easing.isSettled
    }

    func setBrightness(_ b: HUDBrightness) {
        let color = HUDOverlayView.hudGreen.withAlphaComponent(b.alpha)
        ticksLayer.strokeColor = color.cgColor
        valueLabel.textColor = color
        unitLabel.textColor = color
        for lbl in tickLabels { lbl.textColor = color }
        centerBox.backgroundColor = UIColor.black.withAlphaComponent(0.25 * Double(b.alpha) / 0.7)
        rebuild(force: true)
    }

    /// Redraw the tick marks/numbers and the center readout for `currentValue` — unless the picture
    /// would not change (`TapeEasing.needsRedraw`), which while easing is most frames' answer for
    /// the readout and, once settled, every frame's.
    private func rebuild(force: Bool = false) {
        guard bounds.height > 0 else { return }
        let pxPerUnit = CGFloat(bounds.height / 2) / CGFloat(range)
        guard force || TapeEasing.needsRedraw(drawn: drawnValue, value: currentValue,
                                              pxPerUnit: Double(pxPerUnit)) else { return }
        drawnValue = currentValue
        let readout = String(format: "%.0f", currentValue)
        if valueLabel.text != readout { valueLabel.text = readout }

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
                let text = String(format: "%.0f", tickValue)
                if lbl.text != text { lbl.text = text }
                // Fixed width, aligned toward the tick: no text measurement per redraw (#15).
                let width = HUDTapeView.tickLabelWidth
                let labelX = isLeftTape ? anchorX + dir * tickLen - 4 - width : anchorX + dir * tickLen + 4
                lbl.frame = CGRect(x: labelX, y: y - 7, width: width, height: 14)
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

/// How a tape moves toward a new reading (#15).
///
/// The readings arrive at the 4 Hz status cadence, and a tape that jumped on each one read as a
/// stutter. So the shown value eases toward the latest reading every display frame, exponentially,
/// with a time constant independent of the frame rate; a jump larger than the tape's half-range (a
/// source switch, a first reading) snaps instead of scrolling through numbers that were never true.
/// Pure, so the rule is tested.
struct TapeEasing {
    let timeConstant: TimeInterval
    let snapDistance: Double
    /// Within this of the target the shown value is the target, and the tape stops moving.
    let settleEpsilon: Double

    private(set) var value: Double?
    private(set) var target: Double?

    init(timeConstant: TimeInterval = 0.25, snapDistance: Double, settleEpsilon: Double) {
        self.timeConstant = timeConstant
        self.snapDistance = snapDistance
        self.settleEpsilon = settleEpsilon
    }

    var isSettled: Bool { value != nil && value == target }

    mutating func setTarget(_ newTarget: Double) {
        guard newTarget.isFinite else { return }
        target = newTarget
        if let shown = value, abs(newTarget - shown) <= snapDistance { return }
        value = newTarget
    }

    mutating func snap(to newValue: Double) {
        guard newValue.isFinite else { return }
        target = newValue
        value = newValue
    }

    /// Advance by `dt` seconds of display time. Returns the value to show, nil before any reading.
    mutating func step(dt: TimeInterval) -> Double? {
        guard let target, var shown = value else { return value }
        let elapsed = max(0, min(dt, 0.25))
        let fraction = timeConstant > 0 ? 1 - exp(-elapsed / timeConstant) : 1
        shown += (target - shown) * fraction
        if abs(target - shown) <= settleEpsilon { shown = target }
        value = shown
        return shown
    }

    /// Whether a tape drawn for `drawn` must be redrawn to show `value`: its scale would move at least
    /// `minPixels` on screen, or the readout's whole number changes.
    static func needsRedraw(drawn: Double?, value: Double, pxPerUnit: Double,
                            minPixels: Double = 0.25) -> Bool {
        guard let drawn else { return true }
        if drawn.rounded() != value.rounded() { return true }
        return abs(value - drawn) * pxPerUnit >= minPixels
    }
}

private extension Double {
    /// Rounds down to the nearest multiple of `step`.
    func rounded(toNearest step: Double) -> Double {
        (self / step).rounded(.down) * step
    }
}
