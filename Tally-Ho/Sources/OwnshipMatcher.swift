//
//  OwnshipMatcher.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Which aircraft in the traffic picture is the one the user is sitting in (#13).
//
//  With an ADS-B receiver the answer is its ownship report's ICAO address (ConnectionLogic).
//  On internet traffic alone there is no such report, and the user's own airliner used to leak
//  into the picture: it was only dropped within 0.1 NM of the raw phone position, and the
//  internet feed runs seconds behind — 0.3 NM and more at airliner speed — so it sat beside the
//  viewer as a target and raised TCAS on itself.
//
//  So the traffic is matched against the ownship estimate instead: position, altitude, ground
//  speed and track, every candidate dead-reckoned to the same instant as the estimate. One
//  clear candidate held for a few seconds is selected; two or more must be resolved by one
//  winning consistently. Once selected, the choice is kept unless the match clearly breaks.
//
//  Pure: no clocks, no UIKit. Every call takes the time as an argument.
//

import Foundation
import CoreLocation

// MARK: - Selection

/// The aircraft identified as the user's own, and how it was identified. Always keyed by the
/// traffic `id` (hex address), never by callsign.
struct OwnshipSelection: Equatable {
    enum Source: String {
        /// The ADS-B receiver's ownship report (GDL90 0x0A).
        case adsb
        /// Matched against the ownship estimate by `OwnshipMatcher`.
        case auto
        /// Picked by the user in Settings ("I'm Flying").
        case manual
    }

    var id: String
    var source: Source

    /// Precedence: the user's own pick, then the receiver's address, then the automatic match.
    /// A manual pick overrides everything because the user is the one who knows; the receiver
    /// beats the matcher because it is told, not inferring.
    static func resolve(manualID: String?, adsbID: String?, autoID: String?) -> OwnshipSelection? {
        if let manualID { return OwnshipSelection(id: manualID, source: .manual) }
        if let adsbID { return OwnshipSelection(id: adsbID, source: .adsb) }
        if let autoID { return OwnshipSelection(id: autoID, source: .auto) }
        return nil
    }

    /// The id for a callsign picked in Settings: the nearest aircraft carrying it. Settings still
    /// stores the pick as a callsign (that table is not this change's to alter), so it is turned
    /// into an id once, here, and the id is what is held from then on.
    static func nearestID(withCallsign callsign: String,
                          in aircraft: [Aircraft],
                          near location: CLLocationCoordinate2D) -> String? {
        let carrying = aircraft.filter { $0.callsign == callsign }
        let nearest = carrying.min { lhs, rhs in
            CalculationsLogic.distanceInNauticalMiles(from: location, to: lhs.coordinate)
                < CalculationsLogic.distanceInNauticalMiles(from: location, to: rhs.coordinate)
        }
        return nearest?.id
    }
}

// MARK: - Matcher

struct OwnshipMatcher {

    /// Ownship as estimated, at the instant the candidates were dead-reckoned to.
    struct OwnState {
        var coordinate: CLLocationCoordinate2D
        /// The altitude placement uses (`OwnshipSnapshot.displayAltitudeFt`), feet.
        var altitudeFt: Double
        var groundSpeedKt: Double
        var trackDeg: Double
        var hasVelocity: Bool
    }

    /// One aircraft as a candidate for being ownship.
    struct Candidate {
        var id: String
        /// Dead-reckoned to the same instant as `OwnState`.
        var coordinate: CLLocationCoordinate2D
        /// Converted into `OwnState.altitudeFt`'s vertical datum, feet.
        var altitudeFt: Double
        var groundSpeedKt: Double
        var trackDeg: Double
        var hasValidTrack: Bool = true
        /// The report this state was extrapolated from, so "several updates" can be counted in
        /// reports rather than in display ticks.
        var reportTime: TimeInterval
    }

    /// How far a candidate may sit from the ownship estimate and still be ownship.
    struct Tolerances {
        /// Horizontal tolerance with no motion: GPS error on both sides, plus how far a straight
        /// dead-reckoning line strays from a turning aircraft between reports.
        var horizontalBaseNM: Double
        /// Seconds of position latency allowed on top. Written when a feed position was
        /// extrapolated from the fetch time rather than from when it was measured, so it trailed by
        /// the feed's own age plus the round trip — a couple of seconds, a third of a mile at
        /// airliner speed. Since #17 a feed position is extrapolated from its own report time
        /// (fetch time minus "seen_pos"), so that lag is gone and this allowance is now extra margin.
        var latencyAllowanceS: Double
        /// Vertical tolerance. Both altitudes are in the same datum by the time they get here;
        /// what remains is GPS vertical error, which the app accepts up to 150 m in the air.
        var altitudeFt: Double
        var groundSpeedKt: Double
        var trackDeg: Double

        func horizontalNM(atGroundSpeedKt groundSpeedKt: Double) -> Double {
            horizontalBaseNM + max(0, groundSpeedKt) / 3_600.0 * latencyAllowanceS
        }

