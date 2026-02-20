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

    /// Always from iPhone CLLocationManager — primary positioning source.
    private var userLocation: CLLocationCoordinate2D?
    /// Altitude from iPhone barometer/GPS (meters, converted to feet).
    private var userAltitude: Double = 0
    /// Heading from iPhone compass.
    private var userHeading: Double = 0
    /// Last heading accuracy reading from CLLocationManager (-1 = unknown).
    private var lastHeadingAccuracy: CLLocationDirectionAccuracy = -1

    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Last position used to centre the 200 NM airport pre-filter.
    private var lastAirportFilterLocation: CLLocationCoordinate2D?

    /// Current target selection state.
    private var selectionState: SelectionState = .none

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

        // Load persisted settings before starting
        if let saved = ARVisualizationSettings.load() {
            sceneManager?.settings = saved
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
            lines.append(String(format: "📍 %.4f°  %.4f°  (\(gpsSource))", loc.latitude, loc.longitude))
            // Show compass heading with live accuracy indicator
            let accStr: String
            if lastHeadingAccuracy < 0 {
                accStr = "?"
            } else if lastHeadingAccuracy > 20 {
                accStr = "⚠️calibrate"
            } else {
                accStr = String(format: "±%.0f°", lastHeadingAccuracy)
            }
            lines.append(String(format: "✈️ %.0f ft MSL   🧭 %.0f° (\(accStr))", displayAlt, userHeading))
        } else {
            lines.append("📍 GPS: Acquiring…")
        }

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
        userLocation = loc.coordinate
        userAltitude = loc.altitude * CalculationsLogic.metersToFeet
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
        }

        lastHeadingAccuracy = accuracy
        userHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
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
