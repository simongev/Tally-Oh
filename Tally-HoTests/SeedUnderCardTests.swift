//
//  SeedUnderCardTests.swift
//  Tally-HoTests
//
//  The seed's clean-field grace under the launch card (#20 with #21, CTO decision).
//
//  - While the card is up the seed waits the card's own ten seconds for a clean field, not three: the
//    card hides the view, so waiting costs nothing, and a user who steps away from the metal gets a
//    clean seed rather than one the ground correction fixes later. Once the card is gone — an
//    in-session re-seed — three seconds, as #21 built it.
//  - Ten seconds is longer than the seed's 10 s watchdog allows, and the watchdog's fallback restarts
//    the session. So while the card is up, a seed waiting on the field alone has its watchdog renewed
//    each tick instead of fired, and the card's close renews it once more. The card's 15 s timeout
//    bounds the whole thing.
//
//  The replays below step the pure pieces — `GroundCompassGate`, `CalibrationCardPolicy` and the
//  watchdog's renew rule (`max(deadline, now + 10 s)`, as `renewSeedWatchdogAfterOverlay`) — in the
//  order the AR view's 4 Hz tick runs them: the card (and its hold) first, then, with a position, the
//  field check and the seed. They cannot show ARKit or the capture itself; the capture is modelled as
//  the 1.15 s log 849c560a measured from `normal` to `seed_captured`.
//

import Testing
import Foundation
@testable import Tally_Ho

struct SeedUnderCardTests {

    private typealias Reason = CalibrationCardPolicy.CloseReason

    // MARK: - The gate

    /// With the card up the seed waits the card's ten seconds on an unclean field.
    @Test func tenSecondGraceWithTheCardUp() {
        var gate = GroundCompassGate()
        gate.update(.disturbed, at: 1)
        let early = gate.seedMayUseCompass(at: 1 + 9.9, cardUp: true)
        let atTen = gate.seedMayUseCompass(at: 1 + 10, cardUp: true)
        #expect(!early)
        #expect(atTen)
        #expect(GroundCompassGate.seedGrace(cardUp: true) == 10)
        #expect(GroundCompassGate.cardUpSeedGraceSeconds == CalibrationViewController.fieldWaitSeconds)
        #expect(GroundCompassGate.cardUpSeedGraceSeconds == CalibrationCardPolicy.compassWaitSeconds)
    }

    /// With the card gone — an in-session re-seed — three seconds, as #21 built it.
    @Test func threeSecondGraceWithTheCardGone() {
        var gate = GroundCompassGate()
        gate.update(.pending, at: 1)
        let early = gate.seedMayUseCompass(at: 1 + 2.9, cardUp: false)
        let atThree = gate.seedMayUseCompass(at: 1 + 3, cardUp: false)
        let byDefault = gate.seedMayUseCompass(at: 1 + 3)
        #expect(!early)
        #expect(atThree)
        #expect(byDefault)
        #expect(GroundCompassGate.seedGrace(cardUp: false) == GroundCompassGate.seedGraceSeconds)
        #expect(GroundCompassGate.seedGraceSeconds == 3)
    }

    /// A clean field, or a device that cannot measure one, needs no grace either way.
    @Test func aCleanFieldNeedsNoGraceEitherWay() {
        var clean = GroundCompassGate()
        clean.update(.clean, at: 0)
        #expect(clean.seedMayUseCompass(at: 0, cardUp: true))
        #expect(clean.seedMayUseCompass(at: 0, cardUp: false))
        var unmeasurable = GroundCompassGate()
        unmeasurable.update(.unavailable, at: 0)
        #expect(unmeasurable.seedMayUseCompass(at: 0, cardUp: true))
    }

    /// Unclean with the card up reads as proceeding unclean only once the ten seconds are out.
    @Test func proceedingUncleanFollowsTheCardsGrace() {
        var gate = GroundCompassGate()
        gate.update(.disturbed, at: 0)
        let cardUpAtFive = gate.seedProceedsUnclean(at: 5, cardUp: true)
        let cardGoneAtFive = gate.seedProceedsUnclean(at: 5, cardUp: false)
        let cardUpAtTen = gate.seedProceedsUnclean(at: 10, cardUp: true)
        #expect(!cardUpAtFive)
        #expect(cardGoneAtFive)
        #expect(cardUpAtTen)
    }