        /// To be selected. Tight, because a wrong pick hides a real aircraft: 0.25 NM at 120 kt,
        /// 0.55 NM at 480 kt; inside RVSM's 1,000 ft with GPS error to spare; the speed and track
        /// a co-located aircraft at another level or on another heading would not share.
        static let acquire = Tolerances(horizontalBaseNM: 0.15, latencyAllowanceS: 3.0,
                                        altitudeFt: 600, groundSpeedKt: 30, trackDeg: 20)
        /// To stay selected: twice as loose everywhere. A turn makes the feed's last reported
        /// track lag by up to a fetch interval at 3 deg/s, about 25 deg, and moves its
        /// dead-reckoned position off the arc; none of that may cost the selection.
        static let retain = Tolerances(horizontalBaseNM: 0.30, latencyAllowanceS: 6.0,
                                       altitudeFt: 1_200, groundSpeedKt: 60, trackDeg: 45)
    }

    /// How well one candidate matches, for selection and for the log.
    struct Match: Equatable {
        var id: String
        /// Root-mean-square of each difference over its tolerance: 0 is a perfect match, 1 is a
        /// candidate at the edge of every tolerance at once.
        var quality: Double
        var horizontalNM: Double
        var altitudeFt: Double
        var groundSpeedKt: Double
        var trackDeg: Double
    }

    enum Event: Equatable {
        case selected(Match, candidateCount: Int)
        case released(id: String, reason: String)
    }

    // MARK: Timing

    /// One clear candidate must hold this long before it is selected.
    static let singleCandidateDwellS: TimeInterval = 3.0
    /// With two or more candidates, the winner must win this long without interruption.
    static let ambiguousDwellS: TimeInterval = 5.0
    /// And it must have matched on this many distinct reports, so a single extrapolated report
    /// cannot carry a selection on its own.
    static let minDistinctReports = 2
    /// Once selected, the match must fail the retention test continuously for this long before
    /// the selection is released.
    static let breakAfterS: TimeInterval = 10.0
    /// A selected aircraft absent from the picture is kept this long: missing is not evidence of
    /// a wrong pick, and keeping it means it is still hidden if it comes straight back.
    static let absentReleaseS: TimeInterval = 30.0
    /// Below this own speed track is noise, so nothing new is selected.
    static let minGroundSpeedKt: Double = 30.0

    // MARK: State

    /// The confirmed match.
    private(set) var selected: Match?
    /// How many candidates there were when `selected` was chosen.
    private(set) var selectedCandidateCount: Int = 0
    /// The best candidate while nothing is selected yet. TCAS leaves it out, so the user's own
    /// aircraft cannot raise an advisory on itself in the seconds before it is confirmed.
    private(set) var provisionalID: String?
    /// Candidates passing the acquisition test on the last update.
    private(set) var candidateCount: Int = 0

    private var leaderSince: TimeInterval = 0
    private var leaderAmbiguous = false
    private var leaderReports: Set<TimeInterval> = []
    private var failingSince: TimeInterval?
    private var lastSeen: TimeInterval = 0

    var selectedID: String? { selected?.id }

    /// Forget everything, the confirmed match included.
    mutating func reset() {
        self = OwnshipMatcher()
    }

    /// Stop acquiring without dropping a confirmed match: on the ground, where speed and track
    /// say nothing, or while a manual pick or the receiver's address is in force.
    mutating func suspendAcquisition() {
        clearLeader()
        candidateCount = 0
    }

    // MARK: Matching

    /// The match between one candidate and ownship, or nil when any difference is outside
    /// `tolerances`. Track and ground speed take part only when ownship has a velocity, and track
    /// only above `minGroundSpeedKt`.
    static func match(_ candidate: Candidate, own: OwnState, tolerances: Tolerances) -> Match? {
        let horizontalTolerance = tolerances.horizontalNM(atGroundSpeedKt: own.groundSpeedKt)
        let horizontal = CalculationsLogic.distanceInNauticalMiles(from: own.coordinate,
                                                                   to: candidate.coordinate)
        let altitude = abs(candidate.altitudeFt - own.altitudeFt)
        guard horizontal <= horizontalTolerance, altitude <= tolerances.altitudeFt else { return nil }

        var terms = [horizontal / horizontalTolerance, altitude / tolerances.altitudeFt]
        var speed = 0.0
        var track = 0.0
        if own.hasVelocity {
            speed = abs(candidate.groundSpeedKt - own.groundSpeedKt)
            guard speed <= tolerances.groundSpeedKt else { return nil }
            terms.append(speed / tolerances.groundSpeedKt)
            if own.groundSpeedKt >= minGroundSpeedKt {
                guard candidate.hasValidTrack else { return nil }
                track = trackDifferenceDeg(candidate.trackDeg, own.trackDeg)
                guard track <= tolerances.trackDeg else { return nil }
                terms.append(track / tolerances.trackDeg)
            }
        }
        let meanSquare = terms.reduce(0) { $0 + $1 * $1 } / Double(terms.count)
        return Match(id: candidate.id, quality: meanSquare.squareRoot(), horizontalNM: horizontal,
                     altitudeFt: altitude, groundSpeedKt: speed, trackDeg: track)
    }

