//
//  HUDSmoothingTests.swift
//  Tally-HoTests
//
//  Issue #15: a smoother HUD, and no calibration screen in flight.
//
//  - CoreMotion at 100 Hz: everything that counted samples now counts time, with the same results at
//    20 Hz input and the right ones at 100 Hz.
//  - The heading rose paired with its own frame's placement offset.
//  - The latest-wins HUD mailbox, and the batched yaw-hold hop that drops nothing.
//  - The tapes: eased per frame, redrawn only when the picture changes.
//  - The launch calibration screen leaving on an airborne fix.
//

import Testing
import Foundation
import CoreGraphics
import simd
@testable import Tally_Ho

struct HUDSmoothingTests {

    // MARK: - CoreMotion windows in time

    private func stream(rateHz: Double, seconds: Double, yaw: (Double) -> Double) -> [(t: TimeInterval, yawDeg: Double)] {
        (0..<Int(seconds * rateHz)).map { i in
            let t = 100.0 + Double(i) / rateHz
            return (t: t, yawDeg: AngularResponse.wrappedDeg(yaw(t)))
        }
    }

    /// At 20 Hz the rate's baseline is the previous sample, exactly as before; at 100 Hz it is the
    /// newest sample at least 40 ms back, not the one 10 ms back.
    @Test func theRateBaselineIsTimeNotSamples() throws {
        let times20 = stream(rateHz: 20, seconds: 1, yaw: { _ in 0 }).map(\.t)
        #expect(GyroYawHold.rateBaselineIndex(times20) == times20.count - 2)
        let times100 = stream(rateHz: 100, seconds: 1, yaw: { _ in 0 }).map(\.t)
        let i = try #require(GyroYawHold.rateBaselineIndex(times100))
        let last = try #require(times100.last)
        #expect(last - times100[i] >= GyroYawHold.minRateBaselineSeconds)
        #expect(last - times100[i + 1] < GyroYawHold.minRateBaselineSeconds)
        #expect(GyroYawHold.rateBaselineIndex([1.0]) == nil)
        #expect(GyroYawHold.rateBaselineIndex([1.0, 1.01]) == 0)     // nothing 40 ms back: the oldest
    }

    /// At 20 Hz the baseline rate is the old consecutive-sample rate to the bit, on a stream with a gap
    /// in it (the history clears on a missing yaw, as before).
    @Test func atTwentyHertzTheRateIsUnchanged() {
        var history: [(t: TimeInterval, yawDeg: Double)] = []
        var previous: (t: TimeInterval, yaw: Double) = (t: .nan, yaw: .nan)
        for i in 0..<60 {
            let t = 50.0 + Double(i) * 0.05
            let yaw: Double = (i == 23) ? .nan : AngularResponse.wrappedDeg(170 + 12 * sin(t))
            if yaw.isFinite {
                history.append((t: t, yawDeg: yaw))
                history = GyroYawHold.trimmedMotionHistory(history, time: { $0.t })
            } else {
                history.removeAll()
            }
            let old = GyroYawHold.azimuthRateDps(fromDeg: previous.yaw, toDeg: yaw, seconds: t - previous.t)
            let new = GyroYawHold.baselineAzimuthRateDps(history)
            if old.isNaN {
                #expect(new.isNaN)
            } else {
                #expect(new == old)
            }
            previous = (t: t, yaw: yaw)
        }
    }

    /// At 100 Hz, with ±0.05° of sample noise on a 10°/s turn, a 10 ms difference reads the rate up to
    /// 10°/s wrong; the 40 ms baseline stays within about 3°/s.
    @Test func atOneHundredHertzTheRateIsNotNoise() {
        var history: [(t: TimeInterval, yawDeg: Double)] = []
        var worstBaseline = 0.0, worstConsecutive = 0.0
        var previous: (t: TimeInterval, yaw: Double)?
        for i in 0..<200 {
            let t = 10.0 + Double(i) * 0.01
            let noise = (i % 2 == 0) ? 0.05 : -0.05
            let yaw = AngularResponse.wrappedDeg(10 * t + noise)
            history.append((t: t, yawDeg: yaw))
            history = GyroYawHold.trimmedMotionHistory(history, time: { $0.t })
            if i > 10 {
                worstBaseline = max(worstBaseline, abs(GyroYawHold.baselineAzimuthRateDps(history) - 10))
                if let previous {
                    let consecutive = GyroYawHold.azimuthRateDps(fromDeg: previous.yaw, toDeg: yaw,
                                                                 seconds: t - previous.t)
                    worstConsecutive = max(worstConsecutive, abs(consecutive - 10))
                }
            }
            previous = (t: t, yaw: yaw)
        }
        #expect(worstConsecutive > 9)
        #expect(worstBaseline < 3)
    }

