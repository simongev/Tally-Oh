//
//  TCASSystem.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  TCAS II-style traffic alerting (#13).
//
//  The thresholds come from the TCAS II sensitivity levels, chosen by own altitude:
//
//    Own altitude              SL  TA tau  RA tau  DMOD TA/RA (NM)  ZTHR TA/RA (ft)
//    below 1,000 ft AGL         2   20 s    none     0.30 / -          850 / -
//    1,000 - 2,350 ft AGL       3   25 s    15 s     0.33 / 0.20       850 / 600
//    2,350 - 5,000 ft           4   30 s    20 s     0.48 / 0.35       850 / 600
//    5,000 - 10,000 ft          5   40 s    25 s     0.75 / 0.55       850 / 600
//    10,000 - 20,000 ft         6   45 s    30 s     1.00 / 0.80       850 / 600
//    20,000 - 42,000 ft         7   48 s    35 s     1.30 / 1.10       850 / 700
//    above 42,000 ft            7   48 s    35 s     1.30 / 1.10      1200 / 800
//
//  An intruder alerts when BOTH tests pass, each against the thresholds of the advisory:
//
//    Range test     r < DMOD, or the intruder is closing and the modified tau
//                   (r - DMOD^2 / r) / (-r') is below the tau threshold.
//    Vertical test  |dh| < ZTHR, or the altitude gap is closing and the vertical tau
//                   |dh| / |dh'| is below the tau threshold.
//
//  Modified tau is what lets a slow closure still alert before it is too late: plain tau
//  r / (-r') goes to infinity as the closure rate falls, and DMOD^2 / r pulls it back in.
//  r and r' are horizontal here, because the vertical test is separate.
//
//  An advisory is held for a few seconds after its condition clears (`AdvisoryTracker`), so a
//  threat whose geometry wobbles across a threshold — at every internet fetch, for instance —
//  does not flash the frame on and off.
//
//  IMPORTANT: This system only INDICATES threats.
//  It does NOT advise the pilot to climb or descend — the pilot must listen to
//  their aircraft's own TCAS/ACAS equipment for resolution guidance.
//

import Foundation
import CoreLocation

// MARK: - Alert Level

enum TCASAlertLevel: Int, Comparable {
    case none               = 0
    case trafficAdvisory    = 1   // TA
    case resolutionAdvisory = 2   // RA

    static func < (lhs: TCASAlertLevel, rhs: TCASAlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short form for logs and the status line.
    var shortName: String {
        switch self {
        case .none:               return "none"
        case .trafficAdvisory:    return "TA"
        case .resolutionAdvisory: return "RA"
        }
    }
}

// MARK: - Evaluation result

struct TCASEvaluation {
    /// Highest alert level across all threats.
    let overallLevel: TCASAlertLevel
    /// Per-aircraft alert levels (only contains aircraft that are TA or RA).
    let threats: [String: TCASAlertLevel]
    /// The most urgent threat: the highest advisory level, then the lowest tau, then the
    /// nearest. Nil when there is no threat. The view auto-selects this one.
    let primaryThreatID: String?
    /// Modified range tau per threat, in seconds — what the primary threat is ranked by.
    /// Zero for a closing intruder already inside DMOD, infinity for one that is not closing.
    let threatTausS: [String: Double]
    /// Horizontal range per threat, in nautical miles.
    let threatRangesNM: [String: Double]
    /// The sensitivity level the thresholds came from; nil when TCAS did not run.
    let sensitivityLevel: Int?

    init(
        overallLevel: TCASAlertLevel,
        threats: [String: TCASAlertLevel],
        primaryThreatID: String? = nil,
        threatTausS: [String: Double] = [:],
        threatRangesNM: [String: Double] = [:],
        sensitivityLevel: Int? = nil
    ) {
        self.overallLevel = overallLevel
        self.threats = threats
        self.primaryThreatID = primaryThreatID
        self.threatTausS = threatTausS
        self.threatRangesNM = threatRangesNM
        self.sensitivityLevel = sensitivityLevel
    }

    static let clear = TCASEvaluation(overallLevel: .none, threats: [:])
}

// MARK: - TCAS System

/// Pure TCAS logic: sensitivity levels, the range and vertical tests, the adapter from the
/// app's traffic model, and the advisory hysteresis. No UIKit, no ARKit, no clocks of its own —
/// every time-dependent call takes the time as an argument.
enum TCASSystem {

    // MARK: - Sensitivity levels

