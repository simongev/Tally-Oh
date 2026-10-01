//
//  AirborneSeedSettleTests.swift
//  Tally-HoTests
//
//  The airborne seed's trigger: when, after the "hold the phone facing the direction of flight"
//  card, the seed is taken. Build 39 took it 1.1 s after the card, before anyone could have aimed,
//  and was 41.3° wrong. These pin the three ways it may now publish, the one thing it must never
//  do — publish inside the first second — and that the ground seed was left alone.
//
//  Every stream is 5 Hz, as the view controller feeds it, and `finish` is polled after every sample,
//  as the view controller polls it. Sample times start at 0.05 s so that no sample lands exactly on
//  a threshold and a test cannot pass or fail on floating-point rounding.
//

import Testing
import Foundation
@testable import Tally_Ho

struct AirborneSeedSettleTests {

    /// Feed a stream sample by sample, polling after each one, and return the first publication.
    private func run(_ seed: inout AirborneSeedSettle,
                     azimuths: [Double],
                     track: Double,
                     from t0: TimeInterval = 0.05,
                     step: TimeInterval = 0.2) -> (estimate: AirborneSeedSettle.Estimate, at: TimeInterval)? {
        for (i, az) in azimuths.enumerated() {
            let t = t0 + Double(i) * step
            seed.add(arAzimuthDeg: az, trackDeg: track, at: t)
            if let estimate = seed.finish(at: t) { return (estimate: estimate, at: t) }
        }
        return nil
    }

    /// A hand that never holds within the settle spread: alternate samples 4° apart.
    private func wobble(_ i: Int) -> Double { i % 2 == 0 ? 100 : 104 }

    // MARK: - Moved

    /// The case the card exists for. The phone starts out of a side window, the user turns it to the
    /// nose and stops; the seed is the settled aim, not the side window, and it lands inside the bar.
    @Test func movedPathTakesTheSettledAimNotTheStartingOne() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let azimuths: [Double] = [270, 270.5, 269.6,          // reading the card, facing the window
                                  240, 200, 150,              // turning
                                  100, 100.5, 99.8, 100.2,    // settled on the nose
                                  100, 100, 100, 100]
        let published = run(&seed, azimuths: azimuths, track: 104)
        let result = try #require(published)

