//
//  CircularMedianTests.swift
//  Tally-HoTests
//
//  Medians of angles that straddle ±180°. Sorting raw values splits such a cluster into two halves
//  360° apart, and the median lands between them — about 0 for a set that is really about 180, a
//  world put 180° wrong. Offsets sit near the phone's starting true heading under `.gravity`, so a
//  southbound start is enough: Gev's ground logs seed at −173.5, −160.7 and −158.9.
//
//  Each estimator gets a straddling set, which must come out near ±180 (and, for the IQR, small),
//  and a set off the seam, which must come out *exactly* as the old raw sort computed it.
//

import Testing
import Foundation
@testable import Tally_Ho

struct CircularMedianTests {

    /// The pre-fix computation, kept here as the reference the off-seam results must still match.
    private func rawMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func rawIQR(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return AltitudeDatumOffset.percentile(sorted, 0.75) - AltitudeDatumOffset.percentile(sorted, 0.25)
    }

    /// Near ±180 — either sign is the same direction.
    private func isNearOneEighty(_ degrees: Double) -> Bool { abs(abs(degrees) - 180) < 0.5 }

    /// A phone facing due south, ARKit's azimuth jittering about 0: every offset is `180 − az`, and
    /// half of them wrap to the negative side.
    private let southAzimuths: [Double] = [0.4, 0.2, -0.1, -0.3]

    // MARK: - The helper

    @Test func circularMedianOfAStraddlingSetIsNearOneEighty() {
        let straddling: [Double] = [179.6, 179.8, -179.9, -179.7]
        // The bug, stated: the raw middle pair is −179.7 and 179.6.
        #expect(abs(rawMedian(straddling)) < 1)

        let median = AngularResponse.circularMedianDeg(straddling)
        #expect(isNearOneEighty(median))
        #expect(abs(median - 179.95) < 0.001)
    }

    /// Off the seam nothing moves, so the answer is bit-for-bit what the raw sort gave — odd and even
    /// counts, and clusters close to the seam without crossing it.
    @Test func circularMedianOffTheSeamIsExactlyTheRawMedian() {
        let sets: [[Double]] = [
            [-173.3, -173.8, -173.4, -173.6, -173.5, -173.7],        // Gev's −173.5 ground seed, n=6
            [-160.7, -158.9, -165.0, -172.0, -168.4],                // the 15 s median's wander
            [137.7, 139.2, 135.9, 141.0, 136.4, 138.8, 134.1],       // Teterboro
            [2.0, -31.6, 19.4, 1.5, 3.0, -2.5],                      // a spiky ground residual
            [176.0, 178.9, 179.9, 175.2],                            // close to the seam, not across
            [-4.0],
        ]
        for set in sets {
            #expect(AngularResponse.circularMedianDeg(set) == rawMedian(set))
        }
    }

    @Test func circularIQRAcrossTheSeamIsSmall() {
        let straddling: [Double] = [179.2, -179.5, 178.8, -179.1, 179.6, -178.9,
                                    179.2, -179.5, 178.8, -179.1, 179.6, -178.9]
        #expect(rawIQR(straddling) > 300)          // the bug, stated
        let iqr = AngularResponse.circularInterquartileRangeDeg(straddling)
        #expect(iqr < 3)
        #expect(iqr >= 0)
    }

    @Test func circularIQROffTheSeamIsExactlyTheRawIQR() {
        let sets: [[Double]] = [
            Array(0...10).map(Double.init),                          // the existing 0…10 fixture
            [137.7, 139.2, 135.9, 141.0, 136.4, 138.8, 134.1, 140.2, 137.1, 142.3],
            [-165.0, -172.0, -168.4, -160.7, -170.2, -163.3, -171.9, -166.6, -169.0, -167.5],
        ]
        for set in sets {
            #expect(AngularResponse.circularInterquartileRangeDeg(set) == rawIQR(set))
        }
    }

    /// The result is always in (−180, 180], whichever side of the seam the middle falls.
    @Test func circularMedianIsWrappedIntoTheHalfOpenRange() {
        let sets: [[Double]] = [[179.0, -179.0], [-179.0, 179.0], [180.0, -180.0],
                                [179.9, -179.8, -179.9], [-179.9, 179.8, 179.9]]
        for set in sets {
            let median = AngularResponse.circularMedianDeg(set)
            #expect(median > -180 && median <= 180)
            #expect(isNearOneEighty(median))
        }
    }

    @Test func anEmptySetHasNoMedianOrIQR() {
        #expect(AngularResponse.circularMedianDeg([]).isNaN)
        #expect(AngularResponse.circularInterquartileRangeDeg([]).isNaN)
        #expect(AngularResponse.circularMedianDeg([.nan, .infinity]).isNaN)
    }

    // MARK: - AirborneSeedSettle

