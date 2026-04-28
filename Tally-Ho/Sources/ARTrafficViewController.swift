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
    private var statusLabel: UITextView!
    private var copyStatusButton: UIButton!
    private var shareLogButton: UIButton!
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

    // MARK: - Auto-log
    private var capturedEventKeys = Set<String>()
    private var logSavedNote: String = ""

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
    private var currentZoomScale: CGFloat = 1.0
    private var pinchStartScale: CGFloat = 1.0
    private var cancellables = Set<AnyCancellable>()

    private var lastAirportFilterLocation: CLLocationCoordinate2D?
    private var selectionState: SelectionState = .none
    private let gpsAccuracyThreshold: CLLocationAccuracy = 30.0

    private var arKitNorthCorrectionDeg: Double = 0
    private var isFirstHeadingFix: Bool = true

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

        // startARSession() resets ARKit world tracking but no longer clears the
        // north correction (which is the stable geographic declination).  The scene
        // manager is synced here so nodes placed immediately on re-entry use the
        // correct bearing offset without waiting for the next heading callback.
        startARSession()

        // The map is presented .fullScreen, so viewWillDisappear fires while it is shown
        // (pausing the AR session, invalidating the timer, stopping the altimeter).
        // Restart everything here so the AR view is fully live again when it reappears.

        // Restart the altimeter (stopped in viewWillDisappear).
        setupAltimeter()

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

        // Status HUD — UITextView acts as its own scroll view, so pinning all four
        // edges to the safe area gives it a definite frame height and lets the user
        // scroll when content is taller than the screen.
        statusLabel = UITextView()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        statusLabel.textColor = .white
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.isScrollEnabled = true
        statusLabel.showsVerticalScrollIndicator = true
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
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
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -68),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        // Copy button — top-right corner of the HUD text view.
        copyStatusButton = UIButton(type: .system)
        copyStatusButton.translatesAutoresizingMaskIntoConstraints = false
        copyStatusButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copyStatusButton.tintColor = .white
        copyStatusButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        copyStatusButton.layer.cornerRadius = 12
        copyStatusButton.isHidden = true
        copyStatusButton.addTarget(self, action: #selector(copyStatusTapped), for: .touchUpInside)
        view.addSubview(copyStatusButton)

        NSLayoutConstraint.activate([
            copyStatusButton.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: -4),
            copyStatusButton.topAnchor.constraint(equalTo: statusLabel.topAnchor, constant: 4),
            copyStatusButton.widthAnchor.constraint(equalToConstant: 28),
            copyStatusButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        // Share log button — below the copy button; shares tally-hud-log.txt via the system sheet.
        shareLogButton = UIButton(type: .system)
        shareLogButton.translatesAutoresizingMaskIntoConstraints = false
        shareLogButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        shareLogButton.tintColor = .white
        shareLogButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        shareLogButton.layer.cornerRadius = 12
        shareLogButton.isHidden = true
        shareLogButton.addTarget(self, action: #selector(shareLogTapped), for: .touchUpInside)
        view.addSubview(shareLogButton)

        NSLayoutConstraint.activate([
            shareLogButton.trailingAnchor.constraint(equalTo: copyStatusButton.trailingAnchor),
            shareLogButton.topAnchor.constraint(equalTo: copyStatusButton.bottomAnchor, constant: 4),
            shareLogButton.widthAnchor.constraint(equalToConstant: 28),
            shareLogButton.heightAnchor.constraint(equalToConstant: 28)
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

        // Pinch is added to self.view (not arSceneView) so that ARKit's internal
        // touch handling cannot swallow the two-finger event before we see it.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
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
        currentZoomScale = 1.0
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
            let old = self.sceneManager?.settings
            var updatedSettings = updated
            updatedSettings.updateFilter()
            self.sceneManager?.settings = updatedSettings
            updatedSettings.save()
            self.connectionLogic.updateInternetQueryRadius(updatedSettings.aircraftMaxDistance)

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
        present(nav, animated: true)
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
        copyStatusButton.isHidden = statusLabel.isHidden
        shareLogButton.isHidden   = statusLabel.isHidden
    }

    @objc private func shareLogTapped() {
        // Always save the current state first so the file always exists when shared.
        let d = connectionLogic.adsbDiag
        var frames: [String] = []
        for (i, f) in d.recent22bFrames.enumerated() { frames.append("22b[\(i)]: \(f)") }
        for (i, f) in d.recent20bFrames.enumerated() { frames.append("20b[\(i)]: \(f)") }
        for (i, f) in d.recent47bFrames.enumerated() { frames.append("47b[\(i)]: \(f)") }
        for (i, f) in d.recent22bUndecodedFrames.enumerated() { frames.append("22b?[\(i)]: \(f)") }
        appendToHUDLog(reason: "Manual save", rawFrames: frames)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = docs.appendingPathComponent("tally-hud-log.txt")
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        let vc = UIActivityViewController(activityItems: [logURL], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = shareLogButton
        present(vc, animated: true)
    }

    private func appendToHUDLog(reason: String, rawFrames: [String] = []) {
        let ts = ISO8601DateFormatter().string(from: Date())
        var entry = "\n=== \(ts) [\(reason)] ===\n\(statusLabel.text ?? "")\n"
        if !rawFrames.isEmpty {
            entry += "\n--- raw frames ---\n" + rawFrames.joined(separator: "\n") + "\n"
        }

        let d = connectionLogic.adsbDiag
        var cal: [String] = []
        if let s = d.calibrationStatus   { cal.append(s) }
        if let s = d.calibrationV2Status { cal.append(s) }
        if let s = d.calibrationV3Status { cal.append(s) }
        if let lat = d.propLatByteOffset, let lon = d.propLonByteOffset,
           let latS = d.propLatScale,    let lonS = d.propLonScale {
            cal.append(String(format: "22b offsets: lat@%d×%.2e  lon@%d×%.2e", lat, latS, lon, lonS))
        }
        for (size, hit) in d.undecodedHits.sorted(by: { $0.key < $1.key }) {
            cal.append("\(size)b xcorr: \(hit.display)")
        }
        for (size, result) in d.undecodedXcorrResults.sorted(by: { $0.key < $1.key }) {
            cal.append("xcorr[\(size)b]: \(result)")
        }
        for (size, hex) in d.sampleFramesBySize.sorted(by: { $0.key < $1.key })
            where rawFrames.allSatisfy({ !$0.hasPrefix("\(size)b:") }) {
            cal.append("\(size)b sample: \(hex)")
        }
        for (i, frame) in d.recent22bFrames.enumerated() { cal.append("22b[\(i)]: \(frame)") }
        for (i, frame) in d.recent20bFrames.enumerated() { cal.append("20b[\(i)]: \(frame)") }
        for (i, frame) in d.recent47bFrames.enumerated() { cal.append("47b[\(i)]: \(frame)") }
        for (i, frame) in d.recent70bFrames.enumerated() { cal.append("70b[\(i)]: \(frame)") }
        for (i, frame) in d.recent22bUndecodedFrames.enumerated() { cal.append("22b?[\(i)]: \(frame)") }
        if !d.rawMsgTypeCounts.isEmpty {
            let msgLine = d.rawMsgTypeCounts
                .sorted { $0.key < $1.key }
                .map { String(format: "0x%02X:%d", $0.key, $0.value) }
                .joined(separator: " ")
            cal.append("msg types: \(msgLine)")
        }
        if !cal.isEmpty {
            entry += "\n--- calibration ---\n" + cal.joined(separator: "\n") + "\n"
        }

        guard let data = entry.data(using: .utf8) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url  = docs.appendingPathComponent("tally-hud-log.txt")
        var writeOK = false
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            writeOK = true
        } else if (try? data.write(to: url)) != nil {
            writeOK = true
        }
        logSavedNote = writeOK
            ? "📝 Log saved [\(reason)] — Files > TallyOh > tally-hud-log.txt"
            : "⚠️ Log write failed [\(reason)]"
    }

    @objc private func copyStatusTapped() {
        // Change icon immediately so the tap feels instant.
        copyStatusButton.setImage(UIImage(systemName: "checkmark"), for: .normal)
        // Pasteboard write can stall the main thread briefly; push it to a background queue.
        let text = statusLabel.text ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            UIPasteboard.general.string = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyStatusButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        }
    }

    // MARK: - Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = currentZoomScale
        case .changed:
            let scale = pinchStartScale * gesture.scale
            currentZoomScale = max(1.0, min(4.0, scale))
            // Digital zoom: scale the AR view layer in the compositor.
            // ARKit owns the camera's projectionTransform and resets it every frame,
            // so adjusting fieldOfView has no effect. A UIView transform scales the
            // already-rendered Metal content at composite time, which is the only
            // reliable way to achieve full-scene digital zoom in ARKit.
            arSceneView.transform = CGAffineTransform(scaleX: currentZoomScale, y: currentZoomScale)
        default:
            break
        }
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
    /// D-ATIS text contains a Zulu time token such as "2345Z" or "2345Z." (with trailing
    /// punctuation). Falls back to nil if no matching token is found.
    private func parseDATISObservationTime(from text: String) -> Date? {
        let tokens = text.uppercased().components(separatedBy: .whitespacesAndNewlines)
        // Strip trailing punctuation so "2345Z." is treated identically to "2345Z".
        guard let timeToken = tokens.compactMap({ token -> String? in
            let cleaned = token.trimmingCharacters(in: .punctuationCharacters)
            guard cleaned.count == 5,
                  cleaned.hasSuffix("Z"),
                  cleaned.dropLast().allSatisfy({ $0.isNumber }) else { return nil }
            return cleaned
        }).first else { return nil }
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
                cameraWorldPosition: cameraPos
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
        var lines: [String] = []
        let d = connectionLogic.adsbDiag

        if !logSavedNote.isEmpty { lines.append(logSavedNote) }

        // Source
        switch connectionLogic.connectionStatus {
        case .receiving:
            let ipPart = d.sentryIPCaptured.map { " | \($0)" } ?? ""
            lines.append("⚠️ Sentry\(ipPart)")
        case .searching:    lines.append("📡 ADS-B: Searching…")
        case .notAvailable: lines.append("📡 ADS-B: Unavailable")
        case .disconnected: lines.append("📡 ADS-B: Off")
        }

        // Internet
        if connectionLogic.isInternetAvailable {
            if let status = d.lastInternetFetchStatus {
                lines.append(status.isEmpty
                    ? "🌐 Online (\(d.lastInternetFetchCount)ac)"
                    : "🌐 Online ⚠️ \(status)")
            } else {
                lines.append("🌐 Online (fetching…)")
            }
        } else {
            let cached = connectionLogic.detectedAircraft.values.filter { $0.source == .internet }.count
            lines.append(cached > 0 ? "🌐 Offline (\(cached) cached)" : "🌐 Offline")
        }

        // GPS + altitude
        let displayLoc = activeLocation
        let displayAlt = activeAltitude
        let gpsSource  = usingADSBGPS ? "ADS-B" : "iPhone"
        if let loc = displayLoc {
            let gpsAccStr: String
            if lastHorizontalAccuracy < 0 {
                gpsAccStr = "?"
            } else if lastHorizontalAccuracy > gpsAccuracyThreshold {
                gpsAccStr = String(format: "⚠️±%.0fm", lastHorizontalAccuracy)
            } else {
                gpsAccStr = String(format: "±%.0fm", lastHorizontalAccuracy)
            }
            lines.append(String(format: "📍 %.4f°  %.4f°  (\(gpsSource) \(gpsAccStr))", loc.latitude, loc.longitude))

            let altSource = baroBaselineSet ? "baro" : "GPS"
            let compassAccStr: String
            if lastHeadingAccuracy < 0 {
                compassAccStr = "?"
            } else if lastHeadingAccuracy > 20 {
                compassAccStr = "⚠️calibrate"
            } else {
                compassAccStr = String(format: "±%.0f°", lastHeadingAccuracy)
            }
            lines.append(String(format: "✈️ %.0f ft (%@)   🧭 %.0f° (%@)", displayAlt, altSource, userHeading, compassAccStr))
        } else if lastHorizontalAccuracy > 0 {
            lines.append(String(format: "📍 GPS ±%.0fm (AR pending)", lastHorizontalAccuracy))
        } else {
            lines.append("📍 GPS: Acquiring…")
        }

        // AR
        let arStateStr: String
        switch arTrackingState {
        case .normal:                  arStateStr = "AR: ✓"
        case .limited(let reason):
            switch reason {
            case .initializing:        arStateStr = "AR: Initializing…"
            case .relocalizing:        arStateStr = "AR: Relocalizing…"
            case .excessiveMotion:     arStateStr = "AR: ⚠️ Motion"
            case .insufficientFeatures: arStateStr = "AR: ⚠️ Features"
            @unknown default:          arStateStr = "AR: Limited"
            }
        case .notAvailable:            arStateStr = "AR: Not available"
        @unknown default:              arStateStr = "AR: Unknown"
        }
        lines.append("📷 \(arStateStr)")

        // TCAS
        switch currentTCASEvaluation.overallLevel {
        case .none: break
        case .trafficAdvisory:
            lines.append("⚠️ TCAS TA: \(currentTCASEvaluation.threats.count) aircraft")
        case .resolutionAdvisory:
            let n = currentTCASEvaluation.threats.values.filter { $0 == .resolutionAdvisory }.count
            lines.append("🔴 TCAS RA: \(n) aircraft")
        }

        // Decoder summary (one line)
        if connectionLogic.connectionStatus == .receiving {
            var decoders: [String] = []
            if d.calibrationStatus  != nil { decoders.append("22b") }
            if d.calibrationV2Status != nil { decoders.append("22v2") }
            if d.calibrationV3Status != nil { decoders.append("22v3") }
            if d.frameSizeCounts[70]  != nil || d.frameSizeCounts[560] != nil { decoders.append("70b") }
            if d.prop560DecodeCount > 0 { decoders.append("560b") }
            let wCount = d.uniqueAircraftSeen.filter { $0.hasPrefix("W") }.count
            if wCount > 0 {
                decoders.append("56b(W×\(wCount))")
            } else if d.frameSizeCounts[56] != nil {
                decoders.append("56b(scanning)")
            }
            // Show xcorr-confirmed hits for any non-standard frame size (20b, 28b, etc.)
            for (size, _) in d.undecodedHits.sorted(by: { $0.key < $1.key }) {
                decoders.append("\(size)b(✅)")
            }
            if !decoders.isEmpty { lines.append("✅ " + decoders.joined(separator: " · ")) }

            // xcorr progress for all actively-scanned frame sizes.
            // Shows in-progress vote state ("🔍…") and resets ("🔄…").
            // Confirmed hits ("✅…") are already shown in the decoder line above.
            // Size 22 is excluded: v1/v2/v3 are confirmed; xcorr just rediscovers them.
            for (size, result) in d.undecodedXcorrResults.sorted(by: { $0.key < $1.key })
                where !result.hasPrefix("✅") && size != 22 {
                lines.append(result)
            }

            // Frame-size histogram: top-5 sizes by receive count.
            let topSizes = d.frameSizeCounts
                .sorted { $0.value > $1.value }
                .prefix(5)
            if !topSizes.isEmpty {
                let hist = topSizes.map { "\($0.key)b×\($0.value)" }.joined(separator: " ")
                lines.append("📊 \(hist)")
            }
        }

        // Aircraft
        let total   = connectionLogic.detectedAircraft.count
        let adsbCnt = connectionLogic.detectedAircraft.values.filter { $0.source == .adsb }.count
        let netCnt  = connectionLogic.internetAircraftCount
        let internetPositions = connectionLogic.detectedAircraft.values
            .filter { $0.source == .internet }
            .map { ($0.latitude, $0.longitude) }
        let confirmedCnt = connectionLogic.detectedAircraft.values.filter { ac in
            guard ac.source == .adsb else { return false }
            return internetPositions.contains { abs($0.0 - ac.latitude) < 0.1 && abs($0.1 - ac.longitude) < 0.1 }
        }.count

        var trafficLine = "🛩 Aircraft: \(total)"
        var tparts: [String] = []
        if adsbCnt > 0 {
            let seen = d.uniqueAircraftSeen.count
            let seenSuffix = seen > adsbCnt ? " seen:\(seen)" : ""
            let confSuffix = confirmedCnt > 0 ? " ✅\(confirmedCnt)" : ""
            let stdSuffix = " std:\(d.parsedStdTraffic)"
            tparts.append("ADS-B:\(adsbCnt)\(confSuffix)\(seenSuffix)\(stdSuffix)")
        }
        if netCnt > 0 { tparts.append("Net:\(netCnt)") }
        if !tparts.isEmpty { trafficLine += " (\(tparts.joined(separator: " ")))" }
        if let last = connectionLogic.detectedAircraft.values.max(by: { $0.lastUpdate < $1.lastUpdate })?.lastUpdate {
            trafficLine += "  [\(Int(-last.timeIntervalSinceNow))s ago]"
        }
        lines.append(trafficLine)

        if let userLoc = displayLoc {
            let nearby = connectionLogic.detectedAircraft.values
                .map { ac -> (Aircraft, Double) in
                    let dlat = ac.latitude  - userLoc.latitude
                    let dlon = (ac.longitude - userLoc.longitude) * cos(userLoc.latitude * .pi / 180)
                    return (ac, sqrt(dlat*dlat + dlon*dlon) * 60)
                }
                .sorted { $0.1 < $1.1 }
            for (ac, distNM) in nearby {
                let srcTag: String
                if ac.source == .internet {
                    srcTag = "🌐"
                } else if internetPositions.contains(where: { abs($0.0 - ac.latitude) < 0.1 && abs($0.1 - ac.longitude) < 0.1 }) {
                    srcTag = "✅"
                } else {
                    srcTag = "📡"
                }
                let altPrefix = (ac.source == .adsb && ac.altitude == 10_000) ? "~" : ""
                lines.append(String(format: "  %@%@ %.4f° %.4f° %@%.0fft %.0fnm",
                                    srcTag, ac.callsign, ac.latitude, ac.longitude, altPrefix, ac.altitude, distNM))
            }
        }

        lines.append("🛫 Airports: \(airports.count)")

        let newText = lines.map { "  \($0)  " }.joined(separator: "\n")
        guard newText != statusLabel.text else { return }
        statusLabel.text = newText

        // Auto-capture triggers
        if connectionLogic.connectionStatus == .receiving {
            if !d.prop56bLastDecodedHex.isEmpty && capturedEventKeys.insert("w56_first").inserted {
                appendToHUDLog(reason: "First W56 decode",
                               rawFrames: [d.prop56bLastDecodedHex])
            }
            // xcorr lock no longer auto-saves: result already appears in every
            // calibration section, and sampleFramesBySize[n] is not the convergence frame.
            // Ground correlation: fires once we have ≥20 56b frames and internet aircraft.
            // Waiting for 20 frames (~20s) avoids firing on the very first connection burst.
            let netCount = connectionLogic.detectedAircraft.values.filter { $0.source == .internet }.count
            if (d.frameSizeCounts[56] ?? 0) >= 20 && netCount >= 3
                && capturedEventKeys.insert("56b_ground_corr").inserted {
                var frames: [String] = []
                if let hex = d.sampleFramesBySize[56] { frames.append("56b: \(hex)") }
                if !d.prop56bLastDecodedHex.isEmpty { frames.append("56b(W): \(d.prop56bLastDecodedHex)") }
                appendToHUDLog(reason: "56b+internet ground correlation", rawFrames: frames)
            }
        }
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
        // Without A-GPS (flight mode, no cellular), cold-start accuracy is typically
        // 200–2000 m — well above the 30 m AR threshold — for the first few minutes.
        // The spatial filter (±10°) only needs ~100 km precision, so seed ConnectionLogic
        // with any sub-2 km fix before the AR accuracy guard runs.  This breaks the
        // chicken-and-egg deadlock where tcasEnabled requires altitude which requires
        // a GPS fix that requires tcasEnabled.
        if hAcc > 0 && hAcc < 2000 && userLocation == nil {
            connectionLogic.updateLocation(loc.coordinate,
                                           altitudeFeet: loc.altitude * CalculationsLogic.metersToFeet)
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

        let newGPSFeet = loc.altitude * CalculationsLogic.metersToFeet
        gpsMSLAltitudeFeet = newGPSFeet

        if !baroBaselineSet {
            userAltitude = newGPSFeet
        } else {
            baroBaselineAltitudeFeet = newGPSFeet - baroRelativeAltitude * CalculationsLogic.metersToFeet
        }

        connectionLogic.updateLocation(loc.coordinate, altitudeFeet: userAltitude)

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
        //
        // Only apply while airborne: on the ground the magnetometer is disturbed by
        // vehicles, buildings, and ground equipment, which would pollute the smoothed
        // correction value used in flight.
        if tcasEnabled && newHeading.trueHeading >= 0 && newHeading.magneticHeading >= 0 {
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
