//
//  GyroYawHoldReplayTests.swift
//  Tally-HoTests
//
//  The gyro yaw hold replayed against the two 2026-10-01 airborne logs, row for row.
//
//  - FL403 (2b8e5508): seeded at 15.6 s with offset −146.1; ARKit's world jumped about 95° across
//    `limited:features` at 21.8 s, Gev's anchor at 30.4 s corrected it by hand to 114.3, and it
//    jumped again, −62°, across 35.5–37.2 s. The hold must reach the anchor's answer on its own,
//    within 5°, and undo the second step.
//  - FL207 (0ce11a8b): ARKit's world wandered out by tens of degrees through a run of
//    `limited:motion` episodes and relocalized back. The hold must follow it out and back, ending
//    where it started rather than accumulating anything.
//
//  Each row is what the CSV holds: `t_since_lift_s`; whether `ar_state` was normal (tracking-state
//  transition events, which carry no azimuths, are rows too); `ar_heading_deg`, ARKit's raw azimuth
//  (0–360, blank unless normal); and `gyro_az_deg`. That column was then the integrated gyro, which
//  stands in for CoreMotion's yaw here: both are inertial and blind to ARKit. The log has no rate
//  column, so the rate each row is gated on is the backward difference of `gyro_az_deg` — all a 1 Hz
//  log can say. On every row the hold compares, any pairing of rows gives under 11°/s.
//
//  At 1 Hz each end's quarter-second window holds one row, so each step is a single row's D.
//

import Testing
import Foundation
@testable import Tally_Ho

struct GyroYawHoldReplayTests {

    private struct Row {
        let t: Double
        let normal: Bool
        let az: Double?
        let gyro: Double?
        /// An alignment applied just after this row, as the log records one.
        var align: (offsetDeg: Double, source: TrackFollowingYawOffset.Source)? = nil
    }

    private struct Replay {
        /// Offset in force after each row, by row index, including any alignment the row carries.
        var offsets: [Double] = []
        /// The same before that alignment: what the hold alone had made of it by then.
        var held: [Double] = []
        /// `K` after each row.
        var anchorConstants: [Double?] = []
        var events: [(t: Double, event: GyroYawHold.Event)] = []
        var hold = GyroYawHold()
    }

    /// Drive the hold through the rows, applying each glitch it hands back as the view controller
    /// does (`offset −= ΔD`) and each logged alignment as the log says it happened.
    private func replay(_ rows: [Row]) -> Replay {
        var result = Replay()
        // Both fixtures begin just after a world reset that had nothing to carry.
        result.hold.worldDidReset(offsetBeforeDeg: .nan, carry: false)
        var offset = Double.nan
        var lastGyro: (t: Double, deg: Double)?
        for row in rows {
            var rate = Double.nan
            if let gyro = row.gyro {
                if let last = lastGyro {
                    rate = AngularResponse.signedDelta(last.deg, gyro) / (row.t - last.t)
                }
                lastGyro = (t: row.t, deg: gyro)
            }
            var gap: Double?
            if row.normal, let az = row.az, let gyro = row.gyro {
                gap = AngularResponse.signedDelta(gyro, az)
            }
            let sample = GyroYawHold.Sample(time: row.t, isNormal: row.normal, gapDeg: gap,
                                            azimuthRateDps: rate)
            if let event = result.hold.add(sample) {
                if event.kind == .glitch, event.refusal == nil {
                    offset = AngularResponse.wrappedDeg(offset - event.deltaDeg)
                }
                result.events.append((t: row.t, event: event))
            }
            result.held.append(offset)
            if let align = row.align {
                offset = align.offsetDeg
                result.hold.recordAlignment(offsetDeg: align.offsetDeg, source: align.source)
            }
            result.offsets.append(offset)
            result.anchorConstants.append(result.hold.anchorConstantDeg)
        }
        return result
    }

    private func index(of t: Double, in rows: [Row]) throws -> Int {
        try #require(rows.firstIndex { abs($0.t - t) < 1e-6 })
    }

