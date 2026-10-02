//
//  AirHeadingHoldTests.swift
//  Tally-HoTests
//
//  Issue #10: the continuous gyro heading in the air, and the stuck-camera watchdog.
//
//  - `SmoothedGap` (D̄): a one-second circular median of steady readings, frozen while the phone
//    turns fast or tracking is not normal, settled after an episode.
//  - The mode policy: continuous only in the air, with K, an alignment, and the sign check intact;
//    otherwise the step hold exactly as before. The write rule: 20 Hz at most, 0.1° at least.
//  - CoreMotion interpolated to the frame's timestamp.
//  - The watchdog's policy.
//  - The 2026-10-02 climb, row for row: D drifts 33.2° in normal tracking and the held heading
//    stays on the gyro's.
//

import Testing
import Foundation
@testable import Tally_Ho

struct AirHeadingHoldTests {

    private func sample(_ t: Double, normal: Bool = true, gap: Double?, rate: Double = 1.0) -> GyroYawHold.Sample {
        GyroYawHold.Sample(time: t, isNormal: normal, gapDeg: normal ? gap : nil,
                           azimuthRateDps: normal ? rate : .nan)
    }

    /// Feed `count` samples 50 ms apart from `t0`; returns D̄ after the last.
    @discardableResult
    private func feed(_ filter: inout GyroYawHold.SmoothedGap, from t0: Double, count: Int,
                      normal: Bool = true, rate: Double = 1.0,
                      gapAt: (Double) -> Double?) -> Double? {
        var value: Double?
        for i in 0..<count {
            let t = t0 + Double(i) * 0.05
            value = filter.add(sample(t, normal: normal, gap: gapAt(t), rate: rate))
        }
        return value
    }

