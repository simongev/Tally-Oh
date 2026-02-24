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

/// Full-screen transparent overlay that draws directional chevrons at the
/// screen edge for the selected target and/or TCAS threat aircraft.
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

    func show(angle: CGFloat, center: CGPoint) {
        selectionArrow = ArrowEntry(angle: angle, center: center, color: .white)
        setNeedsDisplay()
    }

    // MARK: TCAS arrows

    func setTCASArrows(_ arrows: [(angle: CGFloat, center: CGPoint, color: UIColor)]) {
        tcasArrows = arrows.map { ArrowEntry(angle: $0.angle, center: $0.center, color: $0.color) }
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
        for entry in all { drawArrow(ctx: ctx, entry: entry) }
    }

    private func drawArrow(ctx: CGContext, entry: ArrowEntry) {
        let size: CGFloat     = 48
        let half              = size / 2
        let cornerRadius: CGFloat = 10
        let bgRect = CGRect(x: entry.center.x - half,
                            y: entry.center.y - half,
                            width: size, height: size)

        ctx.saveGState()
        let path = UIBezierPath(roundedRect: bgRect, cornerRadius: cornerRadius)
        UIColor.black.withAlphaComponent(0.65).setFill()
        path.fill()
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

// MARK: - ARTrafficViewController

class ARTrafficViewController: UIViewController {

    // MARK: - UI

    private var arSceneView: ARSCNView!
    private var statusLabel: UILabel!
    private var settingsButton: UIButton!
    private var mapButton: UIButton!
    private var backButton: UIButton!
    private var offScreenArrowView: OffScreenArrowView!

    // Dynamic leading constraints on statusLabel
    private var statusLeadingToEdge: NSLayoutConstraint!
    private var statusLeadingToBack: NSLayoutConstraint!

    /// Full-screen border overlay driven by TCAS alerts.
    private var tcasOverlayView: UIView!
    private var tcasFlashTimer: Timer?
    private var tcasFlashState: Bool = false

    // MARK: - METAR Panel

    private var metarPanelView: UIView!
    private var metarLabel: UILabel!
    private var metarCloseButton: UIButton!
    private var metarSelectedICAO: String?
    private var metarFetchTask: URLSessionDataTask?

    // MARK: - Core

    private var connectionLogic = ConnectionLogic()
    private var sceneManager: ARSceneManager?
    private var locationManager = CLLocationManager()

    // MARK: - State

    private var airports: [Airport] = []
    private var currentTCASEvaluation: TCASEvaluation = .clear

    var seedLocation: CLLocation?

    private var userLocation: CLLocationCoordinate2D?
    private var bestHorizontalAccuracy: CLLocationAccuracy = -1
    private var lastHorizontalAccuracy: CLLocationAccuracy = -1
    private var userAltitude: Double = 0
    private var gpsMSLAltitudeFeet: Double = 0
    private var userHeading: Double = 0
    private var lastHeadingAccuracy: CLLocationDirectionAccuracy = -1
    private var arTrackingState: ARCamera.TrackingState = .notAvailable

    private let altimeter = CMAltimeter()
    private var baroRelativeAltitude: Double = 0
    private var baroBaselineAltitudeFeet: Double = 0
    private var baroBaselineSet = false

    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var lastAirportFilterLocation: CLLocationCoordinate2D?
    private var selectionState: SelectionState = .none
    private let gpsAccuracyThreshold: CLLocationAccuracy = 30.0

    private var arKitNorthCorrectionDeg: Double = 0
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

        if let saved = ARVisualizationSettings.load() {
            sceneManager?.settings = saved
        }

        if let seed = seedLocation {
            userLocation        = seed.coordinate
            gpsMSLAltitudeFeet  = seed.altitude * CalculationsLogic.metersToFeet
            userAltitude        = gpsMSLAltitudeFeet
            baroBaselineAltitudeFeet = gpsMSLAltitudeFeet
            lastHorizontalAccuracy   = seed.horizontalAccuracy
            bestHorizontalAccuracy   = seed.horizontalAccuracy
            connectionLogic.updateLocation(seed.coordinate, altitudeFeet: userAltitude)
        }

        connectionLogic.startListening()

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
        stopTCASFlash()
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

        NSLayoutConstraint.activate([
            metarPanelView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            metarPanelView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            metarPanelView.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -12),

            metarCloseButton.topAnchor.constraint(equalTo: metarPanelView.topAnchor, constant: 8),
            metarCloseButton.trailingAnchor.constraint(equalTo: metarPanelView.trailingAnchor, constant: -8),
            metarCloseButton.widthAnchor.constraint(equalToConstant: 28),
            metarCloseButton.heightAnchor.constraint(equalToConstant: 28),

            metarLabel.topAnchor.constraint(equalTo: metarPanelView.topAnchor, constant: 10),
            metarLabel.leadingAnchor.constraint(equalTo: metarPanelView.leadingAnchor, constant: 12),
            metarLabel.trailingAnchor.constraint(equalTo: metarCloseButton.leadingAnchor, constant: -4),
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

        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateVisualization()
        }
    }

    private func setupAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            let relM = data.relativeAltitude.doubleValue
            if !self.baroBaselineSet {
                self.baroBaselineAltitudeFeet = self.gpsMSLAltitudeFeet
                self.baroBaselineSet = true
                self.baroRelativeAltitude = 0
            } else {
                self.baroRelativeAltitude = relM
            }
            let fusedFeet = self.baroBaselineAltitudeFeet + relM * CalculationsLogic.metersToFeet
            self.userAltitude = fusedFeet
        }
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arSceneView.addGestureRecognizer(tap)
    }

    // MARK: - Airport Loading

    private var allAirports: [Airport] = []

    private func loadAirports() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let parsed = AirportDataParser.loadAirportsFromCSV() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let loc = self.userLocation ?? self.activeLocation
                self.allAirports = parsed
                if let loc = loc {
                    DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                        let nearby = CalculationsLogic.filterAirportsInRange(
                            airports: parsed,
                            userCoord: loc,
                            maxRangeNauticalMiles: 200
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
        }
    }

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
        arKitNorthCorrectionDeg = 0
        northCorrectionSampleCount = 0
        sceneManager?.arKitNorthCorrectionDeg = 0
    }

    // MARK: - Actions

    @objc private func showSettings() {
        guard let settings = sceneManager?.settings else { return }
        let vc = SettingsViewController(settings: settings) { [weak self] updated in
            guard let self else { return }
            let old = self.sceneManager?.settings
            var updatedSettings = updated
            updatedSettings.updateFilter()
            self.sceneManager?.settings = updatedSettings
            updatedSettings.save()

            let needsRebuild =
                updatedSettings.showAircraft        != old?.showAircraft ||
                updatedSettings.showAirports        != old?.showAirports ||
                updatedSettings.aircraftMaxDistance != old?.aircraftMaxDistance ||
                updatedSettings.airportMaxDistance  != old?.airportMaxDistance ||
                updatedSettings.showLargeAirports   != old?.showLargeAirports  ||
                updatedSettings.showMediumAirports  != old?.showMediumAirports ||
                updatedSettings.showSmallAirports   != old?.showSmallAirports  ||
                updatedSettings.callsignFilter      != old?.callsignFilter

            if needsRebuild {
                self.sceneManager?.clearAll()
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    @objc private func showMap() {
        guard let loc = activeLocation else { return }
        let aircraft = Array(connectionLogic.detectedAircraft.values)
        let settings = sceneManager?.settings ?? ARVisualizationSettings()

        let vc = MapViewController(
            userLocation: loc,
            userHeading: userHeading,
            aircraft: aircraft,
            airports: airports,
            settings: settings
        )

        // Provide fresh data every live-update tick
        vc.dataProvider = { [weak self] in
            guard let self, let loc = self.activeLocation else { return nil }
            return (
                aircraft: Array(self.connectionLogic.detectedAircraft.values),
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

    // MARK: - METAR Panel

    private func showMetarPanel(for icao: String) {
        metarSelectedICAO = icao
        metarLabel.text = "METAR \(icao): fetching…"
        metarPanelView.isHidden = false
        fetchMETAR(for: icao)
    }

    private func hideMetarPanel() {
        metarFetchTask?.cancel()
        metarFetchTask = nil
        metarPanelView.isHidden = true
        metarSelectedICAO = nil
    }

    private func fetchMETAR(for icao: String) {
        metarFetchTask?.cancel()

        // Build aviationweather.gov request
        let urlStr = "https://aviationweather.gov/api/data/metar?ids=\(icao)&format=raw&hours=2"
        guard let url = URL(string: urlStr) else { return }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.metarSelectedICAO == icao else { return }
                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    self.metarLabel.text = "METAR \(icao): unavailable"
                    return
                }
                guard let data = data,
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
            }
        }
        metarFetchTask = task
        task.resume()
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

    private var usingADSBGPS: Bool {
        connectionLogic.connectionStatus == .receiving && connectionLogic.ownshipData != nil
    }

    private func updateVisualization() {
        guard let loc = activeLocation else { return }

        let aircraftList = Array(connectionLogic.detectedAircraft.values)

        let cameraPos: SCNVector3
        if let pov = arSceneView.pointOfView {
            let t = pov.worldTransform
            cameraPos = SCNVector3(t.m41, t.m42, t.m43)
        } else {
            cameraPos = .init()
        }

        // Evaluate TCAS state for this tick
        let tcas = TCASSystem.evaluate(
            aircraft: aircraftList,
            userLocation: loc,
            userAltitude: activeAltitude
        )
        currentTCASEvaluation = tcas
        applyTCASOverlay(tcas)

        sceneManager?.updateAircraft(
            aircraftList,
            userLocation: loc,
            userAltitude: activeAltitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraPos,
            tcasEvaluation: tcas
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

    private func updateOffScreenArrow(for nodeID: String) {
        guard let node = sceneManager?.node(forID: nodeID), !node.isHidden else {
            DispatchQueue.main.async { self.offScreenArrowView.hide() }
            return
        }

        let worldPos  = node.worldPosition
        let projected = arSceneView.projectPoint(worldPos)
        let screenSize = arSceneView.bounds.size

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

    /// Runs at 60 Hz. For every active TCAS threat that is off-screen,
    /// draws a colored chevron at the screen edge pointing toward it.
    private func updateTCASArrows() {
        let tcas = currentTCASEvaluation
        guard tcas.overallLevel != .none else {
            DispatchQueue.main.async { self.offScreenArrowView.clearTCASArrows() }
            return
        }

        let screenSize = arSceneView.bounds.size
        var arrowData: [(angle: CGFloat, center: CGPoint, color: UIColor)] = []

        for (id, level) in tcas.threats {
            let nodeID = "aircraft_\(id)"
            // Skip if this is the user-selected node — the white selection arrow already covers it
            if case .selected(let sel) = selectionState, sel == nodeID { continue }

            guard let node = sceneManager?.node(forID: nodeID), !node.isHidden else { continue }

            let projected = arSceneView.projectPoint(node.worldPosition)
            let behindCamera = projected.z >= 1.0
            let onScreen = !behindCamera
                && projected.x >= 0 && CGFloat(projected.x) <= screenSize.width
                && projected.y >= 0 && CGFloat(projected.y) <= screenSize.height

            // Aircraft is already visible on screen — no arrow needed
            if onScreen { continue }

            let (edgePoint, angle) = screenEdgePoint(
                projected: CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
                isBehindCamera: behindCamera,
                screenSize: screenSize,
                margin: 40
            )

            let color: UIColor = level == .resolutionAdvisory
                ? UIColor(red: 1.0, green: 0.2, blue: 0.0, alpha: 1.0)   // RA — red-orange
                : UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1.0)   // TA — amber

            arrowData.append((angle: angle, center: edgePoint, color: color))
        }

        let data = arrowData
        DispatchQueue.main.async { self.offScreenArrowView.setTCASArrows(data) }
    }

    // MARK: - TCAS Overlay

    private func applyTCASOverlay(_ tcas: TCASEvaluation) {
        switch tcas.overallLevel {
        case .none:
            stopTCASFlash()
            tcasOverlayView.layer.borderColor = UIColor.clear.cgColor
        case .trafficAdvisory:
            stopTCASFlash()
            tcasOverlayView.layer.borderColor =
                UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.85).cgColor
        case .resolutionAdvisory:
            startTCASFlashIfNeeded()
        }
    }

    private func startTCASFlashIfNeeded() {
        guard tcasFlashTimer == nil else { return }
        tcasFlashState = true
        tcasOverlayView.layer.borderColor = UIColor.red.cgColor
        tcasFlashTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tcasFlashState.toggle()
            self.tcasOverlayView.layer.borderColor = self.tcasFlashState
                ? UIColor.red.cgColor
                : UIColor.clear.cgColor
        }
    }

    private func stopTCASFlash() {
        tcasFlashTimer?.invalidate()
        tcasFlashTimer = nil
        tcasFlashState = false
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
            let gpsAccStr: String
            if lastHorizontalAccuracy < 0 {
                gpsAccStr = "?"
            } else if lastHorizontalAccuracy > gpsAccuracyThreshold {
                gpsAccStr = String(format: "⚠️ ±%.0fm", lastHorizontalAccuracy)
            } else {
                gpsAccStr = String(format: "±%.0fm", lastHorizontalAccuracy)
            }
            lines.append(String(format: "📍 %.4f°  %.4f°  (\(gpsSource)  \(gpsAccStr))", loc.latitude, loc.longitude))

            let altSource = baroBaselineSet ? "baro" : "GPS"
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

        if case .selected(let nodeID) = selectionState {
            updateOffScreenArrow(for: nodeID)
        }
        updateTCASArrows()
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
        guard hAcc > 0 && hAcc <= gpsAccuracyThreshold else {
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

        let newGPSFeet = loc.altitude * CalculationsLogic.metersToFeet
        gpsMSLAltitudeFeet = newGPSFeet

        if !baroBaselineSet {
            userAltitude = newGPSFeet
        } else {
            baroBaselineAltitudeFeet = newGPSFeet - baroRelativeAltitude * CalculationsLogic.metersToFeet
        }

        connectionLogic.updateLocation(loc.coordinate, altitudeFeet: userAltitude)

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

        if lastHeadingAccuracy >= 0
            && lastHeadingAccuracy <= 20
            && accuracy > 20 {
            startARSession()
            arKitNorthCorrectionDeg = 0
            northCorrectionSampleCount = 0
        }

        lastHeadingAccuracy = accuracy
        let trueNorth = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        userHeading = trueNorth

        if accuracy <= 10, let frame = arSceneView.session.currentFrame {
            let arYawDeg = Double(-frame.camera.eulerAngles.y) * 180.0 / .pi
            var sample = trueNorth - arYawDeg
            while sample >  180 { sample -= 360 }
            while sample < -180 { sample += 360 }

            let alpha = 0.15
            if northCorrectionSampleCount == 0 {
                arKitNorthCorrectionDeg = sample
            } else {
                arKitNorthCorrectionDeg = alpha * sample + (1 - alpha) * arKitNorthCorrectionDeg
            }
            northCorrectionSampleCount += 1
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
