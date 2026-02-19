//
//  ConnectionLogic.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Handles ADS-B reception from ForeFlight Sentry (and compatible devices)
//  and internet aircraft data from adsb.lol.
//
//  ADS-B note: Sentry BROADCASTS GDL 90 UDP packets to the local network on
//  port 4000. We must LISTEN on that port — not connect outbound to the device.
//  A UDP NWConnection to a remote host transitions to .ready immediately
//  regardless of whether the device is present, giving a false "connected" status.
//

import Foundation
import Network
import CoreLocation
import Combine

// MARK: - Enums

enum AircraftSource {
    case adsb
    case internet
}

enum ConnectionStatus {
    case searching      // listener is up, waiting for first packet
    case receiving      // actively receiving ADS-B packets
    case notAvailable   // listener failed to start
    case disconnected
}

// MARK: - Aircraft

struct Aircraft: Identifiable {
    let id: String
    var callsign: String
    var aircraftType: String = ""
    var latitude: Double
    var longitude: Double
    var altitude: Double       // feet MSL
    var track: Double          // degrees true
    var groundSpeed: Double    // knots
    var verticalRate: Double   // feet per minute
    var lastUpdate: Date
    var source: AircraftSource = .adsb

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - ConnectionLogic

class ConnectionLogic: ObservableObject {

    // MARK: Published

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var detectedAircraft: [String: Aircraft] = [:]
    @Published var ownshipData: Aircraft?           // GPS/altitude from ADS-B ownship report
    @Published var isInternetAvailable: Bool = false
    @Published var internetAircraftCount: Int = 0

    // MARK: Private — ADS-B listener

    private var listener: NWListener?
    private let adsbQueue = DispatchQueue(label: "com.tallyoh.adsb", qos: .userInitiated)
    private let adsbPort: NWEndpoint.Port = 4000

    /// Time of last received GDL90 packet — used to detect signal loss
    private var lastPacketReceived: Date?
    private var signalWatchdogTimer: Timer?

    // MARK: Private — Internet

    private let adsbLolClient = ADSBLolClient()
    private let networkReachability = NetworkReachability()
    private var internetFetchTimer: Timer?
    private let internetFetchInterval: TimeInterval = 10.0
    private var currentLocation: CLLocationCoordinate2D?
    private let internetQueryRadius: Double = 50.0

    // MARK: Private — Cleanup

    private let aircraftTimeout: TimeInterval = 60.0
    private var cleanupTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init() {
        setupNetworkMonitoring()
        setupCleanupTimer()
        setupSignalWatchdog()
    }

    deinit {
        stopListening()
        cleanupTimer?.invalidate()
        internetFetchTimer?.invalidate()
        signalWatchdogTimer?.invalidate()
        networkReachability.stopMonitoring()
    }

    // MARK: - Public

