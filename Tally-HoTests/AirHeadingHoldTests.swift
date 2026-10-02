//
//  AirHeadingHoldTests.swift
//  Tally-HoTests
//
//  Issue #10, as amended: K refreshed from the live alignment in the air, CoreMotion taken at the
//  frame's timestamp, and the stuck-camera watchdog.
//
//  - The refresh follows the alignment in force, is frozen through an episode and through fast
//    turns, starts afresh at a new alignment, and is what a reset carries.
//  - The Oct 2 cruise check (log b97771f3), row for row: two resets in straight flight, each carried
//    with a K seconds old instead of 17 s and 99 s.
//

import Testing
import Foundation
@testable import Tally_Ho

struct AirHeadingHoldTests {

    private func sample(_ t: Double, normal: Bool = true, gap: Double?, rate: Double = 1.0) -> GyroYawHold.Sample {
        GyroYawHold.Sample(time: t, isNormal: normal, gapDeg: normal ? gap : nil,
                           azimuthRateDps: normal ? rate : .nan)
    }

    /// One frame as the view controller runs it: `add`, apply a held step or a carry to `offset`, then
    /// refresh K from the offset now in force. Returns the event, if any.
    @discardableResult
    private func fly(_ hold: inout GyroYawHold, offset: inout Double, _ s: GyroYawHold.Sample) -> GyroYawHold.Event? {
        let event = hold.add(s)
        if let event {
            if event.kind == .glitch, event.refusal == nil {
                offset = AngularResponse.wrappedDeg(offset - event.deltaDeg)
            } else if event.kind == .reset, let carried = event.carriedOffsetDeg {
                offset = carried
            }
        }
        hold.refreshAnchor(liveOffsetDeg: offset, from: s)
        return event
    }

    /// `count` frames 50 ms apart from `t0`.
    @discardableResult
    private func fly(_ hold: inout GyroYawHold, offset: inout Double, from t0: Double, count: Int,
                     normal: Bool = true, rate: Double = 1.0,
                     gapAt: (Double) -> Double?) -> [GyroYawHold.Event] {
        var events: [GyroYawHold.Event] = []
        for i in 0..<count {
            let t = t0 + Double(i) * 0.05
            if let event = fly(&hold, offset: &offset, sample(t, normal: normal, gap: gapAt(t), rate: rate)) {
                events.append(event)
            }
        }
        return events
    }

    // MARK: - K refresh

    /// ARKit drifting 0.5°/s under an offset that does not move: K follows `offset + D`, as the median
    /// of the last 5 s — 2.5 s behind — while the alignment's own value stays where it was measured.
    @Test func kRefreshFollowsTheLiveAlignment() throws {
        var hold = GyroYawHold()
        var offset = 20.0
        fly(&hold, offset: &offset, from: 0.01, count: 20, gapAt: { _ in 10 })
        hold.recordAlignment(offsetDeg: 20, source: .anchor)
        let atAlignment = try #require(hold.anchorConstantDeg)
        #expect(abs(atAlignment - 30) < 1e-9)

        fly(&hold, offset: &offset, from: 1.01, count: 420, gapAt: { t in 10 + 0.5 * max(0, t - 2) })
        let last = 1.01 + 419 * 0.05
        let k = try #require(hold.anchorConstantDeg)
        #expect(abs(k - (20 + 10 + 0.5 * (last - 2.5 - 2))) < 0.05)
        #expect(abs(try #require(hold.alignmentConstantDeg) - 30) < 1e-9)
        #expect(hold.anchorAgeSeconds(at: last) < 1e-9)
        #expect(hold.alignmentAgeSeconds(at: last) > 20)
    }

