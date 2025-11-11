//
//  ConnectionLogic.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Handles connection to Sentri (ForeFlight) ADS-B receiver
//  Receives and parses traffic data in GDL 90 format
//

import Foundation
import Network
import CoreLocation
import Combine

/// Data source for aircraft information
enum AircraftSource {
    case adsb      // From local ADS-B receiver (Sentri)
    case internet  // From adsb.lol API
}

/// Represents an aircraft detected by ADS-B
struct Aircraft: Identifiable {
    let id: String // ICAO address
    var callsign: String
    var latitude: Double
    var longitude: Double
    var altitude: Double // in feet MSL
    var track: Double // true track in degrees
    var groundSpeed: Double // in knots
    var verticalRate: Double // in feet per minute
    var lastUpdate: Date
    var source: AircraftSource = .adsb // Data source (default to ADS-B)

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Connection status for the ADS-B receiver
enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// Handles connection and data reception from Sentri ADS-B receiver and internet sources
class ConnectionLogic: ObservableObject {

    // MARK: - Published Properties

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var detectedAircraft: [String: Aircraft] = [:] // Key: ICAO address
    @Published var ownshipData: Aircraft?
    @Published var isInternetAvailable: Bool = false
    @Published var internetAircraftCount: Int = 0

    // MARK: - Private Properties

    // ADS-B Connection
    private var connection: NWConnection?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.tallyoh.adsb", qos: .userInitiated)

    // Sentri typically broadcasts on these ports
    // GDL 90 protocol uses UDP port 4000 or TCP port 2000
    private let defaultHost = "192.168.10.1" // Typical Sentri IP
    private let defaultPort: UInt16 = 4000

    // Internet Data
    private let adsbLolClient = ADSBLolClient()
    private let networkReachability = NetworkReachability()
    private var internetFetchTimer: Timer?
    private let internetFetchInterval: TimeInterval = 10.0 // Fetch every 10 seconds

    // User location for internet queries
    private var currentLocation: CLLocationCoordinate2D?
    private let internetQueryRadius: Double = 50.0 // 50 NM radius

    // Aircraft timeout - remove if not seen for 60 seconds
    private let aircraftTimeout: TimeInterval = 60.0
    private var cleanupTimer: Timer?

    // MARK: - Initialization

    init() {
        setupCleanupTimer()
        setupNetworkMonitoring()
    }

    deinit {
        disconnect()
        cleanupTimer?.invalidate()
        internetFetchTimer?.invalidate()
        networkReachability.stopMonitoring()
    }

    // MARK: - Public Methods

    /// Connect to Sentri ADS-B receiver
    func connect(host: String? = nil, port: UInt16? = nil) {
        let targetHost = host ?? defaultHost
        let targetPort = port ?? defaultPort

        connectionStatus = .connecting

        // Create UDP connection
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: targetPort)!
        )