    private func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
        abs(AngularResponse.signedDelta(a, b)) <= tolerance
    }

    // MARK: - D̄

    /// Drifting at 0.3°/s — the climb's rate — D̄ follows half a second behind: the median of the last
    /// second is its middle.
    @Test func smoothedGapFollowsDriftHalfASecondBehind() throws {
        var filter = GyroYawHold.SmoothedGap()
        let value = feed(&filter, from: 0.01, count: 200, gapAt: { 0.3 * $0 })   // to 9.96 s
        let smoothed = try #require(value)
        #expect(abs(smoothed - 0.3 * (9.96 - 0.5)) < 0.05)
        #expect(!filter.isFrozen)
    }

    /// One wild frame in a steady second does not move the median.
    @Test func oneBadFrameDoesNotMoveIt() throws {
        var filter = GyroYawHold.SmoothedGap()
        feed(&filter, from: 0.01, count: 40, gapAt: { _ in 10 })
        filter.add(sample(2.01, gap: 40))
        let value = feed(&filter, from: 2.06, count: 3, gapAt: { _ in 10 })
        #expect(abs(try #require(value) - 10) < 1e-9)
    }

    /// Faster than 15°/s the readings are timing noise: D̄ holds. Once steady again it follows.
    @Test func freezesWhileThePhoneTurnsFast() throws {
        var filter = GyroYawHold.SmoothedGap()
        feed(&filter, from: 0.01, count: 40, gapAt: { _ in 10 })
        let turning = feed(&filter, from: 2.01, count: 20, rate: 40, gapAt: { _ in 30 })
        #expect(abs(try #require(turning) - 10) < 1e-9)
        #expect(filter.isFrozen)
        let after = feed(&filter, from: 3.01, count: 40, gapAt: { _ in 30 })
        #expect(abs(try #require(after) - 30) < 1e-9)
    }

    /// Through an episode D̄ holds; after it, nothing until tracking has held for the settle, and then
    /// the new world's D alone — never a median of the world before and the world after.
    @Test func freezesThroughAnEpisodeAndSettles() throws {
        var filter = GyroYawHold.SmoothedGap()
        feed(&filter, from: 0.01, count: 40, gapAt: { _ in 10 })
        let during = feed(&filter, from: 2.01, count: 20, normal: false, gapAt: { _ in nil })
        #expect(abs(try #require(during) - 10) < 1e-9)
        let settling = feed(&filter, from: 3.01, count: 9, gapAt: { _ in 40 })   // to 3.41 s
        #expect(abs(try #require(settling) - 10) < 1e-9)
        let settled = feed(&filter, from: 3.56, count: 1, gapAt: { _ in 40 })
        #expect(abs(try #require(settled) - 40) < 1e-9)
    }

    @Test func resetForgetsEverything() {
        var filter = GyroYawHold.SmoothedGap()
        feed(&filter, from: 0.01, count: 40, gapAt: { _ in 10 })
        filter.reset()
        #expect(filter.valueDeg == nil)
        #expect(filter.isFrozen)
    }

    /// Readings straddling ±180 median to the seam, not to 0.
    @Test func smoothedGapStaysOnTheSeam() throws {
        var filter = GyroYawHold.SmoothedGap()
        let value = feed(&filter, from: 0.01, count: 40, gapAt: { t in
            Int((t * 20).rounded()) % 2 == 0 ? 179.8 : -179.9
        })
        #expect(abs(abs(try #require(value)) - 180) < 0.5)
    }

    // MARK: - Mode and writes

    /// Continuous only in the air, with K, an alignment, and the sign check intact. Anything else is
    /// the step hold — on the ground the compass correction owns the offset, unchanged.
    @Test func continuousOnlyInTheAirWithEverythingInPlace() {
        #expect(GyroYawHold.headingMode(airborne: true, hasAnchorConstant: true,
                                        signDisabled: false, aligned: true) == .continuous)
        #expect(GyroYawHold.headingMode(airborne: false, hasAnchorConstant: true,
                                        signDisabled: false, aligned: true) == .step)
        #expect(GyroYawHold.headingMode(airborne: true, hasAnchorConstant: false,
                                        signDisabled: false, aligned: true) == .step)
        #expect(GyroYawHold.headingMode(airborne: true, hasAnchorConstant: true,
                                        signDisabled: true, aligned: true) == .step)
        #expect(GyroYawHold.headingMode(airborne: true, hasAnchorConstant: true,
                                        signDisabled: false, aligned: false) == .step)
    }

    /// K − D̄, wrapped.
    @Test func continuousOffsetIsKMinusSmoothedGapWrapped() {
        #expect(abs(GyroYawHold.continuousOffsetDeg(anchorConstantDeg: 22.7, smoothedGapDeg: 56.6)
                    - (-33.9)) < 1e-9)
        #expect(abs(GyroYawHold.continuousOffsetDeg(anchorConstantDeg: -170, smoothedGapDeg: 20)
                    - 170) < 1e-9)
    }

    /// At most 20 Hz, at least 0.1°, the short way across the seam.
    @Test func writesAtMostTwentyHertzAndOnlyForATenthOfADegree() {
        #expect(!GyroYawHold.shouldWriteOffset(currentDeg: 10, targetDeg: 10.05, sinceLastWriteSeconds: 1))
        #expect(GyroYawHold.shouldWriteOffset(currentDeg: 10, targetDeg: 10.2, sinceLastWriteSeconds: 1))
        #expect(!GyroYawHold.shouldWriteOffset(currentDeg: 10, targetDeg: 12, sinceLastWriteSeconds: 0.03))
        #expect(GyroYawHold.shouldWriteOffset(currentDeg: 10, targetDeg: 12, sinceLastWriteSeconds: 0.05))
        #expect(GyroYawHold.shouldWriteOffset(currentDeg: 179.9, targetDeg: -179.8, sinceLastWriteSeconds: 1))
        #expect(!GyroYawHold.shouldWriteOffset(currentDeg: 179.98, targetDeg: -179.98, sinceLastWriteSeconds: 1))
        #expect(!GyroYawHold.shouldWriteOffset(currentDeg: .nan, targetDeg: 10, sinceLastWriteSeconds: 1))
    }

    /// The whole loop on a phone held still while ARKit drifts 20°: written as the view controller
    /// writes it, the heading the user sees stays on cmYaw + K.
    @Test func theOffsetFollowsKMinusSmoothedGap() throws {
        var filter = GyroYawHold.SmoothedGap()
        let k = 22.7, cmYaw = 110.1
        var offset = -12.0
        var lastWrite = -Double.greatestFiniteMagnitude
        var worst = 0.0
        for i in 0..<400 {   // 20 s at 20 Hz, ARKit drifting −1°/s
            let t = 0.01 + Double(i) * 0.05
            let gap = 48.0 - 1.0 * t
            filter.add(sample(t, gap: gap, rate: 0.5))
            guard let smoothed = filter.valueDeg else { continue }
            let target = GyroYawHold.continuousOffsetDeg(anchorConstantDeg: k, smoothedGapDeg: smoothed)
            if GyroYawHold.shouldWriteOffset(currentDeg: offset, targetDeg: target,
                                             sinceLastWriteSeconds: t - lastWrite) {
                offset = target
                lastWrite = t
            }
            if t > 2 {
                let seen = AngularResponse.wrappedDeg(gap + cmYaw + offset)   // arAz + offset
                worst = max(worst, abs(AngularResponse.signedDelta(cmYaw + k, seen)))
            }
        }
        // Half a second of median lag at 1°/s, plus the 0.1° write step.
        #expect(worst < 0.7)
    }

    // MARK: - CoreMotion at the frame's timestamp

    @Test func interpolatesBetweenSamplesTheShortWay() throws {
        let samples: [(t: TimeInterval, yawDeg: Double)] = [(0.00, 10), (0.05, 12), (0.10, 179), (0.15, -179)]
        #expect(abs(try #require(GyroYawHold.interpolatedYawDeg(samples, at: 0.025)) - 11) < 1e-9)
        let seam = try #require(GyroYawHold.interpolatedYawDeg(samples, at: 0.125))
        #expect(abs(abs(seam) - 180) < 1e-9)
        #expect(abs(try #require(GyroYawHold.interpolatedYawDeg(samples, at: 0.05)) - 12) < 1e-9)
    }

    /// Ahead of the newest sample by up to 0.1 s it extrapolates at the last rate; beyond, nothing.
    @Test func extrapolatesOnlyALittle() throws {
        let samples: [(t: TimeInterval, yawDeg: Double)] = [(0.00, 10), (0.05, 11)]
        #expect(abs(try #require(GyroYawHold.interpolatedYawDeg(samples, at: 0.08)) - 11.6) < 1e-9)
        #expect(GyroYawHold.interpolatedYawDeg(samples, at: 0.2) == nil)
        #expect(abs(try #require(GyroYawHold.interpolatedYawDeg(samples, at: -0.05)) - 10) < 1e-9)
        #expect(GyroYawHold.interpolatedYawDeg(samples, at: -0.5) == nil)
        #expect(GyroYawHold.interpolatedYawDeg([], at: 0) == nil)
    }

    // MARK: - Watchdog

    /// Tick at 4 Hz like the view controller; returns the restarts as (time, seconds stuck), calling
    /// `sessionStarted` for each, as `startARSession` does.
    private func tick(_ dog: inout ARSessionWatchdog, from t0: Double, to t1: Double,
                      notAvailable: Bool = true, visible: Bool = true,
                      paused: Bool = false) -> [(t: Double, stuck: Double)] {
        var restarts: [(t: Double, stuck: Double)] = []
        var t = t0
        while t < t1 {
            if let stuck = dog.update(notAvailable: notAvailable, viewVisible: visible,
                                      sessionPaused: paused, at: t) {
                restarts.append((t: t, stuck: stuck))
                dog.sessionStarted(at: t)
            }
            t += 0.25
        }
        return restarts
    }

    @Test func watchdogRestartsAfterFourSecondsStuck() throws {
        var dog = ARSessionWatchdog()
        dog.sessionStarted(at: 0)
        let restarts = tick(&dog, from: 0.1, to: 5)
        #expect(restarts.count == 1)
        let first = try #require(restarts.first)
        #expect(abs(first.t - 4.1) < 1e-9)
        #expect(abs(first.stuck - 4.1) < 1e-9)
    }

    @Test func watchdogLeavesAHiddenOrPausedSessionAlone() {
        var dog = ARSessionWatchdog()
        dog.sessionStarted(at: 0)
        #expect(tick(&dog, from: 0.1, to: 20, visible: false).isEmpty)
        #expect(tick(&dog, from: 20.1, to: 40, paused: true).isEmpty)
    }

    /// Reaching `limited:initializing` is not stuck: the clock starts again.
    @Test func watchdogClockRestartsWhenTrackingComesBack() {
        var dog = ARSessionWatchdog()
        dog.sessionStarted(at: 0)
        #expect(tick(&dog, from: 0.1, to: 3.1).isEmpty)
        #expect(tick(&dog, from: 3.1, to: 3.6, notAvailable: false).isEmpty)
        #expect(tick(&dog, from: 3.6, to: 7.4).isEmpty)
    }

    /// A camera that will not come back is restarted every ten seconds, not four.
    @Test func watchdogRestartsAtMostOncePerTenSeconds() {
        var dog = ARSessionWatchdog()
        dog.sessionStarted(at: 0)
        let restarts = tick(&dog, from: 0.1, to: 30)
        #expect(restarts.count == 3)
        #expect(restarts.map(\.t).map { ($0 * 100).rounded() / 100 } == [4.1, 14.1, 24.1])
    }

    /// A start of any kind restarts the clock.
    @Test func watchdogCountsFromTheLatestStart() {
        var dog = ARSessionWatchdog()
        dog.sessionStarted(at: 0)
        #expect(tick(&dog, from: 0.1, to: 3.1).isEmpty)
        dog.sessionStarted(at: 3.1)
        #expect(tick(&dog, from: 3.1, to: 7.0).isEmpty)
        #expect(!tick(&dog, from: 7.1, to: 7.5).isEmpty)
    }

    // MARK: - The 2026-10-02 climb

    /// One row of log 4eb7adf9 from 18:36:20.713 to 18:39:31.718: seconds after 18:00 UTC, from the
    /// `time` column (the 0.01 s `t_since_lift_s` puts rows a second apart exactly on the edge of the
    /// one-second window); whether `ar_state` was normal, tracking-state events included; the
    /// `airborne` flag; `ar_heading_deg`; `gyro_az_deg`, which is CoreMotion's yaw in build 391; and
    /// the GPS track.
    private struct Row {
        let t: Double
        let normal: Bool
        let air: Bool
        let az: Double?
        let gyro: Double?
        let trk: Double?
    }

    private static let oct2: [Row] = [
        Row(t: 2180.713, normal: true , air: false, az: 318.9, gyro: -75.8, trk: 308.3),  // 18:36:20.713
        Row(t: 2181.179, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:36:21.179 limited:motion
        Row(t: 2181.713, normal: false, air: false, az: nil, gyro: -73.7, trk: 314.6),  // 18:36:21.713
        Row(t: 2182.713, normal: false, air: false, az: nil, gyro: -70.5, trk: 319.2),  // 18:36:22.713
        Row(t: 2183.713, normal: false, air: false, az: nil, gyro: -64.4, trk: 327.0),  // 18:36:23.713
        Row(t: 2184.974, normal: false, air: false, az: nil, gyro: -52.3, trk: 343.8),  // 18:36:24.974
        Row(t: 2186.213, normal: false, air: false, az: nil, gyro: -36.2, trk: 26.4),  // 18:36:26.213
        Row(t: 2187.233, normal: false, air: false, az: nil, gyro: -20.8, trk: 43.9),  // 18:36:27.233
        Row(t: 2187.673, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:36:27.673 normal
        Row(t: 2188.463, normal: true , air: false, az: 347.7, gyro: 1.4, trk: 72.4),  // 18:36:28.463
        Row(t: 2189.729, normal: true , air: false, az: 0.9, gyro: 24.6, trk: 71.7),  // 18:36:29.729
        Row(t: 2190.962, normal: true , air: false, az: 19.5, gyro: 46.5, trk: 96.7),  // 18:36:30.962
        Row(t: 2191.963, normal: true , air: false, az: 35.7, gyro: 61.1, trk: 117.1),  // 18:36:31.963
        Row(t: 2192.963, normal: true , air: false, az: 69.4, gyro: 73.1, trk: 131.8),  // 18:36:32.963
        Row(t: 2194.213, normal: true , air: false, az: 105.6, gyro: 84.9, trk: 144.1),  // 18:36:34.213
        Row(t: 2195.213, normal: true , air: false, az: 126.0, gyro: 91.8, trk: 145.5),  // 18:36:35.213
        Row(t: 2196.213, normal: true , air: false, az: 135.5, gyro: 95.8, trk: 143.8),  // 18:36:36.213
        Row(t: 2197.466, normal: true , air: false, az: 141.5, gyro: 98.4, trk: 139.6),  // 18:36:37.466
        Row(t: 2198.713, normal: true , air: false, az: 144.4, gyro: 99.4, trk: 131.5),  // 18:36:38.713
        Row(t: 2199.963, normal: true , air: false, az: 146.3, gyro: 101.3, trk: 129.7),  // 18:36:39.963
        Row(t: 2200.963, normal: true , air: false, az: 148.5, gyro: 103.0, trk: 129.7),  // 18:36:40.963
        Row(t: 2202.223, normal: true , air: false, az: 151.5, gyro: 105.0, trk: 134.3),  // 18:36:42.223
        Row(t: 2203.225, normal: true , air: false, az: 153.3, gyro: 106.6, trk: 134.6),  // 18:36:43.225
        Row(t: 2204.469, normal: true , air: false, az: 154.1, gyro: 107.0, trk: 134.3),  // 18:36:44.469
        Row(t: 2205.713, normal: true , air: false, az: 154.7, gyro: 107.5, trk: 133.9),  // 18:36:45.713
        Row(t: 2206.970, normal: true , air: false, az: 154.8, gyro: 107.9, trk: 134.6),  // 18:36:46.970
        Row(t: 2207.971, normal: true , air: false, az: 155.5, gyro: 108.2, trk: 134.6),  // 18:36:47.971
        Row(t: 2209.041, normal: true , air: false, az: 155.3, gyro: 108.3, trk: 134.6),  // 18:36:49.041
        Row(t: 2209.485, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:36:49.485 limited:motion
        Row(t: 2210.229, normal: false, air: false, az: nil, gyro: 107.5, trk: 134.3),  // 18:36:50.229
        Row(t: 2211.463, normal: false, air: false, az: nil, gyro: 107.3, trk: 133.9),  // 18:36:51.463
        Row(t: 2212.123, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:36:52.123 normal
        Row(t: 2212.713, normal: true , air: false, az: 155.9, gyro: 108.1, trk: 133.9),  // 18:36:52.713
        Row(t: 2213.713, normal: true , air: false, az: 157.5, gyro: 108.4, trk: 134.3),  // 18:36:53.713
        Row(t: 2214.729, normal: true , air: false, az: 158.7, gyro: 108.7, trk: 134.3),  // 18:36:54.729
        Row(t: 2215.735, normal: true , air: false, az: 158.9, gyro: 108.5, trk: 134.6),  // 18:36:55.735
        Row(t: 2215.823, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:36:55.823 limited:motion
        Row(t: 2216.973, normal: false, air: false, az: nil, gyro: 107.6, trk: 134.6),  // 18:36:56.973
        Row(t: 2217.176, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:36:57.176 normal
        Row(t: 2218.213, normal: true , air: false, az: 161.1, gyro: 108.5, trk: 133.9),  // 18:36:58.213
        Row(t: 2219.471, normal: true , air: false, az: 161.9, gyro: 108.3, trk: 134.3),  // 18:36:59.471
        Row(t: 2219.873, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:36:59.873 limited:motion
        Row(t: 2220.123, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:37:00.123 normal
        Row(t: 2220.175, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:37:00.175 limited:motion
        Row(t: 2220.323, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:37:00.323 normal
        Row(t: 2220.523, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:37:00.523 limited:motion
        Row(t: 2220.714, normal: false, air: false, az: nil, gyro: 107.9, trk: 134.3),  // 18:37:00.714
        Row(t: 2221.714, normal: false, air: false, az: nil, gyro: 107.3, trk: 134.3),  // 18:37:01.714
        Row(t: 2222.964, normal: false, air: false, az: nil, gyro: 107.2, trk: 134.3),  // 18:37:02.964
        Row(t: 2223.968, normal: false, air: false, az: nil, gyro: 107.7, trk: 133.9),  // 18:37:03.968
        Row(t: 2224.083, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:37:04.083 normal
        Row(t: 2225.214, normal: true , air: false, az: 167.1, gyro: 108.4, trk: 133.9),  // 18:37:05.214
        Row(t: 2226.463, normal: true , air: false, az: 166.6, gyro: 108.0, trk: 133.9),  // 18:37:06.463
        Row(t: 2226.776, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:37:06.776 limited:motion
        Row(t: 2227.472, normal: false, air: false, az: nil, gyro: 107.5, trk: 134.3),  // 18:37:07.472
        Row(t: 2227.584, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:37:07.584 normal
        Row(t: 2228.475, normal: true , air: false, az: 164.8, gyro: 107.7, trk: 134.6),  // 18:37:08.475
        Row(t: 2229.714, normal: true , air: false, az: 164.3, gyro: 108.5, trk: 134.6),  // 18:37:09.714
        Row(t: 2230.964, normal: true , air: false, az: 163.7, gyro: 108.2, trk: 135.0),  // 18:37:10.964
        Row(t: 2232.220, normal: true , air: false, az: 164.3, gyro: 108.3, trk: 135.4),  // 18:37:12.220
        Row(t: 2233.222, normal: true , air: false, az: 164.2, gyro: 108.8, trk: 135.4),  // 18:37:13.222
        Row(t: 2234.229, normal: true , air: false, az: 163.8, gyro: 108.8, trk: 135.4),  // 18:37:14.229
        Row(t: 2235.463, normal: true , air: false, az: 164.2, gyro: 108.6, trk: 135.0),  // 18:37:15.463
        Row(t: 2235.473, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:37:15.473 limited:motion
        Row(t: 2236.023, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:37:16.023 normal
        Row(t: 2236.228, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:37:16.228 limited:motion
        Row(t: 2236.423, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:37:16.423 normal
        Row(t: 2236.467, normal: true , air: false, az: 163.5, gyro: 108.6, trk: 135.4),  // 18:37:16.467
        Row(t: 2236.828, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:37:16.828 limited:motion
        Row(t: 2237.483, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:37:17.483 normal
        Row(t: 2237.490, normal: true , air: false, az: 164.6, gyro: 108.9, trk: 135.4),  // 18:37:17.490
        Row(t: 2238.733, normal: true , air: false, az: 165.3, gyro: 109.7, trk: 135.7),  // 18:37:18.733
        Row(t: 2239.748, normal: true , air: false, az: 165.6, gyro: 109.9, trk: 136.1),  // 18:37:19.748
        Row(t: 2240.981, normal: true , air: false, az: 165.7, gyro: 110.4, trk: 136.4),  // 18:37:20.981
        Row(t: 2241.078, normal: false, air: false, az: nil, gyro: nil, trk: nil),  // 18:37:21.078 limited:motion
        Row(t: 2241.923, normal: true , air: false, az: nil, gyro: nil, trk: nil),  // 18:37:21.923 normal
        Row(t: 2242.214, normal: true , air: false, az: 166.3, gyro: 110.7, trk: 136.8),  // 18:37:22.214
        Row(t: 2243.218, normal: true , air: false, az: 166.3, gyro: 110.8, trk: 136.8),  // 18:37:23.218
        Row(t: 2244.463, normal: true , air: false, az: 166.7, gyro: 111.0, trk: 137.1),  // 18:37:24.463
        Row(t: 2245.464, normal: true , air: true , az: 167.6, gyro: 111.0, trk: 137.1),  // 18:37:25.464
        Row(t: 2246.464, normal: true , air: true , az: 168.6, gyro: 111.4, trk: 137.1),  // 18:37:26.464
        Row(t: 2246.773, normal: false, air: true , az: nil, gyro: nil, trk: nil),  // 18:37:26.773 limited:motion
        Row(t: 2247.173, normal: true , air: true , az: nil, gyro: nil, trk: nil),  // 18:37:27.173 normal
        Row(t: 2247.469, normal: true , air: true , az: 169.3, gyro: 111.8, trk: 137.1),  // 18:37:27.469
        Row(t: 2248.720, normal: true , air: true , az: 169.7, gyro: 112.0, trk: 137.1),  // 18:37:28.720
        Row(t: 2249.970, normal: true , air: true , az: 169.8, gyro: 112.2, trk: 137.1),  // 18:37:29.970
        Row(t: 2250.972, normal: true , air: true , az: 171.0, gyro: 112.1, trk: 137.5),  // 18:37:30.972
        Row(t: 2252.008, normal: true , air: true , az: 171.0, gyro: 112.3, trk: 137.5),  // 18:37:32.008
        Row(t: 2253.214, normal: true , air: true , az: 170.7, gyro: 112.2, trk: 137.5),  // 18:37:33.214
        Row(t: 2253.226, normal: false, air: true , az: nil, gyro: nil, trk: nil),  // 18:37:33.226 limited:motion
        Row(t: 2253.424, normal: true , air: true , az: nil, gyro: nil, trk: nil),  // 18:37:33.424 normal
        Row(t: 2254.214, normal: true , air: true , az: 169.1, gyro: 111.5, trk: 137.8),  // 18:37:34.214
        Row(t: 2255.464, normal: true , air: true , az: 171.5, gyro: 110.8, trk: 137.5),  // 18:37:35.464
        Row(t: 2256.464, normal: true , air: true , az: 169.1, gyro: 110.9, trk: 137.1),  // 18:37:36.464
        Row(t: 2257.714, normal: true , air: true , az: 169.0, gyro: 110.9, trk: 137.1),  // 18:37:37.714
        Row(t: 2258.980, normal: true , air: true , az: 169.1, gyro: 110.8, trk: 137.1),  // 18:37:38.980
        Row(t: 2260.215, normal: true , air: true , az: 168.2, gyro: 110.3, trk: 136.8),  // 18:37:40.215
        Row(t: 2261.471, normal: true , air: true , az: 167.1, gyro: 109.1, trk: 136.4),  // 18:37:41.471
        Row(t: 2262.473, normal: true , air: true , az: 166.8, gyro: 109.1, trk: 136.4),  // 18:37:42.473
        Row(t: 2263.721, normal: true , air: true , az: 167.3, gyro: 109.7, trk: 136.1),  // 18:37:43.721
        Row(t: 2264.964, normal: true , air: true , az: 167.5, gyro: 110.5, trk: 136.1),  // 18:37:44.964
        Row(t: 2265.965, normal: true , air: true , az: 167.7, gyro: 111.1, trk: 135.7),  // 18:37:45.965
        Row(t: 2266.965, normal: true , air: true , az: 169.0, gyro: 111.1, trk: 135.4),  // 18:37:46.965
        Row(t: 2268.214, normal: true , air: true , az: 168.8, gyro: 110.7, trk: 135.7),  // 18:37:48.214
        Row(t: 2269.215, normal: true , air: true , az: 169.7, gyro: 110.8, trk: 135.7),  // 18:37:49.215
        Row(t: 2270.469, normal: true , air: true , az: 169.2, gyro: 110.7, trk: 135.7),  // 18:37:50.469
        Row(t: 2271.469, normal: true , air: true , az: 167.9, gyro: 110.2, trk: 135.7),  // 18:37:51.469
        Row(t: 2272.474, normal: true , air: true , az: 164.7, gyro: 109.7, trk: 135.4),  // 18:37:52.474
        Row(t: 2273.715, normal: true , air: true , az: 164.2, gyro: 110.0, trk: 135.4),  // 18:37:53.715
        Row(t: 2274.715, normal: true , air: true , az: 164.0, gyro: 110.1, trk: 135.0),  // 18:37:54.715
        Row(t: 2275.717, normal: true , air: true , az: 163.8, gyro: 110.2, trk: 135.0),  // 18:37:55.717
        Row(t: 2276.964, normal: true , air: true , az: 167.2, gyro: 110.6, trk: 135.0),  // 18:37:56.964
        Row(t: 2277.965, normal: true , air: true , az: 183.0, gyro: 110.1, trk: 135.0),  // 18:37:57.965
        Row(t: 2278.967, normal: true , air: true , az: 157.6, gyro: 109.9, trk: 135.0),  // 18:37:58.967
        Row(t: 2280.215, normal: true , air: true , az: 159.3, gyro: 110.1, trk: 135.0),  // 18:38:00.215
        Row(t: 2281.472, normal: true , air: true , az: 160.8, gyro: 110.7, trk: 134.6),  // 18:38:01.472
        Row(t: 2282.715, normal: true , air: true , az: 160.9, gyro: 110.4, trk: 134.6),  // 18:38:02.715
        Row(t: 2283.965, normal: true , air: true , az: 162.2, gyro: 109.9, trk: 134.6),  // 18:38:03.965
        Row(t: 2284.975, normal: true , air: true , az: 161.7, gyro: 109.8, trk: 134.6),  // 18:38:04.975
        Row(t: 2286.215, normal: true , air: true , az: 162.4, gyro: 109.5, trk: 134.3),  // 18:38:06.215
        Row(t: 2287.215, normal: true , air: true , az: 161.5, gyro: 109.4, trk: 134.3),  // 18:38:07.215
        Row(t: 2288.223, normal: true , air: true , az: 160.5, gyro: 109.2, trk: 133.9),  // 18:38:08.223
        Row(t: 2289.469, normal: true , air: true , az: 159.2, gyro: 109.5, trk: 133.6),  // 18:38:09.469
        Row(t: 2290.473, normal: true , air: true , az: 158.6, gyro: 109.8, trk: 133.6),  // 18:38:10.473
        Row(t: 2291.715, normal: true , air: true , az: 158.3, gyro: 109.9, trk: 133.6),  // 18:38:11.715
        Row(t: 2292.975, normal: true , air: true , az: 159.2, gyro: 110.3, trk: 133.6),  // 18:38:12.975
        Row(t: 2294.226, normal: true , air: true , az: 158.5, gyro: 110.2, trk: 133.6),  // 18:38:14.226
        Row(t: 2295.466, normal: true , air: true , az: 157.9, gyro: 110.1, trk: 133.6),  // 18:38:15.466
        Row(t: 2296.726, normal: true , air: true , az: 157.3, gyro: 110.2, trk: 133.6),  // 18:38:16.726
        Row(t: 2297.966, normal: true , air: true , az: 158.4, gyro: 110.1, trk: 133.6),  // 18:38:17.966
        Row(t: 2298.967, normal: true , air: true , az: 158.1, gyro: 110.1, trk: 133.6),  // 18:38:18.967
        Row(t: 2299.968, normal: true , air: true , az: 157.9, gyro: 110.1, trk: 133.6),  // 18:38:19.968
        Row(t: 2300.973, normal: true , air: true , az: 158.1, gyro: 110.1, trk: 133.2),  // 18:38:20.973
        Row(t: 2301.974, normal: true , air: true , az: 157.8, gyro: 110.1, trk: 133.2),  // 18:38:21.974
        Row(t: 2302.978, normal: true , air: true , az: 157.7, gyro: 110.1, trk: 133.2),  // 18:38:22.978
        Row(t: 2303.981, normal: true , air: true , az: 158.0, gyro: 110.1, trk: 132.9),  // 18:38:23.981
        Row(t: 2305.218, normal: true , air: true , az: 158.0, gyro: 110.1, trk: 132.9),  // 18:38:25.218
        Row(t: 2306.466, normal: true , air: true , az: 156.9, gyro: 110.1, trk: 132.9),  // 18:38:26.466
        Row(t: 2307.472, normal: true , air: true , az: 156.3, gyro: 110.1, trk: 133.2),  // 18:38:27.472
        Row(t: 2308.716, normal: true , air: true , az: 156.0, gyro: 110.1, trk: 133.2),  // 18:38:28.716
        Row(t: 2309.968, normal: true , air: true , az: 155.8, gyro: 110.1, trk: 133.6),  // 18:38:29.968
        Row(t: 2310.974, normal: true , air: true , az: 155.2, gyro: 110.1, trk: 133.9),  // 18:38:30.974
        Row(t: 2311.975, normal: true , air: true , az: 154.4, gyro: 110.1, trk: 134.6),  // 18:38:31.975
        Row(t: 2313.216, normal: true , air: true , az: 154.3, gyro: 110.1, trk: 135.7),  // 18:38:33.216
        Row(t: 2314.216, normal: true , air: true , az: 154.7, gyro: 110.1, trk: 136.1),  // 18:38:34.216
        Row(t: 2315.466, normal: true , air: true , az: 154.8, gyro: 110.1, trk: 136.8),  // 18:38:35.466
        Row(t: 2316.466, normal: true , air: true , az: 155.2, gyro: 110.1, trk: 137.5),  // 18:38:36.466
        Row(t: 2317.470, normal: true , air: true , az: 155.4, gyro: 110.1, trk: 137.8),  // 18:38:37.470
        Row(t: 2318.716, normal: true , air: true , az: 155.1, gyro: 110.1, trk: 138.2),  // 18:38:38.716
        Row(t: 2319.716, normal: true , air: true , az: 155.3, gyro: 110.1, trk: 138.5),  // 18:38:39.716
        Row(t: 2320.716, normal: true , air: true , az: 155.5, gyro: 110.1, trk: 138.9),  // 18:38:40.716
        Row(t: 2321.716, normal: true , air: true , az: 155.6, gyro: 110.1, trk: 138.9),  // 18:38:41.716
        Row(t: 2322.981, normal: true , air: true , az: 155.0, gyro: 110.1, trk: 139.2),  // 18:38:42.981
        Row(t: 2324.216, normal: true , air: true , az: 154.3, gyro: 110.1, trk: 139.6),  // 18:38:44.216
        Row(t: 2325.217, normal: true , air: true , az: 154.1, gyro: 110.1, trk: 139.2),  // 18:38:45.217
        Row(t: 2326.466, normal: true , air: true , az: 153.3, gyro: 110.1, trk: 138.9),  // 18:38:46.466
        Row(t: 2327.479, normal: true , air: true , az: 152.8, gyro: 110.1, trk: 138.9),  // 18:38:47.479
        Row(t: 2328.716, normal: true , air: true , az: 151.8, gyro: 110.1, trk: 138.5),  // 18:38:48.716
        Row(t: 2329.972, normal: true , air: true , az: 150.8, gyro: 110.1, trk: 137.8),  // 18:38:49.972
        Row(t: 2331.216, normal: true , air: true , az: 149.4, gyro: 110.1, trk: 136.8),  // 18:38:51.216
        Row(t: 2332.217, normal: true , air: true , az: 148.9, gyro: 110.1, trk: 136.1),  // 18:38:52.217
        Row(t: 2333.217, normal: true , air: true , az: 147.9, gyro: 110.1, trk: 135.7),  // 18:38:53.217
        Row(t: 2334.474, normal: true , air: true , az: 147.3, gyro: 110.1, trk: 135.4),  // 18:38:54.474
        Row(t: 2335.482, normal: true , air: true , az: 147.5, gyro: 110.1, trk: 134.6),  // 18:38:55.482
        Row(t: 2336.724, normal: true , air: true , az: 146.2, gyro: 110.1, trk: 134.6),  // 18:38:56.724
        Row(t: 2337.967, normal: true , air: true , az: 145.6, gyro: 110.1, trk: 134.6),  // 18:38:57.967
        Row(t: 2338.968, normal: true , air: true , az: 145.3, gyro: 110.1, trk: 134.3),  // 18:38:58.968
        Row(t: 2339.968, normal: true , air: true , az: 144.8, gyro: 110.1, trk: 134.3),  // 18:38:59.968
        Row(t: 2341.217, normal: true , air: true , az: 144.3, gyro: 110.1, trk: 133.9),  // 18:39:01.217
        Row(t: 2342.477, normal: true , air: true , az: 143.5, gyro: 110.1, trk: 133.6),  // 18:39:02.477
        Row(t: 2343.717, normal: true , air: true , az: 142.7, gyro: 109.3, trk: 133.2),  // 18:39:03.717
        Row(t: 2344.717, normal: true , air: true , az: 142.4, gyro: 109.1, trk: 132.9),  // 18:39:04.717
        Row(t: 2345.722, normal: true , air: true , az: 142.0, gyro: 109.0, trk: 132.5),  // 18:39:05.722
        Row(t: 2346.967, normal: true , air: true , az: 141.5, gyro: 108.9, trk: 132.2),  // 18:39:06.967
        Row(t: 2347.969, normal: true , air: true , az: 141.2, gyro: 108.8, trk: 132.2),  // 18:39:07.969
        Row(t: 2349.217, normal: true , air: true , az: 141.0, gyro: 108.7, trk: 131.8),  // 18:39:09.217
        Row(t: 2350.217, normal: true , air: true , az: 141.1, gyro: 108.7, trk: 131.8),  // 18:39:10.217
        Row(t: 2351.217, normal: true , air: true , az: 141.4, gyro: 108.8, trk: 131.8),  // 18:39:11.217
        Row(t: 2352.475, normal: true , air: true , az: 142.0, gyro: 109.9, trk: 132.2),  // 18:39:12.475
        Row(t: 2353.478, normal: true , air: true , az: 142.9, gyro: 111.3, trk: 132.9),  // 18:39:13.478
        Row(t: 2354.720, normal: true , air: true , az: 144.0, gyro: 113.2, trk: 133.6),  // 18:39:14.720
        Row(t: 2355.847, normal: true , air: true , az: 145.3, gyro: 115.1, trk: 135.0),  // 18:39:15.847
        Row(t: 2356.968, normal: true , air: true , az: 146.5, gyro: 117.0, trk: 136.1),  // 18:39:16.968
        Row(t: 2358.239, normal: true , air: true , az: 148.3, gyro: 119.0, trk: 139.9),  // 18:39:18.239
        Row(t: 2359.468, normal: true , air: true , az: 149.7, gyro: 121.9, trk: 142.0),  // 18:39:19.468
        Row(t: 2360.483, normal: true , air: true , az: 151.4, gyro: 123.9, trk: 144.1),  // 18:39:20.483
        Row(t: 2361.718, normal: true , air: true , az: 153.2, gyro: 126.8, trk: 146.6),  // 18:39:21.718
        Row(t: 2362.718, normal: true , air: true , az: 154.9, gyro: 129.1, trk: 149.1),  // 18:39:22.718
        Row(t: 2363.974, normal: true , air: true , az: 157.7, gyro: 132.2, trk: 151.9),  // 18:39:23.974
        Row(t: 2364.977, normal: true , air: true , az: 160.3, gyro: 134.7, trk: 154.0),  // 18:39:24.977
        Row(t: 2366.218, normal: true , air: true , az: 162.9, gyro: 137.3, trk: 159.6),  // 18:39:26.218
        Row(t: 2366.783, normal: false, air: true , az: nil, gyro: nil, trk: nil),  // 18:39:26.783 limited:motion
        Row(t: 2367.240, normal: false, air: true , az: nil, gyro: 139.6, trk: 162.1),  // 18:39:27.240
        Row(t: 2368.468, normal: false, air: true , az: nil, gyro: 141.7, trk: 164.9),  // 18:39:28.468
        Row(t: 2368.877, normal: true , air: true , az: nil, gyro: nil, trk: nil),  // 18:39:28.877 normal
        Row(t: 2368.981, normal: false, air: true , az: nil, gyro: nil, trk: nil),  // 18:39:28.981 limited:motion
        Row(t: 2369.285, normal: true , air: true , az: nil, gyro: nil, trk: nil),  // 18:39:29.285 normal
        Row(t: 2369.486, normal: true , air: true , az: 169.3, gyro: 143.7, trk: 167.0),  // 18:39:29.486
        Row(t: 2369.677, normal: false, air: true , az: nil, gyro: nil, trk: nil),  // 18:39:29.677 limited:motion
        Row(t: 2369.877, normal: true , air: true , az: nil, gyro: nil, trk: nil),  // 18:39:29.877 normal
        Row(t: 2369.977, normal: false, air: true , az: nil, gyro: nil, trk: nil),  // 18:39:29.977 limited:motion
        Row(t: 2370.717, normal: false, air: true , az: nil, gyro: 146.5, trk: 169.8),  // 18:39:30.717
        Row(t: 2371.577, normal: true , air: true , az: nil, gyro: nil, trk: nil),  // 18:39:31.577 normal
        Row(t: 2371.718, normal: true , air: true , az: 173.1, gyro: 148.7, trk: 172.3),  // 18:39:31.718
    ]

    private struct Point {
        let t: Double
        let air: Bool
        let gap: Double
        let track: Double
        /// arAz + the continuous hold's offset (the step hold's on the ground).
        let held: Double
        /// arAz + the step hold's offset: what build 391 showed.
        let step: Double
        /// cmYaw + K.
        let gyroHeading: Double
    }

    /// The climb replayed as the view controller runs it. K is the 18:36:20.9 ground correction's:
    /// offset −12.0 against D 34.7, applied after the first row. The step-only offset starts there.
    private func replayOct2() -> (k: Double?, points: [Point]) {
        var hold = GyroYawHold()
        var smoothed = GyroYawHold.SmoothedGap()
        var k: Double?
        var step = -12.0
        var lastGyro: (t: Double, deg: Double)?
        var points: [Point] = []
        for (i, row) in AirHeadingHoldTests.oct2.enumerated() {
            var rate = Double.nan
            if let gyro = row.gyro {
                if let last = lastGyro { rate = AngularResponse.signedDelta(last.deg, gyro) / (row.t - last.t) }
                lastGyro = (t: row.t, deg: gyro)
            }
            var gap: Double?
            if row.normal, let az = row.az, let gyro = row.gyro { gap = AngularResponse.signedDelta(gyro, az) }
            let s = GyroYawHold.Sample(time: row.t, isNormal: row.normal, gapDeg: gap, azimuthRateDps: rate)
            if let event = hold.add(s), event.kind == .glitch, event.refusal == nil, row.air {
                step = AngularResponse.wrappedDeg(step - event.deltaDeg)
            }
            smoothed.add(s)
            if i == 0 {
                hold.recordAlignment(offsetDeg: -12.0, source: .ground)
                k = hold.anchorConstantDeg
            }
            guard let az = row.az, let gyro = row.gyro, let track = row.trk, let gap, let k else { continue }
            let mode = GyroYawHold.headingMode(airborne: row.air, hasAnchorConstant: true,
                                               signDisabled: false, aligned: true)
            var offset = step
            if mode == .continuous, let value = smoothed.valueDeg {
                offset = GyroYawHold.continuousOffsetDeg(anchorConstantDeg: k, smoothedGapDeg: value)
            }
            points.append(Point(t: row.t, air: row.air, gap: gap, track: track,
                                held: AngularResponse.wrappedDeg(az + offset),
                                step: AngularResponse.wrappedDeg(az + step),
                                gyroHeading: AngularResponse.wrappedDeg(gyro + k)))
        }
        return (k, points)
    }

    private func spread(_ values: [Double]) -> Double {
        (values.max() ?? 0) - (values.min() ?? 0)
    }

    /// The acceptance bar. 18:37:34.214 → 18:39:31.718, normal tracking but for the last few seconds:
    /// D drifts 33.2°, and the held heading stays on the gyro's — within 1.25° everywhere, the
    /// median's half-second lag and the frozen value after the final flaps — where build 391 showed
    /// ARKit's. Against GPS track (which carries the climb's changing drift angle, and a 40° turn at
    /// the end that the phone turned with) the held heading keeps within a 10.4° band; build 391's
    /// swept 47.2°.
    @Test func oct2ClimbHeldHeadingStaysOnTheGyroWhileDDrifts33Degrees() throws {
        let run = replayOct2()
        #expect(abs(try #require(run.k) - 22.7) < 0.05)
        let climb = run.points.filter { $0.t >= 2254.2 && $0.t <= 2371.8 }
        #expect(climb.count == 102)
        let first = try #require(climb.first), last = try #require(climb.last)
        #expect(abs((first.gap - last.gap) - 33.2) < 0.05)
        let offGyro = climb.map { abs(AngularResponse.signedDelta($0.gyroHeading, $0.held)) }
        #expect((offGyro.max() ?? .infinity) <= 1.3)
        let heldVsTrack = climb.map { AngularResponse.signedDelta($0.track, $0.held) }
        let stepVsTrack = climb.map { AngularResponse.signedDelta($0.track, $0.step) }
        #expect(spread(heldVsTrack) < 11)
        #expect(spread(stepVsTrack) > 45)
    }

    /// 18:38:14 → 18:39:02 the phone did not move — CoreMotion's yaw read 110.1° for 48 s — and D slid
    /// 14.9° (48.3 → 33.4). The held heading moves 0.7°; build 391's moved 15°.
    @Test func oct2PhoneHeldStillHeadingHeldStill() throws {
        let still = replayOct2().points.filter { $0.t >= 2294.2 && $0.t <= 2342.5 }
        #expect(still.count == 44)
        let first = try #require(still.first), last = try #require(still.last)
        #expect(abs((first.gap - last.gap) - 14.9) < 0.05)
        #expect(spread(still.map(\.held)) < 1.0)
        #expect(spread(still.map(\.step)) > 14)
    }

    /// On the ground nothing changes: the step hold's offset places every row.
    @Test func oct2GroundRowsAreTheStepHold() {
        let ground = replayOct2().points.filter { !$0.air }
        #expect(ground.count == 43)
        #expect(ground.allSatisfy { abs(AngularResponse.signedDelta($0.step, $0.held)) < 1e-9 })
    }

    /// Why the takeoff hand-over must not store K again. Build 391 did, pairing the −12.0 offset with
    /// D at 18:37:25.464 (56.6): K 44.6, and every carry that flight used it. With the phone held
    /// still and facing forward, that K puts the heading 21° off the track; the correction's own K
    /// puts it within 7°.
    @Test func oct2HandOverKWasTheDriftedOne() throws {
        let kAtTakeoff = AngularResponse.wrappedDeg(-12.0 + AngularResponse.signedDelta(111.0, 167.6))
        #expect(abs(kAtTakeoff - 44.6) < 0.05)
        let run = replayOct2()
        let k = try #require(run.k)
        let still = run.points.filter { $0.t >= 2294.2 && $0.t <= 2342.5 }
        for point in still {
            let gyro = point.gyroHeading - k   // cmYaw
            #expect(abs(AngularResponse.signedDelta(point.track, gyro + k)) < 7)
            #expect(abs(AngularResponse.signedDelta(point.track, gyro + kAtTakeoff)) > 14)
        }
    }
}
