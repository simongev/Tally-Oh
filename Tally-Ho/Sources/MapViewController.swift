//
//  MapViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  2D top-down traffic map showing aircraft and airports around the user.
//  Distance rings every 10 NM, adjustable range 10–50 NM.
//

import UIKit
import CoreLocation

// MARK: - Map Canvas View

private final class MapCanvasView: UIView {

    // Data
    var userLocation: CLLocationCoordinate2D = CLLocationCoordinate2D()
    var userHeading: Double = 0
    var aircraft: [Aircraft] = []
    var airports: [Airport] = []
    var rangeNM: Double = 50

    // Drawing constants
    private let ringColor        = UIColor.white.withAlphaComponent(0.18)
    private let ringLabelColor   = UIColor.white.withAlphaComponent(0.55)
    private let aircraftColor    = UIColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)
    private let airportColor     = UIColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1)
    private let ownColor         = UIColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1)
    private let gridFont         = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    private let labelFont        = UIFont.boldSystemFont(ofSize: 10)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.06, alpha: 1)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Coordinate mapping

    /// Convert a geographic coordinate to canvas point.
    /// The user is always at the center; north is up.
    private func canvasPoint(for coord: CLLocationCoordinate2D, in rect: CGRect) -> CGPoint {
        let cx = rect.midX
        let cy = rect.midY
        let pxPerNM = mapPixelsPerNM(in: rect)

        let distM = CalculationsLogic.distance(from: userLocation, to: coord)
        let distNM = distM / CalculationsLogic.nauticalMileToMeters

        // Bearing from user to target (0 = north, clockwise)
        let bearing = CalculationsLogic.bearing(from: userLocation, to: coord)
        let bearingRad = bearing * .pi / 180.0

        // North-up: x = east, y = north (inverted for screen)
        let dx = CGFloat(distNM * sin(bearingRad)) * pxPerNM
        let dy = CGFloat(distNM * cos(bearingRad)) * pxPerNM

        return CGPoint(x: cx + dx, y: cy - dy)
    }

    private func mapPixelsPerNM(in rect: CGRect) -> CGFloat {
        let mapDiameter = min(rect.width, rect.height) * 0.88
        return mapDiameter / 2 / CGFloat(rangeNM)
    }

    // MARK: - Draw

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let cx = rect.midX
        let cy = rect.midY
        let pxPerNM = mapPixelsPerNM(in: rect)
        let ringStep: Double = 10

        // --- Distance rings ---
        ctx.setStrokeColor(ringColor.cgColor)
        ctx.setLineWidth(1.0)
        var nm = ringStep
        while nm <= rangeNM {
            let r = CGFloat(nm) * pxPerNM
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

            // Ring label
            let label = nm < 1000 ? "\(Int(nm)) NM" : "\(Int(nm)) NM"
            let attrs: [NSAttributedString.Key: Any] = [.font: gridFont, .foregroundColor: ringLabelColor]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: CGPoint(x: cx - size.width / 2, y: cy - r - size.height - 1),
                withAttributes: attrs)
            nm += ringStep
        }

        // --- North indicator line ---
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy - CGFloat(rangeNM) * pxPerNM))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // --- Airports ---
        for ap in airports {
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: ap.coordinate)
            guard distNM <= rangeNM else { continue }

            let pt = canvasPoint(for: ap.coordinate, in: rect)
            drawAirportSymbol(ctx: ctx, at: pt, color: airportColor)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: airportColor
            ]
            (ap.icao as NSString).draw(at: CGPoint(x: pt.x + 8, y: pt.y - 6), withAttributes: attrs)
        }

        // --- Aircraft ---
        for ac in aircraft {
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: ac.coordinate)
            guard distNM <= rangeNM else { continue }

            let pt = canvasPoint(for: ac.coordinate, in: rect)
            drawAircraftSymbol(ctx: ctx, at: pt, heading: ac.track, color: aircraftColor)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: aircraftColor
            ]
            let label = "\(ac.callsign)\n\(Int(ac.altitude)) ft"
            (label as NSString).draw(
                at: CGPoint(x: pt.x + 9, y: pt.y - 7),
                withAttributes: attrs)
        }

        // --- User dot ---
        drawUserSymbol(ctx: ctx, at: CGPoint(x: cx, y: cy), heading: userHeading)

        // --- "N" label at top ---
        let northAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 12),
            .foregroundColor: UIColor.white.withAlphaComponent(0.7)
        ]
        let nSize = ("N" as NSString).size(withAttributes: northAttrs)
        ("N" as NSString).draw(
            at: CGPoint(x: cx - nSize.width / 2, y: rect.minY + 6),
            withAttributes: northAttrs)
    }

    private func drawAircraftSymbol(ctx: CGContext, at pt: CGPoint, heading: Double, color: UIColor) {
        let r: CGFloat = 5
        ctx.saveGState()
        ctx.translateBy(x: pt.x, y: pt.y)
        ctx.rotate(by: CGFloat(heading) * .pi / 180.0)

        // Dot
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))

        // Track vector
        ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: .zero)
        ctx.addLine(to: CGPoint(x: 0, y: -14))
        ctx.strokePath()

        ctx.restoreGState()
    }

    private func drawAirportSymbol(ctx: CGContext, at pt: CGPoint, color: UIColor) {
        let r: CGFloat = 5
        // Circle with crosshairs
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
        ctx.move(to: CGPoint(x: pt.x - r * 1.3, y: pt.y))
        ctx.addLine(to: CGPoint(x: pt.x + r * 1.3, y: pt.y))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: pt.x, y: pt.y - r * 1.3))
        ctx.addLine(to: CGPoint(x: pt.x, y: pt.y + r * 1.3))
        ctx.strokePath()
    }

    private func drawUserSymbol(ctx: CGContext, at pt: CGPoint, heading: Double) {
        let r: CGFloat = 7
        ctx.saveGState()
        ctx.translateBy(x: pt.x, y: pt.y)
        ctx.rotate(by: CGFloat(heading) * .pi / 180.0)

        // Airplane silhouette (simple triangle)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: -r))
        path.addLine(to: CGPoint(x: r * 0.6, y: r * 0.7))
        path.addLine(to: CGPoint(x: 0, y: r * 0.3))
        path.addLine(to: CGPoint(x: -r * 0.6, y: r * 0.7))
        path.close()

        ctx.setFillColor(ownColor.cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()

        // White outline
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path.cgPath)
        ctx.strokePath()

        ctx.restoreGState()
    }
}

