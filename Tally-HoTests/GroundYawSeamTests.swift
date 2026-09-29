//
//  GroundYawSeamTests.swift
//  Tally-HoTests
//
//  `GroundYawCorrection` across ±180°. It subtracted the median from the applied offset with a
//  plain minus and never wrapped what it applied, so a median that crossed the seam — applied
//  −179.5, median +179.8 — read as 359.3° to go and slewed the long way round at 1°/s: six minutes
//  of the scene turning where 0.7° was the answer. Offsets near ±180 are an ordinary southbound
//  start under `.gravity`; Gev's ground logs seed at −173.5.
//
//  The existing ground-yaw tests in TargetDataTests are deliberately untouched: off the seam the
//  arithmetic is the same operations on the same numbers.
//

import Testing
import Foundation
@testable import Tally_Ho

struct GroundYawSeamTests {

    /// One healthy ground tick: compass measuring the phone, accuracy good, world up.
    private func tick(_ correction: inout GroundYawCorrection,
                      median: Double,
                      at time: TimeInterval) -> GroundYawCorrection.Outcome {
        correction.update(medianErrorDeg: median,
                          dispersionDeg: 4.0,
                          compassResponse: 1.0,
                          compassResponseR: 0.95,
                          headingAccuracyDeg: 10,
                          airborne: false,
                          worldUsable: true,
                          at: time)
    }

    private func inRange(_ degrees: Double) -> Bool { degrees > -180 && degrees <= 180 }

    /// The reported case. One step, 0.7° the short way, and then nothing more to do.
    @Test func aMedianAcrossTheSeamIsReachedTheShortWay() {
        var correction = GroundYawCorrection(deadbandDeg: 0.5)
        correction.prime(offsetDeg: -179.5)

        let first = tick(&correction, median: 179.8, at: 0)
        #expect(first != .refused(.withinDeadband))
        // −179.5 − 0.7 = −180.2, which is +179.8.
        #expect(abs(correction.appliedOffsetDeg - 179.8) < 0.001)
        #expect(abs(AngularResponse.signedDelta(-179.5, correction.appliedOffsetDeg) - (-0.7)) < 0.001)

        // Converged: every later tick is inside the deadband. The old code would have spent the
        // next 358 ticks walking the other way round.
        var moves = 0
        for i in 1...10 {
            if case .applied = tick(&correction, median: 179.8, at: Double(i)) { moves += 1 }
        }
        #expect(moves == 0)
        #expect(abs(correction.appliedOffsetDeg - 179.8) < 0.001)
    }

    /// With the default 1.5° deadband the same 0.7° is inside the band, so the right answer is to
    /// stay put. The old arithmetic read 359.3°, cleared the band and started the long slew.
    @Test func aSmallGapAcrossTheSeamIsInsideTheDefaultDeadband() {
        var correction = GroundYawCorrection()
        correction.prime(offsetDeg: -179.5)
        let outcome = tick(&correction, median: 179.8, at: 0)
        #expect(outcome == .refused(.withinDeadband))
        #expect(correction.appliedOffsetDeg == -179.5)
    }

    /// A larger gap across the seam slews at the normal rate, the short way, and arrives in as many
    /// ticks as the short gap needs — four for 4° — never more than 1° a tick.
    @Test func aSlewAcrossTheSeamTakesTheShortWayAtTheNormalRate() {
        var correction = GroundYawCorrection(deadbandDeg: 0.5, maxSlewPerUpdateDeg: 1.0)
        correction.prime(offsetDeg: -179.0)
        var previous = correction.appliedOffsetDeg
        var ticks = 0
        for i in 0..<20 {
            guard case .applied(let applied) = tick(&correction, median: 177.0, at: Double(i)) else { break }
            ticks += 1
            #expect(inRange(applied))
            #expect(abs(AngularResponse.signedDelta(previous, applied)) <= 1.0 + 1e-9)
            previous = applied
        }
        #expect(ticks == 4)
        #expect(abs(correction.appliedOffsetDeg - 177.0) < 0.001)
    }

    /// Primed just short of the seam, then walked across it: the applied offset stays in
    /// (−180, 180] at every step, rather than counting on through 180.9 and beyond.
    @Test func aPrimeNearTheSeamStaysWrappedAsStepsCrossIt() {
        var correction = GroundYawCorrection(deadbandDeg: 0.5, maxSlewPerUpdateDeg: 1.0)
        correction.prime(offsetDeg: 179.9)
        #expect(correction.appliedOffsetDeg == 179.9)

        var outcomes: [Double] = []
        for i in 0..<5 {
            if case .applied(let applied) = tick(&correction, median: -177.1, at: Double(i)) {
                outcomes.append(applied)
            }
        }
        // 179.9 → −179.1 → −178.1 → −177.1: three steps of +1, all wrapped.
        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy(inRange))
        #expect(abs(correction.appliedOffsetDeg - (-177.1)) < 0.001)
    }

    /// `prime` wraps what it is handed, including the seam itself.
    @Test func primeWrapsItsInput() {
        var correction = GroundYawCorrection()
        correction.prime(offsetDeg: 190)
        #expect(abs(correction.appliedOffsetDeg - (-170)) < 1e-9)
        correction.prime(offsetDeg: -180)
        #expect(correction.appliedOffsetDeg == 180)
        correction.prime(offsetDeg: -173.5)
        #expect(correction.appliedOffsetDeg == -173.5)
    }

    /// The magnitude cap judges the angle, not the number: 350 is −10, which a 20° cap accepts.
    @Test func theOffsetCapJudgesTheAngleNotTheNumber() {
        var correction = GroundYawCorrection(maxOffsetDeg: 20, deadbandDeg: 0.5)
        let accepted = tick(&correction, median: 350, at: 0)
        #expect(accepted != .refused(.implausibleOffset))
        #expect(abs(correction.appliedOffsetDeg - (-1.0)) < 0.001)   // the first step toward −10

        var capped = GroundYawCorrection(maxOffsetDeg: 20, deadbandDeg: 0.5)
        let refused = tick(&capped, median: 315, at: 0)                // −45
        #expect(refused == .refused(.implausibleOffset))
    }
}
