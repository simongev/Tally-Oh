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

    /// True when the source reported the aircraft as on the ground: the GDL90 Misc airborne
    /// bit clear, or adsb.lol sending "ground" in place of a barometric altitude.
    var isOnGround: Bool = false

    /// False when the source reported no usable altitude. Keeping this separate from a 0 ft
    /// reading matters: traffic on the ground at a 5,400 ft field would otherwise be placed
    /// a mile below the viewer instead of on the airfield.
    var hasValidAltitude: Bool = true

    /// False when the source reported no usable direction, in which case the position must
    /// not be dead-reckoned along `track`.
    var hasValidTrack: Bool = true

    /// The target's altitude as reported in each vertical datum, kept separately from
    /// `altitude` (which is whichever one the app currently places against).
    ///
    /// Carrying both is what makes the local pressure-to-geometric conversion measurable:
    /// every aircraft that reports both is measuring it for us at its own position. GDL90
    /// traffic reports carry only pressure altitude, so `geometricAltitudeFt` is nil there.
    var pressureAltitudeFt: Double?
    var geometricAltitudeFt: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Whether this aircraft should be treated as ground traffic for display filtering.
    /// Prefers the source's own on-ground flag and falls back to the altitude heuristic,
    /// which is only meaningful for aircraft that actually reported an altitude.
    var isGroundTraffic: Bool {
        if isOnGround { return true }
        return hasValidAltitude && altitude <= 50
    }
}

// MARK: - ConnectionLogic

class ConnectionLogic: ObservableObject {

    // MARK: Published

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var detectedAircraft: [String: Aircraft] = [:]
    @Published var ownshipData: Aircraft?           // GPS/altitude from ADS-B ownship report
    /// Receiver GNSS altitude above the WGS-84 ellipsoid, from GDL90 message 0x0B.
    @Published var ownshipGeometricAltitudeFt: Double?

    /// Set by the owner so ADS-B ownship reports feed the single ownship estimator directly,
    /// carrying their own timestamps instead of being resampled by the 4 Hz UI tick.
    weak var ownshipEstimator: OwnshipEstimator?
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

