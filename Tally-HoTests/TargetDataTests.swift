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
}