    /// Four samples in the settled window — an even count, which is what makes the raw middle pair
    /// average to about 0.
    @Test func airborneSeedAcrossTheSeamIsNearOneEighty() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let azimuths: [Double] = [90, 90, 90, 40] + southAzimuths + [0.1, 0.1]
        var published: AirborneSeedSettle.Estimate?
        for (i, az) in azimuths.enumerated() {
            let t = 0.05 + Double(i) * 0.2
            seed.add(arAzimuthDeg: az, trackDeg: 180, at: t)
            if let e = seed.finish(at: t) { published = e; break }
        }
        let e = try #require(published)
        #expect(e.path == .moved)
        #expect(e.sampleCount == 4)
        #expect(abs(rawMedian(southAzimuths.map { AngularResponse.signedDelta($0, 180) })) < 1)
        #expect(isNearOneEighty(e.offsetDeg))
    }

    @Test func airborneSeedOffTheSeamIsUnchanged() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let cycle: [Double] = [0.3, -0.2, 0.1, 0.4, -0.1, 0.0]
        var offsets: [Double] = []
        var published: AirborneSeedSettle.Estimate?
        for i in 0..<30 {
            let t = 0.05 + Double(i) * 0.2
            let az = cycle[i % cycle.count]
            offsets.append(AngularResponse.signedDelta(az, 201))     // about −159, Gev's −160.7 seed
            seed.add(arAzimuthDeg: az, trackDeg: 201, at: t)
            if let e = seed.finish(at: t) { published = e; break }
        }
        let e = try #require(published)
        #expect(e.path == .still)
        #expect(e.sampleCount == offsets.count)     // steady throughout, so the window is all of it
        #expect(e.offsetDeg == rawMedian(offsets))
    }

    // MARK: - StartupSeed

    /// The ground seed, n=6 as in Gev's logs, facing due south.
    @Test func startupSeedAcrossTheSeamIsNearOneEighty() throws {
        var seed = StartupSeed()
        seed.begin(reference: .compass)
        let azimuths = southAzimuths + [-0.5, 0.5]
        for (i, az) in azimuths.enumerated() {
            seed.add(arAzimuthDeg: az, referenceDeg: 180, at: Double(i) * 0.2)
        }
        let finished = seed.finish(at: 1.2)
        let e = try #require(finished)
        #expect(abs(rawMedian(azimuths.map { AngularResponse.signedDelta($0, 180) })) < 1)
        #expect(isNearOneEighty(e.offsetDeg))
    }

    @Test func startupSeedOffTheSeamIsUnchanged() throws {
        var seed = StartupSeed()
        seed.begin(reference: .compass)
        let azimuths: [Double] = [359.3, 359.6, 359.4, 359.8, 359.5, 359.7]
        for (i, az) in azimuths.enumerated() {
            seed.add(arAzimuthDeg: az, referenceDeg: 186, at: Double(i) * 0.2)
        }
        let finished = seed.finish(at: 1.2)
        let e = try #require(finished)
        let offsets = azimuths.map { AngularResponse.signedDelta($0, 186) }   // about −173.5
        #expect(e.offsetDeg == rawMedian(offsets))
    }

    // MARK: - FlightDirectionAnchor

    @Test func flightAnchorAcrossTheSeamIsNearOneEighty() {
        var anchor = FlightDirectionAnchor()
        anchor.begin(at: 0)
        var offsets: [Double] = []
        for i in 0..<16 {
            let az = southAzimuths[i % southAzimuths.count]
            offsets.append(AngularResponse.signedDelta(az, 180))
            anchor.add(arAzimuthDeg: az, trackDeg: 180, at: Double(i) * 0.2)
        }
        let result = anchor.finish(at: 3.2)
        guard case .success(let e) = result else {
            #expect(Bool(false), "the anchor refused a steady hold")
            return
        }
        #expect(abs(rawMedian(offsets)) < 1)
        #expect(isNearOneEighty(e.offsetDeg))
    }

    @Test func flightAnchorOffTheSeamIsUnchanged() {
        var anchor = FlightDirectionAnchor()
        anchor.begin(at: 0)
        let cycle: [Double] = [100.2, 99.7, 100.5, 99.9, 100.1]
        var offsets: [Double] = []
        for i in 0..<16 {
            let az = cycle[i % cycle.count]
            offsets.append(AngularResponse.signedDelta(az, 263.5))
            anchor.add(arAzimuthDeg: az, trackDeg: 263.5, at: Double(i) * 0.2)
        }
        let result = anchor.finish(at: 3.2)
        guard case .success(let e) = result else {
            #expect(Bool(false), "the anchor refused a steady hold")
            return
        }
        #expect(e.offsetDeg == rawMedian(offsets))
    }

    // MARK: - AlignmentDriftMonitor

    /// Fed `worldYawErrorDeg`, which is the whole offset rather than a residual, so a southbound
    /// session sits on the seam for its entire length. Raw, the median read about 0 and the IQR about
    /// 358, which the dispersion gate refused as `.dispersed` on every tick.
    @Test func driftMonitorAcrossTheSeamHasAMedianNearOneEightyAndASmallIQR() throws {
        var monitor = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        let cycle: [Double] = [179.2, -179.5, 178.8, -179.1, 179.6, -178.9]
        var values: [Double] = []
        for i in 0..<12 {
            let v = cycle[i % cycle.count]
            values.append(v)
            monitor.add(errorDeg: v, at: Double(i) * 0.5)
        }
        #expect(abs(rawMedian(values)) < 1)
        #expect(rawIQR(values) > 300)

        let median = try #require(monitor.medianErrorDeg)
        let iqr = try #require(monitor.interquartileRangeDeg)
        #expect(isNearOneEighty(median))
        #expect(iqr < 3)
        // And the refinement is no longer refused for it: well inside the 12° dispersion gate.
        #expect(iqr < GroundYawCorrection().maxDispersionDeg)
    }

    @Test func driftMonitorOffTheSeamIsUnchanged() throws {
        var monitor = AlignmentDriftMonitor(window: 15, minSamples: 10, minSampleInterval: 0.5)
        let values: [Double] = [137.7, 139.2, 135.9, 141.0, 136.4, 138.8,
                                134.1, 140.2, 137.1, 142.3, 136.8, 139.5]
        for (i, v) in values.enumerated() { monitor.add(errorDeg: v, at: Double(i) * 0.5) }

        let median = try #require(monitor.medianErrorDeg)
        let iqr = try #require(monitor.interquartileRangeDeg)
        #expect(median == rawMedian(values))
        #expect(iqr == rawIQR(values))
    }
}