    struct SensitivityLevel: Equatable {
        /// TCAS II numbering, 2 through 7.
        let number: Int
        let taTauS: Double
        let taDMODNM: Double
        let taZTHRFt: Double
        /// Nil at SL2, where TCAS II issues traffic advisories only.
        let raTauS: Double?
        let raDMODNM: Double?
        let raZTHRFt: Double?

        var allowsRA: Bool { raTauS != nil }

        static let sl2 = SensitivityLevel(number: 2, taTauS: 20, taDMODNM: 0.30, taZTHRFt: 850,
                                          raTauS: nil, raDMODNM: nil, raZTHRFt: nil)
        static let sl3 = SensitivityLevel(number: 3, taTauS: 25, taDMODNM: 0.33, taZTHRFt: 850,
                                          raTauS: 15, raDMODNM: 0.20, raZTHRFt: 600)
        static let sl4 = SensitivityLevel(number: 4, taTauS: 30, taDMODNM: 0.48, taZTHRFt: 850,
                                          raTauS: 20, raDMODNM: 0.35, raZTHRFt: 600)
        static let sl5 = SensitivityLevel(number: 5, taTauS: 40, taDMODNM: 0.75, taZTHRFt: 850,
                                          raTauS: 25, raDMODNM: 0.55, raZTHRFt: 600)
        static let sl6 = SensitivityLevel(number: 6, taTauS: 45, taDMODNM: 1.00, taZTHRFt: 850,
                                          raTauS: 30, raDMODNM: 0.80, raZTHRFt: 600)
        static let sl7 = SensitivityLevel(number: 7, taTauS: 48, taDMODNM: 1.30, taZTHRFt: 850,
                                          raTauS: 35, raDMODNM: 1.10, raZTHRFt: 700)
        /// SL7 above FL420, where the vertical thresholds open up for the larger altimetry error.
        static let sl7High = SensitivityLevel(number: 7, taTauS: 48, taDMODNM: 1.30, taZTHRFt: 1_200,
                                              raTauS: 35, raDMODNM: 1.10, raZTHRFt: 800)

        /// The band edges. Each lower edge belongs to the band above it ("1,000 - 2,350" starts
        /// at exactly 1,000); 42,000 ft itself is still ordinary SL7, "above 42,000" is above it.
        static let sl2TopAGLFt: Double = 1_000
        static let sl3TopAGLFt: Double = 2_350
        static let sl4TopFt: Double = 5_000
        static let sl5TopFt: Double = 10_000
        static let sl6TopFt: Double = 20_000
        static let sl7TopFt: Double = 42_000

        /// The sensitivity level for an own altitude.
        ///
        /// Below 2,350 ft the bands are height above the ground, as TCAS II takes them from the
        /// radio altimeter. Where no height above ground is known, MSL stands in for it: terrain
        /// is at or above sea level almost everywhere, so MSL can only overstate the height, which
        /// errs towards the more sensitive band rather than towards the TA-only one. Above that,
        /// the bands are altitude (MSL here, pressure altitude in the real system).
        static func forOwnAltitude(mslFt: Double, aglFt: Double?) -> SensitivityLevel {
            let height = aglFt ?? mslFt
            if height < sl2TopAGLFt { return .sl2 }
            if height < sl3TopAGLFt { return .sl3 }
            if mslFt < sl4TopFt { return .sl4 }
            if mslFt < sl5TopFt { return .sl5 }
            if mslFt < sl6TopFt { return .sl6 }
            if mslFt <= sl7TopFt { return .sl7 }
            return .sl7High
        }
    }

    // MARK: - Geometry

    /// One intruder relative to ownship in a local flat-Earth frame: position and velocity are
    /// intruder minus ownship.
    struct RelativeState {
        var id: String
        /// Horizontal offset, metres north and east of ownship.
        var northM: Double
        var eastM: Double
        /// False when the intruder reported no usable direction, so its velocity, and with it the
        /// range rate, is unknown. Only the `r < DMOD` half of the range test can pass then.
        var hasHorizontalVelocity: Bool = true
        /// Relative velocity, metres per second north and east.
        var velocityNorthMS: Double = 0
        var velocityEastMS: Double = 0
        /// Intruder altitude minus own altitude, feet: positive when the intruder is above.
        var altitudeDeltaFt: Double
        /// Intruder vertical rate minus own vertical rate, feet per minute.
        var verticalRateDeltaFpm: Double = 0
    }

    /// The instantaneous verdict on one intruder, before hysteresis.
    struct Assessment: Equatable {
        var level: TCASAlertLevel
        /// Modified range tau against the DMOD of `level` (the TA DMOD when `level` is none),
        /// in seconds. Zero for a closing intruder inside DMOD, infinity when not closing.
        var tauS: Double
        var rangeNM: Double
    }

