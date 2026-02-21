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

/// Full-screen transparent overlay that draws a single directional chevron
/// at the screen edge when the selected target is outside the camera FOV.
private final class OffScreenArrowView: UIView {

    private var arrowAngle: CGFloat = 0      // radians: 0 = pointing up, clockwise +
    private var arrowCenter: CGPoint = .zero
    private var isVisible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        setNeedsDisplay()
    }

    func show(angle: CGFloat, center: CGPoint) {
        arrowAngle  = angle
        arrowCenter = center
        isVisible   = true
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard isVisible else { return }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let size: CGFloat  = 48
        let half           = size / 2
        let cornerRadius: CGFloat = 10
        let bgRect = CGRect(x: arrowCenter.x - half,
                            y: arrowCenter.y - half,
                            width: size, height: size)

        // Background rounded rect
        ctx.saveGState()
        let path = UIBezierPath(roundedRect: bgRect, cornerRadius: cornerRadius)
        UIColor.black.withAlphaComponent(0.65).setFill()
        path.fill()
        ctx.restoreGState()

        // Chevron: two lines forming a "^" shape, rotated to `arrowAngle`
        ctx.saveGState()
        ctx.translateBy(x: arrowCenter.x, y: arrowCenter.y)
        ctx.rotate(by: arrowAngle)

        let armLen: CGFloat = 10
        let tipY: CGFloat   = -11   // tip of chevron (pointing up before rotation)
        let baseY: CGFloat  =   5

        ctx.setStrokeColor(UIColor.white.cgColor)
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

// MARK: - ARTrafficViewController

class ARTrafficViewController: UIViewController {

    // MARK: - UI

    private var arSceneView: ARSCNView!
    private var statusLabel: UILabel!
    private var settingsButton: UIButton!
    private var backButton: UIButton!
    private var offScreenArrowView: OffScreenArrowView!

    // Dynamic leading constraints on statusLabel (swapped when selection active)
    private var statusLeadingToEdge: NSLayoutConstraint!
    private var statusLeadingToBack: NSLayoutConstraint!

    // MARK: - Core

    private var connectionLogic = ConnectionLogic()
    private var sceneManager: ARSceneManager?
    private var locationManager = CLLocationManager()

    // MARK: - State

    private var airports: [Airport] = []

    /// Seed location passed from CalibrationViewController (may be nil if skipped).
    var seedLocation: CLLocation?

    /// Always from iPhone CLLocationManager — primary positioning source.
    private var userLocation: CLLocationCoordinate2D?
    /// Best horizontal accuracy seen in the current flight session (metres). -1 = unknown.
    private var bestHorizontalAccuracy: CLLocationAccuracy = -1
    /// Last raw GPS horizontal accuracy for HUD display.
    private var lastHorizontalAccuracy: CLLocationAccuracy = -1
    /// Altitude from CMAltimeter (barometric, relative) + GPS MSL baseline, in feet.
    private var userAltitude: Double = 0
    /// GPS MSL altitude in feet — used as baseline for barometric correction.
    private var gpsMSLAltitudeFeet: Double = 0
    /// Heading from iPhone compass.
    private var userHeading: Double = 0
    /// Last heading accuracy reading from CLLocationManager (-1 = unknown).
    private var lastHeadingAccuracy: CLLocationDirectionAccuracy = -1
    /// ARKit tracking state — used to warn user if tracking degrades.
    private var arTrackingState: ARCamera.TrackingState = .notAvailable

    /// CMAltimeter for barometric relative-altitude measurements.
    private let altimeter = CMAltimeter()
    /// Relative altitude change from altimeter since baseline (metres).
    private var baroRelativeAltitude: Double = 0
    /// Baseline GPS altitude set when altimeter starts (metres MSL).
    private var baroBaselineAltitudeFeet: Double = 0
    /// True once the altimeter has produced its first reading and baseline is set.
    private var baroBaselineSet = false

    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Last position used to centre the 200 NM airport pre-filter.
    private var lastAirportFilterLocation: CLLocationCoordinate2D?

    /// Current target selection state.
    private var selectionState: SelectionState = .none

    /// GPS accuracy threshold — fixes worse than this are discarded.
    private let gpsAccuracyThreshold: CLLocationAccuracy = 30.0

    /// Running correction for the angular drift between the ARKit world-north
    /// (frozen at session.run() time) and the live compass true-north.
    ///
    /// ARKit sets its north once via the compass at session start, then relies
    /// entirely on the gyroscope — so any initial compass error stays fixed for
    /// the whole session. Every time we get a high-quality heading reading we
    /// re-measure the difference between ARKit's yaw and the compass, and store
    /// it here. All bearing calculations add this offset to cancel the drift.
    ///
    /// Value is in degrees; positive = ARKit north is clockwise of true north.
    private var arKitNorthCorrectionDeg: Double = 0

    /// Number of heading samples accumulated for the running correction average.
    private var northCorrectionSampleCount: Int = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true

        setupUI()
        setupARScene()
        setupLocation()
        setupAltimeter()
        setupObservers()
        setupGestures()
        loadAirports()

        // Load persisted settings before starting
        if let saved = ARVisualizationSettings.load() {
            sceneManager?.settings = saved
        }

        // Apply calibration seed location so we have a position immediately
        if let seed = seedLocation {
            userLocation        = seed.coordinate
            gpsMSLAltitudeFeet  = seed.altitude * CalculationsLogic.metersToFeet
            userAltitude        = gpsMSLAltitudeFeet
            baroBaselineAltitudeFeet = gpsMSLAltitudeFeet
            lastHorizontalAccuracy   = seed.horizontalAccuracy
            bestHorizontalAccuracy   = seed.horizontalAccuracy
            connectionLogic.updateLocation(seed.coordinate, altitudeFeet: userAltitude)
        }

        // Begin listening for ADS-B broadcasts in background
        connectionLogic.startListening()

        // Wire deselection callback for when a selected node is removed from the scene
        sceneManager?.onSelectionInvalidated = { [weak self] in
            self?.clearSelection()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startARSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arSceneView.session.pause()
        updateTimer?.invalidate()
        altimeter.stopRelativeAltitudeUpdates()
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

        // Off-screen arrow overlay — sits above arSceneView, below all buttons
        offScreenArrowView = OffScreenArrowView(frame: view.bounds)
        offScreenArrowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(offScreenArrowView)

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
        view.addSubview(statusLabel)

        // Back button — hidden until a target is selected
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

        // statusLabel leading: two variants — default (edge) and with-back-button
        statusLeadingToEdge = statusLabel.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: 12)
        statusLeadingToBack = statusLabel.leadingAnchor.constraint(
            equalTo: backButton.trailingAnchor, constant: 8)
        statusLeadingToEdge.isActive = true   // default

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])

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
        // kCLHeadingFilterNone gives every hardware sample so the system can
        // apply maximum internal smoothing; we filter bad readings ourselves.
        locationManager.headingFilter = kCLHeadingFilterNone
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

        connectionLogic.$detectedAircraft
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusLabel() }
            .store(in: &cancellables)

        // 4 Hz — at 250 kt the user moves ~32 m per second; updating 4x/s keeps
        // target positions smooth enough for comfortable viewing in flight.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateVisualization()
        }
    }

    private func setupAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            let relM = data.relativeAltitude.doubleValue   // metres since altimeter start
            // Set baseline on first reading using GPS MSL
            if !self.baroBaselineSet {
                self.baroBaselineAltitudeFeet = self.gpsMSLAltitudeFeet
                self.baroBaselineSet = true
                self.baroRelativeAltitude = 0
            } else {
                self.baroRelativeAltitude = relM
            }
            // Fused altitude: GPS MSL baseline + barometric delta (barometer is more precise for changes)
            let fusedFeet = self.baroBaselineAltitudeFeet + relM * CalculationsLogic.metersToFeet
            self.userAltitude = fusedFeet
        }
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arSceneView.addGestureRecognizer(tap)
    }

    // MARK: - Airport Loading

    /// Full airport database — loaded once in background, never iterated on main thread.
    private var allAirports: [Airport] = []

    private func loadAirports() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let parsed = AirportDataParser.loadAirportsFromCSV() else { return }
            let loc = DispatchQueue.main.sync { self?.userLocation ?? self?.activeLocation }
            let nearby: [Airport]
            if let loc = loc {
                nearby = CalculationsLogic.filterAirportsInRange(
                    airports: parsed,
                    userCoord: loc,
                    maxRangeNauticalMiles: 200
                )
            } else {
                nearby = []
            }
            DispatchQueue.main.async {
                self?.allAirports = parsed
                self?.airports = nearby
                self?.lastAirportFilterLocation = loc
                self?.updateStatusLabel()
            }
        }
    }

    /// Re-filter allAirports to 200 NM — called when user moves > 50 NM.
    private func refreshNearbyAirports() {
        guard let loc = userLocation ?? activeLocation else { return }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let nearby = CalculationsLogic.filterAirportsInRange(
                airports: self.allAirports,
                userCoord: loc,
                maxRangeNauticalMiles: 200
            )
            DispatchQueue.main.async {
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
        // After a session reset, ARKit re-samples the compass for its new north.
        // Reset the correction so we build a fresh measurement from the new north.
        arKitNorthCorrectionDeg = 0
        northCorrectionSampleCount = 0
        sceneManager?.arKitNorthCorrectionDeg = 0
    }

    // MARK: - Actions

    @objc private func showSettings() {
        guard let settings = sceneManager?.settings else { return }
        let vc = SettingsViewController(settings: settings) { [weak self] updated in
            self?.sceneManager?.settings = updated
            updated.save()
            self?.sceneManager?.clearAll()
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    @objc private func backButtonTapped() {
        clearSelection()
    }

    // MARK: - Hit Testing / Selection

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let touchPoint = gesture.location(in: arSceneView)
        let hits = arSceneView.hitTest(touchPoint, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true
        ])
        if let hit = hits.first, let nid = containerNodeID(for: hit.node) {
            // Tapped a target
            if case .selected(let current) = selectionState, current == nid {
                clearSelection()    // tap same target again = deselect
            } else {
                applySelection(nodeID: nid)
            }
        } else {
            // Tapped empty space
            clearSelection()
        }
    }

    /// Walk the node hierarchy to find the container node's name (e.g. "aircraft_ABC").
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
    }

    private func clearSelection() {
        selectionState = .none
        sceneManager?.setSelection(nodeID: nil)
        offScreenArrowView.hide()
        updateSelectionUI(active: false)
    }

    private func updateSelectionUI(active: Bool) {
        backButton.isHidden = !active
        offScreenArrowView.isHidden = !active
        // Swap statusLabel leading constraint
        statusLeadingToEdge.isActive = !active
        statusLeadingToBack.isActive = active
    }

    // MARK: - Update Loop

    /// The active position source: ADS-B ownship when receiving, otherwise iPhone GPS.
    private var activeLocation: CLLocationCoordinate2D? {
        if connectionLogic.connectionStatus == .receiving,
           let ownship = connectionLogic.ownshipData,
           ownship.latitude != 0 || ownship.longitude != 0 {
            return ownship.coordinate
        }
        return userLocation
    }

    /// Active altitude: ADS-B ownship when receiving, otherwise iPhone barometer.
    private var activeAltitude: Double {
        if connectionLogic.connectionStatus == .receiving,
           let ownship = connectionLogic.ownshipData,
           ownship.altitude > -1000 {
            return ownship.altitude
        }
        return userAltitude
    }

    private var usingADSBGPS: Bool {
        connectionLogic.connectionStatus == .receiving && connectionLogic.ownshipData != nil
    }

    private func updateVisualization() {
        guard let loc = activeLocation else { return }

        let cameraPos: SCNVector3
        if let pov = arSceneView.pointOfView {
            let t = pov.worldTransform
            cameraPos = SCNVector3(t.m41, t.m42, t.m43)
        } else {
            cameraPos = .init()
        }

        sceneManager?.updateAircraft(
            Array(connectionLogic.detectedAircraft.values),
            userLocation: loc,
            userAltitude: activeAltitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraPos
        )
        sceneManager?.updateAirports(
            airports,
            userLocation: loc,
            userAltitude: activeAltitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraPos
        )
        connectionLogic.updateLocation(loc, altitudeFeet: activeAltitude)
        updateStatusLabel()
    }

    // MARK: - Off-Screen Arrow

    /// Projects the selected target onto the screen and, if outside the FOV,
    /// positions the edge arrow. Called from the render thread; dispatches UI
    /// updates to the main thread.
    private func updateOffScreenArrow(for nodeID: String) {
        guard let node = sceneManager?.node(forID: nodeID), !node.isHidden else {
            DispatchQueue.main.async { self.offScreenArrowView.hide() }
            return
        }

        let worldPos  = node.worldPosition
        let projected = arSceneView.projectPoint(worldPos)
        let screenSize = arSceneView.bounds.size   // safe: bounds is read-only from render thread

        let behindCamera = projected.z >= 1.0
        let onScreen = !behindCamera
            && projected.x >= 0 && CGFloat(projected.x) <= screenSize.width
            && projected.y >= 0 && CGFloat(projected.y) <= screenSize.height

        if onScreen {
            DispatchQueue.main.async { self.offScreenArrowView.hide() }
            return
        }

        let (edgePoint, angle) = screenEdgePoint(
            projected: CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
            isBehindCamera: behindCamera,
            screenSize: screenSize,
            margin: 40
        )
        DispatchQueue.main.async { self.offScreenArrowView.show(angle: angle, center: edgePoint) }
    }

    /// Returns the screen-edge intersection point and the rotation angle (radians,
    /// 0 = up, clockwise +) for the arrow chevron.
    private func screenEdgePoint(
        projected: CGPoint,
        isBehindCamera: Bool,
        screenSize: CGSize,
        margin: CGFloat
    ) -> (point: CGPoint, angle: CGFloat) {

        let cx = screenSize.width  / 2
        let cy = screenSize.height / 2

        // When behind the camera the projected x/y are mirrored — flip through centre
        var dir: CGPoint
        if isBehindCamera {
            dir = CGPoint(x: cx - projected.x, y: cy - projected.y)
        } else {
            dir = CGPoint(x: projected.x - cx, y: projected.y - cy)
        }

        // Avoid zero-length vector
        if dir.x == 0 && dir.y == 0 { dir = CGPoint(x: 0, y: -1) }

        // atan2 in screen space (+Y down): angle of the ray from screen centre
        let angle = atan2(dir.y, dir.x)   // right = 0, clockwise in screen coords

        // Find scale factor t so the ray reaches the nearest safe edge
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

        // Convert from atan2 convention (right=0, CCW+) to UIKit rotation
        // (up=0, CW+): rotate 90° clockwise
        let uiAngle = angle + .pi / 2

        return (edgePoint, uiAngle)
    }

    // MARK: - HUD

    private func updateStatusLabel() {
        var lines: [String] = []

        // ADS-B status
        switch connectionLogic.connectionStatus {
        case .receiving:     lines.append("📡 ADS-B: Receiving")
        case .searching:     lines.append("📡 ADS-B: Searching…")
        case .notAvailable:  lines.append("📡 ADS-B: Unavailable")
        case .disconnected:  lines.append("📡 ADS-B: Off")
        }

        lines.append(connectionLogic.isInternetAvailable ? "🌐 Internet: Online" : "🌐 Internet: Offline")

        // GPS position + accuracy
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

            // Altitude + source
            let altSource = baroBaselineSet ? "baro" : "GPS"
            // Compass heading with live accuracy indicator
            let compassAccStr: String
            if lastHeadingAccuracy < 0 {
                compassAccStr = "?"
            } else if lastHeadingAccuracy > 20 {
                compassAccStr = "⚠️calibrate"
            } else {
                compassAccStr = String(format: "±%.0f°", lastHeadingAccuracy)
            }
            let corrStr = northCorrectionSampleCount == 0
                ? "—"
                : String(format: "%+.1f°", arKitNorthCorrectionDeg)
            lines.append(String(format: "✈️ %.0f ft (%@)   🧭 %.0f° (%@)  Δ%@", displayAlt, altSource, userHeading, compassAccStr, corrStr))
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

        // Aircraft count
        let total   = connectionLogic.detectedAircraft.count
        let adsbCnt = connectionLogic.detectedAircraft.values.filter { $0.source == .adsb }.count
        let netCnt  = connectionLogic.internetAircraftCount
        var trafficLine = "🛩 Aircraft: \(total)"
        var parts: [String] = []
        if adsbCnt > 0 { parts.append("ADS-B:\(adsbCnt)") }
        if netCnt  > 0 { parts.append("Net:\(netCnt)") }
        if !parts.isEmpty { trafficLine += " (\(parts.joined(separator: " ")))" }
        lines.append(trafficLine)

        lines.append("🛫 Airports loaded: \(airports.count)")

        statusLabel.text = lines.map { "  \($0)  " }.joined(separator: "\n")
    }
}

