//
//  TCASSystem.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  TCAS-like proximity alerting with Closest Point of Approach (CPA) prediction.
//
//  Alert logic mirrors real TCAS τ (tau) thresholds:
//    Traffic Advisory  (TA) — convergence to CPA within 180 s AND CPA separation
//                              is within the TA envelope.
//    Resolution Advisory (RA) — convergence to CPA within 40 s AND CPA separation
//                               is within the RA envelope.
//
//  Alerts are only raised for converging aircraft (tCPA > 0).
//  Aircraft that are nearby but diverging or flying parallel do not alert.
//
//  IMPORTANT: This system only INDICATES threats.
//  It does NOT advise the pilot to climb or descend — the pilot must listen to
//  their aircraft's own TCAS/ACAS equipment for resolution guidance.
//

import Foundation
import CoreLocation

// MARK: - Alert Level

enum TCASAlertLevel: Int, Comparable {
    case none              = 0
    case trafficAdvisory    = 1   // TA — converging toward CPA within TA envelope
    case resolutionAdvisory = 2   // RA — converging toward CPA within RA envelope

    static func < (lhs: TCASAlertLevel, rhs: TCASAlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Per-aircraft threat

struct TCASThreat {
    let aircraftID: String
    let level: TCASAlertLevel
}

// MARK: - Evaluation result

struct TCASEvaluation {
    /// Highest alert level across all threats.
    let overallLevel: TCASAlertLevel
    /// Per-aircraft alert levels (only contains aircraft that are TA or RA).
    let threats: [String: TCASAlertLevel]

    static let clear = TCASEvaluation(overallLevel: .none, threats: [:])
}

// MARK: - TCAS System

/// Evaluates aircraft proximity and convergence, returning TCAS alert levels.
class TCASSystem {

    // MARK: - CPA separation thresholds (predicted closest approach)

    /// If predicted CPA horizontal separation < this, the aircraft counts as converging threat
    static let taCPAHorizNM: Double = 3.0
    static let taCPAVertFt:  Double = 800.0

    static let raCPAHorizNM: Double = 1.0
    static let raCPAVertFt:  Double = 400.0

    // MARK: - Time thresholds (τ — time to CPA must be within this window)

    static let taTauSeconds: Double = 180.0   // TA: alert if CPA < 3 min away
    static let raTauSeconds: Double  =  40.0  // RA: alert if CPA < 40 s away

    // MARK: - Outer guard range (skip CPA computation for clearly distant traffic)

    static let guardHorizNM: Double = 18.0     // 3× the TA CPA threshold
    static let guardVertFt:  Double = 3_600.0  // 3× the TA bubble vertical

    // MARK: - Evaluation

    /// Evaluate all aircraft and return the current TCAS state.
    /// - Parameters:
    ///   - aircraft: List of all detected aircraft.
    ///   - userLocation: User's current position.
    ///   - userAltitude: User's altitude in feet MSL.
    ///   - userTrack: User's track in degrees true (0 = north). Pass 0 if unknown.
    ///   - userGroundSpeed: User's ground speed in knots. Pass 0 if stationary/unknown.
    ///   - userVerticalRate: User's vertical rate in ft/min. Pass 0 if unknown.
    ///   - geoidSeparationFt: Local geoid separation (HAE − MSL), used to convert each target's
    ///     reported altitude into `userAltitude`'s geometric MSL datum. Traffic reports pressure
    ///     altitude while the viewer's altitude is GPS geometric, and the gap between the two runs
    ///     to ~1,900 ft at cruise — four times the RA vertical threshold, which would decide every
    ///     vertical comparison here on a datum mismatch rather than on real separation.
    static func evaluate(
        aircraft: [Aircraft],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userTrack: Double = 0,
        userGroundSpeed: Double = 0,
        userVerticalRate: Double = 0,
        geoidSeparationFt: Double? = nil
    ) -> TCASEvaluation {

        var threats: [String: TCASAlertLevel] = [:]

        // Convert user velocity to flat-Earth m/s vector (North-East axes)
        let userVel = velocityVector(
            trackDeg: userTrack,
            groundSpeedKts: userGroundSpeed,
            vertRateFPM: userVerticalRate
        )

        for ac in aircraft {
            let level = threatLevel(
                ac: ac,
                userLocation: userLocation,
                userAltitude: userAltitude,
                userVel: userVel,
                geoidSeparationFt: geoidSeparationFt
            )
            if level != .none {
                threats[ac.id] = level
            }
        }

        let overallLevel = threats.values.max() ?? .none
        return TCASEvaluation(overallLevel: overallLevel, threats: threats)
    }

    // MARK: - Per-aircraft threat level

    private static func threatLevel(
        ac: Aircraft,
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userVel: SIMD3<Double>,
        geoidSeparationFt: Double?
    ) -> TCASAlertLevel {

        // In the viewer's own datum, so every vertical figure below is real separation rather
        // than the pressure-versus-geometric gap.
        let acAltitude = CalculationsLogic.geometricPlacementAltitude(
            for: ac, reportedAltitudeFt: ac.altitude, geoidSeparationFt: geoidSeparationFt)

        // Compute instantaneous separation (used for guard range check below)
        let horizNM = CalculationsLogic.distanceInNauticalMiles(
            from: userLocation, to: ac.coordinate)
        let vertFt = abs(acAltitude - userAltitude)

        // --- CPA prediction — skip aircraft clearly outside the outer guard range ---
        guard horizNM <= guardHorizNM && vertFt <= guardVertFt else {
            return .none
        }

        let acVel = velocityVector(
            trackDeg: ac.track,
            groundSpeedKts: ac.groundSpeed,
            vertRateFPM: ac.verticalRate
        )

        // Relative position: intruder relative to ownship (metres, North-East-Up)
        let (dx, dy) = horizontalOffsetMeters(from: userLocation, to: ac.coordinate)
        let dz = (acAltitude - userAltitude) * CalculationsLogic.feetToMeters

        // Relative velocity: intruder velocity minus ownship velocity
        let rvx = acVel.x - userVel.x   // North component
        let rvy = acVel.y - userVel.y   // East component
        let rvz = acVel.z - userVel.z   // Up component

        // Time of CPA = -dot(relPos, relVel) / dot(relVel, relVel)
        let relVelSq = rvx * rvx + rvy * rvy + rvz * rvz
        guard relVelSq > 1e-6 else { return .none }  // essentially stationary relative to each other

        let dot = dx * rvx + dy * rvy + dz * rvz
        let tCPA = -dot / relVelSq

        // Only alert for future convergences within the τ window
        guard tCPA > 0 else { return .none }   // already past CPA — diverging

        // --- RA CPA check ---
        if tCPA <= raTauSeconds {
            let cpaDx = dx + rvx * tCPA
            let cpaDy = dy + rvy * tCPA
            let cpaDz = dz + rvz * tCPA

            let cpaHorizM = sqrt(cpaDx * cpaDx + cpaDy * cpaDy)
            let cpaHorizNM = cpaHorizM / CalculationsLogic.nauticalMileToMeters
            let cpaVertFt  = abs(cpaDz) * CalculationsLogic.metersToFeet

            if cpaHorizNM <= raCPAHorizNM && cpaVertFt <= raCPAVertFt {
                return .resolutionAdvisory
            }
        }

        // --- TA CPA check ---
        if tCPA <= taTauSeconds {
            let cpaDx = dx + rvx * tCPA
            let cpaDy = dy + rvy * tCPA
            let cpaDz = dz + rvz * tCPA

            let cpaHorizM = sqrt(cpaDx * cpaDx + cpaDy * cpaDy)
            let cpaHorizNM = cpaHorizM / CalculationsLogic.nauticalMileToMeters
            let cpaVertFt  = abs(cpaDz) * CalculationsLogic.metersToFeet

            if cpaHorizNM <= taCPAHorizNM && cpaVertFt <= taCPAVertFt {
                return .trafficAdvisory
            }
        }

        return .none
    }

    // MARK: - Helpers

    /// Convert track/speed/vrate to a North-East-Up velocity vector in m/s.
    private static func velocityVector(
        trackDeg: Double,
        groundSpeedKts: Double,
        vertRateFPM: Double
    ) -> SIMD3<Double> {
        let trackRad = trackDeg * .pi / 180.0
        let speedMS  = groundSpeedKts * CalculationsLogic.knotsToMetersPerSecond
        let northMS  = speedMS * cos(trackRad)
        let eastMS   = speedMS * sin(trackRad)
        let upMS     = vertRateFPM * CalculationsLogic.feetToMeters / 60.0
        return SIMD3<Double>(northMS, eastMS, upMS)
    }

    /// Flat-Earth offset in metres (North, East) from `from` to `to`.
    /// Accurate for the short separations relevant to TCAS (<50 NM).
    private static func horizontalOffsetMeters(
        from origin: CLLocationCoordinate2D,
        to target: CLLocationCoordinate2D
    ) -> (north: Double, east: Double) {
        let latRad = origin.latitude * .pi / 180.0
        let R = CalculationsLogic.earthRadius(at: latRad)
        let north = (target.latitude  - origin.latitude)  * (.pi / 180.0) * R
        let east  = (target.longitude - origin.longitude) * (.pi / 180.0) * R * cos(latRad)
        return (north, east)
    }
}
