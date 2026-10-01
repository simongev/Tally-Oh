//
//  GyroYawHoldTests.swift
//  Tally-HoTests
//
//  The gyro yaw hold, off the device: a step in D = arAz − cmYaw across a tracking episode is
//  undone, slow drift is not, a step measured while the phone was turning is refused, a world reset
//  carries the anchor constant K across as K − D, and nothing goes the long way round ±180°. Then
//  the CoreMotion geometry: the camera's azimuth from an attitude matrix and gravity, whichever way
//  the matrix maps.
//
//  Streams are 20 Hz, as CoreMotion updates, and start at 0.01 s so a sample rarely lands on a
//  threshold. Where one could, the test is built not to care which side it falls.
//

import Testing
import Foundation
@testable import Tally_Ho

struct GyroYawHoldTests {

    // MARK: - Stream helpers

    private func sample(_ t: Double, normal: Bool = true, gap: Double?,
                        rate: Double = 1.0) -> GyroYawHold.Sample {
        GyroYawHold.Sample(time: t, isNormal: normal, gapDeg: normal ? gap : nil,
                           azimuthRateDps: normal ? rate : .nan)
    }

    /// Feed `count` frames `step` apart from `t0`, D given by `gapAt(t)`, and return every event.
    @discardableResult
    private func feed(_ hold: inout GyroYawHold,
                      from t0: Double, count: Int, step: Double = 0.05,
                      normal: Bool = true, rate: Double = 1.0,
                      gapAt: (Double) -> Double?) -> [GyroYawHold.Event] {
        var events: [GyroYawHold.Event] = []
        for i in 0..<count {
            let t = t0 + Double(i) * step
            if let event = hold.add(sample(t, normal: normal, gap: gapAt(t), rate: rate)) {
                events.append(event)
            }
        }
        return events
    }

    @discardableResult
    private func feed(_ hold: inout GyroYawHold,
                      from t0: Double, count: Int, step: Double = 0.05,
                      normal: Bool = true, rate: Double = 1.0,
                      gap: Double?) -> [GyroYawHold.Event] {
        feed(&hold, from: t0, count: count, step: step, normal: normal, rate: rate, gapAt: { _ in gap })
    }

    /// Tracking lost from `t0` for `count` frames.
    @discardableResult
    private func lose(_ hold: inout GyroYawHold, from t0: Double, count: Int) -> [GyroYawHold.Event] {
        feed(&hold, from: t0, count: count, normal: false, gap: nil)
    }

