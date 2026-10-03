//
//  CaptureAnchorConstantTests.swift
//  Tally-HoTests
//
//  Issue #11, QA round 1 note 1: a capture's K is measured over its own samples.
//
//  K is `true heading − cmYaw`. A capture used to store it as its offset (a median over a window) plus
//  the newest single-frame D, which is a different instant: with ARKit's yaw moving under a still
//  phone the two disagree by however far ARKit turned in between. Now every seed, settle and anchor
//  sample carries CoreMotion's yaw at its frame's timestamp, and K is the circular median of
//  `reference − cmYaw` over the very samples the offset is the median of. ARKit does not enter it.
//
//  The streams: a phone held 1° right of the nose (so the K a perfect capture measures is
//  `K_true − 1`), CoreMotion reading `H − K_true` with ±0.1° of alternating noise, and ARKit's world
//  rotating under it, during the window and after it.
//

import Testing
import Foundation
@testable import Tally_Ho

struct CaptureAnchorConstantTests {

    private static let kTrue = 128.2
    private static let track = 92.8
    /// The phone's aim, right of the nose: what a capture measures K against is where the phone points.
    private static let aim = 1.0
    /// `track − cmYaw` while the phone is held at `aim`: the in-window gyro truth.
    private static let truth = kTrue - aim

    /// One sample from the phone's true heading `h` and ARKit's world error `w` (true − ARKit):
    /// ARKit's azimuth `h − w`, and CoreMotion's yaw `h − K_true`, ±0.1° by sample parity.
    private func reading(h: Double, w: Double, k: Int) -> (az: Double, cm: Double) {
        let noise = k % 2 == 0 ? 0.1 : -0.1
        return (az: AngularResponse.wrappedDeg(h - w),
                cm: AngularResponse.wrappedDeg(h - CaptureAnchorConstantTests.kTrue + noise))
    }

    private func off(_ value: Double) -> Double {
        abs(AngularResponse.signedDelta(CaptureAnchorConstantTests.truth, value))
    }

    /// Run an airborne seed at 5 Hz from a card at 0. Returns the estimate, when it published, and
    /// what the old pairing — the offset plus the newest sample's D — would have stored as K.
    private func settle(h: (Double, Int) -> Double, w: (Double) -> Double)
        -> (estimate: AirborneSeedSettle.Estimate, t: Double, oldK: Double)? {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        for k in 0..<40 {
            let t = 0.1 + Double(k) * 0.2
            let r = reading(h: h(t, k), w: w(t), k: k)
            seed.add(arAzimuthDeg: r.az, trackDeg: CaptureAnchorConstantTests.track, cmYawDeg: r.cm, at: t)
            if let estimate = seed.finish(at: t) {
                let newestD = AngularResponse.signedDelta(r.cm, r.az)
                return (estimate: estimate, t: t,
                        oldK: AngularResponse.wrappedDeg(estimate.offsetDeg + newestD))
            }
        }
        return nil
    }

    // MARK: - The airborne seed's three paths

