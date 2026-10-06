//
//  TCASSystemTests.swift
//  Tally-HoTests
//
//  The TCAS II-style alerting of #13: the sensitivity-level table, the range and vertical tests
//  across the encounter geometries that matter (head-on, overtaking, crossing, diverging, close
//  parallel, level-off, fast climber), the advisory hysteresis, and the primary-threat ranking.
//
//  Expected thresholds are worked by hand in each test from the SL table, so a test failing says
//  which number moved, not just that something did.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

struct TCASSystemTests {

    // MARK: - Helpers

    private typealias SL = TCASSystem.SensitivityLevel

    /// Intruder-minus-own geometry in nautical miles, knots, feet and feet per minute.
    private func relative(
        northNM: Double, eastNM: Double = 0,
        vNorthKt: Double = 0, vEastKt: Double = 0,
        dhFt: Double = 0, dhdotFpm: Double = 0,
        hasVelocity: Bool = true,
        id: String = "X"
    ) -> TCASSystem.RelativeState {
        let nm = CalculationsLogic.nauticalMileToMeters
        let kt = CalculationsLogic.knotsToMetersPerSecond
        return TCASSystem.RelativeState(
            id: id,
            northM: northNM * nm,
            eastM: eastNM * nm,
            hasHorizontalVelocity: hasVelocity,
            velocityNorthMS: vNorthKt * kt,
            velocityEastMS: vEastKt * kt,
            altitudeDeltaFt: dhFt,
            verticalRateDeltaFpm: dhdotFpm
        )
    }

    private func level(_ state: TCASSystem.RelativeState, _ sl: SL = .sl5) -> TCASAlertLevel {
        TCASSystem.assess(state, sensitivity: sl).level
    }

    private func assessment(_ level: TCASAlertLevel, tau: Double, range: Double = 1.0)
        -> TCASSystem.Assessment {
        TCASSystem.Assessment(level: level, tauS: tau, rangeNM: range)
    }

    // MARK: - Sensitivity-level table

    @Test func sensitivityLevelsFollowTheTable() {
        // Below 2,350 ft the bands are height above the ground.
        #expect(SL.forOwnAltitude(mslFt: 5_400, aglFt: 999) == .sl2)
        #expect(SL.forOwnAltitude(mslFt: 5_400, aglFt: 1_000) == .sl3)
        #expect(SL.forOwnAltitude(mslFt: 5_400, aglFt: 2_349) == .sl3)
        // Above it, altitude.
        #expect(SL.forOwnAltitude(mslFt: 2_350, aglFt: 2_350) == .sl4)
        #expect(SL.forOwnAltitude(mslFt: 4_999, aglFt: nil) == .sl4)
        #expect(SL.forOwnAltitude(mslFt: 5_000, aglFt: nil) == .sl5)
        #expect(SL.forOwnAltitude(mslFt: 9_999, aglFt: nil) == .sl5)
        #expect(SL.forOwnAltitude(mslFt: 10_000, aglFt: nil) == .sl6)
        #expect(SL.forOwnAltitude(mslFt: 19_999, aglFt: nil) == .sl6)
        #expect(SL.forOwnAltitude(mslFt: 20_000, aglFt: nil) == .sl7)
        #expect(SL.forOwnAltitude(mslFt: 42_000, aglFt: nil) == .sl7)
        #expect(SL.forOwnAltitude(mslFt: 42_001, aglFt: nil) == .sl7High)
    }

    @Test func withoutHeightAboveGroundMSLStandsIn() {
        #expect(SL.forOwnAltitude(mslFt: 800, aglFt: nil) == .sl2)
        #expect(SL.forOwnAltitude(mslFt: 1_500, aglFt: nil) == .sl3)
        #expect(SL.forOwnAltitude(mslFt: 3_000, aglFt: nil) == .sl4)
    }