    /// Start listening for ADS-B broadcasts. Called once on app launch.
    func startListening() {
        guard listener == nil else { return }

        do {
            listener = try NWListener(using: .udp, on: adsbPort)
        } catch {
            print("❌ Failed to create ADS-B listener: \(error)")
            DispatchQueue.main.async { self.connectionStatus = .notAvailable }
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.adsbQueue ?? .global())
            self?.receiveFrom(conn)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("📡 ADS-B listener ready on port 4000")
                    self?.connectionStatus = .searching
                case .failed(let err):
                    print("❌ ADS-B listener failed: \(err)")
                    self?.connectionStatus = .notAvailable
                default:
                    break
                }
            }
        }

        listener?.start(queue: adsbQueue)
        DispatchQueue.main.async { self.connectionStatus = .searching }
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.connectionStatus = .disconnected
            self.detectedAircraft.removeAll()
            self.ownshipData = nil
        }
    }

    func updateLocation(_ location: CLLocationCoordinate2D) {
        currentLocation = location
        // Kick off internet fetching now that we have a location, if not already running
        if isInternetAvailable {
            ensureInternetFetchRunning()
        }
    }

    func addTestAircraft() {
        let test = Aircraft(
            id: "TEST01",
            callsign: "N12345",
            aircraftType: "C172",
            latitude: (currentLocation?.latitude ?? 37.7749) + 0.05,
            longitude: (currentLocation?.longitude ?? -122.4194) + 0.05,
            altitude: 5500,
            track: 270,
            groundSpeed: 120,
            verticalRate: 0,
            lastUpdate: Date(),
            source: .internet
        )
        DispatchQueue.main.async { self.detectedAircraft[test.id] = test }
    }

    // MARK: - Private — ADS-B

    private func receiveFrom(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                self?.processGDL90Data(data)
                DispatchQueue.main.async {
                    self?.lastPacketReceived = Date()
                    if self?.connectionStatus != .receiving {
                        self?.connectionStatus = .receiving
                        print("✅ ADS-B signal acquired")
                    }
                }
            }
            if error == nil {
                self?.receiveFrom(conn)   // keep receiving
            }
        }
    }

    /// Watchdog: if no packet received in 10 s, drop back to .searching
    private func setupSignalWatchdog() {
        signalWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.connectionStatus == .receiving else { return }
            if let last = self.lastPacketReceived, Date().timeIntervalSince(last) > 10.0 {
                DispatchQueue.main.async {
                    self.connectionStatus = .searching
                    print("⚠️ ADS-B signal lost")
                }
            }
        }
    }

    private func processGDL90Data(_ data: Data) {
        // Scan for 0x7E frame boundaries — a UDP packet may contain multiple messages
        var bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x7E else { i += 1; continue }
            // Find closing flag
            if let end = bytes[(i+1)...].firstIndex(of: 0x7E) {
                let payload = Array(bytes[(i+1)..<end])
                handleGDL90Message(payload)
                i = end + 1
            } else {
                break
            }
        }
    }

    private func handleGDL90Message(_ payload: [UInt8]) {
        guard let msgType = payload.first else { return }
        switch msgType {
        case 0x00: break  // Heartbeat
        case 0x0A:        // Ownship
            if let ac = parseTrafficPayload(payload, isOwnship: true) {
                DispatchQueue.main.async { self.ownshipData = ac }
            }
        case 0x14:        // Traffic
            if let ac = parseTrafficPayload(payload, isOwnship: false) {
                DispatchQueue.main.async { self.detectedAircraft[ac.id] = ac }
            }
        case 0x0B: break  // Ownship geometric alt (parsed inside ownship if needed)
        default: break
        }
    }

    private func parseTrafficPayload(_ payload: [UInt8], isOwnship: Bool) -> Aircraft? {
        // GDL 90 traffic report: 28 bytes after framing stripped
        guard payload.count >= 28 else { return nil }

        var i = 1 // skip message ID byte

        // Status (1 byte)
        i += 1
        // Address type (1 byte) + ICAO (3 bytes)
        i += 1
        guard i + 3 <= payload.count else { return nil }
        let icao = String(format: "%02X%02X%02X", payload[i], payload[i+1], payload[i+2])
        i += 3

        // Latitude (3 bytes, two's complement, semicircles)
        guard i + 3 <= payload.count else { return nil }
        var latRaw = Int32(payload[i]) << 16 | Int32(payload[i+1]) << 8 | Int32(payload[i+2])
        if latRaw & 0x800000 != 0 { latRaw |= Int32(bitPattern: 0xFF000000) }
        let latitude = Double(latRaw) * (180.0 / 8_388_608.0)
        i += 3

        // Longitude (3 bytes, two's complement)
        guard i + 3 <= payload.count else { return nil }
        var lonRaw = Int32(payload[i]) << 16 | Int32(payload[i+1]) << 8 | Int32(payload[i+2])
        if lonRaw & 0x800000 != 0 { lonRaw |= Int32(bitPattern: 0xFF000000) }
        let longitude = Double(lonRaw) * (180.0 / 8_388_608.0)
        i += 3

        // Altitude: upper 12 bits of next 2 bytes, 25 ft resolution, -1000 ft offset
        guard i + 2 <= payload.count else { return nil }
        let altCode = (UInt16(payload[i]) << 4) | (UInt16(payload[i+1]) >> 4)
        let altitude = altCode == 0xFFF ? 0.0 : Double(altCode) * 25.0 - 1000.0
        i += 2

        // Misc (1), NIC (1), NACp (1)
        i += 3

        // Horizontal velocity: upper 12 bits of next 2 bytes (knots)
        guard i + 2 <= payload.count else { return nil }
        let hvCode = (UInt16(payload[i]) << 4) | (UInt16(payload[i+1]) >> 4)
        let groundSpeed = hvCode == 0xFFF ? 0.0 : Double(hvCode)
        i += 1   // only advance 1 — vv shares the lower nibble

        // Vertical velocity: lower nibble of byte at i, then full byte at i+1
        guard i + 2 <= payload.count else { return nil }
        let vvRaw = (Int16(payload[i] & 0x0F) << 8) | Int16(payload[i+1])
        let vvSigned = vvRaw > 2047 ? vvRaw - 4096 : vvRaw
        let verticalRate = Double(vvSigned) * 64.0
        i += 2

        // Track (1 byte, 0–255 maps to 0–360°)
        guard i < payload.count else { return nil }
        let track = Double(payload[i]) * (360.0 / 256.0)
        i += 1

        // Emitter category (1 byte)
        i += 1

        // Callsign: up to 8 ASCII chars
        var callsign = icao
        if !isOwnship, i + 8 <= payload.count {
            let raw = String(bytes: payload[i..<(i+8)], encoding: .ascii) ?? ""
            let trimmed = raw.trimmingCharacters(in: .init(charactersIn: " \0"))
            if !trimmed.isEmpty { callsign = trimmed }
        }

        return Aircraft(
            id: isOwnship ? "OWNSHIP" : icao,
            callsign: isOwnship ? "OWNSHIP" : callsign,
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

    // MARK: - Private — Internet

    private func setupNetworkMonitoring() {
        networkReachability.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isInternetAvailable = connected
                if connected {
                    self?.ensureInternetFetchRunning()
                } else {
                    self?.stopInternetFetching()
                }
            }
            .store(in: &cancellables)
    }

    private func ensureInternetFetchRunning() {
        guard currentLocation != nil else { return }
        guard internetFetchTimer == nil else { return }
        fetchInternetData()
        internetFetchTimer = Timer.scheduledTimer(withTimeInterval: internetFetchInterval, repeats: true) { [weak self] _ in
            self?.fetchInternetData()
        }
    }

    private func stopInternetFetching() {
        internetFetchTimer?.invalidate()
        internetFetchTimer = nil
        DispatchQueue.main.async {
            self.detectedAircraft = self.detectedAircraft.filter { $0.value.source == .adsb }
            self.internetAircraftCount = 0
        }
    }

    private func fetchInternetData() {
        guard let loc = currentLocation else { return }
        adsbLolClient.fetchAircraft(
            latitude: loc.latitude,
            longitude: loc.longitude,
            radiusNM: internetQueryRadius
        ) { [weak self] result in
            switch result {
            case .success(let aircraft):
                self?.mergeInternetAircraft(aircraft)
            case .failure(let err):
                print("⚠️ adsb.lol fetch failed: \(err.localizedDescription)")
            }
        }
    }

    private func mergeInternetAircraft(_ list: [Aircraft]) {
        DispatchQueue.main.async {
            var count = 0
            for ac in list {
                if let existing = self.detectedAircraft[ac.id], existing.source == .adsb { continue }
                self.detectedAircraft[ac.id] = ac
                count += 1
            }
            self.internetAircraftCount = count
        }
    }

    // MARK: - Private — Cleanup

    private func setupCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let cutoff = Date().addingTimeInterval(-self.aircraftTimeout)
            DispatchQueue.main.async {
                self.detectedAircraft = self.detectedAircraft.filter { $0.value.lastUpdate > cutoff }
            }
        }
    }
}
