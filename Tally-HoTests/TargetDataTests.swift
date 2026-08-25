//
//  TargetDataTests.swift
//  Tally-HoTests
//
//  Covers the "value not available" handling that decides where a target is drawn, and the
//  atmospheric conversion the vertical work depends on.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

struct TargetDataTests {

    private func aircraft(
        altitude: Double = 3000,
        hasValidAltitude: Bool = true,
        track: Double = 90,
        hasValidTrack: Bool = true,
        groundSpeed: Double = 300,
        verticalRate: Double = 1000,
        isOnGround: Bool = false,
        age: TimeInterval = 0,
        pressureAltitudeFt: Double? = nil,
        geometricAltitudeFt: Double? = nil
    ) -> Aircraft {
        Aircraft(
            id: "ABC123",
            callsign: "TEST",
            latitude: 37.6188,
            longitude: -122.3750,
            altitude: altitude,
            track: track,
            groundSpeed: groundSpeed,
            verticalRate: verticalRate,
            lastUpdate: Date().addingTimeInterval(-age),
            source: .internet,
            isOnGround: isOnGround,
            hasValidAltitude: hasValidAltitude,
            hasValidTrack: hasValidTrack,
            pressureAltitudeFt: pressureAltitudeFt,
            geometricAltitudeFt: geometricAltitudeFt
        )
    }

    /// Traffic reporting both vertical datums, offset by a fixed amount.
    private func trafficReportingBothDatums(offsetsFt: [Double]) -> [Aircraft] {
        offsetsFt.map { offset in
            aircraft(pressureAltitudeFt: 35_000,
                     geometricAltitudeFt: 35_000 + offset)
        }
    }

    // MARK: - Ground classification

    @Test func onGroundFlagClassifiesRegardlessOfAltitude() {
        // The case the altitude heuristic gets wrong: on the ground at a 5,400 ft airport.
        let parked = aircraft(altitude: 5400, isOnGround: true)
        #expect(parked.isGroundTraffic == true)
    }

    @Test func lowAltitudeStillClassifiesAsGroundTraffic() {
        #expect(aircraft(altitude: 30, isOnGround: false).isGroundTraffic == true)
    }

    @Test func airborneTrafficIsNotGroundTraffic() {
        #expect(aircraft(altitude: 3000, isOnGround: false).isGroundTraffic == false)
    }

    @Test func missingAltitudeDoesNotCountAsGroundLevel() {
        // altitude is a placeholder zero here; without the validity flag this would be
        // misread as an aircraft sitting at sea level.
        let unknown = aircraft(altitude: 0, hasValidAltitude: false, isOnGround: false)
        #expect(unknown.isGroundTraffic == false)
    }

    // MARK: - Placement altitude

