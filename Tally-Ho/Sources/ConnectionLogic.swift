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
    /// Traffic decoded specifically from standard GDL90 0x14 frames (subset of parsedTraffic).
    var parsedStdTraffic: Int = 0
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
    /// Set when decode22bV3 (BE lat@10/lon@6 ×1e-5) successfully produces an aircraft.
    var calibrationV3Status: String? = nil
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
    /// 56b experimental hardcoded status shown in HUD (Build 220). Empty until first decode fires.
    var prop56bStatus: String = ""
    /// Raw hex of last successfully-decoded W frame, for ICAO hunting (Build 222).
    var prop56bLastDecodedHex: String = ""
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
    /// Ring buffer of the last 4 distinct 47-byte 0x26 frames, newest first.
    var recent47bFrames: [String] = []
    /// Ring buffer of the last 8 distinct 22-byte 0x26 frames that failed all decoders, newest first.
    var recent22bUndecodedFrames: [String] = []
    /// Ring buffer of the last 8 distinct 70-byte 0x26 frames, newest first.
    var recent70bFrames: [String] = []
    /// The raw bytes (space-separated hex) of the most recent 22b frame that successfully
    /// decoded an aircraft position. Lets us verify which bytes actually encode lat/lon.
    var capturedPositionFrameHex: String = ""
    /// Raw hex of last v2-decoded 22b frame (callsign: hex), for unknown-byte analysis.
    var capturedV2FrameHex: String = ""
    /// Raw hex of last v3-decoded 22b frame (callsign: hex), for unknown-byte analysis.
    var capturedV3FrameHex: String = ""
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
    /// Per-ICAO velocity decoded from ADS-B type-19 squitters.
    /// Key: 6-char uppercase hex ICAO from b[1-3] (e.g. "002FD2").
    /// Populated from type-19 ME fields inside position decoders and the undecoded handler.
    var adsbVelocityCache: [String: (track: Double, speed: Double, verticalRate: Double)] = [:]
    /// Last 22b v1/v2/v3 decoded frame for which decodeType19ME returned non-nil.
    /// Empty until a position-decoder path sees a type-19 ME. Used in share log only.
    var capturedVelFrameV1Hex: String = ""
    var capturedVelFrameV2Hex: String = ""
    var capturedVelFrameV3Hex: String = ""
    var calibrationV4Status: String? = nil
    var capturedV4FrameHex: String = ""
    var calibration47bStatus: String? = nil
    var captured47bHardcodedHex: String = ""
    var calibrationV5Status: String? = nil
    var capturedV5FrameHex: String = ""
    var calibrationV6Status: String? = nil
    var capturedV6FrameHex: String = ""
    var calibration47bV2Status: String? = nil
    var captured47bV2Hex: String = ""
    var calibration20bStatus: String? = nil
    var captured20bHex: String = ""
    var calibrationV7Status: String? = nil
    var capturedV7FrameHex: String = ""
    var calibration47bV3Status: String? = nil
    var captured47bV3Hex: String = ""
    var calibration43bV1Status: String? = nil
    var captured43bV1Hex: String = ""
    var calibrationV8Status: String? = nil
    var capturedV8FrameHex: String = ""
    var calibration47bV4Status: String? = nil
    var captured47bV4Hex: String = ""
    var calibrationV9Status: String? = nil
    var capturedV9FrameHex: String = ""
    var calibration47bV5Status: String? = nil
    var captured47bV5Hex: String = ""
    var calibration20bV2Status: String? = nil
    var captured20bV2Hex: String = ""
    var calibrationV10Status: String? = nil
    var capturedV10FrameHex: String = ""
    var calibration47bV6Status: String? = nil
    var captured47bV6Hex: String = ""
    var calibration47bV7Status: String? = nil
    var captured47bV7Hex: String = ""
    var calibration47bV8Status: String? = nil
    var captured47bV8Hex: String = ""
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

        // Always track raw message type for diagnostics.
        // frameSizeCounts is incremented only for 0x26 traffic frames (see case 0x26 below)
        // so the histogram shows the true distribution of proprietary traffic frame sizes,
        // not mixed with 0x25 ownship frames (e.g. 28b/47b ownship was inflating histogram).
        let frameSize = payload.count
        DispatchQueue.main.async {
            self.adsbDiag.rawMsgTypeCounts[msgType, default: 0] += 1
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
                        self.adsbDiag.parsedStdTraffic += 1
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
                // Count only 0x26 traffic frames so the histogram reflects actual traffic
                // distribution (not mixed with 0x25 ownship frames that share some sizes).
                self.adsbDiag.frameSizeCounts[copy26.count, default: 0] += 1
                let hex = copy26.map { String(format: "%02X", $0) }.joined(separator: " ")
                // Always refresh high-interest frame sizes so HUD stays current.
                // Other sizes: first-seen only. 28b removed: those frames are 0x25 ownship.
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
                } else if copy26.count == 47 {
                    if self.adsbDiag.recent47bFrames.first != hex {
                        self.adsbDiag.recent47bFrames.insert(hex, at: 0)
                        if self.adsbDiag.recent47bFrames.count > 4 {
                            self.adsbDiag.recent47bFrames.removeLast()
                        }
                    }
                } else if copy26.count == 70 {
                    if self.adsbDiag.recent70bFrames.first != hex {
                        self.adsbDiag.recent70bFrames.insert(hex, at: 0)
                        if self.adsbDiag.recent70bFrames.count > 8 {
                            self.adsbDiag.recent70bFrames.removeLast()
                        }
                    }
                }

                // 70b voting removed — encoding confirmed and hardcoded (Build 185).
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
                        self.adsbDiag.capturedV2FrameHex = "\(ac.callsign): \(hex)"
                    } else if let ac = self.decode22bV3(copy26), self.isPhysicallyReceivable(ac) {
                        // Capture internet-match label before adding to detectedAircraft
                        // to avoid a circular self-match in matchLabelForPosition.
                        let v3Tag: String? = self.adsbDiag.calibrationV3Status == nil
                            ? self.matchLabelForPosition(lat: ac.latitude, lon: ac.longitude)
                            : nil
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedV3FrameHex = "\(ac.callsign): \(hex)"
                        if let tag = v3Tag {
                            self.adsbDiag.calibrationV3Status = "✅22v3 BE lat@10 lon@6 ×1e-5\(tag.isEmpty ? "" : " \(tag)")"
                        }
                    } else if let ac = self.decode22bV4(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedV4FrameHex = "\(ac.callsign): \(hex)"
                        if self.adsbDiag.calibrationV4Status == nil {
                            self.adsbDiag.calibrationV4Status = "✅22v4 BE lat@12×1.00e-05 lon@8×1.00e-05 (hardcoded)"
                        }
                    } else if let ac = self.decode22bV5(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedV5FrameHex = "\(ac.callsign): \(hex)"
                        if self.adsbDiag.calibrationV5Status == nil {
                            self.adsbDiag.calibrationV5Status = "✅22v5 BE lat@12×1.00e-05 lon@16×1.00e-05 (hardcoded)"
                        }
                    } else if let ac = self.decode22bV6(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedV6FrameHex = "\(ac.callsign): \(hex)"
                        if self.adsbDiag.calibrationV6Status == nil {
                            self.adsbDiag.calibrationV6Status = "✅22v6 LE lat@7×2.15e-05 lon@2×1.00e-05 (hardcoded)"
                        }
                    } else if let ac = self.decode22bV7(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedV7FrameHex = "\(ac.callsign): \(hex)"
                        if self.adsbDiag.calibrationV7Status == nil {
                            self.adsbDiag.calibrationV7Status = "✅22v7 LE lat@0×1.00e-05 lon@5×1.00e-05 (hardcoded)"
                        }
                    } else if let ac = self.decode22bV8(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedV8FrameHex = "\(ac.callsign): \(hex)"
                        if self.adsbDiag.calibrationV8Status == nil {
                            self.adsbDiag.calibrationV8Status = "✅22v8 LE lat@12×1.00e-05 lon@3×1.00e-05 (hardcoded)"
                        }
                    } else if let ac = self.decode22bV9(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedV9FrameHex = "\(ac.callsign): \(hex)"
                        if self.adsbDiag.calibrationV9Status == nil {
                            self.adsbDiag.calibrationV9Status = "✅22v9 BE lat@2×1.07e-05 lon@16×1.07e-05 (hardcoded)"
                        }
                    } else if let ac = self.decode22bV10(copy26), self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        self.adsbDiag.capturedV10FrameHex = "\(ac.callsign): \(hex)"
                        if self.adsbDiag.calibrationV10Status == nil {
                            self.adsbDiag.calibrationV10Status = "✅22v10 LE lat@7×1.07e-05 lon@19×1.00e-05 (hardcoded)"
                        }
                    } else {
                        // Prefix each entry with the ME type code (b[8] high 5 bits) so the
                        // share log immediately shows which ADS-B squitter types are undecoded.
                        let bArr = Array(copy26)
                        let tcTagged = String(format: "tc%02d: %@", Int(bArr[8]) >> 3, hex)
                        if self.adsbDiag.recent22bUndecodedFrames.first != tcTagged {
                            self.adsbDiag.recent22bUndecodedFrames.insert(tcTagged, at: 0)
                            if self.adsbDiag.recent22bUndecodedFrames.count > 8 {
                                self.adsbDiag.recent22bUndecodedFrames.removeLast()
                            }
                        }
                        // Cache velocity from type-19 ME (e.g. position out of ±10° range).
                        if let vel = Self.decodeType19ME(bArr, meOffset: 8) {
                            let key = String(format: "%02X%02X%02X", bArr[1], bArr[2], bArr[3])
                            self.adsbDiag.adsbVelocityCache[key] = vel
                        }
                        let alreadySeen = self.adsbDiag.xcorrSeenFrames[22]?.contains(hex) ?? false
                        if !alreadySeen {
                            self.adsbDiag.xcorrSeenFrames[22, default: []].insert(hex)
                            self.scanUndecodedFrame(copy26)
                        }
                    }
                } else if copy26.count == 70 {
                    // 70b bundle — hardcoded LE 1e-5 lat@11/lon@46 (confirmed ×3, Build 185).
                    // xcorr disabled for 70b: ground sessions show 186+ internet aircraft which
                    // drive false convergence within seconds. The 70b frames encode distant/Atlantic
                    // aircraft not present in the local internet feed, so no real xcorr signal
                    // exists on the ground. Re-enable if an in-flight session confirms a new layout.
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
                    // 56b: dominant in-flight frame (500+/session).
                    // Decode priority: (1) hardcoded experimental, (2) xcorr hit, (3) xcorr scan.
                    // 20b/21b/43b/47b: previously labelled "not traffic"; now scanned via xcorr
                    // to detect if nearby aircraft are encoded here (may explain ForeFlight gap).
                    if copy26.count == 56 {
                        var decoded56 = false
                        // (1) Experimental hardcoded format: LE lat@52×1.07e-5 lon@18×1.00e-5.
                        if let ac = self.decode56bHardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            let wCount = self.adsbDiag.uniqueAircraftSeen.filter { $0.hasPrefix("W") }.count
                            let netTag = self.internetAircraftCount > 0
                                ? self.matchLabelForPosition(lat: ac.latitude, lon: ac.longitude)
                                : ""
                            let netNote = netTag.isEmpty ? "" : " \(netTag)"
                            self.adsbDiag.prop56bStatus = "HARDCODED LE lat@52×1.07e-05 lon@18×1.00e-05 (W×\(wCount))\(netNote)"
                            // Log raw bytes with <XX> marking 0xA0-0xAF bytes (US ICAO range).
                            let b = Array(copy26)
                            let hexParts = b.enumerated().map { (i, byte) -> String in
                                let h = String(format: "%02X", byte)
                                return (byte >= 0xA0 && byte <= 0xAF) ? "<\(h)>" : h
                            }
                            self.adsbDiag.prop56bLastDecodedHex = hexParts.joined(separator: " ")
                            decoded56 = true
                        }
                        // (2) xcorr confirmed hit (if present).
                        if !decoded56, let hit = self.adsbDiag.undecodedHits[56] {
                            if let ac = self.decodeWithHit(copy26, hit: hit),
                               self.isPhysicallyReceivable(ac) {
                                self.detectedAircraft[ac.id] = ac
                                self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                                self.adsbDiag.parsedTraffic += 1
                                decoded56 = true
                            }
                        }
                        // (3) xcorr scan for new unique frames so format can still be validated.
                        if !decoded56 {
                            let alreadySeen = self.adsbDiag.xcorrSeenFrames[56]?.contains(hex) ?? false
                            if !alreadySeen {
                                self.adsbDiag.xcorrSeenFrames[56, default: []].insert(hex)
                                self.scanUndecodedFrame(copy26)
                            }
                        }
                    } else {
                        // 20b / 21b / 43b / 47b: hardcoded 47b first, then xcorr hit, then scan.
                        let size = copy26.count
                        var decodedSmall = false
                        if copy26.count == 47,
                           let ac = self.decode47bHardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured47bHardcodedHex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration47bStatus == nil {
                                self.adsbDiag.calibration47bStatus = "✅47b LE lat@20×1.00e-05 lon@29×1.00e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 47,
                           let ac = self.decode47bV2Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured47bV2Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration47bV2Status == nil {
                                self.adsbDiag.calibration47bV2Status = "✅47b-v2 LE lat@39×1.00e-05 lon@29×1.00e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 20,
                           let ac = self.decode20bHardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured20bHex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration20bStatus == nil {
                                self.adsbDiag.calibration20bStatus = "✅20b LE lat@6×1.00e-05 lon@2×1.00e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 47,
                           let ac = self.decode47bV3Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured47bV3Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration47bV3Status == nil {
                                self.adsbDiag.calibration47bV3Status = "✅47b-v3 BE lat@17×1.07e-05 lon@33×1.00e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 43,
                           let ac = self.decode43bV1Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured43bV1Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration43bV1Status == nil {
                                self.adsbDiag.calibration43bV1Status = "✅43b-v1 LE lat@39×1.07e-05 lon@5×1.07e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 47,
                           let ac = self.decode47bV4Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured47bV4Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration47bV4Status == nil {
                                self.adsbDiag.calibration47bV4Status = "✅47b-v4 LE lat@27×1.00e-05 lon@30×2.15e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 47,
                           let ac = self.decode47bV5Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured47bV5Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration47bV5Status == nil {
                                self.adsbDiag.calibration47bV5Status = "✅47b-v5 LE lat@28×2.15e-05 lon@31×1.07e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 20,
                           let ac = self.decode20bV2Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured20bV2Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration20bV2Status == nil {
                                self.adsbDiag.calibration20bV2Status = "✅20b-v2 LE lat@6×1.07e-05 lon@11×1.00e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 47,
                           let ac = self.decode47bV6Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured47bV6Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration47bV6Status == nil {
                                self.adsbDiag.calibration47bV6Status = "✅47b-v6 LE lat@40×1.00e-05 lon@35×1.00e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 47,
                           let ac = self.decode47bV7Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured47bV7Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration47bV7Status == nil {
                                self.adsbDiag.calibration47bV7Status = "✅47b-v7 LE lat@38×1.07e-05 lon@25×1.00e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if copy26.count == 47,
                           let ac = self.decode47bV8Hardcoded(copy26),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            self.adsbDiag.captured47bV8Hex = "\(ac.callsign): \(hex)"
                            if self.adsbDiag.calibration47bV8Status == nil {
                                self.adsbDiag.calibration47bV8Status = "✅47b-v8 LE lat@11×2.15e-05 lon@34×1.07e-05 (hardcoded)"
                            }
                            decodedSmall = true
                        } else if let hit = self.adsbDiag.undecodedHits[size],
                           let ac = self.decodeWithHit(copy26, hit: hit),
                           self.isPhysicallyReceivable(ac) {
                            self.detectedAircraft[ac.id] = ac
                            self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                            self.adsbDiag.parsedTraffic += 1
                            decodedSmall = true
                        }
                        if !decodedSmall {
                            let alreadySeen = self.adsbDiag.xcorrSeenFrames[size]?.contains(hex) ?? false
                            if !alreadySeen {
                                self.adsbDiag.xcorrSeenFrames[size, default: []].insert(hex)
                                self.scanUndecodedFrame(copy26)
                            }
                        }
                    }
                } else if ![70, 22, 20, 21, 43, 47, 56, 560].contains(copy26.count) {
                    // Catch-all for any other frame size (e.g. 28b).
                    // Three-step fallback: xcorr hit → v1-calibrated → xcorr scan.
                    let size = copy26.count
                    var decodedCatchAll = false
                    // (1) xcorr-confirmed hit for this size (from a prior session).
                    if let hit = self.adsbDiag.undecodedHits[size],
                       let ac = self.decodeWithHit(copy26, hit: hit),
                       self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        decodedCatchAll = true
                    }
                    // (2) 22b-calibrated v1 offsets.
                    if !decodedCatchAll,
                       let ac = self.decodeProprietaryTraffic(copy26),
                       self.isPhysicallyReceivable(ac) {
                        self.detectedAircraft[ac.id] = ac
                        self.adsbDiag.uniqueAircraftSeen.insert(ac.id)
                        self.adsbDiag.parsedTraffic += 1
                        decodedCatchAll = true
                    }
                    // (3) xcorr scan for new unique frames so the format can be discovered.
                    // scanUndecodedFrame silently skips 47b via its own guard.
                    if !decodedCatchAll {
                        let alreadySeen = self.adsbDiag.xcorrSeenFrames[size]?.contains(hex) ?? false
                        if !alreadySeen {
                            self.adsbDiag.xcorrSeenFrames[size, default: []].insert(hex)
                            self.scanUndecodedFrame(copy26)
                        }
                    }
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

        // 48-byte variable section (b[2-49]) is three 16-byte sub-records.
        // Each sub-record: 2b header | 3b lat (internal+2) | 7b middle | 3b lon (internal+12) | 1b tail.
        // Slot C (lat@36/lon@46) is structurally confirmed: bytes 34-49 repeat across frames
        // encoding the same persistent aircraft.  Slots A/B decode the variable traffic region.
        let slots: [(latOff: Int, lonOff: Int, id: String)] = [
            ( 4, 14, "T70A"),
            (20, 30, "T70B"),
            (36, 46, "T70C"),
        ]

        var result: [Aircraft] = []
        for slot in slots {
            guard slot.lonOff + 2 < b.count else { continue }
            let lat = Double(s24le(slot.latOff)) * scale
            let lon = Double(s24le(slot.lonOff)) * scale

            guard (-90...90).contains(lat), (-180...180).contains(lon) else { continue }
            guard abs(lat) > 1.0 || abs(lon) > 1.0 else { continue }
            // Reject positions more than 3° from user (~200nm) — tighter than generic 10° guard
            // because 70b positions validated to always be ≥100nm away when decoded incorrectly.
            if let loc = currentLocation,
               abs(lat - loc.latitude) > 4 || abs(lon - loc.longitude) > 4 { continue }
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
            // Same 3 × 16-byte sub-record layout as standalone 70b bundles.
            let subSlots: [(latOff: Int, lonOff: Int, suffix: String)] = [
                (base +  4, base + 14, "A"),
                (base + 20, base + 30, "B"),
                (base + 36, base + 46, "C"),
            ]
            for slot in subSlots {
            guard slot.lonOff + 2 < b.count else { continue }

            let lat = Double(s24le(slot.latOff)) * scale
            let lon = Double(s24le(slot.lonOff)) * scale

            guard (-90...90).contains(lat), (-180...180).contains(lon) else { continue }
            guard abs(lat) > 1.0 || abs(lon) > 1.0 else { continue }
            if let loc = currentLocation,
               abs(lat - loc.latitude) > 4 || abs(lon - loc.longitude) > 4 { continue }
            // Reject ownship echo.
            if let loc = currentLocation,
               abs(lat - loc.latitude) < ownshipRejectionRadius &&
               abs(lon - loc.longitude) < ownshipRejectionRadius { continue }

            let acId = "B560_\(i)\(slot.suffix)"

            let altOff = slot.lonOff + 3
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
            } // for slot in subSlots
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
    private func scanUndecodedFrame(_ payload: Data, maxByte: Int? = nil) {
        let n = payload.count
        let b = Array(payload)

        // lat and lon are tried with all combinations of these scales.
        let scales: [Double] = [
            1.0 / 100_000.0,       // LE 1e-5 (confirmed for 70b/22b)
            180.0 / 16_777_216.0,  // GDL90 lat  (180°/2^24)
            360.0 / 16_777_216.0,  // GDL90 lon  (360°/2^24)
        ]
        let nsc = scales.count

        // Reference set.
        // Internet aircraft (±0.10°/0.15°) used only when live feed is active.
        // ADS-B decoded aircraft (±0.15°) used ALWAYS, even offline. Their diverse
        //   positions break the systematic adjacent-offset correlation that keeps
        //   the ownship-only xcorr gap at ≤2: with 30-50 refs spanning 20+° lon,
        //   competing offset candidates can't match all refs, growing the gap to 20+.
        // Ownship (±1.50°) catches 56b aircraft not in the ADS-B list.
        // Expected noise: ~3.4 votes/candidate (ownship 2.2 + ADS-B refs 1.2).
        // Expected signal: 20-50 votes (ADS-B ref matches + ownship-only aircraft).
        struct Ref { let lat, lon, latTol, lonTol: Double }
        var refs: [Ref] = []
        let hasInternet = internetAircraftCount > 0
        if let loc = currentLocation {
            let ownTol: Double = hasInternet ? 0.20 : 1.50
            refs.append(Ref(lat: loc.latitude, lon: loc.longitude, latTol: ownTol, lonTol: ownTol))
        }
        for ac in detectedAircraft.values where ac.source == .adsb {
            refs.append(Ref(lat: ac.latitude, lon: ac.longitude, latTol: 0.15, lonTol: 0.15))
        }
        if hasInternet {
            for ac in detectedAircraft.values where ac.source == .internet {
                refs.append(Ref(lat: ac.latitude, lon: ac.longitude, latTol: 0.10, lonTol: 0.15))
            }
        }
        guard !refs.isEmpty else { return }
        // Once a hit is confirmed for this frame size, xcorr has done its job.
        // Stop scanning so the ✅ display is preserved and the hit is never overwritten.
        guard adsbDiag.undecodedHits[n] == nil else { return }

        let maxOff = min(maxByte ?? n, n) - 3
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
        // Require a GPS fix: without currentLocation the position-validation check in
        // the commit block below is a no-op, allowing noise to pass (seen in Build 238
        // when xcorr converged within seconds of app launch before GPS was ready).
        guard bestVotes >= 14, (bestVotes - thirdVotes) >= 6, currentLocation != nil else { return }

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

        let proposedHit = ADSBDiagnostics.UndecodedHit(
            isLE: isLE, latOff: latOff, lonOff: lonOff,
            latScale: scales[lsi], lonScale: scales[msi], votes: bestVotes)
        // Validate before committing: decoded position must be within 10° of the user.
        // Dense internet-aircraft references (200+ ground aircraft) can drive false
        // convergence to offsets that produce geographically distant positions.
        // If decodeWithHit returns nil, wipe votes for this frame size so xcorr can
        // start accumulating again on subsequent frames (typically in-flight with fewer
        // and closer references).
        if let ac = decodeWithHit(payload, hit: proposedHit), isPhysicallyReceivable(ac) {
            adsbDiag.undecodedHits[n] = proposedHit
            adsbDiag.undecodedXcorrResults[n] = "✅\(bestKey) ×\(bestVotes)"
            _ = decodeWithHit(payload, hit: proposedHit)
        } else {
            adsbDiag.undecodedXcorrVotes = adsbDiag.undecodedXcorrVotes.filter {
                !$0.key.hasPrefix(sizePrefix)
            }
            adsbDiag.xcorrSeenFrames[n] = nil
            adsbDiag.undecodedXcorrResults[n] = "🔄\(bestKey) ×\(bestVotes) (far→reset)"
        }
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
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        var vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        if let v = Self.decodeType19ME(b, meOffset: 8) {
            vel = v
            adsbDiag.adsbVelocityCache[icaoKey] = v
            adsbDiag.capturedVelFrameV1Hex = "\(icao): \(b.map { String(format: "%02X", $0) }.joined(separator: " "))"
        }
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: altFt,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
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
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        var vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        if let v = Self.decodeType19ME(b, meOffset: 8) {
            vel = v
            adsbDiag.adsbVelocityCache[icaoKey] = v
            adsbDiag.capturedVelFrameV2Hex = "\(icao): \(b.map { String(format: "%02X", $0) }.joined(separator: " "))"
        }
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// 22b sub-type v3: BE lat@10 ×1e-5, lon@6 ×1e-5.
    /// Inferred from single-frame xcorr match (RPA4574 Δlat=0.030° Δlon=0.060°, Build 235).
    private func decode22bV3(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24be(_ i: Int) -> Int32 {
            let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24be(10)) * (1.0 / 100_000.0)
        let lon = Double(s24be(6))  * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "X%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        var vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        if let v = Self.decodeType19ME(b, meOffset: 13) {
            vel = v
            adsbDiag.adsbVelocityCache[icaoKey] = v
            adsbDiag.capturedVelFrameV3Hex = "\(icao): \(b.map { String(format: "%02X", $0) }.joined(separator: " "))"
        }
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// 22b sub-type v4: BE lat@12 ×1e-5, lon@8 ×1e-5.
    /// Confirmed by xcorr ×3/3 in undecoded 22b frames (Build 254). Prefix "B".
    private func decode22bV4(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24be(_ i: Int) -> Int32 {
            let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24be(12)) * (1.0 / 100_000.0)
        let lon = Double(s24be(8))  * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "B%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// 22b sub-type v5: BE lat@12 ×1e-5, lon@16 ×1e-5.
    /// Confirmed by xcorr ×3/3 in undecoded 22b frames (Build 255). Prefix "C".
    private func decode22bV5(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24be(_ i: Int) -> Int32 {
            let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24be(12)) * (1.0 / 100_000.0)
        let lon = Double(s24be(16)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "C%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 47b decoder: LE lat@20 ×1e-5, lon@29 ×1e-5.
    /// Confirmed by xcorr ×2/2 (Build 254 ground session). Prefix "F". 165 frames/session.
    private func decode47bHardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 47 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(20)) * (1.0 / 100_000.0)
        let lon = Double(s24le(29)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "F%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// 22b sub-type v6: LE lat@7 ×(360/2^24), lon@2 ×1e-5.
    /// Confirmed by xcorr ×8/8 (Build 256). Prefix "D".
    private func decode22bV6(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(7)) * (360.0 / 16_777_216.0)
        let lon = Double(s24le(2)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "D%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 47b decoder v2: LE lat@39 ×1e-5, lon@29 ×1e-5.
    /// Confirmed by xcorr ×4/4 (Build 256). Prefix "G".
    private func decode47bV2Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 47 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(39)) * (1.0 / 100_000.0)
        let lon = Double(s24le(29)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "G%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 20b decoder: LE lat@6 ×1e-5, lon@2 ×1e-5.
    /// Confirmed by xcorr ×3/3 (Build 256). Prefix "E".
    private func decode20bHardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 20 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(6)) * (1.0 / 100_000.0)
        let lon = Double(s24le(2)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "E%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// 22b sub-type v7: LE lat@0 ×1e-5, lon@5 ×1e-5.
    /// Confirmed by xcorr ×5/4 (Build 257). Prefix "H".
    /// Note: b[0]=0x26, b[1]=0x00 are constant; lat precision anchored by low byte 0x26.
    private func decode22bV7(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(0)) * (1.0 / 100_000.0)
        let lon = Double(s24le(5)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "H%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 47b decoder v3: BE lat@17 ×(180/2^24), lon@33 ×1e-5.
    /// Confirmed by xcorr ×2/2 (Build 257). Prefix "J".
    private func decode47bV3Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 47 else { return nil }
        let b = Array(payload)
        func s24be(_ i: Int) -> Int32 {
            let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24be(17)) * (180.0 / 16_777_216.0)
        let lon = Double(s24le(33)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "J%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 43b decoder v1: LE lat@39 ×(180/2^24), lon@5 ×(180/2^24).
    /// Confirmed by xcorr ×2/2 (Build 257). Prefix "K".
    private func decode43bV1Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 43 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(39)) * (180.0 / 16_777_216.0)
        let lon = Double(s24le(5))  * (180.0 / 16_777_216.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "K%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// 22b sub-type v8: LE lat@12 ×1e-5, lon@3 ×1e-5.
    /// Confirmed by xcorr ×4/3 (Build 258). Prefix "L".
    private func decode22bV8(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(12)) * (1.0 / 100_000.0)
        let lon = Double(s24le(3))  * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "L%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 47b decoder v4: LE lat@27 ×1e-5, lon@30 ×(360/2^24).
    /// Confirmed by xcorr ×2/2 (Build 258). Prefix "M".
    private func decode47bV4Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 47 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(27)) * (1.0 / 100_000.0)
        let lon = Double(s24le(30)) * (360.0 / 16_777_216.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "M%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// 22b sub-type v9: BE lat@2 ×(180/2^24), lon@16 ×(180/2^24).
    /// Confirmed by xcorr ×3/3 (Build 259). Prefix "N".
    private func decode22bV9(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24be(_ i: Int) -> Int32 {
            let v = Int32(b[i]) << 16 | Int32(b[i+1]) << 8 | Int32(b[i+2])
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24be(2))  * (180.0 / 16_777_216.0)
        let lon = Double(s24be(16)) * (180.0 / 16_777_216.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "N%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 47b decoder v5: LE lat@28 ×(360/2^24), lon@31 ×(180/2^24).
    /// Confirmed by xcorr ×5/3 (Build 259). Prefix "P".
    private func decode47bV5Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 47 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(28)) * (360.0 / 16_777_216.0)
        let lon = Double(s24le(31)) * (180.0 / 16_777_216.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "P%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 20b decoder v2: LE lat@6 ×(180/2^24), lon@11 ×1e-5.
    /// Confirmed by xcorr ×2/2 (Build 259). Prefix "Q".
    /// 22b sub-type v10: LE lat@7 ×(180/2^24), lon@19 ×1e-5.
    /// Confirmed by xcorr ×3/3 (Build 260). Prefix "R".
    private func decode22bV10(_ payload: Data) -> Aircraft? {
        guard payload.count == 22 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(7))  * (180.0 / 16_777_216.0)
        let lon = Double(s24le(19)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "R%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 47b decoder v8: LE lat@11 ×(360/2^24), lon@34 ×(180/2^24).
    /// Confirmed by xcorr ×3/3 (Build 262 session 16:26Z). Prefix "A".
    private func decode47bV8Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 47 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(11)) * (360.0 / 16_777_216.0)
        let lon = Double(s24le(34)) * (180.0 / 16_777_216.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "A%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 47b decoder v7: LE lat@38 ×(180/2^24), lon@25 ×1e-5.
    /// Confirmed by xcorr ×4/3 (Build 261 session 15:59Z). Prefix "W".
    private func decode47bV7Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 47 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(38)) * (180.0 / 16_777_216.0)
        let lon = Double(s24le(25)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "W%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Hardcoded 47b decoder v6: LE lat@40 ×1e-5, lon@35 ×1e-5.
    /// Confirmed by xcorr ×3/3 (Build 260). Prefix "U".
    private func decode47bV6Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 47 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(40)) * (1.0 / 100_000.0)
        let lon = Double(s24le(35)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "U%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    private func decode20bV2Hardcoded(_ payload: Data) -> Aircraft? {
        guard payload.count == 20 else { return nil }
        let b = Array(payload)
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(6))  * (180.0 / 16_777_216.0)
        let lon = Double(s24le(11)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "Q%02X%02X%02X", b[1], b[2], b[3])
        let icaoKey = String(format: "%02X%02X%02X", b[1], b[2], b[3])
        let vel = adsbDiag.adsbVelocityCache[icaoKey] ?? (track: 0, speed: 0, verticalRate: 0)
        return Aircraft(id: icao, callsign: icao,
                        latitude: lat, longitude: lon,
                        altitude: 10_000,
                        track: vel.track, groundSpeed: vel.speed, verticalRate: vel.verticalRate,
                        lastUpdate: Date(), source: .adsb)
    }

    /// Decode ADS-B type-19 (airborne velocity) ME field starting at byte offset `o`.
    /// Handles subtype 1 (ground speed EW/NS vectors) and subtypes 3/4 (true airspeed +
    /// magnetic heading, when heading-status bit is set). Returns (track°, speed kt, 0) or nil.
    /// VR is not extracted — ADS-B VR bits produce unreliable values in this frame format.
    private static func decodeType19ME(_ b: [UInt8], meOffset o: Int)
        -> (track: Double, speed: Double, verticalRate: Double)? {
        guard o + 6 < b.count else { return nil }
        guard (b[o] & 0xF8) == 0x98 else { return nil }  // type code 19
        let subtype = Int(b[o] & 0x07)
        switch subtype {
        case 1:
            // Ground speed: EW and NS velocity components.
            let ewDir = (Int(b[o+1]) >> 2) & 1     // 0=east, 1=west
            let ewRaw = ((Int(b[o+1]) & 0x03) << 8) | Int(b[o+2])
            let nsDir = Int(b[o+3]) >> 7            // 0=north, 1=south
            let nsRaw = ((Int(b[o+3]) & 0x7F) << 3) | (Int(b[o+4]) >> 5)
            guard ewRaw > 0, nsRaw > 0 else { return nil }
            let ew = Double(ewRaw - 1) * (ewDir == 0 ? 1.0 : -1.0)
            let ns = Double(nsRaw - 1) * (nsDir == 0 ? 1.0 : -1.0)
            let speed = (ew * ew + ns * ns).squareRoot()
            guard speed > 0, speed < 700 else { return nil }
            let track = (atan2(ew, ns) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360.0)
            return (track: track, speed: speed, verticalRate: 0)
        case 3, 4:
            // True airspeed + magnetic heading (when heading-status bit is set).
            guard (Int(b[o+1]) >> 2) & 1 == 1 else { return nil }
            let hdgRaw = ((Int(b[o+1]) & 0x03) << 8) | Int(b[o+2])
            let spdRaw = ((Int(b[o+3]) & 0x7F) << 3) | (Int(b[o+4]) >> 5)
            guard spdRaw > 0 else { return nil }
            let speed = Double(spdRaw - 1) * (subtype == 4 ? 4.0 : 1.0)
            guard speed > 0, speed < 700 else { return nil }
            let track = Double(hdgRaw) * (360.0 / 1024.0)
            return (track: track, speed: speed, verticalRate: 0)
        default:
            return nil
        }
    }

    /// Internet-match label for a decoded (lat,lon): "[net]" within ±0.10° of an internet
    /// aircraft, "[adsb]" within ±0.15° of an ADS-B aircraft, "" otherwise. Call on main.
    func matchLabelForPosition(lat: Double, lon: Double) -> String {
        for ac in detectedAircraft.values {
            if ac.source == .internet,
               abs(lat - ac.latitude) <= 0.10,
               abs(lon - ac.longitude) <= 0.10 { return "[net:\(ac.callsign)]" }
        }
        for ac in detectedAircraft.values {
            if ac.source == .adsb,
               !ac.id.hasPrefix("W"),
               abs(lat - ac.latitude) <= 0.15,
               abs(lon - ac.longitude) <= 0.15 { return "[adsb:\(ac.id)]" }
        }
        return ""
    }

    /// Experimental hardcoded 56b decoder: LE lat@52 ×(180/2²⁴), lon@18 ×1e-5.
    /// Candidate from 4 consecutive cruise HUDs at ×10/9 (Build 218). W-prefix IDs.
    private func decode56bHardcoded(_ payload: Data) -> Aircraft? {
        let b = Array(payload)
        guard b.count == 56 else { return nil }
        func s24le(_ i: Int) -> Int32 {
            let v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            return v & 0x800000 != 0 ? v | Int32(bitPattern: 0xFF000000) : v
        }
        let lat = Double(s24le(52)) * (180.0 / 16_777_216.0)
        let lon = Double(s24le(18)) * (1.0 / 100_000.0)
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        guard abs(lat) > 1.0 || abs(lon) > 1.0 else { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) > 10 || abs(lon - loc.longitude) > 10 { return nil }
        if let loc = currentLocation,
           abs(lat - loc.latitude) < ownshipRejectionRadius &&
           abs(lon - loc.longitude) < ownshipRejectionRadius { return nil }
        let icao = String(format: "W%02X%02X%02X", b[1], b[2], b[3])
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