    /// A candidate from one aircraft, dead-reckoned and datum-converted exactly as its marker is
    /// drawn (`predictedPosition`, `placementAltitude`). Nil for an aircraft that reported itself
    /// on the ground or reported no altitude: neither can be the aircraft the user is flying in.
    static func candidate(
        from aircraft: Aircraft,
        ownAltitudeFt: Double,
        geoidSeparationFt: Double?,
        datumFit: AltitudeDatumOffset.DatumFit?
    ) -> Candidate? {
        guard !aircraft.isOnGround, aircraft.hasValidAltitude else { return nil }
        let (coordinate, reportedAltitude) = CalculationsLogic.predictedPosition(for: aircraft, aheadSeconds: 0)
        let altitude = CalculationsLogic.placementAltitude(
            for: aircraft, targetAltitude: reportedAltitude, userAltitudeFt: ownAltitudeFt,
            geoidSeparationFt: geoidSeparationFt, datumFit: datumFit)
        return Candidate(id: aircraft.id, coordinate: coordinate, altitudeFt: altitude,
                         groundSpeedKt: aircraft.groundSpeed, trackDeg: aircraft.track,
                         hasValidTrack: aircraft.hasValidTrack,
                         reportTime: aircraft.lastUpdate.timeIntervalSinceReferenceDate)
    }

    // MARK: Update

    /// Fold in one pass. Call only while airborne; `now` is seconds on any monotonic clock.
    /// Returns an event when the selection changes.
    mutating func update(own: OwnState, candidates: [Candidate], at now: TimeInterval) -> Event? {
        if let current = selected {
            return updateSelected(current, own: own, candidates: candidates, at: now)
        }
        return acquire(own: own, candidates: candidates, at: now)
    }

    /// Keep the selection unless the match clearly breaks. Another candidate never takes over
    /// while this one holds, however good it looks.
    private mutating func updateSelected(_ current: Match, own: OwnState,
                                         candidates: [Candidate], at now: TimeInterval) -> Event? {
        guard let candidate = candidates.first(where: { $0.id == current.id }) else {
            if now - lastSeen >= Self.absentReleaseS {
                return release(current.id, reason: "absent")
            }
            return nil
        }
        lastSeen = now
        if let match = Self.match(candidate, own: own, tolerances: .retain) {
            selected = match
            failingSince = nil
            return nil
        }
        let since = failingSince ?? now
        failingSince = since
        if now - since >= Self.breakAfterS {
            return release(current.id, reason: "mismatch")
        }
        return nil
    }

    private mutating func acquire(own: OwnState, candidates: [Candidate], at now: TimeInterval) -> Event? {
        guard own.hasVelocity, own.groundSpeedKt >= Self.minGroundSpeedKt else {
            suspendAcquisition()
            return nil
        }
        let matches = candidates.compactMap { (candidate: Candidate) -> (candidate: Candidate, match: Match)? in
            guard let match = Self.match(candidate, own: own, tolerances: .acquire) else { return nil }
            return (candidate: candidate, match: match)
        }
        candidateCount = matches.count
        let leader = matches.min { lhs, rhs in
            if lhs.match.quality != rhs.match.quality { return lhs.match.quality < rhs.match.quality }
            return lhs.match.id < rhs.match.id
        }
        guard let best = leader else {
            clearLeader()
            return nil
        }

        if best.match.id != provisionalID {
            // A new leader starts its streak from nothing.
            provisionalID = best.match.id
            leaderSince = now
            leaderAmbiguous = false
            leaderReports = []
        }
        if matches.count > 1 { leaderAmbiguous = true }
        leaderReports.insert(best.candidate.reportTime)

        let dwell = leaderAmbiguous ? Self.ambiguousDwellS : Self.singleCandidateDwellS
        guard now - leaderSince >= dwell, leaderReports.count >= Self.minDistinctReports else {
            return nil
        }

        selected = best.match
        selectedCandidateCount = matches.count
        lastSeen = now
        failingSince = nil
        clearLeader()
        return .selected(best.match, candidateCount: matches.count)
    }

    private mutating func release(_ id: String, reason: String) -> Event {
        reset()
        return .released(id: id, reason: reason)
    }

    private mutating func clearLeader() {
        provisionalID = nil
        leaderAmbiguous = false
        leaderReports = []
    }

    /// Absolute difference between two tracks, 0...180 degrees.
    private static func trackDifferenceDeg(_ a: Double, _ b: Double) -> Double {
        var delta = (a - b).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return abs(delta)
    }
}