    private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(AngularResponse.signedDelta(a, b)) <= tolerance
    }

    // MARK: - Glitch hold

    /// The FL403 shape: steady before, an episode, steady after with D 30° on. One event, applied,
    /// carrying exactly the step — and applying it as the caller does keeps the heading continuous.
    @Test func aStepAcrossAnEpisodeIsUndone() throws {
        var hold = GyroYawHold()
        var events = feed(&hold, from: 0.01, count: 40, gap: 10)   // 0.01 … 1.96
        events += lose(&hold, from: 2.01, count: 20)                // 2.01 … 2.96
        events += feed(&hold, from: 3.01, count: 40, gap: 40)       // 3.01 … 4.96

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .glitch)
        #expect(event.refusal == nil)
        #expect(near(event.deltaDeg, 30))
        #expect(near(event.gapBeforeDeg, 10))
        #expect(near(event.gapAfterDeg, 40))
        #expect(abs(event.episodeSeconds - 1.0) < 1e-9)

        // Heading = arAz + offset = D + cmYaw + offset. The phone did not turn, so it must not move.
        let cmYaw = 100.0, offset = 50.0
        let headingBefore = 10 + cmYaw + offset
        let headingAfter = 40 + cmYaw + AngularResponse.wrappedDeg(offset - event.deltaDeg)
        #expect(near(headingBefore, headingAfter))
    }

    /// D walking 15° over thirty seconds of normal tracking is drift, and is left alone; an episode
    /// that comes back within a degree or so of where it left is refused as small.
    @Test func slowDriftIsNotTouched() throws {
        var hold = GyroYawHold()
        let drift = feed(&hold, from: 0.01, count: 600, gapAt: { t in 0.5 * t })   // to 29.96 s
        #expect(drift.isEmpty)

        var events = lose(&hold, from: 30.01, count: 10)
        events += feed(&hold, from: 30.51, count: 40, gap: 16.0)
        #expect(events.count == 1)
        let event = try #require(events.first)
        // Before: the median of the last quarter-second of the walk, about 14.9.
        #expect(event.refusal == .small)
        #expect(abs(event.deltaDeg) < 3)
        #expect(event.deltaDeg > 0)
    }

    /// The gate itself: 15°/s either way passes, anything faster or unknown does not.
    @Test func steadinessGateIsFifteenDegreesPerSecond() {
        let hold = GyroYawHold()
        #expect(hold.isSteady(15))
        #expect(hold.isSteady(-15))
        #expect(hold.isSteady(0))
        #expect(!hold.isSteady(15.01))
        #expect(!hold.isSteady(-40))
        #expect(!hold.isSteady(.nan))
    }

    /// A phone still being turned after the episode never gives a steady "after", so the step is
    /// refused once the wait runs out — not applied from a reading timing could have bent.
    @Test func aStepWhileSpinningAfterIsRefused() throws {
        var hold = GyroYawHold()
        var events = feed(&hold, from: 0.01, count: 40, gap: 10)
        events += lose(&hold, from: 2.01, count: 20)
        events += feed(&hold, from: 3.01, count: 60, rate: 60, gap: 40)   // spinning to 5.96

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.refusal == .unsteadyAfter)
        #expect(event.deltaDeg.isNaN)
    }

    /// The same at the other end: no steady reading before the episode, so nothing to compare with.
    @Test func aStepWhileSpinningBeforeIsRefused() throws {
        var hold = GyroYawHold()
        var events = feed(&hold, from: 0.01, count: 100, rate: 60, gap: 10)   // spinning to 4.96
        events += lose(&hold, from: 5.01, count: 20)
        events += feed(&hold, from: 6.01, count: 40, gap: 40)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.refusal == .unsteadyBefore)
    }

    /// A steady reading too long before the episode does not stand in for the moment before it.
    @Test func aReferenceOlderThanTwoSecondsIsRefused() throws {
        var hold = GyroYawHold()
        feed(&hold, from: 0.01, count: 20, gap: 10)                 // steady to 0.96
        feed(&hold, from: 1.01, count: 80, rate: 60, gap: 10)       // spinning to 4.96
        var events = lose(&hold, from: 5.01, count: 20)
        events += feed(&hold, from: 6.01, count: 40, gap: 40)

        let event = try #require(events.first)
        #expect(event.refusal == .unsteadyBefore)
    }

    /// Tracking that flaps back to limited before it has held for the settle time is one episode:
    /// the step is measured from before the first loss to after the last.
    @Test func flappingEpisodesAreOne() throws {
        var hold = GyroYawHold()
        var events = feed(&hold, from: 0.01, count: 20, gap: 10)    // to 0.96
        events += lose(&hold, from: 1.01, count: 10)                // 1.01 … 1.46
        events += feed(&hold, from: 1.51, count: 5, gap: 25)        // 1.51 … 1.71, inside the settle
        events += lose(&hold, from: 1.76, count: 10)                // 1.76 … 2.21
        events += feed(&hold, from: 2.26, count: 40, gap: 40)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.refusal == nil)
        #expect(near(event.deltaDeg, 30))
        #expect(abs(event.episodeSeconds - (2.26 - 1.01)) < 1e-9)
    }

    /// An alignment taken during an episode already describes the world as it came back, so the step
    /// is refused rather than applied on top of it, and K pairs that alignment with the D after.
    @Test func anAlignmentDuringAnEpisodeSupersedesIt() throws {
        var hold = GyroYawHold()
        feed(&hold, from: 0.01, count: 40, gap: 10)
        hold.recordAlignment(offsetDeg: 20, source: .seed)
        let first = try #require(hold.anchorConstantDeg)
        #expect(near(first, 30))

        var events = lose(&hold, from: 2.01, count: 10)
        hold.recordAlignment(offsetDeg: 30, source: .anchor)
        events += feed(&hold, from: 2.51, count: 40, gap: 50)

        let event = try #require(events.first)
        #expect(event.refusal == .realigned)
        #expect(near(event.deltaDeg, 40))
        let second = try #require(hold.anchorConstantDeg)
        #expect(near(second, 80))
        #expect(hold.anchorSource == .anchor)
    }

    /// With no reading to pair it with yet, an alignment waits for the first one.
    @Test func anAlignmentWaitsForAReading() throws {
        var hold = GyroYawHold()
        hold.recordAlignment(offsetDeg: -146.1, source: .seed)
        #expect(!hold.hasAnchorConstant)
        feed(&hold, from: 0.01, count: 1, gap: 0.7)
        let k = try #require(hold.anchorConstantDeg)
        #expect(near(k, -145.4))
    }

    // MARK: - Reset carry

    /// K = offset + D at the seed; after a reset, the first steady normal frame gives K − D. Frames
    /// from the old world still in flight, and frames while the phone is turning, are passed over.
    @Test func theResetCarryGivesKMinusD() throws {
        var hold = GyroYawHold()
        feed(&hold, from: 0.01, count: 20, gap: 0.7)
        hold.recordAlignment(offsetDeg: -146.1, source: .seed)
        let k = try #require(hold.anchorConstantDeg)
        #expect(near(k, -145.4))

        hold.worldDidReset(offsetBeforeDeg: -146.1, carry: true)
        #expect(hold.isCarryPending)
        // Rendered from the world before the reset and processed after it.
        #expect(feed(&hold, from: 1.01, count: 1, gap: 0.7).isEmpty)
        #expect(lose(&hold, from: 1.11, count: 28).isEmpty)                    // 1.11 … 2.46
        #expect(feed(&hold, from: 2.51, count: 6, rate: 40, gap: 37).isEmpty)  // turning
        let events = feed(&hold, from: 2.81, count: 1, gap: 37)

        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .reset)
        #expect(event.refusal == nil)
        let carried = try #require(event.carriedOffsetDeg)
        #expect(near(carried, -145.4 - 37))
        #expect(near(event.offsetBeforeDeg, -146.1))
        #expect(near(event.gapBeforeDeg, 0.7))
        #expect(near(event.gapAfterDeg, 37))
        #expect(near(event.deltaDeg, 36.3))
        #expect(abs(event.episodeSeconds - (2.81 - 1.11)) < 1e-9)
        #expect(event.anchorSource == .seed)
        #expect(!hold.isCarryPending)

        // Placed with the carried offset, the heading is cmYaw + K whatever the new world's D.
        let cmYaw = -12.0
        let arAz = 37 + cmYaw
        #expect(near(arAz + carried, cmYaw - 145.4))
    }

    /// No K, no carry — and a reset is never mistaken for a glitch, however far D moves across it.
    @Test func noAnchorNoCarryAndAResetIsNotAGlitch() {
        var hold = GyroYawHold()
        hold.worldDidReset(offsetBeforeDeg: .nan, carry: true)
        #expect(!hold.isCarryPending)

        var events = feed(&hold, from: 0.01, count: 40, gap: 5)
        hold.worldDidReset(offsetBeforeDeg: .nan, carry: false)
        events += lose(&hold, from: 2.01, count: 30)
        events += feed(&hold, from: 3.51, count: 60, gap: 120)
        #expect(events.isEmpty)
    }

    /// Giving up leaves the reset to finish without a carry.
    @Test func anAbandonedCarryCarriesNothing() {
        var hold = GyroYawHold()
        feed(&hold, from: 0.01, count: 20, gap: 0.7)
        hold.recordAlignment(offsetDeg: 10, source: .anchor)
        hold.worldDidReset(offsetBeforeDeg: 10, carry: true)
        #expect(hold.abandonCarry())
        #expect(!hold.isCarryPending)
        #expect(!hold.abandonCarry())

        var events = lose(&hold, from: 1.01, count: 20)
        events += feed(&hold, from: 2.01, count: 40, gap: 37)
        #expect(events.isEmpty)
        // K itself survives: it describes CoreMotion and true north, not this world.
        #expect(hold.hasAnchorConstant)
    }

    /// Device motion restarting voids K, so the next reset seeds afresh.
    @Test func invalidatingDropsTheAnchorConstant() {
        var hold = GyroYawHold()
        feed(&hold, from: 0.01, count: 20, gap: 0.7)
        hold.recordAlignment(offsetDeg: 10, source: .seed)
        #expect(hold.hasAnchorConstant)
        hold.invalidate()
        #expect(!hold.hasAnchorConstant)
        hold.worldDidReset(offsetBeforeDeg: 10, carry: true)
        #expect(!hold.isCarryPending)
    }

    // MARK: - The ±180° seam

    /// D from 178 to −177 is a 5° step, not −355°; the offset it moves wraps; a carry wraps too.
    @Test func stepsAndCarriesTakeTheShortWayAcrossTheSeam() throws {
        var hold = GyroYawHold()
        var events = feed(&hold, from: 0.01, count: 40, gap: 178)
        events += lose(&hold, from: 2.01, count: 10)
        events += feed(&hold, from: 2.51, count: 40, gap: -177)
        let step = try #require(events.first)
        #expect(step.refusal == nil)
        #expect(near(step.deltaDeg, 5))
        #expect(abs(step.deltaDeg - 5) < 1e-9)
        // An offset of −178 less 5 is 177, not −183.
        let held = AngularResponse.wrappedDeg(-178 - step.deltaDeg)
        #expect(abs(held - 177) < 1e-9)

        // K = 170 + 20 = 190, i.e. −170; a new world reading D = −175 needs 5.
        var carry = GyroYawHold()
        feed(&carry, from: 0.01, count: 20, gap: 20)
        carry.recordAlignment(offsetDeg: 170, source: .anchor)
        let k = try #require(carry.anchorConstantDeg)
        #expect(abs(k - (-170)) < 1e-9)
        carry.worldDidReset(offsetBeforeDeg: 170, carry: true)
        lose(&carry, from: 1.01, count: 10)
        let carriedEvent = try #require(feed(&carry, from: 1.51, count: 1, gap: -175).first)
        let carried = try #require(carriedEvent.carriedOffsetDeg)
        #expect(abs(carried - 5) < 1e-9)
    }

    /// A steady reference straddling the seam medians to ±180, not to 0, so a return to −179 is a
    /// one-degree non-event rather than a 180° step.
    @Test func aReferenceStraddlingTheSeamStaysOnIt() throws {
        var hold = GyroYawHold()
        var events = feed(&hold, from: 0.01, count: 40, gapAt: { t in
            Int((t * 20).rounded()) % 2 == 0 ? 179.8 : -179.9
        })
        events += lose(&hold, from: 2.01, count: 10)
        events += feed(&hold, from: 2.51, count: 40, gap: -179.0)
        let event = try #require(events.first)
        #expect(abs(abs(event.gapBeforeDeg) - 180) < 0.5)
        #expect(event.refusal == .small)
        #expect(abs(event.deltaDeg) < 2)
    }

    // MARK: - CoreMotion geometry

    /// CoreMotion's matrix and gravity for a phone whose back camera looks along `headingDeg`,
    /// clockwise from the reference X axis seen from above, tilted up by `pitchDeg` and rolled about
    /// the line of sight by `rollDeg`. Built from the device axes in reference coordinates (Z up):
    /// device X is the screen's right, Y its top, Z out of the screen — so the camera looks along −Z.
    /// `rows` true gives the reading where the matrix takes reference coordinates to device ones
    /// (device axes as rows); false gives its transpose.
    private func attitude(headingDeg: Double, pitchDeg: Double = 0, rollDeg: Double = 0,
                          rows: Bool = true) -> (GyroYawHold.Rotation, SIMD3<Double>) {
        let psi = headingDeg * .pi / 180, theta = pitchDeg * .pi / 180, phi = rollDeg * .pi / 180
        let look = SIMD3<Double>(cos(theta) * cos(psi), -cos(theta) * sin(psi), sin(theta))
        let right0 = SIMD3<Double>(-sin(psi), -cos(psi), 0)
        let back = -look
        // up0 = (−look) × right0, so (right0, up0, −look) is right-handed.
        let up0 = SIMD3<Double>(back.y * right0.z - back.z * right0.y,
                                back.z * right0.x - back.x * right0.z,
                                back.x * right0.y - back.y * right0.x)
        let x = cos(phi) * right0 + sin(phi) * up0
        let y = -sin(phi) * right0 + cos(phi) * up0
        let z = back
        // Gravity, (0, 0, −1) in the reference frame, in device coordinates.
        let gravity = SIMD3<Double>(-x.z, -y.z, -z.z)
        let m = rows
            ? GyroYawHold.Rotation(m11: x.x, m12: x.y, m13: x.z,
                                   m21: y.x, m22: y.y, m23: y.z,
                                   m31: z.x, m32: z.y, m33: z.z)
            : GyroYawHold.Rotation(m11: x.x, m12: y.x, m13: z.x,
                                   m21: x.y, m22: y.y, m23: z.y,
                                   m31: x.z, m32: y.z, m33: z.z)
        return (m, gravity)
    }

    private func azimuth(_ input: (GyroYawHold.Rotation, SIMD3<Double>)) -> Double? {
        GyroYawHold.cameraAzimuthDeg(rotation: input.0, gravity: input.1)
    }

    /// Held upright in portrait, the azimuth is the heading the camera faces, whichever way the
    /// matrix is read.
    @Test func uprightPortraitReadsTheCameraHeadingEitherWay() throws {
        for heading in [0.0, 37.0, 90.0, 179.0, -120.0, -45.5] {
            let asRows = try #require(azimuth(attitude(headingDeg: heading, rows: true)))
            let asColumns = try #require(azimuth(attitude(headingDeg: heading, rows: false)))
            #expect(near(asRows, heading, 1e-9))
            #expect(near(asColumns, heading, 1e-9))
        }
    }

    /// A pan to the right raises it by the pan, in the same sense as ARKit's azimuth.
    @Test func aClockwisePanRaisesTheAzimuth() throws {
        let before = try #require(azimuth(attitude(headingDeg: 10, pitchDeg: 15, rollDeg: 5)))
        let after = try #require(azimuth(attitude(headingDeg: 35, pitchDeg: 15, rollDeg: 5)))
        #expect(near(AngularResponse.signedDelta(before, after), 25, 1e-9))
    }

    /// Rolling the phone about the line of sight — portrait, either landscape, anything between —
    /// and tilting it up do not move the azimuth. Euler yaw would, near gimbal lock.
    @Test func rollAndPitchDoNotMoveTheAzimuth() throws {
        for roll in [0.0, 90.0, -90.0, 30.0, 180.0] {
            for pitch in [-30.0, 0.0, 20.0, 60.0] {
                for rows in [true, false] {
                    let value = try #require(azimuth(attitude(headingDeg: 64, pitchDeg: pitch,
                                                              rollDeg: roll, rows: rows)))
                    #expect(near(value, 64, 1e-9))
                }
            }
        }
    }

    /// Within about 12° of vertical the line of sight has no horizontal direction worth reading, the
    /// same floor ARKit's azimuth uses.
    @Test func aNearVerticalCameraHasNoAzimuth() {
        #expect(azimuth(attitude(headingDeg: 64, pitchDeg: 85)) == nil)
        #expect(azimuth(attitude(headingDeg: 64, pitchDeg: -85)) == nil)
        #expect(azimuth(attitude(headingDeg: 64, pitchDeg: 75)) != nil)
    }

    /// Gravity that fits neither reading is a broken input, not an answer.
    @Test func inconsistentGravityIsRefused() {
        let (matrix, _) = attitude(headingDeg: 0)
        // Upright, true gravity is (0, −1, 0); claim the phone is lying flat instead.
        #expect(GyroYawHold.cameraAzimuthDeg(rotation: matrix,
                                             gravity: SIMD3<Double>(0, 0, -1)) == nil)
        #expect(GyroYawHold.cameraAzimuthDeg(rotation: matrix,
                                             gravity: SIMD3<Double>(0, 0, 0)) == nil)
    }

    /// The rate the steadiness gate reads: signed, the short way across the seam, and NaN for a gap
    /// that is no gap or too long to mean a rate.
    @Test func azimuthRateIsSignedAndShortWay() {
        #expect(abs(GyroYawHold.azimuthRateDps(fromDeg: 350, toDeg: 10, seconds: 0.05) - 400) < 1e-9)
        #expect(abs(GyroYawHold.azimuthRateDps(fromDeg: 10, toDeg: 350, seconds: 0.05) + 400) < 1e-9)
        #expect(abs(GyroYawHold.azimuthRateDps(fromDeg: 20, toDeg: 20.5, seconds: 0.05) - 10) < 1e-9)
        #expect(GyroYawHold.azimuthRateDps(fromDeg: 20, toDeg: 21, seconds: 0).isNaN)
        #expect(GyroYawHold.azimuthRateDps(fromDeg: 20, toDeg: 21, seconds: 1.0).isNaN)
        #expect(GyroYawHold.azimuthRateDps(fromDeg: .nan, toDeg: 21, seconds: 0.05).isNaN)
    }
}