    /// Hard cap on total internet aircraft stored, applied by distance so the set kept is
    /// always the closest N. Bounds the dictionary that is copied on every update tick;
    /// beyond this, additional distant traffic adds cost without adding awareness.
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
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
        ownshipEstimator?.clearADSB()
        DispatchQueue.main.async {
            self.connectionStatus = .disconnected
            self.detectedAircraft.removeAll()
            self.ownshipData = nil
            self.ownshipGeometricAltitudeFt = nil
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
                // Drop the receiver's ownship state as well, so a position frozen ten seconds
                // ago cannot keep winning source selection over the phone's live GPS.
                self.ownshipEstimator?.clearADSB()
                FlightRecorder.shared.record(event: "adsb_signal_lost")
                DispatchQueue.main.async {
                    self.connectionStatus = .searching
                    print("⚠️ ADS-B signal lost")
                }
            }
        }
    }

    private func processGDL90Data(_ data: Data) {
        // Framing, byte-unstuffing and CRC verification all live in GDL90.extractMessages.
        // Only messages that pass CRC reach the parser, so a corrupted datagram can no longer
        // surface as an aircraft that jumps across the sky.
        let extraction = GDL90.extractMessages(from: data)
        FlightRecorder.shared.recordGDL90(
            valid: extraction.messages.count,
            crcFailures: extraction.crcFailures,
            malformed: extraction.malformed
        )
        for message in extraction.messages {
            handleGDL90Message(message)
        }
    }

    private func handleGDL90Message(_ message: [UInt8]) {
        guard let messageID = message.first else { return }
        let receivedAt = Date()

        switch messageID {
        case GDL90.MessageID.ownshipReport.rawValue:
            guard let report = GDL90.parseTrafficReport(message) else { return }
            let hasPosition = report.latitude != 0 || report.longitude != 0
            // Feed the estimator straight from the receiver queue, with this report's own
            // arrival time and its own velocity, so coasting between the ~1 Hz reports does
            // not borrow the phone's timestamp or course.
            ownshipEstimator?.ingestADSBOwnship(
                coordinate: hasPosition
                    ? CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude)
                    : nil,
                pressureAltitudeFt: report.pressureAltitudeFt,
                groundSpeedKt: report.groundSpeedKt,
                trackDeg: report.track,
                verticalRateFpm: report.verticalRateFpm,
                timestamp: receivedAt
            )
            let aircraft = makeAircraft(from: report, isOwnship: true, receivedAt: receivedAt)
            DispatchQueue.main.async { self.ownshipData = aircraft }

        case GDL90.MessageID.ownshipGeometricAltitude.rawValue:
            // Previously discarded. This is the receiver's GNSS altitude, which is the only
            // ownship vertical reference that stays valid in a pressurized cabin.
            guard let geometric = GDL90.parseOwnshipGeometricAltitude(message) else { return }
            ownshipEstimator?.ingestADSBGeometricAltitude(
                heightAboveEllipsoidFt: geometric.heightAboveEllipsoidFt,
                timestamp: receivedAt
            )
            DispatchQueue.main.async {
                self.ownshipGeometricAltitudeFt = geometric.heightAboveEllipsoidFt
            }

        case GDL90.MessageID.trafficReport.rawValue:
            guard let report = GDL90.parseTrafficReport(message) else { return }
            let aircraft = makeAircraft(from: report, isOwnship: false, receivedAt: receivedAt)
            DispatchQueue.main.async { self.detectedAircraft[aircraft.id] = aircraft }

        default:
            break
        }
    }

    /// Convert a decoded GDL90 report into the app's aircraft model, preserving the
    /// "value not available" cases rather than collapsing them to zero.
    ///
    /// Note on direction: GDL90 allows the track field to carry a magnetic heading instead of
    /// a true track (Misc bits 1-0). ADS-B Out installations report true track for airborne
    /// targets, so this is rare; when it happens the value is used as reported, which costs at
    /// most a declination-sized error over the few seconds a target is coasted.
    private func makeAircraft(
        from report: GDL90.TrafficReport,
        isOwnship: Bool,
        receivedAt: Date
    ) -> Aircraft {
        Aircraft(
            id:           isOwnship ? "OWNSHIP" : report.icaoAddress,
            callsign:     report.callsign,
            latitude:     report.latitude,
            longitude:    report.longitude,
            altitude:     report.pressureAltitudeFt ?? 0,
            track:        report.track ?? 0,
            groundSpeed:  report.groundSpeedKt ?? 0,
            verticalRate: report.verticalRateFpm ?? 0,
            lastUpdate:   receivedAt,
            source:       .adsb,
            isOnGround:       !report.isAirborne,
            hasValidAltitude: report.pressureAltitudeFt != nil,
            hasValidTrack:    report.track != nil,
            pressureAltitudeFt:  report.pressureAltitudeFt,
            geometricAltitudeFt: nil   // GDL90 traffic reports carry pressure altitude only
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
                    // The path really is gone, so stored internet traffic cannot be refreshed
                    // and will only get older. This is the case the discard was written for.
                    self?.stopInternetFetching(discardingStoredTraffic: true)
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

    /// Stop polling adsb.lol.
    ///
    /// `discardingStoredTraffic` exists because these are two very different things and
    /// conflating them cost a flight's worth of traffic. Dropping the stored aircraft is right
    /// when the network path itself has gone away, and wrong when a few HTTP requests failed:
    /// ninety-second-old traffic beats an empty sky, and the app already draws stale targets
    /// honestly — `isStale` dashes their rings and `n_stale` records them.
    private func stopInternetFetching(discardingStoredTraffic: Bool) {
        internetFetchTimer?.invalidate()
        internetFetchTimer = nil
        guard discardingStoredTraffic else { return }
        DispatchQueue.main.async {
            let before = self.detectedAircraft.count
            self.detectedAircraft = self.detectedAircraft.filter { $0.value.source == .adsb }
            let removed = before - self.detectedAircraft.count
            if removed > 0 {
                FlightRecorder.shared.record(
                    event: "traffic_purged",
                    detail: "removed=\(removed) reason=network_path_down"
                )
            }
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
                    FlightRecorder.shared.record(
                        event: "internet_fetch_failed",
                        detail: "consecutive=\(self.consecutiveInternetFailures) stored=\(self.detectedAircraft.count)"
                    )
                    if self.consecutiveInternetFailures >= self.maxInternetFailuresBeforeOffline {
                        // Back off polling — but keep every aircraft already stored.
                        //
                        // This used to also wipe them, justified by a comment claiming no
                        // internet aircraft could be stored because all fetches had failed.
                        // That is only true of a cold start on a hotspot with no internet.
                        // The counter resets on every success, so reaching three says nothing
                        // about what is in the store: one flight ran for 85 seconds holding five
                        // aircraft, hit a momentary cabin-wifi glitch, and had all five deleted
                        // in a single tick, leaving an empty sky at FL350.
                        //
                        // isInternetAvailable is also deliberately left alone. HTTP failing is
                        // not the network path being down, and forcing the flag false made
                        // recovery wait on a path change that never came, because the path had
                        // never actually dropped. NWPathMonitor owns that flag.
                        //
                        // The 30 s cleanup timer ages these out on aircraftTimeout, which is its
                        // job, and ensureInternetFetchRunning restarts polling on the next fix.
                        self.stopInternetFetching(discardingStoredTraffic: false)
                    }
                }
            }
        }
    }

    /// Seed detectedAircraft with a list fetched ahead of time (e.g. during the
    /// calibration screen), so aircraft are visible on the very first frame
    /// instead of waiting for the first regular fetch's network round-trip.
    /// Runs through the exact same filter/cap/dedup logic as a normal fetch.
    func seedInternetAircraft(_ list: [Aircraft]) {
        mergeInternetAircraft(list)
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

                    // Every aircraft in range is taken here. The cap is applied afterwards,
                    // by distance, rather than by refusing new arrivals: filling it in the
                    // order the API happened to return meant that in dense airspace the
                    // hundred stored aircraft were an arbitrary hundred, and once full no
                    // new aircraft could enter for 90 seconds — so the nearest traffic, the
                    // traffic that matters most, was routinely the traffic left out.
                    ac.lastUpdate = fetchTime
                    updates[ac.id] = ac
                }

                guard !updates.isEmpty else { return }

                // ── Step 3: merge on main thread — one @Published fire ──────────────
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    var merged = self.detectedAircraft
                    for (id, ac) in updates { merged[id] = ac }

                    // Enforce the cap by keeping the closest aircraft, so a nearer target can
                    // always displace a more distant one. Aircraft received earlier that have
                    // since flown away are the first to go.
                    if let here = self.currentLocation {
                        let internetIDs = merged.filter { $0.value.source == .internet }
                        if internetIDs.count > cap {
                            let byDistance = internetIDs
                                .map { (id: $0.key,
                                        distNM: CalculationsLogic.distanceInNauticalMiles(
                                            from: here, to: $0.value.coordinate)) }
                                .sorted { $0.distNM < $1.distNM }
                            for entry in byDistance.dropFirst(cap) {
                                merged.removeValue(forKey: entry.id)
                            }
                        }
                    }

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
