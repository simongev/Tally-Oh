//
//  MapViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  2D top-down traffic map showing aircraft and airports around the user.
//  • Obeys the same show/hide and type filters set in the AR settings.
//  • Shows ALL aircraft/airports within the map's own range (not the AR distance cap).
//  • Default range 30 NM; the user's last chosen range is persisted across sessions.
//  • Updates live at 1 Hz via a dataProvider closure supplied by ARTrafficViewController.
//  • Tap an aircraft or airport to dismiss the map and select it in the AR view.
//

import UIKit
import CoreLocation

// MARK: - Map Canvas View

private final class MapCanvasView: UIView {

    // Data (refreshed every live-update tick)
    var userLocation: CLLocationCoordinate2D = CLLocationCoordinate2D()
    var userHeading: Double = 0
    var aircraft: [Aircraft] = []
    var airports: [Airport] = []
    var rangeNM: Double = 30
    var settings: ARVisualizationSettings = ARVisualizationSettings()

    // Drawing constants
    private let ringColor        = UIColor.white.withAlphaComponent(0.18)
    private let ringLabelColor   = UIColor.white.withAlphaComponent(0.55)
    private let aircraftColor    = UIColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)
    private let airportColor     = UIColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1)
    private let ownColor         = UIColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1)
    private let gridFont         = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    private let labelFont        = UIFont.boldSystemFont(ofSize: 10)

    // Hit-test data — populated on every draw pass so tap detection is always current
    private(set) var drawnAircraftHits: [(id: String, point: CGPoint)] = []
    private(set) var drawnAirportHits:  [(icao: String, point: CGPoint)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.06, alpha: 1)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Coordinate mapping

    /// Convert a geographic coordinate to a canvas point (user at centre, north up).
    private func canvasPoint(for coord: CLLocationCoordinate2D, in rect: CGRect) -> CGPoint {
        let cx = rect.midX
        let cy = rect.midY
        let pxPerNM = mapPixelsPerNM(in: rect)

        let distM  = CalculationsLogic.distance(from: userLocation, to: coord)
        let distNM = distM / CalculationsLogic.nauticalMileToMeters

        let bearing    = CalculationsLogic.bearing(from: userLocation, to: coord)
        let bearingRad = bearing * .pi / 180.0

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

        let cx     = rect.midX
        let cy     = rect.midY
        let pxPerNM = mapPixelsPerNM(in: rect)
        let ringStep: Double = 10

        // Reset hit data for this frame
        drawnAircraftHits = []
        drawnAirportHits  = []

        // --- Distance rings ---
        ctx.setStrokeColor(ringColor.cgColor)
        ctx.setLineWidth(1.0)
        var nm = ringStep
        while nm <= rangeNM {
            let r = CGFloat(nm) * pxPerNM
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

            let label = "\(Int(nm)) NM"
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

        // --- Airports (respects show/hide and size-category filters; ignores AR distance cap) ---
        if settings.showAirports {
            for ap in airports {
                guard settings.shouldShow(airportType: ap.type) else { continue }
                let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: ap.coordinate)
                guard distNM <= rangeNM else { continue }

                let pt = canvasPoint(for: ap.coordinate, in: rect)
                drawAirportSymbol(ctx: ctx, at: pt, color: airportColor)
                drawnAirportHits.append((icao: ap.icao, point: pt))

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: labelFont,
                    .foregroundColor: airportColor
                ]
                (ap.icao as NSString).draw(at: CGPoint(x: pt.x + 8, y: pt.y - 6), withAttributes: attrs)
            }
        }

        // --- Aircraft (respects show/hide and callsign filter; ignores AR distance cap) ---
        if settings.showAircraft {
            for ac in aircraft {
                guard settings.passes(callsign: ac.callsign) else { continue }
                if !settings.showGroundAircraft && ac.altitude <= 50 { continue }
                let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: ac.coordinate)
                guard distNM <= rangeNM else { continue }

                let pt = canvasPoint(for: ac.coordinate, in: rect)
                drawAircraftSymbol(ctx: ctx, at: pt, heading: ac.track, color: aircraftColor)
                drawnAircraftHits.append((id: ac.id, point: pt))

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: labelFont,
                    .foregroundColor: aircraftColor
                ]
                let label = "\(ac.callsign)\n\(Int(ac.altitude)) ft"
                (label as NSString).draw(
                    at: CGPoint(x: pt.x + 9, y: pt.y - 7),
                    withAttributes: attrs)
            }
        }

        // --- User symbol ---
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

    // MARK: - Symbol helpers

    private func drawAircraftSymbol(ctx: CGContext, at pt: CGPoint, heading: Double, color: UIColor) {
        let r: CGFloat = 5
        ctx.saveGState()
        ctx.translateBy(x: pt.x, y: pt.y)
        ctx.rotate(by: CGFloat(heading) * .pi / 180.0)

        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))

        ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: .zero)
        ctx.addLine(to: CGPoint(x: 0, y: -14))
        ctx.strokePath()

        ctx.restoreGState()
    }

    private func drawAirportSymbol(ctx: CGContext, at pt: CGPoint, color: UIColor) {
        let r: CGFloat = 5
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

        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: -r))
        path.addLine(to: CGPoint(x: r * 0.6, y: r * 0.7))
        path.addLine(to: CGPoint(x: 0, y: r * 0.3))
        path.addLine(to: CGPoint(x: -r * 0.6, y: r * 0.7))
        path.close()

        ctx.setFillColor(ownColor.cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()

        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path.cgPath)
        ctx.strokePath()

        ctx.restoreGState()
    }
}

