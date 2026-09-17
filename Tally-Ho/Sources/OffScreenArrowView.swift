//
//  OffScreenArrowView.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Edge chevrons pointing at off-screen TCAS threats and the selected target.
//

import UIKit

// MARK: - Off-Screen Arrow View

/// Full-screen transparent overlay that draws directional edge chevrons pointing
/// toward off-screen targets (TCAS threats and the user-selected aircraft).
/// On-screen targets do not get an overlay arrow — the colored ring on the AR node
/// is already prominent enough, and removing the orbiting animation saves the
/// CADisplayLink + 60 Hz redraws that were a non-trivial RAM/CPU cost.
final class OffScreenArrowView: UIView {

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
