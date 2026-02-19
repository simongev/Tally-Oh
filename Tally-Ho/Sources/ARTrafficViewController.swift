//
//  ARTrafficViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//

import UIKit
import ARKit
import CoreLocation
import Combine

class ARTrafficViewController: UIViewController {

    // MARK: - UI Components

    private var arSceneView: ARSCNView!
    private var statusLabel: UILabel!
    private var settingsButton: UIButton!

    // MARK: - Core Components

    private var connectionLogic = ConnectionLogic()
    private var sceneManager: ARSceneManager?
    private var locationManager = CLLocationManager()

    // MARK: - State

    private var airports: [Airport] = []
    private var userLocation: CLLocationCoordinate2D?
    private var userAltitude: Double = 0
    private var userHeading: Double = 0

    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Keep screen always on
        UIApplication.shared.isIdleTimerDisabled = true

        setupUI()
        setupARScene()
        setupLocation()
        setupObservers()
        loadAirports()

        // Auto-connect to Sentri ADS-B on launch (runs in background; no user action needed)
        connectionLogic.connect()
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
        connectionLogic.disconnect()
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .black

        // AR Scene View — fills the whole screen
        arSceneView = ARSCNView(frame: view.bounds)
        arSceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arSceneView)

        // Status Label — top-left HUD
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

        // Settings Button — bottom-right corner only
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
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    private func setupObservers() {
        // Reflect Sentri connection changes in the status label
        connectionLogic.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusLabel() }
            .store(in: &cancellables)

        // Reflect internet status changes
        connectionLogic.$isInternetAvailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusLabel() }
            .store(in: &cancellables)

        // 1-second update loop for AR visualization
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateVisualization()
        }
    }

    private func loadAirports() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let airports = AirportDataParser.loadAirportsFromCSV() {
                DispatchQueue.main.async {
                    self?.airports = airports
                    self?.updateStatusLabel()
                }
            }
        }
    }

    private func startARSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravityAndHeading
        configuration.providesAudioData = false
        arSceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Settings

    @objc private func showSettings() {
        guard let settings = sceneManager?.settings else { return }
        let vc = SettingsViewController(settings: settings) { [weak self] updated in
            self?.sceneManager?.settings = updated
            // Clear and redraw so type-filter changes take effect immediately
            self?.sceneManager?.clearAll()
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    // MARK: - Update Loop

    private func updateVisualization() {
        guard let userLocation = userLocation else { return }

        sceneManager?.updateAircraft(
            Array(connectionLogic.detectedAircraft.values),
            userLocation: userLocation,
            userAltitude: userAltitude,
            userHeading: userHeading
        )

        sceneManager?.updateAirports(
            airports,
            userLocation: userLocation,
            userAltitude: userAltitude,
            userHeading: userHeading
        )

        updateStatusLabel()
    }

    // MARK: - HUD Status Label

    private func updateStatusLabel() {
        var lines: [String] = []

        // ADS-B / Sentri status
        switch connectionLogic.connectionStatus {
        case .connected:   lines.append("📡 Sentri: Connected")
        case .connecting:  lines.append("📡 Sentri: Connecting…")
        case .disconnected: lines.append("📡 Sentri: Searching…")
        case .error:       lines.append("📡 Sentri: Not found")
        }

        // Internet
        lines.append(connectionLogic.isInternetAvailable ? "🌐 Internet: Online" : "🌐 Internet: Offline")

        // GPS
        if let loc = userLocation {
            lines.append(String(format: "📍 %.4f°  %.4f°", loc.latitude, loc.longitude))
            lines.append(String(format: "✈️ %.0f ft MSL   🧭 %.0f°", userAltitude, userHeading))
        } else {
            lines.append("📍 Waiting for GPS…")
        }

        // Traffic
        let total   = connectionLogic.detectedAircraft.count
        let adsbCnt = connectionLogic.detectedAircraft.values.filter { $0.source == .adsb }.count
        let netCnt  = connectionLogic.internetAircraftCount
        var trafficLine = "🛩 Aircraft: \(total)"
        if adsbCnt > 0 || netCnt > 0 {
            var parts: [String] = []
            if adsbCnt > 0 { parts.append("ADS-B:\(adsbCnt)") }
            if netCnt  > 0 { parts.append("Net:\(netCnt)") }
            trafficLine += " (\(parts.joined(separator: " ")))"
        }
        lines.append(trafficLine)

        // Airports
        lines.append("🛫 Airports loaded: \(airports.count)")
        if let loc = userLocation {
            let nearby = CalculationsLogic.filterAirportsInRange(
                airports: airports,
                userCoord: loc,
                maxRangeNauticalMiles: 50.0
            )
            lines.append("🛫 Nearby: \(nearby.count)")
        }

        // Pad each line with a small left margin
        statusLabel.text = lines.map { "  \($0)  " }.joined(separator: "\n")
    }
}

// MARK: - ARSCNViewDelegate

extension ARTrafficViewController: ARSCNViewDelegate {

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("AR Session failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        print("AR Session interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        print("AR Session resumed")
        startARSession()
    }
}

// MARK: - CLLocationManagerDelegate

extension ARTrafficViewController: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        userLocation = location.coordinate
        userAltitude = location.altitude * CalculationsLogic.metersToFeet
        connectionLogic.updateLocation(location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        userHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
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