    /// The case the freeze exists for: across an episode D jumps 30° and the offset only follows when
    /// the step is held, half a second and more later. `offset + D` in between is the glitch. K must
    /// not move at any point, before, during or after.
    @Test func kRefreshIsFrozenThroughAnEpisode() throws {
        var hold = GyroYawHold()
        var offset = 20.0
        fly(&hold, offset: &offset, from: 0.01, count: 20, gapAt: { _ in 10 })
        hold.recordAlignment(offsetDeg: 20, source: .seed)
        var worst = 0.0
        var held: [GyroYawHold.Event] = []
        let frames: [(from: Double, count: Int, normal: Bool, gap: Double?)] = [
            (1.01, 40, true, 10), (3.01, 20, false, nil), (4.01, 60, true, 40),
        ]
        for segment in frames {
            for i in 0..<segment.count {
                let t = segment.from + Double(i) * 0.05
                if let event = fly(&hold, offset: &offset,
                                   sample(t, normal: segment.normal, gap: segment.gap)) {
                    held.append(event)
                }
                let k = try #require(hold.anchorConstantDeg)
                worst = max(worst, abs(AngularResponse.signedDelta(30, k)))
            }
        }
        #expect(held.count == 1)
        #expect(held.first?.refusal == nil)
        #expect(abs(offset - (-10)) < 1e-9)   // 20 less the 30° step
        #expect(worst < 1e-9)
    }

    /// Faster than 15°/s the reading is timing, not alignment: K holds.
    @Test func kRefreshIsFrozenWhileThePhoneTurnsFast() throws {
        var hold = GyroYawHold()
        var offset = 20.0
        fly(&hold, offset: &offset, from: 0.01, count: 20, gapAt: { _ in 10 })
        hold.recordAlignment(offsetDeg: 20, source: .seed)
        fly(&hold, offset: &offset, from: 1.01, count: 40, gapAt: { _ in 10 })
        fly(&hold, offset: &offset, from: 3.01, count: 40, rate: 40, gapAt: { _ in 25 })
        #expect(abs(try #require(hold.anchorConstantDeg) - 30) < 1e-9)
    }

    /// No alignment, nothing to refresh; and a new alignment is taken whole, not averaged with the
    /// readings of the one it replaces.
    @Test func kRefreshNeedsAnAlignmentAndRestartsAtEachOne() throws {
        var hold = GyroYawHold()
        var offset = 20.0
        fly(&hold, offset: &offset, from: 0.01, count: 40, gapAt: { _ in 10 })
        #expect(!hold.hasAnchorConstant)

        hold.recordAlignment(offsetDeg: 20, source: .seed)
        fly(&hold, offset: &offset, from: 2.01, count: 100, gapAt: { _ in 10 })
        #expect(abs(try #require(hold.anchorConstantDeg) - 30) < 1e-9)

        offset = 50
        hold.recordAlignment(offsetDeg: 50, source: .anchor)
        #expect(abs(try #require(hold.anchorConstantDeg) - 60) < 1e-9)
        fly(&hold, offset: &offset, from: 7.01, count: 3, gapAt: { _ in 10 })
        #expect(abs(try #require(hold.anchorConstantDeg) - 60) < 1e-9)
    }

