//
//  NightFlightHoldTests.swift
//  Tally-HoTests
//
//  Issue #11: the continuous heading must not freeze. In the air with K, the offset is K − D on every
//  frame with a camera, normal or limited, so the heading is cmYaw + K; it holds only on stale
//  CoreMotion, a clock mismatch, or a start's first 0.3 s. Targets stay drawn and the airborne seed
//  may capture in limited tracking; the ground is unchanged.
//
//  The replay is the last minute and a half of the 2026-10-03 night flight, log 3500faa7, in which
//  build 392 froze D for 51.6 s of flapping limited tracking while ARKit's azimuth rotated 121°.
//

import Testing
import Foundation
@testable import Tally_Ho

struct NightFlightHoldTests {

    private func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
        abs(AngularResponse.signedDelta(a, b)) <= tolerance
    }

    // MARK: - Which frames are used

    /// Tracking state is not an input any more: with a camera, past the start guard, and CoreMotion
    /// fresh at the frame's timestamp, every frame is used.
    @Test func everyFrameWithACameraIsUsed() {
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 5,
                                      motionGapSeconds: 0.02, motionYawDeg: -35.6) == nil)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 0.3,
                                      motionGapSeconds: 0.1, motionYawDeg: 10) == nil)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 5,
                                      motionGapSeconds: -0.04, motionYawDeg: 10) == nil)
    }

    /// The only reasons left to hold D.
    @Test func theReasonsToHold() {
        #expect(GyroYawHold.frameHold(hasCamera: false, secondsSinceStart: 5,
                                      motionGapSeconds: 0.02, motionYawDeg: 10) == .noCamera)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 0.29,
                                      motionGapSeconds: 0.02, motionYawDeg: 10) == .startGuard)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 5,
                                      motionGapSeconds: 0.15, motionYawDeg: 10) == .staleMotion)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 5,
                                      motionGapSeconds: .nan, motionYawDeg: nil) == .staleMotion)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 5,
                                      motionGapSeconds: 0.02, motionYawDeg: nil) == .staleMotion)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 5,
                                      motionGapSeconds: 0.6, motionYawDeg: 10) == .clockMismatch)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 5,
                                      motionGapSeconds: -203.798, motionYawDeg: nil) == .clockMismatch)
    }

    /// 3500faa7, 02:56:39.335: 0.28 s after a foreground start, a frame left over from before the pause
    /// arrived 203.8 s older than CoreMotion. The start guard holds it before the clocks are compared.
    /// A leftover frame — captured before the start — is held however late it arrives; a frame with a
    /// fresh CoreMotion reading after the guard is not.
    @Test func theNightsLeftoverFrameIsInsideTheStartGuard() {
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 0.28,
                                      motionGapSeconds: -203.798, motionYawDeg: nil) == .startGuard)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 0.6, isLeftoverFrame: true,
                                      motionGapSeconds: -0.2, motionYawDeg: 10) == .startGuard)
        #expect(GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: 0.6, isLeftoverFrame: false,
                                      motionGapSeconds: 0.02, motionYawDeg: 10) == nil)
    }

    /// A reset in the air with K, at 60 Hz. For 0.3 s the frames are held — the first few are the old
    /// world's last, the rest `limited:initializing` — and the carry is taken at the first frame after
    /// that, in limited tracking, with no normal frame anywhere. Lift 4 of 3500faa7 waited 1.30 s for
    /// its normal-tracking carry.
    @Test func afterAResetTheCarryIsTheFirstFrameAfterTheStartGuard() throws {
        var hold = GyroYawHold()
        hold.recordAlignment(offsetDeg: 20.2, source: .seed, gapDeg: 108.0)
        let k = try #require(hold.anchorConstantDeg)
        hold.worldDidReset(offsetBeforeDeg: 20.2, carry: true)
        var frameGap = GyroYawHold.FrameGap()
        let cmYaw = -35.6
        var carry: (t: Double, offset: Double)?
        for i in 1...60 {
            let t = Double(i) / 60.0
            let leftover = i <= 3
            let arAz = leftover ? 233.4 : 41.0          // the old world's frame, then the new world's
            let reason = GyroYawHold.frameHold(hasCamera: true, secondsSinceStart: t,
                                               motionGapSeconds: leftover ? -203.798 : 0.02,
                                               motionYawDeg: leftover ? nil : cmYaw)
            let frame = reason == nil ? AngularResponse.signedDelta(cmYaw, arAz) : nil
            _ = hold.add(GyroYawHold.Sample(time: t, isNormal: false, gapDeg: nil, azimuthRateDps: 0.5,
                                            frameGapDeg: frame))
            frameGap.add(gapDeg: frame, at: t)
            if carry == nil, hold.isCarryPending, let value = frameGap.valueDeg {
                carry = (t: t, offset: GyroYawHold.continuousOffsetDeg(anchorConstantDeg: k, gapDeg: value))
                hold.abandonCarry()
            }
        }
        let taken = try #require(carry)
        #expect(taken.t >= GyroYawHold.startGuardSeconds && taken.t < 0.32)
        #expect(near(41.0 + taken.offset, cmYaw + k, 1e-9))
        #expect(!hold.isCarryPending)
    }

    // MARK: - Drawing and seeding in limited tracking

    /// In the air under the continuous hold, every state with a camera is drawn, `initializing` and
    /// `relocalizing` included; `.notAvailable` is not. Otherwise — the ground, or the step hold — the
    /// usual rule, unchanged.
    @Test func targetsAreDrawnInLimitedTrackingOnlyUnderTheAirHold() {
        // limited:initializing / relocalizing (not base-usable), with the air hold on
        #expect(GyroYawHold.worldUsableForDisplay(baseUsable: false, notAvailable: false,
                                                  continuousHoldActive: true))
        #expect(!GyroYawHold.worldUsableForDisplay(baseUsable: false, notAvailable: true,
                                                   continuousHoldActive: true))
        // The ground, or the air without the continuous hold: base rule only.
        #expect(!GyroYawHold.worldUsableForDisplay(baseUsable: false, notAvailable: false,
                                                   continuousHoldActive: false))
        #expect(GyroYawHold.worldUsableForDisplay(baseUsable: true, notAvailable: false,
                                                  continuousHoldActive: false))
        #expect(!GyroYawHold.worldUsableForDisplay(baseUsable: false, notAvailable: true,
                                                   continuousHoldActive: false))
    }

    /// The airborne track seed may start in any state with a camera; the compass seed keeps waiting for
    /// a usable world.
    @Test func onlyTheTrackSeedCapturesInLimitedTracking() {
        #expect(GyroYawHold.seedMayCapture(trackReference: true, baseUsable: false, notAvailable: false))
        #expect(!GyroYawHold.seedMayCapture(trackReference: true, baseUsable: false, notAvailable: true))
        #expect(!GyroYawHold.seedMayCapture(trackReference: false, baseUsable: false, notAvailable: false))
        #expect(GyroYawHold.seedMayCapture(trackReference: false, baseUsable: true, notAvailable: false))
    }

    /// A night start that never reaches normal: `.notAvailable` until 0.43 s (lift 4 of 3500faa7), then
    /// `limited:initializing`, with the card up at 0.28 s and the phone held forward. The 4 Hz tick
    /// arms the capture at 0.5 s, samples come every 0.2 s as `feedStartupSeed` takes them, and the
    /// still path publishes at 2.3 s — the card plus 2.0 s. Before #11 nothing could start before
    /// normal tracking.
    @Test func anAirborneSeedFromLimitedTrackingPublishesAtTheCardPlusTwoSeconds() throws {
        let cardAt = 0.28, track = 92.8
        var seed = AirborneSeedSettle()
        var armedAtFrame: Int?
        var published: (estimate: AirborneSeedSettle.Estimate, t: Double)?
        for i in 1...360 {
            let t = Double(i) / 60.0
            let notAvailable = t < 0.43
            if armedAtFrame == nil, i % 15 == 0, t >= cardAt,
               GyroYawHold.seedMayCapture(trackReference: true, baseUsable: false, notAvailable: notAvailable) {
                armedAtFrame = i
                seed.begin(cardShownAt: cardAt)
            }
            guard let armed = armedAtFrame, (i - armed) % 12 == 0 else { continue }
            let arAz = 141.5 + 0.3 * sin(t * 7)        // ARKit's azimuth, limited, the phone forward
            seed.add(arAzimuthDeg: arAz, trackDeg: track, at: t)
            if let e = seed.finish(at: t) { published = (estimate: e, t: t); break }
        }
        #expect(armedAtFrame == 30)
        let result = try #require(published)
        #expect(result.estimate.path == .still)
        #expect(result.t >= cardAt + 2.0 && result.t < 2.35)
        #expect(near(result.estimate.offsetDeg, track - 141.5, 0.5))
    }

    // MARK: - K from an alignment with its own D

    /// An airborne alignment in limited tracking comes with the frame D of its moment, and K is stored
    /// at once. Without a D — the ground's call — it waits for a normal reading, as before.
    @Test func anAlignmentWithItsOwnDStoresKAtOnce() throws {
        var air = GyroYawHold()
        _ = air.add(GyroYawHold.Sample(time: 0, isNormal: false, gapDeg: nil, azimuthRateDps: 0.5,
                                       frameGapDeg: 108.0))
        air.recordAlignment(offsetDeg: 20.2, source: .seed, gapDeg: 108.0)
        #expect(near(try #require(air.anchorConstantDeg), 128.2, 1e-9))

        var ground = GyroYawHold()
        _ = ground.add(GyroYawHold.Sample(time: 0, isNormal: false, gapDeg: nil, azimuthRateDps: 0.5))
        ground.recordAlignment(offsetDeg: 20.2, source: .ground)
        #expect(ground.anchorConstantDeg == nil)
    }

    /// K stored with its own D during an episode stays that K when the episode closes on a different D:
    /// the step is refused as realigned, and K is not paired again with the D after.
    @Test func anAlignmentDuringAnEpisodeKeepsItsOwnK() throws {
        var hold = GyroYawHold()
        var events: [GyroYawHold.Event] = []
        for i in 0..<20 {                                   // normal, D 10
            let t = Double(i) * 0.05
            if let e = hold.add(GyroYawHold.Sample(time: t, isNormal: true, gapDeg: 10, azimuthRateDps: 1)) {
                events.append(e)
            }
        }
        for i in 0..<20 {                                   // limited for a second
            let t = 1.0 + Double(i) * 0.05
            if let e = hold.add(GyroYawHold.Sample(time: t, isNormal: false, gapDeg: nil, azimuthRateDps: 1,
                                                   frameGapDeg: 45)) {
                events.append(e)
            }
            if i == 10 { hold.recordAlignment(offsetDeg: 20, source: .seed, gapDeg: 45) }
        }
        #expect(near(try #require(hold.anchorConstantDeg), 65, 1e-9))
        for i in 0..<40 {                                   // normal again, D 50
            let t = 2.0 + Double(i) * 0.05
            if let e = hold.add(GyroYawHold.Sample(time: t, isNormal: true, gapDeg: 50, azimuthRateDps: 1)) {
                events.append(e)
            }
        }
        let closed = try #require(events.last)
        #expect(closed.kind == .glitch)
        #expect(closed.refusal == .realigned)
        #expect(near(try #require(hold.anchorConstantDeg), 65, 1e-9))
    }

    // MARK: - The 2026-10-03 night flight (log 3500faa7), 02:58:30 to 02:59:59

    /// Every frame row of the log from 02:58:30.252 to 02:59:59.012: seconds after 02:58:00 UTC from
    /// the `time` column; `ar_state`; ARKit's azimuth, which is `ar_heading_deg` where it was logged
    /// (normal rows) and `−cam_yaw_deg` everywhere — the two agree to the digit on every normal row;
    /// `gyro_az_deg`, CoreMotion's yaw in build 392; and `anchor_offset_deg`, the offset build 392 had
    /// in force. The track was 92.8 on every row, at 457–466 kt.
    private struct Night {
        let t: Double
        let state: String
        let az: Double
        let g: Double
        let off: Double
    }

    private static let night: [Night] = [
Night(t: 30.252, state: "limited:features", az: 141.5, g: 31.3, off: 20.2),  // 02:58:30.252
        Night(t: 31.491, state: "limited:features", az: 145.1, g: 34.3, off: 20.2),  // 02:58:31.491
        Night(t: 32.504, state: "limited:features", az: 176.0, g: 65.0, off: 20.2),  // 02:58:32.504
        Night(t: 33.506, state: "limited:features", az: -169.4, g: 79.2, off: 20.2),  // 02:58:33.506
        Night(t: 34.744, state: "limited:features", az: -166.0, g: 81.9, off: 20.2),  // 02:58:34.744
        Night(t: 35.991, state: "limited:features", az: -167.9, g: 79.6, off: 20.2),  // 02:58:35.991
        Night(t: 37.008, state: "limited:features", az: -164.0, g: 83.8, off: 20.2),  // 02:58:37.008
        Night(t: 38.249, state: "limited:features", az: -167.6, g: 79.9, off: 20.2),  // 02:58:38.249
        Night(t: 39.258, state: "limited:features", az: -167.7, g: 79.4, off: 20.2),  // 02:58:39.258
        Night(t: 40.497, state: "limited:features", az: 178.4, g: 65.1, off: 20.2),  // 02:58:40.497
        Night(t: 41.507, state: "limited:features", az: 106.2, g: -6.6, off: 20.2),  // 02:58:41.507
        Night(t: 42.742, state: "normal", az: 109.9, g: -4.7, off: 20.2),  // 02:58:42.742
        Night(t: 43.742, state: "limited:motion", az: 110.8, g: -4.0, off: 13.7),  // 02:58:43.742
        Night(t: 44.752, state: "normal", az: 78.4, g: -37.0, off: 12.9),  // 02:58:44.752
        Night(t: 45.758, state: "normal", az: 77.1, g: -36.9, off: 12.8),  // 02:58:45.758
        Night(t: 46.992, state: "limited:motion", az: 78.9, g: -35.3, off: 14.4),  // 02:58:46.992
        Night(t: 47.997, state: "limited:motion", az: 81.5, g: -32.8, off: 14.4),  // 02:58:47.997
        Night(t: 49.010, state: "normal", az: 84.9, g: -30.1, off: 14.4),  // 02:58:49.010
        Night(t: 50.259, state: "normal", az: 82.0, g: -33.3, off: 13.1),  // 02:58:50.259
        Night(t: 51.492, state: "normal", az: 76.7, g: -38.4, off: 12.9),  // 02:58:51.492
        Night(t: 52.503, state: "normal", az: -5.3, g: -42.0, off: 12.9),  // 02:58:52.503
        Night(t: 53.517, state: "limited:features", az: -0.8, g: -33.7, off: 52.3),  // 02:58:53.517
        Night(t: 54.742, state: "limited:features", az: -3.0, g: -33.2, off: 52.3),  // 02:58:54.742
        Night(t: 55.742, state: "limited:features", az: -7.5, g: -33.1, off: 52.3),  // 02:58:55.742
        Night(t: 56.772, state: "limited:features", az: -8.0, g: -32.9, off: 52.3),  // 02:58:56.772
        Night(t: 57.998, state: "limited:features", az: -12.1, g: -32.9, off: 52.3),  // 02:58:57.998
        Night(t: 59.249, state: "limited:features", az: -13.5, g: -36.6, off: 52.3),  // 02:58:59.249
        Night(t: 60.491, state: "limited:features", az: -5.5, g: -33.2, off: 52.3),  // 02:59:00.491
        Night(t: 61.501, state: "limited:features", az: -24.7, g: -36.2, off: 52.3),  // 02:59:01.501
        Night(t: 62.762, state: "limited:features", az: -17.2, g: -35.6, off: 52.3),  // 02:59:02.762
        Night(t: 63.999, state: "limited:features", az: -16.9, g: -35.9, off: 52.3),  // 02:59:03.999
        Night(t: 65.000, state: "limited:features", az: -37.5, g: -36.9, off: 52.3),  // 02:59:05.000
        Night(t: 66.017, state: "limited:features", az: -41.1, g: -37.2, off: 52.3),  // 02:59:06.017
        Night(t: 67.259, state: "limited:features", az: -45.4, g: -38.0, off: 52.3),  // 02:59:07.259
        Night(t: 68.503, state: "limited:features", az: -49.1, g: -38.0, off: 52.3),  // 02:59:08.503
        Night(t: 69.747, state: "limited:features", az: -52.8, g: -37.7, off: 52.3),  // 02:59:09.747
        Night(t: 70.760, state: "limited:features", az: -57.7, g: -37.7, off: 52.3),  // 02:59:10.760
        Night(t: 71.999, state: "limited:features", az: -61.0, g: -37.7, off: 52.3),  // 02:59:11.999
        Night(t: 73.000, state: "limited:features", az: -63.0, g: -37.4, off: 52.3),  // 02:59:13.000
        Night(t: 74.261, state: "limited:features", az: -64.0, g: -37.3, off: 52.3),  // 02:59:14.261
        Night(t: 75.498, state: "limited:features", az: -64.9, g: -37.3, off: 52.3),  // 02:59:15.498
        Night(t: 76.499, state: "limited:features", az: -70.3, g: -47.0, off: 52.3),  // 02:59:16.499
        Night(t: 77.499, state: "limited:features", az: -85.4, g: -33.8, off: 52.3),  // 02:59:17.499
        Night(t: 78.504, state: "limited:features", az: -69.7, g: -33.1, off: 52.3),  // 02:59:18.504
        Night(t: 79.762, state: "limited:features", az: -73.2, g: -33.4, off: 52.3),  // 02:59:19.762
        Night(t: 81.000, state: "limited:features", az: -76.0, g: -33.3, off: 52.3),  // 02:59:21.000
        Night(t: 82.009, state: "limited:features", az: -80.0, g: -33.9, off: 52.3),  // 02:59:22.009
        Night(t: 83.250, state: "limited:features", az: -85.6, g: -33.9, off: 52.3),  // 02:59:23.250
        Night(t: 84.251, state: "limited:features", az: -86.9, g: -34.0, off: 52.3),  // 02:59:24.251
        Night(t: 85.263, state: "limited:features", az: -90.7, g: -34.0, off: 52.3),  // 02:59:25.263
        Night(t: 86.495, state: "limited:features", az: -91.6, g: -34.1, off: 52.3),  // 02:59:26.495
        Night(t: 87.511, state: "limited:features", az: -93.9, g: -34.1, off: 52.3),  // 02:59:27.511
        Night(t: 88.762, state: "limited:features", az: -97.5, g: -34.2, off: 52.3),  // 02:59:28.762
        Night(t: 90.004, state: "limited:features", az: -100.1, g: -34.2, off: 52.3),  // 02:59:30.004
        Night(t: 91.274, state: "limited:features", az: -99.8, g: -34.0, off: 52.3),  // 02:59:31.274
        Night(t: 92.507, state: "limited:features", az: -102.5, g: -33.9, off: 52.3),  // 02:59:32.507
        Night(t: 93.772, state: "limited:features", az: -106.3, g: -34.1, off: 52.3),  // 02:59:33.772
        Night(t: 94.997, state: "limited:features", az: -109.5, g: -35.0, off: 52.3),  // 02:59:34.997
        Night(t: 96.004, state: "limited:features", az: -110.1, g: -34.9, off: 52.3),  // 02:59:36.004
        Night(t: 97.004, state: "limited:features", az: -111.7, g: -35.0, off: 52.3),  // 02:59:37.004
        Night(t: 98.253, state: "limited:features", az: -114.9, g: -35.0, off: 52.3),  // 02:59:38.253
        Night(t: 99.269, state: "limited:features", az: -116.1, g: -35.0, off: 52.3),  // 02:59:39.269
        Night(t: 100.271, state: "limited:features", az: -118.1, g: -35.2, off: 52.3),  // 02:59:40.271
        Night(t: 101.505, state: "limited:features", az: -118.7, g: -35.1, off: 52.3),  // 02:59:41.505
        Night(t: 102.509, state: "limited:features", az: -120.1, g: -35.1, off: 52.3),  // 02:59:42.509
        Night(t: 103.759, state: "limited:motion", az: -121.6, g: -35.5, off: 52.3),  // 02:59:43.759
        Night(t: 105.010, state: "normal", az: -126.6, g: -35.6, off: -140.9),  // 02:59:45.010
        Night(t: 106.248, state: "limited:features", az: -120.2, g: -35.7, off: -140.4),  // 02:59:46.248
        Night(t: 107.264, state: "limited:features", az: -122.9, g: -35.7, off: -140.4),  // 02:59:47.264
        Night(t: 108.503, state: "limited:features", az: -123.7, g: -35.7, off: -144.1),  // 02:59:48.503
        Night(t: 109.761, state: "normal", az: -124.6, g: -37.2, off: -144.6),  // 02:59:49.761
        Night(t: 111.009, state: "limited:features", az: -112.8, g: -28.8, off: -144.4),  // 02:59:51.009
        Night(t: 112.018, state: "limited:features", az: -124.9, g: -34.2, off: -144.4),  // 02:59:52.018
        Night(t: 113.258, state: "limited:motion", az: -143.7, g: -37.4, off: -144.4),  // 02:59:53.258
        Night(t: 114.514, state: "limited:motion", az: -142.8, g: -37.6, off: -144.4),  // 02:59:54.514
        Night(t: 115.756, state: "limited:motion", az: -118.4, g: -6.4, off: -144.4),  // 02:59:55.756
        Night(t: 116.998, state: "limited:motion", az: -96.7, g: -3.6, off: -144.4),  // 02:59:56.998
        Night(t: 118.010, state: "limited:features", az: -145.0, g: -28.9, off: -144.4),  // 02:59:58.010
        Night(t: 119.012, state: "limited:features", az: -138.0, g: -31.5, off: -144.4),  // 02:59:59.012
    ]

    private static let track = 92.8
    /// The lift's `ar_session_start`, 02:57:13.466, on the rows' clock.
    private static let sessionStart = -46.534

    private struct NightPoint {
        let t: Double
        let state: String
        let hold: GyroYawHold.FrameHold?
        let gap: Double
        /// arAz + the continuous offset, written as the view controller writes it.
        let held: Double
        /// arAz + build 392's offset: what was on screen.
        let build392: Double
        /// cmYaw + K.
        let gyroHeading: Double
    }

    /// The minute and a half replayed as the view controller now runs it. K is the log's 128.2 — the
    /// seed's of 02:57:04.7, which every `heading_compare` line here agrees with (offset 20.2 against
    /// D̄ 108.1, 13.7 against 114.5, 12.8 against 115.4) — stored as an airborne alignment with its own
    /// D. CoreMotion is taken as fresh at each frame (the log has no clock gap here). The step hold is
    /// fed alongside, as the view controller feeds it, to show it never touches K.
    private func replayNight() -> (k: Double?, kAfter: Double?, points: [NightPoint]) {
        var hold = GyroYawHold()
        var frameGap = GyroYawHold.FrameGap()
        hold.recordAlignment(offsetDeg: 20.2, source: .seed, gapDeg: 108.0)
        let k = hold.anchorConstantDeg
        var offset = 20.2
        var lastG: (t: Double, deg: Double)?
        var points: [NightPoint] = []
        for row in NightFlightHoldTests.night {
            var rate = Double.nan
            if let last = lastG { rate = AngularResponse.signedDelta(last.deg, row.g) / (row.t - last.t) }
            lastG = (t: row.t, deg: row.g)
            let normal = row.state == "normal"
            let reason = GyroYawHold.frameHold(hasCamera: true,
                                               secondsSinceStart: row.t - NightFlightHoldTests.sessionStart,
                                               motionGapSeconds: 0.02, motionYawDeg: row.g)
            let frame = reason == nil ? AngularResponse.signedDelta(row.g, row.az) : nil
            _ = hold.add(GyroYawHold.Sample(time: row.t, isNormal: normal, gapDeg: normal ? frame : nil,
                                            azimuthRateDps: rate, frameGapDeg: frame))
            frameGap.add(gapDeg: frame, at: row.t)
            let mode = GyroYawHold.headingMode(airborne: true, hasAnchorConstant: k != nil,
                                               signDisabled: false, aligned: true)
            if mode == .continuous, let k, let value = frameGap.valueDeg {
                let target = GyroYawHold.continuousOffsetDeg(anchorConstantDeg: k, gapDeg: value)
                if GyroYawHold.shouldWriteOffset(currentDeg: offset, targetDeg: target) { offset = target }
            }
            points.append(NightPoint(t: row.t, state: row.state, hold: reason, gap: frame ?? .nan,
                                     held: AngularResponse.wrappedDeg(row.az + offset),
                                     build392: AngularResponse.wrappedDeg(row.az + row.off),
                                     gyroHeading: AngularResponse.wrappedDeg(row.g + (k ?? .nan))))
        }
        return (k, hold.anchorConstantDeg, points)
    }

    /// The frozen episode, 02:58:53.5 to 02:59:43.8: 45 rows, all `limited:features` or
    /// `limited:motion`, D from 32.9 to −86.1. Every frame is used, and the held heading is
    /// `cmYaw + K` on every row, to the 0.1° write step — through the whole 51 s, with K 160 s old by
    /// the end and untouched by the step hold.
    @Test func nightHeldHeadingIsTheGyroThroughTheFiftyOneSeconds() throws {
        let run = replayNight()
        let k = try #require(run.k)
        #expect(near(k, 128.2, 1e-9))
        #expect(near(try #require(run.kAfter), k, 1e-9))
        #expect(run.points.count == 79)
        #expect(run.points.allSatisfy { $0.hold == nil })
        let episode = run.points.filter { $0.t >= 53.0 && $0.t <= 104.0 }
        #expect(episode.count == 45)
        #expect(episode.allSatisfy { $0.state != "normal" })
        let first = try #require(episode.first), last = try #require(episode.last)
        #expect(abs(first.gap - 32.9) < 0.05)
        #expect(abs(last.gap - (-86.1)) < 0.05)
        for point in run.points {
            #expect(abs(AngularResponse.signedDelta(point.gyroHeading, point.held)) < 0.1 + 1e-9)
        }
    }

    /// What build 392 showed over the same rows: its frozen offset, 52.3, under an ARKit azimuth that
    /// rotated 120.8° (−0.8 → −121.6) while CoreMotion moved 5.1° (14.1° with one swing at
    /// 02:59:16.5). It started at 02:58:52.5, when ARKit stepped −82° in normal tracking and build
    /// 392's heading fell to 7.6 — 79° from the gyro's 86.2, which the held heading shows.
    @Test func build392SweptTheTargetsWithARKit() throws {
        let run = replayNight()
        let episode = run.points.filter { $0.t >= 53.0 && $0.t <= 104.0 }
        let shown = episode.map(\.build392), gyro = episode.map(\.gyroHeading)
        #expect((shown.max() ?? 0) - (shown.min() ?? 0) > 120)
        #expect((gyro.max() ?? 0) - (gyro.min() ?? 0) < 15)
        let step = try #require(run.points.first { abs($0.t - 52.503) < 1e-6 })
        #expect(abs(step.build392 - 7.6) < 0.05)
        #expect(abs(step.held - 86.2) < 0.05)
    }

    /// 02:59:45.0 to 02:59:48.6, the phone on the nose: the held heading is 92.5–92.6 against the 92.8
    /// track — three of those rows in `limited:features`, where build 392 showed 99.4, 96.7 and 92.2. The
    /// app's own `heading_compare` lines, 02:59:44.4 to 02:59:50.2, log `cmYaw + K` — the held heading
    /// by construction — at 92.1–93.0. At 02:59:49.8 the held heading reads 91.0: the phone had turned
    /// 1.5° left, and build 392, in normal tracking again on that frame, agreed at 90.8.
    @Test func nightPhoneOnTheNoseIsWithinADegreeOfTheTrack() throws {
        let run = replayNight()
        let onTheNose = run.points.filter { $0.t >= 104.5 && $0.t <= 108.6 }
        #expect(onTheNose.count == 4)
        for point in onTheNose {
            #expect(abs(AngularResponse.signedDelta(NightFlightHoldTests.track, point.held)) < 1)
        }
        let compareLines = [92.6, 92.8, 92.6, 92.5, 92.1, 93.0]
        #expect(compareLines.allSatisfy { abs($0 - NightFlightHoldTests.track) < 1 })
        let turned = try #require(run.points.first { abs($0.t - 109.761) < 1e-6 })
        #expect(abs(turned.held - 91.0) < 0.05)
        #expect(abs(AngularResponse.signedDelta(turned.build392, turned.held)) < 0.5)
    }
}