    @Test func heightAboveGroundDecidesTheLowBandsAtAHighField() {
        // 1,500 ft above a 9,900 ft field is SL3, not the SL5 its MSL altitude would give.
        #expect(SL.forOwnAltitude(mslFt: 11_400, aglFt: 1_500) == .sl3)
        // 3,000 ft above the same field is back on the altitude bands.
        #expect(SL.forOwnAltitude(mslFt: 12_900, aglFt: 3_000) == .sl6)
    }

    @Test func tableValuesMatchTCASII() {
        #expect(SL.sl2.taTauS == 20 && SL.sl2.taDMODNM == 0.30 && SL.sl2.taZTHRFt == 850)
        #expect(SL.sl2.allowsRA == false)
        #expect(SL.sl3.taTauS == 25 && SL.sl3.raTauS == 15)
        #expect(SL.sl3.taDMODNM == 0.33 && SL.sl3.raDMODNM == 0.20)
        #expect(SL.sl3.taZTHRFt == 850 && SL.sl3.raZTHRFt == 600)
        #expect(SL.sl4.taTauS == 30 && SL.sl4.raTauS == 20)
        #expect(SL.sl4.taDMODNM == 0.48 && SL.sl4.raDMODNM == 0.35)
        #expect(SL.sl5.taTauS == 40 && SL.sl5.raTauS == 25)
        #expect(SL.sl5.taDMODNM == 0.75 && SL.sl5.raDMODNM == 0.55)
        #expect(SL.sl6.taTauS == 45 && SL.sl6.raTauS == 30)
        #expect(SL.sl6.taDMODNM == 1.00 && SL.sl6.raDMODNM == 0.80)
        #expect(SL.sl7.taTauS == 48 && SL.sl7.raTauS == 35)
        #expect(SL.sl7.taDMODNM == 1.30 && SL.sl7.raDMODNM == 1.10)
        #expect(SL.sl7.taZTHRFt == 850 && SL.sl7.raZTHRFt == 700)
        #expect(SL.sl7High.taZTHRFt == 1_200 && SL.sl7High.raZTHRFt == 800)
    }

    // MARK: - Head-on

    /// SL5, 500 kt closure (0.1389 NM/s), co-altitude.
    ///   TA when (r - 0.5625/r) / 0.1389 < 40  ->  r < ~5.65 NM
    ///   RA when (r - 0.3025/r) / 0.1389 < 25  ->  r < ~3.56 NM
    @Test func headOnAlertsAtTheTauThresholds() {
        #expect(level(relative(northNM: 6.0, vNorthKt: -500)) == .none)              // tau 42.5 s
        #expect(level(relative(northNM: 5.0, vNorthKt: -500)) == .trafficAdvisory)   // TA tau 35.2 s, RA 35.6 s
        #expect(level(relative(northNM: 3.0, vNorthKt: -500)) == .resolutionAdvisory) // RA tau 20.9 s
    }

    @Test func headOnTauIsReported() {
        let result = TCASSystem.assess(relative(northNM: 3.0, vNorthKt: -500), sensitivity: .sl5)
        // Against the RA DMOD: (3 - 0.3025/3) / (500/3600) = 20.87 s.
        #expect(abs(result.tauS - 20.87) < 0.05)
        #expect(abs(result.rangeNM - 3.0) < 1e-9)
    }

    // MARK: - Overtaking

    /// SL5, intruder behind and 150 kt faster (0.0417 NM/s closure).
    @Test func overtakingTrafficFromBehindAlerts() {
        #expect(level(relative(northNM: -2.5, vNorthKt: 150)) == .none)              // TA tau 54.6 s
        #expect(level(relative(northNM: -1.5, vNorthKt: 150)) == .trafficAdvisory)   // TA 27.0 s, RA 31.2 s
        #expect(level(relative(northNM: -1.0, vNorthKt: 150)) == .resolutionAdvisory) // RA 16.7 s
    }

    // MARK: - Crossing