    // MARK: - FL403

    private static let fl403: [Row] = [
        Row(t: 13.36, normal: false, az: nil, gyro: -3.6),     // unavailable: the 12.87 s reset
        Row(t: 13.39, normal: false, az: nil, gyro: nil),
        Row(t: 13.41, normal: false, az: nil, gyro: nil),      // limited:initializing
        Row(t: 14.38, normal: false, az: nil, gyro: -3.6),
        Row(t: 14.39, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 15.62, normal: true,  az: 0.6, gyro: -0.1,
            align: (offsetDeg: -146.1, source: .seed)),        // seed_captured 15.63
        Row(t: 16.62, normal: true,  az: 358.8, gyro: -0.0),
        Row(t: 17.88, normal: true,  az: 359.5, gyro: -1.6),
        Row(t: 18.88, normal: true,  az: 300.1, gyro: -63.6),
        Row(t: 20.02, normal: true,  az: 266.8, gyro: -96.1),
        Row(t: 21.03, normal: true,  az: 267.3, gyro: -98.1),
        Row(t: 21.80, normal: false, az: nil, gyro: nil),      // limited:features
        Row(t: 22.27, normal: false, az: nil, gyro: -97.7),
        Row(t: 22.53, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 23.29, normal: true,  az: 2.2, gyro: -98.2),
        Row(t: 24.51, normal: true,  az: 1.9, gyro: -97.3),
        Row(t: 25.52, normal: true,  az: 62.8, gyro: -35.2),
        Row(t: 26.76, normal: true,  az: 96.2, gyro: -3.6),
        Row(t: 27.97, normal: true,  az: 98.9, gyro: 0.1),
        Row(t: 28.98, normal: true,  az: 99.9, gyro: 1.0),
        Row(t: 30.01, normal: true,  az: 100.2, gyro: 0.8,
            align: (offsetDeg: 114.3, source: .anchor)),       // anchor_captured 30.36
        Row(t: 31.23, normal: true,  az: 107.1, gyro: 0.8),
        Row(t: 32.48, normal: true,  az: 104.8, gyro: 0.3),
        Row(t: 33.51, normal: true,  az: 105.6, gyro: 0.1),
        Row(t: 34.68, normal: true,  az: 106.4, gyro: -0.0),
        Row(t: 35.53, normal: false, az: nil, gyro: nil),      // limited:features
        Row(t: 35.75, normal: false, az: nil, gyro: -42.2),
        Row(t: 36.03, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 36.81, normal: false, az: nil, gyro: -42.2),
        Row(t: 37.24, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 37.93, normal: true,  az: 10.5, gyro: -33.9),
        Row(t: 38.03, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 38.33, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 38.96, normal: true,  az: 7.0, gyro: -35.1),
        Row(t: 40.03, normal: true,  az: 6.7, gyro: -34.8),
        Row(t: 41.05, normal: false, az: nil, gyro: nil),      // limited:features
        Row(t: 41.27, normal: false, az: nil, gyro: -35.0),
        Row(t: 41.79, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 42.50, normal: true,  az: 13.3, gyro: -41.1),   // log ends
    ]

    /// Every episode the log contains, decided as the hold decides it. The last one, at 41.05 s, is
    /// still collecting its "after" when the log ends.
    @Test func fl403EpisodesAreDecidedAsExpected() throws {
        let run = replay(GyroYawHoldReplayTests.fl403)
        #expect(run.events.count == 3)
        guard run.events.count == 3 else { return }

        // 21.80–22.53: D 5.4 → 100.4, decided once the after-window closes at 24.51.
        let first = run.events[0]
        #expect(abs(first.t - 24.51) < 1e-6)
        #expect(first.event.kind == .glitch)
        #expect(first.event.refusal == nil)
        #expect(abs(first.event.deltaDeg - 95.0) < 0.05)
        #expect(abs(first.event.gapBeforeDeg - 5.4) < 0.05)
        #expect(abs(first.event.gapAfterDeg - 100.4) < 0.05)
        #expect(abs(first.event.episodeSeconds - 0.73) < 1e-6)

        // 35.53–37.24: D 106.4 → 44.4, decided when tracking drops again at 38.03.
        let second = run.events[1]
        #expect(abs(second.t - 38.03) < 1e-6)
        #expect(second.event.refusal == nil)
        #expect(abs(second.event.deltaDeg - (-62.0)) < 0.05)
        #expect(abs(second.event.episodeSeconds - 1.71) < 1e-6)

        // 38.03–38.33: D 44.4 → 42.1. Under 3°, left alone.
        let third = run.events[2]
        #expect(third.event.refusal == .small)
        #expect(abs(third.event.deltaDeg - (-2.3)) < 0.05)
    }

