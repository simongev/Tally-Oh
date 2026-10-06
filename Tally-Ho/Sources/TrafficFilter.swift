//
//  TrafficFilter.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Which traffic and airports are shown: one set of rules for the AR scene, the 2D map and the
//  off-screen arrow (#14).
//

import Foundation
import CoreLocation

/// The display rules for traffic and airports, shared by the AR scene, the 2D map and the
/// off-screen arrow, so the three cannot disagree about what is shown (#14).
///
/// The map used to keep its own copy of these rules, and it had drifted. It ignored Max Distance,
/// and because the internet fetch reaches 1.25 times that radius, traffic at 20–25 NM showed on
/// the map and never in AR. It also ignored the altitude band, used a different ground rule and
/// measured distance from the raw report rather than the dead-reckoned position. Selecting one of
/// those aircraft on the map left an arrow pointing at a target the scene would never draw.
///
/// The rules run in two stages, because that is how the AR path has always run them, and AR has to
/// behave exactly as before while "Only traffic within ±10,000 ft" is on:
///
/// 1. **Candidates** (`isCandidate`): the cheap cull the view controller runs over everything
///    received, on the raw reported position: ground traffic, Max Distance and ownship. Its output
///    also feeds TCAS, the flight log and the pressure-altitude estimate, which is why it stops at
///    these three rules.
/// 2. **Display** (`verdict`): every rule, on the dead-reckoned position and the altitude converted
///    into the viewer's own datum, which is where the scene draws the target.
///
/// A target is shown when it passes both. `judge` and `displayed` apply both stages in one call
/// and serve the map and the off-screen arrow. The scene manager receives the candidates and runs
/// `verdict` on each, which comes to the same thing; `TrafficFilterTests` checks that it does.
///
/// A value type with no SceneKit or UIKit dependency. The only clock it reads is the one
/// `CalculationsLogic.predictedPosition` reads.
struct TrafficFilter {

    /// The vertical half-width of the band the "Only traffic within ±10,000 ft" setting applies
    /// in the air.
    static let altitudeBandFt: Double = 10_000

    /// Why a target is not shown. Cases are listed in the order `judge` checks them, so the reason
    /// given is the first rule the target fails.
    enum Exclusion: Equatable, CaseIterable {
        /// Show Aircraft is off.
        case aircraftHidden
        /// The user's own aircraft, identified by ownship id or by the "I'm Flying" callsign.
        case ownship
        /// Ground traffic while Show Aircraft on Ground is off.
        case groundTraffic
        /// Further than Max Distance.
        case beyondMaxDistance
        /// Excluded by the callsign filter.
        case callsignFilter
        /// More than `altitudeBandFt` above or below, while airborne with the band setting on.
        case outsideAltitudeBand

        /// A few words for the "filtered out" note shown when a selected target has no AR node.
        var noteText: String {
            switch self {
            case .aircraftHidden:      return "aircraft display off"
            case .ownship:             return "your own aircraft"
            case .groundTraffic:       return "on the ground"
            case .beyondMaxDistance:   return "beyond max distance"
            case .callsignFilter:      return "callsign filter"
            case .outsideAltitudeBand: return "outside ±10,000 ft"
            }
        }
    }

    /// The viewer, in the frame every comparison is made in: the same position, altitude and datum
    /// conversion the scene places targets with.
    struct Observer {
        var coordinate: CLLocationCoordinate2D
        /// Geometric MSL, feet.
        var altitudeFt: Double
        /// Local geoid separation (HAE − MSL, feet). See `CalculationsLogic.geometricPlacementAltitude`.
        var geoidSeparationFt: Double? = nil
        /// The air-mass fit used for targets reporting pressure altitude only.
        var datumFit: AltitudeDatumOffset.DatumFit? = nil
    }