    /// Modified tau, (r - DMOD^2 / r) / (-r'), in seconds; infinity unless closing, and never
    /// negative — a closing intruder already inside DMOD is at zero.
    static func modifiedTauS(rangeNM: Double, rangeRateNMPerS: Double?, dmodNM: Double) -> Double {
        guard let rangeRate = rangeRateNMPerS, rangeRate < 0 else { return .infinity }
        guard rangeNM > 0 else { return 0 }
        return max(0, (rangeNM - dmodNM * dmodNM / rangeNM) / -rangeRate)
    }

    /// r < DMOD, or closing with modified tau below the threshold.
    static func rangeTestPasses(rangeNM: Double, rangeRateNMPerS: Double?,
                                tauS: Double, dmodNM: Double) -> Bool {
        if rangeNM < dmodNM { return true }
        return modifiedTauS(rangeNM: rangeNM, rangeRateNMPerS: rangeRateNMPerS, dmodNM: dmodNM) < tauS
    }

    /// |dh| < ZTHR, or the gap is closing and the time to co-altitude is below the threshold.
    static func verticalTestPasses(altitudeDeltaFt: Double, verticalRateDeltaFpm: Double,
                                   tauS: Double, zthrFt: Double) -> Bool {
        if abs(altitudeDeltaFt) < zthrFt { return true }
        // Closing when the gap and its rate of change have opposite signs.
        guard altitudeDeltaFt * verticalRateDeltaFpm < 0 else { return false }
        let verticalTauS = abs(altitudeDeltaFt) / abs(verticalRateDeltaFpm) * 60.0
        return verticalTauS < tauS
    }

    /// Run both tests for TA and, where the sensitivity level allows one, RA.
    static func assess(_ state: RelativeState, sensitivity sl: SensitivityLevel) -> Assessment {
        let rangeM = (state.northM * state.northM + state.eastM * state.eastM).squareRoot()
        let rangeNM = rangeM / CalculationsLogic.nauticalMileToMeters

        let rangeRate: Double?
        if !state.hasHorizontalVelocity {
            rangeRate = nil
        } else if rangeM > 1e-6 {
            let metresPerSecond = (state.northM * state.velocityNorthMS
                                   + state.eastM * state.velocityEastMS) / rangeM
            rangeRate = metresPerSecond / CalculationsLogic.nauticalMileToMeters
        } else {
            // Co-located: inside every DMOD regardless, so the rate only matters for ranking.
            let speed = (state.velocityNorthMS * state.velocityNorthMS
                         + state.velocityEastMS * state.velocityEastMS).squareRoot()
            rangeRate = -speed / CalculationsLogic.nauticalMileToMeters
        }

        func passes(tauS: Double, dmodNM: Double, zthrFt: Double) -> Bool {
            rangeTestPasses(rangeNM: rangeNM, rangeRateNMPerS: rangeRate, tauS: tauS, dmodNM: dmodNM)
                && verticalTestPasses(altitudeDeltaFt: state.altitudeDeltaFt,
                                      verticalRateDeltaFpm: state.verticalRateDeltaFpm,
                                      tauS: tauS, zthrFt: zthrFt)
        }

        var level = TCASAlertLevel.none
        var dmodForTau = sl.taDMODNM
        if passes(tauS: sl.taTauS, dmodNM: sl.taDMODNM, zthrFt: sl.taZTHRFt) {
            level = .trafficAdvisory
            if let raTau = sl.raTauS, let raDMOD = sl.raDMODNM, let raZTHR = sl.raZTHRFt,
               passes(tauS: raTau, dmodNM: raDMOD, zthrFt: raZTHR) {
                level = .resolutionAdvisory
                dmodForTau = raDMOD
            }
        }
        let tau = modifiedTauS(rangeNM: rangeNM, rangeRateNMPerS: rangeRate, dmodNM: dmodForTau)
        return Assessment(level: level, tauS: tau, rangeNM: rangeNM)
    }

    // MARK: - Adapter from the traffic model

    /// Ownship as TCAS needs it, from the same snapshot the markers are drawn against.
    struct OwnState {
        var coordinate: CLLocationCoordinate2D
        /// The altitude placement uses (`OwnshipSnapshot.displayAltitudeFt`), feet.
        var altitudeFt: Double
        var trackDeg: Double
        var groundSpeedKt: Double
        var verticalRateFpm: Double
        /// Height above the ground when known, feet. Selects SL2 and SL3.
        var heightAboveGroundFt: Double?
    }