// MARK: - MapViewController

class MapViewController: UIViewController {

    // MARK: - Data

    private var userLocation: CLLocationCoordinate2D
    private var userHeading: Double
    private var aircraft: [Aircraft]
    private var airports: [Airport]
    private var settings: ARVisualizationSettings

    // MARK: - Callbacks

    /// Returns a fresh snapshot of all live data; called every 1 s by the update timer.
    var dataProvider: (() -> (aircraft: [Aircraft], airports: [Airport],
                              location: CLLocationCoordinate2D, heading: Double)?)?

    /// Called with "aircraft_<id>" or "airport_<icao>" when the user taps an item.
    /// The map is dismissed immediately afterward.
    var onSelect: ((String) -> Void)?

    // MARK: - Range

    private static let rangeDefaultsKey = "MapViewRangeNM"

    /// Current map radius in NM.  Default 30 NM; persisted in UserDefaults.
    private var currentRangeNM: Double = 30

    // MARK: - UI

    private var canvasView: MapCanvasView!
    private var rangeLabel: UILabel!
    private var decreaseButton: UIButton!
    private var increaseButton: UIButton!

    // MARK: - Timer

    private var updateTimer: Timer?

    // MARK: - Init

    init(
        userLocation: CLLocationCoordinate2D,
        userHeading: Double,
        aircraft: [Aircraft],
        airports: [Airport],
        settings: ARVisualizationSettings
    ) {
        self.userLocation = userLocation
        self.userHeading  = userHeading
        self.aircraft     = aircraft
        self.airports     = airports
        self.settings     = settings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Traffic Map"
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(dismissMap))

        // Restore persisted range; fall back to 30 NM
        let saved = UserDefaults.standard.double(forKey: Self.rangeDefaultsKey)
        if saved >= 10 && saved <= 50 { currentRangeNM = saved }

        setupCanvas()
        setupControls()
        setupGestures()
        refreshMap()

        // Live updates at 1 Hz
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pullLiveData()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Live Data

    private func pullLiveData() {
        guard let data = dataProvider?() else { return }
        userLocation = data.location
        userHeading  = data.heading
        aircraft     = data.aircraft
        airports     = data.airports
        refreshMap()
    }

    // MARK: - Canvas

