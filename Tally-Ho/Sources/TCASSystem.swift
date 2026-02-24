//
//  TCASSystem.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Simplified TCAS-like proximity alerting.
//
//  Two alert levels:
//    Traffic Advisory  (TA) — intruder within TA envelope; highlights aircraft amber.
//    Resolution Advisory (RA) — intruder within RA envelope; flashing red screen border
//                                and highlights aircraft red/orange.
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
    case trafficAdvisory   = 1   // TA — within outer envelope
    case resolutionAdvisory = 2  // RA — within inner envelope

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

/// Evaluates aircraft proximity and returns TCAS alert levels.
class TCASSystem {

    // MARK: Thresholds

    /// Traffic Advisory envelope
    static let taHorizontalNM: Double = 6.0     // nautical miles
    static let taVerticalFt:   Double = 1_200.0 // feet

    /// Resolution Advisory envelope (subset of TA envelope)
    static let raHorizontalNM: Double = 1.5     // nautical miles
    static let raVerticalFt:   Double = 600.0   // feet

    // MARK: Evaluation

    /// Evaluate all aircraft and return the current TCAS state.
    static func evaluate(
        aircraft: [Aircraft],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double            // feet MSL
    ) -> TCASEvaluation {

        var threats: [String: TCASAlertLevel] = [:]

        for ac in aircraft {
            let horizNM = CalculationsLogic.distanceInNauticalMiles(
                from: userLocation,
                to: ac.coordinate
            )
            let vertFt = abs(ac.altitude - userAltitude)

            if horizNM <= raHorizontalNM && vertFt <= raVerticalFt {
                threats[ac.id] = .resolutionAdvisory
            } else if horizNM <= taHorizontalNM && vertFt <= taVerticalFt {
                threats[ac.id] = .trafficAdvisory
            }
        }

        let overallLevel = threats.values.max() ?? .none
        return TCASEvaluation(overallLevel: overallLevel, threats: threats)
    }
}
