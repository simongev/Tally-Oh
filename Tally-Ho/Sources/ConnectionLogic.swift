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
    /// Number of ForeFlight 63093 registration broadcasts sent since listening started.
    var registrationsSent: Int = 0
    /// IP address of the device currently sending us GDL90 packets (captured from NWConnection endpoint).
    /// nil until first packet received.
    var sentryIPCaptured: String? = nil
    /// Histogram of de-stuffed GDL90 frame payload sizes (in bytes), keyed by size.
    /// Helps characterise proprietary frame formats for reverse-engineering.
    var frameSizeCounts: [Int: Int] = [:]
    /// Most recent 0x25 (ownship) frame hex, updated on every 0x25 arrival.
    var lastMsg25Hex: String? = nil
    /// One sample hex string per unique de-stuffed frame size (first seen wins).
    var sampleFramesBySize: [Int: String] = [:]
    // MARK: Confirmed 22b frame layout (reverse-engineered, validated against captured frames)
    // Layout: [0x26][ICAO 3b][flags][LON 3b][unk 7b][LAT 3b][ALT 2b][CRC 2b]
    // Both lat and lon use scale 180/2^24 (= 1.07e-05°/LSB).
    // Altitude: top 12 bits of big-endian uint16 at byte 18: (raw12 × 25) − 1000 ft.
    /// Byte offset into the 0x26 payload where latitude was found.
    var propLatByteOffset: Int? = 15
    /// Byte offset into the 0x26 payload where longitude was found.
    var propLonByteOffset: Int? = 5
    /// Scale factor: rawInt * propLatScale = degrees latitude.
    var propLatScale: Double? = 180.0 / 16_777_216.0
    /// Scale factor: rawInt * propLonScale = degrees longitude.
    var propLonScale: Double? = 180.0 / 16_777_216.0
    /// Human-readable calibration status shown in the HUD.
    var calibrationStatus: String? = "✅22 lat@15×1.07e-05 lon@5×1.07e-05 (hardcoded)"
    var calibrationV2Status: String? = "✅22v2 LE lat@2×1.00e-05 lon@5×1.07e-05 (hardcoded)"
    /// Vote counts for proprietary 0x26 encoding discovery.
    /// Keyed by packed (roBit, latOff, latScIdx, lonOff, lonScIdx) indices.
    var prop26VoteCounts: [Int: Int] = [:]
    /// Number of 70-byte 0x26 bundle frames processed for voting.
    var prop26FramesVoted: Int = 0
    /// Separate vote counts for 22-byte single-aircraft 0x26 frames.
    /// Kept isolated from prop26VoteCounts so 70-byte bundle votes don't
    /// create spurious ties that block 22-byte convergence.
    var prop22bVoteCounts: [Int: Int] = [:]
    /// Number of 22-byte 0x26 frames processed for voting.
    var prop22bFramesVoted: Int = 0
    /// DEPRECATED dispatch sentinel — kept for legacy code paths.  No longer drives decode.
    var prop70RecordOffset: Int? = 0
    /// Sub-record byte offset within a 70b bundle (set by voteForEncoding26 on convergence).
    /// nil = 70b bundle not yet calibrated.  Non-nil activates decodeProprietaryBundle.
    var prop70SubRecordOffset: Int? = nil
    /// Calibration values for 70b bundle sub-records (separate from confirmed 22b values).
    /// Only written by voteForEncoding26; never overwrite the hardcoded 22b offsets.
    var prop70LatByteOffset: Int = 0
    var prop70LonByteOffset: Int = 0
    var prop70LatScale: Double = 0
    var prop70LonScale: Double = 0
    /// 70b bundle calibration status shown in HUD (hardcoded since Build 185).
    var prop70VotingStatus: String = "HARDCODED LE 1e-5 lat@11/lon@46"
    /// Cached result of last cross-correlation scan of 70b bytes against detected aircraft.
    var prop70ScanResult: String = ""
    /// Vote counts for cross-correlation candidates across scan windows.
    /// Key: "BE/LE,latOff,lonOff,lscIdx,nscIdx"  Value: number of scan windows that hit this key.
    var prop70XcorrVotes: [String: Int] = [:]
    /// Confirmed hit — only set when a single (latOff,lonOff,scale) key accumulates 3+ votes.
    var prop70ConfirmedHit: String = ""
    /// Hypothesis decode result (unused since Build 185 — encoding confirmed).
    var prop70HypothesisResult: String = ""

    // MARK: Multi-frame correlation capture
    /// Ring buffer of the last 4 distinct 22-byte 0x26 frames (hex strings), newest first.
    var recent22bFrames: [String] = []
    /// Last internet fetch result: nil=never, "" = success, non-empty = error message.
    var lastInternetFetchStatus: String? = nil
    /// Aircraft count from last successful internet fetch (for HUD display).
    var lastInternetFetchCount: Int = 0
    /// Ring buffer of the last 4 distinct 20-byte 0x26 frames, newest first.
    var recent20bFrames: [String] = []
    /// The raw bytes (space-separated hex) of the most recent 22b frame that successfully
    /// decoded an aircraft position. Lets us verify which bytes actually encode lat/lon.
    var capturedPositionFrameHex: String = ""
    /// The raw bytes (space-separated hex) of the most recent 47b frame that successfully
    /// decoded an aircraft position via decodeProprietaryTraffic.
    var captured47bFrameHex: String = ""

    // MARK: - Undecoded frame xcorr (21b / 43b / 47b)

    /// Confirmed encoding for a previously-undecoded frame size.
    struct UndecodedHit {
        let isLE: Bool
        let latOff: Int
        let lonOff: Int
        let latScale: Double   // scale applied to the lat field
        let lonScale: Double   // scale applied to the lon field (may differ from latScale)
        let votes: Int
        var display: String {
            let latSc = String(format: "%.2e", latScale)
            let lonSc = String(format: "%.2e", lonScale)
            let sc = latScale == lonScale ? "sc=\(latSc)" : "latSc=\(latSc) lonSc=\(lonSc)"
            return "\(isLE ? "LE" : "BE") lat@\(latOff) lon@\(lonOff) \(sc) ×\(votes)"
        }
    }

    /// Accumulated xcorr vote counts for 21b/43b/47b frames.
    /// Key format: "\(size)b LE|BE lat@\(latOff)s\(lsi) lon@\(lonOff)s\(msi)"
    /// where lsi/msi index into [1e-5, 180/2^24, 360/2^24].
    var undecodedXcorrVotes: [String: Int] = [:]
    /// Current best xcorr candidate per frame size (key = byte count).
    var undecodedXcorrResults: [Int: String] = [:]
    /// Confirmed encoding per frame size (key = payload byte count).
    /// Set once ≥8 votes accumulate for one candidate; drives direct decode thereafter.
    var undecodedHits: [Int: UndecodedHit] = [:]
    /// Deduplicate xcorr inputs per frame size: each unique byte sequence votes only
    /// once, preventing a high-frequency static frame (e.g. the G1 device-ID frame)
    /// from drowning the signal with thousands of identical votes.
    var xcorrSeenFrames: [Int: Set<String>] = [:]
    /// Last decoded lat/lon from decodeWithHit (before ownship/range rejection).
    /// Lets us verify whether xcorr-converged frames encode ownship or traffic.
    struct XcorrDecodedSample { let lat: Double; let lon: Double; let nearGPS: Bool }
    var xcorrDecodedSamples: [Int: XcorrDecodedSample] = [:]
    /// All unique ADS-B aircraft IDs decoded during this session (never cleared).
    /// Current count shown as "seen:N" in HUD alongside the live aircraft count.
    var uniqueAircraftSeen: Set<String> = []
    /// Count of 560b frames that produced ≥1 decoded aircraft (for HUD display).
    var prop560DecodeCount: Int = 0
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

    /// IP address (string) of the last device that sent us a GDL90 packet.
    /// Captured from the NWConnection remote endpoint and used to send the registration
    /// unicast directly to the Sentry, bypassing any broadcast routing issues.
    private var sentryIPString: String?

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

    /// Hard cap on total internet aircraft stored.  When Sentry ADS-B is receiving,
    /// the query radius grows to 200 nm to cover the same range as ADS-B traffic,
    /// so the cap also grows to accommodate the larger area.
    private var maxInternetAircraft: Int { connectionStatus == .receiving ? 300 : 100 }
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
            // Capture the remote endpoint so we can unicast registration directly to the Sentry.
            if case .hostPort(let host, _) = conn.endpoint {
                let ipString = "\(host)"
                DispatchQueue.main.async {
                    self?.sentryIPString = ipString
                    self?.adsbDiag.sentryIPCaptured = ipString
                }
            }
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
            // Reset all calibration and vote state so a reconnect starts clean.
            // Without this, stale vote counts survive into the next session and can
            // cause early false convergence (e.g. ICAO-as-lat at offset 2).
            self.adsbDiag = ADSBDiagnostics()
        }
    }

    func updateLocation(_ location: CLLocationCoordinate2D, altitudeFeet: Double = 0) {
        let firstFix = currentLocation == nil
        currentLocation = location
        currentAltitudeFeet = altitudeFeet
        // On first GPS fix, evict ghost ADS-B aircraft that were decoded before the
        // geographic filter could apply (currentLocation was nil at decode time).
        // This cleans up worldwide phantom aircraft that appear during GPS cold-start.
        if firstFix {
            detectedAircraft = detectedAircraft.filter { _, ac in
                ac.source == .internet ||
                (abs(ac.latitude  - location.latitude)  <= 5.0 &&
                 abs(ac.longitude - location.longitude) <= 5.0)
            }
        }
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

        // Research shows the Sentry does NOT listen on port 63093 for unicast —
        // 63093 is the port ForeFlight uses to broadcast its own presence to standard
        // GDL90 hardware (Garmin, Stratus), not a mode-switch port for the Sentry.
        // The Sentry always sends proprietary 0x25/0x26 regardless of registration.
        //
        // We still send the broadcast because it may cause the Sentry to switch from
        // broad­cast delivery to unicast delivery (same 0x25/0x26 content, lower overhead).
        // NWConnection unicast to sentryIP:63093 is intentionally omitted because the
        // Sentry's port 63093 is closed — it produces ICMP unreachable for every attempt.

        func sendBroadcast(to destAddr: in_addr_t) {
            let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else { return }
            defer { close(sock) }
            var yes: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port   = UInt16(63093).bigEndian
            addr.sin_addr.s_addr = destAddr
            payload.withUnsafeBytes { ptr in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        _ = sendto(sock, ptr.baseAddress, ptr.count, 0,
                                   saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        // Subnet-directed broadcast from each active interface, then limited broadcast.
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifap) == 0, let ifList = ifap {
            var cursor: UnsafeMutablePointer<ifaddrs>? = ifList
            while let ifa = cursor {
                let flags = Int32(ifa.pointee.ifa_flags)
                if flags & IFF_UP != 0,
                   flags & IFF_BROADCAST != 0,
                   ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                   let bcastSA = ifa.pointee.ifa_dstaddr {
                    let bcastAddr = bcastSA.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee.sin_addr.s_addr
                    }
                    sendBroadcast(to: bcastAddr)
                }
                cursor = ifa.pointee.ifa_next
            }
            freeifaddrs(ifList)
        }
        sendBroadcast(to: INADDR_BROADCAST)

        DispatchQueue.main.async { self.adsbDiag.registrationsSent += 1 }
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

        // Always track raw message type and frame size for diagnostics.
        let frameSize = payload.count
        DispatchQueue.main.async {
            self.adsbDiag.rawMsgTypeCounts[msgType, default: 0] += 1
            self.adsbDiag.frameSizeCounts[frameSize, default: 0] += 1
        }

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
                    if self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                    }
                }
            } else {
                DispatchQueue.main.async { self.adsbDiag.parsedFail += 1 }
            }
        case 0x25:   // Sentry proprietary ownship — contains device GPS position
            let copy25 = payload
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let hex = copy25.map { String(format: "%02X", $0) }.joined(separator: " ")
                self.adsbDiag.lastMsg25Hex = hex
                if self.adsbDiag.sampleFramesBySize[copy25.count] == nil {
                    self.adsbDiag.sampleFramesBySize[copy25.count] = hex
                }
                // Brute-force calibration: discover lat/lon byte layout using known GPS.
                if let loc = self.currentLocation, self.adsbDiag.propLatByteOffset == nil {
                    self.calibrateProprietaryEncoding(copy25, userLat: loc.latitude, userLon: loc.longitude)
                }
                self.startSentryRegistration()
            }
        case 0x26:   // Sentry proprietary traffic
            let copy26 = payload
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let hex = copy26.map { String(format: "%02X", $0) }.joined(separator: " ")
                // Always refresh high-interest frame sizes so HUD stays current.
                // Other sizes: first-seen only.
                let alwaysRefreshSizes: Set<Int> = [70, 22, 20, 21, 43, 47, 56]
                if alwaysRefreshSizes.contains(copy26.count) {
                    self.adsbDiag.sampleFramesBySize[copy26.count] = hex
                } else if self.adsbDiag.sampleFramesBySize[copy26.count] == nil {
                    self.adsbDiag.sampleFramesBySize[copy26.count] = hex
                }

                // Ring buffers of recent unique frames for cross-session comparison.
                if copy26.count == 22 {
                    if self.adsbDiag.recent22bFrames.first != hex {
                        self.adsbDiag.recent22bFrames.insert(hex, at: 0)
                        if self.adsbDiag.recent22bFrames.count > 4 {
                            self.adsbDiag.recent22bFrames.removeLast()
                        }
                    }
                } else if copy26.count == 20 {
                    if self.adsbDiag.recent20bFrames.first != hex {
                        self.adsbDiag.recent20bFrames.insert(hex, at: 0)
                        if self.adsbDiag.recent20bFrames.count > 4 {
                            self.adsbDiag.recent20bFrames.removeLast()
                        }
                    }
                }

                // 70b voting removed — encoding confirmed and hardcoded (Build 185).
                // 22b: two hardcoded formats. v1=BE lat@15 lon@5 180/2^24 (far traffic).
                //      v2=LE lat@2 1e-5 lon@5 180/2^24 (confirmed xcorr ×26, Build 212).
                //      Frames failing both go through xcorr for any future unknown format.
                if copy26.count == 22 {
                    if let ac = self.decodeProprietarySingle(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedPositionFrameHex = "\(ac.callsign): \(hex)"
                    } else if let ac = self.decode22bV2(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                    } else {
                        let alreadySeen = self.adsbDiag.xcorrSeenFrames[22]?.contains(hex) ?? false
                        if !alreadySeen {
                            self.adsbDiag.xcorrSeenFrames[22, default: []].insert(hex)
                            self.scanUndecodedFrame(copy26)
                        }
                    }
                } else if copy26.count == 70 {
                    // 70b bundle — hardcoded LE 1e-5 lat@11/lon@46 (confirmed ×3).
                    for ac in self.decodeProprietaryBundle(copy26) {
                        guard self.isPhysicallyReceivable(ac) else { continue }
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                    }
                } else if copy26.count == 560 {
                    // 560b = 8×70b bundle — same LE 1e-5 encoding per sub-record.
                    let decoded560 = self.decodeProprietaryBundle560(copy26)
                    var added = 0
                    for ac in decoded560 {
                        guard self.isPhysicallyReceivable(ac) else { continue }
                        // Bytes 1-3 of each sub-record are not a stable ICAO —
                        // the same aircraft appears in different sub-record slots
                        // across frames with different byte values.  Look for an
                        // existing ADS-B aircraft within 0.02° (≈1 nm) and reuse
                        // its ID to prevent duplicate entries for the same aircraft.
                        let stableId: String
                        if let existingKey = self.detectedAircraft.first(where: { _, ex in
                            ex.source == .adsb &&
                            abs(ex.latitude  - ac.latitude)  < 0.02 &&
                            abs(ex.longitude - ac.longitude) < 0.02
                        })?.key {
                            stableId = existingKey
                        } else {
                            stableId = ac.id
                        }
                        let stableAc = Aircraft(id: stableId, callsign: stableId,
                                                latitude: ac.latitude, longitude: ac.longitude,
                                                altitude: ac.altitude, track: 0, groundSpeed: 0,
                                                verticalRate: 0, lastUpdate: ac.lastUpdate,
                                                source: .adsb)
                        self.detectedAircraft[stableId] = stableAc
                        self.adsbDiag.uniqueAircraftSeen.insert(stableId)
                        self.adsbDiag.parsedTraffic += 1
                        added += 1
                    }
                    if added > 0 { self.adsbDiag.prop560DecodeCount += 1 }
                } else if [20, 21, 43, 47, 56].contains(copy26.count) {
                    // 20b: ground-only device status (never appears in flight). Skip.
                    // 47b/21b/43b: confirmed not traffic. Skip.
                    // 56b: dominant in-flight frame (500+/session). Re-enabled xcorr.
                    //      Previous "inconsistent offsets" was a false alarm — xcorr
                    //      converged on different aircraft in different sessions, not
                    //      different formats. With decoded aircraft as reference anchors
                    //      (±0.15°) xcorr will converge on the correct lat/lon offsets.
                    if copy26.count == 56 {
                        var decoded56 = false
                        if let hit = self.adsbDiag.undecodedHits[56] {
                            if let ac = self.decodeWithHit(copy26, hit: hit),
                               self.isPhysicallyReceivable(ac) {
                                self.detectedAircraft[ac.id] = ac
                                self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                                self.adsbDiag.parsedTraffic += 1
                                decoded56 = true
                            }
                        }
                        // If no hit yet, or hit produced invalid position (false convergence):
                        // run xcorr on new unique frames so the true format can still converge.
                        if !decoded56 {
                            let alreadySeen = self.adsbDiag.xcorrSeenFrames[56]?.contains(hex) ?? false
                            if !alreadySeen {
                                self.adsbDiag.xcorrSeenFrames[56, default: []].insert(hex)
                                self.scanUndecodedFrame(copy26)
                            }
                        }
                    }
                } else if ![70, 22, 20, 21, 43, 47, 56, 560].contains(copy26.count),
                          let ac = self.decodeProprietaryTraffic(copy26),
                          self.isPhysicallyReceivable(ac) {
                    // Catch-all for other frame sizes: try 22b-calibrated offsets.
                    self.detectedAircraft[ac.id] = ac
                    self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                    self.adsbDiag.parsedTraffic += 1
                }
                self.startSentryRegistration()
            }
        case 0x0B: break  // Ownship geometric alt (ignored)
        default: break
        }
    }

    /// Vote-based proprietary encoding discovery for 0x26 traffic frames.
    ///
    /// For every incoming 22-byte 0x26 frame, tries all (latOff, latScale, lonOff, lonScale)
    /// combinations and casts a vote for each that decodes to a geographically plausible
    /// NYC-area position (lat [35°,48°]N, lon [-82°,−65°]W).  After 30+ frames the
    /// correct combination wins overwhelmingly — correct ~80% hit rate vs. ~0.3% for
    /// random false-positive combinations.
    ///
    /// Must be called on the main thread.
    /// Vote-based proprietary encoding discovery for 70-byte bundle frames.
    ///
    /// Each bundle contains 3 × 22-byte sub-records preceded by a 1- or 2-byte
    /// header.  Tries both header sizes and all byte-offset/scale combinations,
    /// voting for each that decodes to a position near the user's GPS location.
    /// Uses GPS ±10° bounds when available; falls back to broad North America box.
    ///
    /// Key insight: standalone 22-byte 0x26 frames carry velocity/identification
    /// data without lat/lon; the 70-byte bundles hold position reports.
    ///
    /// Must be called on the main thread.
    private func voteForEncoding26(_ payload: Data) {
        guard payload.count == 70 else { return }
        let b = Array(payload)

        // ±3° ≈ 200 mi window — comfortably covers full ADS-B range.
        // With per-scale probability ~0.056% of a random 3-byte value landing in range,
        // the chance that ALL 3 sub-records pass by coincidence is ~1.8e-10 per frame
        // per candidate, eliminating false-positive ties entirely.
        let (latMin, latMax, lonMin, lonMax): (Double, Double, Double, Double)
        if let loc = currentLocation {
            let pad: Double = 3.0
            latMin = loc.latitude  - pad;  latMax = loc.latitude  + pad
            lonMin = loc.longitude - pad;  lonMax = loc.longitude + pad
        } else {
            latMin = 25.0; latMax = 55.0; lonMin = -105.0; lonMax = -55.0
        }

        let scales: [Double] = [
            180.0 / 16_777_216.0,   // GDL90 lat
            360.0 / 16_777_216.0,   // GDL90 lon
            1.0 / 10_000.0,
            1.0 / 100_000.0,
            1.0 / 1_000.0,
        ]
        let SC = scales.count   // 5
        let PC = 13             // relative offsets 0…12 within a 16-byte sub-record (need +2 for s24)

        func s24at(_ absOff: Int) -> Int32 {
            let v = Int32(b[absOff]) << 16 | Int32(b[absOff + 1]) << 8 | Int32(b[absOff + 2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }

        // Little-endian signed 24-bit read (used for xcorr and hypothesis decode).
        func s24le(_ off: Int) -> Double {
            let v = Int32(b[off]) | Int32(b[off+1]) << 8 | Int32(b[off+2]) << 16
            return Double(v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v)
        }

        adsbDiag.prop26FramesVoted += 1

        // 70b frame layout: [0-1] header, [2-17] sub0, [18-33] sub1, [34-49] unknown block,
        // [50-67] constant device metadata, [68-69] CRC.
        // Vote with OR logic: each sub-record independently contributes a vote when its
        // own lat+lon bytes decode to a position near the user.  AND logic (requiring both)
        // always scores 0 because when one sub-record contains a distant or absent aircraft
        // it blocks the other.  Expected noise ≈ 920×0.12% ≈ 1 vote per candidate;
        // true encoding accumulates ~920 votes in 460 frames → converges after ~10 frames.
        let ro  = 2
        let PSC = PC * SC   // 13 × 5 = 65

        for ri in 0 ..< 2 {   // sub0 (bytes 2-17) and sub1 (bytes 18-33) independently
            let sub = ro + ri * 16
            for latIdx in 0 ..< PC {
                for latScIdx in 0 ..< SC {
                    let lat = Double(s24at(sub + latIdx)) * scales[latScIdx]
                    guard lat >= latMin && lat <= latMax else { continue }
                    for lonIdx in 0 ..< PC {
                        guard abs(lonIdx - latIdx) >= 3 else { continue }
                        let hiIdx = max(latIdx, lonIdx)
                        guard sub + hiIdx + 2 < b.count else { continue }
                        for lonScIdx in 0 ..< SC {
                            let lon = Double(s24at(sub + lonIdx)) * scales[lonScIdx]
                            guard lon >= lonMin && lon <= lonMax else { continue }
                            let key = (latIdx * SC + latScIdx) * PSC + lonIdx * SC + lonScIdx
                            adsbDiag.prop26VoteCounts[key, default: 0] += 1
                        }
                    }
                }
            }
        }

        guard adsbDiag.prop26FramesVoted >= 20 else { return }

        guard let (bestKey, bestVotes) = adsbDiag.prop26VoteCounts.max(by: { $0.value < $1.value }) else {
            adsbDiag.prop70VotingStatus = String(format:
                "🗳70 0 votes after %d fr (filter too strict?)",
                adsbDiag.prop26FramesVoted)
            return
        }

        let top3 = Array(adsbDiag.prop26VoteCounts.values.sorted(by: >).prefix(3))
        let secondVotes = top3.count > 1 ? top3[1] : 0
        let thirdVotes  = top3.count > 2 ? top3[2] : 0

        let lonComp  = bestKey % PSC;  let lonIdx  = lonComp / SC;  let lonScIdx = lonComp % SC
        let latComp  = bestKey / PSC;  let latIdx  = latComp / SC;  let latScIdx = latComp % SC

        // Decode sub0 with best candidate for diagnostic display even before convergence.
        let diagLat = Double(s24at(ro + latIdx)) * scales[latScIdx]
        let diagLon = Double(s24at(ro + lonIdx)) * scales[lonScIdx]

        // Distance from best-candidate decoded position to user GPS.
        // Values >15° mean the winner is from random noise, not a real aircraft.
        let userLat = currentLocation?.latitude  ?? 40.0
        let userLon = currentLocation?.longitude ?? -74.0
        let dDeg = max(abs(diagLat - userLat), abs(diagLon - userLon))

        // Cross-correlation: every 10 frames scan all 3-byte windows in the 70b variable
        // region (bytes 2-49) against every detected Sentry aircraft's lat & lon.
        // Tolerances: ±0.05° lat, ±0.1° lon (tight enough to give <1 false positive per
        // 2000 scans with 3 aircraft; ±0.2°/±0.5° gave ~1 false pos per scan → noise).
        // "∅/N" = N aircraft checked, none found → 70b frame is NOT a simple 3-byte bundle.
        // "🎯callsign lat@off=DDD.DD lon@off=DDD.DD" = confirmed hit with decoded values.
        if adsbDiag.prop26FramesVoted % 10 == 0 && adsbDiag.prop26FramesVoted >= 50 {
            // Include ALL aircraft (Sentry + Internet) as reference points.
            let allAircraft = Array(detectedAircraft.values)

            // Vote-accumulating cross-correlation.
            // With 100+ Internet aircraft, ~33 false positives per scan window are expected.
            // A true hit at a specific (latOff, lonOff, scale) key will accumulate votes across
            // multiple consecutive scan windows; a random FP won't hit the same key repeatedly.
            // Only promote to prop70ConfirmedHit after 3+ votes on the same key.
            var bestHit: (key: String, votes: Int, display: String)? = nil

            outerXcorr: for ac in allAircraft {
                for latOff in 2 ..< 47 {
                    guard latOff + 2 <= b.count - 3 else { break }
                    let latBE = Double(s24at(latOff))
                    let latLE = s24le(latOff)
                    for lonOff in 2 ..< 47 {
                        guard abs(lonOff - latOff) >= 3, lonOff + 2 <= b.count - 3 else { continue }
                        let lonBE = Double(s24at(lonOff))
                        let lonLE = s24le(lonOff)
                        for (lscIdx, lsc) in scales.enumerated() {
                            // big-endian lat check
                            let decLatBE = latBE * lsc
                            if abs(decLatBE - ac.latitude) < 0.05 {
                                for (nscIdx, nsc) in scales.enumerated() {
                                    let decLonBE = lonBE * nsc
                                    guard abs(decLonBE - ac.longitude) < 0.1 else { continue }
                                    let key = "BE,\(latOff),\(lonOff),\(lscIdx),\(nscIdx)"
                                    adsbDiag.prop70XcorrVotes[key, default: 0] += 1
                                    let v = adsbDiag.prop70XcorrVotes[key]!
                                    let disp = String(format: "🎯BE×%d %@ lat@%d(%.2e)=%.2f lon@%d(%.2e)=%.2f",
                                                      v, ac.callsign, latOff, lsc, decLatBE, lonOff, nsc, decLonBE)
                                    if bestHit == nil || v > bestHit!.votes { bestHit = (key, v, disp) }
                                    if v >= 3 { break outerXcorr }
                                }
                            }
                            // little-endian lat check
                            let decLatLE = latLE * lsc
                            if abs(decLatLE - ac.latitude) < 0.05 {
                                for (nscIdx, nsc) in scales.enumerated() {
                                    let decLonLE = lonLE * nsc
                                    guard abs(decLonLE - ac.longitude) < 0.1 else { continue }
                                    let key = "LE,\(latOff),\(lonOff),\(lscIdx),\(nscIdx)"
                                    adsbDiag.prop70XcorrVotes[key, default: 0] += 1
                                    let v = adsbDiag.prop70XcorrVotes[key]!
                                    let disp = String(format: "🎯LE×%d %@ lat@%d(%.2e)=%.2f lon@%d(%.2e)=%.2f",
                                                      v, ac.callsign, latOff, lsc, decLatLE, lonOff, nsc, decLonLE)
                                    if bestHit == nil || v > bestHit!.votes { bestHit = (key, v, disp) }
                                    if v >= 3 { break outerXcorr }
                                }
                            }
                        }
                    }
                }
            }

            if let best = bestHit {
                adsbDiag.prop70ScanResult = best.display
                if best.votes >= 3 && adsbDiag.prop70ConfirmedHit.isEmpty {
                    adsbDiag.prop70ConfirmedHit = best.display
                }
            } else {
                adsbDiag.prop70ScanResult = allAircraft.isEmpty ? "" : "∅/\(allAircraft.count)ac"
            }
        }

        // Build 180: Real-time hypothesis decode at confirmed-candidate offsets.
        // 🎯LE×2 hit identified: lat@3 LE, lon@38 LE, scale 360/2^24 (2.15e-05°/LSB).
        // Hypothesis: the 70b variable region packs lat fields together (b[3,6,9…])
        // and lon fields together (b[38,41,44…]) — all lats first, then all lons.
        // Show 3 candidate aircraft slots (stride 3 between each).
        // Each slot shows decoded lat/lon and nearest aircraft within 5°.
        do {
            let hypScale = 360.0 / 16_777_216.0   // 2.15e-05 — confirmed LE scale
            let latBases = [3, 6, 9]
            let lonBases = [38, 41, 44]
            let userLat  = currentLocation?.latitude  ?? 40.0
            let userLon  = currentLocation?.longitude ?? -74.0
            var parts: [String] = []
            for slot in 0 ..< 3 {
                let lOff = latBases[slot]
                let nOff = lonBases[slot]
                guard nOff + 2 < b.count else { continue }
                let hypLat = s24le(lOff) * hypScale
                let hypLon = s24le(nOff) * hypScale
                // Find nearest aircraft within 5° of decoded position.
                let nearest = detectedAircraft.values.min(by: {
                    max(abs($0.latitude - hypLat), abs($0.longitude - hypLon)) <
                    max(abs($1.latitude - hypLat), abs($1.longitude - hypLon))
                })
                let tag: String
                if let n = nearest,
                   abs(n.latitude - hypLat) < 2.0,
                   abs(n.longitude - hypLon) < 2.0 {
                    tag = n.callsign
                } else if abs(hypLat - userLat) < 10.0 && abs(hypLon - userLon) < 10.0 {
                    tag = "?"
                } else {
                    tag = "∅"
                }
                parts.append(String(format: "S%d %.2f/%.2f(%@)", slot, hypLat, hypLon, tag))
            }
            adsbDiag.prop70HypothesisResult = parts.joined(separator: " ")
        }

        guard bestVotes >= 8 && (bestVotes - thirdVotes) >= 2 else {
            let noiseTag = dDeg > 15.0 ? "⚡" : ""
            adsbDiag.prop70VotingStatus = String(format:
                "🗳70 %@(%.1f,%.1f)Δ%.0f° best=%d 3rd=%d (%d fr) %@",
                noiseTag, diagLat, diagLon, dDeg,
                bestVotes, thirdVotes, adsbDiag.prop26FramesVoted,
                adsbDiag.prop70ScanResult)
            return
        }

        // Write 70b-specific calibration to its own fields — never touch the confirmed
        // 22b values (propLatByteOffset / propLonByteOffset / calibrationStatus).
        adsbDiag.prop70SubRecordOffset = ro
        adsbDiag.prop70LatByteOffset   = latIdx
        adsbDiag.prop70LonByteOffset   = lonIdx
        adsbDiag.prop70LatScale        = scales[latScIdx]
        adsbDiag.prop70LonScale        = scales[lonScIdx]
        adsbDiag.prop70VotingStatus    = String(format:
            "✅70 ro=%d lat@%d×%.2e lon@%d×%.2e (%d/%d fr)",
            ro, latIdx, scales[latScIdx],
            lonIdx, scales[lonScIdx],
            bestVotes, adsbDiag.prop26FramesVoted)
    }

    /// Vote-based encoding discovery for 22-byte single-aircraft 0x26 frames.
    ///
    /// The most common Sentry frame size (22 bytes = 1 msg type + 19 data + 2 CRC) likely
    /// carries one aircraft's position per frame.  We try all (latOff, lonOff, scale)
    /// combinations and vote for any that decode to a position within ±3° of the user's GPS.
    /// One vote per frame — with 80+ frames all showing the same aircraft near the user,
    /// the true layout will score far above any false candidate.
    private func voteForEncoding22(_ payload: Data) {
        guard payload.count == 22 else { return }
        guard let loc = currentLocation else { return }

        let b  = Array(payload)
        let pad: Double = 3.0
        let latMin = loc.latitude  - pad,  latMax = loc.latitude  + pad
        let lonMin = loc.longitude - pad,  lonMax = loc.longitude + pad

        let scales: [Double] = [
            180.0 / 16_777_216.0,
            360.0 / 16_777_216.0,
            1.0 / 10_000.0,
            1.0 / 100_000.0,
            1.0 / 1_000.0,
        ]
        let SC = scales.count
        // PC = 19 covers all byte positions in the 22b frame.
        // latStart/lonStart = 5: skip bytes 0 (type), 1 (status), 2-4 (ICAO address).
        // Bytes 2-4 with GDL90-lat scale accidentally produce plausible latitudes for any
        // aircraft whose ICAO starts with 0x38-0x45 (e.g. ICAO 378E26 decodes to 39.06°N),
        // causing the voting to converge on lat@2 and emit phantom ICAO-derived aircraft.
        let PC = 19
        let latStart = 5
        let lonStart = 5

        func s24at(_ i: Int) -> Int32 {
            let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }

        adsbDiag.prop22bFramesVoted += 1

        let PSC = PC * SC
        for latIdx in latStart ..< PC {
            guard latIdx + 2 < b.count - 2 else { continue }
            let rawLat = Double(s24at(latIdx))
            for latScIdx in 0 ..< SC {
                let lat = rawLat * scales[latScIdx]
                guard lat >= latMin && lat <= latMax else { continue }
                for lonIdx in lonStart ..< PC {
                    guard abs(lonIdx - latIdx) >= 3 else { continue }
                    guard lonIdx + 2 < b.count - 2 else { continue }
                    let rawLon = Double(s24at(lonIdx))
                    for lonScIdx in 0 ..< SC {
                        let lon = rawLon * scales[lonScIdx]
                        guard lon >= lonMin && lon <= lonMax else { continue }
                        let inner = (latIdx * SC + latScIdx) * PSC + lonIdx * SC + lonScIdx
                        adsbDiag.prop22bVoteCounts[inner, default: 0] += 1
                    }
                }
            }
        }

        guard adsbDiag.prop22bFramesVoted >= 20 else { return }
        guard let (bestKey, bestVotes) = adsbDiag.prop22bVoteCounts.max(by: { $0.value < $1.value })
        else { return }

        let top3 = Array(adsbDiag.prop22bVoteCounts.values.sorted(by: >).prefix(3))
        let thirdVotes = top3.count > 2 ? top3[2] : 0

        // Threshold: ≥6 absolute votes AND winner leads 3rd by ≥3.
        // The ×2 multiplier was too strict: aliased byte-offset candidates
        // (sharing 2 of 3 bytes with the true field) legitimately score ~90%
        // as many votes as the winner, so best/3rd ratios stay near 1.5×.
        // An absolute gap of 3 is safe: random noise peaks at ~1 vote
        // (494 × 0.056% = 0.28 expected), so a gap of 3 is ~10σ above noise.
        // This still blocks the 7=7=7 deadlock (gap = 0 < 3).
        guard bestVotes >= 6 && (bestVotes - thirdVotes) >= 3 else {
            let second = top3.count > 1 ? top3[1] : 0
            adsbDiag.calibrationStatus = String(format:
                "🗳22 voting: best=%d 2nd=%d 3rd=%d (%d frames)",
                bestVotes, second, thirdVotes, adsbDiag.prop22bFramesVoted)
            return
        }

        // Converged — decode the key back to (latIdx, latScIdx, lonIdx, lonScIdx).
        let latIdx   = (bestKey / PSC) / SC
        let latScIdx = (bestKey / PSC) % SC
        let lonIdx   = (bestKey % PSC) / SC
        let lonScIdx = (bestKey % PSC) % SC

        // Commit calibration using the same fields as the 70-byte path.
        adsbDiag.prop70RecordOffset = 0    // 0 = 22-byte single-frame mode
        adsbDiag.propLatByteOffset  = latIdx
        adsbDiag.propLonByteOffset  = lonIdx
        adsbDiag.propLatScale       = scales[latScIdx]
        adsbDiag.propLonScale       = scales[lonScIdx]
        adsbDiag.calibrationStatus  = String(format:
            "✅22 lat@%d×%.2e lon@%d×%.2e (%d/%d frames)",
            latIdx, scales[latScIdx], lonIdx, scales[lonScIdx],
            bestVotes, adsbDiag.prop22bFramesVoted)
        detectedAircraft.removeAll()
    }

    /// Decode aircraft from a 70-byte proprietary bundle frame.
    /// Encoding confirmed via ×3 xcorr hit (Build 185):
    ///   - LE 24-bit signed, scale 1/100,000 (1.0e-05 °/LSB)
    ///   - Slot 0: lat@3,  lon@38  (tentative ×2)
    ///   - Slot 1: lat@11, lon@46  (confirmed ×3 — NKS832/RPA5643 hits)
    /// Both slots use a 35-byte lat→lon separation (46-11 = 38-3 = 35).
    /// Must be called on the main thread.
    private func decodeProprietaryBundle(_ payload: Data) -> [Aircraft] {
        guard payload.count == 70 else { return [] }
        let b = Array(payload)
        let scale = 1.0 / 100_000.0

        // LE 24-bit signed: byte[off] = LSB, byte[off+1] = MID, byte[off+2] = MSB
        func s24le(_ off: Int) -> Int32 {
            let v = Int32(b[off]) | Int32(b[off + 1]) << 8 | Int32(b[off + 2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }

        // Slot 0 lat@3/lon@38 was removed: lon bytes 38-40 are a fixed protocol field
        // that always decode to -80.17°W regardless of actual aircraft position.
        // Slot 1 lat@11/lon@46 confirmed ×3 (NKS832/RPA5643 hits).
        let slots: [(latOff: Int, lonOff: Int, id: String)] = [
            (11, 46, "T70B"),
        ]

        var result: [Aircraft] = []
        for slot in slots {
            guard slot.lonOff + 2 < b.count else { continue }
            let lat = Double(s24le(slot.latOff)) * scale
            let lon = Double(s24le(slot.lonOff)) * scale

            guard (-90...90).contains(lat), (-180...180).contains(lon) else { continue }
            guard abs(lat) > 1.0 || abs(lon) > 1.0 else { continue }
            // Reject positions more than 10° from user — prevents phantom aircraft.
            if let loc = currentLocation,
               abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { continue }
            // Reject ownship echo.
            if let loc = currentLocation,
               abs(lat - loc.latitude) < ownshipRejectionRadius &&
               abs(lon - loc.longitude) < ownshipRejectionRadius { continue }

            // GDL90 12-bit altitude packed at bytes immediately after the later coordinate.
            let altOff = max(slot.latOff, slot.lonOff) + 3
            var altFt: Double = 10_000
            if altOff + 1 < b.count {
                let raw12 = (Int(b[altOff]) << 4) | (Int(b[altOff + 1]) >> 4)
                let dec = Double(raw12) * 25.0 - 1000.0
                if dec >= -1_000 && dec <= 50_000 { altFt = dec }
            }

            result.append(Aircraft(id: slot.id, callsign: slot.id,
                                   latitude: lat, longitude: lon,
                                   altitude: altFt, track: 0, groundSpeed: 0, verticalRate: 0,
                                   lastUpdate: Date(), source: .adsb))
        }
        return result
    }

    /// Decode a 560-byte proprietary bundle as 8 × 70b sub-records.
    ///
    /// 560 = 8 × 70 exactly.  Each sub-record uses the same LE 1e-5 encoding confirmed
    /// for standalone 70b bundles: lat@(base+11), lon@(base+46), alt@(base+49).
    /// ICAO ID comes from bytes base+1,2,3 (same position as in 22b single-aircraft frames).
    private func decodeProprietaryBundle560(_ payload: Data) -> [Aircraft] {
        guard payload.count == 560 else { return [] }
        let b = Array(payload)
        let scale = 1.0 / 100_000.0

        func s24le(_ off: Int) -> Int32 {
            let v = Int32(b[off]) | Int32(b[off + 1]) << 8 | Int32(b[off + 2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }

        var result: [Aircraft] = []
        for i in 0..<8 {
            let base = i * 70
            let latOff = base + 11
            let lonOff = base + 46
            guard lonOff + 2 < b.count else { continue }

            let lat = Double(s24le(latOff)) * scale
            let lon = Double(s24le(lonOff)) * scale

            guard (-90...90).contains(lat), (-180...180).contains(lon) else { continue }
            guard abs(lat) > 1.0 || abs(lon) > 1.0 else { continue }
            if let loc = currentLocation,
               abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { continue }
            // Reject ownship echo.
            if let loc = currentLocation,
               abs(lat - loc.latitude) < ownshipRejectionRadius &&
               abs(lon - loc.longitude) < ownshipRejectionRadius { continue }

            let icaoHex = String(format: "%02X%02X%02X", b[base + 1], b[base + 2], b[base + 3])
            let acId = icaoHex == "000000" ? "B560_\(i)" : icaoHex

            let altOff = base + 49  // max(latOff-base, lonOff-base) + 3 = 46+3 = 49
            var altFt: Double = 10_000
            if altOff + 1 < b.count {
                let raw12 = (Int(b[altOff]) << 4) | (Int(b[altOff + 1]) >> 4)
                let dec = Double(raw12) * 25.0 - 1000.0
                if dec >= -1_000 && dec <= 50_000 { altFt = dec }
            }

            result.append(Aircraft(id: acId, callsign: acId,
                                   latitude: lat, longitude: lon,
                                   altitude: altFt, track: 0, groundSpeed: 0, verticalRate: 0,
                                   lastUpdate: Date(), source: .adsb))
        }
        return result
    }

    /// Cross-correlation scan for undecoded frame sizes (21b / 43b / 47b).
    ///
    /// Tries all (endian, latOff, latScale, lonOff, lonScale) combinations.
    /// Lat and lon may use DIFFERENT scales, covering standard GDL90 layout
    /// (lat: 180/2^24, lon: 360/2^24) as well as the proprietary 1e-5 format.
    ///
    /// References used (tightest wins):
    ///   • Internet aircraft (from adsb.lol) — ±0.10° lat, ±0.15° lon
    ///   • User GPS                          — ±0.20° lat, ±0.20° lon
    ///   • Other decoded ADS-B aircraft      — ±0.15° lat, ±0.15° lon
    ///
    /// Confirms once one candidate reaches ≥8 votes AND leads 3rd by ≥4.
    /// Per-size results stored in adsbDiag.undecodedXcorrResults[n].
    ///
    /// Must be called on the main thread.
    private func scanUndecodedFrame(_ payload: Data) {
        let n = payload.count
        // 47b frames are paired with 0x25 ownship (count always matches) — skip.
        guard n != 47 else { return }
        let b = Array(payload)

        // lat and lon are tried with all combinations of these scales.
        let scales: [Double] = [
            1.0 / 100_000.0,       // LE 1e-5 (confirmed for 70b/22b)
            180.0 / 16_777_216.0,  // GDL90 lat  (180°/2^24)
            360.0 / 16_777_216.0,  // GDL90 lon  (360°/2^24)
        ]
        let nsc = scales.count

        // Reference set.
        // With internet: ownship ±0.20° + all aircraft refs (internet ±0.10°, ADS-B ±0.15°).
        //   Many tight anchors → fast convergence from ground sessions.
        // Without internet (in-flight): ONLY ownship ±1.50° (≈90nm).
        //   Dropping 100+ ADS-B refs reduces false-positive surface from ~0.03% to ~0.014%
        //   per frame, keeping noise well below 1 vote while the true format accumulates
        //   hundreds of votes from aircraft within 90nm.
        struct Ref { let lat, lon, latTol, lonTol: Double }
        var refs: [Ref] = []
        let hasInternet = detectedAircraft.values.contains { $0.source == .internet }
        if let loc = currentLocation {
            let ownTol: Double = hasInternet ? 0.20 : 1.50
            refs.append(Ref(lat: loc.latitude, lon: loc.longitude, latTol: ownTol, lonTol: ownTol))
        }
        if hasInternet {
            for ac in detectedAircraft.values {
                let (lt, ln): (Double, Double) = ac.source == .internet ? (0.10, 0.15) : (0.15, 0.15)
                refs.append(Ref(lat: ac.latitude, lon: ac.longitude, latTol: lt, lonTol: ln))
            }
        }
        guard !refs.isEmpty else { return }

        let maxOff = n - 3
        guard maxOff >= 3 else { return }

        func s24le(_ i: Int) -> Double {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            let s = v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
            return Double(s)
        }
        func s24be(_ i: Int) -> Double {
            let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
            let s = v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
            return Double(s)
        }

        let sizePrefix = "\(n)b "

        for latOff in 0...maxOff {
            for lonOff in 0...maxOff {
                guard abs(lonOff - latOff) >= 3 else { continue }
                let rawLE_lat = s24le(latOff)
                let rawBE_lat = s24be(latOff)
                let rawLE_lon = s24le(lonOff)
                let rawBE_lon = s24be(lonOff)
                for lsi in 0..<nsc {
                    let latSc = scales[lsi]
                    let latLE = rawLE_lat * latSc
                    let latBE = rawBE_lat * latSc
                    guard (-90...90).contains(latLE) || (-90...90).contains(latBE) else { continue }
                    for msi in 0..<nsc {
                        let lonSc = scales[msi]
                        let lonLE = rawLE_lon * lonSc
                        let lonBE = rawBE_lon * lonSc
                        // LE
                        if (-90...90).contains(latLE), (-180...180).contains(lonLE),
                           abs(latLE) > 1 || abs(lonLE) > 1 {
                            for ref in refs where
                                abs(latLE - ref.lat) <= ref.latTol &&
                                abs(lonLE - ref.lon) <= ref.lonTol {
                                adsbDiag.undecodedXcorrVotes[
                                    "\(sizePrefix)LE lat@\(latOff)s\(lsi) lon@\(lonOff)s\(msi)",
                                    default: 0] += 1
                            }
                        }
                        // BE
                        if (-90...90).contains(latBE), (-180...180).contains(lonBE),
                           abs(latBE) > 1 || abs(lonBE) > 1 {
                            for ref in refs where
                                abs(latBE - ref.lat) <= ref.latTol &&
                                abs(lonBE - ref.lon) <= ref.lonTol {
                                adsbDiag.undecodedXcorrVotes[
                                    "\(sizePrefix)BE lat@\(latOff)s\(lsi) lon@\(lonOff)s\(msi)",
                                    default: 0] += 1
                            }
                        }
                    }
                }
            }
        }

        // Evaluate convergence for this specific frame size.
        let sizeVotes = adsbDiag.undecodedXcorrVotes.filter { $0.key.hasPrefix(sizePrefix) }
        guard let (bestKey, bestVotes) = sizeVotes.max(by: { $0.value < $1.value }) else { return }
        let top3 = Array(sizeVotes.values.sorted(by: >).prefix(3))
        let thirdVotes = top3.count > 2 ? top3[2] : 0

        // Store per-size result for HUD.
        adsbDiag.undecodedXcorrResults[n] = "🔍\(bestKey) ×\(bestVotes)/\(thirdVotes)"

        // Confirm at ≥8 votes with winner leading 3rd by ≥4.
        guard bestVotes >= 8, (bestVotes - thirdVotes) >= 4 else { return }

        // Parse the winning key: "\(n)b LE|BE lat@\(latOff)s\(lsi) lon@\(lonOff)s\(msi)"
        // e.g. "47b LE lat@5s1 lon@8s2"
        let parts = bestKey.components(separatedBy: " ")
        guard parts.count == 4,
              let isLE = (parts[1] == "LE" ? true : parts[1] == "BE" ? false : nil)
        else { return }
        let latStr = String(parts[2].dropFirst(4))  // "5s1"
        let lonStr = String(parts[3].dropFirst(4))  // "8s2"
        let latParts = latStr.components(separatedBy: "s")
        let lonParts = lonStr.components(separatedBy: "s")
        guard latParts.count == 2, lonParts.count == 2,
              let latOff = Int(latParts[0]), let lsi = Int(latParts[1]),
              let lonOff = Int(lonParts[0]), let msi = Int(lonParts[1]),
              lsi < nsc, msi < nsc else { return }

        adsbDiag.undecodedHits[n] = ADSBDiagnostics.UndecodedHit(
            isLE: isLE, latOff: latOff, lonOff: lonOff,
            latScale: scales[lsi], lonScale: scales[msi], votes: bestVotes)
        adsbDiag.undecodedXcorrResults[n] = "✅\(bestKey) ×\(bestVotes)"
        // Immediately decode the triggering frame so xcorrDecodedSamples is
        // populated right away — without this, the HUD position annotation only
        // appears after the NEXT frame of this size arrives.
        _ = decodeWithHit(payload, hit: adsbDiag.undecodedHits[n]!)
    }

    /// Decode a payload using a confirmed xcorr hit.
    /// Must be called on the main thread.
    private func decodeWithHit(_ payload: Data, hit: ADSBDiagnostics.UndecodedHit) -> Aircraft? {
        let b = Array(payload)
        let n = b.count
        guard hit.latOff + 2 < n, hit.lonOff + 2 < n else { return nil }

        func s24(_ i: Int) -> Int32 {
            if hit.isLE {
                let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
                return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
            } else {
                let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
                return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
            }
        }

        let lat = Double(s24(hit.latOff)) * hit.latScale
        let lon = Double(s24(hit.lonOff)) * hit.lonScale
        // Sample the raw decoded position before any rejection, so HUD can show
        // whether xcorr-converged frames encode ownship or actual traffic.
        if let loc = currentLocation {
            let nearGPS = abs(lat - loc.latitude) < 0.5 && abs(lon - loc.longitude) < 0.5
            adsbDiag.xcorrDecodedSamples[n] = ADSBDiagnostics.XcorrDecodedSample(
                lat: lat, lon: lon, nearGPS: nearGPS)
        }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        // Reject ownship echo.
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }

        // Tentative ICAO from b[1-3]; prefixed with 'U' + frame size to avoid
        // collisions with 22b ('S') and 70b ('T') aircraft.
        let icao = n >= 4
            ? String(format: "U%d%02X%02X%02X", n, b[1], b[2], b[3])
            : String(format: "U%d%02X", n, b[1])
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000, track: 0, groundSpeed: 0, verticalRate: 0,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Brute-force all 3-byte positions and scale factors in a 0x25 ownship frame
    /// to discover the proprietary lat/lon encoding by matching against the user's
    /// known GPS position. Must be called on the main thread.
    private func calibrateProprietaryEncoding(_ payload: Data, userLat: Double, userLon: Double) {
        let b = Array(payload)
        let n = b.count
        guard n >= 7 else { return }

        func s24(_ off: Int) -> Int32 {
            let v = Int32(b[off]) << 16 | Int32(b[off + 1]) << 8 | Int32(b[off + 2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }

        let scales: [Double] = [
            180.0 / 16_777_216.0,   // standard GDL90 lat
            360.0 / 16_777_216.0,   // standard GDL90 lon
            1.0 / 10_000.0,
            1.0 / 100_000.0,
        ]
        let latTol = 1.5   // degrees
        let lonTol = 2.5   // degrees

        for latOff in 1 ... (n - 3) {
            for latSc in scales {
                let lat = Double(s24(latOff)) * latSc
                guard abs(lat - userLat) <= latTol else { continue }
                for lonOff in 1 ... (n - 3) {
                    guard abs(lonOff - latOff) >= 3 else { continue }
                    for lonSc in scales {
                        let lon = Double(s24(lonOff)) * lonSc
                        guard abs(lon - userLon) <= lonTol else { continue }
                        adsbDiag.propLatByteOffset = latOff
                        adsbDiag.propLonByteOffset = lonOff
                        adsbDiag.propLatScale = latSc
                        adsbDiag.propLonScale = lonSc
                        adsbDiag.calibrationStatus = String(format:
                            "✅ lat@%d×%.2e=%.4f° lon@%d×%.2e=%.4f°",
                            latOff, latSc, lat, lonOff, lonSc, lon)
                        return
                    }
                }
            }
        }
        adsbDiag.calibrationStatus = String(format:
            "🔍 no match: target [%.4f, %.4f] in %db frame",
            userLat, userLon, n)
    }

    /// RF line-of-sight range check.  Returns false if the aircraft is geometrically
    /// unreachable given its altitude and the user's GPS altitude.
    /// physAlt: use 40000 ft for fallback-altitude aircraft (decoded as <15000 ft) so
    /// the check is conservative rather than rejecting real en-route traffic.
    private func isPhysicallyReceivable(_ ac: Aircraft) -> Bool {
        guard let loc = currentLocation else { return true }
        let userAltFt = max(currentAltitudeFeet, 0.0)
        let physAltFt: Double = (ac.altitude == 10_000) ? 40_000.0 : max(ac.altitude, 1_000.0)
        let maxRangeNm = (1.23 * sqrt(physAltFt) + 1.23 * sqrt(userAltFt)) * 1.1
        let dlat = ac.latitude  - loc.latitude
        let dlon = (ac.longitude - loc.longitude) * cos(loc.latitude * .pi / 180.0)
        let distNm = sqrt(dlat * dlat + dlon * dlon) * 60.0
        return distNm <= maxRangeNm
    }

    /// Ownship echo rejection radius in degrees.
    /// In flight the aircraft transponder GPS can disagree with the iPhone GPS by
    /// up to ~3 nm (different receivers, timing offset).  On the ground keep the
    /// radius tight (≈0.6 nm) so nearby taxiing aircraft are not suppressed.
    private var ownshipRejectionRadius: Double {
        currentAltitudeFeet > 5_000 ? 0.05 : 0.01
    }

    /// Decode a single-aircraft 22-byte 0x26 frame using calibration from voteForEncoding22.
    /// prop70RecordOffset == 0 signals this mode.
    private func decodeProprietarySingle(_ payload: Data) -> Aircraft? {
        guard payload.count == 22,
              let latOff = adsbDiag.propLatByteOffset,
              let lonOff = adsbDiag.propLonByteOffset,
              let latSc  = adsbDiag.propLatScale,
              let lonSc  = adsbDiag.propLonScale else { return nil }
        let b = Array(payload)
        func s24at(_ i: Int) -> Int32 {
            let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        guard latOff + 2 < b.count, lonOff + 2 < b.count else { return nil }
        let lat = Double(s24at(latOff)) * latSc
        let lon = Double(s24at(lonOff)) * lonSc
        guard lat >= -90 && lat <= 90, lon >= -180 && lon <= 180 else { return nil }
        // Reject positions >5° from user. Only ~3% of 22-byte frames are true position
        // frames; the rest carry velocity/identity data whose random bytes accidentally pass
        // the ±90/±180 range check, flooding detectedAircraft with phantom aircraft worldwide.
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        // Reject ownship echo (transponder GPS can differ from iPhone GPS by up to ~3 nm).
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        // Build a unique ICAO-style ID from the first 3 non-type bytes.
        let icao = String(format: "S%02X%02X%02X", b[1], b[2], b[3])
        // Try GDL90 altitude (12-bit packed) from the two bytes immediately after the
        // later coordinate field.  Only one offset is tried — a secondary fallback at
        // the earlier coordinate field produced spurious sub-zero altitudes (Build 190).
        let altOff = max(latOff, lonOff) + 3
        var altFt: Double = 10_000
        if altOff + 1 < b.count {
            let raw12 = (Int(b[altOff]) << 4) | (Int(b[altOff + 1]) >> 4)
            let dec = Double(raw12) * 25.0 - 1000.0
            if dec >= -1000 && dec <= 50_000 { altFt = dec }
        }
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: altFt, track: 0, groundSpeed: 0, verticalRate: 0,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 22b sub-type v2: LE lat@2 scale 1e-5, lon@5 scale 180/2^24.
    /// Confirmed via xcorr ×26 (Build 212 session 2). Supersedes BE lat@4/lon@9 ×11.
    private func decode22bV2(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(2)) * (1.0 / 100_000.0)
        let lon = Double(s24le(5)) * (180.0 / 16_777_216.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "V%02X%02X%02X", b[1], b[2], b[3])
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000, track: 0, groundSpeed: 0, verticalRate: 0,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Decode a 0x26 proprietary traffic frame using calibrated byte offsets.
    /// Returns nil if not yet calibrated, frame is too small, or position is invalid.
    /// Must be called on the main thread.
    private func decodeProprietaryTraffic(_ payload: Data) -> Aircraft? {
        guard let latOff = adsbDiag.propLatByteOffset,
              let lonOff = adsbDiag.propLonByteOffset,
              let latSc  = adsbDiag.propLatScale,
              let lonSc  = adsbDiag.propLonScale else { return nil }

        let b = Array(payload)
        let n = b.count
        guard n > max(latOff + 2, lonOff + 2) else { return nil }

        func s24(_ off: Int) -> Int32 {
            let v = Int32(b[off]) << 16 | Int32(b[off + 1]) << 8 | Int32(b[off + 2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }

        let lat = Double(s24(latOff)) * latSc
        let lon = Double(s24(lonOff)) * lonSc

        guard (-90 ... 90).contains(lat), (-180 ... 180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }  // reject near-zero

        // Reject positions >5° from user (same phantom-elimination logic as decodeProprietarySingle).
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }

        // Skip ownship echo.
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }

        // Use bytes [1-3] for ICAO, consistent with decodeProprietarySingle.
        // b[1] == 0x00 for TIS-B pseudo-addresses (same as 22b frames);
        // b[4] is a flags byte, not part of the ICAO.
        let icao = n >= 4
            ? String(format: "P%02X%02X%02X", b[1], b[2], b[3])
            : String(format: "P%02X%02d", b[1], n)

        // Try GDL90 altitude (12-bit packed) from the two bytes after the later coord field.
        let altOff = max(latOff, lonOff) + 3
        var altFt: Double = 10_000
        if altOff + 1 < n {
            let raw12 = (Int(b[altOff]) << 4) | (Int(b[altOff + 1]) >> 4)
            let dec = Double(raw12) * 25.0 - 1000.0
            if dec >= -1000 && dec <= 50_000 { altFt = dec }
        }
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: altFt, track: 0, groundSpeed: 0, verticalRate: 0,
                        lastUpdate: Date(), source: .adsb)
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
        // Do NOT evict internet aircraft immediately — they remain in detectedAircraft and
        // age out via the 90-second cleanup timer.  This gives the 70b cross-correlation
        // ~90 seconds of cached reference aircraft after switching to Sentry WiFi (which
        // has no internet), enabling xcorr to run against recently-seen traffic.
        DispatchQueue.main.async {
            self.internetAircraftCount = 0   // signal: live feed is down, but aircraft may still be cached
        }
    }

    private func fetchInternetData() {
        guard let loc = currentLocation else { return }
        lastInternetFetchTime = Date()
        let effectiveRadius = connectionStatus == .receiving ? max(internetQueryRadius, 200.0) : internetQueryRadius
        adsbLolClient.fetchAircraft(
            latitude: loc.latitude,
            longitude: loc.longitude,
            radiusNM: effectiveRadius
        ) { [weak self] result in
            switch result {
            case .success(let aircraft):
                self?.consecutiveInternetFailures = 0
                DispatchQueue.main.async { self?.adsbDiag.lastInternetFetchStatus = "" }
                self?.mergeInternetAircraft(aircraft)
            case .failure(let err):
                let msg = err.localizedDescription
                print("⚠️ adsb.lol fetch failed: \(msg)")
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.adsbDiag.lastInternetFetchStatus = msg
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
                    let netCount = merged.values.filter { $0.source == .internet }.count
                    self.internetAircraftCount = netCount
                    self.adsbDiag.lastInternetFetchCount = netCount
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