        connection = NWConnection(
            to: endpoint,
            using: .udp
        )

        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleConnectionState(state)
            }
        }

        startReceiving()
        connection?.start(queue: queue)
    }

    /// Disconnect from ADS-B receiver
    func disconnect() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil

        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = .disconnected
            self?.detectedAircraft.removeAll()
            self?.ownshipData = nil
        }
    }

    /// Manually add test aircraft for development/testing
    func addTestAircraft() {
        guard let userLocation = currentLocation else {
            print("Cannot add test aircraft: User location not available yet")
            return
        }

        // Add multiple test aircraft around the user's position
        let testAircraftData: [(id: String, callsign: String, latOffset: Double, lonOffset: Double, altitude: Double, track: Double)] = [
            ("TEST01", "N12345", 0.005, 0.005, 1000, 270),    // ~500m NE, 1000ft above
            ("TEST02", "N67890", -0.005, 0.005, 1500, 180),   // ~500m SE, 1500ft above
            ("TEST03", "UAL123", 0.01, -0.01, 2000, 90),      // ~1km NW, 2000ft above
            ("TEST04", "DAL456", -0.01, -0.01, 500, 45),      // ~1km SW, 500ft above
        ]

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            for data in testAircraftData {
                let aircraft = Aircraft(
                    id: data.id,
                    callsign: data.callsign,
                    latitude: userLocation.latitude + data.latOffset,
                    longitude: userLocation.longitude + data.lonOffset,
                    altitude: data.altitude,
                    track: data.track,
                    groundSpeed: 120,
                    verticalRate: 0,
                    lastUpdate: Date(),
                    source: .adsb
                )
                self.detectedAircraft[aircraft.id] = aircraft
            }

            print("Added \(testAircraftData.count) test aircraft near user location")
        }
    }

    /// Update user location for internet queries
    func updateLocation(_ location: CLLocationCoordinate2D) {
        currentLocation = location

        // Start internet fetching if not already started and internet is available
        if isInternetAvailable && internetFetchTimer == nil {
            startInternetFetching()
        }
    }

    // MARK: - Private Methods

    /// Setup network monitoring
    private func setupNetworkMonitoring() {
        networkReachability.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.isInternetAvailable = isConnected

                if isConnected {
                    print("🌐 Internet available - starting adsb.lol data fetching")
                    self?.startInternetFetching()
                } else {
                    print("🌐 Internet unavailable - stopping adsb.lol data fetching")
                    self?.stopInternetFetching()
                }
            }
            .store(in: &cancellables)
    }

    /// Start fetching data from internet
    private func startInternetFetching() {
        guard internetFetchTimer == nil, currentLocation != nil else {
            return
        }

        // Fetch immediately
        fetchInternetData()

        // Setup timer for periodic fetching
        internetFetchTimer = Timer.scheduledTimer(
            withTimeInterval: internetFetchInterval,
            repeats: true
        ) { [weak self] _ in
            self?.fetchInternetData()
        }
    }

    /// Stop fetching data from internet
    private func stopInternetFetching() {
        internetFetchTimer?.invalidate()
        internetFetchTimer = nil

        // Remove internet-sourced aircraft
        DispatchQueue.main.async { [weak self] in
            self?.detectedAircraft = self?.detectedAircraft.filter { _, aircraft in
                aircraft.source == .adsb
            } ?? [:]
            self?.internetAircraftCount = 0
        }
    }

    /// Fetch aircraft data from internet
    private func fetchInternetData() {
        guard let location = currentLocation else { return }

        adsbLolClient.fetchAircraft(
            latitude: location.latitude,
            longitude: location.longitude,
            radiusNM: internetQueryRadius
        ) { [weak self] result in
            switch result {
            case .success(let aircraft):
                self?.mergeInternetAircraft(aircraft)

            case .failure(let error):
                print("⚠️ Failed to fetch internet aircraft data: \(error.localizedDescription)")
            }
        }
    }

    /// Merge internet aircraft data with ADS-B data (ADS-B has priority)
    private func mergeInternetAircraft(_ internetAircraft: [Aircraft]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            var internetCount = 0

            for aircraft in internetAircraft {
                // Check if we already have this aircraft from ADS-B
                if let existing = self.detectedAircraft[aircraft.id] {
                    // If existing aircraft is from ADS-B, keep it (ADS-B has priority)
                    if existing.source == .adsb {
                        continue
                    }
                }

                // Add or update internet aircraft
                self.detectedAircraft[aircraft.id] = aircraft
                internetCount += 1
            }

            self.internetAircraftCount = internetCount

            if internetCount > 0 {
                print("🌐 Added/updated \(internetCount) aircraft from adsb.lol")
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionStatus = .connected
            print("✓ Connected to Sentri ADS-B receiver")

        case .waiting(let error):
            connectionStatus = .error("Waiting: \(error.localizedDescription)")
            print("⚠ Waiting for connection: \(error)")

        case .failed(let error):
            connectionStatus = .error("Failed: \(error.localizedDescription)")
            print("✗ Connection failed: \(error)")

        case .cancelled:
            connectionStatus = .disconnected
            print("✗ Connection cancelled")

        default:
            break
        }
    }

    private func startReceiving() {
        connection?.receiveMessage { [weak self] data, context, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processGDL90Data(data)
            }

            if let error = error {
                print("Receive error: \(error)")
                DispatchQueue.main.async {
                    self?.connectionStatus = .error(error.localizedDescription)
                }
            } else {
                // Continue receiving
                self?.startReceiving()
            }
        }
    }

    private func processGDL90Data(_ data: Data) {
        // GDL 90 message format:
        // 0x7E (flag byte) + Message ID + Data + FCS + 0x7E (flag byte)

        guard data.count >= 5 else { return }

        // Remove flag bytes
        var messageData = data
        if messageData.first == 0x7E {
            messageData.removeFirst()
        }
        if messageData.last == 0x7E {
            messageData.removeLast()
        }

        guard let messageType = messageData.first else { return }

        switch messageType {
        case 0x00: // Heartbeat
            break

        case 0x0A: // Ownship Report
            if let aircraft = parseTrafficReport(messageData, isOwnship: true) {
                DispatchQueue.main.async { [weak self] in
                    self?.ownshipData = aircraft
                }
            }

        case 0x14: // Traffic Report
            if let aircraft = parseTrafficReport(messageData, isOwnship: false) {
                DispatchQueue.main.async { [weak self] in
                    self?.detectedAircraft[aircraft.id] = aircraft
                }
            }

        case 0x0B: // Ownship Geometric Altitude
            break

        default:
            break
        }
    }

    private func parseTrafficReport(_ data: Data, isOwnship: Bool) -> Aircraft? {
        // GDL 90 Traffic Report format (simplified)
        // This is a basic implementation - full GDL 90 parsing is complex

        guard data.count >= 28 else { return nil }

        var index = 1 // Skip message type

        // Status byte
        _ = data[index] // Status byte (unused in basic implementation)
        index += 1

        // Address Type and Address (3 bytes)
        _ = data[index] // Address type (unused in basic implementation)
        index += 1

        let icaoAddress = String(format: "%02X%02X%02X",
                                data[index], data[index + 1], data[index + 2])
        index += 3

        // Latitude (3 bytes, two's complement)
        let latBytes = [UInt8](data[index..<index+3])
        let latRaw = Int32(latBytes[0]) << 16 | Int32(latBytes[1]) << 8 | Int32(latBytes[2])
        let latitude = Double(latRaw) * (180.0 / 8388608.0)
        index += 3

        // Longitude (3 bytes, two's complement)
        let lonBytes = [UInt8](data[index..<index+3])
        let lonRaw = Int32(lonBytes[0]) << 16 | Int32(lonBytes[1]) << 8 | Int32(lonBytes[2])
        let longitude = Double(lonRaw) * (180.0 / 8388608.0)
        index += 3

        // Altitude (12 bits)
        let altRaw = (UInt16(data[index]) << 4) | (UInt16(data[index + 1]) >> 4)
        let altitude = Double(altRaw) * 25.0 - 1000.0 // 25 ft resolution, -1000 ft offset
        index += 2

        // Misc indicator byte
        index += 1

        // NIC (Navigation Integrity Category)
        index += 1

        // NACp (Navigation Accuracy Category - Position)
        index += 1

        // Horizontal velocity (12 bits)
        let hvBytes = [UInt8](data[index..<index+2])
        let hvRaw = (UInt16(hvBytes[0]) << 4) | (UInt16(hvBytes[1]) >> 4)
        let groundSpeed = Double(hvRaw)
        index += 1

        // Vertical velocity (12 bits, in 64 fpm increments)
        let vvByte1 = UInt16(data[index]) & 0x0F
        let vvByte2 = UInt16(data[index + 1])
        let vvRaw = (vvByte1 << 8) | vvByte2
        let verticalRate = Double(Int16(bitPattern: vvRaw)) * 64.0
        index += 2

        // Track/Heading
        let trackRaw = data[index]
        let track = Double(trackRaw) * (360.0 / 256.0)

        // Extract callsign if available (simplified)
        let callsign = isOwnship ? "OWNSHIP" : "N\(icaoAddress)"

        return Aircraft(
            id: icaoAddress,
            callsign: callsign,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            track: track,
            groundSpeed: groundSpeed,
            verticalRate: verticalRate,
            lastUpdate: Date(),
            source: .adsb
        )
    }

    private func setupCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.cleanupOldAircraft()
        }
    }

    private func cleanupOldAircraft() {
        let now = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.detectedAircraft = self.detectedAircraft.filter { _, aircraft in
                now.timeIntervalSince(aircraft.lastUpdate) < self.aircraftTimeout
            }
        }
    }
}
