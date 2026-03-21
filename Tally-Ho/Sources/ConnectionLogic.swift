//
//  ConnectionLogic.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Handles ADS-B reception from ForeFlight Sentry (and compatible devices)
//  and internet aircraft data from adsb.lol.
//
//  ADS-B note: the ForeFlight Sentry listens for a registration broadcast that
//  ForeFlight sends on UDP port 63093 every 5 seconds.  Without this handshake
//  the Sentry only sends proprietary 0x25/0x26 messages whose format is undocumented.
//  Once it sees the JSON registration it switches to unicast standard GDL90
//  (0x0A ownship + 0x14 traffic) back to port 4000 on the registrant's IP.
//  We replicate that broadcast so the Sentry treats us like ForeFlight Mobile.
//

import Foundation
import Network
import CoreLocation
import Combine
import Darwin   // BSD socket APIs for UDP broadcast

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

// MARK: - ADSBDiagnostics

struct ADSBDiagnostics {
    var packetCount: Int = 0
    var parsedHeartbeat: Int = 0
    var parsedOwnship: Int = 0
    var parsedTraffic: Int = 0
    var parsedFail: Int = 0
    /// Count of each raw GDL90 message type seen (keyed by msg type byte, e.g. 0x26).
    var rawMsgTypeCounts: [UInt8: Int] = [:]
    /// Hex string of the first received UDP packet, for display in the status HUD.
    var firstPacketHex: String? = nil
    /// Byte positions of 0x7E frame flags within firstPacketHex.
    var firstPacketFlagPositions: [Int] = []
}

// MARK: - ConnectionLogic

class ConnectionLogic: ObservableObject {

    // MARK: Published

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var detectedAircraft: [String: Aircraft] = [:]
    @Published var ownshipData: Aircraft?           // GPS/altitude from ADS-B ownship report
    @Published var isInternetAvailable: Bool = false
    @Published var internetAircraftCount: Int = 0
    @Published var adsbDiag = ADSBDiagnostics()

    // MARK: Private — ADS-B listener

    private var listener: NWListener?
    private let adsbQueue = DispatchQueue(label: "com.tallyoh.adsb", qos: .userInitiated)
    private let adsbPort: NWEndpoint.Port = 4000

    /// Time of last received GDL90 packet — used to detect signal loss
    private var lastPacketReceived: Date?
    private var signalWatchdogTimer: Timer?

    /// Timer that broadcasts the ForeFlight registration JSON on port 63093 every 5 seconds.
    /// The Sentry (and compatible devices) listen for this broadcast; on receipt they switch
    /// from their default proprietary 0x25/0x26 broadcast to unicast standard GDL90
    /// (0x0A ownship + 0x14 traffic) back to us on port 4000.
    private var foreflight63093Timer: Timer?

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