        #expect(result.estimate.path == .moved)
        // Four settled samples spanning 0.6 s — published at t=1.85, the first moment the run is long
        // enough. Well inside 2–3 s of the card, and before the still path could have fired.
        #expect(abs(result.at - 1.85) < 0.001)
        #expect(result.estimate.cardAgeSeconds < 2.5)
        #expect(result.estimate.sampleCount == 4)
        // track − az over the settled run: 4.0, 3.5, 4.2, 3.8 → median 3.9. The side window would
        // have read 104 − 270 = −166.
        #expect(abs(result.estimate.offsetDeg - 3.9) < 0.001)
        #expect(result.estimate.azimuthSpreadDeg < 1.0)
        #expect(result.estimate.movedDeg > 100)
    }

    /// A pause shorter than the settle time is a pause, not an answer.
    @Test func aBriefPauseMidTurnIsNotASettle() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let azimuths: [Double] = [270, 250, 230, 230.5,       // one-sample pause mid-turn
                                  200, 170, 140, 110,
                                  100, 100.3, 99.9, 100.1, 100, 100]
        let published = run(&seed, azimuths: azimuths, track: 100)
        let result = try #require(published)

        #expect(result.estimate.path == .moved)
        #expect(abs(result.estimate.offsetDeg) < 1.0)   // the final aim, not the pause at 230
    }

    /// A turn of a few degrees is adjusting a grip, not turning to the nose, so it waits for the
    /// still path rather than being read as a settle after movement.
    @Test func aSmallAdjustmentIsNotAMove() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let azimuths = [100, 100.2, 99.9] + Array(repeating: 104.0, count: 17)
        let published = run(&seed, azimuths: azimuths, track: 110)
        let result = try #require(published)

        #expect(result.estimate.path == .still)
        #expect(result.at >= 2.5)
    }

    // MARK: - Still

    /// Already facing forward when the card went up: nothing to wait for but the 2.5 s allowance.
    @Test func stillPathPublishesAtTwoAndAHalfSeconds() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let jitter: [Double] = [0, 0.3, -0.2, 0.1, -0.3, 0.2]
        let azimuths = (0..<30).map { 100 + jitter[$0 % jitter.count] }
        let published = run(&seed, azimuths: azimuths, track: 130)
        let result = try #require(published)

        #expect(result.estimate.path == .still)
        // Steady from the first sample, so only the clock holds it: the first sample at or past 2.5 s.
        #expect(result.at >= 2.5 && result.at < 2.7)
        #expect(result.estimate.cardAgeSeconds >= 2.5)
        #expect(abs(result.estimate.offsetDeg - 30) < 0.5)
        #expect(result.estimate.movedDeg < 1.0)
    }

    /// A phone straddling north is holding still, not swinging through 360°.
    @Test func holdingAcrossNorthIsStill() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let cycle: [Double] = [359.6, 0.3, 359.8, 0.4, 359.7, 0.1]
        let azimuths = (0..<30).map { cycle[$0 % cycle.count] }
        let published = run(&seed, azimuths: azimuths, track: 2)
        let result = try #require(published)

        #expect(result.estimate.path == .still)
        #expect(abs(result.estimate.offsetDeg - 2) < 0.5)
        #expect(result.estimate.azimuthSpreadDeg < 1.0)
    }

    // MARK: - Cap

    /// A hand that never settles: at 5 s take the steadiest window seen, wherever it was.
    @Test func capTakesTheSteadiestWindowAtFiveSeconds() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        // Wobbling 4° throughout, except t=2.85–3.45 where it wobbles 2.5° — steadier, but never
        // within the 2° a settle needs, so neither the moved nor the still path may take it.
        var azimuths = (0..<14).map(wobble)
        azimuths += [110, 112.5, 110, 112.5]
        azimuths += (18..<31).map(wobble)
        let published = run(&seed, azimuths: azimuths, track: 120)
        let result = try #require(published)

        #expect(result.estimate.path == .cap)
        #expect(result.at >= 5.0 && result.at < 5.2)
        #expect(abs(result.estimate.azimuthSpreadDeg - 2.5) < 0.001)
        // track − az over that window: 10, 7.5, 10, 7.5 → 8.75.
        #expect(abs(result.estimate.offsetDeg - 8.75) < 0.001)
        #expect(result.estimate.sampleCount == 4)
    }

    /// The cap is 5 s after the *card*, but the watchdog is 10 s after the *world*. A card that went
    /// up late would let the cap race the watchdog, whose failure path is the `.gravityAndHeading`
    /// world that rotated 176° in flight — so the caller can pull the cap earlier.
    @Test func publishByPullsTheCapAheadOfTheWatchdog() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0, publishBy: 3.0)
        let published = run(&seed, azimuths: (0..<31).map(wobble), track: 100)
        let result = try #require(published)

        #expect(result.estimate.path == .cap)
        #expect(result.at >= 3.0 && result.at < 3.2)
    }

    /// With the default cap the capture always publishes well inside the 10 s watchdog, however
    /// badly the phone is held.
    @Test func aPhoneThatNeverSettlesStillPublishesBeforeTheWatchdog() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let published = run(&seed, azimuths: (0..<60).map(wobble), track: 100)
        let result = try #require(published)

        #expect(result.estimate.path == .cap)
        #expect(result.at < 6.0)
    }

    /// QA round 1's repro. About 1.4 s steady at a side window 40° off the nose while the card is
    /// read (spread 1.8°), then a turn to the nose held with a 2.5° wobble — never within 2° for
    /// 0.5 s, so neither the moved nor the still path fires. The cap used to take the reading pause:
    /// offset −40.9°, spread 1.8°, under the resample gate, wrong for the life of the world. After a
    /// move it may only look at what came after it.
    @Test func capAfterAMoveNeverTakesTheReadingPause() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let reading: [Double] = [140, 141.8, 140.5, 141.8, 140, 141.5, 140.2]  // side window
        let turning: [Double] = [125, 110]
        let atTheNose: [Double] = (0..<30).map { $0 % 2 == 0 ? 100.0 : 102.5 }  // wobbling 2.5°
        let azimuths = reading + turning + atTheNose
        let published = run(&seed, azimuths: azimuths, track: 100)
        let result = try #require(published)

        #expect(result.estimate.path == .cap)
        #expect(result.at >= 5.0 && result.at < 5.2)
        // track − az over the nose hold: 0, −2.5, 0, −2.5 → −1.25. The side window reads −40.9.
        #expect(abs(result.estimate.offsetDeg - (-1.25)) < 0.001)
        #expect(abs(result.estimate.azimuthSpreadDeg - 2.5) < 0.001)
    }

    /// A turn so late that the samples after it do not span a window by the cap: the cap takes
    /// those, not the steadier-looking reading pause before them.
    @Test func capWithALateTurnTakesThePostMoveSamplesNotTheReadingPause() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        // Wobbling 2.5° at the side window until t=4.65 — too loose for the still path — then onto
        // the nose at 4.85 and 5.05, the cap's first sample.
        let sideWindow: [Double] = (0..<24).map { $0 % 2 == 0 ? 140.0 : 142.5 }
        let atTheNose: [Double] = [101, 100, 100.3, 99.8]
        let azimuths = sideWindow + atTheNose
        let published = run(&seed, azimuths: azimuths, track: 100)
        let result = try #require(published)

        #expect(result.estimate.path == .cap)
        #expect(result.at >= 5.0 && result.at < 5.1)
        #expect(result.estimate.sampleCount == 2)              // 4.85 and 5.05, only post-move
        #expect(abs(result.estimate.offsetDeg - (-0.5)) < 0.001)
        #expect(abs(result.estimate.azimuthSpreadDeg - 1.0) < 0.001)
    }

    /// One post-move sample has a spread of zero whatever it caught, which would slip under the
    /// resample gate even mid-turn. So with only one, the cap waits a sample rather than take it —
    /// and still never reaches back before the turn.
    @Test func capNeverSeedsFromASinglePostMoveSample() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        // The turn lands exactly on the cap's first sample, 5.05.
        let sideWindow: [Double] = (0..<25).map { $0 % 2 == 0 ? 140.0 : 142.5 }
        let atTheNose: [Double] = [100, 100.4, 99.9]
        let azimuths = sideWindow + atTheNose
        let published = run(&seed, azimuths: azimuths, track: 100)
        let result = try #require(published)

        #expect(result.estimate.path == .cap)
        #expect(result.at >= 5.2 && result.at < 5.3)            // waited one sample, to 5.25
        #expect(result.estimate.sampleCount == 2)
        #expect(abs(result.estimate.offsetDeg - (-0.2)) < 0.001)
    }

    // MARK: - Never before 1.0 s

    /// A turn finished and settled at 0.85 s is still not taken until the card has been up a second.
    @Test func neverPublishesBeforeOneSecondEvenWhenSettled() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let azimuths = [270.0] + Array(repeating: 100.0, count: 20)
        let published = run(&seed, azimuths: azimuths, track: 100)
        let result = try #require(published)

        #expect(result.estimate.path == .moved)
        #expect(result.at >= 1.0 && result.at < 1.1)
        #expect(result.estimate.cardAgeSeconds >= 1.0)
    }

    /// Not even a deadline can pull a publish inside the first second.
    @Test func publishByNeverPullsTheCapInsideOneSecond() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0, publishBy: 0.2)
        let published = run(&seed, azimuths: Array(repeating: 100.0, count: 20), track: 100)
        let result = try #require(published)

        #expect(result.estimate.path == .cap)
        #expect(result.at >= 1.0 && result.at < 1.1)
    }

    /// Polling at any time under one second, with any history, returns nothing.
    @Test func finishIsNilForTheWholeFirstSecond() {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 10, publishBy: 10)
        for i in 0..<5 {
            let t = 10.05 + Double(i) * 0.2              // 10.05 … 10.85
            seed.add(arAzimuthDeg: i == 0 ? 270 : 100, trackDeg: 100, at: t)
            let finished = seed.finish(at: t)
            #expect(finished == nil)
        }
        #expect(seed.isCapturing)
    }

    // MARK: - Capture mechanics

    /// A reading from before the card cannot be an answer to it. If these counted, the 170° swing
    /// from 270 to 100 would make this a moved capture at ~2 s; ignored, it is a still one.
    @Test func samplesFromBeforeTheCardAreIgnored() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 1.0)
        for t in [0.05, 0.25, 0.45, 0.65, 0.85] {
            seed.add(arAzimuthDeg: 270, trackDeg: 100, at: t)
        }
        let published = run(&seed, azimuths: Array(repeating: 100.0, count: 20),
                            track: 100, from: 1.05)
        let result = try #require(published)

        #expect(result.estimate.path == .still)
        #expect(result.estimate.movedDeg < 1.0)
        #expect(result.estimate.cardAgeSeconds >= 2.5)
    }

    /// Same input, same number, same sign as `StartupSeed` — `track − arAzimuth`, which is what
    /// placement subtracts from every bearing. A sign difference between the two would be silent.
    @Test func offsetHasTheStartupSeedsSignConvention() throws {
        var startup = StartupSeed()
        startup.begin(reference: .track)
        var settle = AirborneSeedSettle()
        settle.begin(cardShownAt: 0)
        for i in 0..<14 {
            let t = 0.05 + Double(i) * 0.2
            startup.add(arAzimuthDeg: 254, referenceDeg: 78, at: t)
            settle.add(arAzimuthDeg: 254, trackDeg: 78, at: t)
        }
        let startupEstimate = startup.finish(at: 2.65)
        let settleEstimate = settle.finish(at: 2.65)
        let s = try #require(startupEstimate)
        let a = try #require(settleEstimate)
        #expect(abs(a.offsetDeg - s.offsetDeg) < 0.001)
        #expect(abs(a.offsetDeg - (-176)) < 0.001)
    }

    /// The hand-off to the existing plumbing: `SeedResamplePolicy` and the log read these fields.
    @Test func seedShapeCarriesTheWindowAndTheTrackReference() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let azimuths: [Double] = [270, 270, 270, 200, 100, 100.4, 99.8, 100.1, 100, 100]
        let published = run(&seed, azimuths: azimuths, track: 104)
        let e = try #require(published).estimate
        let s = e.seed

        #expect(s.referenceKind == .track)
        #expect(s.offsetDeg == e.offsetDeg)
        #expect(s.sampleCount == e.sampleCount)
        #expect(s.seconds == e.windowSeconds)
        #expect(s.azimuthSpreadDeg == e.azimuthSpreadDeg)
        #expect(abs(e.windowSeconds - 0.6) < 0.001)
    }

    /// Not-ready is a no-op, so polling after every sample cannot cost the capture its samples —
    /// the build-30 bug, which `StartupSeed` has a test for too.
    @Test func pollingBeforeReadyLeavesTheCaptureIntact() {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        for i in 0..<5 {
            let t = 0.05 + Double(i) * 0.2
            seed.add(arAzimuthDeg: 100, trackDeg: 130, at: t)
            let finished = seed.finish(at: t)
            #expect(finished == nil)
        }
        #expect(seed.isCapturing)
    }

    /// Publishing clears, so nothing leaks into a later capture.
    @Test func clearsAfterPublishing() throws {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        let published = run(&seed, azimuths: Array(repeating: 100.0, count: 20), track: 130)
        _ = try #require(published)
        #expect(!seed.isCapturing)
        seed.add(arAzimuthDeg: 100, trackDeg: 130, at: 9)
        let finished = seed.finish(at: 9)
        #expect(finished == nil)
    }

    /// A world reset or a lost reference cancels; the samples belong to the old frame.
    @Test func cancelDiscardsTheCapture() {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        for i in 0..<14 { seed.add(arAzimuthDeg: 100, trackDeg: 130, at: 0.05 + Double(i) * 0.2) }
        seed.cancel()
        #expect(!seed.isCapturing)
        let finishedAfterCancel = seed.finish(at: 2.65)
        #expect(finishedAfterCancel == nil)
        seed.add(arAzimuthDeg: 100, trackDeg: 130, at: 3.0)
        let finishedAfterAdd = seed.finish(at: 3.0)
        #expect(finishedAfterAdd == nil)
    }

    @Test func ignoresNonFiniteInputs() {
        var seed = AirborneSeedSettle()
        seed.begin(cardShownAt: 0)
        for i in 0..<30 {
            let t = 0.05 + Double(i) * 0.2
            seed.add(arAzimuthDeg: i % 2 == 0 ? .nan : 100, trackDeg: i % 2 == 0 ? 130 : .infinity, at: t)
            let finished = seed.finish(at: t)
            #expect(finished == nil)
        }
    }

    // MARK: - The ground seed is untouched

    /// The ground seed is compass-referenced and needs no aim, so it keeps the one-second capture:
    /// the same defaults, no card, no settle. A phone still turning 3° every sample — which the
    /// airborne trigger would hold until its 5 s cap — closes here at the first sample a second in.
    @Test func groundCompassSeedIsStillTheOneSecondCapture() throws {
        var seed = StartupSeed()
        #expect(seed.minSeconds == 1.0)
        #expect(seed.minSamples == 5)
        seed.begin(reference: .compass)

        var published: (estimate: StartupSeed.Estimate, at: TimeInterval)?
        for i in 0..<30 {
            let t = 0.05 + Double(i) * 0.2
            seed.add(arAzimuthDeg: 100 + Double(i) * 3, referenceDeg: 130, at: t)
            if seed.progress(at: t) >= 1.0, let e = seed.finish(at: t) {
                published = (estimate: e, at: t)
                break
            }
        }
        let result = try #require(published)
        #expect(result.estimate.referenceKind == .compass)
        #expect(result.at < 1.3)
        // Still not gated on spread: a loose ground seed publishes and reports how loose it was.
        #expect(result.estimate.azimuthSpreadDeg > 10)
    }
}