    /// The watchdog is held only with the card up, the compass otherwise usable, and the gate refusing.
    @Test func theWatchdogIsHeldOnlyForASeedWaitingOnTheField() {
        var gate = GroundCompassGate()
        gate.update(.disturbed, at: 0)
        let held = gate.holdsSeedWatchdog(cardUp: true, compassOtherwiseUsable: true, at: 5)
        let cardGone = gate.holdsSeedWatchdog(cardUp: false, compassOtherwiseUsable: true, at: 5)
        let noCompass = gate.holdsSeedWatchdog(cardUp: true, compassOtherwiseUsable: false, at: 5)
        let graceOut = gate.holdsSeedWatchdog(cardUp: true, compassOtherwiseUsable: true, at: 10)
        #expect(held)
        #expect(!cardGone)
        #expect(!noCompass)
        #expect(!graceOut)

        var clean = GroundCompassGate()
        clean.update(.clean, at: 0)
        let cleanHeld = clean.holdsSeedWatchdog(cardUp: true, compassOtherwiseUsable: true, at: 5)
        #expect(!cleanHeld)

        // Before the first ground tick there is no verdict at all: waiting on the field, so held.
        let fresh = GroundCompassGate()
        let freshHeld = fresh.holdsSeedWatchdog(cardUp: true, compassOtherwiseUsable: true, at: 0.5)
        #expect(freshHeld)
    }

    // MARK: - Replayed on the 4 Hz tick

    private struct Launch {
        /// First fix: the tick's position guard opens, and the field check starts feeding the gate.
        var firstFixAt: TimeInterval = 1.0
        /// Tracking `.normal`: the ground compass capture may begin.
        var normalAt: TimeInterval = 2.62
        /// The card's GPS row reaches 10 m.
        var gpsReadyAt: TimeInterval = 1.0
        /// The field reads clean from here; before it, `unclean`.
        var cleanFrom: TimeInterval = .infinity
        var unclean: MagneticFieldIntegrity.Verdict = .pending
        /// The hold and the renew at close. False models the 10 s grace without them.
        var holdsWatchdog = true
    }

    private struct Outcome {
        var seedBeganAt: TimeInterval?
        var seedBeganWithCardUp: Bool?
        var seedPublishedAt: TimeInterval?
        /// The watchdog fired: `seed_fallback`, a session restart.
        var fallbackAt: TimeInterval?
        var cardClosedAt: TimeInterval?
        var closeReason: Reason?
    }

    private static let tick: TimeInterval = 0.25
    /// `ARTrafficViewController.seedReferenceTimeoutSeconds`.
    private static let watchdogSeconds: TimeInterval = 10
    /// Log 849c560a: `normal` at 2.62 s, `seed_captured` at 3.77 s.
    private static let captureSeconds: TimeInterval = 1.15

    private func run(_ launch: Launch, until: TimeInterval = 40) -> Outcome {
        var gate = GroundCompassGate()
        var deadline = Self.watchdogSeconds      // the world starts at launch, t = 0
        var cardUp = true
        var awaitingSeed = true
        var began: TimeInterval?
        var out = Outcome()
        var t: TimeInterval = 0
        while t <= until {
            let hasPosition = t >= launch.firstFixAt
            // `updateLaunchCard`: the hold, then the card's close rule; a close renews once more.
            if cardUp {
                let held = gate.holdsSeedWatchdog(cardUp: true, compassOtherwiseUsable: true, at: t)
                if launch.holdsWatchdog, held, awaitingSeed {
                    deadline = max(deadline, t + Self.watchdogSeconds)
                }
                let aligned = out.seedPublishedAt != nil && t >= launch.normalAt && hasPosition
                let why = CalibrationCardPolicy.closeReason(
                    gpsReady: t >= launch.gpsReadyAt, worldAligned: aligned,
                    compassVerified: gate.verdict == .clean, skipped: false, inFlight: false,
                    secondsShown: t)
                if let why {
                    cardUp = false
                    out.cardClosedAt = t
                    out.closeReason = why
                    if launch.holdsWatchdog, awaitingSeed {
                        deadline = max(deadline, t + Self.watchdogSeconds)
                    }
                }
            }
            // The position guard, then `updateCompassFieldCheck`, then `updateStartupSeed`.
            if hasPosition {
                let verdict: MagneticFieldIntegrity.Verdict = t >= launch.cleanFrom ? .clean : launch.unclean
                gate.update(verdict, at: t)
                if awaitingSeed {
                    if t >= deadline {
                        out.fallbackAt = t
                        return out
                    }
                    let mayUse = gate.seedMayUseCompass(at: t, cardUp: cardUp)
                    if let start = began {
                        if !mayUse {
                            began = nil                         // reference taken away: cancelled
                        } else if t - start >= Self.captureSeconds {
                            out.seedPublishedAt = t
                            awaitingSeed = false
                        }
                    } else if mayUse && t >= launch.normalAt {
                        began = t
                        out.seedBeganAt = t
                        out.seedBeganWithCardUp = cardUp
                    }
                }
            }
            if !awaitingSeed && !cardUp { return out }
            t += Self.tick
        }
        return out
    }

    /// Log 849c560a with the field clean by 2 s: the seed captures under the card on a clean field,
    /// publishes at 4.0 s, and the card closes on the next tick, compass verified. No reset.
    @Test func log849c560aWithACleanField() throws {
        let out = run(Launch(cleanFrom: 2.0))
        #expect(out.fallbackAt == nil)
        #expect(out.seedBeganAt == 2.75)
        #expect(out.seedBeganWithCardUp == true)
        #expect(out.seedPublishedAt == 4.0)
        #expect(out.closeReason == .ready)
        #expect(out.cardClosedAt == 4.25)
    }

