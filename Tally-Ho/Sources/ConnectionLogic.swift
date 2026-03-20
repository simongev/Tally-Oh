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

    // Diagnostic counters — read by the status label via adsbStats
    var _heartbeatCount  = 0
    var _ownshipCount    = 0
    var _trafficCount    = 0
    var _trafficFailed   = 0
    /// Hex dump of the very first raw bytes received (shown in status label)
    var _firstPacketHex  = ""
    var _packetCount     = 0
    /// How many received packets contain 7E+known MSG_ID anywhere in the raw bytes.
    /// If these are 0 after many packets, the Sentry isn't sending standard GDL90.
    var _sigHB  = 0   // packets containing 7E 00
    var _sigOWN = 0   // packets containing 7E 0A
    var _sigTR  = 0   // packets containing 7E 14

    // MARK: Private — Internet

    private let adsbLolClient = ADSBLolClient()
    private let networkReachability = NetworkReachability()
    private var internetFetchTimer: Timer?
    /// How many consecutive adsb.lol fetches have failed. After a threshold we treat
    /// the path as having no real internet (e.g. phone joined a Sentry WiFi hotspot
    /// that provides no internet — NWPathMonitor reports the WiFi link as satisfied even
    /// though api.adsb.lol is unreachable). Resets to 0 on any successful fetch or when
    /// NWPathMonitor triggers ensureInternetFetchRunning() after a path change.
    private var consecutiveInternetFailures = 0
    private let maxInternetFailuresBeforeOffline = 3
    // At 250 kt the user moves ~1.0 NM in 8 s — fetch frequently enough to
    // keep the traffic picture current as the aircraft flies.
    private let internetFetchInterval: TimeInterval = 8.0
    private var currentLocation: CLLocationCoordinate2D?

    /// Query radius for the internet fetch.  Kept in sync with the scene manager's
    /// aircraftMaxDistance (set via updateInternetQueryRadius) so we never fetch a
    /// much larger bubble than we can display — avoids storing thousands of aircraft
    /// in detectedAircraft when only ~200 within 20 NM will ever be rendered.
    private var internetQueryRadius: Double = 25.0

    /// Called by ARSceneManager whenever aircraftMaxDistance changes.
    func updateInternetQueryRadius(_ distanceNM: Double) {
        // Fetch 25 % beyond the render limit so aircraft don't pop in at the edge.
        internetQueryRadius = max(10, distanceNM * 1.25)
    }

    /// Hard cap on total internet aircraft stored.  Only 200 nodes can ever be
    /// rendered, and the closest 200 by distance are chosen, so storing more than
    /// ~100 provides no visual benefit while inflating the dictionary copied every tick.
    private let maxInternetAircraft = 100
    /// Timestamp of the most recent internet fetch request — used to compute
    /// dynamic extrapolation latency in the dead-reckoning position predictor.
    private(set) var lastInternetFetchTime: Date?

    // MARK: Private — Cleanup

    // Internet fetch runs every 8s. With a 60s timeout, a single slow fetch (network
    // spike > 60s) causes aircraft to vanish then reappear. 90s gives 11 fetch cycles
    // of slack — enough for transient connectivity hiccups without keeping stale data
    // long enough to matter.
    private let aircraftTimeout: TimeInterval = 90.0
    private var cleanupTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// One-line GDL90 diagnostic string shown in the status label while receiving.
    var adsbStats: String {
        // Parsed-frame counters (what the GDL90 parser actually processed)
        var s = "pkts:\(_packetCount) parsed HB:\(_heartbeatCount) OS:\(_ownshipCount) TR:\(_trafficCount) fail:\(_trafficFailed)"
        // Raw-byte signature counts (are standard GDL90 byte pairs present at all?)
        s += " | raw 7E00:\(_sigHB) 7E0A:\(_sigOWN) 7E14:\(_sigTR)"
        if !_firstPacketHex.isEmpty {
            s += " | first[\(_firstPacketHex)]"
        }
        return s
    }

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

    func updateLocation(_ location: CLLocationCoordinate2D, altitudeFeet: Double = 0) {
        currentLocation = location
        currentAltitudeFeet = altitudeFeet
        // Kick off internet fetching now that we have a location.
        // Check both the published flag AND the live path status so we don't
        // miss the window where NWPathMonitor hasn't fired its first callback yet.
        ensureInternetFetchRunning()
    }

    /// Last known user altitude in feet (set alongside currentLocation).
    private var currentAltitudeFeet: Double = 0

    // MARK: - Private — ADS-B

    private func receiveFrom(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                // Capture raw hex of first packet and scan all packets for GDL90 signatures
                self?._packetCount += 1
                if self?._firstPacketHex.isEmpty == true {
                    let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: "·")
                    self?._firstPacketHex = "\(data.count)b \(hex)"
                }
                // Scan raw bytes for 7E+MSG_ID pairs to see if standard GDL90 frames
                // exist anywhere in the packet, independent of the frame parser.
                var sawHB = false, sawOWN = false, sawTR = false
                for k in 0 ..< data.count - 1 where data[data.startIndex + k] == 0x7E {
                    switch data[data.startIndex + k + 1] {
                    case 0x00: sawHB  = true
                    case 0x0A: sawOWN = true
                    case 0x14: sawTR  = true
                    default: break
                    }
                }
                if sawHB  { self?._sigHB  += 1 }
                if sawOWN { self?._sigOWN += 1 }
                if sawTR  { self?._sigTR  += 1 }
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

    /// GDL90 HDLC byte unstuffing: the spec requires that 0x7E and 0x7D bytes
    /// inside a frame are escaped on the wire as 0x7D 0x5E and 0x7D 0x5D
    /// respectively.  Passing raw (stuffed) bytes to the field parser produces
    /// garbage values for any aircraft whose ICAO address, lat/lon, speed, etc.
    /// happen to contain those byte values.
    private func gdl90Unstuff(_ raw: Data.SubSequence) -> Data {
        var out = Data()
        out.reserveCapacity(raw.count)
        var j = raw.startIndex
        while j < raw.endIndex {
            let b = raw[j]
            if b == 0x7D {
                let next = raw.index(after: j)
                guard next < raw.endIndex else { break }
                out.append(raw[next] ^ 0x20)
                j = raw.index(after: next)
            } else {
                out.append(b)
                j = raw.index(after: j)
            }
        }
        return out
    }

    private func processGDL90Data(_ data: Data) {
        // Scan for 0x7E frame boundaries without copying the Data into [UInt8].
        // Iterating Data directly avoids a heap allocation per UDP packet (which
        // arrives up to ~10 times/second from an ADS-B receiver).
        var i = data.startIndex
        while i < data.endIndex {
            guard data[i] == 0x7E else { i = data.index(after: i); continue }
            let payloadStart = data.index(after: i)
            guard payloadStart < data.endIndex else { break }
            if let end = data[payloadStart...].firstIndex(of: 0x7E) {
                // Unstuff HDLC escape sequences before handing off to the field
                // parser.  The frame scanner above correctly finds the closing 0x7E
                // because byte-stuffing guarantees no raw 0x7E appears inside a
                // frame, but the field offsets are only valid on unstuffed data.
                let unstuffed = gdl90Unstuff(data[payloadStart..<end])
                handleGDL90Message(unstuffed[...])
                // Per GDL90 spec, consecutive frames share their flag byte:
                // the closing 0x7E of frame N is also the opening 0x7E of frame N+1.
                // Set i = end (not end+1) so the next iteration treats this 0x7E
                // as the start of the following frame.
                i = end
            } else {
                // No closing 0x7E found — treat the remaining bytes as the last
                // frame in this UDP datagram.  Many GDL90-over-UDP devices omit
                // the trailing flag on the final frame in a packet (the datagram
                // boundary serves as an implicit delimiter).  Without this branch
                // the last frame — typically a Traffic Report — is silently dropped.
                let unstuffed = gdl90Unstuff(data[payloadStart...])
                handleGDL90Message(unstuffed[...])
                break
            }
        }
    }

    private func handleGDL90Message(_ payload: Data.SubSequence) {
        guard let msgType = payload.first else { return }
        switch msgType {
        case 0x00:        // Heartbeat
            _heartbeatCount += 1
            if _heartbeatCount == 1 { print("[GDL90] First heartbeat received") }
        case 0x0A:        // Ownship
            _ownshipCount += 1
            if let ac = parseTrafficPayload(payload, isOwnship: true) {
                if _ownshipCount <= 3 {
                    print("[GDL90] Ownship #\(_ownshipCount): lat=\(ac.latitude) lon=\(ac.longitude) alt=\(ac.altitude)ft")
                }
                DispatchQueue.main.async { self.ownshipData = ac }
            } else {
                if _ownshipCount <= 3 { print("[GDL90] Ownship parse failed (payload len=\(payload.count))") }
            }
        case 0x14:        // Traffic
            _trafficCount += 1
            if let ac = parseTrafficPayload(payload, isOwnship: false) {
                if _trafficCount <= 5 {
                    print("[GDL90] Traffic #\(_trafficCount): \(ac.callsign) icao=\(ac.id) lat=\(ac.latitude) lon=\(ac.longitude) alt=\(ac.altitude)ft spd=\(ac.groundSpeed)kt")
                }
                DispatchQueue.main.async { self.detectedAircraft[ac.id] = ac }
            } else {
                _trafficFailed += 1
                if _trafficCount <= 5 { print("[GDL90] Traffic parse failed (payload len=\(payload.count))") }
            }
        case 0x0B: break  // Ownship geometric alt
        default: break
        }
    }

    /// Parse a GDL90 traffic/ownship payload. Operates directly on a Data.SubSequence
    /// so no heap copy is required — the indices are absolute within the original Data.
    private func parseTrafficPayload(_ payload: Data.SubSequence, isOwnship: Bool) -> Aircraft? {
        guard payload.count >= 28 else { return nil }

        // Use an index cursor relative to the slice start.
        var idx = payload.startIndex

        func advance(_ n: Int) { idx = payload.index(idx, offsetBy: n) }
        func remaining() -> Int { payload.distance(from: idx, to: payload.endIndex) }
        func byte(_ offset: Int) -> UInt8 { payload[payload.index(idx, offsetBy: offset)] }

        advance(1) // skip message ID
        advance(1) // traffic alert status (bits 7:4) | address type (bits 3:0) — single combined byte per GDL90 spec

        guard remaining() >= 3 else { return nil }
        let icao = String(format: "%02X%02X%02X", byte(0), byte(1), byte(2))
        advance(3)

        guard remaining() >= 3 else { return nil }
        var latRaw = Int32(byte(0)) << 16 | Int32(byte(1)) << 8 | Int32(byte(2))
        if latRaw & 0x800000 != 0 { latRaw |= Int32(bitPattern: 0xFF000000) }
        let latitude = Double(latRaw) * (180.0 / 8_388_608.0)
        advance(3)

        guard remaining() >= 3 else { return nil }
        var lonRaw = Int32(byte(0)) << 16 | Int32(byte(1)) << 8 | Int32(byte(2))
        if lonRaw & 0x800000 != 0 { lonRaw |= Int32(bitPattern: 0xFF000000) }
        let longitude = Double(lonRaw) * (180.0 / 8_388_608.0)
        advance(3)

        guard remaining() >= 2 else { return nil }
        let altCode = (UInt16(byte(0)) << 4) | (UInt16(byte(1)) >> 4)
        // 0xFFF means "no barometric altitude info". Use -9999 sentinel so callers
        // can distinguish "aircraft at sea level" (0 ft) from "altitude unknown".
        let altitude = altCode == 0xFFF ? -9999.0 : Double(altCode) * 25.0 - 1000.0
        advance(2)

        advance(1) // NIC | NACp (byte 13 — single byte; HVel starts at byte 14)

        guard remaining() >= 2 else { return nil }
        let hvCode = (UInt16(byte(0)) << 4) | (UInt16(byte(1)) >> 4)
        let groundSpeed = hvCode == 0xFFF ? 0.0 : Double(hvCode)
        advance(1)

        guard remaining() >= 2 else { return nil }
        let vvRaw = (Int16(byte(0) & 0x0F) << 8) | Int16(byte(1))
        let vvSigned = vvRaw > 2047 ? vvRaw - 4096 : vvRaw
        let verticalRate = Double(vvSigned) * 64.0
        advance(2)

        guard remaining() >= 1 else { return nil }
        let track = Double(byte(0)) * (360.0 / 256.0)
        advance(1)

        advance(1) // emitter category

        var callsign = icao
        if remaining() >= 8 {
            let csEnd = payload.index(idx, offsetBy: 8)
            if let raw = String(bytes: payload[idx..<csEnd], encoding: .ascii) {
                let trimmed = raw.trimmingCharacters(in: .init(charactersIn: " \0"))
                if !trimmed.isEmpty { callsign = trimmed }
            }
        }

        return Aircraft(
            id: isOwnship ? "OWNSHIP" : icao,
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
        guard isInternetAvailable || networkReachability.isConnected else { return }
        guard internetFetchTimer == nil else { return }
        // Update published flag in case NWPathMonitor hasn't fired yet but we know we're connected
        if !isInternetAvailable { isInternetAvailable = networkReachability.isConnected }
        consecutiveInternetFailures = 0   // fresh start after a network-path change
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
        lastInternetFetchTime = Date()
        adsbLolClient.fetchAircraft(
            latitude: loc.latitude,
            longitude: loc.longitude,
            radiusNM: internetQueryRadius
        ) { [weak self] result in
            switch result {
            case .success(let aircraft):
                self?.consecutiveInternetFailures = 0
                self?.mergeInternetAircraft(aircraft)
            case .failure(let err):
                print("⚠️ adsb.lol fetch failed: \(err.localizedDescription)")
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.consecutiveInternetFailures += 1
                    if self.consecutiveInternetFailures >= self.maxInternetFailuresBeforeOffline {
                        // Treat the path as having no real internet (e.g. Sentry WiFi hotspot).
                        // stopInternetFetching() is safe here: no internet aircraft were stored
                        // (all fetches failed), so the filter inside it is a no-op. NWPathMonitor
                        // remains active and will call ensureInternetFetchRunning() if the path
                        // genuinely becomes internet-capable later.
                        self.isInternetAvailable = false
                        self.stopInternetFetching()
                    }
                }
            }
        }
    }

    private func mergeInternetAircraft(_ list: [Aircraft]) {
        let fetchTime = Date()

        // ── Step 1: snapshot — must happen on the main thread ──────────────────────
        // detectedAircraft, ownshipData, and currentLocation are @Published properties
        // owned by the main thread.  Reading them from the URLSession background callback
        // without synchronisation is a data race.  Jump to the main queue first so the
        // snapshot is always taken on the correct thread, then hop to background for the
        // CPU-heavy distance-filter pass, then back to main to commit.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let currentAircraft = self.detectedAircraft
            let ownship         = self.ownshipData
            let ownLoc          = self.currentLocation
            let maxRadius       = self.internetQueryRadius
            let cap             = self.maxInternetAircraft

            // ── Step 2: filter on background thread ────────────────────────────────
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }

                let existingCount     = currentAircraft.values.filter { $0.source == .internet }.count
                var newSlotsRemaining = max(0, cap - existingCount)

                var updates: [String: Aircraft] = [:]
                for var ac in list {
                    // Pre-filter by distance — aircraft outside render range are never stored.
                    if let ownLoc {
                        let distNM = CalculationsLogic.distanceInNauticalMiles(from: ownLoc, to: ac.coordinate)
                        guard distNM <= maxRadius else { continue }
                        if distNM < 0.1 { continue }   // skip ownship by GPS proximity
                    }

                    // Skip if an ADS-B aircraft with this ID already exists.
                    if let existing = currentAircraft[ac.id], existing.source == .adsb { continue }

                    // Skip ownship by proximity to ADS-B ownship position.
                    if let ownship {
                        let ownCoord = CLLocationCoordinate2D(latitude: ownship.latitude, longitude: ownship.longitude)
                        if CalculationsLogic.distanceInNauticalMiles(from: ownCoord, to: ac.coordinate) < 0.1 { continue }
                    }

                    // Existing internet aircraft: always refresh position + timestamp so
                    // the 4 Hz visualization loop sees current data every 8-second fetch.
                    // New aircraft: only add while below the cap.
                    // Use `continue` (not `break`) so the loop keeps scanning — existing
                    // aircraft that appear later in the list still get their update even
                    // when no new slots are available.
                    let isUpdate = currentAircraft[ac.id]?.source == .internet
                    if !isUpdate {
                        guard newSlotsRemaining > 0 else { continue }
                        newSlotsRemaining -= 1
                    }

                    ac.lastUpdate = fetchTime
                    updates[ac.id] = ac
                }

                guard !updates.isEmpty else { return }

                // ── Step 3: merge on main thread — one @Published fire ──────────────
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    var merged = self.detectedAircraft
                    for (id, ac) in updates { merged[id] = ac }
                    self.detectedAircraft = merged
                    self.internetAircraftCount = merged.values.filter { $0.source == .internet }.count
                }
            }
        }
    }

    // MARK: - Private — Cleanup

    private func setupCleanupTimer() {
        // Run cleanup at 30s — long enough that the 8s fetch has multiple chances to
        // refresh an aircraft before cleanup considers it stale. Previously at 10s the
        // cleanup and fetch could race, causing brief disappearances.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let cutoff = Date().addingTimeInterval(-self.aircraftTimeout)
            DispatchQueue.main.async {
                self.detectedAircraft = self.detectedAircraft.filter { $0.value.lastUpdate > cutoff }
            }
        }
    }
}
