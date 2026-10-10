//
//  CalibrationCardPolicyTests.swift
//  Tally-HoTests
//
//  Issue #20: the AR view starts at launch under the calibration card, and the card closes when
//  the targets underneath are solid and placed. Combined with #21 (the compass field check), on the
//  ground it also waits for a clean field, for up to ten seconds on the card:
//
//  - Skip: close.
//  - In flight: close.
//  - On the ground: GPS ready, the world aligned, and the field clean or ten seconds on the card.
//  - Fifteen seconds on the card: close, whatever else — and that counts as a Skip.
//
//  What this cannot test: that the card is a child over a live session, that the session, location,
//  traffic and seed really start at launch, and that the targets are solid when it closes. Those are
//  ARKit and UIKit, and only the phone shows them.
//

import Testing
import Foundation
@testable import Tally_Ho

struct CalibrationCardPolicyTests {

    private typealias Reason = CalibrationCardPolicy.CloseReason

    private func reason(gps: Bool = false, aligned: Bool = false, compass: Bool = false,
                        skipped: Bool = false, inFlight: Bool = false,
                        shown: TimeInterval = 1) -> Reason? {
        CalibrationCardPolicy.closeReason(gpsReady: gps, worldAligned: aligned, compassVerified: compass,
                                          skipped: skipped, inFlight: inFlight, secondsShown: shown)
    }

    // MARK: - Skip

    /// Skip closes it whatever else is true.
    @Test func skipClosesItWhateverElseIsTrue() {
        #expect(reason(skipped: true) == .skipped)
        #expect(reason(gps: true, aligned: true, compass: true, skipped: true) == .skipped)
        #expect(reason(skipped: true, inFlight: true) == .skipped)
        #expect(reason(skipped: true, shown: 60) == .skipped)
    }

    // MARK: - In flight

    /// In flight it does not wait for a 10 m fix that a cabin never gives (#15), nor for a field check
    /// that does not run in the air (#21).
    @Test func inFlightItClosesAtOnce() {
        #expect(reason(inFlight: true) == .inFlight)
        #expect(reason(gps: false, aligned: false, compass: false, inFlight: true, shown: 0) == .inFlight)
        // Flying outranks ready, so the log says why it really closed.
        #expect(reason(gps: true, aligned: true, compass: true, inFlight: true) == .inFlight)
    }

    // MARK: - On the ground

    /// GPS ready, the world aligned and the field clean: the targets are solid and placed, on a
    /// compass steering by the Earth's field, so it goes at once.
    @Test func groundClosesWhenAllThreeAreReady() {
        #expect(reason(gps: true, aligned: true, compass: true, shown: 0.5) == .ready)
    }

    /// An unverified field holds it until ten seconds on the card, then it goes anyway — the HUD's
    /// note takes over from there.
    @Test func groundWaitsTenSecondsOnAnUnverifiedField() {
        let wait = CalibrationCardPolicy.compassWaitSeconds
        #expect(reason(gps: true, aligned: true, compass: false, shown: wait - 0.01) == nil)
        #expect(reason(gps: true, aligned: true, compass: false, shown: wait) == .ready)
    }

    /// The ten seconds are the compass card's own wait (#21), and come before the overall timeout.
    @Test func theCompassWaitIsTheCardsTenSeconds() {
        #expect(CalibrationCardPolicy.compassWaitSeconds == CalibrationViewController.fieldWaitSeconds)
        #expect(CalibrationCardPolicy.compassWaitSeconds == 10)
        #expect(CalibrationCardPolicy.compassWaitSeconds < CalibrationCardPolicy.timeoutSeconds)
    }

    /// A clean field never stands in for GPS or alignment: either missing keeps it up, field or not,
    /// and the ten-second wait does not release it either.
    @Test func groundNeedsGPSAndAlignmentWhateverTheField() {
        #expect(reason(gps: true, aligned: false, compass: true) == nil)
        #expect(reason(gps: false, aligned: true, compass: true) == nil)
        #expect(reason(gps: true, aligned: false, compass: false, shown: 12) == nil)
        #expect(reason(gps: false, aligned: true, compass: false, shown: 12) == nil)
        #expect(reason() == nil)
    }

    // MARK: - Timeout

    /// Indoors GPS never reaches 10 m and a seed can fail to land: the card gets out of the way at
    /// fifteen seconds rather than holding the view, clean field or not.
    @Test func timesOutAtFifteenSecondsWhateverElse() {
        let limit = CalibrationCardPolicy.timeoutSeconds
        #expect(limit == 15)
        #expect(reason(shown: limit - 0.01) == nil)
        #expect(reason(shown: limit) == .timeout)
        #expect(reason(gps: true, aligned: false, compass: true, shown: limit) == .timeout)
        #expect(reason(gps: false, aligned: true, compass: true, shown: limit + 5) == .timeout)
    }

    /// Ready reads as ready, not as a timeout, however late it comes.
    @Test func readyOutranksTheTimeout() {
        let late = CalibrationCardPolicy.timeoutSeconds + 10
        #expect(reason(gps: true, aligned: true, compass: false, shown: late) == .ready)
    }