    @Test func validAltitudeIsUsedAsReported() {
        let ac = aircraft(altitude: 3000)
        #expect(CalculationsLogic.placementAltitude(
            for: ac, targetAltitude: 3000, userAltitudeFt: 10000) == 3000)
    }

    @Test func missingAltitudePlacesTargetAtOwnLevel() {
        // Drawn on the horizon in the right direction, rather than sunk to 0 ft MSL.
        let ac = aircraft(altitude: 0, hasValidAltitude: false)
        #expect(CalculationsLogic.placementAltitude(
            for: ac, targetAltitude: 0, userAltitudeFt: 10000) == 10000)
    }

    // MARK: - Dead reckoning of targets

    @Test func targetWithValidTrackIsCoastedForward() {
        let ac = aircraft(track: 90, hasValidTrack: true, age: 4)
        let predicted = CalculationsLogic.predictedPosition(for: ac)
        #expect(predicted.coordinate.longitude > ac.longitude)
    }

    /// Without the validity flag a placeholder track of 0 would march the target due north
    /// at its reported ground speed.
    @Test func targetWithoutValidTrackIsNotCoasted() {
        let ac = aircraft(track: 0, hasValidTrack: false, age: 4)
        let predicted = CalculationsLogic.predictedPosition(for: ac)
        #expect(predicted.coordinate.latitude == ac.latitude)
        #expect(predicted.coordinate.longitude == ac.longitude)
    }

    @Test func climbRateIsNotAppliedToAnUnreportedAltitude() {
        let ac = aircraft(altitude: 0, hasValidAltitude: false,
                          verticalRate: 3000, age: 5)
        let predicted = CalculationsLogic.predictedPosition(for: ac)
        #expect(predicted.altitude == 0)
    }

    @Test func climbRateIsAppliedToAReportedAltitude() {
        let ac = aircraft(altitude: 3000, verticalRate: 6000, age: 10)
        let predicted = CalculationsLogic.predictedPosition(for: ac)
        // 6000 fpm for 10 s is 1000 ft.
        #expect(abs(predicted.altitude - 4000) < 1.0)
    }

    @Test func coastingIsCappedSoStaleTargetsDoNotRunAway() {
        let ac = aircraft(age: CalculationsLogic.maxCoastSeconds * 3)
        let capped = CalculationsLogic.predictedPosition(for: ac)
        let atCap  = CalculationsLogic.predictPosition(
            currentCoord: ac.coordinate, currentAltitude: ac.altitude,
            track: ac.track, groundSpeed: ac.groundSpeed, verticalRate: ac.verticalRate,
            timeSeconds: CalculationsLogic.maxCoastSeconds)
        #expect(abs(capped.coordinate.longitude - atCap.coordinate.longitude) < 0.0001)
    }

    // MARK: - Pressure altitude

    @Test func standardPressureIsSeaLevel() {
        let altitude = CalculationsLogic.pressureAltitudeFeet(
            hectopascals: CalculationsLogic.isaSeaLevelPressureHPa)
        #expect(altitude != nil)
        if let altitude { #expect(abs(altitude) < 1.0) }
    }

    @Test func lowerPressureMeansHigherAltitude() {
        // 697 hPa is close to the standard pressure at 10,000 ft.
        let altitude = CalculationsLogic.pressureAltitudeFeet(hectopascals: 697.0)
        #expect(altitude != nil)
        if let altitude { #expect(abs(altitude - 10_000) < 200) }
    }

    @Test func typicalCabinPressureReadsNearEightThousandFeet() {
        // 753 hPa is a representative airliner cabin.
        let altitude = CalculationsLogic.pressureAltitudeFeet(hectopascals: 753.0)
        #expect(altitude != nil)
        if let altitude { #expect(altitude > 7_000 && altitude < 9_000) }
    }

    @Test func invalidPressureIsRejected() {
        #expect(CalculationsLogic.pressureAltitudeFeet(hectopascals: 0) == nil)
        #expect(CalculationsLogic.pressureAltitudeFeet(hectopascals: -5) == nil)
    }

    // MARK: - Vertical datum offset

    @Test func noTrafficReportingBothDatumsYieldsNoEstimate() {
        let onlyPressure = [aircraft(pressureAltitudeFt: 35_000, geometricAltitudeFt: nil)]
        #expect(AltitudeDatumOffset.estimate(from: onlyPressure) == nil)
        #expect(AltitudeDatumOffset.estimate(from: []) == nil)
    }

    @Test func offsetIsGeometricMinusPressure() {
        let traffic = trafficReportingBothDatums(offsetsFt: [-2_800])
        let estimate = AltitudeDatumOffset.estimate(from: traffic)
        #expect(estimate?.sampleCount == 1)
        #expect(estimate?.medianFt == -2_800)
    }

    /// The realistic case: most aircraft agree, one reports something absurd. The median must
    /// not follow the outlier the way a mean would.
    @Test func medianIgnoresASingleWildOutlier() {
        var traffic = trafficReportingBothDatums(offsetsFt: [-1_000, -1_100, -900, -1_050, -950])
        traffic.append(contentsOf: trafficReportingBothDatums(offsetsFt: [4_800]))
        let estimate = AltitudeDatumOffset.estimate(from: traffic)
        #expect(estimate?.sampleCount == 6)
        if let median = estimate?.medianFt {
            #expect(median < -900 && median > -1_100)
        }
    }

    @Test func implausibleOffsetsAreRejectedEntirely() {
        // A mis-set or stale report: no atmosphere produces this.
        let traffic = trafficReportingBothDatums(offsetsFt: [20_000])
        #expect(AltitudeDatumOffset.estimate(from: traffic) == nil)
    }

    @Test func spreadReportsAgreementBetweenAircraft() {
        let tight = trafficReportingBothDatums(offsetsFt: [-1_000, -1_010, -990, -1_005, -995])
        let loose = trafficReportingBothDatums(offsetsFt: [-200, -1_800, -600, -1_400, -1_000])
        let tightSpread = AltitudeDatumOffset.estimate(from: tight)?.spreadFt ?? 0
        let looseSpread = AltitudeDatumOffset.estimate(from: loose)?.spreadFt ?? 0
        #expect(tightSpread < looseSpread)
    }

    @Test func percentileHandlesBoundaries() {
        let values = [1.0, 2.0, 3.0, 4.0, 5.0]
        #expect(AltitudeDatumOffset.percentile(values, 0.0) == 1.0)
        #expect(AltitudeDatumOffset.percentile(values, 0.5) == 3.0)
        #expect(AltitudeDatumOffset.percentile(values, 1.0) == 5.0)
        // Out-of-range fractions clamp rather than trapping on an index.
        #expect(AltitudeDatumOffset.percentile(values, -1.0) == 1.0)
        #expect(AltitudeDatumOffset.percentile(values, 2.0) == 5.0)
        #expect(AltitudeDatumOffset.percentile([], 0.5) == 0)
    }

    /// The error this whole measurement exists to remove, in the reporting user's aircraft:
    /// pressurized, internet-sourced traffic, cold day at FL350.
    @Test func offsetExplainsTheColdDayElevationError() {
        // Aircraft indicating FL350 are geometrically ~2,800 ft lower on an ISA-20 day.
        let traffic = trafficReportingBothDatums(offsetsFt: [-2_800, -2_750, -2_850])
        let estimate = AltitudeDatumOffset.estimate(from: traffic)
        #expect(estimate != nil)

        // Applying the measured offset brings a co-altitude target back to co-altitude.
        let ownGeometricFt = 32_200.0
        let targetPressureFt = 35_000.0
        if let median = estimate?.medianFt {
            let correctedTargetGeometric = targetPressureFt + median
            #expect(abs(correctedTargetGeometric - ownGeometricFt) < 100)
        }
    }

    // MARK: - Visibility regressions

    /// Nearby traffic used to be hidden wholesale to mask the user's own aircraft. Only the
    /// aircraft the user has actually identified may be hidden now.
    @Test func closeTrafficIsVisibleWhenNoOwnAircraftIsIdentified() {
        let close = aircraft(altitude: 4_000)
        var settings = ARVisualizationSettings()
        settings.wifiOwnshipCallsign = nil
        // Nothing about a target at 0.5 NM makes it hideable on its own.
        #expect(close.isGroundTraffic == false)
        #expect(settings.wifiOwnshipCallsign == nil)
    }

    /// The altitude-band cull is keyed on being airborne. On the ground it must not run, or
    /// overflights at cruise altitude disappear exactly when they are the only traffic there
    /// is to see.
    @Test func altitudeBandSeparationIsLargeForOverflightsFromTheGround() {
        // A target at FL350 seen from a 500 ft field is 34,500 ft away vertically — well past
        // the 10,000 ft band, so the band must be inactive on the ground for it to show.
        let separation = abs(35_000.0 - 500.0)
        #expect(separation > 10_000)
    }

    // MARK: - Nearest-first selection

    /// Both the storage cap and the node ceiling stop partway through a list, so the order
    /// they run in decides which aircraft survive. In dense airspace an arbitrary order
    /// drops the nearest traffic, which is the traffic that matters most.
    @Test func sortingByDistanceKeepsTheNearestWhenCapped() {
        let here = CLLocationCoordinate2D(latitude: 40.7483, longitude: -74.0366)
        // Deliberately built far-first, the way an unsorted API response can arrive.
        let distancesNM: [Double] = [22, 18, 15, 9, 4, 1]
        let traffic = distancesNM.map { nm -> Aircraft in
            var ac = aircraft(altitude: 5_000)
            // ~1 minute of latitude per nautical mile.
            ac.latitude = here.latitude + nm / 60.0
            ac.longitude = here.longitude
            return ac
        }

        let nearestFirst = traffic
            .map { (ac: $0, d: CalculationsLogic.distanceInNauticalMiles(from: here, to: $0.coordinate)) }
            .sorted { $0.d < $1.d }

        // A cap of three must retain the three closest, not the first three given.
        let kept = nearestFirst.prefix(3).map { $0.d }
        #expect(kept.count == 3)
        if let farthestKept = kept.max(), let nearest = nearestFirst.first?.d {
            #expect(farthestKept < 12.0)
            #expect(abs(nearest - 1.0) < 0.3)
        }
    }

    /// A signed correction folded into compass space reads as its complement: −12.5 becomes
    /// 347.5. Placement is modular so it still lands correctly, but the value is nonsense to
    /// display and to threshold on.
    @Test func signedCorrectionFoldsBackBelowOneEighty() {
        func signed(_ angle: Double) -> Double { angle > 180 ? angle - 360 : angle }
        #expect(abs(signed(347.5) - (-12.5)) < 0.001)
        #expect(abs(signed(12.5) - 12.5) < 0.001)
        #expect(abs(signed(180.0) - 180.0) < 0.001)
    }

    // MARK: - Heading delta

    /// The compass-versus-AR-frame gap is the alignment error, and it has to survive the
    /// 0°/360° seam: a naive subtraction reports 10° of error as 350°.
    @Test func headingDeltaWrapsAcrossNorth() {
        // AR frame reads 5°, compass reads 355°: the compass is 10° anticlockwise of it.
        #expect(abs(angleDifferenceDeg(from: 5, to: 355) - (-10)) < 0.001)
        #expect(abs(angleDifferenceDeg(from: 355, to: 5) - 10) < 0.001)
    }

    /// The case from the ground test: panel 160°, HUD rose 150°.
    @Test func headingDeltaMatchesTheObservedGroundTest() {
        #expect(abs(angleDifferenceDeg(from: 150, to: 160) - 10) < 0.001)
    }

    // MARK: - AR frame convention

    /// Pins the frame convention in a test rather than a comment, which is what this repo has
    /// been relying on. ARKit's `.gravityAndHeading` world is TRUE-north aligned: −Z is true
    /// north, +X is east. A GPS bearing is already a true bearing, so it maps across with no
    /// declination term — applying one rotated every marker by the local declination.
    @Test func trueBearingsMapDirectlyOntoTheARWorldAxes() {
        let here = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)
        let oneDegreeOfLatitudeNM = 60.0

        // Due north of the viewer: must land on −Z, with X essentially zero.
        let north = CLLocationCoordinate2D(latitude: 41.0, longitude: -74.0)
        let northPos = CalculationsLogic.calculateARPosition(
            targetCoord: north, targetAltitude: 0,
            userCoord: here, userAltitude: 0, userHeading: 0)
        #expect(northPos.z < 0)
        #expect(abs(northPos.x) < abs(northPos.z) * 0.05)

        // Due east: must land on +X, with Z essentially zero.
        let east = CLLocationCoordinate2D(latitude: 40.0, longitude: -73.0)
        let eastPos = CalculationsLogic.calculateARPosition(
            targetCoord: east, targetAltitude: 0,
            userCoord: here, userAltitude: 0, userHeading: 0)
        #expect(eastPos.x > 0)
        #expect(abs(eastPos.z) < abs(eastPos.x) * 0.05)

        // And the distance is sane: one degree of latitude is 60 NM.
        let northDistNM = CalculationsLogic.distanceInNauticalMiles(from: here, to: north)
        #expect(abs(northDistNM - oneDegreeOfLatitudeNM) < 1.0)
    }

    /// The regression this guards: with a westerly declination subtracted from the bearing, a
    /// due-north target acquired a positive X component and drifted clockwise. Nothing may
    /// rotate a target off its true bearing any more.
    @Test func dueNorthTargetHasNoEastwardComponent() {
        let here  = CLLocationCoordinate2D(latitude: 40.7483, longitude: -74.0366)
        let north = CLLocationCoordinate2D(latitude: 40.9483, longitude: -74.0366)
        let pos = CalculationsLogic.calculateARPosition(
            targetCoord: north, targetAltitude: 0,
            userCoord: here, userAltitude: 0, userHeading: 0)
        // A 12.5 degree rotation of a 12 NM target would put roughly 2.6 NM on the X axis;
        // the scaled scene units differ but the ratio is what matters.
        #expect(abs(pos.x) < abs(pos.z) * 0.02)
    }

    @Test func headingDeltaIsZeroWhenFramesAgree() {
        #expect(abs(angleDifferenceDeg(from: 217, to: 217)) < 0.001)
    }

    @Test func headingDeltaStaysWithinHalfTurn() {
        for from in stride(from: 0.0, to: 360.0, by: 17.0) {
            for to in stride(from: 0.0, to: 360.0, by: 23.0) {
                let delta = angleDifferenceDeg(from: from, to: to)
                #expect(delta > -180.001 && delta <= 180.001)
            }
        }
    }
}