    /// The acceptance bar: from the 15.6 s seed, with no anchor, the held offset at 30 s is within
    /// 5° of the 114.3 the anchor then measured.
    ///
    /// It lands 4.6° away, and the 4.6° is by design: D drifted 0.7 → 5.4 in normal tracking between
    /// the seed and the episode, and drift is left alone. K-based correction would land within a
    /// degree here, at the cost of importing CoreMotion's own drift — see GyroYawHold.
    @Test func fl403HeldOffsetAtThirtySecondsMeetsTheAnchor() throws {
        let rows = GyroYawHoldReplayTests.fl403
        let run = replay(rows)
        let anchorRow = try index(of: 30.01, in: rows)
        let atThirty = run.held[anchorRow]
        #expect(abs(atThirty - 118.9) < 0.05)
        #expect(abs(AngularResponse.signedDelta(atThirty, 114.3)) <= 5.0)
        // And the anchor constant the anchor leaves behind is the seed's to within a degree — the
        // measurement that says it was ARKit's world that moved, not the gyro.
        let seedRow = try index(of: 15.62, in: rows)
        let kSeed = try #require(run.anchorConstants[seedRow])
        let kAnchor = try #require(run.anchorConstants[anchorRow])
        #expect(abs(kSeed - (-145.4)) < 0.05)
        #expect(abs(AngularResponse.signedDelta(kSeed, kAnchor)) <= 1.0)
    }

    /// The 37.9 s step is undone: the offset moves by exactly −ΔD, and the heading the user sees at
    /// 37.93 s is what gyro continuity from 34.68 s predicts.
    @Test func fl403SecondStepIsUndone() throws {
        let rows = GyroYawHoldReplayTests.fl403
        let run = replay(rows)
        let lastBefore = try index(of: 37.93, in: rows)
        let decided = try index(of: 38.03, in: rows)
        let before = run.offsets[lastBefore]
        let after = run.offsets[decided]
        #expect(abs(before - 114.3) < 1e-9)
        #expect(abs(AngularResponse.signedDelta(before, after) - 62.0) < 0.05)

        // Seen heading = arAz + offset. Predicted from 34.68 s by what the gyro says the phone did.
        let predicted = AngularResponse.wrappedDeg(106.4 + 114.3 + (-33.9 - 0.0))
        let held = AngularResponse.wrappedDeg(10.5 + after)
        let unheld = AngularResponse.wrappedDeg(10.5 + before)
        #expect(abs(AngularResponse.signedDelta(predicted, held)) < 0.1)
        // Without the hold the user saw the 124.8° the log's `hud_heading_deg` records: 62° out.
        #expect(abs(unheld - 124.8) < 0.05)
        #expect(abs(AngularResponse.signedDelta(predicted, unheld)) > 60)

        // Against the anchor constant the residual is the 7° D drifted in normal tracking after the
        // anchor (99.4 → 106.4), left alone by design. Unheld it is 55°.
        let k = try #require(run.hold.anchorConstantDeg)
        let truth = AngularResponse.wrappedDeg(-33.9 + k)
        #expect(abs(AngularResponse.signedDelta(truth, held)) < 8)
        #expect(abs(AngularResponse.signedDelta(truth, unheld)) > 50)
    }