    /// SL5, own northbound 250 kt, intruder westbound 250 kt from the north-east on a collision
    /// course: relative position (d, d), relative velocity (-250, -250) kt — 353.6 kt closure.
    @Test func crossingOnACollisionCourseAlerts() {
        #expect(level(relative(northNM: 4.0, eastNM: 4.0, vNorthKt: -250, vEastKt: -250)) == .none)
        // r = 2.83 NM: TA tau 26.8 s, RA tau 27.7 s.
        #expect(level(relative(northNM: 2.0, eastNM: 2.0, vNorthKt: -250, vEastKt: -250))
                == .trafficAdvisory)
        // r = 2.12 NM: RA tau 20.1 s.
        #expect(level(relative(northNM: 1.5, eastNM: 1.5, vNorthKt: -250, vEastKt: -250))
                == .resolutionAdvisory)
    }

    // MARK: - Diverging

    @Test func divergingTrafficNeverAlerts() {
        // Ahead and pulling away, co-altitude, just outside DMOD.
        #expect(level(relative(northNM: 1.0, vNorthKt: 150)) == .none)
        // A head-on that has already passed: behind and still opening at 500 kt.
        #expect(level(relative(northNM: -1.0, vNorthKt: -500)) == .none)
        // Opening sideways.
        #expect(level(relative(northNM: 0, eastNM: 0.9, vEastKt: 200)) == .none)
    }

    @Test func divergingTrafficHasInfiniteTau() {
        let result = TCASSystem.assess(relative(northNM: 1.0, vNorthKt: 150), sensitivity: .sl5)
        #expect(result.tauS == .infinity)
    }

    // MARK: - Close parallel inside DMOD

    /// No closure at all, so only `r < DMOD` can pass: SL5 TA DMOD 0.75 NM, RA DMOD 0.55 NM.
    @Test func closeParallelInsideDMODAlertsWithoutClosure() {
        #expect(level(relative(northNM: 0, eastNM: 0.50)) == .resolutionAdvisory)
        #expect(level(relative(northNM: 0, eastNM: 0.65)) == .trafficAdvisory)
        #expect(level(relative(northNM: 0, eastNM: 1.00)) == .none)
    }

    // MARK: - Level-off inside ZTHR

    /// Parallel 0.4 NM abeam (inside both DMODs), intruder level: only `|dh| < ZTHR` can pass the
    /// vertical test. SL5 TA ZTHR 850 ft, RA ZTHR 600 ft.
    @Test func levelTrafficInsideZTHRAlerts() {
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: 500)) == .resolutionAdvisory)
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: 700)) == .trafficAdvisory)
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: 900)) == .none)
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: -700)) == .trafficAdvisory)
    }

    @Test func levellingOffInsideZTHRDowngradesTheRAToATA() {
        // 700 ft below and still climbing at 3,000 fpm: 14 s to co-altitude, under the RA's 25 s.
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: -700, dhdotFpm: 3_000)) == .resolutionAdvisory)
        // Levelled off where it is: outside the RA's 600 ft, inside the TA's 850 ft.
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: -700, dhdotFpm: 0)) == .trafficAdvisory)
    }

    // MARK: - Fast climber

    /// Parallel 0.4 NM abeam, so the range test passes and the vertical tau decides.
    @Test func fastClimberAlertsOnVerticalTau() {
        // 3,000 ft below at 6,000 fpm: 30 s to co-altitude — TA (< 40), not RA (> 25).
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: -3_000, dhdotFpm: 6_000)) == .trafficAdvisory)
        // 2,000 ft below at 6,000 fpm: 20 s — RA.
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: -2_000, dhdotFpm: 6_000)) == .resolutionAdvisory)
        // The same gap closing at 1,000 fpm: 180 s — nothing.
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: -3_000, dhdotFpm: 1_000)) == .none)
        // Fast, but descending away.
        #expect(level(relative(northNM: 0, eastNM: 0.4, dhFt: -3_000, dhdotFpm: -6_000)) == .none)
    }

    @Test func fastClimberNeedsTheRangeTestToo() {
        // The same climber 8 NM away and not closing horizontally: vertical passes, range does not.
        #expect(level(relative(northNM: 0, eastNM: 8.0, dhFt: -2_000, dhdotFpm: 6_000)) == .none)
    }

    // MARK: - Sensitivity-level effects

    @Test func sl2IssuesTrafficAdvisoriesOnly() {
        // Co-located, co-altitude: an RA anywhere else.
        #expect(level(relative(northNM: 0.1, eastNM: 0), .sl2) == .trafficAdvisory)
        #expect(level(relative(northNM: 0.1, eastNM: 0), .sl5) == .resolutionAdvisory)
    }

    @Test func higherLevelsAlertEarlier() {
        // 5 NM head-on at 500 kt: SL5 TA (35 s < 40), SL4 nothing (TA tau 30).
        #expect(level(relative(northNM: 5.0, vNorthKt: -500), .sl4) == .none)
        #expect(level(relative(northNM: 5.0, vNorthKt: -500), .sl5) == .trafficAdvisory)
    }

    @Test func aboveFL420TheVerticalThresholdsOpen() {
        // 1,000 ft apart, level, inside DMOD: nothing at SL7, a TA above FL420 (ZTHR 1,200).
        #expect(level(relative(northNM: 0, eastNM: 0.5, dhFt: 1_000), .sl7) == .none)
        #expect(level(relative(northNM: 0, eastNM: 0.5, dhFt: 1_000), .sl7High) == .trafficAdvisory)
    }

    // MARK: - Unknown direction

    @Test func intruderWithNoDirectionAlertsOnlyInsideDMOD() {
        // Would be a TA head-on if its velocity were known; without one there is no range rate.
        #expect(level(relative(northNM: 5.0, vNorthKt: -500, hasVelocity: false)) == .none)
        #expect(level(relative(northNM: 0.6, hasVelocity: false)) == .trafficAdvisory)
    }

    // MARK: - Modified tau

    @Test func modifiedTauIsZeroInsideDMODAndInfiniteWhenOpening() {
        #expect(TCASSystem.modifiedTauS(rangeNM: 0.5, rangeRateNMPerS: -0.1, dmodNM: 0.75) == 0)
        #expect(TCASSystem.modifiedTauS(rangeNM: 0.5, rangeRateNMPerS: 0.1, dmodNM: 0.75) == .infinity)
        #expect(TCASSystem.modifiedTauS(rangeNM: 0.5, rangeRateNMPerS: nil, dmodNM: 0.75) == .infinity)
        // (2 - 0.25 / 2) / 0.1 = 18.75 s.
        let tau = TCASSystem.modifiedTauS(rangeNM: 2.0, rangeRateNMPerS: -0.1, dmodNM: 0.5)
        #expect(abs(tau - 18.75) < 1e-9)
    }

    // MARK: - Adapter from Aircraft

    private let home = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)

    private func coordinate(northNM: Double, eastNM: Double = 0) -> CLLocationCoordinate2D {
        let latRad = home.latitude * .pi / 180
        let radius = CalculationsLogic.earthRadius(at: latRad)
        let metresNorth = northNM * CalculationsLogic.nauticalMileToMeters
        let metresEast = eastNM * CalculationsLogic.nauticalMileToMeters
        return CLLocationCoordinate2D(
            latitude: home.latitude + metresNorth / radius * 180 / .pi,
            longitude: home.longitude + metresEast / (radius * cos(latRad)) * 180 / .pi)
    }

    private func intruder(
        id: String = "INTR", northNM: Double, altitude: Double = 8_000,
        track: Double = 180, groundSpeed: Double = 250, age: TimeInterval = 0,
        isOnGround: Bool = false, hasValidAltitude: Bool = true
    ) -> Aircraft {
        let position = coordinate(northNM: northNM)
        return Aircraft(
            id: id, callsign: id,
            latitude: position.latitude, longitude: position.longitude,
            altitude: altitude, track: track, groundSpeed: groundSpeed, verticalRate: 0,
            lastUpdate: Date().addingTimeInterval(-age),
            source: .internet,
            isOnGround: isOnGround,
            hasValidAltitude: hasValidAltitude,
            hasValidTrack: true
        )
    }

    /// Northbound at 250 kt, 8,000 ft, no height above ground known: SL5.
    private var ownship: TCASSystem.OwnState {
        TCASSystem.OwnState(coordinate: home, altitudeFt: 8_000, trackDeg: 0, groundSpeedKt: 250,
                            verticalRateFpm: 0, heightAboveGroundFt: nil)
    }

    @Test func aircraftAdapterReproducesTheHeadOnThresholds() {
        let pass = TCASSystem.assess(
            aircraft: [intruder(id: "FAR", northNM: 6.0),
                       intruder(id: "TA", northNM: 5.0),
                       intruder(id: "RA", northNM: 3.0)],
            own: ownship)
        #expect(pass.sensitivity == .sl5)
        #expect(pass.assessments["FAR"]?.level == TCASAlertLevel.none)
        #expect(pass.assessments["TA"]?.level == .trafficAdvisory)
        #expect(pass.assessments["RA"]?.level == .resolutionAdvisory)
    }

    @Test func groundNoAltitudeAndStaleTrafficIsNotAssessed() {
        let pass = TCASSystem.assess(
            aircraft: [intruder(id: "GND", northNM: 0.2, isOnGround: true),
                       intruder(id: "NOALT", northNM: 0.2, hasValidAltitude: false),
                       // Past maxCoastSeconds: its marker is frozen at a guess.
                       intruder(id: "STALE", northNM: 0.2, age: CalculationsLogic.maxCoastSeconds + 5)],
            own: ownship)
        #expect(pass.assessments.isEmpty)
    }

    @Test func heightAboveGroundSelectsTheLowSensitivityLevel() {
        var own = ownship
        own.heightAboveGroundFt = 800
        let pass = TCASSystem.assess(aircraft: [intruder(northNM: 0.1)], own: own)
        #expect(pass.sensitivity == .sl2)
        // Co-located, but SL2 never issues an RA.
        #expect(pass.assessments["INTR"]?.level == .trafficAdvisory)
    }

    // MARK: - Hysteresis

    @Test func anRAIsHeldThenFallsBackToTAThenClears() {
        var tracker = TCASSystem.AdvisoryTracker()
        let ra = ["A": assessment(.resolutionAdvisory, tau: 10)]
        let clear = ["A": assessment(.none, tau: .infinity, range: 3)]

        var result = tracker.update(ra, sensitivityLevel: 5, at: 100)
        #expect(result.threats["A"] == .resolutionAdvisory)
        #expect(result.overallLevel == .resolutionAdvisory)

        // Condition gone, RA still held (hold 5 s).
        result = tracker.update(clear, sensitivityLevel: 5, at: 104.9)
        #expect(result.threats["A"] == .resolutionAdvisory)

        // RA hold over, TA hold (8 s) still running.
        result = tracker.update(clear, sensitivityLevel: 5, at: 105.5)
        #expect(result.threats["A"] == .trafficAdvisory)
        #expect(result.overallLevel == .trafficAdvisory)

        // Both over.
        result = tracker.update(clear, sensitivityLevel: 5, at: 108.5)
        #expect(result.threats.isEmpty)
        #expect(result.overallLevel == .none)
        #expect(result.primaryThreatID == nil)
    }

    @Test func aTAThatComesBackRestartsItsHold() {
        var tracker = TCASSystem.AdvisoryTracker()
        let ta = ["A": assessment(.trafficAdvisory, tau: 30)]
        let clear = ["A": assessment(.none, tau: .infinity)]
        _ = tracker.update(ta, sensitivityLevel: 5, at: 0)
        _ = tracker.update(clear, sensitivityLevel: 5, at: 6)
        _ = tracker.update(ta, sensitivityLevel: 5, at: 7)
        // 13 s after the first TA, but only 6 s after the second.
        let result = tracker.update(clear, sensitivityLevel: 5, at: 13)
        #expect(result.threats["A"] == .trafficAdvisory)
    }

    @Test func anAircraftThatLeavesThePictureIsDroppedAtOnce() {
        var tracker = TCASSystem.AdvisoryTracker()
        _ = tracker.update(["A": assessment(.resolutionAdvisory, tau: 10)], sensitivityLevel: 5, at: 0)
        // Gone from the input — out of range, or identified as ownship. Not held.
        let result = tracker.update([:], sensitivityLevel: 5, at: 0.25)
        #expect(result.threats.isEmpty)
    }

    @Test func resetForgetsHeldAdvisories() {
        var tracker = TCASSystem.AdvisoryTracker()
        _ = tracker.update(["A": assessment(.trafficAdvisory, tau: 30)], sensitivityLevel: 5, at: 0)
        tracker.reset()
        let result = tracker.update(["A": assessment(.none, tau: .infinity)], sensitivityLevel: 5, at: 1)
        #expect(result.threats.isEmpty)
    }

    @Test func noneLevelTrafficNeverEntersTheTracker() {
        var tracker = TCASSystem.AdvisoryTracker()
        let result = tracker.update(["A": assessment(.none, tau: 50)], sensitivityLevel: 5, at: 0)
        #expect(result.threats.isEmpty)
        #expect(result.sensitivityLevel == 5)
    }

    // MARK: - Primary threat

    @Test func primaryThreatIsTheLowestTau() {
        var tracker = TCASSystem.AdvisoryTracker()
        let result = tracker.update([
            "SLOW": assessment(.trafficAdvisory, tau: 30, range: 1.0),
            "FAST": assessment(.trafficAdvisory, tau: 12, range: 3.0),
            "MID": assessment(.trafficAdvisory, tau: 20, range: 2.0),
        ], sensitivityLevel: 5, at: 0)
        #expect(result.primaryThreatID == "FAST")
        #expect(result.threatTausS["FAST"] == 12)
    }

    @Test func anRAOutranksATAWhateverTheirTaus() {
        var tracker = TCASSystem.AdvisoryTracker()
        let result = tracker.update([
            "TA": assessment(.trafficAdvisory, tau: 5),
            "RA": assessment(.resolutionAdvisory, tau: 20),
        ], sensitivityLevel: 5, at: 0)
        #expect(result.primaryThreatID == "RA")
    }

    @Test func aClosingThreatOutranksOneThatIsNot() {
        var tracker = TCASSystem.AdvisoryTracker()
        let result = tracker.update([
            "PARALLEL": assessment(.trafficAdvisory, tau: .infinity, range: 0.3),
            "CLOSING": assessment(.trafficAdvisory, tau: 25, range: 2.0),
        ], sensitivityLevel: 5, at: 0)
        #expect(result.primaryThreatID == "CLOSING")
    }

    @Test func equalTausAreRankedByRange() {
        var tracker = TCASSystem.AdvisoryTracker()
        let result = tracker.update([
            "FAR": assessment(.trafficAdvisory, tau: 0, range: 0.6),
            "NEAR": assessment(.trafficAdvisory, tau: 0, range: 0.2),
        ], sensitivityLevel: 5, at: 0)
        #expect(result.primaryThreatID == "NEAR")
    }

    @Test func endToEndThePrimaryThreatIsTheMostUrgentHeadOn() {
        var tracker = TCASSystem.AdvisoryTracker()
        let pass = TCASSystem.assess(
            aircraft: [intruder(id: "NEAR", northNM: 4.0), intruder(id: "FARTHER", northNM: 5.0)],
            own: ownship)
        let result = tracker.update(pass.assessments, sensitivityLevel: pass.sensitivity.number, at: 0)
        #expect(result.threats.count == 2)
        #expect(result.primaryThreatID == "NEAR")
        #expect(result.sensitivityLevel == 5)
    }
}