    /// Outside this volume nothing can alert at any sensitivity level — 48 s at a 1,200 kt
    /// closure is 16 NM, and at a 10,000 fpm vertical closure 8,000 ft — so the tests are not run.
    static let guardRangeNM: Double = 20.0
    static let guardVerticalFt: Double = 10_000.0

    /// One aircraft relative to ownship, from the same dead-reckoned position and the same
    /// datum-converted altitude its marker is drawn with (`predictedPosition`,
    /// `placementAltitude`), so the alert and the picture can never disagree.
    ///
    /// Nil — not assessed at all — for an aircraft that:
    ///  - reported itself on the ground (TCAS II likewise declares on-ground intruders non-threats);
    ///  - reported no altitude (the vertical test cannot pass without one);
    ///  - has gone stale: past `maxCoastSeconds` its marker is frozen at a guess, and an alert
    ///    against a guess is noise;
    ///  - lies outside the guard volume.
    static func relativeState(
        of aircraft: Aircraft,
        own: OwnState,
        geoidSeparationFt: Double?,
        datumFit: AltitudeDatumOffset.DatumFit?
    ) -> RelativeState? {
        guard !aircraft.isOnGround, aircraft.hasValidAltitude, !CalculationsLogic.isStale(aircraft) else {
            return nil
        }
        let (coordinate, reportedAltitude) = CalculationsLogic.predictedPosition(for: aircraft, aheadSeconds: 0)
        let altitude = CalculationsLogic.placementAltitude(
            for: aircraft, targetAltitude: reportedAltitude, userAltitudeFt: own.altitudeFt,
            geoidSeparationFt: geoidSeparationFt, datumFit: datumFit)
        let offset = horizontalOffsetMeters(from: own.coordinate, to: coordinate)
        let rangeNM = (offset.north * offset.north + offset.east * offset.east).squareRoot()
            / CalculationsLogic.nauticalMileToMeters
        let altitudeDelta = altitude - own.altitudeFt
        guard rangeNM <= guardRangeNM, abs(altitudeDelta) <= guardVerticalFt else { return nil }

        let ownVelocity = velocityMS(trackDeg: own.trackDeg, groundSpeedKt: own.groundSpeedKt)
        let intruderVelocity = aircraft.hasValidTrack
            ? velocityMS(trackDeg: aircraft.track, groundSpeedKt: aircraft.groundSpeed)
            : (north: 0.0, east: 0.0)
        return RelativeState(
            id: aircraft.id,
            northM: offset.north,
            eastM: offset.east,
            hasHorizontalVelocity: aircraft.hasValidTrack,
            velocityNorthMS: intruderVelocity.north - ownVelocity.north,
            velocityEastMS: intruderVelocity.east - ownVelocity.east,
            altitudeDeltaFt: altitudeDelta,
            verticalRateDeltaFpm: aircraft.verticalRate - own.verticalRateFpm
        )
    }

    /// Assess every aircraft given. The caller passes all traffic except ownship — including
    /// traffic the display filters hide — and applies `AdvisoryTracker` to the result.
    static func assess(
        aircraft: [Aircraft],
        own: OwnState,
        geoidSeparationFt: Double? = nil,
        datumFit: AltitudeDatumOffset.DatumFit? = nil
    ) -> (sensitivity: SensitivityLevel, assessments: [String: Assessment]) {
        let sl = SensitivityLevel.forOwnAltitude(mslFt: own.altitudeFt, aglFt: own.heightAboveGroundFt)
        var assessments: [String: Assessment] = [:]
        for ac in aircraft {
            guard let state = relativeState(of: ac, own: own, geoidSeparationFt: geoidSeparationFt,
                                            datumFit: datumFit) else { continue }
            assessments[ac.id] = assess(state, sensitivity: sl)
        }
        return (sl, assessments)
    }

    // MARK: - Hysteresis and ranking

    /// Holds each advisory for a few seconds after its condition last held, and ranks the
    /// threats. One per view; reset whenever TCAS stops running.
    struct AdvisoryTracker {
        /// An RA stays an RA this long after its condition last held, then falls back to TA
        /// while the TA hold lasts. Long enough to ride out a fetch-cycle correction (the
        /// internet traffic is refreshed every 8 s), short enough to clear promptly.
        static let raHoldSeconds: TimeInterval = 5.0
        /// A TA stays displayed this long after its condition last held. One full internet
        /// fetch cycle, so a target hopping across a threshold at each fetch reads as steady.
        static let taHoldSeconds: TimeInterval = 8.0

