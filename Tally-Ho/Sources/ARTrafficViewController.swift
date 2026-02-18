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
import Combine

class ARTrafficViewController: UIViewController {

    // MARK: - UI Components

    private var arSceneView: ARSCNView!
    private var statusLabel: UILabel!
    private var connectionButton: UIButton!
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
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arSceneView.session.pause()
        updateTimer?.invalidate()
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
        // Load airports from CSV
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let airports = AirportDataParser.loadAirportsFromCSV() {
                self?.airports = airports
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
        let alert = UIAlertController(
            title: "Settings",
            message: "Configure AR visualization settings",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Toggle Aircraft", style: .default) { [weak self] _ in
            self?.sceneManager?.settings.showAircraft.toggle()
        })

        alert.addAction(UIAlertAction(title: "Toggle Airports", style: .default) { [weak self] _ in
            self?.sceneManager?.settings.showAirports.toggle()
        })

        alert.addAction(UIAlertAction(title: "Add Test Aircraft", style: .default) { [weak self] _ in
            self?.connectionLogic.addTestAircraft()
        })

        alert.addAction(UIAlertAction(title: "Clear All", style: .destructive) { [weak self] _ in
            self?.sceneManager?.clearAll()
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        present(alert, animated: true)
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
        userHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
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