    /// One target judged against the rules. Carries the dead-reckoned position and converted
    /// altitude it was judged at, so the scene draws it exactly where it was judged.
    struct Verdict {
        let aircraft: Aircraft
        /// Dead-reckoned position, `CalculationsLogic.predictedPosition(for:aheadSeconds: 0)`.
        let coordinate: CLLocationCoordinate2D
        /// The dead-reckoned altitude converted into the viewer's datum, which is what the scene
        /// places the target at and what the altitude band is measured against.
        let placementAltitudeFt: Double
        /// From the viewer to `coordinate`.
        let distanceNM: Double
        /// Nil when the target is shown.
        let exclusion: Exclusion?

        var isShown: Bool { exclusion == nil }
    }

    let settings: ARVisualizationSettings
    /// Whether the user is flying. The altitude band applies only in the air.
    let airborne: Bool
    /// The user's own aircraft by id (hex), when something has identified it. Hidden in addition
    /// to `settings.wifiOwnshipCallsign`; either one matching is enough.
    let ownshipID: String?

    init(settings: ARVisualizationSettings, airborne: Bool, ownshipID: String? = nil) {
        self.settings = settings
        self.airborne = airborne
        self.ownshipID = ownshipID
    }

    /// Whether the altitude band culls anything right now: in the air, with the setting on.
    var altitudeBandActive: Bool { airborne && settings.limitTrafficToAltitudeBand }

    func isOwnship(_ aircraft: Aircraft) -> Bool {
        if let ownshipID, aircraft.id == ownshipID { return true }
        if let callsign = settings.wifiOwnshipCallsign, aircraft.callsign == callsign { return true }
        return false
    }

    // MARK: - Stage 1: candidates

    /// The rule the cheap cull rejects a target for, or nil if it is a candidate. Uses the raw
    /// reported position, exactly as the pre-filter always has.
    func candidateExclusion(_ aircraft: Aircraft, near coordinate: CLLocationCoordinate2D) -> Exclusion? {
        if !settings.showGroundAircraft && aircraft.isGroundTraffic { return .groundTraffic }
        let distNM = CalculationsLogic.distanceInNauticalMiles(from: coordinate, to: aircraft.coordinate)
        if distNM > settings.aircraftMaxDistance { return .beyondMaxDistance }
        if isOwnship(aircraft) { return .ownship }
        return nil
    }

    func isCandidate(_ aircraft: Aircraft, near coordinate: CLLocationCoordinate2D) -> Bool {
        candidateExclusion(aircraft, near: coordinate) == nil
    }

    func candidates<S: Sequence>(_ aircraft: S, near coordinate: CLLocationCoordinate2D) -> [Aircraft]
    where S.Element == Aircraft {
        aircraft.filter { isCandidate($0, near: coordinate) }
    }

    // MARK: - Stage 2: display

    /// Judge a target on its dead-reckoned position and converted altitude. This is the scene
    /// manager's per-target test, run on candidates.
    func verdict(for aircraft: Aircraft, from observer: Observer) -> Verdict {
        let (coordinate, predictedAltitude) = CalculationsLogic.predictedPosition(for: aircraft, aheadSeconds: 0)
        // Converted into the viewer's own datum before anything compares the two. Against an
        // unconverted pressure altitude the band read about 1,900 ft of separation at cruise for
        // co-altitude traffic, most of its 10,000 ft spent on a datum mismatch.
        let placementAltitude = CalculationsLogic.placementAltitude(
            for: aircraft, targetAltitude: predictedAltitude, userAltitudeFt: observer.altitudeFt,
            geoidSeparationFt: observer.geoidSeparationFt, datumFit: observer.datumFit)
        let distanceNM = CalculationsLogic.distanceInNauticalMiles(from: observer.coordinate, to: coordinate)
        return Verdict(
            aircraft: aircraft,
            coordinate: coordinate,
            placementAltitudeFt: placementAltitude,
            distanceNM: distanceNM,
            exclusion: exclusion(for: aircraft,
                                 distanceNM: distanceNM,
                                 verticalSeparationFt: abs(placementAltitude - observer.altitudeFt))
        )
    }