    /// The history is 0.4 s whatever the rate: at 20 Hz every frame time it can be asked for interpolates
    /// exactly as the old eight-sample history did; at 100 Hz it is 41 samples, not eight (80 ms).
    @Test func theHistoryIsFourTenthsOfASecondAtAnyRate() throws {
        let samples = stream(rateHz: 20, seconds: 3, yaw: { 30 * sin($0) })
        var timed: [(t: TimeInterval, yawDeg: Double)] = []
        var counted: [(t: TimeInterval, yawDeg: Double)] = []
        for sample in samples {
            timed.append(sample)
            timed = GyroYawHold.trimmedMotionHistory(timed, time: { $0.t })
            counted.append(sample)
            if counted.count > 8 { counted.removeFirst() }
            let newest = sample.t
            for lag in stride(from: -0.08, through: 0.33, by: 0.017) {
                let a = GyroYawHold.interpolatedYawDeg(timed, at: newest - lag)
                let b = GyroYawHold.interpolatedYawDeg(counted, at: newest - lag)
                #expect(a == b)
            }
        }
        var fast: [(t: TimeInterval, yawDeg: Double)] = []
        for sample in stream(rateHz: 100, seconds: 2, yaw: { _ in 0 }) {
            fast.append(sample)
            fast = GyroYawHold.trimmedMotionHistory(fast, time: { $0.t })
        }
        // 0.4 s of 10 ms samples: 40 or 41 of them, as the boundary sample's rounding falls.
        #expect(fast.count >= 40 && fast.count <= 41)
        let span = try #require(fast.last).t - (try #require(fast.first)).t
        #expect(span >= 0.39 - 1e-9 && span <= 0.4 + 1e-9)
    }

    /// Extrapolating past the newest 100 Hz sample uses the 40 ms (or, as rounding falls, 50 ms) rate:
    /// alternating ±0.05° noise moves a 50 ms extrapolation by at most 0.15°, where the 10 ms pair would
    /// move it by 0.55°.
    @Test func extrapolationAtOneHundredHertzIsQuiet() throws {
        let samples: [(t: TimeInterval, yawDeg: Double)] = (0..<40).map { i in
            let t = Double(i) * 0.01
            return (t: t, yawDeg: 20 * t + ((i % 2 == 0) ? 0.05 : -0.05))
        }
        let last = try #require(samples.last)
        let ahead = try #require(GyroYawHold.interpolatedYawDeg(samples, at: last.t + 0.05))
        let truth = 20 * (last.t + 0.05)
        #expect(abs(ahead - truth) < 0.2)
    }

    /// The sign check is weighted by time, so a 90° pan read at 20 Hz and at 100 Hz turns the same
    /// number of degrees on the agreeing side.
    @Test func theSignCheckSeesTheSameTurningAtAnyRate() {
        func agreeing(rateHz: Double) -> Double {
            var guardian = GyroYawHold.SignGuard()
            var history: [(t: TimeInterval, yawDeg: Double)] = []
            var previousTime = Double.nan
            for i in 0..<Int(3 * rateHz) {
                let t = Double(i) / rateHz
                let yaw = AngularResponse.wrappedDeg(30 * t)          // 30°/s for 3 s
                history.append((t: t, yawDeg: yaw))
                history = GyroYawHold.trimmedMotionHistory(history, time: { $0.t })
                guardian.add(azimuthRateDps: GyroYawHold.baselineAzimuthRateDps(history),
                             witnessRateDps: 30, seconds: t - previousTime)
                previousTime = t
            }
            return guardian.agreeingDeg
        }
        let slow = agreeing(rateHz: 20), fast = agreeing(rateHz: 100)
        #expect(abs(slow - 88.5) < 1e-6)                             // 59 samples after the first × 1.5°
        #expect(abs(fast - slow) < 2)
    }

