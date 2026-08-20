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
        age: TimeInterval = 0
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
            hasValidTrack: hasValidTrack
        )
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
}