        // Broadcast the ForeFlight registration JSON on port 63093 immediately and
        // repeat every 5 seconds.  The Sentry listens for this broadcast and, on
        // receipt, switches from its default proprietary 0x25/0x26 mode to unicast
        // standard GDL90 (0x0A ownship + 0x14 traffic) back to us on port 4000.
        // This mirrors exactly what ForeFlight Mobile does — it broadcasts
        // unconditionally from launch so the Sentry catches it as early as possible.
        // Non-Sentry devices (Stratux, etc.) don't listen on port 63093, so the
        // broadcast is harmless to them.  The timer is cancelled once standard GDL90
        // frames confirm the device has switched (or isn't a Sentry at all).
        DispatchQueue.main.async {
            self.startSentryRegistration()
        }
    }

    func stopListening() {
        foreflight63093Timer?.invalidate()
        foreflight63093Timer = nil
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
                self?.processGDL90Data(data)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.adsbDiag.packetCount += 1
                    // Capture raw bytes of the very first packet for HUD diagnostics.
                    if self.adsbDiag.firstPacketHex == nil {
                        self.adsbDiag.firstPacketHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                        self.adsbDiag.firstPacketFlagPositions = data.indices
                            .filter { data[$0] == 0x7E }
                            .map { data.distance(from: data.startIndex, to: $0) }
                    }
                    self.lastPacketReceived = Date()
                    if self.connectionStatus != .receiving {
                        self.connectionStatus = .receiving
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

    /// Broadcast the ForeFlight registration JSON on UDP port 63093.
    ///
    /// The ForeFlight Sentry (and uAvionix Scout) monitor the local network for this
    /// broadcast.  Per the ForeFlight GDL 90 Extended Specification the message is:
    ///
    ///   {"App":"ForeFlight","GDL90":{"port":4000}}
    ///
    /// On receipt the Sentry switches from its default proprietary broadcast (message
    /// types 0x25/0x26, format undisclosed) to unicast standard GDL90 on port 4000
    /// addressed to us — including 0x0A ownship and 0x14 traffic reports that our
    /// existing parser can decode correctly.

    /// Start the Sentry registration broadcast if not already running.
    /// Must be called on the main thread (timer scheduling).
    private func startSentryRegistration() {
        guard foreflight63093Timer == nil else { return }
        sendForeFlight63093Registration()
        foreflight63093Timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sendForeFlight63093Registration()
        }
    }

    /// Stop the Sentry registration broadcast.
    /// Must be called on the main thread.
    private func stopSentryRegistration() {
        guard foreflight63093Timer != nil else { return }
        foreflight63093Timer?.invalidate()
        foreflight63093Timer = nil
    }

    private func sendForeFlight63093Registration() {
        let json = #"{"App":"ForeFlight","GDL90":{"port":4000}}"#
        guard let payload = json.data(using: .utf8) else { return }

        // BSD socket: UDP broadcast to 255.255.255.255:63093.
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = UInt16(63093).bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST  // 0xFFFFFFFF

        payload.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    _ = sendto(sock, ptr.baseAddress, ptr.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func processGDL90Data(_ data: Data) {
        // Scan for 0x7E frame boundaries, then de-stuff each frame before dispatching.
        var i = data.startIndex
        while i < data.endIndex {
            guard data[i] == 0x7E else { i = data.index(after: i); continue }
            let payloadStart = data.index(after: i)
            guard payloadStart < data.endIndex else { break }
            if let end = data[payloadStart...].firstIndex(of: 0x7E) {
                // GDL90 byte-stuffing: 0x7D 0x5E → 0x7E, 0x7D 0x5D → 0x7D
                let unstuffed = unstuffGDL90(data[payloadStart..<end])
                handleGDL90Message(unstuffed)
                i = data.index(after: end)
            } else {
                break
            }
        }
    }

    /// Remove GDL90 byte-stuffing escape sequences from a raw frame payload.
    private func unstuffGDL90(_ payload: Data.SubSequence) -> Data {
        var result = Data()
        result.reserveCapacity(payload.count)
        var i = payload.startIndex
        while i < payload.endIndex {
            if payload[i] == 0x7D {
                let next = payload.index(after: i)
                if next < payload.endIndex {
                    result.append(payload[next] ^ 0x20)
                    i = payload.index(after: next)
                    continue
                }
            }
            result.append(payload[i])
            i = payload.index(after: i)
        }
        return result
    }

    private func handleGDL90Message(_ payload: Data) {
        guard let msgType = payload.first else { return }

        // Always track raw message type for diagnostics.
        DispatchQueue.main.async { self.adsbDiag.rawMsgTypeCounts[msgType, default: 0] += 1 }

        switch msgType {
        case 0x00:   // Heartbeat — standard GDL90 device confirmed
            DispatchQueue.main.async {
                self.adsbDiag.parsedHeartbeat += 1
                self.stopSentryRegistration()
            }
        case 0x0A:   // Ownship — standard GDL90 device confirmed
            DispatchQueue.main.async { self.stopSentryRegistration() }
            if let ac = parseTrafficPayload(payload, isOwnship: true) {
                DispatchQueue.main.async {
                    self.ownshipData = ac
                    self.adsbDiag.parsedOwnship += 1
                }
            } else {
                DispatchQueue.main.async { self.adsbDiag.parsedFail += 1 }
            }
        case 0x14:   // Standard traffic report — standard GDL90 device confirmed
            DispatchQueue.main.async { self.stopSentryRegistration() }
            if let ac = parseTrafficPayload(payload, isOwnship: false) {
                DispatchQueue.main.async {
                    self.detectedAircraft[ac.id] = ac
                    self.adsbDiag.parsedTraffic += 1
                }
            } else {
                DispatchQueue.main.async { self.adsbDiag.parsedFail += 1 }
            }
        case 0x25,   // ADS-B position (ForeFlight Sentry proprietary — format undisclosed)
             0x26:   // ADS-R fine position (ForeFlight Sentry proprietary — format undisclosed)
            // These proprietary formats cannot be decoded: the coordinate encoding is
            // private (confirmed by ForeFlight/uAvionix).  Applying the standard GDL90
            // parser produces garbage positions that fail the 20 NM distance filter,
            // yielding a misleading "N aircraft but nothing displayed" situation.
            //
            // Seeing these means the Sentry is in proprietary mode — either it never
            // received our registration, or it did but another ForeFlight client later
            // took over and has since closed (reverting the Sentry to broadcast mode).
            // Re-start the registration broadcast so the Sentry switches back to
            // standard GDL90 on the next 5-second cycle.
            DispatchQueue.main.async { self.startSentryRegistration() }
        case 0x0B: break  // Ownship geometric alt (ignored)
        default: break
        }
    }

    /// Parse a de-stuffed GDL90 traffic/ownship payload (last 2 bytes are FCS — included in
    /// count but not interpreted here).  Returns nil if the payload is too short or malformed.
    private func parseTrafficPayload(_ payload: Data, isOwnship: Bool) -> Aircraft? {
        // Minimum: msg_id(1)+status_addr(1)+ICAO(3)+lat(3)+lon(3)+
        //          alt_misc(2)+NIC(1)+vel(2)+vv(2)+track(1)+emitter(1)+FCS(2) = 22 bytes.
        // Compact 0x25/0x26 frames from the Sentry omit the 8-byte callsign,
        // so 22 bytes is the practical floor; standard 0x14 frames are 30 bytes.
        guard payload.count >= 22 else { return nil }

        // Use an index cursor relative to the slice start.
        var idx = payload.startIndex

        func advance(_ n: Int) { idx = payload.index(idx, offsetBy: n) }
        func remaining() -> Int { payload.distance(from: idx, to: payload.endIndex) }
        func byte(_ offset: Int) -> UInt8 { payload[payload.index(idx, offsetBy: offset)] }

        advance(1) // skip message ID
        advance(1) // status / address type (combined byte in GDL90: alert_status[7:4] | addr_type[3:0])

        guard remaining() >= 3 else { return nil }
        let icao = String(format: "%02X%02X%02X", byte(0), byte(1), byte(2))
        advance(3)

        guard remaining() >= 3 else { return nil }
        var latRaw = Int32(byte(0)) << 16 | Int32(byte(1)) << 8 | Int32(byte(2))
        if latRaw & 0x800000 != 0 { latRaw |= Int32(bitPattern: 0xFF000000) }
        // GDL90 latitude: 24-bit signed, range [-90, 90] → LSB = 90/2²³ = 180/2²⁴
        let latitude = Double(latRaw) * (180.0 / 16_777_216.0)
        advance(3)

        guard remaining() >= 3 else { return nil }
        var lonRaw = Int32(byte(0)) << 16 | Int32(byte(1)) << 8 | Int32(byte(2))
        if lonRaw & 0x800000 != 0 { lonRaw |= Int32(bitPattern: 0xFF000000) }
        let longitude = Double(lonRaw) * (180.0 / 8_388_608.0)
        advance(3)

        guard remaining() >= 2 else { return nil }
        let altCode = (UInt16(byte(0)) << 4) | (UInt16(byte(1)) >> 4)
        let altitude = altCode == 0xFFF ? 0.0 : Double(altCode) * 25.0 - 1000.0
        advance(2)

        advance(1) // NIC / NACp (Misc is in the lower nibble of the alt byte, already consumed)

        guard remaining() >= 2 else { return nil }
        let hvCode = (UInt16(byte(0)) << 4) | (UInt16(byte(1)) >> 4)
        let groundSpeed = hvCode == 0xFFF ? 0.0 : Double(hvCode)
        advance(2)  // consume both bytes of the horiz-vel field

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