// MARK: - ARSCNViewDelegate

extension ARTrafficViewController: ARSCNViewDelegate {

    /// Called every display frame (~60 Hz) on the render thread.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let pov = arSceneView.pointOfView else { return }
        let t = pov.worldTransform
        let cam = SCNVector3(t.m41, t.m42, t.m43)
        sceneManager?.tickAircraftPositions(cameraWorldPosition: cam)

        // Update off-screen arrow for the selected target every frame
        if case .selected(let nodeID) = selectionState {
            updateOffScreenArrow(for: nodeID)
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

        // Reject fixes with poor accuracy or invalid data
        let hAcc = loc.horizontalAccuracy
        guard hAcc > 0 && hAcc <= gpsAccuracyThreshold else {
            // Still update the HUD to show accuracy degradation
            if hAcc > 0 { lastHorizontalAccuracy = hAcc }
            updateStatusLabel()
            return
        }

        lastHorizontalAccuracy = hAcc
        if bestHorizontalAccuracy < 0 || hAcc < bestHorizontalAccuracy {
            bestHorizontalAccuracy = hAcc
        }

        userLocation = loc.coordinate

        // GPS MSL altitude — always update so barometric baseline stays current
        let newGPSFeet = loc.altitude * CalculationsLogic.metersToFeet
        gpsMSLAltitudeFeet = newGPSFeet

        // If altimeter is not running or baseline not set yet, fall back to GPS altitude
        if !baroBaselineSet {
            userAltitude = newGPSFeet
        } else {
            // Drift-correct barometric baseline periodically using GPS MSL
            // (GPS MSL is accurate over long periods; baro is more precise for short-term changes)
            baroBaselineAltitudeFeet = newGPSFeet - baroRelativeAltitude * CalculationsLogic.metersToFeet
        }

        connectionLogic.updateLocation(loc.coordinate, altitudeFeet: userAltitude)

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
        // Discard readings with unknown accuracy
        guard newHeading.headingAccuracy >= 0 else { return }

        let accuracy = newHeading.headingAccuracy

        // If accuracy just crossed from good to bad, reset ARKit so the scene
        // realigns to the corrected compass on the next good reading.
        if lastHeadingAccuracy >= 0
            && lastHeadingAccuracy <= 20
            && accuracy > 20 {
            startARSession()
            // Reset correction — the new session will re-establish its own north.
            arKitNorthCorrectionDeg = 0
            northCorrectionSampleCount = 0
        }

        lastHeadingAccuracy = accuracy
        let trueNorth = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        userHeading = trueNorth

        // --- Compute ARKit north correction ---
        // Only use high-quality readings (accuracy ≤ 10°) to update the correction.
        if accuracy <= 10, let frame = arSceneView.session.currentFrame {
            // ARKit camera yaw in world space (radians). With .gravityAndHeading
            // the world is fixed: yaw = 0 means the camera faces ARKit's north.
            // Negate because ARKit yaw is CCW-positive but compass is CW-positive.
            let arYawDeg = Double(-frame.camera.eulerAngles.y) * 180.0 / .pi

            // The camera's compass direction = trueNorth (where the phone is pointing).
            // ARKit thinks the camera is at `arYawDeg` from its own north.
            // So: arKitNorth = trueNorth - arYawDeg
            var sample = trueNorth - arYawDeg
            // Normalise to [-180, 180]
            while sample >  180 { sample -= 360 }
            while sample < -180 { sample += 360 }

            // Exponential moving average — weight recent readings more heavily.
            // α = 0.15: slow enough to filter noise, fast enough to converge in ~20 readings.
            let alpha = 0.15
            if northCorrectionSampleCount == 0 {
                arKitNorthCorrectionDeg = sample
            } else {
                arKitNorthCorrectionDeg = alpha * sample + (1 - alpha) * arKitNorthCorrectionDeg
            }
            northCorrectionSampleCount += 1

            // Pass the live correction into the scene manager so position ticks use it.
            sceneManager?.arKitNorthCorrectionDeg = arKitNorthCorrectionDeg
        }

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