    /// Log 849c560a with a field that never verifies: the seed waits out the card's ten seconds from
    /// the first fix, proceeds at 11.0 s under the card, publishes at 12.25 s, and the card closes at
    /// 12.5 s — with no reset, though the old 10 s watchdog passed at 10.0 s.
    @Test func log849c560aWithAFieldThatNeverVerifies() throws {
        let out = run(Launch())
        #expect(out.fallbackAt == nil)
        #expect(out.seedBeganAt == 11.0)
        #expect(out.seedBeganWithCardUp == true)
        #expect(out.seedPublishedAt == 12.25)
        #expect(out.closeReason == .ready)
        #expect(out.cardClosedAt == 12.5)
        let closedAt = try #require(out.cardClosedAt)
        #expect(closedAt < CalibrationCardPolicy.timeoutSeconds)
    }

    /// The control: the ten-second grace without the hold falls back — restarting the session under
    /// the card — at the old 10 s watchdog. This is what the hold is for.
    @Test func withoutTheHoldTheTenSecondGraceWouldResetTheSession() {
        let out = run(Launch(holdsWatchdog: false))
        #expect(out.fallbackAt == 10.0)
        #expect(out.seedPublishedAt == nil)
        #expect(out.cardClosedAt == nil)
    }

    /// The card closes on its 15 s timeout with no seed yet — here a first fix at 6 s, so the card's
    /// ten-second grace would run to 16 s. The seed falls to the three-second grace on the renewed
    /// watchdog and publishes, with no reset; the timeout counts as a Skip.
    @Test func timeoutThenSeed() throws {
        let out = run(Launch(firstFixAt: 6.0, gpsReadyAt: 6.0))
        #expect(out.closeReason == .timeout)
        #expect(out.cardClosedAt == CalibrationCardPolicy.timeoutSeconds)
        let reason = try #require(out.closeReason)
        #expect(reason.countsAsSkip)
        #expect(out.seedBeganAt == 15.0)
        #expect(out.seedBeganWithCardUp == false)
        #expect(out.seedPublishedAt == 16.25)
        #expect(out.fallbackAt == nil)
    }

    /// Never a fallback, and so never a reset, while the card is up — whenever the field clears, if it
    /// does, disturbed or pending, early or late fix. The 9.5 s case is the cliff a skipped (rather
    /// than renewed) watchdog would fall off: a capture begun just before 10 s.
    @Test func noFallbackOrResetWhileTheCardIsUp() {
        let cleanTimes: [TimeInterval] = [0.5, 3.0, 6.0, 9.5, 11.0, 14.0, .infinity]
        let fixTimes: [TimeInterval] = [0.5, 1.0, 4.0, 8.0, 12.0]
        let uncleanVerdicts: [MagneticFieldIntegrity.Verdict] = [.pending, .disturbed]
        var cases = 0
        var fallbacksUnderCard = 0
        var resets = 0
        var unpublished = 0
        for clean in cleanTimes {
            for fix in fixTimes {
                for unclean in uncleanVerdicts {
                    let out = run(Launch(firstFixAt: fix, gpsReadyAt: fix, cleanFrom: clean, unclean: unclean))
                    cases += 1
                    if let fell = out.fallbackAt {
                        resets += 1
                        if out.cardClosedAt == nil || fell < (out.cardClosedAt ?? 0) { fallbacksUnderCard += 1 }
                    }
                    if out.seedPublishedAt == nil { unpublished += 1 }
                }
            }
        }
        #expect(cases == 70)
        #expect(fallbacksUnderCard == 0)
        // With tracking normal and a heading, every one of these seeds — none needs the fallback.
        #expect(resets == 0)
        #expect(unpublished == 0)
    }

    /// The bound: a seed waiting on the field that cannot capture either (tracking never normal) gets
    /// no fallback under the card; the 15 s timeout closes the card, and the renewed watchdog falls
    /// back 10 s after that, as it always would have.
    @Test func theCardsTimeoutBoundsTheHold() {
        let out = run(Launch(normalAt: 100))
        #expect(out.closeReason == .timeout)
        #expect(out.cardClosedAt == 15.0)
        #expect(out.fallbackAt == 25.0)
    }

    /// The hold is for a seed waiting on the field alone. With the field clean and tracking never
    /// normal the seed is waiting on ARKit, not the field, and the watchdog runs as it did before —
    /// falling back under the card, a little later than 10 s only by the ticks the field was still
    /// pending.
    @Test func aSeedWaitingOnTrackingIsNotHeld() throws {
        let out = run(Launch(normalAt: 100, cleanFrom: 2.0))
        let fell = try #require(out.fallbackAt)
        #expect(fell >= 10)
        #expect(fell < CalibrationCardPolicy.timeoutSeconds)
        #expect(out.cardClosedAt == nil)
    }
}
