//
//  CalibrationCardPolicyTests.swift
//  Tally-HoTests
//
//  Issue #20: the AR view starts at launch under the calibration card, and the card closes when
//  the targets underneath are solid and placed — GPS ready and the world aligned — or on Skip, in
//  flight, or after a timeout.
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

    private func reason(gps: Bool = false, aligned: Bool = false, skipped: Bool = false,
                        inFlight: Bool = false, shown: TimeInterval = 1) -> Reason? {
        CalibrationCardPolicy.closeReason(gpsReady: gps, worldAligned: aligned, skipped: skipped,
                                          inFlight: inFlight, secondsShown: shown)
    }

    // MARK: - The four ways out

    /// GPS ready and the world aligned underneath: the targets are solid and placed, so it goes.
    @Test func closesWhenGPSIsReadyAndTheWorldIsAligned() {
        #expect(reason(gps: true, aligned: true) == .ready)
    }

    /// Either alone is not enough: a fix with the world still unaligned would show faded targets, and
    /// an aligned world with no fix to place from shows nothing worth having.
    @Test func staysUpOnEitherAlone() {
        #expect(reason(gps: true, aligned: false) == nil)
        #expect(reason(gps: false, aligned: true) == nil)
        #expect(reason() == nil)
    }

    /// Skip closes it whatever else is true.
    @Test func skipClosesItWhateverElseIsTrue() {
        #expect(reason(skipped: true) == .skipped)
        #expect(reason(gps: true, aligned: true, skipped: true) == .skipped)
        #expect(reason(skipped: true, inFlight: true) == .skipped)
        #expect(reason(skipped: true, shown: 60) == .skipped)
    }

    /// In flight it does not wait for a 10 m fix that a cabin never gives (#15).
    @Test func inFlightItClosesAtOnce() {
        #expect(reason(inFlight: true) == .inFlight)
        #expect(reason(gps: false, aligned: false, inFlight: true, shown: 0) == .inFlight)
        // Flying outranks ready, so the log says why it really closed.
        #expect(reason(gps: true, aligned: true, inFlight: true) == .inFlight)
    }

    /// Indoors GPS never reaches 10 m and a seed can fail to land: the card gets out of the way at the
    /// timeout rather than holding the view.
    @Test func timesOutIfNeitherComes() {
        let limit = CalibrationCardPolicy.timeoutSeconds
        #expect(reason(shown: limit - 0.01) == nil)
        #expect(reason(shown: limit) == .timeout)
        #expect(reason(gps: true, aligned: false, shown: limit + 5) == .timeout)
        #expect(reason(gps: false, aligned: true, shown: limit + 5) == .timeout)
    }

    /// Ready before the timeout reads as ready, not as a timeout, however late it comes.
    @Test func readyOutranksTheTimeout() {
        let late = CalibrationCardPolicy.timeoutSeconds + 10
        #expect(reason(gps: true, aligned: true, shown: late) == .ready)
    }

    /// No clock — the card not yet loaded — never times out.
    @Test func noClockNeverTimesOut() {
        #expect(reason(shown: .nan) == nil)
        #expect(reason(gps: true, aligned: true, shown: .nan) == .ready)
    }

    /// The timeout is a parameter, so the card's own default is not the only one tested.
    @Test func theTimeoutCanBeGiven() {
        let early = CalibrationCardPolicy.closeReason(gpsReady: false, worldAligned: false,
                                                      skipped: false, inFlight: false,
                                                      secondsShown: 3, timeoutSeconds: 2)
        #expect(early == .timeout)
    }

    /// Long enough for a ground seed to land under the card — log 849c560a had it at 3.77 s after
    /// the session started, and the seed's own fallback hands the world back to the heading at 10 s
    /// — and short enough not to hold the view hostage.
    @Test func theTimeoutOutlastsTheSeedAndItsFallback() {
        #expect(CalibrationCardPolicy.timeoutSeconds > 10)
        #expect(CalibrationCardPolicy.timeoutSeconds <= 20)
    }

    /// The reasons as they appear on the `card_closed` line.
    @Test func theLogNamesTheReason() {
        #expect(Reason.ready.rawValue == "ready")
        #expect(Reason.skipped.rawValue == "skipped")
        #expect(Reason.inFlight.rawValue == "in_flight")
        #expect(Reason.timeout.rawValue == "timeout")
    }

    // MARK: - Replayed on the 4 Hz tick

    /// The tick's view of one launch: GPS ready from `gpsAt`, world aligned from `alignedAt`, Skip at
    /// `skipAt`, flying from `flyingAt`. Returns when and why the card closes, or nil if it never
    /// does within `until`.
    private func replay(gpsAt: TimeInterval = .infinity, alignedAt: TimeInterval = .infinity,
                        skipAt: TimeInterval = .infinity, flyingAt: TimeInterval = .infinity,
                        until: TimeInterval = 60) -> (t: TimeInterval, reason: Reason)? {
        let tick: TimeInterval = 0.25
        var t: TimeInterval = 0
        while t <= until {
            if let why = CalibrationCardPolicy.closeReason(gpsReady: t >= gpsAt, worldAligned: t >= alignedAt,
                                                           skipped: t >= skipAt, inFlight: t >= flyingAt,
                                                           secondsShown: t) {
                return (t: t, reason: why)
            }
            t += tick
        }
        return nil
    }

    /// Log 849c560a, the session now started at launch: tracking normal at 2.62 s and the seed at
    /// 3.77 s. The card closes on the first tick after the seed, solid and placed, where it used to
    /// close first and leave all of that still to come in front of the user.
    @Test func groundLaunchClosesOnTheTickAfterTheSeed() throws {
        let closed = try #require(replay(gpsAt: 1.0, alignedAt: 3.77))
        #expect(closed.reason == .ready)
        #expect(closed.t == 4.0)
    }

    /// GPS the last to arrive: it closes when GPS does.
    @Test func gpsLastClosesWhenGPSArrives() throws {
        let closed = try #require(replay(gpsAt: 6.1, alignedAt: 3.77))
        #expect(closed.reason == .ready)
        #expect(closed.t == 6.25)
    }

    /// Indoors: aligned, never a 10 m fix. Out at the timeout.
    @Test func indoorsItTimesOut() throws {
        let closed = try #require(replay(alignedAt: 3.77))
        #expect(closed.reason == .timeout)
        #expect(closed.t == CalibrationCardPolicy.timeoutSeconds)
    }

    /// In flight it is gone on the first tick that knows, before any seed.
    @Test func inFlightItIsGoneOnTheFirstTickThatKnows() throws {
        let closed = try #require(replay(flyingAt: 0.4))
        #expect(closed.reason == .inFlight)
        #expect(closed.t == 0.5)
    }

    /// Skip mid-wait.
    @Test func skipMidWait() throws {
        let closed = try #require(replay(gpsAt: 1.0, skipAt: 2.1))
        #expect(closed.reason == .skipped)
        #expect(closed.t == 2.25)
    }
}
