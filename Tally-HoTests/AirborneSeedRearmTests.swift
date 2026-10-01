//
//  AirborneSeedRearmTests.swift
//  Tally-HoTests
//
//  Whether a takeoff goes back for an airborne seed. Log af4f1d6b (2026-10-01): opened on the
//  ground with the compass unusable, `seed_unavailable` at 10 s, the world fell back to
//  `.gravityAndHeading`, takeoff at 194 s — and it never seeded from the track. These pin that the
//  takeoff now re-arms such a world, that it never throws away an anchor or a ground correction,
//  and that a restart the rate limit refuses is waited for rather than lost.
//

import Testing
@testable import Tally_Ho

struct AirborneSeedRearmTests {

    /// The af4f1d6b world at takeoff: fell back, nothing else in force.
    private let fellBack = AirborneSeedRearm.World(fellBackToHeading: true,
                                                   hasYawSource: false,
                                                   anchorInForce: false,
                                                   groundCorrectionInForce: false,
                                                   seedPending: false)

    /// A `.gravity` world with no yaw source and no seed on the way.
    private let unaligned = AirborneSeedRearm.World(fellBackToHeading: false,
                                                    hasYawSource: false,
                                                    anchorInForce: false,
                                                    groundCorrectionInForce: false,
                                                    seedPending: false)

    // MARK: - When it re-arms

    @Test func aFallbackWorldIsRearmedAtTakeoff() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(fellBack)
        let action1 = rearm.next(fellBack, sessionPaused: false, restartAllowed: true)
        #expect(action1 == .restartWorld(.fallback))
    }

    @Test func aGravityWorldWithNoAlignmentIsRearmedAtTakeoff() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(unaligned)
        let action2 = rearm.next(unaligned, sessionPaused: false, restartAllowed: true)
        #expect(action2 == .restartWorld(.noAlignment))
    }

    // MARK: - When it must not

    /// A ground correction is a measurement; a seed is a guess. Never trade one for the other — not
    /// even on a fallback world, where the correction is all that is holding it.
    @Test func aGroundCorrectionInForceIsNeverRearmed() {
        var onFallback = fellBack
        onFallback.groundCorrectionInForce = true
        onFallback.hasYawSource = true
        var unalignedButPrimed = unaligned
        unalignedButPrimed.groundCorrectionInForce = true

        for world in [onFallback, unalignedButPrimed] {
            #expect(AirborneSeedRearm.reason(for: world) == nil)
            var rearm = AirborneSeedRearm()
            rearm.tookOff(world)
            let action3 = rearm.next(world, sessionPaused: false, restartAllowed: true)
            #expect(action3 == .none)
            #expect(rearm.pending == nil)
        }
    }

    @Test func anAnchorInForceIsNeverRearmed() {
        var world = fellBack
        world.anchorInForce = true
        world.hasYawSource = true
        var rearm = AirborneSeedRearm()
        rearm.tookOff(world)
        let action4 = rearm.next(world, sessionPaused: false, restartAllowed: true)
        #expect(action4 == .none)
    }

    /// A seed that succeeded is a trusted alignment, and the world keeps it.
    @Test func aWorldWithATrustedSeedIsLeftAlone() {
        var world = unaligned
        world.hasYawSource = true
        #expect(AirborneSeedRearm.reason(for: world) == nil)
        var rearm = AirborneSeedRearm()
        rearm.tookOff(world)
        let action5 = rearm.next(world, sessionPaused: false, restartAllowed: true)
        #expect(action5 == .none)
    }

    /// Opening the app in the air: the world is brand new and its seed is already armed, so the
    /// first tick's airborne transition must not restart it.
    @Test func aSeedAlreadyOnTheWayIsNotRestarted() {
        var world = unaligned
        world.seedPending = true
        var rearm = AirborneSeedRearm()
        rearm.tookOff(world)
        let action6 = rearm.next(world, sessionPaused: false, restartAllowed: true)
        #expect(action6 == .none)
    }

    @Test func nothingHappensWithoutATakeoff() {
        var rearm = AirborneSeedRearm()
        let action7 = rearm.next(fellBack, sessionPaused: false, restartAllowed: true)
        #expect(action7 == .none)
    }

    // MARK: - Timing

    /// Opening the app in the climb: `viewWillAppear` has just started a world, so the restart is
    /// refused for three seconds. The re-arm waits for it instead of being suppressed and lost.
    @Test func aThrottledRestartWaitsAndThenFires() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(fellBack)
        let action8 = rearm.next(fellBack, sessionPaused: false, restartAllowed: false)
        #expect(action8 == .none)
        #expect(rearm.pending == .fallback)
        let action9 = rearm.next(fellBack, sessionPaused: false, restartAllowed: false)
        #expect(action9 == .none)
        let action10 = rearm.next(fellBack, sessionPaused: false, restartAllowed: true)
        #expect(action10 == .restartWorld(.fallback))
        #expect(rearm.pending == nil)
    }

    /// Whatever aligns the world while the re-arm waits wins, and the re-arm is dropped for good.
    @Test func anAlignmentArrivingWhileWaitingCancelsTheRearm() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(fellBack)
        let action11 = rearm.next(fellBack, sessionPaused: false, restartAllowed: false)
        #expect(action11 == .none)

        var anchored = fellBack
        anchored.anchorInForce = true
        anchored.hasYawSource = true
        let action12 = rearm.next(anchored, sessionPaused: false, restartAllowed: true)
        #expect(action12 == .none)
        #expect(rearm.pending == nil)
        // Even if the anchor is later withdrawn, the takeoff's re-arm has been spent.
        let action13 = rearm.next(fellBack, sessionPaused: false, restartAllowed: true)
        #expect(action13 == .none)
    }

    /// The AR view is not running — the user is on another screen. Do not start a camera; clear the
    /// fallback so the start that comes when the view returns is the seeded one.
    @Test func aPausedSessionArmsTheNextStartInsteadOfRestarting() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(fellBack)
        let action14 = rearm.next(fellBack, sessionPaused: true, restartAllowed: true)
        #expect(action14 == .armNextStart(.fallback))
        #expect(rearm.pending == nil)
    }

    @Test func landingCancelsAPendingRearm() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(fellBack)
        let action15 = rearm.next(fellBack, sessionPaused: false, restartAllowed: false)
        #expect(action15 == .none)
        rearm.landed()
        #expect(rearm.pending == nil)
        let action16 = rearm.next(fellBack, sessionPaused: false, restartAllowed: true)
        #expect(action16 == .none)
    }

    /// Once per takeoff. If the re-seeded world's own seed later times out and falls back again,
    /// that is not a second re-arm — it would loop on a reference that is not arriving.
    @Test func itRearmsOncePerTakeoff() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(fellBack)
        let action17 = rearm.next(fellBack, sessionPaused: false, restartAllowed: true)
        #expect(action17 == .restartWorld(.fallback))
        for _ in 0..<5 {
            let action18 = rearm.next(fellBack, sessionPaused: false, restartAllowed: true)
            #expect(action18 == .none)
        }
        // A new takeoff is a new chance.
        rearm.landed()
        rearm.tookOff(fellBack)
        let action19 = rearm.next(fellBack, sessionPaused: false, restartAllowed: true)
        #expect(action19 == .restartWorld(.fallback))
    }
}