    private func setupCanvas() {
        canvasView = MapCanvasView()
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60)
        ])
    }

    // MARK: - Controls

    private func setupControls() {
        let controlBar = UIView()
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBar.backgroundColor = UIColor(white: 0.1, alpha: 1)
        view.addSubview(controlBar)

        NSLayoutConstraint.activate([
            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: 60)
        ])

        decreaseButton = makeRoundButton(symbol: "minus.circle.fill")
        decreaseButton.addTarget(self, action: #selector(increaseRange), for: .touchUpInside)

        rangeLabel = UILabel()
        rangeLabel.translatesAutoresizingMaskIntoConstraints = false
        rangeLabel.textColor = .white
        rangeLabel.font = UIFont.boldSystemFont(ofSize: 17)
        rangeLabel.textAlignment = .center

        increaseButton = makeRoundButton(symbol: "plus.circle.fill")
        increaseButton.addTarget(self, action: #selector(decreaseRange), for: .touchUpInside)

        controlBar.addSubview(decreaseButton)
        controlBar.addSubview(rangeLabel)
        controlBar.addSubview(increaseButton)

        NSLayoutConstraint.activate([
            decreaseButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
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

    // MARK: - Gestures

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleMapTap(_:)))
        canvasView.addGestureRecognizer(tap)
    }

    /// Hit-test a tap on the canvas.  Picks the closest aircraft or airport within 22 pt,
    /// calls onSelect, then dismisses the map so the AR view becomes active with that item selected.
    @objc private func handleMapTap(_ gesture: UITapGestureRecognizer) {
        let point     = gesture.location(in: canvasView)
        let hitRadius: CGFloat = 22

        var bestAC: (id: String,   dist: CGFloat)?
        for hit in canvasView.drawnAircraftHits {
            let dx = hit.point.x - point.x
            let dy = hit.point.y - point.y
            let d  = sqrt(dx * dx + dy * dy)
            if d <= hitRadius, bestAC == nil || d < bestAC!.dist {
                bestAC = (id: hit.id, dist: d)
            }
        }

        var bestAP: (icao: String, dist: CGFloat)?
        for hit in canvasView.drawnAirportHits {
            let dx = hit.point.x - point.x
            let dy = hit.point.y - point.y
            let d  = sqrt(dx * dx + dy * dy)
            if d <= hitRadius, bestAP == nil || d < bestAP!.dist {
                bestAP = (icao: hit.icao, dist: d)
            }
        }

        // Pick whichever hit is closer to the tap
        let nodeID: String?
        if let ac = bestAC, let ap = bestAP {
            nodeID = ac.dist < ap.dist ? "aircraft_\(ac.id)" : "airport_\(ap.icao)"
        } else if let ac = bestAC {
            nodeID = "aircraft_\(ac.id)"
        } else if let ap = bestAP {
            nodeID = "airport_\(ap.icao)"
        } else {
            nodeID = nil
        }

        guard let nid = nodeID else { return }
        onSelect?(nid)
        dismiss(animated: true)
    }

    // MARK: - Refresh

    private func refreshMap() {
        canvasView.userLocation = userLocation
        canvasView.userHeading  = userHeading
        canvasView.aircraft     = aircraft
        canvasView.airports     = airports
        canvasView.rangeNM      = currentRangeNM
        canvasView.settings     = settings
        canvasView.setNeedsDisplay()

        rangeLabel.text = "\(Int(currentRangeNM)) NM"
        decreaseButton.alpha = currentRangeNM >= 50 ? 0.35 : 1.0
        increaseButton.alpha = currentRangeNM <= 10 ? 0.35 : 1.0
    }

    // MARK: - Range buttons

    @objc private func decreaseRange() {
        guard currentRangeNM > 10 else { return }
        currentRangeNM = max(10, currentRangeNM - 10)
        UserDefaults.standard.set(currentRangeNM, forKey: Self.rangeDefaultsKey)
        refreshMap()
    }

    @objc private func increaseRange() {
        guard currentRangeNM < 50 else { return }
        currentRangeNM = min(50, currentRangeNM + 10)
        UserDefaults.standard.set(currentRangeNM, forKey: Self.rangeDefaultsKey)
        refreshMap()
    }

    @objc private func dismissMap() {
        dismiss(animated: true)
    }
}

