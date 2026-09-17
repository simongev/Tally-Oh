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