    /// Issue #10's continuous hold on the same flight: at 30 s, before the anchor, `K − D̄` from the
    /// 15.6 s seed lands 0.9° from the 114.3 the anchor then measured, where the step hold alone
    /// (above) lands 4.6° away — the pre-episode drift it leaves alone is exactly what the continuous
    /// hold removes.
    @Test func fl403ContinuousHoldLandsOnTheAnchor() throws {
        var hold = GyroYawHold()
        var smoothed = GyroYawHold.SmoothedGap()
        hold.worldDidReset(offsetBeforeDeg: .nan, carry: false)
        var lastGyro: (t: Double, deg: Double)?
        var atThirty: Double?
        for row in GyroYawHoldReplayTests.fl403 {
            var rate = Double.nan
            if let gyro = row.gyro {
                if let last = lastGyro { rate = AngularResponse.signedDelta(last.deg, gyro) / (row.t - last.t) }
                lastGyro = (t: row.t, deg: gyro)
            }
            var gap: Double?
            if row.normal, let az = row.az, let gyro = row.gyro { gap = AngularResponse.signedDelta(gyro, az) }
            let sample = GyroYawHold.Sample(time: row.t, isNormal: row.normal, gapDeg: gap,
                                            azimuthRateDps: rate)
            _ = hold.add(sample)
            smoothed.add(sample)
            if let align = row.align, align.source == .seed {
                hold.recordAlignment(offsetDeg: align.offsetDeg, source: .seed)
            }
            if abs(row.t - 30.01) < 1e-6, let k = hold.anchorConstantDeg, let d = smoothed.valueDeg {
                atThirty = GyroYawHold.continuousOffsetDeg(anchorConstantDeg: k, smoothedGapDeg: d)
            }
        }
        let offset = try #require(atThirty)
        #expect(abs(offset - 115.2) < 0.05)
        #expect(abs(AngularResponse.signedDelta(offset, 114.3)) <= 1.0)
    }

    // MARK: - FL207