    /// The display rules on geometry already worked out. Every rule in one place.
    func exclusion(for aircraft: Aircraft, distanceNM: Double, verticalSeparationFt: Double) -> Exclusion? {
        if !settings.showAircraft { return .aircraftHidden }
        if isOwnship(aircraft) { return .ownship }
        // The source's own on-ground flag where there is one; altitude alone misclassified traffic
        // at high-elevation airports. See `Aircraft.isGroundTraffic`.
        if !settings.showGroundAircraft && aircraft.isGroundTraffic { return .groundTraffic }
        if distanceNM > settings.aircraftMaxDistance { return .beyondMaxDistance }
        if !settings.passes(callsign: aircraft.callsign) { return .callsignFilter }
        // In the air, traffic more than 10,000 ft above or below is no use for visual traffic
        // awareness: there is no reason to show 5,000 ft traffic while cruising at 40,000 ft.
        //
        // Only targets that reported an altitude. One with no altitude carries a placeholder zero,
        // which at cruise reads as 35,000 ft of separation: it would be hidden because the source
        // said nothing about its altitude, not because it is far away.
        if altitudeBandActive, aircraft.hasValidAltitude, verticalSeparationFt > Self.altitudeBandFt {
            return .outsideAltitudeBand
        }
        return nil
    }

    // MARK: - Both stages

    /// Judge a target against every rule, both stages. What the map and the off-screen arrow use.
    func judge(_ aircraft: Aircraft, from observer: Observer) -> Verdict {
        let display = verdict(for: aircraft, from: observer)
        // Show Aircraft off explains everything else, so it is named first.
        guard settings.showAircraft else { return display }
        guard let early = candidateExclusion(aircraft, near: observer.coordinate) else { return display }
        return Verdict(aircraft: aircraft, coordinate: display.coordinate,
                       placementAltitudeFt: display.placementAltitudeFt,
                       distanceNM: display.distanceNM, exclusion: early)
    }

    /// The targets the AR scene shows, nearest first: both stages, on everything received.
    func displayed<S: Sequence>(_ aircraft: S, from observer: Observer) -> [Verdict]
    where S.Element == Aircraft {
        aircraft
            .map { judge($0, from: observer) }
            .filter { $0.isShown }
            .sorted { $0.distanceNM < $1.distanceNM }
    }

    // MARK: - Airports

    /// Whether an airport passes the airport rules: Show Airports, its type's toggle and Airport
    /// Max Distance.
    func isAirportShown(_ airport: Airport, from coordinate: CLLocationCoordinate2D) -> Bool {
        guard settings.showAirports, settings.shouldShow(airportType: airport.type) else { return false }
        return CalculationsLogic.distanceInNauticalMiles(from: coordinate, to: airport.coordinate)
            <= settings.airportMaxDistance
    }

    /// The airports the scene draws: those passing the airport rules, nearest first, at most
    /// `limit`. The scene caps airport nodes for memory (`ARSceneManager.maxAirportNodes`), so the
    /// map takes the same cap; without it the map could offer an airport the scene never draws.
    func shownAirports(_ airports: [Airport], from coordinate: CLLocationCoordinate2D, limit: Int) -> [Airport] {
        guard settings.showAirports, limit > 0 else { return [] }
        // The bounding-box pre-check in filterAirportsInRange keeps this cheap over the whole table.
        let inRange = CalculationsLogic.filterAirportsInRange(
            airports: airports,
            userCoord: coordinate,
            maxRangeNauticalMiles: settings.airportMaxDistance
        ).filter { settings.shouldShow(airportType: $0.type) }
        let nearestFirst = inRange
            .map { (airport: $0,
                    distNM: CalculationsLogic.distanceInNauticalMiles(from: coordinate, to: $0.coordinate)) }
            .sorted { $0.distNM < $1.distNM }
        return nearestFirst.prefix(limit).map { $0.airport }
    }
}
