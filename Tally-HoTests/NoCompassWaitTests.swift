//
//  NoCompassWaitTests.swift
//  Tally-HoTests
//
//  #21 follow-up, Gev's decision: no compass wait on the ground.
//
//  - The launch card closes on Skip, in flight, GPS ≤ 10 m plus aligned, or 15 s — never held by the
//    compass field.
//  - The ground seed takes the compass as soon as it is otherwise ready, flagged unclean when the
//    field is disturbed or still pending.
//  - After an unclean seed, once the field has stayed clean for 2 s, `FastGroundCorrection` takes the
//    clean compass and slews to it over 1 s; nothing moves while the field is disturbed.
//
//  The replay steps the pure pieces the AR view's 4 Hz tick runs — `CalibrationCardPolicy`,
//  `GroundCompassGate`, `FastGroundCorrection` — in its order: the card first, then, with a position,
//  the field check, the fast correction and the seed. It cannot show ARKit or the render-thread
//  capture itself, which is modelled as log 849c560a measured it: tracking normal at 2.62 s, the
//  capture begun on the next tick and published one second (six samples at 0.2 s) later.
//

import Testing
import Foundation
@testable import Tally_Ho

struct NoCompassWaitTests {

    private typealias Fast = FastGroundCorrection

    // MARK: - FastGroundCorrection

    /// Clean for two seconds at 4 Hz, then a one-second slew. Returns every step with its time.
    private func runClean(from applied: Double, to compass: Double, armed: Bool = true,
                          until: TimeInterval = 6) -> [(t: TimeInterval, step: Fast.Step)] {
        var fast = Fast()
        fast.seedApplied(unclean: armed)
        var offset = applied
        var steps: [(t: TimeInterval, step: Fast.Step)] = []
        var t: TimeInterval = 0
        while t <= until {
            if let step = fast.update(fieldClean: true, compassSampleDeg: compass,
                                      appliedOffsetDeg: offset, canApply: true, at: t) {
                offset = step.offsetDeg
                steps.append((t: t, step: step))
            }
            t += 0.25
        }
        return steps
    }

    @Test func theFastCorrectionFiresAfterTwoSecondsClean() throws {
        let steps = runClean(from: 132.4, to: 128.0)
        let first = try #require(steps.first)
        #expect(first.t == Fast.cleanHoldSeconds)
        #expect(first.step.isFirst)
        #expect(abs(first.step.targetDeg - 128.0) < 1e-9)
        let last = try #require(steps.last)
        #expect(last.step.isLast)
        #expect(abs(last.step.offsetDeg - 128.0) < 1e-9)
    }

    @Test func itSlewsWithinTheBound() throws {
        let steps = runClean(from: 132.4, to: 122.4)          // a 10° correction
        let first = try #require(steps.first)
        let last = try #require(steps.last)
        // The whole slew inside its second.
        #expect(last.t - first.t <= Fast.slewSeconds + 1e-9)
        #expect(Fast.slewSeconds == 1.0)
        // A slide, not a jump: at 4 Hz no step moves more than a quarter of the correction.
        for (a, b) in zip(steps, steps.dropFirst()) {
            #expect(abs(b.step.offsetDeg - a.step.offsetDeg) <= 10.0 / 4 + 1e-9)
        }
        #expect(steps.count == 5)                               // start, 25 %, 50 %, 75 %, done
    }

    @Test func nothingCorrectsWhileTheFieldIsDisturbed() {
        var fast = Fast()
        fast.seedApplied(unclean: true)
        var t: TimeInterval = 0
        while t <= 30 {
            let step = fast.update(fieldClean: false, compassSampleDeg: 128, appliedOffsetDeg: 132.4,
                                   canApply: true, at: t)
            #expect(step == nil)
            t += 0.25
        }
        #expect(fast.isArmed)
        #expect(!fast.isSlewing)
    }

    @Test func aDisturbanceInsideTheHoldStartsItAgain() throws {
        var fast = Fast()
        fast.seedApplied(unclean: true)
        var firstStepAt: TimeInterval?
        var t: TimeInterval = 0
        while t <= 10 && firstStepAt == nil {
            // Clean for 1.5 s, disturbed for one tick at 1.5 s, clean again from 1.75 s.
            let clean = t != 1.5
            if fast.update(fieldClean: clean, compassSampleDeg: 128, appliedOffsetDeg: 132.4,
                           canApply: true, at: t) != nil {
                firstStepAt = t
            }
            t += 0.25
        }
        let first = try #require(firstStepAt)
        #expect(first == 1.75 + Fast.cleanHoldSeconds)
    }

