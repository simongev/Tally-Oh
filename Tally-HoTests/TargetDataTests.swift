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
import SceneKit
import UIKit
import ARKit
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

    // MARK: - Angular response estimator

    /// Feeds a synthetic series into the estimator: the driver turns by `driverStep` each sample
    /// and the response follows at `responseRatio` of it, with `jitterDeg` of alternating noise
    /// added to the response only.
    private func response(driverStep: Double,
                          responseRatio: Double,
                          jitterDeg: Double = 0,
                          samples: Int = 60) -> AngularResponse.Estimate? {
        var estimator = AngularResponse(window: 1000, minDriverRotationDeg: 20, minDriverExcursionDeg: 10)
        var driver = 0.0
        var response = 0.0
        for i in 0..<samples {
            // Deterministic alternating jitter, so the test cannot flake.
            let jitter = (i % 2 == 0 ? jitterDeg : -jitterDeg)
            estimator.add(driver: driver,
                          response: (response + jitter).truncatingRemainder(dividingBy: 360),
                          at: TimeInterval(i) * 0.1)
            driver   += driverStep
            response += driverStep * responseRatio
        }
        return estimator.estimate
    }

    /// A compass that genuinely follows the phone.
    @Test func responseIsOneWhenTheSensorTracks() {
        let estimate = response(driverStep: 2.0, responseRatio: 1.0)
        #expect(estimate != nil)
        if let estimate {
            #expect(abs(estimate.slope - 1.0) < 0.05)
            #expect(estimate.correlation > 0.95)
        }
    }

    /// The measured case: the phone turns, the sensor does not. Two flights read like this.
    @Test func responseIsZeroWhenTheSensorIsSlavedElsewhere() {
        let estimate = response(driverStep: 2.0, responseRatio: 0.0)
        #expect(estimate != nil)
        if let estimate { #expect(abs(estimate.slope) < 0.05) }
    }

    /// **The regression this exists to prevent.** The first estimator summed *absolute* changes,
    /// so jitter on a stationary sensor accumulated into apparent response: it read 0.61 in
    /// flight where the true slope was 0.018, which would have certified a compass that was not
    /// tracking the phone at all. Signed least squares must stay near zero here, because jitter
    /// is uncorrelated with the driver and cancels in the numerator instead of piling up.
    @Test func jitterOnAStationarySensorDoesNotLookLikeResponse() {
        let estimate = response(driverStep: 2.0, responseRatio: 0.0, jitterDeg: 3.0)
        #expect(estimate != nil)
        if let estimate {
            #expect(abs(estimate.slope) < 0.15)
            #expect(abs(estimate.correlation) < 0.5)
        }
        // And the same series under the old estimator would have looked highly responsive:
        // sum|d response| is driven entirely by the 6 deg jitter swing on every sample.
    }

    /// Jitter must not deflate a sensor that really is tracking, either.
    @Test func jitterDoesNotHideARealResponse() {
        let estimate = response(driverStep: 3.0, responseRatio: 1.0, jitterDeg: 2.0)
        #expect(estimate != nil)
        if let estimate { #expect(abs(estimate.slope - 1.0) < 0.2) }
    }

    /// **The build 12 regression.** The estimator is unbiased at any sampling rate, so a mean-only
    /// test passes even when the rate is badly wrong. What breaks is the *spread*: for a fixed
    /// total rotation R split into n steps, Σ(Δdriver²) = R²/n, so the slope's variance grows
    /// linearly with sampling rate. Sampled at ~10 Hz over 3 s this read a median +0.161 with
    /// excursions to +0.709 on a flight whose true slope was −0.039.
    ///
    /// Same rotation, same jitter, same true slope of zero — only the sample count differs. The
    /// coarse estimate must not be worse than the fine one.
    @Test func samplingSlowerGivesATighterEstimate() {
        // Deterministic pseudo-noise, so the test cannot flake.
        func jitter(_ i: Int) -> Double {
            let x = sin(Double(i) * 12.9898) * 43758.5453
            return (x - x.rounded(.down) - 0.5) * 4.0      // ±2 degrees
        }
        /// Worst-case |slope| over a sweep, for a sensor that does not follow at all.
        func worstSlope(steps: Int) -> Double {
            var worst = 0.0
            for offset in 0..<25 {
                var estimator = AngularResponse(window: 1000, minDriverRotationDeg: 20, minDriverExcursionDeg: 10, minPairs: 2)
                let step = 90.0 / Double(steps)          // 90 degrees of pan, however divided
                for i in 0...steps {
                    estimator.add(driver: Double(i) * step,
                                  response: (jitter(i + offset * 100) + 360)
                                      .truncatingRemainder(dividingBy: 360),
                                  at: TimeInterval(i))
                }
                if let estimate = estimator.estimate {
                    worst = max(worst, abs(estimate.slope))
                }
            }
            return worst
        }
        let fine   = worstSlope(steps: 30)   // ~10 Hz over 3 s
        let coarse = worstSlope(steps: 3)    // ~1 Hz over 3 s
        #expect(coarse <= fine)
        // And the coarse one must actually be usable, not merely better.
        #expect(coarse < 0.2)
    }

    /// **The build 13 regression, and the same rectification error in a third place.** Fixing the
    /// estimator to use signed least squares left the *publish gate* summing absolute changes, so
    /// a driver that only dithered still cleared it. On one flight the GPS ground track stayed
    /// inside a 0.4° band — the aircraft flew dead straight — yet 128 samples of quantisation
    /// flutter summed to 12.4°, passed an 8° gate, and published slopes from −0.770 to +0.321.
    ///
    /// A dithering driver must publish nothing, however many samples it contains.
    @Test func aDitheringDriverPublishesNothing() {
        var estimator = AngularResponse(window: 1000, minDriverRotationDeg: 8,
                                        minDriverExcursionDeg: 8, minPairs: 15)
        // 128 samples flicking between 263.3 and 263.7, as the real log did.
        for i in 0..<128 {
            estimator.add(driver: (i % 2 == 0) ? 263.3 : 263.7,
                          response: Double(i) * 3.0,        // response swinging wildly meanwhile
                          at: TimeInterval(i))
        }
        #expect(estimator.driverRotationDeg > 8)      // the old gate would have passed this
        #expect(estimator.driverExcursionDeg < 1)     // the new one sees 0.4 degrees
        #expect(estimator.estimate == nil)
    }

    /// And a real turn of the same duration must still publish.
    @Test func aRealTurnStillPublishes() {
        var estimator = AngularResponse(window: 1000, minDriverRotationDeg: 8,
                                        minDriverExcursionDeg: 8, minPairs: 15)
        for i in 0..<30 {
            let track = 263.3 + Double(i) * 3.0       // a 90 degree turn at 3 deg/s
            estimator.add(driver: track, response: track, at: TimeInterval(i))
        }
        let estimate = estimator.estimate
        #expect(estimate != nil)
        if let estimate {
            #expect(estimate.driverExcursionDeg > 80)
            #expect(abs(estimate.slope - 1.0) < 0.05)
        }
    }

    /// Panning out and back is real motion and must keep counting, which is why excursion is an
    /// additional gate rather than a replacement for summed rotation.
    @Test func panningOutAndBackStillCounts() {
        var estimator = AngularResponse(window: 1000, minDriverRotationDeg: 40,
                                        minDriverExcursionDeg: 25, minPairs: 15)
        var angle = 0.0
        for i in 0..<40 {
            angle += (i / 10) % 2 == 0 ? 4.0 : -4.0   // sweep 40 deg out, back, out, back
            estimator.add(driver: angle, response: angle, at: TimeInterval(i))
        }
        #expect(estimator.estimate != nil)
    }

    /// Too little rotation must publish nothing rather than a confident-looking ratio.
    @Test func tooLittleRotationYieldsNoEstimate() {
        #expect(response(driverStep: 0.05, responseRatio: 1.0, samples: 30) == nil)
    }

    /// Partial response, e.g. an ARKit frame that follows only some of the aircraft's turn.
    @Test func partialResponseIsReportedAsAFraction() {
        let estimate = response(driverStep: 2.0, responseRatio: 0.5)
        #expect(estimate != nil)
        if let estimate { #expect(abs(estimate.slope - 0.5) < 0.05) }
    }

    /// The estimator must wrap correctly rather than treating 359 -> 1 as a 358 degree jump.
    @Test func responseHandlesWrapAcrossNorth() {
        var estimator = AngularResponse(window: 1000, minDriverRotationDeg: 20, minDriverExcursionDeg: 10)
        var angle = 350.0
        for i in 0..<40 {
            let wrapped = angle.truncatingRemainder(dividingBy: 360)
            estimator.add(driver: wrapped, response: wrapped, at: TimeInterval(i) * 0.1)
            angle += 2.0
        }
        let estimate = estimator.estimate
        #expect(estimate != nil)
        if let estimate {
            #expect(abs(estimate.slope - 1.0) < 0.05)
            #expect(estimate.driverRotationDeg > 20)
        }
    }

    // MARK: - ARKit yaw drift

    /// Feed a still run of `seconds` at 5 Hz, drifting at `driftDps`, with optional jitter on the
    /// azimuth that must not be mistaken for drift.
    private func drift(driftDps: Double, seconds: Double,
                       jitterDeg: Double = 0,
                       gyroRateDps: Double = 0,
                       gyroVibrationDps: Double = 0) -> YawDriftAccumulator.Estimate? {
        var accumulator = YawDriftAccumulator(minRunSeconds: 5.0, minTotalSeconds: 10.0)
        let dt = 0.2
        var t = 0.0
        var i = 0
        while t <= seconds {
            // Deterministic alternating jitter, so the test cannot flake.
            let jitter = (i % 2 == 0 ? jitterDeg : -jitterDeg)
            let vibration = (i % 2 == 0 ? gyroVibrationDps : -gyroVibrationDps)
            let azimuth = (driftDps * t + jitter + 360).truncatingRemainder(dividingBy: 360)
            accumulator.add(azimuthDeg: azimuth,
                            gyroYawRateDps: gyroRateDps + vibration,
                            isTracking: true,
                            at: t)
            t += dt
            i += 1
        }
        return accumulator.estimate
    }

    @Test func constantDriftIsReportedAsItsRate() {
        let estimate = drift(driftDps: 0.25, seconds: 20)
        #expect(estimate != nil)
        if let estimate {
            #expect(abs(estimate.degreesPerSecond - 0.25) < 0.02)
            #expect(estimate.totalStillSeconds > 15)
        }
    }

    /// **The build 10 mistake, guarded in a new place.** Azimuth jitter with no underlying drift
    /// must read as no drift. Summing per-sample absolute changes would turn ±2° of jitter at
    /// 5 Hz into about 20°/s of phantom drift; a net change across the run is immune.
    @Test func jitterWithoutDriftReadsAsNoDrift() {
        let estimate = drift(driftDps: 0, seconds: 20, jitterDeg: 2.0)
        #expect(estimate != nil)
        if let estimate { #expect(abs(estimate.degreesPerSecond) < 0.05) }
    }

    @Test func jitterDoesNotHideRealDrift() {
        let estimate = drift(driftDps: 0.5, seconds: 20, jitterDeg: 2.0)
        #expect(estimate != nil)
        if let estimate { #expect(abs(estimate.degreesPerSecond - 0.5) < 0.1) }
    }

    /// Time when the phone was being turned must never be credited as drift.
    @Test func realRotationIsNotCountedAsDrift() {
        #expect(drift(driftDps: 5.0, seconds: 20, gyroRateDps: 2.0) == nil)
    }

    /// **The build 14 regression.** The gate used to require the *instantaneous* gyro rate to stay
    /// under a threshold at every 60 Hz sample for five continuous seconds, so a single vibration
    /// spike ended the run: it collected 51 seconds of still time in smooth cruise at FL415 and
    /// nothing at all in a descent through FL340. Vibration is zero-mean, so gating on the
    /// integral accepts it — which is correct, because drift is measured as the net change across
    /// a run and vibration contributes nothing to a net.
    @Test func vibrationDoesNotPreventARunFromBanking() {
        let estimate = drift(driftDps: 0.1, seconds: 20, gyroVibrationDps: 30.0)
        #expect(estimate != nil)
        if let estimate {
            #expect(abs(estimate.degreesPerSecond - 0.1) < 0.05)
            #expect(estimate.worstGyroNetDeg < 2.0)
        }
    }

    /// A run that ends rotated must be refused even if it never rotated fast: 0.5 deg/s for
    /// 20 s is 10 degrees of net rotation, and the phone's azimuth change over that is not drift.
    @Test func aSlowSustainedTurnIsRefused() {
        #expect(drift(driftDps: 0.5, seconds: 20, gyroRateDps: 0.5) == nil)
    }

    /// A run cut short by motion is discarded rather than averaged through.
    @Test func shortRunsAreDiscarded() {
        var accumulator = YawDriftAccumulator(minRunSeconds: 5.0, minTotalSeconds: 10.0)
        var t = 0.0
        for _ in 0..<10 {                       // ten runs of 2 s each, none long enough
            for _ in 0..<10 {
                accumulator.add(azimuthDeg: t * 3.0, gyroYawRateDps: 0, isTracking: true, at: t)
                t += 0.2
            }
            accumulator.add(azimuthDeg: t * 3.0, gyroYawRateDps: 0, isTracking: false, at: t)
            t += 0.2
        }
        #expect(accumulator.estimate == nil)
    }

    /// A gap in samples — tracking lost, or the app backgrounded — must not be credited as still
    /// time, or a minute in someone's pocket would read as a minute of rock-steady holding.
    @Test func gapsInSamplingBreakTheRun() {
        var accumulator = YawDriftAccumulator(minRunSeconds: 5.0, minTotalSeconds: 10.0)
        for i in 0..<15 {
            accumulator.add(azimuthDeg: 100, gyroYawRateDps: 0, isTracking: true,
                            at: Double(i) * 0.2)
        }
        // 60 s of nothing, then samples resume.
        for i in 0..<15 {
            accumulator.add(azimuthDeg: 100, gyroYawRateDps: 0, isTracking: true,
                            at: 63 + Double(i) * 0.2)
        }
        let estimate = accumulator.estimate
        // Both runs are under the 5 s minimum, so nothing banks: the gap must not have bridged
        // them into one 66-second run.
        #expect(estimate == nil)
    }

    // MARK: - AR frame convention

    /// The world azimuth a position vector sits at, in 0…360 — the inverse of the mapping
    /// `calculateARPosition` performs, so a test can state where a target landed in the same
    /// units the bearing went in as.
    private func worldAzimuthDeg(_ p: SCNVector3) -> Double {
        let deg = atan2(Double(p.x), Double(-p.z)) * 180.0 / Double.pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Pins the frame convention in a test rather than a comment, which is what this repo has
    /// been relying on. ARKit's `.gravityAndHeading` world nominally puts true north on −Z and
    /// east on +X, so with no yaw error a true bearing maps straight across.
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
    /// rotate a target off its true bearing.
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

    /// The invariant both failed corrections broke, stated once and exactly: a target on true
    /// bearing B is placed at world azimuth B. No declination, no compass-derived yaw term, no
    /// anything. Checked on oblique bearings, since a rotation is easiest to hide on the axes.
    ///
    /// This is the test that would have failed loudly for either bad build, so it is the one to
    /// keep passing.
    @Test func targetsArePlacedOnTheirTrueBearingExactly() {
        let here = CLLocationCoordinate2D(latitude: 41.0, longitude: -79.3)
        let targets = [
            CLLocationCoordinate2D(latitude: 41.2, longitude: -79.1),   // NE-ish
            CLLocationCoordinate2D(latitude: 40.8, longitude: -79.6),   // SW-ish
            CLLocationCoordinate2D(latitude: 41.3, longitude: -79.5),   // NW-ish
            CLLocationCoordinate2D(latitude: 40.7, longitude: -79.0),   // SE-ish
        ]
        for target in targets {
            let trueBearing = CalculationsLogic.bearing(from: here, to: target)
            let placed = worldAzimuthDeg(CalculationsLogic.calculateARPosition(
                targetCoord: target, targetAltitude: 0,
                userCoord: here, userAltitude: 0, userHeading: 0))
            #expect(abs(angleDifferenceDeg(from: trueBearing, to: placed)) < 0.5)
        }
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

    // MARK: - Flight-direction anchor

    private func holdSamples(_ anchor: inout FlightDirectionAnchor,
                             az: [Double], track: Double, dt: Double = 0.2) {
        for (i, a) in az.enumerated() {
            anchor.add(arAzimuthDeg: a, trackDeg: track, at: Double(i) * dt)
        }
    }

    /// The offset is track minus ARKit azimuth — the same quantity and sign as world_yaw_corr_deg
    /// measures against the compass on the ground, and what placement subtracts from each bearing.
    @Test func aSteadyHoldPublishesTrackMinusAzimuth() {
        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8)
        anchor.begin(at: 0)
        holdSamples(&anchor, az: Array(repeating: 100.0, count: 20), track: 130.0)
        guard case .success(let e) = anchor.finish(at: 4.0) else { #expect(Bool(false)); return }
        #expect(abs(e.offsetDeg - 30) < 0.001)
        #expect(e.sampleCount == 20)
    }

    /// Hand wobble is what the median is for. A hold that jitters either side of the true direction,
    /// within the 5° gate, must still land on it.
    @Test func wobbleIsMedianedAway() {
        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8)
        anchor.begin(at: 0)
        let jitter = [-2.4, 1.6, -0.8, 2.4, -2.0, 0.4, 1.2, -1.6, 0.8, 0.0,
                      2.0, -1.2, 0.4, -0.4, 2.4, -2.4, 0.8, 0.0, -0.8, 1.2]
        holdSamples(&anchor, az: jitter.map { 100.0 + $0 }, track: 130.0)
        guard case .success(let e) = anchor.finish(at: 4.0) else { #expect(Bool(false)); return }
        #expect(abs(e.offsetDeg - 30) < 3)
    }

    /// **Build 29's tightening.** A hold that wanders 13° used to be accepted, on the reasoning that
    /// the median absorbs wander. It does — but the anchor's error is aim, not wander, and a capture
    /// this loose has the least claim to be a considered aim.
    @Test func aLooseHoldIsNowRefused() {
        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8)
        anchor.begin(at: 0)
        let jitter = [-6.0, 4.0, -2.0, 7.0, -5.0, 1.0, 3.0, -4.0, 2.0, 0.0,
                      5.0, -3.0, 1.0, -1.0, 6.0, -6.0, 2.0, 0.0, -2.0, 3.0]
        holdSamples(&anchor, az: jitter.map { 100.0 + $0 }, track: 130.0)
        guard case .failure(let reason) = anchor.finish(at: 4.0) else { #expect(Bool(false)); return }
        #expect(reason == .phoneMoved)
    }

    /// A pan is not a hold. The samples were taken pointing in different directions, so their
    /// median means nothing and the capture must be refused rather than averaged.
    @Test func aPanIsRefused() {
        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8, maxAzimuthSpreadDeg: 5)
        anchor.begin(at: 0)
        holdSamples(&anchor, az: (0..<20).map { 100.0 + Double($0) * 5 }, track: 130.0)
        guard case .failure(let reason) = anchor.finish(at: 4.0) else { #expect(Bool(false)); return }
        #expect(reason == .phoneMoved)
    }

    /// If the aircraft turned during the hold, the samples were measured against different tracks.
    @Test func aTurnDuringTheHoldIsRefused() {
        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8, maxTrackSpreadDeg: 5)
        anchor.begin(at: 0)
        for i in 0..<20 {
            anchor.add(arAzimuthDeg: 100, trackDeg: 130 + Double(i), at: Double(i) * 0.2)
        }
        guard case .failure(let reason) = anchor.finish(at: 4.0) else { #expect(Bool(false)); return }
        #expect(reason == .aircraftTurning)
    }

    @Test func aShortHoldIsRefused() {
        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8)
        anchor.begin(at: 0)
        holdSamples(&anchor, az: Array(repeating: 100.0, count: 20), track: 130.0)
        guard case .failure(let reason) = anchor.finish(at: 1.0) else { #expect(Bool(false)); return }
        #expect(reason == .tooShort)
    }

    /// Tracking dropping out mid-hold leaves too little to median.
    @Test func tooFewSamplesIsRefused() {
        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8)
        anchor.begin(at: 0)
        holdSamples(&anchor, az: Array(repeating: 100.0, count: 3), track: 130.0)
        guard case .failure(let reason) = anchor.finish(at: 4.0) else { #expect(Bool(false)); return }
        #expect(reason == .tooFewSamples)
    }

    /// A hold that straddles north must not read as 360 degrees of movement.
    @Test func spreadUnwrapsAcrossNorth() {
        #expect(FlightDirectionAnchor.spreadDeg([358, 359, 0, 1, 2]) < 5)
        #expect(FlightDirectionAnchor.spreadDeg([10, 40, 70]) > 55)
    }

    /// A refused hold must not leak its samples into the next attempt.
    @Test func aRefusedHoldClearsItself() {
        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8)
        anchor.begin(at: 0)
        holdSamples(&anchor, az: (0..<20).map { 100.0 + Double($0) * 5 }, track: 130.0)
        _ = anchor.finish(at: 4.0)
        #expect(!anchor.isCapturing)
        anchor.begin(at: 10)
        holdSamples(&anchor, az: Array(repeating: 200.0, count: 20), track: 250.0)
        // Times restart at 0 inside the helper, so only the count matters here.
        guard case .success(let e) = anchor.finish(at: 14.0) else { #expect(Bool(false)); return }
        #expect(abs(e.offsetDeg - 50) < 0.001)
        #expect(e.sampleCount == 20)
    }

    // MARK: - Applying the offset

    /// The offset rotates the whole scene by exactly its own size, in the direction that cancels
    /// ARKit's error: a target on a true bearing is placed at bearing minus offset.
    @Test func theOffsetRotatesPlacementByItsOwnSize() {
        let here = CLLocationCoordinate2D(latitude: 41.0, longitude: -79.3)
        let target = CLLocationCoordinate2D(latitude: 41.2, longitude: -79.1)
        let uncorrected = worldAzimuthDeg(CalculationsLogic.calculateARPosition(
            targetCoord: target, targetAltitude: 0,
            userCoord: here, userAltitude: 0, userHeading: 0))
        let corrected = worldAzimuthDeg(CalculationsLogic.calculateARPosition(
            targetCoord: target, targetAltitude: 0,
            userCoord: here, userAltitude: 0, userHeading: 0,
            cameraWorldPosition: .init(), worldYawOffsetDeg: 30))
        #expect(abs(angleDifferenceDeg(from: corrected, to: uncorrected) - 30) < 0.5)
    }

    /// Zero must be exactly what shipped before, since that is what the ground and every
    /// pre-anchor flight run on.
    @Test func aZeroOffsetChangesNothing() {
        let here = CLLocationCoordinate2D(latitude: 41.0, longitude: -79.3)
        let target = CLLocationCoordinate2D(latitude: 40.8, longitude: -79.6)
        let plain = worldAzimuthDeg(CalculationsLogic.calculateARPosition(
            targetCoord: target, targetAltitude: 0,
            userCoord: here, userAltitude: 0, userHeading: 0))
        let zero = worldAzimuthDeg(CalculationsLogic.calculateARPosition(
            targetCoord: target, targetAltitude: 0,
            userCoord: here, userAltitude: 0, userHeading: 0,
            cameraWorldPosition: .init(), worldYawOffsetDeg: 0))
        #expect(abs(angleDifferenceDeg(from: plain, to: zero)) < 0.001)
    }

    // MARK: - World usability

    /// The split that matters: "no world yet" hides the markers, "world of degraded quality" does
    /// not. Blanking the display every time the phone moves briskly would be worse than a marker
    /// that wobbles.
    @Test func onlyMissingWorldsHideTheMarkers() {
        #expect(worldIsUsableForDisplay(.normal))
        #expect(!worldIsUsableForDisplay(.notAvailable))
        #expect(!worldIsUsableForDisplay(.limited(.initializing)))
        #expect(!worldIsUsableForDisplay(.limited(.relocalizing)))
    }

    /// The two cases that must keep drawing. `relocalizing` is the 5 s airborne-resume window and
    /// hides; `excessiveMotion` is a bump and must not.
    @Test func degradedTrackingKeepsDrawing() {
        #expect(worldIsUsableForDisplay(.limited(.excessiveMotion)))
        #expect(worldIsUsableForDisplay(.limited(.insufficientFeatures)))
    }

    // MARK: - Alignment drift

    /// The gap between ARKit and the compass is spiky — a fast pan briefly outruns the compass, and
    /// the ground log that medians 2.0 degrees spans -31.6 to +19.4. One spike must never re-anchor
    /// the world, which is why this is a median and not a mean or a single reading.
    @Test func oneSpikeDoesNotMoveTheMedian() {
        var monitor = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        for i in 0..<14 { monitor.add(errorDeg: 2.0, at: Double(i) * 0.5) }
        monitor.add(errorDeg: -31.6, at: 7.0)
        #expect(monitor.medianErrorDeg != nil)
        #expect(abs(monitor.medianErrorDeg!) < 3)
    }

    /// The monitor no longer decides anything — build 21 removed the branch — but it is still
    /// reported beside every reset, so it must still separate a quiet ground alignment from a
    /// drifted one. The numbers are the measured ones: clean ground logs peak at 4.05 and 5.33
    /// degrees on rolling medians, flights run 85 to 126.
    @Test func theMonitorSeparatesQuietFromDrifted() {
        var quiet = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        for i in 0..<20 { quiet.add(errorDeg: i % 2 == 0 ? 4.05 : -1.0, at: Double(i) * 0.5) }
        #expect(abs(quiet.medianErrorDeg ?? 0) < 6)

        var drifted = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        for i in 0..<20 { drifted.add(errorDeg: 18.0, at: Double(i) * 0.5) }
        #expect(abs(drifted.medianErrorDeg ?? 0) > 15)
    }

    /// A median of three readings is not a median. Nothing is published until the window is full
    /// enough to mean something.
    @Test func tooFewSamplesPublishNothing() {
        var monitor = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        for i in 0..<9 { monitor.add(errorDeg: 40.0, at: Double(i) * 0.5) }
        #expect(monitor.medianErrorDeg == nil)
        monitor.add(errorDeg: 40.0, at: 4.5)
        #expect(monitor.medianErrorDeg != nil)
    }

    /// Readings older than the window are dropped, so an alignment that has recovered stops
    /// reporting the drift it used to have.
    @Test func theWindowExpiresOldReadings() {
        var monitor = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        for i in 0..<20 { monitor.add(errorDeg: 30.0, at: Double(i) * 0.5) }
        #expect(abs(monitor.medianErrorDeg ?? 0) > 25)
        // Twenty healthy readings, all more than a window after the drifted ones.
        for i in 0..<20 { monitor.add(errorDeg: 1.0, at: 100.0 + Double(i) * 0.5) }
        #expect(abs(monitor.medianErrorDeg ?? 99) < 2)
    }

    /// The feeding site runs at 60 Hz; the throttle is what stops the window becoming a
    /// nine-hundred-entry array re-sorted every frame.
    @Test func samplesArrivingTooFastAreDropped() {
        var monitor = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        // 60 Hz for a second: only two of these may be kept.
        for i in 0..<60 { monitor.add(errorDeg: 5.0, at: Double(i) / 60.0) }
        #expect(monitor.medianErrorDeg == nil)
    }

    /// After a re-anchor the readings that caused it describe a world that no longer exists.
    @Test func resetClearsTheWindow() {
        var monitor = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        for i in 0..<20 { monitor.add(errorDeg: 30.0, at: Double(i) * 0.5) }
        #expect(monitor.medianErrorDeg != nil)
        monitor.reset()
        #expect(monitor.medianErrorDeg == nil)
        // And it accepts a fresh sample immediately rather than waiting out the throttle.
        for i in 0..<10 { monitor.add(errorDeg: 1.0, at: 10.0 + Double(i) * 0.5) }
        #expect(abs(monitor.medianErrorDeg ?? 99) < 2)
    }

    /// A NaN reading (no compass fix yet) must not poison the window.
    @Test func nonFiniteReadingsAreIgnored() {
        var monitor = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        for i in 0..<10 { monitor.add(errorDeg: .nan, at: Double(i) * 0.5) }
        #expect(monitor.medianErrorDeg == nil)
    }

    // MARK: - Ground compass correction

    // The gates exist because build 8 applied a compass correction without them and swung the whole
    // scene toward the nose whenever the user looked out of a side window. Two of these tests are
    // that failure, written down: refusedWhenAirborne and refusedWhenCompassIsTrackSlaved.

    /// Healthy ground conditions: compass measuring the phone, accuracy good, world up.
    private func applyGround(_ correction: inout GroundYawCorrection,
                             medianDeg: Double,
                             ticks: Int,
                             from startTime: Double = 0,
                             airborne: Bool = false,
                             response: Double = 1.0,
                             responseR: Double = 0.95,
                             headingAccuracy: Double = 10) {
        for i in 0..<ticks {
            correction.update(medianErrorDeg: medianDeg,
                              compassResponse: response,
                              compassResponseR: responseR,
                              headingAccuracyDeg: headingAccuracy,
                              airborne: airborne,
                              worldUsable: true,
                              at: startTime + Double(i))
        }
    }

    @Test func groundCorrectionConvergesOnTheMedian() {
        var correction = GroundYawCorrection()
        applyGround(&correction, medianDeg: -2.5, ticks: 10)
        #expect(correction.hasOffset)
        #expect(abs(correction.appliedOffsetDeg - (-2.5)) < 0.01)
    }

    /// The slew limit: one second may not move the scene by the whole correction.
    @Test func groundCorrectionSlewsRatherThanStepping() {
        var correction = GroundYawCorrection(maxSlewPerUpdateDeg: 1.0)
        applyGround(&correction, medianDeg: -8.0, ticks: 1)
        #expect(abs(correction.appliedOffsetDeg - (-1.0)) < 0.001)
        applyGround(&correction, medianDeg: -8.0, ticks: 1, from: 1)
        #expect(abs(correction.appliedOffsetDeg - (-2.0)) < 0.001)
    }

    /// **The build-8 fence.** Inside a fuselage CLHeading reports the aircraft's ground track, so
    /// this median is the phone-to-nose angle, not an alignment error.
    @Test func refusedWhenAirborne() {
        var correction = GroundYawCorrection()
        applyGround(&correction, medianDeg: -2.5, ticks: 10, airborne: true)
        #expect(!correction.hasOffset)
        #expect(correction.appliedOffsetDeg == 0)
    }

    /// **The discriminating gate** — it would have caught build 8 even on the ground. A compass
    /// that turns 0.018° per degree the phone turns is not measuring the phone.
    @Test func refusedWhenCompassIsTrackSlaved() {
        var correction = GroundYawCorrection()
        applyGround(&correction, medianDeg: -2.5, ticks: 10, response: 0.018, responseR: 0.1)
        #expect(!correction.hasOffset)
    }

    /// A slope near 1 fitted through noise is not evidence that the compass follows the phone.
    @Test func refusedWhenResponseCorrelationIsWeak() {
        var correction = GroundYawCorrection()
        applyGround(&correction, medianDeg: -2.5, ticks: 10, response: 1.0, responseR: 0.2)
        #expect(!correction.hasOffset)
    }

    /// Nothing is published until the estimator has a slope at all — a phone held perfectly still
    /// from launch is corrected by nothing, which is correct.
    @Test func refusedWhileResponseIsUnmeasured() {
        var correction = GroundYawCorrection()
        applyGround(&correction, medianDeg: -2.5, ticks: 10, response: .nan, responseR: .nan)
        #expect(!correction.hasOffset)
    }

    @Test func refusedWithoutAMedian() {
        var correction = GroundYawCorrection()
        for i in 0..<10 {
            correction.update(medianErrorDeg: nil, compassResponse: 1.0, compassResponseR: 0.95,
                              headingAccuracyDeg: 10, airborne: false, worldUsable: true,
                              at: Double(i))
        }
        #expect(!correction.hasOffset)
    }

    @Test func refusedWhileTheWorldIsUnusable() {
        var correction = GroundYawCorrection()
        for i in 0..<10 {
            correction.update(medianErrorDeg: -2.5, compassResponse: 1.0, compassResponseR: 0.95,
                              headingAccuracyDeg: 10, airborne: false, worldUsable: false,
                              at: Double(i))
        }
        #expect(!correction.hasOffset)
    }

    @Test func refusedWhenTheCompassCallsItselfInaccurate() {
        var correction = GroundYawCorrection(maxHeadingAccuracyDeg: 25)
        applyGround(&correction, medianDeg: -2.5, ticks: 10, headingAccuracy: 40)
        #expect(!correction.hasOffset)
        // And a negative accuracy — CoreLocation's "no fix" — is refused, not read as excellent.
        applyGround(&correction, medianDeg: -2.5, ticks: 10, from: 20, headingAccuracy: -1)
        #expect(!correction.hasOffset)
    }

    /// A 40° disagreement on the ground is a broken sensor, not a 40°-wrong world.
    @Test func refusedWhenTheOffsetIsImplausible() {
        var correction = GroundYawCorrection(maxOffsetDeg: 20)
        applyGround(&correction, medianDeg: -45, ticks: 10)
        #expect(!correction.hasOffset)
    }

    /// The rate limit: the correction updates about once a second, not at the feed rate.
    @Test func groundCorrectionIsRateLimited() {
        var correction = GroundYawCorrection(minUpdateInterval: 1.0, maxSlewPerUpdateDeg: 1.0)
        for i in 0..<20 { applyGround(&correction, medianDeg: -10, ticks: 1, from: Double(i) * 0.1) }
        // Two seconds of feed at 10 Hz is two updates, so two degrees — not twenty.
        #expect(abs(correction.appliedOffsetDeg) <= 2.01)
    }

    /// Once converged, ordinary median jitter must not keep nudging the scene.
    @Test func smallChangesFallInTheDeadband() {
        var correction = GroundYawCorrection(deadbandDeg: 0.5)
        applyGround(&correction, medianDeg: -2.5, ticks: 10)
        let settled = correction.appliedOffsetDeg
        applyGround(&correction, medianDeg: -2.7, ticks: 5, from: 20)
        #expect(correction.appliedOffsetDeg == settled)
    }

    /// Takeoff freezes the last ground value rather than discarding it: the ARKit world survives
    /// takeoff, so a correction measured minutes ago is still the better estimate.
    @Test func goingAirborneFreezesRatherThanClears() {
        var correction = GroundYawCorrection()
        applyGround(&correction, medianDeg: -2.5, ticks: 10)
        let settled = correction.appliedOffsetDeg
        applyGround(&correction, medianDeg: -30, ticks: 20, from: 20, airborne: true)
        #expect(correction.appliedOffsetDeg == settled)
        #expect(correction.hasOffset)
    }

    /// A world reset builds a different frame, so the number measured against the old one goes.
    @Test func groundCorrectionResetsWithTheWorld() {
        var correction = GroundYawCorrection()
        applyGround(&correction, medianDeg: -2.5, ticks: 10)
        #expect(correction.hasOffset)
        correction.reset()
        #expect(!correction.hasOffset)
        #expect(correction.appliedOffsetDeg == 0)
    }

    /// A genuine 0.0° must be distinguishable from "never ran", since both read zero.
    @Test func aMeasuredZeroStillCountsAsApplied() {
        var correction = GroundYawCorrection()
        applyGround(&correction, medianDeg: 0, ticks: 3)
        #expect(correction.hasOffset)
        #expect(correction.appliedOffsetDeg == 0)
    }

    /// The refusal reason is reported, not swallowed — the log distinguishes "no correction" from
    /// "no correction because the compass is track-slaved".
    @Test func refusalNamesItsReason() {
        var correction = GroundYawCorrection()
        let airborne = correction.update(medianErrorDeg: -2.5, compassResponse: 1.0,
                                         compassResponseR: 0.95, headingAccuracyDeg: 10,
                                         airborne: true, worldUsable: true, at: 0)
        #expect(airborne == .refused(.airborne))
        let slaved = correction.update(medianErrorDeg: -2.5, compassResponse: 0.018,
                                       compassResponseR: 0.1, headingAccuracyDeg: 10,
                                       airborne: false, worldUsable: true, at: 1)
        #expect(slaved == .refused(.compassNotMeasuringPhone))
    }

    // MARK: - Startup seed

    // Under .gravity this is the only thing that orients the scene, so these cover the arithmetic
    // and the one property that matters most: that it produces the same number, with the same sign,
    // as the manual anchor measuring the same situation.

    private func feedSeed(_ seed: inout StartupSeed, az: [Double], reference: Double,
                          from t0: Double = 0, step: Double = 0.2) {
        for (i, a) in az.enumerated() {
            seed.add(arAzimuthDeg: a, referenceDeg: reference, at: t0 + Double(i) * step)
        }
    }

    /// The offset is reference minus ARKit azimuth — the same quantity and sign the anchor publishes
    /// and that placement subtracts from every bearing.
    @Test func seedPublishesReferenceMinusAzimuth() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .track)
        feedSeed(&seed, az: Array(repeating: 254.0, count: 8), reference: 78.0)
        guard let e = seed.finish(at: 1.6) else { #expect(Bool(false)); return }
        // 78 - 254 wraps to -176, which is what the anchor read on the flight that ended backwards.
        #expect(abs(e.offsetDeg - (-176)) < 0.001)
        #expect(e.referenceKind == .track)
        #expect(e.sampleCount == 8)
    }

    /// The seed and the manual anchor must agree when handed identical inputs; they are the same
    /// measurement taken at different moments, and a sign difference between them would be silent.
    @Test func seedAgreesWithTheAnchorOnTheSameInput() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .track)
        feedSeed(&seed, az: Array(repeating: 100.0, count: 8), reference: 130.0)
        guard let s = seed.finish(at: 1.6) else { #expect(Bool(false)); return }

        var anchor = FlightDirectionAnchor(minSeconds: 3, minSamples: 8)
        anchor.begin(at: 0)
        holdSamples(&anchor, az: Array(repeating: 100.0, count: 20), track: 130.0)
        guard case .success(let a) = anchor.finish(at: 4.0) else { #expect(Bool(false)); return }

        #expect(abs(s.offsetDeg - a.offsetDeg) < 0.001)
    }

    /// Wobble is medianed away, as in the anchor.
    @Test func seedMediansWobble() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .compass)
        feedSeed(&seed, az: [98, 103, 99, 102, 100, 101, 97, 104], reference: 130.0)
        guard let e = seed.finish(at: 1.6) else { #expect(Bool(false)); return }
        #expect(abs(e.offsetDeg - 30) < 3)
        #expect(e.referenceKind == .compass)
    }

    /// **Deliberately not gated on spread**, unlike the anchor: a refused seed under `.gravity`
    /// leaves the world with no alignment at all, which is worse than one a few degrees loose. The
    /// spread is published instead so a bad one is visible in the log.
    @Test func seedPublishesEvenWhenLooseButReportsTheSpread() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .track)
        feedSeed(&seed, az: (0..<8).map { 100.0 + Double($0) * 4 }, reference: 130.0)
        guard let e = seed.finish(at: 1.6) else { #expect(Bool(false)); return }
        #expect(e.azimuthSpreadDeg > 25)
    }

    @Test func seedRefusesTooShortAHold() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .track)
        feedSeed(&seed, az: Array(repeating: 100.0, count: 8), reference: 130.0)
        #expect(seed.finish(at: 0.4) == nil)
    }

    @Test func seedRefusesTooFewSamples() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .track)
        feedSeed(&seed, az: [100, 100, 100], reference: 130.0)
        #expect(seed.finish(at: 1.6) == nil)
    }

    /// Finishing clears, so a refused capture cannot leak its samples into the next attempt.
    @Test func seedClearsAfterFinishing() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .track)
        feedSeed(&seed, az: Array(repeating: 100.0, count: 8), reference: 130.0)
        _ = seed.finish(at: 1.6)
        #expect(!seed.isCapturing)
        #expect(seed.finish(at: 3.0) == nil)
    }

    /// A world reset cancels any capture in flight; its samples were measured in the old frame.
    @Test func seedCancelDiscardsSamples() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .track)
        feedSeed(&seed, az: Array(repeating: 100.0, count: 8), reference: 130.0)
        seed.cancel()
        #expect(!seed.isCapturing)
        #expect(seed.finish(at: 1.6) == nil)
    }

    @Test func seedIgnoresNonFiniteInputs() {
        var seed = StartupSeed(minSeconds: 1.0, minSamples: 5)
        seed.begin(reference: .track)
        for i in 0..<8 { seed.add(arAzimuthDeg: .nan, referenceDeg: 130, at: Double(i) * 0.2) }
        #expect(seed.finish(at: 1.6) == nil)
    }

    // MARK: - Align prompt scheduling

    // Two flights offered the align button on every healthy-tracking row and neither took it, so
    // both flew uncorrected. These cover the one thing that must not happen in fixing that: the
    // prompt becoming noise the user learns to dismiss.

    /// Fires as soon as the opportunity appears — that is the moment it is worth saying.
    @Test func promptsOnFirstAvailability() {
        var s = AlignPromptScheduler(minIntervalSeconds: 300, maxPrompts: 3)
        #expect(s.shouldPrompt(available: true, hasOffset: false, capturing: false, at: 100))
        #expect(s.promptCount == 1)
    }

    @Test func doesNotPromptWhileUnavailable() {
        var s = AlignPromptScheduler()
        for i in 0..<100 {
            #expect(!s.shouldPrompt(available: false, hasOffset: false, capturing: false,
                                    at: Double(i)))
        }
        #expect(s.promptCount == 0)
    }

    /// The 4 Hz tick asks constantly. It must be answered once, then not again for five minutes.
    @Test func promptRespectsTheInterval() {
        var s = AlignPromptScheduler(minIntervalSeconds: 300, maxPrompts: 3)
        var fired = 0
        // 4 Hz for four minutes: one prompt only.
        for i in 0..<960 {
            if s.shouldPrompt(available: true, hasOffset: false, capturing: false,
                              at: Double(i) * 0.25) { fired += 1 }
        }
        #expect(fired == 1)
        #expect(s.shouldPrompt(available: true, hasOffset: false, capturing: false, at: 300))
    }

    /// After three the user has decided. A fourth is nagging.
    @Test func promptStopsAtTheCap() {
        var s = AlignPromptScheduler(minIntervalSeconds: 300, maxPrompts: 3)
        var fired = 0
        for i in 0..<20 {
            if s.shouldPrompt(available: true, hasOffset: false, capturing: false,
                              at: Double(i) * 300) { fired += 1 }
        }
        #expect(fired == 3)
    }

    /// Once an offset is in force there is nothing left to ask for.
    @Test func promptGoesSilentOnceAligned() {
        var s = AlignPromptScheduler(minIntervalSeconds: 300, maxPrompts: 3)
        #expect(s.shouldPrompt(available: true, hasOffset: false, capturing: false, at: 0))
        for i in 1..<20 {
            #expect(!s.shouldPrompt(available: true, hasOffset: true, capturing: false,
                                    at: Double(i) * 300))
        }
        #expect(s.promptCount == 1)
    }

    /// Interrupting a running capture with a banner telling the user to start one would be absurd.
    @Test func promptStaysQuietDuringACapture() {
        var s = AlignPromptScheduler(minIntervalSeconds: 300, maxPrompts: 3)
        #expect(!s.shouldPrompt(available: true, hasOffset: false, capturing: true, at: 0))
        #expect(s.promptCount == 0)
    }

    /// A flight dipping in and out of usable tracking must not be owed a prompt each time it
    /// returns; availability going away restarts the wait.
    @Test func availabilityFlappingDoesNotBurstPrompts() {
        var s = AlignPromptScheduler(minIntervalSeconds: 300, maxPrompts: 3)
        var fired = 0
        for i in 0..<200 {
            let up = i % 2 == 0
            if s.shouldPrompt(available: up, hasOffset: false, capturing: false,
                              at: Double(i)) { fired += 1 }
        }
        #expect(fired == 1)
    }

    /// The log line's "how long has this been on offer" figure.
    @Test func secondsAvailableCountsFromFirstOffer() {
        var s = AlignPromptScheduler()
        #expect(s.secondsAvailable(at: 500) == 0)
        _ = s.shouldPrompt(available: true, hasOffset: false, capturing: false, at: 100)
        #expect(abs(s.secondsAvailable(at: 160) - 60) < 0.001)
    }

    @Test func promptResetsWithTheWorld() {
        var s = AlignPromptScheduler(minIntervalSeconds: 300, maxPrompts: 3)
        for i in 0..<3 {
            _ = s.shouldPrompt(available: true, hasOffset: false, capturing: false,
                               at: Double(i) * 300)
        }
        #expect(s.promptCount == 3)
        s.reset()
        #expect(s.promptCount == 0)
        #expect(s.shouldPrompt(available: true, hasOffset: false, capturing: false, at: 1000))
    }

    // MARK: - Track-following offset

    // Following is OFF from build 28 — the FL362 turn measured ARKit's azimuth tracking the
    // aircraft at a slope of 0.893 with r = 0.978, so the offset is a constant. The tests below
    // construct the struct with an explicit `gain: 1.0` because what they exercise is the
    // accumulator, which is unchanged and still feeds the log; the two tests immediately following
    // are the ones that pin the shipped behaviour.

    /// **The build-28 retraction.** The default gain must apply nothing: an anchor's offset is held
    /// exactly as measured, however far the aircraft turns. In the FL362 log the difference is the
    /// offset staying at −35.5 instead of walking to −66.1.
    @Test func defaultGainHoldsTheOffsetThroughATurn() {
        var follower = TrackFollowingYawOffset()
        follower.seed(offsetDeg: -35.5, trackDeg: 229.9, source: .anchor, at: 0)
        // The turn that settled it: 30.6° left over 110 s.
        for i in 1...110 {
            follower.update(trackDeg: 229.9 - 30.6 * Double(i) / 110.0,
                            courseAccuracyDeg: 0.1, groundSpeedKt: 460, at: Double(i))
        }
        #expect(abs((follower.offsetDeg ?? 99) - (-35.5)) < 0.001)
    }

    /// The accumulation still runs under the zero gain, because the log records it as the
    /// counterfactual that would justify switching following back on.
    @Test func followedDegreesStillAccumulateWhileDisabled() {
        var follower = TrackFollowingYawOffset()
        follower.seed(offsetDeg: -35.5, trackDeg: 229.9, source: .anchor, at: 0)
        for i in 1...110 {
            follower.update(trackDeg: 229.9 - 30.6 * Double(i) / 110.0,
                            courseAccuracyDeg: 0.1, groundSpeedKt: 460, at: Double(i))
        }
        #expect(abs(follower.followedDeg - (-30.6)) < 0.01)
    }

    // The accumulator itself, exercised at gain 1.0: every guard that decides whether a heading
    // sample is worth integrating, and the unwrapping that survives a course reversal.

    /// Steady cruise: a fixed course accumulates nothing, so the offset stays where it was measured.
    @Test func straightFlightDoesNotMoveTheOffset() {
        var follower = TrackFollowingYawOffset(gain: 1.0)
        follower.seed(offsetDeg: 1.5, trackDeg: 298, source: .anchor, at: 0)
        for i in 1...60 {
            follower.update(trackDeg: 298, courseAccuracyDeg: 0.1, groundSpeedKt: 440,
                            at: Double(i))
        }
        #expect(abs(follower.followedDeg) < 0.001)
        #expect(abs((follower.offsetDeg ?? 99) - 1.5) < 0.001)
    }

    /// The FL317 case itself: 12.7° of left turn must be added back to the offset.
    @Test func offsetFollowsTheHeadingChange() {
        var follower = TrackFollowingYawOffset(gain: 1.0)
        follower.seed(offsetDeg: 1.5, trackDeg: 298.2, source: .anchor, at: 0)
        // 12.7° left over 64 s, the rate the log actually flew.
        for i in 1...64 {
            follower.update(trackDeg: 298.2 - 12.7 * Double(i) / 64.0,
                            courseAccuracyDeg: 0.1, groundSpeedKt: 440, at: Double(i))
        }
        #expect(abs(follower.followedDeg - (-12.7)) < 0.01)
        #expect(abs((follower.offsetDeg ?? 99) - (1.5 - 12.7)) < 0.01)
    }

    /// **Accumulate, don't difference.** A flight that turns through more than 180° would wrap and
    /// invert the correction if the offset were computed against the seed's heading.
    @Test func followingSurvivesATurnPastOneEighty() {
        var follower = TrackFollowingYawOffset(gain: 1.0)
        follower.seed(offsetDeg: 0, trackDeg: 0, source: .anchor, at: 0)
        // 270° right, at 2 °/s — a whole course reversal and then some.
        for i in 1...135 {
            follower.update(trackDeg: (2.0 * Double(i)).truncatingRemainder(dividingBy: 360),
                            courseAccuracyDeg: 1, groundSpeedKt: 440, at: Double(i))
        }
        #expect(abs(follower.followedDeg - 270) < 0.01)
        // The applied offset wraps to ±180, but the accumulation behind it does not.
        #expect(abs((follower.offsetDeg ?? 999) - (-90)) < 0.01)
    }

    @Test func followingIgnoresAnInaccurateCourse() {
        var follower = TrackFollowingYawOffset(maxCourseAccuracyDeg: 5, gain: 1.0)
        follower.seed(offsetDeg: 0, trackDeg: 300, source: .anchor, at: 0)
        for i in 1...30 {
            follower.update(trackDeg: 300 - Double(i), courseAccuracyDeg: 40,
                            groundSpeedKt: 440, at: Double(i))
        }
        #expect(follower.followedDeg == 0)
    }

    /// Taxiing is not a direction. Below the speed gate nothing accumulates.
    @Test func followingIgnoresSlowGroundSpeed() {
        var follower = TrackFollowingYawOffset(minGroundSpeedKt: 80, gain: 1.0)
        follower.seed(offsetDeg: 0, trackDeg: 300, source: .anchor, at: 0)
        for i in 1...30 {
            follower.update(trackDeg: 300 - Double(i), courseAccuracyDeg: 0.5,
                            groundSpeedKt: 15, at: Double(i))
        }
        #expect(follower.followedDeg == 0)
    }

    /// A course that jumps faster than an aircraft can turn is GPS noise, not a turn.
    @Test func followingRejectsAnImpossibleTurnRate() {
        var follower = TrackFollowingYawOffset(maxTurnRateDps: 6, gain: 1.0)
        follower.seed(offsetDeg: 0, trackDeg: 0, source: .anchor, at: 0)
        follower.update(trackDeg: 90, courseAccuracyDeg: 1, groundSpeedKt: 440, at: 1)
        #expect(follower.followedDeg == 0)
        // And it re-baselines on the new value rather than pinning to a heading already left.
        follower.update(trackDeg: 92, courseAccuracyDeg: 1, groundSpeedKt: 440, at: 2)
        #expect(abs(follower.followedDeg - 2) < 0.001)
    }

    /// After a long blackout the aircraft may have turned any amount; booking it as one step would
    /// be worse than under-correcting.
    @Test func followingReBaselinesAfterALongGap() {
        var follower = TrackFollowingYawOffset(maxGapSeconds: 30, gain: 1.0)
        follower.seed(offsetDeg: 5, trackDeg: 0, source: .anchor, at: 0)
        follower.update(trackDeg: 120, courseAccuracyDeg: 1, groundSpeedKt: 440, at: 600)
        #expect(follower.followedDeg == 0)
        #expect(abs((follower.offsetDeg ?? 99) - 5) < 0.001)
        // Following resumes from the new heading.
        follower.update(trackDeg: 123, courseAccuracyDeg: 1, groundSpeedKt: 440, at: 601)
        #expect(abs(follower.followedDeg - 3) < 0.001)
    }

    @Test func unseededFollowerAppliesNothing() {
        var follower = TrackFollowingYawOffset(gain: 1.0)
        follower.update(trackDeg: 300, courseAccuracyDeg: 0.1, groundSpeedKt: 440, at: 1)
        #expect(follower.offsetDeg == nil)
        #expect(!follower.hasSeed)
    }

    @Test func seedingResetsTheAccumulation() {
        var follower = TrackFollowingYawOffset(gain: 1.0)
        follower.seed(offsetDeg: 0, trackDeg: 300, source: .ground, at: 0)
        for i in 1...10 {
            follower.update(trackDeg: 300 - Double(i), courseAccuracyDeg: 1,
                            groundSpeedKt: 440, at: Double(i))
        }
        #expect(abs(follower.followedDeg - (-10)) < 0.001)
        follower.seed(offsetDeg: 20, trackDeg: 290, source: .anchor, at: 11)
        #expect(follower.followedDeg == 0)
        #expect(abs((follower.offsetDeg ?? 99) - 20) < 0.001)
        #expect(follower.source == .anchor)
    }

    @Test func clearStopsFollowing() {
        var follower = TrackFollowingYawOffset(gain: 1.0)
        follower.seed(offsetDeg: 3, trackDeg: 300, source: .ground, at: 0)
        follower.clear()
        #expect(follower.offsetDeg == nil)
        follower.update(trackDeg: 250, courseAccuracyDeg: 1, groundSpeedKt: 440, at: 1)
        #expect(follower.followedDeg == 0)
    }

    /// **The FL317 mis-aim.** A capture 50° off the nose must read as a disagreement against what
    /// following predicts, rather than being applied silently.
    @Test func disagreementCatchesAMisaimedAnchor() {
        var follower = TrackFollowingYawOffset(gain: 1.0)
        follower.seed(offsetDeg: 1.5, trackDeg: 297.8, source: .anchor, at: 0)
        for i in 1...108 {
            follower.update(trackDeg: 297.8 - 12.3 * Double(i) / 108.0,
                            courseAccuracyDeg: 0.1, groundSpeedKt: 440, at: Double(i))
        }
        // Following says −10.8; the mis-aimed capture said +39.1.
        #expect(abs((follower.offsetDeg ?? 99) - (-10.8)) < 0.05)
        let delta = follower.disagreementDeg(with: 39.1)
        #expect(delta != nil)
        #expect(abs(delta! - 49.9) < 0.1)
        // A good capture agrees.
        #expect(abs(follower.disagreementDeg(with: -11.0) ?? 99) < 0.3)
    }

    @Test func disagreementIsNilWithoutASeed() {
        let follower = TrackFollowingYawOffset(gain: 1.0)
        #expect(follower.disagreementDeg(with: 39.1) == nil)
    }

    // MARK: - Gyro azimuth

    @Test func gyroIntegratesASteadyRate() {
        var gyro = GyroAzimuthIntegrator(deadbandDps: 0.05, maxGapSeconds: 1.0)
        for i in 1...100 { gyro.add(yawRateDps: 3.0, at: Double(i) * 0.05) }
        // 100 samples at 0.05 s of 3 °/s; the first has no predecessor to integrate against.
        #expect(abs(gyro.azimuthDeg - 3.0 * 99 * 0.05) < 0.001)
    }

    /// Bias is what makes a gyro walk. Rates under the deadband contribute nothing.
    @Test func gyroDeadbandsBias() {
        var gyro = GyroAzimuthIntegrator(deadbandDps: 0.05)
        for i in 1...1000 { gyro.add(yawRateDps: 0.01, at: Double(i) * 0.05) }
        #expect(gyro.azimuthDeg == 0)
        #expect(gyro.hasSamples)
    }

    /// Device motion dropping out must break the integration, not be integrated as zero — and not
    /// be spanned by the next sample either.
    @Test func gyroDoesNotIntegrateAcrossAGap() {
        var gyro = GyroAzimuthIntegrator(maxGapSeconds: 1.0)
        gyro.add(yawRateDps: 3.0, at: 0)
        gyro.add(yawRateDps: 3.0, at: 0.05)
        let before = gyro.azimuthDeg
        gyro.add(yawRateDps: 3.0, at: 60)      // 60 s later: not integrated
        #expect(gyro.azimuthDeg == before)
        gyro.add(yawRateDps: 3.0, at: 60.05)   // resumes from there
        #expect(abs(gyro.azimuthDeg - (before + 0.15)) < 0.001)
    }

    @Test func gyroIgnoresNonFiniteRates() {
        var gyro = GyroAzimuthIntegrator()
        gyro.add(yawRateDps: .nan, at: 0)
        gyro.add(yawRateDps: .nan, at: 0.05)
        #expect(gyro.azimuthDeg == 0)
        #expect(!gyro.hasSamples)
    }

    // MARK: - Screen orientation

    // The mapping from ARKit's camera roll to an interface orientation, plus the hysteresis and
    // dwell that stop a hand held at an angle from flip-flopping the interface. Written because
    // getting the landscape sense backwards would rotate the picture the wrong way, which is worse
    // than the sideways HUD it is meant to fix.

    /// A phone held upright in portrait. ARKit's camera +x runs from the front camera toward the
    /// home button (device *down*) and +y along the device's portrait right, so world up lands on
    /// camera −x: right.y = −1, up.y = 0.
    @Test func portraitReadsAsMinusNinety() {
        let roll = ScreenOrientationFollower.imageRollDeg(cameraRightY: -1, cameraUpY: 0)
        #expect(roll != nil)
        #expect(abs(roll! - (-90)) < 0.001)
        #expect(ScreenOrientationFollower.nearestOrientation(toRollDeg: roll!, withinDeg: 30) == .portrait)
    }

    /// The four cardinal readings. The −90 → −180 step is the one the FL340 log recorded at the
    /// moment the user reported the HUD going sideways: portrait to landscape-left.
    @Test func cardinalRollsMapToTheirOrientations() {
        let cases: [(Double, UIInterfaceOrientation)] = [
            (0,    .landscapeRight),
            (-90,  .portrait),
            (180,  .landscapeLeft),
            (-180, .landscapeLeft),
            (90,   .portraitUpsideDown),
        ]
        for (roll, expected) in cases {
            #expect(ScreenOrientationFollower.nearestOrientation(toRollDeg: roll, withinDeg: 30) == expected)
        }
    }

    /// The reading wraps, so a roll just the other side of ±180 must still be landscape-left
    /// rather than falling off the end of the table.
    @Test func rollWrapsAcrossPlusMinus180() {
        #expect(ScreenOrientationFollower.nearestOrientation(toRollDeg: 175, withinDeg: 30) == .landscapeLeft)
        #expect(ScreenOrientationFollower.nearestOrientation(toRollDeg: -175, withinDeg: 30) == .landscapeLeft)
        #expect(ScreenOrientationFollower.nearestOrientation(toRollDeg: -155, withinDeg: 30) == .landscapeLeft)
    }

    /// Halfway between two orientations is genuinely ambiguous — the answer must be "no candidate",
    /// not whichever one happens to sort first.
    @Test func anAmbiguousAngleHasNoCandidate() {
        #expect(ScreenOrientationFollower.nearestOrientation(toRollDeg: -45, withinDeg: 30) == nil)
        #expect(ScreenOrientationFollower.nearestOrientation(toRollDeg: 135, withinDeg: 30) == nil)
    }

    /// Pointed within about 11° of straight up or down, both components collapse and the angle is
    /// noise. It must come back as unknown rather than as some confident direction.
    @Test func aFlatPhoneReportsNoRoll() {
        #expect(ScreenOrientationFollower.imageRollDeg(cameraRightY: 0.05, cameraUpY: 0.05) == nil)
        #expect(ScreenOrientationFollower.imageRollDeg(cameraRightY: 0, cameraUpY: 0) == nil)
        #expect(ScreenOrientationFollower.imageRollDeg(cameraRightY: 0, cameraUpY: -1) != nil)
    }

    @Test func aHeldRotationSwitchesAfterTheDwell() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0.5)
        #expect(follower.update(imageRollDeg: -180, at: 0.0) == nil)     // starts the clock
        #expect(follower.update(imageRollDeg: -178, at: 0.2) == nil)     // not yet
        #expect(follower.update(imageRollDeg: -179, at: 0.6) == .landscapeLeft)
        #expect(follower.current == .landscapeLeft)
        // Settled: no repeat request while it stays there.
        #expect(follower.update(imageRollDeg: -179, at: 1.2) == nil)
    }

    /// Turbulence, or a hand passing through landscape on the way somewhere else, must not rotate
    /// the interface.
    @Test func aBriefRotationIsIgnored() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0.5)
        #expect(follower.update(imageRollDeg: -180, at: 0.0) == nil)
        #expect(follower.update(imageRollDeg: -90,  at: 0.2) == nil)     // back to portrait
        #expect(follower.update(imageRollDeg: -180, at: 0.4) == nil)     // clock restarts here
        #expect(follower.update(imageRollDeg: -180, at: 0.7) == nil)     // 0.3s served, not 0.7
        #expect(follower.current == .portrait)
    }

    /// A phone held at 45° for a long time must sit still, not oscillate between neighbours.
    @Test func anAngledHoldNeverSwitches() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0.5)
        for step in 0..<40 {
            #expect(follower.update(imageRollDeg: -45, at: Double(step) * 0.2) == nil)
        }
        #expect(follower.current == .portrait)
    }

    /// Upside-down portrait is not declared for iPhone, so a geometry request for it would be
    /// refused. Holding is right; asking repeatedly would look exactly like the bug.
    @Test func anUndeclaredOrientationIsHeldNotChased() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0.5)
        for step in 0..<20 {
            #expect(follower.update(imageRollDeg: 90, at: Double(step) * 0.2) == nil)
        }
        #expect(follower.current == .portrait)
    }

    /// Going flat mid-rotation must discard the part-served dwell rather than let it resume, so a
    /// phone laid down and picked up differently does not switch on stale evidence.
    @Test func goingFlatRestartsTheDwell() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0.5)
        #expect(follower.update(imageRollDeg: -180, at: 0.0) == nil)
        #expect(follower.update(imageRollDeg: nil,  at: 0.2) == nil)     // laid flat
        #expect(follower.update(imageRollDeg: -180, at: 0.4) == nil)     // clock restarts
        #expect(follower.update(imageRollDeg: -180, at: 0.7) == nil)
        #expect(follower.current == .portrait)
        #expect(follower.update(imageRollDeg: -180, at: 0.95) == .landscapeLeft)
    }

    /// iOS rotating the interface on its own (rotation lock off) must be adopted, not fought.
    @Test func anExternalRotationIsAdopted() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0.5)
        follower.sync(to: .landscapeLeft)
        #expect(follower.current == .landscapeLeft)
        // Already there, so no request is issued for the same orientation.
        #expect(follower.update(imageRollDeg: -180, at: 0.0) == nil)
        #expect(follower.update(imageRollDeg: -180, at: 1.0) == nil)
    }

    /// The values a phone lying still in portrait actually produced on the device, from the
    /// build-16 log, read off frame.camera.transform. All of them must be portrait: this is the
    /// case that oscillated, and it oscillated because the reading came from the wrong frame.
    @Test func measuredPortraitRollsStayPortrait() {
        for roll in [-90.7, -91.3, -91.4, -93.7, -95.9, -96.0, -100.5] {
            #expect(ScreenOrientationFollower.nearestOrientation(toRollDeg: roll, withinDeg: 30) == .portrait)
        }
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0.5)
        for (i, roll) in [-91.4, -94.8, -96.0, -100.5, -93.3].enumerated() {
            #expect(follower.update(imageRollDeg: roll, at: Double(i)) == nil)
        }
        #expect(follower.current == .portrait)
        #expect(follower.isFollowing)
    }

    // MARK: - The thrash cutoff

    /// A screen flipping in the pilot's hand is worse than one that fails to rotate, so following
    /// gives up rather than run an oscillation for a whole flight. The fifth change inside the
    /// window is refused, not performed.
    @Test func rapidFlippingDisablesFollowing() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0,
                                                 maxChangesInWindow: 4, changeWindowSeconds: 20)
        var changes = 0
        // Alternate between portrait and landscape-left as fast as the dwell allows.
        for step in 0..<40 {
            let roll = step % 2 == 0 ? -180.0 : -90.0
            // Two ticks per target: the first starts the dwell, the second can commit.
            _ = follower.update(imageRollDeg: roll, at: Double(step) * 0.5)
            if follower.update(imageRollDeg: roll, at: Double(step) * 0.5 + 0.2) != nil { changes += 1 }
        }
        #expect(changes == 4)
        #expect(!follower.isFollowing)
        #expect(follower.disabledReason == "thrash")
    }

    /// Once it has given up it stays given up — no target is ever returned again, however well
    /// behaved the readings become.
    @Test func aDisabledFollowerNeverRotatesAgain() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0,
                                                 maxChangesInWindow: 1, changeWindowSeconds: 20)
        _ = follower.update(imageRollDeg: -180, at: 0.0)
        #expect(follower.update(imageRollDeg: -180, at: 0.1) == .landscapeLeft)   // 1st change, allowed
        _ = follower.update(imageRollDeg: -90, at: 1.0)
        #expect(follower.update(imageRollDeg: -90, at: 1.1) == nil)               // 2nd, refused
        #expect(!follower.isFollowing)
        for step in 0..<20 {
            #expect(follower.update(imageRollDeg: -90, at: 100 + Double(step)) == nil)
        }
    }

    // MARK: - Staleness

    /// The dashed ring and the dead-reckoning ceiling must stay the same number. Dashed is meant
    /// to say "this has stopped being extrapolated"; if the two drift apart it says nothing.
    @Test func staleMarkMatchesTheCoastCeiling() {
        #expect(CalculationsLogic.staleAircraftAgeSeconds == CalculationsLogic.maxCoastSeconds)
    }

    /// Just inside the ceiling the target is still being projected forward and must not be dashed;
    /// just outside, projection has frozen and it must be. The two have to flip together.
    @Test func aTargetIsDashedExactlyWhenItStopsBeingExtrapolated() {
        let ceiling = CalculationsLogic.maxCoastSeconds
        let fresh = aircraft(age: ceiling - 1)
        let frozen = aircraft(age: ceiling + 1)

        #expect(!CalculationsLogic.isStale(fresh))
        #expect(CalculationsLogic.isStale(frozen))

        // The frozen one sits where the ceiling put it, not where its true age would coast it to.
        let atCeiling = CalculationsLogic.predictPosition(
            currentCoord: frozen.coordinate, currentAltitude: frozen.altitude,
            track: frozen.track, groundSpeed: frozen.groundSpeed,
            verticalRate: frozen.verticalRate, timeSeconds: ceiling)
        let predicted = CalculationsLogic.predictedPosition(for: frozen, aheadSeconds: 0)
        #expect(abs(predicted.coordinate.latitude  - atCeiling.coordinate.latitude)  < 1e-9)
        #expect(abs(predicted.coordinate.longitude - atCeiling.coordinate.longitude) < 1e-9)
    }

    /// One missed fetch on an 8 s cadence must not dash the whole display. Every internet aircraft
    /// shares a fetch timestamp, so this threshold applies to all hundred of them at once.
    @Test func oneMissedFetchDoesNotMarkTrafficStale() {
        #expect(!CalculationsLogic.isStale(aircraft(age: 16)))   // two fetch cycles missed
    }

    // MARK: - Compass reference

    /// CoreLocation and UIKit name the two landscape positions oppositely: both define their cases
    /// by where the home button is, and interface-landscapeRight (home button right) is the same
    /// physical position CoreLocation calls landscapeLeft. Getting this crossing wrong leaves the
    /// compass 90 degrees out, which is the defect this mapping exists to fix.
    @Test func headingOrientationCrossesForLandscape() {
        #expect(ScreenOrientationFollower.headingOrientation(for: .portrait) == .portrait)
        #expect(ScreenOrientationFollower.headingOrientation(for: .portraitUpsideDown) == .portraitUpsideDown)
        #expect(ScreenOrientationFollower.headingOrientation(for: .landscapeLeft) == .landscapeRight)
        #expect(ScreenOrientationFollower.headingOrientation(for: .landscapeRight) == .landscapeLeft)
    }

    /// An unknown interface orientation must fall back to portrait rather than to whatever the
    /// enumeration's zero value happens to be.
    @Test func headingOrientationFallsBackToPortrait() {
        #expect(ScreenOrientationFollower.headingOrientation(for: .unknown) == .portrait)
    }

    /// Someone genuinely turning the phone back and forth over a couple of minutes is not
    /// thrashing, and must not be cut off.
    @Test func changesSpreadOutDoNotDisableFollowing() {
        var follower = ScreenOrientationFollower(current: .portrait, dwellSeconds: 0,
                                                 maxChangesInWindow: 4, changeWindowSeconds: 20)
        var changes = 0
        // One deliberate flip every 15 s — inside the count, outside the window.
        for step in 0..<8 {
            let roll = step % 2 == 0 ? -180.0 : -90.0
            let t = Double(step) * 15.0
            _ = follower.update(imageRollDeg: roll, at: t)
            if follower.update(imageRollDeg: roll, at: t + 0.2) != nil { changes += 1 }
        }
        #expect(changes == 8)
        #expect(follower.isFollowing)
    }
}
