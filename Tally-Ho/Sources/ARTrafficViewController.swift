//
//  ARTrafficViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//

import UIKit
import ARKit
import CoreLocation
import Combine

class ARTrafficViewController: UIViewController {

    // MARK: - UI

    private var arSceneView: ARSCNView!
    private var statusLabel: UILabel!
    private var settingsButton: UIButton!

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

    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Last position used to centre the 200 NM airport pre-filter.
    private var lastAirportFilterLocation: CLLocationCoordinate2D?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        UIApplication.shared.isIdleTimerDisabled = true

        setupUI()
        setupARScene()
        setupLocation()
        setupObservers()
        loadAirports()

        // Load persisted settings before starting
        if let saved = ARVisualizationSettings.load() {
            sceneManager?.settings = saved
        }

        // Begin listening for ADS-B broadcasts in background
        connectionLogic.startListening()
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

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
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
        // Airborne mode gives the best GPS/barometric fusion for fast-moving aircraft
        locationManager.activityType = .airborne
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = 1.0   // update every 1° of heading change
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

    /// Full airport database — kept on the background thread only, never
    /// assigned to the main-thread `airports` array directly.
    private var allAirports: [Airport] = []

    private func loadAirports() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let parsed = AirportDataParser.loadAirportsFromCSV() else { return }
            // Pre-filter to 200 NM on the background thread so the main thread
            // never iterates the full ~70 k-row database on every update tick.
            DispatchQueue.main.async {
                self?.allAirports = parsed
                self?.refreshNearbyAirports()
            }
        }
    }

    /// Re-filter allAirports down to 200 NM from the current position.
    /// Called once after CSV load and again if the user moves significantly.
    private func refreshNearbyAirports() {
        guard let loc = userLocation ?? activeLocation else {
            // No location yet — store nothing; called again on first GPS fix.
            return
        }
        airports = CalculationsLogic.filterAirportsInRange(
            airports: allAirports,
            userCoord: loc,
            maxRangeNauticalMiles: 200
        )
        updateStatusLabel()
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
            return ownship.altitude   // already in feet from GDL90 parser
        }
        return userAltitude
    }

    /// Whether we're currently using ADS-B GPS.
    private var usingADSBGPS: Bool {
        connectionLogic.connectionStatus == .receiving && connectionLogic.ownshipData != nil
    }

    private func updateVisualization() {
        guard let loc = activeLocation else { return }

        // Grab the camera's current world position in the AR scene.
        // This is the key for accuracy in flight: as the aircraft flies,
        // the AR origin stays fixed where ARKit started but the camera
        // moves through the scene. All target positions must be expressed
        // relative to where the camera IS NOW, not where the scene started.
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
        // Keep ConnectionLogic updated with the best available position
        connectionLogic.updateLocation(loc, altitudeFeet: activeAltitude)
        updateStatusLabel()
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

        // Internet
        lines.append(connectionLogic.isInternetAvailable ? "🌐 Internet: Online" : "🌐 Internet: Offline")

        // GPS — source-aware
        let displayLoc = activeLocation
        let displayAlt = activeAltitude
        let gpsSource  = usingADSBGPS ? "ADS-B GPS" : "iPhone GPS"
        if let loc = displayLoc {
            lines.append(String(format: "📍 %.4f°  %.4f°  (\(gpsSource))", loc.latitude, loc.longitude))
            lines.append(String(format: "✈️ %.0f ft MSL   🧭 %.0f°", displayAlt, userHeading))
        } else {
            lines.append("📍 GPS: Acquiring…")
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

        // Airports
        lines.append("🛫 Airports loaded: \(airports.count)")

        statusLabel.text = lines.map { "  \($0)  " }.joined(separator: "\n")
    }
}

// MARK: - ARSCNViewDelegate

extension ARTrafficViewController: ARSCNViewDelegate {
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

        // Re-run the 200 NM pre-filter if: first fix, or user has moved > 50 NM
        // since the last filter (at 250 kt that's ~12 minutes of flight).
        let needsRefresh: Bool
        if let last = lastAirportFilterLocation {
            needsRefresh = CalculationsLogic.distanceInNauticalMiles(
                from: last, to: loc.coordinate) > 50
        } else {
            needsRefresh = true   // first fix — always refresh
        }
        if needsRefresh && !allAirports.isEmpty {
            lastAirportFilterLocation = loc.coordinate
            refreshNearbyAirports()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        userHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        // State is updated here; the 4 Hz timer drives all scene updates.
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
