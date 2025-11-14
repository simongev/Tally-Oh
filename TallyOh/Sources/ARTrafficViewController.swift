//
//  ARTrafficViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Main view controller that integrates:
//  - ConnectionLogic for ADS-B data
//  - CalculationsLogic for positioning
//  - MainAppComponents for visualization
//

import UIKit
import ARKit
import CoreLocation

class ARTrafficViewController: UIViewController {

    // MARK: - UI Components

    private var arSceneView: ARSCNView!
    private var statusLabel: UILabel!
    private var connectionButton: UIButton!
    private var settingsButton: UIButton!
    private var debugButton: UIButton!
    private var debugConsoleView: DebugConsoleView?

    // MARK: - Core Components

    private var connectionLogic = ConnectionLogic()
    private var sceneManager: ARSceneManager?
    private var locationManager = CLLocationManager()

    // MARK: - State

    private var airports: [Airport] = []
    private var userLocation: CLLocationCoordinate2D?
    private var userAltitude: Double = 0
    private var userHeading: Double = 0
    private var smoothedHeading: Double = 0 // Smoothed heading to prevent jittery updates
    private let headingChangeThreshold: Double = 2.0 // Degrees - only update if change > threshold

    private var updateTimer: Timer?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        setupARScene()
        setupLocation()
        setupObservers()
        loadAirports()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startARSession()

        // Disable screen auto-lock while app is in foreground
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arSceneView.session.pause()
        updateTimer?.invalidate()