// MARK: - MapViewController

class MapViewController: UIViewController {

    // Input data
    private let userLocation: CLLocationCoordinate2D
    private let userHeading: Double
    private let aircraft: [Aircraft]
    private let airports: [Airport]

    private var currentRangeNM: Double = 50

    private var canvasView: MapCanvasView!
    private var rangeLabel: UILabel!
    private var decreaseButton: UIButton!
    private var increaseButton: UIButton!
    private var scaleBarView: ScaleBarView!

    init(
        userLocation: CLLocationCoordinate2D,
        userHeading: Double,
        aircraft: [Aircraft],
        airports: [Airport]
    ) {
        self.userLocation = userLocation
        self.userHeading  = userHeading
        self.aircraft     = aircraft
        self.airports     = airports
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Traffic Map"
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(dismissMap))

        setupCanvas()
        setupControls()
        refreshMap()
    }

    private func setupCanvas() {
        canvasView = MapCanvasView()
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -88)
        ])
    }

    private func setupControls() {
        // Bottom control bar background
        let controlBar = UIView()
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.backgroundColor = UIColor(white: 0.1, alpha: 1)
        view.addSubview(controlBar)

        NSLayoutConstraint.activate([
            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: 88)
        ])

        // Range decrease button
        decreaseButton = makeRoundButton(symbol: "minus.circle.fill")
        decreaseButton.addTarget(self, action: #selector(decreaseRange), for: .touchUpInside)

        // Range label
        rangeLabel = UILabel()
        rangeLabel.translatesAutoresizingMaskIntoConstraints = false
        rangeLabel.textColor = .white
        rangeLabel.font = UIFont.boldSystemFont(ofSize: 17)
        rangeLabel.textAlignment = .center

        // Range increase button
        increaseButton = makeRoundButton(symbol: "plus.circle.fill")
        increaseButton.addTarget(self, action: #selector(increaseRange), for: .touchUpInside)

        // Scale bar
        scaleBarView = ScaleBarView()
        scaleBarView.translatesAutoresizingMaskIntoConstraints = false

        controlBar.addSubview(decreaseButton)
        controlBar.addSubview(rangeLabel)
        controlBar.addSubview(increaseButton)
        controlBar.addSubview(scaleBarView)

        NSLayoutConstraint.activate([
            // Center row: − [range label] +
            decreaseButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor, constant: -10),
            decreaseButton.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 24),
            decreaseButton.widthAnchor.constraint(equalToConstant: 44),
            decreaseButton.heightAnchor.constraint(equalToConstant: 44),

            rangeLabel.centerYAnchor.constraint(equalTo: decreaseButton.centerYAnchor),
            rangeLabel.centerXAnchor.constraint(equalTo: controlBar.centerXAnchor),
            rangeLabel.widthAnchor.constraint(equalToConstant: 120),

            increaseButton.centerYAnchor.constraint(equalTo: decreaseButton.centerYAnchor),
            increaseButton.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -24),
            increaseButton.widthAnchor.constraint(equalToConstant: 44),
            increaseButton.heightAnchor.constraint(equalToConstant: 44),

            // Scale bar below
            scaleBarView.topAnchor.constraint(equalTo: decreaseButton.bottomAnchor, constant: 6),
            scaleBarView.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 24),
            scaleBarView.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -24),
            scaleBarView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func makeRoundButton(symbol: String) -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
        btn.tintColor = .white
        return btn
    }

    private func refreshMap() {
        canvasView.userLocation = userLocation
        canvasView.userHeading  = userHeading
        canvasView.aircraft     = aircraft
        canvasView.airports     = airports
        canvasView.rangeNM      = currentRangeNM
        canvasView.setNeedsDisplay()

        rangeLabel.text = "\(Int(currentRangeNM)) NM"
        decreaseButton.alpha = currentRangeNM <= 10 ? 0.35 : 1.0
        increaseButton.alpha = currentRangeNM >= 50 ? 0.35 : 1.0

        // Update scale bar: show width that represents the full range
        scaleBarView.rangeNM = currentRangeNM
    }

    @objc private func decreaseRange() {
        guard currentRangeNM > 10 else { return }
        currentRangeNM = max(10, currentRangeNM - 10)
        refreshMap()
    }

    @objc private func increaseRange() {
        guard currentRangeNM < 50 else { return }
        currentRangeNM = min(50, currentRangeNM + 10)
        refreshMap()
    }

    @objc private func dismissMap() {
        dismiss(animated: true)
    }
}

// MARK: - Scale Bar View

private final class ScaleBarView: UIView {

    var rangeNM: Double = 50 {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // The scale bar represents half the range (a meaningful segment)
        let scaleValueNM = Int(rangeNM / 2)
        let barWidth = rect.width * 0.6    // 60% of available width
        let barHeight: CGFloat = 4
        let barY = rect.midY - barHeight / 2
        let barX = (rect.width - barWidth) / 2

        // Bar
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        ctx.fill(CGRect(x: barX, y: barY, width: barWidth, height: barHeight))

        // End ticks
        ctx.fill(CGRect(x: barX, y: barY - 4, width: 2, height: barHeight + 8))
        ctx.fill(CGRect(x: barX + barWidth - 2, y: barY - 4, width: 2, height: barHeight + 8))

        // Label
        let label = "\(scaleValueNM) NM"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.8)
        ]
        let labelSize = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(
            at: CGPoint(x: rect.midX - labelSize.width / 2, y: barY - labelSize.height - 2),
            withAttributes: attrs)
    }
}