    @Test func aSlewCutShortWaitsForAnotherCleanHold() throws {
        var fast = Fast()
        fast.seedApplied(unclean: true)
        var offset = 132.4
        var starts: [TimeInterval] = []
        var cutAt: Double?
        var t: TimeInterval = 0
        while t <= 10 {
            // Tracking lost for one tick, half-way through the first slew.
            let canApply = t != 2.5
            if let step = fast.update(fieldClean: true, compassSampleDeg: 128, appliedOffsetDeg: offset,
                                      canApply: canApply, at: t) {
                offset = step.offsetDeg
                if step.isFirst { starts.append(t) }
            } else if t == 2.5 {
                cutAt = offset
                #expect(!fast.isSlewing)
                #expect(fast.isArmed)
            }
            t += 0.25
        }
        // Stopped where it stood, part-way there, then a fresh two-second hold before it resumed.
        let stoppedAt = try #require(cutAt)
        #expect(stoppedAt < 132.4 && stoppedAt > 128.0)
        #expect(starts == [2.0, 2.75 + Fast.cleanHoldSeconds])
        #expect(abs(offset - 128.0) < 1e-9)
        #expect(!fast.isArmed)
    }

    @Test func aCleanSeedNeedsNoFastCorrection() {
        #expect(runClean(from: 132.4, to: 128.0, armed: false).isEmpty)
    }

    @Test func itRunsOncePerUncleanSeed() {
        var fast = Fast()
        fast.seedApplied(unclean: true)
        var offset = 132.4
        var completions = 0
        var t: TimeInterval = 0
        while t <= 20 {
            if let step = fast.update(fieldClean: true, compassSampleDeg: 128, appliedOffsetDeg: offset,
                                      canApply: true, at: t) {
                offset = step.offsetDeg
                if step.isLast { completions += 1 }
            }
            t += 0.25
        }
        #expect(completions == 1)
        #expect(!fast.isArmed)
        // The next unclean seed arms it again.
        fast.seedApplied(unclean: true)
        #expect(fast.isArmed)
    }

    @Test func readingsThatDisagreeAreNotActedOn() {
        var fast = Fast()
        fast.seedApplied(unclean: true)
        var t: TimeInterval = 0
        var fired = false
        while t <= 10 {
            // A phone swinging hard: the compass readings 60° apart, tick to tick.
            let sample = Int(t * 4) % 2 == 0 ? 100.0 : 160.0
            if fast.update(fieldClean: true, compassSampleDeg: sample, appliedOffsetDeg: 132.4,
                           canApply: true, at: t) != nil {
                fired = true
            }
            t += 0.25
        }
        #expect(!fired)
    }

    @Test func itTakesTheShortWayAcrossTheSeam() throws {
        let steps = runClean(from: 179.0, to: -179.0)
        let last = try #require(steps.last)
        #expect(abs(AngularResponse.signedDelta(last.step.offsetDeg, -179.0)) < 1e-9)
        // Two degrees across ±180, not 358 the long way round.
        for (a, b) in zip(steps, steps.dropFirst()) {
            #expect(abs(AngularResponse.signedDelta(a.step.offsetDeg, b.step.offsetDeg)) <= 0.5 + 1e-9)
        }
    }