        // Re-enable screen auto-lock when leaving
        UIApplication.shared.isIdleTimerDisabled = false
    }

    deinit {
        connectionLogic.disconnect()
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .black

        // AR Scene View
        arSceneView = ARSCNView(frame: view.bounds)
        arSceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arSceneView)

        // Status Label
        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        statusLabel.textColor = .white
        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.text = "Initializing..."
        statusLabel.layer.cornerRadius = 8
        statusLabel.clipsToBounds = true
        statusLabel.textAlignment = .left
        statusLabel.isUserInteractionEnabled = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])

        // Connection Button
        connectionButton = UIButton(type: .system)
        connectionButton.translatesAutoresizingMaskIntoConstraints = false
        connectionButton.setTitle("Connect to Sentri", for: .normal)
        connectionButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
        connectionButton.setTitleColor(.white, for: .normal)
        connectionButton.layer.cornerRadius = 8
        connectionButton.addTarget(self, action: #selector(toggleConnection), for: .touchUpInside)
        view.addSubview(connectionButton)

        NSLayoutConstraint.activate([
            connectionButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            connectionButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectionButton.widthAnchor.constraint(equalToConstant: 200),
            connectionButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Settings Button
        settingsButton = UIButton(type: .system)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setTitle("⚙️", for: .normal)
        settingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 24)
        settingsButton.backgroundColor = UIColor.gray.withAlphaComponent(0.8)
        settingsButton.layer.cornerRadius = 22
        settingsButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        view.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            settingsButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            settingsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            settingsButton.widthAnchor.constraint(equalToConstant: 44),
            settingsButton.heightAnchor.constraint(equalToConstant: 44)
        ])

        // Debug Button
        debugButton = UIButton(type: .system)
        debugButton.translatesAutoresizingMaskIntoConstraints = false
        debugButton.setTitle("🐛", for: .normal)
        debugButton.titleLabel?.font = UIFont.systemFont(ofSize: 24)
        debugButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8)
        debugButton.layer.cornerRadius = 22
        debugButton.addTarget(self, action: #selector(toggleDebugConsole), for: .touchUpInside)
        view.addSubview(debugButton)

        NSLayoutConstraint.activate([
            debugButton.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -8),
            debugButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            debugButton.widthAnchor.constraint(equalToConstant: 44),
            debugButton.heightAnchor.constraint(equalToConstant: 44)
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
        // Observe connection status changes
        connectionLogic.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateConnectionStatus(status)
            }
            .store(in: &cancellables)

        // Observe settings changes to refresh AR visualization
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .settingsDidChange,
            object: nil
        )

        // Start update timer
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            self?.updateVisualization()
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private func loadAirports() {
        // Load all airports from CSV - filtering is now done in settings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let allAirports = AirportDataParser.loadAirportsFromCSV() {
                self?.airports = allAirports
                print("✓ Loaded \(allAirports.count) airports (filtering handled by user settings)")
                DispatchQueue.main.async {
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

        // Configure camera clipping planes for far object visibility
        // Default far plane is ~100m which is too close for aviation
        if let camera = arSceneView.pointOfView?.camera {
            camera.zNear = 0.1 // 10cm minimum
            camera.zFar = 50000.0 // 50km maximum - much farther than default
            let msg = "📷 AR Camera configured: zNear=\(camera.zNear)m, zFar=\(camera.zFar)m"
            print(msg)
            DebugConsole.shared.log(msg)
        } else {
            let msg = "⚠️  Could not configure AR camera clipping planes"
            print(msg)
            DebugConsole.shared.log(msg)
        }
    }

    // MARK: - Actions

    @objc private func toggleConnection() {
        switch connectionLogic.connectionStatus {
        case .disconnected, .error:
            connectionLogic.connect()

        case .connected:
            connectionLogic.disconnect()

        case .connecting:
            break
        }
    }

    @objc private func showSettings() {
        let settingsVC = SettingsViewController()
        let navController = UINavigationController(rootViewController: settingsVC)
        present(navController, animated: true)
    }

    @objc private func toggleDebugConsole() {
        if let debugConsole = debugConsoleView {
            // Hide console
            UIView.animate(withDuration: 0.3, animations: {
                debugConsole.alpha = 0
            }) { _ in
                debugConsole.removeFromSuperview()
                self.debugConsoleView = nil
            }
        } else {
            // Show console
            let console = DebugConsoleView(frame: .zero)
            console.translatesAutoresizingMaskIntoConstraints = false
            console.alpha = 0
            console.onClose = { [weak self] in
                self?.toggleDebugConsole()
            }

            view.addSubview(console)

            NSLayoutConstraint.activate([
                console.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                console.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                console.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
                console.bottomAnchor.constraint(equalTo: connectionButton.topAnchor, constant: -16)
            ])

            debugConsoleView = console

            UIView.animate(withDuration: 0.3) {
                console.alpha = 1
            }

            DebugConsole.shared.log("✅ Debug console opened")
        }
    }

    @objc private func settingsDidChange() {
        // Force immediate update of AR visualization when settings change
        // This will cause all nodes to be recreated with new settings
        sceneManager?.forceFullRefresh()
        updateVisualization()
        DebugConsole.shared.log("⚙️ Settings changed - AR view refreshed")
    }

    // MARK: - Update Logic

    private func updateVisualization() {
        guard let userLocation = userLocation else { return }

        // Update aircraft
        let aircraft = Array(connectionLogic.detectedAircraft.values)
        sceneManager?.updateAircraft(
            aircraft,
            userLocation: userLocation,
            userAltitude: userAltitude,
            userHeading: userHeading
        )

        // Update airports
        sceneManager?.updateAirports(
            airports,
            userLocation: userLocation,
            userAltitude: userAltitude,
            userHeading: userHeading
        )

        updateStatusLabel()
    }

    private func updateConnectionStatus(_ status: ConnectionStatus) {
        switch status {
        case .disconnected:
            connectionButton.setTitle("Connect to Sentri", for: .normal)
            connectionButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)

        case .connecting:
            connectionButton.setTitle("Connecting...", for: .normal)
            connectionButton.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.8)

        case .connected:
            connectionButton.setTitle("Disconnect", for: .normal)
            connectionButton.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)

        case .error(let message):
            connectionButton.setTitle("Connect (Error)", for: .normal)
            connectionButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
            print("Connection error: \(message)")
        }

        updateStatusLabel()
    }

    private func updateStatusLabel() {
        var status = ""

        // Connection status
        switch connectionLogic.connectionStatus {
        case .connected:
            status += "📡 Connected to Sentri\n"
        case .connecting:
            status += "📡 Connecting...\n"
        case .disconnected:
            status += "📡 Disconnected\n"
        case .error(let msg):
            status += "📡 Error: \(msg)\n"
        }

        // Internet status
        if connectionLogic.isInternetAvailable {
            status += "🌐 Internet: Online\n"
        } else {
            status += "🌐 Internet: Offline\n"
        }

        // Location status
        if let loc = userLocation {
            status += String(format: "📍 %.4f°, %.4f°\n", loc.latitude, loc.longitude)
            status += String(format: "✈️ %.0f ft MSL\n", userAltitude)
            status += String(format: "🧭 %.0f°\n", userHeading)
        } else {
            status += "📍 Waiting for GPS...\n"
        }

        // Aircraft count with data sources
        let totalAircraft = connectionLogic.detectedAircraft.count
        let adsbCount = connectionLogic.detectedAircraft.values.filter { $0.source == .adsb }.count
        let internetCount = connectionLogic.internetAircraftCount

        status += "🛩 Aircraft: \(totalAircraft) "
        if adsbCount > 0 {
            status += "(ADS-B: \(adsbCount)"
            if internetCount > 0 {
                status += ", Internet: \(internetCount)"
            }
            status += ")\n"
        } else if internetCount > 0 {
            status += "(Internet: \(internetCount))\n"
        } else {
            status += "\n"
        }

        // Airport count
        status += "🛫 Airports loaded: \(airports.count)\n"

        // Nearby airports
        if let loc = userLocation {
            let nearby = CalculationsLogic.filterAirportsInRange(
                airports: airports,
                userCoord: loc,
                maxRangeNauticalMiles: 20.0
            )
            status += "🛫 Nearby airports: \(nearby.count)"
        }

        statusLabel.text = status
    }
}