    /// Phone still on the nose, ARKit turning 1.6°/s throughout. The still path publishes at 2.1 s
    /// over a 1.2 s run; K is the window's own, within the noise. The old pairing was 1.1° out: the
    /// run's median sits 0.6 s before the newest D.
    @Test func stillPathKIsTheWindowsOwn() throws {
        let run = try #require(settle(h: { _, _ in CaptureAnchorConstantTests.track + CaptureAnchorConstantTests.aim },
                                      w: { 20 + 1.6 * $0 }))
        #expect(run.estimate.path == .still)
        #expect(abs(run.t - 2.1) < 1e-9)
        #expect(off(try #require(run.estimate.anchorConstantDeg)) <= 0.2)
        #expect(off(run.oldK) > 0.9)
    }

    /// Phone out of a side window (+50°), turned to the nose at 0.8–1.2 s, ARKit turning 3°/s. The
    /// moved path publishes at 1.9 s over the four samples after the turn; K is theirs. The old pairing
    /// was 0.8° out.
    @Test func movedPathKIsTheWindowsOwn() throws {
        let run = try #require(settle(h: { t, _ in
            let track = CaptureAnchorConstantTests.track
            if t < 0.8 { return track + 50 }
            if t < 1.2 { return track + 50 - 49 * (t - 0.8) / 0.4 }
            return track + CaptureAnchorConstantTests.aim
        }, w: { 20 + 3.0 * $0 }))
        #expect(run.estimate.path == .moved)
        #expect(abs(run.t - 1.9) < 1e-9)
        #expect(run.estimate.sampleCount == 4)
        #expect(off(try #require(run.estimate.anchorConstantDeg)) <= 0.2)
        #expect(off(run.oldK) > 0.7)
    }

    /// The case QA caught at 12.4°. Turned to the nose by 0.3 s and steady until 0.9 s — before the
    /// card is a second old, so nothing may publish — then wobbling ±3° for good, while ARKit turns
    /// 2°/s and then 4°/s. Nothing settles, the cap at 5.1 s takes the 0.3–0.9 s window, 4.2 s old,
    /// and ARKit has turned 17° since. K is still the window's own; the old pairing was 17.3° out.
    @Test func capPathKIsTheWindowsOwnHoweverOld() throws {
        let run = try #require(settle(h: { t, k in
            let track = CaptureAnchorConstantTests.track, aim = CaptureAnchorConstantTests.aim
            if t < 0.2 { return track + 50 }
            if t < 1.0 { return track + aim }
            return track + aim + (k % 2 == 0 ? 3 : -3)
        }, w: { t in t < 1.0 ? 20 + 2 * t : 21.8 + 4 * (t - 0.9) }))
        #expect(run.estimate.path == .cap)
        #expect(abs(run.t - 5.1) < 1e-9)
        #expect(run.estimate.sampleCount == 4)
        #expect(abs(run.estimate.windowSeconds - 0.6) < 1e-9)
        #expect(off(try #require(run.estimate.anchorConstantDeg)) <= 0.2)
        #expect(off(run.oldK) > 15)
    }

    /// Without CoreMotion — every existing caller and replay — the estimate has no K, and the caller
    /// pairs the offset with the frame D exactly as before.
    @Test func aSettleFedWithoutCoreMotionHasNoK() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        var published: AirborneSeedSettle.Estimate?
        for k in 0..<20 {
            let t = 0.1 + Double(k) * 0.2
            seed.add(arAzimuthDeg: 100, trackDeg: CaptureAnchorConstantTests.track, at: t)
            if let estimate = seed.finish(at: t) { published = estimate; break }
        }
        let estimate = try #require(published)
        #expect(estimate.anchorConstantDeg == nil)
        #expect(estimate.seed.anchorConstantDeg == nil)
    }

    // MARK: - The startup seed and the flight anchor

    /// A track resample on `StartupSeed`: one second at 5 Hz, ARKit turning 3°/s. K is the capture's
    /// own, and travels on the estimate; the old pairing was 1.4° out.
    @Test func startupSeedKIsTheCapturesOwn() throws {
        var seed = StartupSeed()
        seed.begin(reference: .track)
        var result: (estimate: StartupSeed.Estimate, oldK: Double)?
        for k in 0..<20 {
            let t = 0.1 + Double(k) * 0.2
            let r = reading(h: CaptureAnchorConstantTests.track + CaptureAnchorConstantTests.aim,
                            w: 20 + 3.0 * t, k: k)
            seed.add(arAzimuthDeg: r.az, referenceDeg: CaptureAnchorConstantTests.track, cmYawDeg: r.cm, at: t)
            guard seed.progress(at: t) >= 1.0, let estimate = seed.finish(at: t) else { continue }
            result = (estimate: estimate,
                      oldK: AngularResponse.wrappedDeg(estimate.offsetDeg + AngularResponse.signedDelta(r.cm, r.az)))
            break
        }
        let run = try #require(result)
        #expect(run.estimate.sampleCount == 6)
        #expect(off(try #require(run.estimate.anchorConstantDeg)) <= 0.2)
        #expect(off(run.oldK) > 1.2)
    }

    /// The flight anchor, three seconds at 5 Hz, ARKit turning 1.5°/s (4.5° over the hold, inside the
    /// 5° gate). K is the hold's own; the old pairing was 2.15° out.
    @Test func flightAnchorKIsTheHoldsOwn() throws {
        var anchor = FlightDirectionAnchor()
        anchor.begin(at: 0)
        var last: (az: Double, cm: Double)?
        for k in 0...15 {
            let t = Double(k) * 0.2
            let r = reading(h: CaptureAnchorConstantTests.track + CaptureAnchorConstantTests.aim,
                            w: 20 + 1.5 * t, k: k)
            anchor.add(arAzimuthDeg: r.az, trackDeg: CaptureAnchorConstantTests.track, cmYawDeg: r.cm, at: t)
            last = r
        }
        let newest = try #require(last)
        guard case .success(let estimate) = anchor.finish(at: 3.0) else {
            Issue.record("the anchor refused a steady hold")
            return
        }
        #expect(off(try #require(estimate.anchorConstantDeg)) <= 0.2)
        let oldK = AngularResponse.wrappedDeg(estimate.offsetDeg + AngularResponse.signedDelta(newest.cm, newest.az))
        #expect(off(oldK) > 2.0)
    }

    // MARK: - The window rule and storing K

    /// The median of `reference − cmYaw` over the samples that have CoreMotion, if at least half do.
    @Test func windowKNeedsCoreMotionOnHalfTheSamples() throws {
        let none = GyroYawHold.windowAnchorConstantDeg([(referenceDeg: 92.8, cmYawDeg: nil),
                                                        (referenceDeg: 92.8, cmYawDeg: nil)])
        #expect(none == nil)
        let quarter = GyroYawHold.windowAnchorConstantDeg([(referenceDeg: 92.8, cmYawDeg: -35.4),
                                                           (referenceDeg: 92.8, cmYawDeg: nil),
                                                           (referenceDeg: 92.8, cmYawDeg: nil),
                                                           (referenceDeg: 92.8, cmYawDeg: nil)])
        #expect(quarter == nil)
        let half = GyroYawHold.windowAnchorConstantDeg([(referenceDeg: 92.8, cmYawDeg: -35.4),
                                                        (referenceDeg: 92.8, cmYawDeg: nil),
                                                        (referenceDeg: 92.8, cmYawDeg: -35.2),
                                                        (referenceDeg: 92.8, cmYawDeg: .nan)])
        #expect(abs(try #require(half) - 128.1) < 1e-9)
        #expect(GyroYawHold.windowAnchorConstantDeg([]) == nil)
    }

    /// Constants straddling ±180 median to the seam, not to 0.
    @Test func windowKStaysOnTheSeam() throws {
        let k = GyroYawHold.windowAnchorConstantDeg([(referenceDeg: 100, cmYawDeg: -79.5),
                                                     (referenceDeg: 100, cmYawDeg: -80.5),
                                                     (referenceDeg: 100, cmYawDeg: -79.9)])
        #expect(abs(abs(try #require(k)) - 180) < 1)
    }

    /// A K handed to `recordAlignment` is stored exactly, whatever D the hold has seen, and wins over a
    /// `gapDeg` passed with it. Stored during an episode, it is kept when the episode closes.
    @Test func recordAlignmentStoresAGivenKExactly() throws {
        var hold = GyroYawHold()
        for i in 0..<20 {
            _ = hold.add(GyroYawHold.Sample(time: Double(i) * 0.05, isNormal: true, gapDeg: 10, azimuthRateDps: 1))
        }
        hold.recordAlignment(offsetDeg: 20, source: .seed, anchorConstantDeg: 127.2)
        #expect(abs(try #require(hold.anchorConstantDeg) - 127.2) < 1e-9)
        hold.recordAlignment(offsetDeg: 20, source: .seed, gapDeg: 10, anchorConstantDeg: -170.4)
        #expect(abs(try #require(hold.anchorConstantDeg) - (-170.4)) < 1e-9)

        for i in 0..<20 {                                       // an episode, K stored inside it
            _ = hold.add(GyroYawHold.Sample(time: 1.0 + Double(i) * 0.05, isNormal: false, gapDeg: nil,
                                            azimuthRateDps: 1))
            if i == 10 { hold.recordAlignment(offsetDeg: 20, source: .anchor, anchorConstantDeg: 65) }
        }
        var closed: GyroYawHold.Event?
        for i in 0..<40 {
            if let event = hold.add(GyroYawHold.Sample(time: 2.0 + Double(i) * 0.05, isNormal: true,
                                                       gapDeg: 50, azimuthRateDps: 1)) {
                closed = event
            }
        }
        #expect(try #require(closed).refusal == .realigned)
        #expect(abs(try #require(hold.anchorConstantDeg) - 65) < 1e-9)
        #expect(hold.anchorSource == .anchor)
    }
}
