//
//  TrafficFilterTests.swift
//  Tally-HoTests
//
//  The shared display filter (#14): every rule, the altitude band setting on and off, ground
//  against air, the airport rules, AR/map parity, and AR behaving exactly as build 394 did with
//  the band setting on.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

struct TrafficFilterTests {

    // MARK: - Fixtures

    private static let here = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)

    /// A viewer at `here`, at `altitudeFt` geometric MSL.
    private func observer(altitudeFt: Double = 36_000,
                          geoidSeparationFt: Double? = nil) -> TrafficFilter.Observer {
        TrafficFilter.Observer(coordinate: Self.here, altitudeFt: altitudeFt,
                               geoidSeparationFt: geoidSeparationFt, datumFit: nil)
    }

    /// A target `northNM` due north of `here`. Ground speed 0 by default, so its dead-reckoned
    /// position is its reported one and nothing depends on the clock.
    private func aircraft(
        id: String = "a1b2c3",
        callsign: String = "TEST1",
        northNM: Double = 5,
        altitude: Double = 36_000,
        hasValidAltitude: Bool = true,
        isOnGround: Bool = false,
        track: Double = 0,
        groundSpeed: Double = 0,
        age: TimeInterval = 0,
        pressureAltitudeFt: Double? = nil,
        geometricAltitudeFt: Double? = nil
    ) -> Aircraft {
        Aircraft(
            id: id,
            callsign: callsign,
            latitude: Self.here.latitude + northNM / 60.0,
            longitude: Self.here.longitude,
            altitude: altitude,
            track: track,
            groundSpeed: groundSpeed,
            verticalRate: 0,
            lastUpdate: Date().addingTimeInterval(-age),
            source: .internet,
            isOnGround: isOnGround,
            hasValidAltitude: hasValidAltitude,
            hasValidTrack: true,
            pressureAltitudeFt: pressureAltitudeFt,
            geometricAltitudeFt: geometricAltitudeFt
        )
    }

    private func settings(_ configure: (inout ARVisualizationSettings) -> Void = { _ in }) -> ARVisualizationSettings {
        var s = ARVisualizationSettings()
        configure(&s)
        s.updateFilter()
        return s
    }

    private func filter(airborne: Bool = true, ownshipID: String? = nil,
                        _ configure: (inout ARVisualizationSettings) -> Void = { _ in }) -> TrafficFilter {
        TrafficFilter(settings: settings(configure), airborne: airborne, ownshipID: ownshipID)
    }

    /// The reason `judge` gives, nil when shown.
    private func exclusion(_ ac: Aircraft, _ f: TrafficFilter,
                           observer obs: TrafficFilter.Observer? = nil) -> TrafficFilter.Exclusion? {
        f.judge(ac, from: obs ?? observer()).exclusion
    }

    // MARK: - The setting

    /// Gev's choice: on by default, which is what the app always did.
    @Test func altitudeBandSettingDefaultsOn() {
        #expect(ARVisualizationSettings().limitTrafficToAltitudeBand == true)
        #expect(TrafficFilter.altitudeBandFt == 10_000)
    }

    /// Settings saved by a build that predates the setting have no key for it. They must load
    /// with the band on, not off — otherwise every existing user would lose it on update.
    @Test func settingsSavedBeforeTheBandExistedLoadWithItOn() throws {
        let suite = "TrafficFilterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The stored shape of an older build: same key, no "limitTrafficToAltitudeBand".
        defaults.set(["showAircraft": true, "aircraftMaxDistance": 15.0], forKey: "ARVisualizationSettings")

        let loaded = try #require(ARVisualizationSettings.load(from: defaults))
        #expect(loaded.limitTrafficToAltitudeBand == true)
        #expect(loaded.aircraftMaxDistance == 15)
    }

    @Test func altitudeBandSettingRoundTripsBothWays() throws {
        let suite = "TrafficFilterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var off = ARVisualizationSettings()
        off.limitTrafficToAltitudeBand = false
        off.save(to: defaults)
        #expect(ARVisualizationSettings.load(from: defaults)?.limitTrafficToAltitudeBand == false)

        var on = ARVisualizationSettings()
        on.limitTrafficToAltitudeBand = true
        on.save(to: defaults)
        #expect(ARVisualizationSettings.load(from: defaults)?.limitTrafficToAltitudeBand == true)
    }

    // MARK: - Altitude band: setting on and off, ground and air

    @Test func bandHidesTrafficMoreThan10000FtAwayInTheAir() {
        let f = filter(airborne: true)
        let obs = observer(altitudeFt: 36_000)
        #expect(exclusion(aircraft(altitude: 5_000), f, observer: obs) == .outsideAltitudeBand)
        #expect(exclusion(aircraft(altitude: 46_500), f, observer: obs) == .outsideAltitudeBand)
        #expect(exclusion(aircraft(altitude: 26_500), f, observer: obs) == nil)
        #expect(exclusion(aircraft(altitude: 45_500), f, observer: obs) == nil)
    }

    /// Exactly 10,000 ft is inside: the rule has always been "more than".
    @Test func bandEdgeIsInclusive() {
        let f = filter(airborne: true)
        let obs = observer(altitudeFt: 20_000)
        #expect(exclusion(aircraft(altitude: 30_000), f, observer: obs) == nil)
        #expect(exclusion(aircraft(altitude: 10_000), f, observer: obs) == nil)
        #expect(exclusion(aircraft(altitude: 30_001), f, observer: obs) == .outsideAltitudeBand)
    }

    /// With the setting off, nothing is hidden for altitude, however far away it is.
    @Test func settingOffShowsAllTrafficInTheAir() {
        let f = filter(airborne: true) { $0.limitTrafficToAltitudeBand = false }
        let obs = observer(altitudeFt: 40_000)
        #expect(f.altitudeBandActive == false)
        #expect(exclusion(aircraft(altitude: 2_000), f, observer: obs) == nil)
        #expect(exclusion(aircraft(altitude: 60_000), f, observer: obs) == nil)
    }

    /// The band never applies on the ground, setting on or off: from a field, overflights at
    /// cruise are the only traffic there is to see.
    @Test func bandNeverAppliesOnTheGround() {
        let obs = observer(altitudeFt: 500)
        let cruise = aircraft(altitude: 37_000)
        let on = filter(airborne: false)
        let off = filter(airborne: false) { $0.limitTrafficToAltitudeBand = false }
        #expect(on.altitudeBandActive == false)
        #expect(exclusion(cruise, on, observer: obs) == nil)
        #expect(exclusion(cruise, off, observer: obs) == nil)
    }

    /// A target with no altitude carries a placeholder zero. At cruise that reads as 36,000 ft of
    /// separation, but it says nothing about where the target is, so it is never culled for it.
    @Test func bandSkipsTargetsWithNoAltitude() {
        let f = filter(airborne: true)
        let noAlt = aircraft(altitude: 0, hasValidAltitude: false)
        #expect(exclusion(noAlt, f, observer: observer(altitudeFt: 36_000)) == nil)
        // The guard itself, on a separation that would cull a target that had reported one.
        #expect(f.exclusion(for: noAlt, distanceNM: 5, verticalSeparationFt: 36_000) == nil)
        let reported = aircraft(altitude: 0)
        #expect(f.exclusion(for: reported, distanceNM: 5, verticalSeparationFt: 36_000) == .outsideAltitudeBand)
    }

    /// The band is measured in the viewer's own datum. A target at FL350 whose geometric altitude
    /// is 36,900 ft sits 9,700 ft below a viewer at 46,600 ft geometric: inside the band. Compared
    /// unconverted it would read 11,600 ft and be hidden.
    @Test func bandIsMeasuredOnTheDatumConvertedAltitude() {
        let f = filter(airborne: true)
        let obs = observer(altitudeFt: 46_600)
        let target = aircraft(altitude: 35_000, pressureAltitudeFt: 35_000, geometricAltitudeFt: 36_900)
        let verdict = f.verdict(for: target, from: obs)
        #expect(abs(verdict.placementAltitudeFt - 36_900) < 0.5)
        #expect(verdict.exclusion == nil)
        #expect(abs(target.altitude - obs.altitudeFt) > TrafficFilter.altitudeBandFt)
    }

    // MARK: - The other rules

    @Test func showAircraftOffHidesEverythingAndSaysSoFirst() {
        let f = filter { $0.showAircraft = false }
        #expect(exclusion(aircraft(northNM: 3), f) == .aircraftHidden)
        // Out of range as well, but "aircraft display off" explains it.
        #expect(exclusion(aircraft(northNM: 40), f) == .aircraftHidden)
        #expect(f.displayed([aircraft()], from: observer()).isEmpty)
    }

    @Test func groundTrafficHiddenUnlessShowGroundIsOn() {
        let parked = aircraft(altitude: 20, isOnGround: false)          // altitude heuristic
        let flagged = aircraft(id: "g2", altitude: 5_400, isOnGround: true) // high field, source flag
        let obs = observer(altitudeFt: 400)
        let off = filter(airborne: false)
        #expect(exclusion(parked, off, observer: obs) == .groundTraffic)
        #expect(exclusion(flagged, off, observer: obs) == .groundTraffic)
        #expect(off.isCandidate(parked, near: Self.here) == false)

        let on = filter(airborne: false) { $0.showGroundAircraft = true }
        #expect(exclusion(parked, on, observer: obs) == nil)
        #expect(exclusion(flagged, on, observer: obs) == nil)
    }

    /// A target with no altitude is not ground traffic just because its placeholder reads 0 ft.
    @Test func noAltitudeIsNotGroundTraffic() {
        let f = filter(airborne: false)
        #expect(exclusion(aircraft(altitude: 0, hasValidAltitude: false), f, observer: observer(altitudeFt: 400)) == nil)
    }

    @Test func maxDistanceHidesTrafficBeyondIt() {
        let f = filter { $0.aircraftMaxDistance = 20 }
        #expect(exclusion(aircraft(northNM: 19.5), f) == nil)
        #expect(exclusion(aircraft(northNM: 20.5), f) == .beyondMaxDistance)
        #expect(f.isCandidate(aircraft(northNM: 20.5), near: Self.here) == false)
    }

    /// The display stage measures the dead-reckoned position the marker is drawn at. A target
    /// reported at 19.5 NM and flying away at 360 kt has coasted 1.5 NM in 15 s: it is drawn at
    /// 21 NM, so it is not shown, although the cheap cull on its report passed it.
    @Test func maxDistanceUsesTheDeadReckonedPosition() {
        let f = filter { $0.aircraftMaxDistance = 20 }
        let outbound = aircraft(northNM: 19.5, track: 0, groundSpeed: 360, age: 15)
        #expect(f.isCandidate(outbound, near: Self.here) == true)
        let verdict = f.verdict(for: outbound, from: observer())
        #expect(verdict.distanceNM > 20.5 && verdict.distanceNM < 21.5)
        #expect(verdict.exclusion == .beyondMaxDistance)
        #expect(f.displayed([outbound], from: observer()).isEmpty)
    }

    /// The reverse case keeps build 394's two-stage behaviour: an inbound target reported beyond
    /// Max Distance is culled on its report even though it has coasted inside. AR always did this,
    /// and the band setting on must leave AR exactly as it was.
    @Test func inboundTargetReportedBeyondMaxDistanceStaysCulledAsInBuild394() {
        let f = filter { $0.aircraftMaxDistance = 20 }
        let inbound = aircraft(northNM: 21, track: 180, groundSpeed: 360, age: 15)
        #expect(f.verdict(for: inbound, from: observer()).exclusion == nil)
        #expect(f.candidateExclusion(inbound, near: Self.here) == .beyondMaxDistance)
        #expect(exclusion(inbound, f) == .beyondMaxDistance)
    }

    @Test func callsignFilterKeepsOnlyMatches() {
        let f = filter { $0.callsignFilter = " ual " }
        #expect(exclusion(aircraft(callsign: "UAL123"), f) == nil)
        #expect(exclusion(aircraft(callsign: "DAL45"), f) == .callsignFilter)
        // Not a stage-1 rule: TCAS still sees callsign-filtered traffic, as it always has.
        #expect(f.isCandidate(aircraft(callsign: "DAL45"), near: Self.here) == true)
    }

    @Test func ownshipHiddenByCallsign() {
        let f = filter { $0.wifiOwnshipCallsign = "SWA2024" }
        let mine = aircraft(callsign: "SWA2024", northNM: 0.05)
        #expect(exclusion(mine, f) == .ownship)
        #expect(f.isCandidate(mine, near: Self.here) == false)
        #expect(exclusion(aircraft(callsign: "SWA2025"), f) == nil)
    }

    /// The side channel from #13: an id, matched on its own, alongside the callsign.
    @Test func ownshipHiddenById() {
        let f = filter(ownshipID: "abc123")
        let mine = aircraft(id: "abc123", callsign: "", northNM: 0.05)
        #expect(f.isOwnship(mine))
        #expect(exclusion(mine, f) == .ownship)
        #expect(f.isCandidate(mine, near: Self.here) == false)
        #expect(exclusion(aircraft(id: "abc124"), f) == nil)
        // No id and no callsign identified: nothing is ownship, however close.
        #expect(filter().isOwnship(aircraft(northNM: 0.01)) == false)
    }

    @Test func everyExclusionHasItsOwnNote() {
        let notes = TrafficFilter.Exclusion.allCases.map { $0.noteText }
        #expect(notes.allSatisfy { !$0.isEmpty })
        #expect(Set(notes).count == notes.count)
    }

    // MARK: - AR exactly as build 394, with the band setting on

    /// The AR path exactly as build 394 (a94698b) ran it: the view controller's pre-filter, then
    /// the rules inline in `ARSceneManager.updateAircraft`, band hard-coded. Copied here verbatim
    /// as the reference the shared filter must reproduce while the setting is on.
    private func build394Shown(_ fleet: [Aircraft], settings: ARVisualizationSettings,
                               observer obs: TrafficFilter.Observer, onGround: Bool) -> Set<String> {
        guard settings.showAircraft else { return [] }
        let preFiltered = fleet.filter { ac in
            guard settings.showGroundAircraft || !ac.isGroundTraffic else { return false }
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: obs.coordinate, to: ac.coordinate)
            guard distNM <= settings.aircraftMaxDistance else { return false }
            if let own = settings.wifiOwnshipCallsign, ac.callsign == own { return false }
            return true
        }
        var shown = Set<String>()
        for ac in preFiltered {
            if !settings.showGroundAircraft && ac.isGroundTraffic { continue }
            let (predCoord, predAlt) = CalculationsLogic.predictedPosition(for: ac, aheadSeconds: 0)
            let targetAlt = CalculationsLogic.placementAltitude(
                for: ac, targetAltitude: predAlt, userAltitudeFt: obs.altitudeFt,
                geoidSeparationFt: obs.geoidSeparationFt, datumFit: obs.datumFit)
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: obs.coordinate, to: predCoord)
            guard distNM <= settings.aircraftMaxDistance else { continue }
            guard settings.passes(callsign: ac.callsign) else { continue }
            if !onGround, ac.hasValidAltitude, abs(targetAlt - obs.altitudeFt) > 10_000 { continue }
            shown.insert(ac.id)
        }
        return shown
    }

    /// Something for every rule to bite on, kept well clear of every threshold so the few
    /// microseconds between two evaluations of the dead-reckoned position cannot matter.
    private var mixedFleet: [Aircraft] {
        [
            aircraft(id: "near-co-alt",   callsign: "UAL1",    northNM: 3,    altitude: 35_000),
            aircraft(id: "near-low",      callsign: "DAL2",    northNM: 4,    altitude: 4_000),
            aircraft(id: "near-high",     callsign: "AAL3",    northNM: 6,    altitude: 49_000),
            aircraft(id: "mid-in-band",   callsign: "UAL4",    northNM: 12,   altitude: 28_000),
            aircraft(id: "far",           callsign: "SWA5",    northNM: 25,   altitude: 36_000),
            aircraft(id: "outbound-edge", callsign: "UAL6",    northNM: 19,   altitude: 36_000,
                     track: 0, groundSpeed: 480, age: 15),
            aircraft(id: "inbound-edge",  callsign: "JBU7",    northNM: 21,   altitude: 36_000,
                     track: 180, groundSpeed: 480, age: 15),
            aircraft(id: "no-alt",        callsign: "N123AB",  northNM: 8,    altitude: 0,
                     hasValidAltitude: false),
            aircraft(id: "parked",        callsign: "N456CD",  northNM: 2,    altitude: 10),
            aircraft(id: "ground-flag",   callsign: "SKW8",    northNM: 1,    altitude: 5_400,
                     isOnGround: true),
            aircraft(id: "mine",          callsign: "OWN1",    northNM: 0.02, altitude: 36_100),
            aircraft(id: "datum-pair",    callsign: "UAL9",    northNM: 9,    altitude: 25_000,
                     pressureAltitudeFt: 25_000, geometricAltitudeFt: 26_800),
            aircraft(id: "climbing-fast", callsign: "FDX10",   northNM: 5,    altitude: 20_000,
                     track: 90, groundSpeed: 300, age: 5),
        ]
    }

    private var settingsVariants: [ARVisualizationSettings] {
        [
            settings(),
            settings { $0.showGroundAircraft = true },
            settings { $0.callsignFilter = "UAL" },
            settings { $0.wifiOwnshipCallsign = "OWN1" },
            settings { $0.aircraftMaxDistance = 10 },
            settings { $0.aircraftMaxDistance = 50; $0.showGroundAircraft = true; $0.wifiOwnshipCallsign = "OWN1" },
            settings { $0.showAircraft = false },
        ]
    }

    @Test func withTheBandOnARShowsExactlyWhatBuild394Showed() {
        let obs = observer(altitudeFt: 36_000)
        for s in settingsVariants {
            #expect(s.limitTrafficToAltitudeBand == true)
            for airborne in [true, false] {
                let f = TrafficFilter(settings: s, airborne: airborne)
                // The AR path as it now runs: the view controller's candidates, then the scene
                // manager's verdict on each.
                let candidates = f.candidates(mixedFleet, near: obs.coordinate)
                let verdicts = candidates.map { f.verdict(for: $0, from: obs) }
                let arShown = Set(verdicts.filter { $0.isShown }.map { $0.aircraft.id })
                let reference = build394Shown(mixedFleet, settings: s, observer: obs, onGround: !airborne)
                #expect(arShown == reference)
            }
        }
    }

    /// The fleet does exercise the band: some of it is culled in the air and shown on the ground.
    @Test func mixedFleetExercisesTheBand() {
        let obs = observer(altitudeFt: 36_000)
        let air = Set(filter(airborne: true).displayed(mixedFleet, from: obs).map { $0.aircraft.id })
        let ground = Set(filter(airborne: false).displayed(mixedFleet, from: obs).map { $0.aircraft.id })
        #expect(!air.contains("near-low"))
        #expect(!air.contains("near-high"))
        #expect(ground.contains("near-low"))
        #expect(air.contains("no-alt"))
        #expect(air.contains("datum-pair"))
    }

    /// Setting off in the air is the band switched off and nothing else: the same set build 394
    /// showed with the band skipped.
    @Test func settingOffInTheAirOnlyRemovesTheBand() {
        let obs = observer(altitudeFt: 36_000)
        for var s in settingsVariants {
            s.limitTrafficToAltitudeBand = false
            let f = TrafficFilter(settings: s, airborne: true)
            let shown = Set(f.displayed(mixedFleet, from: obs).map { $0.aircraft.id })
            let reference = build394Shown(mixedFleet, settings: s, observer: obs, onGround: true)
            #expect(shown == reference)
        }
    }

    // MARK: - AR and map parity

    /// The map (`displayed`, both stages in one call) shows exactly what the AR path (candidates,
    /// then the scene manager's verdict) shows, for every settings variant, air and ground, band on
    /// and off.
    @Test func mapShowsExactlyWhatARShows() {
        let obs = observer(altitudeFt: 36_000)
        for var s in settingsVariants {
            for band in [true, false] {
                s.limitTrafficToAltitudeBand = band
                for airborne in [true, false] {
                    let f = TrafficFilter(settings: s, airborne: airborne, ownshipID: "near-co-alt")
                    let map: [String] = f.displayed(mixedFleet, from: obs).map { $0.aircraft.id }
                    let candidates = f.candidates(mixedFleet, near: obs.coordinate)
                    let verdicts = candidates.map { f.verdict(for: $0, from: obs) }
                    let ar: [String] = verdicts.filter { $0.isShown }.map { $0.aircraft.id }
                    let mapSet = Set(map)
                    let arSet = Set(ar)
                    #expect(mapSet == arSet)
                    #expect(map.count == mapSet.count)
                }
            }
        }
    }

    /// The map draws each target where the filter judged it: the dead-reckoned position, nearest
    /// first, with the distance it was judged at.
    @Test func displayedIsNearestFirstAtTheDeadReckonedPosition() {
        let obs = observer(altitudeFt: 36_000)
        let shown = filter().displayed(mixedFleet, from: obs)
        #expect(!shown.isEmpty)
        let distances: [Double] = shown.map { $0.distanceNM }
        #expect(distances == distances.sorted())
        for v in shown {
            let predicted = CalculationsLogic.predictedPosition(for: v.aircraft, aheadSeconds: 0).coordinate
            let driftM = CalculationsLogic.distance(from: predicted, to: v.coordinate)
            #expect(driftM < 5)
            let recomputedNM = CalculationsLogic.distanceInNauticalMiles(from: obs.coordinate, to: v.coordinate)
            #expect(abs(recomputedNM - v.distanceNM) < 1e-9)
        }
    }

    /// What the off-screen arrow's note reports agrees with what the map and AR did: a target is
    /// judged shown exactly when `displayed` contains it.
    @Test func judgeAgreesWithDisplayed() {
        let obs = observer(altitudeFt: 36_000)
        for s in settingsVariants {
            let f = TrafficFilter(settings: s, airborne: true)
            let shown = Set(f.displayed(mixedFleet, from: obs).map { $0.aircraft.id })
            for ac in mixedFleet {
                #expect(f.judge(ac, from: obs).isShown == shown.contains(ac.id))
            }
        }
    }

    // MARK: - Airports

    private func airport(_ icao: String, northNM: Double, type: String = "small_airport") -> Airport {
        Airport(id: icao, icao: icao, name: icao, type: type,
                latitude: Self.here.latitude + northNM / 60.0, longitude: Self.here.longitude,
                elevation: 100)
    }

    private var airportField: [Airport] {
        [
            airport("KLRG", northNM: 30, type: "large_airport"),
            airport("KMED", northNM: 10, type: "medium_airport"),
            airport("KSM1", northNM: 2),
            airport("KSM2", northNM: 5),
            airport("KSM3", northNM: 39),
            airport("KFAR", northNM: 45, type: "large_airport"),
            airport("KHEL", northNM: 1, type: "heliport"),
        ]
    }

    @Test func airportRulesAreShowTypeAndMaxDistance() {
        let f = filter { $0.airportMaxDistance = 40 }
        let shown: Set<String> = Set(passingAirports(f).map { $0.icao })
        let expected: Set<String> = ["KLRG", "KMED", "KSM1", "KSM2", "KSM3"]
        #expect(shown == expected)

        let noSmall = filter { $0.airportMaxDistance = 40; $0.showSmallAirports = false }
        let noSmallShown: [String] = passingAirports(noSmall).map { $0.icao }.sorted()
        #expect(noSmallShown == ["KLRG", "KMED"])

        let none = filter { $0.showAirports = false }
        #expect(passingAirports(none).isEmpty)
        #expect(none.shownAirports(airportField, from: Self.here, limit: 30).isEmpty)
    }

    private func passingAirports(_ f: TrafficFilter) -> [Airport] {
        airportField.filter { f.isAirportShown($0, from: Self.here) }
    }

    /// The list the scene draws and the map shows is the predicate's set, nearest first.
    @Test func shownAirportsIsThePredicateNearestFirst() {
        let f = filter { $0.airportMaxDistance = 40 }
        let list: [String] = f.shownAirports(airportField, from: Self.here, limit: 30).map { $0.icao }
        let predicate: Set<String> = Set(passingAirports(f).map { $0.icao })
        #expect(Set(list) == predicate)
        #expect(list == ["KSM1", "KSM2", "KMED", "KLRG", "KSM3"])
    }

    /// The scene's node cap keeps the nearest; the map takes the same cap so it never offers an
    /// airport the scene does not draw.
    @Test func shownAirportsKeepsTheNearestWhenCapped() {
        let f = filter { $0.airportMaxDistance = 40 }
        let capped: [String] = f.shownAirports(airportField, from: Self.here, limit: 2).map { $0.icao }
        #expect(capped == ["KSM1", "KSM2"])
        #expect(f.shownAirports(airportField, from: Self.here, limit: 0).isEmpty)
        #expect(ARSceneManager.maxAirportNodes == 30)
    }
}