// MARK: - ARSCNViewDelegate

extension ARTrafficViewController: ARSCNViewDelegate {

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // Called every frame
        // Ensure camera clipping planes are set (in case they weren't ready at session start)
        if let camera = arSceneView.pointOfView?.camera {
            if camera.zFar < 10000 {
                camera.zFar = 50000.0
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("AR Session failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        print("AR Session was interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        print("AR Session interruption ended")
        startARSession()
    }
}

// MARK: - CLLocationManagerDelegate

extension ARTrafficViewController: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        userLocation = location.coordinate
        userAltitude = location.altitude * CalculationsLogic.metersToFeet

        // Update connection logic with location for internet data fetching
        connectionLogic.updateLocation(location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let rawHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading

        // Initialize smoothed heading on first update
        if smoothedHeading == 0 {
            smoothedHeading = rawHeading
            userHeading = rawHeading
            return
        }

        // Calculate heading difference (accounting for 0/360 wraparound)
        var headingDiff = rawHeading - smoothedHeading
        if headingDiff > 180 {
            headingDiff -= 360
        } else if headingDiff < -180 {
            headingDiff += 360
        }

        // Only update if change exceeds threshold to prevent jittery AR updates
        if abs(headingDiff) > headingChangeThreshold {
            // Apply exponential smoothing for gradual transitions
            let alpha = 0.3 // Smoothing factor (0 = no change, 1 = instant change)
            smoothedHeading = smoothedHeading + (headingDiff * alpha)

            // Normalize to 0-360 range
            if smoothedHeading < 0 {
                smoothedHeading += 360
            } else if smoothedHeading >= 360 {
                smoothedHeading -= 360
            }

            userHeading = smoothedHeading

            DebugConsole.shared.log("🧭 Heading: \(Int(userHeading))° (raw: \(Int(rawHeading))°)")
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
            locationManager.startUpdatingHeading()

        case .denied, .restricted:
            let alert = UIAlertController(
                title: "Location Access Required",
                message: "TallyOh needs location access to show traffic around you.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)

        default:
            break
        }
    }
}

// MARK: - Combine Import

import Combine