    @Test func nothingAppliesWhenItCannot() {
        var fast = Fast()
        fast.seedApplied(unclean: true)
        var t: TimeInterval = 0
        while t <= 10 {
            // World unusable, a flight anchor, or no alignment: the hold never completes.
            #expect(fast.update(fieldClean: true, compassSampleDeg: 128, appliedOffsetDeg: 132.4,
                                canApply: false, at: t) == nil)
            t += 0.25
        }
    }

    // MARK: - Log 849c560a replayed on the 4 Hz tick

    private struct Launch {
        var firstFixAt: TimeInterval = 1.0
        var gpsReadyAt: TimeInterval = 1.0
        /// Tracking `.normal`: the ground compass capture may begin.
        var normalAt: TimeInterval = 2.62
        /// The field's verdict at time t.
        var field: (TimeInterval) -> MagneticFieldIntegrity.Verdict
        /// What the compass reads (true heading) and what the clean compass would read.
        var seedCompassOffsetDeg: Double = 132.4
        var cleanCompassOffsetDeg: Double = 128.0
    }

    private struct Outcome {
        var seedBeganAt: TimeInterval?
        var seedPublishedAt: TimeInterval?
        var seedUnclean: Bool?
        var cardClosedAt: TimeInterval?
        var closeReason: CalibrationCardPolicy.CloseReason?
        var fastStartedAt: TimeInterval?
        var fastDoneAt: TimeInterval?
        var offsets: [(t: TimeInterval, deg: Double)] = []
    }

    /// One second of capture: six samples 0.2 s apart from the tick that begins it (log 849c560a:
    /// `seed_captured … n=6 secs=1.0`), published on the render thread between ticks.
    private static let captureSeconds: TimeInterval = 1.0

    private func replay(_ launch: Launch, until: TimeInterval = 20) -> Outcome {
        var gate = GroundCompassGate()
        var fast = FastGroundCorrection()
        var out = Outcome()
        var cardUp = true
        var applied: Double?
        var beganUnclean = false
        var t: TimeInterval = 0
        while t <= until {
            let hasPosition = t >= launch.firstFixAt
            // A capture that completed on the render thread since the last tick has been applied.
            // The render thread publishes just after the boundary tick, so the first tick to see it is
            // the one after (log 849c560a: published 3.77 s, between the 3.75 s and 4.0 s ticks).
            if let began = out.seedBeganAt, out.seedPublishedAt == nil, t > began + Self.captureSeconds {
                out.seedPublishedAt = began + Self.captureSeconds
                applied = launch.seedCompassOffsetDeg
                let unclean = beganUnclean || gate.seedIsUnclean
                out.seedUnclean = unclean
                fast.seedApplied(unclean: unclean)
            }
            // `updateLaunchCard`, ahead of the position guard.
            if cardUp {
                let aligned = out.seedPublishedAt != nil && t >= launch.normalAt && hasPosition
                if let why = CalibrationCardPolicy.closeReason(
                    gpsReady: t >= launch.gpsReadyAt, worldAligned: aligned,
                    skipped: false, inFlight: false, secondsShown: t) {
                    cardUp = false
                    out.cardClosedAt = t
                    out.closeReason = why
                }
            }
            if hasPosition {
                // `updateCompassFieldCheck`, then `updateFastGroundCorrection`.
                gate.update(launch.field(t))
                if let current = applied,
                   let step = fast.update(fieldClean: gate.verdict == .clean,
                                          compassSampleDeg: gate.verdict == .clean
                                              ? launch.cleanCompassOffsetDeg : launch.seedCompassOffsetDeg,
                                          appliedOffsetDeg: current, canApply: true, at: t) {
                    applied = step.offsetDeg
                    if step.isFirst { out.fastStartedAt = t }
                    if step.isLast { out.fastDoneAt = t }
                }
                // `updateStartupSeed`: the compass reference never consults the field.
                if out.seedBeganAt == nil, t >= launch.normalAt,
                   GroundCompassGate.seedCompassReferenceDeg(trueHeadingDeg: 132, headingAccuracyDeg: 11.6,
                                                             maxHeadingAccuracyDeg: 25) != nil {
                    out.seedBeganAt = t
                    beganUnclean = gate.seedIsUnclean
                }
            }
            if let applied { out.offsets.append((t: t, deg: applied)) }
            t += 0.25
        }
        return out
    }

    /// The field clean from the first fix: the seed captures clean, publishes at 3.75 s (the log's
    /// 3.77 s), and the card closes on the next tick. No fast correction: nothing to correct.
    @Test func log849c560aWithACleanFieldClosesAtAboutFourSeconds() {
        let out = replay(Launch(field: { _ in .clean }))
        #expect(out.seedBeganAt == 2.75)
        #expect(out.seedPublishedAt == 3.75)
        #expect(out.seedUnclean == false)
        #expect(out.closeReason == .ready)
        #expect(out.cardClosedAt == 4.0)
        #expect(out.fastStartedAt == nil)
    }

    /// The same launch beside a car or a railing — the field never clean: the card closes at exactly
    /// the same tick, and the seed goes ahead flagged unclean.
    @Test func log849c560aWithADisturbedFieldClosesAtAboutFourSeconds() {
        let out = replay(Launch(field: { _ in .disturbed }))
        #expect(out.seedBeganAt == 2.75)
        #expect(out.seedPublishedAt == 3.75)
        #expect(out.seedUnclean == true)
        #expect(out.closeReason == .ready)
        #expect(out.cardClosedAt == 4.0)
        // And nothing moves while it stays disturbed.
        #expect(out.fastStartedAt == nil)
        #expect(out.offsets.allSatisfy { $0.deg == 132.4 })
    }

    /// A field still pending at the seed — the monitor's first verdict not in yet — flags it unclean too.
    @Test func aPendingFieldAtTheSeedFlagsItUnclean() {
        let out = replay(Launch(field: { t in t < 5 ? .pending : .clean }))
        #expect(out.seedUnclean == true)
        #expect(out.cardClosedAt == 4.0)
    }

    /// The user steps away from the metal at 8 s: two seconds of clean field, then a one-second slide
    /// to the clean compass — done at 11 s, against the ordinary correction's warm-up of five seconds
    /// of samples and a 40° pan before it would move at all.
    @Test func steppingAwayCorrectsTheHeadingFast() throws {
        let out = replay(Launch(field: { t in t < 8 ? .disturbed : .clean }))
        #expect(out.cardClosedAt == 4.0)
        let started = try #require(out.fastStartedAt)
        let done = try #require(out.fastDoneAt)
        #expect(started == 8 + FastGroundCorrection.cleanHoldSeconds)
        #expect(done - started <= FastGroundCorrection.slewSeconds + 1e-9)
        // Held at the unclean seed until then, at the clean compass after.
        #expect(out.offsets.filter { $0.t < started }.allSatisfy { $0.deg == 132.4 })
        let final = try #require(out.offsets.last)
        #expect(abs(final.deg - 128.0) < 1e-9)
    }
}
