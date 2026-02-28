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
    private var lastAppliedTCASLevel: TCASAlertLevel = .none

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
            connectionLogic.updateInternetQueryRadius(saved.aircraftMaxDistance)
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
        // Use the user's configured airport range, with a small safety margin so that
        // airports just outside the display range are still available as the user moves.
        // This keeps allAirports small — previously it always held every airport within
        // 200 NM even when the user had set the display range to 10 NM.
        let rangeNM = (sceneManager?.settings.airportMaxDistance ?? 40) * 1.25
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
        }
    }

    private func refreshNearbyAirports() {
        guard let loc = userLocation ?? activeLocation else { return }
        // Same 25% safety margin as loadAirports() — keeps the working set tight
        // while ensuring airports at the edge of the display radius are included.
        let rangeNM = (sceneManager?.settings.airportMaxDistance ?? 40) * 1.25
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let nearby = CalculationsLogic.filterAirportsInRange(
                airports: self.allAirports,
                userCoord: loc,
                maxRangeNauticalMiles: rangeNM
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
            self.connectionLogic.updateInternetQueryRadius(updatedSettings.aircraftMaxDistance)

            // Only rebuild the scene when a filter that can ADD new nodes is tightened
            // (removing nodes is safe; adding potentially thousands at once crashes SceneKit).
            // showGroundAircraft toggled ON is handled gracefully by the per-tick node budget —
            // we do NOT clearAll() for it, so existing airborne nodes stay and ground nodes
            // trickle in over a few update ticks.
            let needsRebuild =
                updatedSettings.showAircraft        != old?.showAircraft ||
                updatedSettings.showAirports        != old?.showAirports ||
                updatedSettings.aircraftMaxDistance  < (old?.aircraftMaxDistance  ?? 0) ||
                updatedSettings.airportMaxDistance   < (old?.airportMaxDistance   ?? 0) ||
                updatedSettings.showLargeAirports   != old?.showLargeAirports  ||
                updatedSettings.showMediumAirports  != old?.showMediumAirports ||
                updatedSettings.showSmallAirports   != old?.showSmallAirports  ||
                updatedSettings.callsignFilter      != old?.callsignFilter      ||
                updatedSettings.showGroundAircraft  == false   // turning OFF ground → prune

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

        updateStatusLabel()
    }

    // MARK: - Off-Screen Arrow

    private func updateOffScreenArrow(for nodeID: String) {
        guard let node = sceneManager?.node(forID: nodeID), !node.isHidden else {
            offScreenArrowView.hide()
            return
        }

        let worldPos   = node.worldPosition
        let projected  = arSceneView.projectPoint(worldPos)
        let screenSize = arSceneView.bounds.size

        let behindCamera = projected.z >= 1.0
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
            let behindCamera = projected.z >= 1.0
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

        // When airborne and moving fast enough for GPS track to be reliable, use
        // it instead of the compass for north-correction. Inside an aircraft fuselage
        // the magnetic field is distorted by engines/avionics, making the compass
        // unreliable. GPS track is unaffected by electromagnetics and gives a stable,
        // drift-free true-north reference at cruise speed.
        // Speed threshold: 30 kt ≈ 15.4 m/s — below this GPS course can jump ±15°.
        let speedMS = loc.speed   // m/s, negative means invalid
        let courseValid = loc.courseAccuracy >= 0 && loc.courseAccuracy < 20 && speedMS >= 15.0
        if tcasEnabled && courseValid, let frame = arSceneView.session.currentFrame {
            // Prefer ADS-B ownship track (already true, high accuracy); fall back to
            // iPhone GPS course (also true north, slightly noisier at low speeds).
            let gpsTrueTrack: Double
            if let ownship = connectionLogic.ownshipData, ownship.groundSpeed > 30 {
                gpsTrueTrack = ownship.track
            } else {
                gpsTrueTrack = loc.course   // CLLocation.course is true north
            }

            applyNorthCorrection(trueNorth: gpsTrueTrack, frame: frame)
        }
    }

    /// Apply a single north-correction sample using the given true-north reference
    /// and the current ARKit world yaw. Uses exponential smoothing (α = 0.15) to
    /// filter noise; the first sample is applied instantly.
    private func applyNorthCorrection(trueNorth: Double, frame: ARFrame) {
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

        // Use compass for north-correction only when NOT in airborne GPS-track mode.
        // In-flight the compass is unreliable inside a metal fuselage; GPS track
        // (applied in didUpdateLocations above) takes over when speed > 30 kt.
        let usingGPSTrack = tcasEnabled && (connectionLogic.ownshipData?.groundSpeed ?? 0) > 30
        if !usingGPSTrack, accuracy <= 10, let frame = arSceneView.session.currentFrame {
            applyNorthCorrection(trueNorth: trueNorth, frame: frame)
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