    /// After ARKit has drifted, a reset carries the refreshed K — seconds old — not the alignment's.
    @Test func theCarryUsesTheFreshK() throws {
        var hold = GyroYawHold()
        var offset = 20.0
        fly(&hold, offset: &offset, from: 0.01, count: 20, gapAt: { _ in 10 })
        hold.recordAlignment(offsetDeg: 20, source: .seed)
        fly(&hold, offset: &offset, from: 1.01, count: 400, gapAt: { t in 10 + 0.5 * max(0, t - 2) })
        let fresh = try #require(hold.anchorConstantDeg)
        #expect(abs(fresh - 30) > 5)                   // ARKit's alignment has moved on

        hold.worldDidReset(offsetBeforeDeg: offset, carry: true)
        #expect(hold.isCarryPending)
        fly(&hold, offset: &offset, from: 21.01, count: 20, normal: false, gapAt: { _ in nil })
        let events = fly(&hold, offset: &offset, from: 22.01, count: 1, gapAt: { _ in -7 })
        let carry = try #require(events.first)
        #expect(carry.kind == .reset)
        #expect(abs(try #require(carry.carriedOffsetDeg) - AngularResponse.wrappedDeg(fresh + 7)) < 1e-9)
        #expect(carry.anchorAgeSeconds < 2.5)          // last steady frame 20.96, carried at 22.01
        #expect(abs(try #require(hold.alignmentConstantDeg) - 30) < 1e-9)
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

    // MARK: - The Oct 2 cruise check (log b97771f3)

    /// The log from 19:30:44.194 to 19:32:29.037, straight and level on track 265: seconds after
    /// 19:00 UTC from the `time` column; frames (tracking-state events among them) with
    /// `ar_heading_deg` and `gyro_az_deg`, CoreMotion's yaw in build 391; the seed as captured; and the
    /// two world resets — Settings closed at 19:31:01.884, the map closed at 19:32:24.035.
    private enum Entry {
        case frame(t: Double, normal: Bool, az: Double?, gyro: Double?)
        case reset(t: Double)
        case seed(t: Double, offsetDeg: Double)
    }

    private static let cruise: [Entry] = [
        .frame(t: 1844.194, normal: false, az: nil, gyro: 2.0),  // 19:30:44.194
        .frame(t: 1844.344, normal: true, az: nil, gyro: nil),  // 19:30:44.344 normal
        .frame(t: 1845.198, normal: true, az: 0.0, gyro: 2.0),  // 19:30:45.198
        .frame(t: 1846.228, normal: true, az: 0.0, gyro: 2.0),  // 19:30:46.228
        .seed(t: 1847.012, offsetDeg: -94.6),  // 19:30:47.012 seed_captured
        .frame(t: 1847.262, normal: true, az: 360.0, gyro: 2.0),  // 19:30:47.262
        .frame(t: 1848.478, normal: true, az: 0.2, gyro: 2.0),  // 19:30:48.478
        .frame(t: 1849.712, normal: true, az: 0.3, gyro: 2.1),  // 19:30:49.712
        .frame(t: 1850.946, normal: true, az: 0.2, gyro: 2.1),  // 19:30:50.946
        .frame(t: 1851.946, normal: true, az: 0.9, gyro: 2.1),  // 19:30:51.946
        .frame(t: 1852.947, normal: true, az: 0.7, gyro: 2.2),  // 19:30:52.947
        .frame(t: 1853.947, normal: true, az: 0.7, gyro: 2.2),  // 19:30:53.947
        .frame(t: 1854.949, normal: true, az: 1.0, gyro: 2.2),  // 19:30:54.949
        .frame(t: 1856.181, normal: true, az: 1.1, gyro: 2.3),  // 19:30:56.181
        .frame(t: 1857.448, normal: true, az: 1.3, gyro: 2.4),  // 19:30:57.448
        .frame(t: 1858.450, normal: true, az: 1.3, gyro: 2.4),  // 19:30:58.450
        .reset(t: 1861.884),  // 19:31:01.884 ar_session_start
        .frame(t: 1862.175, normal: false, az: nil, gyro: 2.6),  // 19:31:02.175
        .frame(t: 1862.184, normal: false, az: nil, gyro: nil),  // 19:31:02.184 limited:initializing
        .frame(t: 1863.236, normal: true, az: nil, gyro: nil),  // 19:31:03.236 normal
        .frame(t: 1863.392, normal: true, az: 0.1, gyro: 2.6),  // 19:31:03.392
        .frame(t: 1864.637, normal: true, az: 0.5, gyro: 2.7),  // 19:31:04.637
        .frame(t: 1865.637, normal: true, az: 0.6, gyro: 2.7),  // 19:31:05.637
        .frame(t: 1866.639, normal: true, az: 2.6, gyro: 2.7),  // 19:31:06.639
        .frame(t: 1867.641, normal: true, az: 2.7, gyro: 2.7),  // 19:31:07.641
        .frame(t: 1868.644, normal: true, az: 2.8, gyro: 2.7),  // 19:31:08.644
        .frame(t: 1869.648, normal: true, az: 3.2, gyro: 2.7),  // 19:31:09.648
        .frame(t: 1870.888, normal: true, az: 3.4, gyro: 2.8),  // 19:31:10.888
        .frame(t: 1871.890, normal: true, az: 3.8, gyro: 2.8),  // 19:31:11.890
        .frame(t: 1872.891, normal: true, az: 3.6, gyro: 2.9),  // 19:31:12.891
        .frame(t: 1873.893, normal: true, az: 2.7, gyro: 2.9),  // 19:31:13.893
        .frame(t: 1874.900, normal: true, az: 2.0, gyro: 2.9),  // 19:31:14.900
        .frame(t: 1876.138, normal: true, az: 0.8, gyro: 2.9),  // 19:31:16.138
        .frame(t: 1877.144, normal: true, az: 0.2, gyro: 2.9),  // 19:31:17.144
        .frame(t: 1878.387, normal: true, az: 0.1, gyro: 3.0),  // 19:31:18.387
        .frame(t: 1879.388, normal: true, az: 359.9, gyro: 3.0),  // 19:31:19.388
        .frame(t: 1880.388, normal: true, az: 359.7, gyro: 3.0),  // 19:31:20.388
        .frame(t: 1881.655, normal: true, az: 359.6, gyro: 3.0),  // 19:31:21.655
        .frame(t: 1882.890, normal: true, az: 358.6, gyro: 3.1),  // 19:31:22.890
        .frame(t: 1883.916, normal: true, az: 359.7, gyro: 3.1),  // 19:31:23.916
        .frame(t: 1885.144, normal: true, az: 359.3, gyro: 3.1),  // 19:31:25.144
        .frame(t: 1886.394, normal: true, az: 358.4, gyro: 3.2),  // 19:31:26.394
        .frame(t: 1887.651, normal: true, az: 357.8, gyro: 3.2),  // 19:31:27.651
        .frame(t: 1888.895, normal: true, az: 357.7, gyro: 3.1),  // 19:31:28.895
        .frame(t: 1890.145, normal: true, az: 357.8, gyro: 3.2),  // 19:31:30.145
        .frame(t: 1891.388, normal: true, az: 358.1, gyro: 3.2),  // 19:31:31.388
        .frame(t: 1892.390, normal: true, az: 358.0, gyro: 3.2),  // 19:31:32.390
        .frame(t: 1893.393, normal: true, az: 358.0, gyro: 3.2),  // 19:31:33.393
        .frame(t: 1894.644, normal: true, az: 358.7, gyro: 3.2),  // 19:31:34.644
        .frame(t: 1895.888, normal: true, az: 359.0, gyro: 3.3),  // 19:31:35.888
        .frame(t: 1896.894, normal: true, az: 359.1, gyro: 3.3),  // 19:31:36.894
        .frame(t: 1897.894, normal: true, az: 359.4, gyro: 3.3),  // 19:31:37.894
        .frame(t: 1899.158, normal: true, az: 359.4, gyro: 3.3),  // 19:31:39.158
        .frame(t: 1900.388, normal: true, az: 359.4, gyro: 3.3),  // 19:31:40.388
        .frame(t: 1901.388, normal: true, az: 359.4, gyro: 3.3),  // 19:31:41.388
        .frame(t: 1902.389, normal: true, az: 359.4, gyro: 3.3),  // 19:31:42.389
        .frame(t: 1903.402, normal: true, az: 359.4, gyro: 3.3),  // 19:31:43.402
        .frame(t: 1904.644, normal: true, az: 359.6, gyro: 3.3),  // 19:31:44.644
        .frame(t: 1905.644, normal: true, az: 359.8, gyro: 3.3),  // 19:31:45.644
        .frame(t: 1906.657, normal: true, az: 359.9, gyro: 3.3),  // 19:31:46.657
        .frame(t: 1907.888, normal: true, az: 0.0, gyro: 3.4),  // 19:31:47.888
        .frame(t: 1908.889, normal: true, az: 360.0, gyro: 3.4),  // 19:31:48.889
        .frame(t: 1910.139, normal: true, az: 0.2, gyro: 3.4),  // 19:31:50.139
        .frame(t: 1911.139, normal: true, az: 0.1, gyro: 3.4),  // 19:31:51.139
        .frame(t: 1912.396, normal: true, az: 0.0, gyro: 3.4),  // 19:31:52.396
        .frame(t: 1913.639, normal: true, az: 0.2, gyro: 3.4),  // 19:31:53.639
        .frame(t: 1914.639, normal: true, az: 0.3, gyro: 3.4),  // 19:31:54.639
        .frame(t: 1915.897, normal: true, az: 0.3, gyro: 3.4),  // 19:31:55.897
        .frame(t: 1916.897, normal: true, az: 0.5, gyro: 3.4),  // 19:31:56.897
        .frame(t: 1918.139, normal: true, az: 0.5, gyro: 3.5),  // 19:31:58.139
        .frame(t: 1919.142, normal: true, az: 0.6, gyro: 3.5),  // 19:31:59.142
        .frame(t: 1920.145, normal: true, az: 0.7, gyro: 3.5),  // 19:32:00.145
        .frame(t: 1921.389, normal: true, az: 357.4, gyro: 0.4),  // 19:32:01.389
        .frame(t: 1922.389, normal: true, az: 352.1, gyro: -3.3),  // 19:32:02.389
        .frame(t: 1923.389, normal: true, az: 353.6, gyro: -1.6),  // 19:32:03.389
        .frame(t: 1924.390, normal: true, az: 3.0, gyro: 7.7),  // 19:32:04.390
        .frame(t: 1925.394, normal: true, az: 358.6, gyro: 4.0),  // 19:32:05.394
        .frame(t: 1926.639, normal: true, az: 0.7, gyro: 8.1),  // 19:32:06.639
        .frame(t: 1927.639, normal: true, az: 358.3, gyro: 6.3),  // 19:32:07.639
        .frame(t: 1928.644, normal: true, az: 355.3, gyro: 2.6),  // 19:32:08.644
        .frame(t: 1929.889, normal: true, az: 353.2, gyro: 0.0),  // 19:32:09.889
        .frame(t: 1930.889, normal: true, az: 352.2, gyro: -1.0),  // 19:32:10.889
        .frame(t: 1931.889, normal: true, az: 353.0, gyro: -0.1),  // 19:32:11.889
        .frame(t: 1933.139, normal: true, az: 1.0, gyro: 7.6),  // 19:32:13.139
        .frame(t: 1934.139, normal: true, az: 1.6, gyro: 8.3),  // 19:32:14.139
        .reset(t: 1944.035),  // 19:32:24.035 ar_session_start
        .frame(t: 1944.302, normal: false, az: nil, gyro: 3.3),  // 19:32:24.302
        .frame(t: 1944.570, normal: false, az: nil, gyro: nil),  // 19:32:24.570 limited:initializing
        .frame(t: 1945.272, normal: true, az: nil, gyro: nil),  // 19:32:25.272 normal
        .frame(t: 1945.537, normal: true, az: 358.8, gyro: 2.7),  // 19:32:25.537
        .frame(t: 1946.537, normal: true, az: 359.7, gyro: 3.5),  // 19:32:26.537
        .frame(t: 1947.787, normal: true, az: 0.1, gyro: 4.0),  // 19:32:27.787
        .frame(t: 1949.037, normal: true, az: 359.6, gyro: 3.3),  // 19:32:29.037
    ]

    private struct Bridge {
        let t: Double
        /// The heading shown after the carry, less the one shown before the reset carried on by what
        /// CoreMotion says the phone did meanwhile. Zero is a seamless carry.
        let errorDeg: Double
        let anchorAgeSeconds: Double
    }

    private func replayCruise(refreshing: Bool) -> (bridges: [Bridge], alignment: Double?) {
        var hold = GyroYawHold()
        hold.worldDidReset(offsetBeforeDeg: .nan, carry: false)   // the 19:30:42.9 foreground reset
        var offset = 0.0
        var aligned = false
        var lastGyro: (t: Double, deg: Double)?
        var lastShown: (heading: Double, gyro: Double)?
        var bridges: [Bridge] = []
        for entry in AirHeadingHoldTests.cruise {
            switch entry {
            case .seed(_, let seedOffset):
                offset = seedOffset
                aligned = true
                hold.recordAlignment(offsetDeg: seedOffset, source: .seed)
            case .reset:
                hold.worldDidReset(offsetBeforeDeg: aligned ? offset : .nan, carry: hold.hasAnchorConstant)
                aligned = false
                offset = 0
            case .frame(let t, let normal, let az, let gyro):
                var rate = Double.nan
                if let gyro {
                    if let last = lastGyro { rate = AngularResponse.signedDelta(last.deg, gyro) / (t - last.t) }
                    lastGyro = (t: t, deg: gyro)
                }
                var gap: Double?
                if normal, let az, let gyro { gap = AngularResponse.signedDelta(gyro, az) }
                let s = GyroYawHold.Sample(time: t, isNormal: normal, gapDeg: gap, azimuthRateDps: rate)
                if let event = hold.add(s) {
                    if event.kind == .reset, let carried = event.carriedOffsetDeg,
                       let az, let gyro, let before = lastShown {
                        offset = carried
                        aligned = true
                        let shown = AngularResponse.wrappedDeg(az + carried)
                        let expected = AngularResponse.wrappedDeg(
                            before.heading + AngularResponse.signedDelta(before.gyro, gyro))
                        bridges.append(Bridge(t: t, errorDeg: AngularResponse.signedDelta(expected, shown),
                                              anchorAgeSeconds: event.anchorAgeSeconds))
                    } else if event.kind == .glitch, event.refusal == nil, aligned {
                        offset = AngularResponse.wrappedDeg(offset - event.deltaDeg)
                    }
                }
                if refreshing, aligned { hold.refreshAnchor(liveOffsetDeg: offset, from: s) }
                if aligned, normal, let az, let gyro {
                    lastShown = (heading: AngularResponse.wrappedDeg(az + offset), gyro: gyro)
                }
            }
        }
        return (bridges, hold.alignmentConstantDeg)
    }

    /// With K refreshed, both carries continue the heading the user was looking at to within a few
    /// tenths, with a K 4.9 s and 11.4 s old — the gap since the last steady frame, the map's ten
    /// seconds included.
    @Test func cruiseCarriesBridgeWithAFreshK() throws {
        let run = replayCruise(refreshing: true)
        #expect(run.bridges.count == 2)
        guard run.bridges.count == 2 else { return }
        for bridge in run.bridges { #expect(abs(bridge.errorDeg) < 0.3) }
        #expect(run.bridges[0].anchorAgeSeconds < 6)
        #expect(run.bridges[1].anchorAgeSeconds < 12)
        // The seed's own K is untouched: −94.6 against D −2.0.
        #expect(abs(try #require(run.alignment) - (-96.6)) < 0.05)
    }

    /// What build 391 did with the seed's K: the second carry, 99 s on, moved the scene 4.2° off the
    /// heading the user had just been looking at; the first, 0.9°.
    @Test func cruiseCarriesWithTheStoredKJumped() throws {
        let run = replayCruise(refreshing: false)
        #expect(run.bridges.count == 2)
        guard run.bridges.count == 2 else { return }
        #expect(abs(run.bridges[0].errorDeg - (-0.9)) < 0.15)
        #expect(abs(run.bridges[1].errorDeg - 4.2) < 0.15)
        #expect(run.bridges[1].anchorAgeSeconds > 90)
    }
}
