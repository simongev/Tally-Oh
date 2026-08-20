//
//  OwnshipEstimatorTests.swift
//  Tally-HoTests
//
//  The behaviour these lock in is the one that was wrong before: which source wins, and whose
//  timestamp and velocity the extrapolation uses.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

struct OwnshipEstimatorTests {

    private let sanFrancisco = CLLocationCoordinate2D(latitude: 37.6188, longitude: -122.3750)
    private let oakland      = CLLocationCoordinate2D(latitude: 37.7213, longitude: -122.2210)

    // MARK: - Source selection

    @Test func noSourceYieldsNoPosition() {
        let estimator = OwnshipEstimator()
        #expect(estimator.snapshot().hasPosition == false)
        #expect(estimator.snapshot().source == .none)
    }

    @Test func phoneIsUsedWhenNoADSBPresent() {
        let estimator = OwnshipEstimator()
        let now = Date()
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 8,
            groundSpeedKt: nil, trackDeg: nil, timestamp: now)

        let snapshot = estimator.snapshot(at: now)
        #expect(snapshot.source == .phone)
        #expect(snapshot.coordinate.latitude == sanFrancisco.latitude)
    }

    @Test func freshADSBOutranksPhone() {
        let estimator = OwnshipEstimator()
        let now = Date()
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 8,
            groundSpeedKt: nil, trackDeg: nil, timestamp: now)
        estimator.ingestADSBOwnship(
            coordinate: oakland, pressureAltitudeFt: 5000,
            groundSpeedKt: 120, trackDeg: 90, verticalRateFpm: 0, timestamp: now)

        let snapshot = estimator.snapshot(at: now)
        #expect(snapshot.source == .adsb)
        #expect(snapshot.coordinate.latitude == oakland.latitude)
    }

    @Test func staleADSBFallsBackToPhone() {
        let estimator = OwnshipEstimator()
        let start = Date()
        estimator.ingestADSBOwnship(
            coordinate: oakland, pressureAltitudeFt: 5000,
            groundSpeedKt: 0, trackDeg: 0, verticalRateFpm: 0, timestamp: start)
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 8,
            groundSpeedKt: nil, trackDeg: nil, timestamp: start)

        // Past the freshness limit the receiver's position must stop winning.
        let later = start.addingTimeInterval(OwnshipEstimator.adsbFreshnessLimit + 1)
        #expect(estimator.snapshot(at: later).source == .phone)
    }

    @Test func clearingADSBRestoresPhoneImmediately() {
        let estimator = OwnshipEstimator()
        let now = Date()
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 8,
            groundSpeedKt: nil, trackDeg: nil, timestamp: now)
        estimator.ingestADSBOwnship(
            coordinate: oakland, pressureAltitudeFt: 5000,
            groundSpeedKt: 0, trackDeg: 0, verticalRateFpm: 0, timestamp: now)
        #expect(estimator.snapshot(at: now).source == .adsb)

        estimator.clearADSB()
        #expect(estimator.snapshot(at: now).source == .phone)
    }

    @Test func ownshipReportWithoutPositionDoesNotBecomeNullIsland() {
        let estimator = OwnshipEstimator()
        let now = Date()
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 8,
            groundSpeedKt: nil, trackDeg: nil, timestamp: now)
        // A receiver that has not yet acquired GPS sends zeroes.
        estimator.ingestADSBOwnship(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            pressureAltitudeFt: 1200,
            groundSpeedKt: nil, trackDeg: nil, verticalRateFpm: nil, timestamp: now)

        let snapshot = estimator.snapshot(at: now)
        #expect(snapshot.source == .phone)
        #expect(snapshot.coordinate.latitude == sanFrancisco.latitude)
    }

    // MARK: - Dead reckoning

    @Test func stationaryPositionIsNotExtrapolated() {
        let estimator = OwnshipEstimator()
        let start = Date()
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 8,
            groundSpeedKt: 1, trackDeg: 90, timestamp: start)

        let snapshot = estimator.snapshot(at: start.addingTimeInterval(2))
        #expect(snapshot.wasDeadReckoned == false)
        #expect(snapshot.coordinate.longitude == sanFrancisco.longitude)
    }

    @Test func movingPositionIsExtrapolatedAlongTrack() {
        let estimator = OwnshipEstimator()
        let start = Date()
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 8,
            groundSpeedKt: 600, trackDeg: 90, timestamp: start)

        let snapshot = estimator.snapshot(at: start.addingTimeInterval(1))
        #expect(snapshot.wasDeadReckoned == true)
        // Due east: longitude increases, latitude essentially unchanged.
        #expect(snapshot.coordinate.longitude > sanFrancisco.longitude)
        #expect(abs(snapshot.coordinate.latitude - sanFrancisco.latitude) < 0.001)

        // 600 kt for one second is ~309 m.
        let travelled = CalculationsLogic.distance(from: sanFrancisco, to: snapshot.coordinate)
        #expect(abs(travelled - 308.7) < 5.0)
    }

    @Test func extrapolationStopsAtTheCoastCap() {
        let estimator = OwnshipEstimator()
        let start = Date()
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 8,
            groundSpeedKt: 600, trackDeg: 90, timestamp: start)

        let beyondCap = start.addingTimeInterval(OwnshipEstimator.maxDeadReckonSeconds + 1)
        let snapshot = estimator.snapshot(at: beyondCap)
        #expect(snapshot.wasDeadReckoned == false)
        #expect(snapshot.coordinate.longitude == sanFrancisco.longitude)
    }

    /// The defect this whole type exists to fix: an ADS-B position must be coasted using the
    /// receiver's own timestamp and velocity, never the phone's.
    @Test func adsbPositionIsNotExtrapolatedUsingPhoneTiming() {
        let estimator = OwnshipEstimator()
        let start = Date()

        // An old phone fix moving fast due west.
        estimator.ingestPhoneLocation(
            coordinate: sanFrancisco, horizontalAccuracyM: 60,
            groundSpeedKt: 450, trackDeg: 270, timestamp: start)

        // A brand-new ADS-B report, stationary.
        let adsbTime = start.addingTimeInterval(3)
        estimator.ingestADSBOwnship(
            coordinate: oakland, pressureAltitudeFt: 35000,
            groundSpeedKt: 0, trackDeg: 0, verticalRateFpm: 0, timestamp: adsbTime)

        let snapshot = estimator.snapshot(at: adsbTime)
        #expect(snapshot.source == .adsb)
        // Must sit exactly on the reported position: no borrowed phone age, no borrowed course.
        #expect(snapshot.wasDeadReckoned == false)
        #expect(snapshot.coordinate.latitude == oakland.latitude)
        #expect(snapshot.coordinate.longitude == oakland.longitude)
    }

    @Test func adsbCoastsOnItsOwnVelocityBetweenReports() {
        let estimator = OwnshipEstimator()
        let start = Date()
        estimator.ingestADSBOwnship(
            coordinate: sanFrancisco, pressureAltitudeFt: 35000,
            groundSpeedKt: 450, trackDeg: 90, verticalRateFpm: 0, timestamp: start)

        // One second later, before the next 1 Hz report arrives.
        let snapshot = estimator.snapshot(at: start.addingTimeInterval(1))
        #expect(snapshot.source == .adsb)
        #expect(snapshot.wasDeadReckoned == true)
        #expect(snapshot.coordinate.longitude > sanFrancisco.longitude)
    }

    // MARK: - Altitude datums

    @Test func displayAltitudePrefersReceiverAltitude() {
        let estimator = OwnshipEstimator()
        let now = Date()
        estimator.ingestPhoneAltitude(fusedMSLFt: 1200)
        estimator.ingestADSBOwnship(
            coordinate: oakland, pressureAltitudeFt: 35000,
            groundSpeedKt: nil, trackDeg: nil, verticalRateFpm: nil, timestamp: now)

        #expect(estimator.snapshot(at: now).displayAltitudeFt == 35000)
    }

    @Test func displayAltitudeFallsBackToPhoneWhenReceiverAltitudeIsMissing() {
        let estimator = OwnshipEstimator()
        let now = Date()
        estimator.ingestPhoneAltitude(fusedMSLFt: 1200)
        // A report whose altitude field carried the "unavailable" code.
        estimator.ingestADSBOwnship(
            coordinate: oakland, pressureAltitudeFt: nil,
            groundSpeedKt: nil, trackDeg: nil, verticalRateFpm: nil, timestamp: now)

        #expect(estimator.snapshot(at: now).displayAltitudeFt == 1200)
    }

    @Test func geometricAltitudeConvertsEllipsoidalUsingGeoidSeparation() {
        let estimator = OwnshipEstimator()
        let now = Date()
        // Phone reports HAE 100 ft above MSL at this location.
        estimator.ingestPhoneVerticalReferences(pressureAltitudeFt: nil, geoidSeparationFt: 100)
        estimator.ingestADSBGeometricAltitude(heightAboveEllipsoidFt: 5100, timestamp: now)

        let snapshot = estimator.snapshot(at: now)
        #expect(snapshot.hasGeometricAltitude == true)
        #expect(snapshot.geometricAltitudeFt == 5000)
    }

    @Test func bothVerticalDatumsAreCarriedIndependently() {
        let estimator = OwnshipEstimator()
        let now = Date()
        estimator.ingestPhoneVerticalReferences(pressureAltitudeFt: 7800, geoidSeparationFt: 0)
        estimator.ingestADSBGeometricAltitude(heightAboveEllipsoidFt: 35000, timestamp: now)

        let snapshot = estimator.snapshot(at: now)
        #expect(snapshot.hasGeometricAltitude == true)
        #expect(snapshot.hasPressureAltitude == true)
        #expect(snapshot.geometricAltitudeFt == 35000)
        #expect(snapshot.pressureAltitudeFt == 7800)
    }

    // MARK: - Pressurization heuristic

    @Test func ambientCabinIsNotFlaggedAsPressurized() {
        // A low QNH on a cold day: the two datums differ, but plausibly so.
        #expect(PressurizationHeuristic.isCabinPressurized(
            cabinPressureAltitudeFt: 6200, geometricAltitudeFt: 5000) == false)
    }

    @Test func jetCabinIsFlaggedAsPressurized() {
        // 8,000 ft cabin at FL350.
        #expect(PressurizationHeuristic.isCabinPressurized(
            cabinPressureAltitudeFt: 8000, geometricAltitudeFt: 35000) == true)
    }
}