    /// The attitude's extrapolation takes the same time baseline: at 100 Hz a steady 20°/s turn
    /// extrapolates 50 ms ahead to within a hundredth of a degree.
    @Test func attitudeExtrapolationUsesTheTimeBaseline() throws {
        func attitude(_ deg: Double) -> simd_quatd {
            simd_quatd(angle: -deg * .pi / 180, axis: SIMD3<Double>(0, 0, 1))
        }
        let samples: [(t: TimeInterval, q: simd_quatd)] = (0..<40).map { i in
            let t = Double(i) * 0.01
            return (t: t, q: attitude(20 * t))
        }
        let ahead = try #require(AttitudeHold.interpolatedAttitude(samples, at: 0.44))
        let expected = attitude(20 * 0.44)
        let error = (ahead * expected.inverse).angle * 180 / .pi
        #expect(min(error, 360 - error) < 0.01)
    }

    // MARK: - The heading rose and its own frame's offset

    /// Under the attitude hold the rose's forward is `R_true`'s, built against the frame's placement
    /// offset; adding that same offset gives `cmYaw + K` whatever the offset is. Adding the offset of
    /// another frame — what main used to read — is off by exactly the difference.
    @Test func theRoseIsPairedWithItsOwnFramesOffset() throws {
        let upright = simd_double3x3(columns: (SIMD3<Double>(0, -1, 0), SIMD3<Double>(0, 0, 1),
                                               SIMD3<Double>(-1, 0, 0)))
        let attitude = simd_double3x3(simd_quatd(angle: -40 * .pi / 180, axis: SIMD3<Double>(0, 0, 1))) * upright
        let k = 128.2
        for offset in [-150.0, -12.5, 0, 33.3, 179.0] {
            let truth = AttitudeHold.trueCameraToWorld(deviceToReference: attitude, anchorConstantDeg: k,
                                                       placementOffsetDeg: offset)
            let raw = try #require(AttitudeHold.azimuthDeg(-truth.columns.2))
            let rose = try #require(HUDFrame.roseHeadingDeg(rawAzimuthDeg: raw, placementOffsetDeg: offset,
                                                            aligned: true))
            #expect(abs(AngularResponse.signedDelta(40 + k, rose)) < 1e-9)
            let stale = try #require(HUDFrame.roseHeadingDeg(rawAzimuthDeg: raw, placementOffsetDeg: offset - 2,
                                                             aligned: true))
            #expect(abs(AngularResponse.signedDelta(rose, stale) - (-2)) < 1e-9)
        }
        #expect(HUDFrame.roseHeadingDeg(rawAzimuthDeg: 10, placementOffsetDeg: 5, aligned: false) == nil)
        let wrapped = HUDFrame.roseHeadingDeg(rawAzimuthDeg: 350, placementOffsetDeg: 20, aligned: true)
        #expect(wrapped.map { abs($0 - 10) < 1e-9 } == true)
    }

    @Test func theArrowShowsOnlyWithTheHorizonOffScreen() {
        let height: CGFloat = 800
        #expect(HUDFrame.horizonVisible((CGPoint(x: 0, y: 400), CGPoint(x: 100, y: 410)), viewHeight: height))
        #expect(HUDFrame.horizonVisible((CGPoint(x: 0, y: -15), CGPoint(x: 100, y: -900)), viewHeight: height))
        #expect(!HUDFrame.horizonVisible((CGPoint(x: 0, y: -25), CGPoint(x: 100, y: -30)), viewHeight: height))
        #expect(!HUDFrame.horizonVisible((CGPoint(x: 0, y: 825), CGPoint(x: 100, y: 900)), viewHeight: height))
    }

    // MARK: - The mailboxes

    /// Latest wins: the first post schedules, later ones replace the waiting value without scheduling,
    /// and the drain takes only the newest.
    @Test func theHUDMailboxKeepsOnlyTheLatestFrame() {
        let mailbox = MainThreadMailbox.Latest<Int>()
        let first = mailbox.post(1)
        let second = mailbox.post(2)
        let third = mailbox.post(3)
        #expect(first)
        #expect(!second)
        #expect(!third)
        #expect(mailbox.take() == 3)
        #expect(mailbox.take() == nil)
        let again = mailbox.post(4)
        #expect(again)
    }

    /// Batched: every value, in order, one schedule per drain — from many threads at once too.
    @Test func theYawHoldBatchDropsNothing() {
        let batch = MainThreadMailbox.Batch<Int>()
        let first = batch.post(1)
        let second = batch.post(2)
        #expect(first)
        #expect(!second)
        #expect(batch.takeAll() == [1, 2])
        #expect(batch.takeAll().isEmpty)

        let lock = NSLock()
        var schedules = 0
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            if batch.post(i) {
                lock.lock()
                schedules += 1
                lock.unlock()
            }
        }
        #expect(schedules == 1)
        let drained = batch.takeAll()
        #expect(drained.count == 1000)
        #expect(Set(drained).count == 1000)
    }

    // MARK: - The tapes

    private func easing() -> TapeEasing {
        TapeEasing(timeConstant: 0.25, snapDistance: 50, settleEpsilon: 0.05)
    }

    /// The first reading snaps; the next eases, 63% of the way in one time constant, and settles on
    /// the target exactly.
    @Test func aTapeEasesTowardTheReading() throws {
        var tape = easing()
        tape.setTarget(250)
        #expect(tape.value == 250)
        #expect(tape.isSettled)
        tape.setTarget(260)
        #expect(tape.value == 250)
        var shown = 250.0
        for _ in 0..<15 { shown = try #require(tape.step(dt: 1.0 / 60)) }   // 0.25 s
        #expect(abs(shown - (250 + 10 * (1 - exp(-1)))) < 1e-6)
        for _ in 0..<300 { shown = try #require(tape.step(dt: 1.0 / 60)) }
        #expect(shown == 260)
        #expect(tape.isSettled)
    }

    /// The easing is in time, not frames: 60 and 120 Hz displays show the same value at the same moment.
    @Test func easingIsFrameRateIndependent() throws {
        var a = easing(), b = easing()
        a.setTarget(100); b.setTarget(100)
        a.setTarget(130); b.setTarget(130)
        var va = 0.0, vb = 0.0
        for _ in 0..<30 { va = try #require(a.step(dt: 1.0 / 60)) }
        for _ in 0..<60 { vb = try #require(b.step(dt: 1.0 / 120)) }
        #expect(abs(va - vb) < 1e-9)
    }

    /// A jump bigger than the tape's half-range — a source switch — snaps instead of scrolling.
    @Test func aBigJumpSnaps() {
        var tape = easing()
        tape.setTarget(100)
        tape.setTarget(400)
        #expect(tape.value == 400)
    }

    /// A tape is redrawn only when the picture changes: the scale moving a quarter-pixel, or the readout's
    /// whole number. Settled, nothing is redrawn.
    @Test func aTapeRedrawsOnlyWhenThePictureChanges() {
        let px = 2.2                                                   // speed tape: 110 pt for 50 kt
        #expect(TapeEasing.needsRedraw(drawn: nil, value: 250, pxPerUnit: px))
        #expect(!TapeEasing.needsRedraw(drawn: 250.0, value: 250.0, pxPerUnit: px))
        #expect(!TapeEasing.needsRedraw(drawn: 250.0, value: 250.1, pxPerUnit: px))   // 0.22 px
        #expect(TapeEasing.needsRedraw(drawn: 250.0, value: 250.12, pxPerUnit: px))   // 0.264 px
        #expect(TapeEasing.needsRedraw(drawn: 250.45, value: 250.52, pxPerUnit: 1))   // 250 → 251
    }

    // MARK: - Calibration in flight

    /// A fix at 50 kt or more shows the phone airborne; slower, or with no valid speed, it does not.
    @Test func theLaunchScreenLeavesOnAnAirborneFix() {
        let kt = 1852.0 / 3600.0
        #expect(CalibrationFlightPolicy.fixShowsFlight(speedMps: 50.1 * kt))
        #expect(CalibrationFlightPolicy.fixShowsFlight(speedMps: 460 * kt))
        #expect(!CalibrationFlightPolicy.fixShowsFlight(speedMps: 49.9 * kt))
        #expect(!CalibrationFlightPolicy.fixShowsFlight(speedMps: -1))
        #expect(!CalibrationFlightPolicy.fixShowsFlight(speedMps: .nan))
    }

    /// The in-session prompts are off in flight, and before the first airborne estimate a fast fix
    /// counts; on the ground, stopped or taxiing, they are as before.
    @Test func thePromptsStayOnTheGround() {
        #expect(CalibrationFlightPolicy.inFlight(airborneEstimate: true, gpsSpeedKt: 0))
        #expect(CalibrationFlightPolicy.inFlight(airborneEstimate: false, gpsSpeedKt: 140))
        #expect(!CalibrationFlightPolicy.inFlight(airborneEstimate: false, gpsSpeedKt: 18))
        #expect(!CalibrationFlightPolicy.inFlight(airborneEstimate: false, gpsSpeedKt: 0))
    }
}