        private struct Entry {
            var lastTA: TimeInterval
            var lastRA: TimeInterval?
            var tauS: Double
            var rangeNM: Double
        }

        private var entries: [String: Entry] = [:]

        mutating func reset() {
            entries.removeAll()
        }

        /// Fold in one pass of assessments taken at `now` (seconds, any monotonic clock).
        ///
        /// An aircraft missing from `assessments` is dropped at once rather than held: it has
        /// left the picture, or turned out to be ownship, and neither should keep the frame lit.
        mutating func update(
            _ assessments: [String: Assessment],
            sensitivityLevel: Int?,
            at now: TimeInterval
        ) -> TCASEvaluation {
            for (id, assessment) in assessments {
                let alerting = assessment.level >= .trafficAdvisory
                let isRA = assessment.level == .resolutionAdvisory
                if var entry = entries[id] {
                    entry.tauS = assessment.tauS
                    entry.rangeNM = assessment.rangeNM
                    if alerting { entry.lastTA = now }
                    if isRA { entry.lastRA = now }
                    entries[id] = entry
                } else if alerting {
                    entries[id] = Entry(lastTA: now, lastRA: isRA ? now : nil,
                                        tauS: assessment.tauS, rangeNM: assessment.rangeNM)
                }
            }

            var threats: [String: TCASAlertLevel] = [:]
            var taus: [String: Double] = [:]
            var ranges: [String: Double] = [:]
            var expired: [String] = []
            for (id, entry) in entries {
                guard assessments[id] != nil else {
                    expired.append(id)
                    continue
                }
                let level: TCASAlertLevel
                if let lastRA = entry.lastRA, now - lastRA <= Self.raHoldSeconds {
                    level = .resolutionAdvisory
                } else if now - entry.lastTA <= Self.taHoldSeconds {
                    level = .trafficAdvisory
                } else {
                    expired.append(id)
                    continue
                }
                threats[id] = level
                taus[id] = entry.tauS
                ranges[id] = entry.rangeNM
            }
            for id in expired { entries.removeValue(forKey: id) }

            let primary = threats.keys.min { lhs, rhs in
                Self.isMoreUrgent(lhs, than: rhs, threats: threats, taus: taus, ranges: ranges)
            }
            let overall: TCASAlertLevel = threats.values.max() ?? TCASAlertLevel.none
            return TCASEvaluation(
                overallLevel: overall,
                threats: threats,
                primaryThreatID: primary,
                threatTausS: taus,
                threatRangesNM: ranges,
                sensitivityLevel: sensitivityLevel
            )
        }

        /// Highest level first — an RA is by definition the more urgent conflict — then the
        /// lowest tau, then the nearest, then the id so the choice is stable between ticks.
        private static func isMoreUrgent(
            _ lhs: String, than rhs: String,
            threats: [String: TCASAlertLevel], taus: [String: Double], ranges: [String: Double]
        ) -> Bool {
            let lhsLevel: TCASAlertLevel = threats[lhs] ?? TCASAlertLevel.none
            let rhsLevel: TCASAlertLevel = threats[rhs] ?? TCASAlertLevel.none
            if lhsLevel != rhsLevel { return lhsLevel > rhsLevel }
            let lhsTau = taus[lhs] ?? .infinity
            let rhsTau = taus[rhs] ?? .infinity
            if lhsTau != rhsTau { return lhsTau < rhsTau }
            let lhsRange = ranges[lhs] ?? .infinity
            let rhsRange = ranges[rhs] ?? .infinity
            if lhsRange != rhsRange { return lhsRange < rhsRange }
            return lhs < rhs
        }
    }

    // MARK: - Helpers

    /// Track and ground speed to a north/east velocity in metres per second.
    static func velocityMS(trackDeg: Double, groundSpeedKt: Double) -> (north: Double, east: Double) {
        let trackRad = trackDeg * .pi / 180.0
        let speedMS = groundSpeedKt * CalculationsLogic.knotsToMetersPerSecond
        return (speedMS * cos(trackRad), speedMS * sin(trackRad))
    }

    /// Flat-Earth offset in metres (north, east) from `origin` to `target`.
    /// Accurate for the short separations relevant to TCAS (< 50 NM).
    static func horizontalOffsetMeters(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> (north: Double, east: Double) {
        let latRad = origin.latitude * .pi / 180.0
        let radius = CalculationsLogic.earthRadius(at: latRad)
        let north = (target.latitude  - origin.latitude)  * (.pi / 180.0) * radius
        let east  = (target.longitude - origin.longitude) * (.pi / 180.0) * radius * cos(latRad)
        return (north, east)
    }
}