    private static let fl207: [Row] = [
        Row(t: 0.27,  normal: false, az: nil, gyro: nil),      // unavailable
        Row(t: 0.38,  normal: false, az: nil, gyro: nil),      // limited:initializing
        Row(t: 1.27,  normal: false, az: nil, gyro: nil),
        Row(t: 1.67,  normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 2.50,  normal: true,  az: 358.6, gyro: 0.2,
            align: (offsetDeg: -166.7, source: .seed)),        // seed_captured 2.78
        Row(t: 3.53,  normal: true,  az: 1.0, gyro: 0.3),
        Row(t: 4.54,  normal: true,  az: 2.9, gyro: 0.6),
        Row(t: 5.79,  normal: true,  az: 1.6, gyro: 0.6),
        Row(t: 6.53,  normal: false, az: nil, gyro: nil),      // limited:features
        Row(t: 6.79,  normal: false, az: nil, gyro: 1.0),
        Row(t: 7.27,  normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 8.04,  normal: true,  az: 358.3, gyro: -21.9),
        Row(t: 9.04,  normal: true,  az: 360.0, gyro: -19.9),
        Row(t: 10.24, normal: true,  az: 352.3, gyro: -28.6),
        Row(t: 11.26, normal: true,  az: 347.0, gyro: -35.7),
        Row(t: 11.53, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 12.28, normal: false, az: nil, gyro: -27.9),
        Row(t: 12.47, normal: false, az: nil, gyro: nil),      // limited:features
        Row(t: 12.95, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 13.51, normal: true,  az: 353.7, gyro: -28.3),
        Row(t: 14.53, normal: true,  az: 357.2, gyro: -20.9),
        Row(t: 15.53, normal: true,  az: 2.1, gyro: -18.2),
        Row(t: 16.53, normal: true,  az: 4.2, gyro: -9.9),
        Row(t: 17.78, normal: true,  az: 358.3, gyro: -23.6),
        Row(t: 18.79, normal: true,  az: 4.0, gyro: -17.8),
        Row(t: 19.80, normal: true,  az: 6.2, gyro: -15.9),
        Row(t: 20.80, normal: true,  az: 5.5, gyro: -16.6),
        Row(t: 22.04, normal: true,  az: 46.6, gyro: 25.3),
        Row(t: 22.60, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 23.06, normal: false, az: nil, gyro: 24.5),
        Row(t: 24.29, normal: false, az: nil, gyro: 24.5),
        Row(t: 24.86, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 25.51, normal: true,  az: 3.8, gyro: 27.3),
        Row(t: 25.84, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 26.53, normal: false, az: nil, gyro: 27.7),
        Row(t: 26.74, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 27.12, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 27.54, normal: false, az: nil, gyro: 14.3),
        Row(t: 28.44, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 28.76, normal: true,  az: 347.5, gyro: 16.3),
        Row(t: 29.93, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 30.01, normal: false, az: nil, gyro: 20.9),
        Row(t: 30.63, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 30.93, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 31.03, normal: false, az: nil, gyro: 30.8),
        Row(t: 31.33, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 32.05, normal: true,  az: 11.3, gyro: 18.7),
        Row(t: 32.41, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 32.52, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 32.81, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 33.05, normal: false, az: nil, gyro: 8.2),
        Row(t: 33.33, normal: false, az: nil, gyro: nil),      // limited:features
        Row(t: 33.58, normal: false, az: nil, gyro: nil),      // limited:motion
        Row(t: 33.63, normal: false, az: nil, gyro: nil),      // limited:features
        Row(t: 34.05, normal: false, az: nil, gyro: 8.2),
        Row(t: 34.23, normal: true,  az: nil, gyro: nil),      // normal
        Row(t: 35.05, normal: true,  az: 11.7, gyro: 9.7),
        Row(t: 36.27, normal: true,  az: 12.2, gyro: 9.3),
        Row(t: 37.54, normal: true,  az: 23.7, gyro: 20.4),    // Settings opened after this row
    ]

    /// Out by 19° at 6.5 s, out by tens of degrees through the `limited:motion` run, back near zero
    /// by 34 s: the hold follows each step and ends within a couple of degrees of the seed. While the
    /// world was out, it kept the heading within 5° of the gyro where the unheld world was 24° off.
    @Test func fl207RelocalizationComesBackToTheSeed() throws {
        let rows = GyroYawHoldReplayTests.fl207
        let run = replay(rows)
        let applied = run.events.filter { $0.event.refusal == nil }.map { $0.event.deltaDeg }
        #expect(applied.count == 4)
        guard applied.count == 4 else { return }
        #expect(abs(applied[0] - 18.9) < 0.05)     // 6.53 limited:features
        #expect(abs(applied[1] - (-45.6)) < 0.05)  // 22.60 limited:motion
        #expect(abs(applied[2] - 16.1) < 0.05)     // 25.84–31.33, five flaps as one
        #expect(abs(applied[3] - 9.4) < 0.05)      // 32.41–34.23

        let final = try #require(run.offsets.last)
        #expect(abs(AngularResponse.signedDelta(-166.7, final)) < 3.0)

        // Mid-excursion, 20.80 s: seen heading against the seed's K carried by the gyro. Held it is
        // 4.8° out — the D drift in normal tracking either side of the episode, left alone — where
        // the unheld world is 23.7° out.
        let i = try index(of: 20.80, in: rows)
        let k = try #require(run.anchorConstants[i])
        #expect(abs(k - (-168.3)) < 0.05)
        let truth = AngularResponse.wrappedDeg(-16.6 + k)
        let held = AngularResponse.wrappedDeg(5.5 + run.offsets[i])
        let unheld = AngularResponse.wrappedDeg(5.5 - 166.7)
        #expect(abs(AngularResponse.signedDelta(truth, held)) < 6.0)
        #expect(abs(AngularResponse.signedDelta(truth, unheld)) > 20.0)
    }
}