    /// A timeout counts as a Skip (CTO): the GPS-degrade popup must not come back later and reset the
    /// session. Ready and in flight do not, so the ground's prompts still work after landing.
    @Test func aTimeoutCountsAsSkip() {
        #expect(Reason.timeout.countsAsSkip)
        #expect(Reason.skipped.countsAsSkip)
        #expect(!Reason.ready.countsAsSkip)
        #expect(!Reason.inFlight.countsAsSkip)
    }

    /// No clock — the card not yet loaded — never times out or ends the compass wait.
    @Test func noClockNeverTimesOut() {
        #expect(reason(shown: .nan) == nil)
        #expect(reason(gps: true, aligned: true, compass: false, shown: .nan) == nil)
        #expect(reason(gps: true, aligned: true, compass: true, shown: .nan) == .ready)
    }

    /// Both waits are parameters, so the card's own defaults are not the only ones tested.
    @Test func theWaitsCanBeGiven() {
        let compassDone = CalibrationCardPolicy.closeReason(gpsReady: true, worldAligned: true,
                                                            compassVerified: false, skipped: false,
                                                            inFlight: false, secondsShown: 3,
                                                            compassWaitSeconds: 2, timeoutSeconds: 4)
        #expect(compassDone == .ready)
        let timedOut = CalibrationCardPolicy.closeReason(gpsReady: false, worldAligned: false,
                                                         compassVerified: false, skipped: false,
                                                         inFlight: false, secondsShown: 5,
                                                         compassWaitSeconds: 2, timeoutSeconds: 4)
        #expect(timedOut == .timeout)
    }

    /// The reasons as they appear on the `card_closed` line.
    @Test func theLogNamesTheReason() {
        #expect(Reason.ready.rawValue == "ready")
        #expect(Reason.skipped.rawValue == "skipped")
        #expect(Reason.inFlight.rawValue == "in_flight")
        #expect(Reason.timeout.rawValue == "timeout")
    }

    // MARK: - Replayed on the 4 Hz tick

    /// The tick's view of one launch: GPS ready from `gpsAt`, world aligned from `alignedAt`, the field
    /// clean from `cleanAt`, Skip at `skipAt`, flying from `flyingAt`. Returns when and why the card
    /// closes, or nil if it never does within `until`.
    private func replay(gpsAt: TimeInterval = .infinity, alignedAt: TimeInterval = .infinity,
                        cleanAt: TimeInterval = .infinity, skipAt: TimeInterval = .infinity,
                        flyingAt: TimeInterval = .infinity,
                        until: TimeInterval = 60) -> (t: TimeInterval, reason: Reason)? {
        let tick: TimeInterval = 0.25
        var t: TimeInterval = 0
        while t <= until {
            if let why = CalibrationCardPolicy.closeReason(gpsReady: t >= gpsAt, worldAligned: t >= alignedAt,
                                                           compassVerified: t >= cleanAt,
                                                           skipped: t >= skipAt, inFlight: t >= flyingAt,
                                                           secondsShown: t) {
                return (t: t, reason: why)
            }
            t += tick
        }
        return nil
    }

    /// Log 849c560a, the session now started at launch: tracking normal at 2.62 s and the seed at
    /// 3.77 s. With the field checked clean by then, the card closes on the first tick after the seed,
    /// solid and placed, where it used to close first and leave all of that still to come in front of
    /// the user. (The log predates #21 and has no field columns; clean at 2.0 s is assumed.)
    @Test func log849c560aClosesOnTheTickAfterTheSeed() throws {
        let closed = try #require(replay(gpsAt: 1.0, alignedAt: 3.77, cleanAt: 2.0))
        #expect(closed.reason == .ready)
        #expect(closed.t == 4.0)
    }

    /// The same launch beside a car or a railing — the field never verified: ready at ten seconds on
    /// the card, not at the timeout.
    @Test func log849c560aOnADisturbedFieldGoesAtTenSeconds() throws {
        let closed = try #require(replay(gpsAt: 1.0, alignedAt: 3.77))
        #expect(closed.reason == .ready)
        #expect(closed.t == CalibrationCardPolicy.compassWaitSeconds)
    }

    /// The field cleaning up after the user steps away closes it on that tick.
    @Test func aFieldCleaningUpClosesItOnThatTick() throws {
        let closed = try #require(replay(gpsAt: 1.0, alignedAt: 3.77, cleanAt: 6.1))
        #expect(closed.reason == .ready)
        #expect(closed.t == 6.25)
    }

    /// Indoors: aligned, field clean, never a 10 m fix. Out at the timeout, and that counts as a Skip.
    @Test func indoorsItTimesOut() throws {
        let closed = try #require(replay(alignedAt: 3.77, cleanAt: 2.0))
        #expect(closed.reason == .timeout)
        #expect(closed.t == CalibrationCardPolicy.timeoutSeconds)
        #expect(closed.reason.countsAsSkip)
    }

    /// In flight it is gone on the first tick that knows, before any seed or field check.
    @Test func inFlightItIsGoneOnTheFirstTickThatKnows() throws {
        let closed = try #require(replay(flyingAt: 0.4))
        #expect(closed.reason == .inFlight)
        #expect(closed.t == 0.5)
    }

    /// Skip mid-wait.
    @Test func skipMidWait() throws {
        let closed = try #require(replay(gpsAt: 1.0, alignedAt: 3.77, skipAt: 5.1))
        #expect(closed.reason == .skipped)
        #expect(closed.t == 5.25)
    }
}
