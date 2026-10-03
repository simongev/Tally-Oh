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
//  #12: an alignment the ground compass measured is not trusted in the air (336276c7: 46.6° out 5.5
//  minutes after takeoff), so a takeoff over one arms the airborne seed in place — with a ground K,
//  and not with a seed or anchor K.
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

    /// A ground correction in force that the ground compass did not measure for this alignment — primed
    /// by a track seed or a carry — is never traded for a restart, not even on a fallback world. (One the
    /// compass did measure gets the in-place seed instead: see the #12 tests below.)
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

    // MARK: - A ground-compass alignment in the air (#12)

    /// The 336276c7 world at takeoff: the ground correction in force, measured by the cabin compass,
    /// and its K what the air hold would carry.
    private let compassAligned = AirborneSeedRearm.World(fellBackToHeading: false,
                                                         hasYawSource: true,
                                                         anchorInForce: false,
                                                         groundCorrectionInForce: true,
                                                         seedPending: false,
                                                         alignedByGroundCompass: true)

    /// A ground K: the airborne seed is armed in place at takeoff — no restart, so the compass
    /// alignment stays until the seed lands — and only once.
    @Test func aGroundCompassAlignmentArmsTheSeedInPlaceAtTakeoff() {
        #expect(AirborneSeedRearm.reason(for: compassAligned) == .groundCompass)
        var rearm = AirborneSeedRearm()
        rearm.tookOff(compassAligned)
        let first = rearm.next(compassAligned, sessionPaused: false, restartAllowed: false)
        #expect(first == .armSeedInPlace(.groundCompass))
        #expect(rearm.pending == nil)
        let again = rearm.next(compassAligned, sessionPaused: false, restartAllowed: true)
        #expect(again == .none)
    }

    /// A compass seed is the ground compass too, primed correction or not.
    @Test func aCompassSeedIsTreatedAsTheGroundCompass() {
        var seeded = unaligned
        seeded.hasYawSource = true
        seeded.alignedByGroundCompass = true
        var rearm = AirborneSeedRearm()
        rearm.tookOff(seeded)
        let action = rearm.next(seeded, sessionPaused: false, restartAllowed: true)
        #expect(action == .armSeedInPlace(.groundCompass))
    }

    /// A seed K (the track) or an anchor K: nothing, whatever correction is primed beside it.
    @Test func aSeedOrAnchorKIsNotRearmed() {
        var trackSeeded = compassAligned
        trackSeeded.alignedByGroundCompass = false           // the track seed primed the correction
        #expect(AirborneSeedRearm.reason(for: trackSeeded) == nil)
        var anchored = compassAligned
        anchored.anchorInForce = true                        // an anchor always wins
        #expect(AirborneSeedRearm.reason(for: anchored) == nil)
        for world in [trackSeeded, anchored] {
            var rearm = AirborneSeedRearm()
            rearm.tookOff(world)
            let action = rearm.next(world, sessionPaused: false, restartAllowed: true)
            #expect(action == .none)
            #expect(rearm.pending == nil)
        }
    }

    /// A seed already on its way is not doubled.
    @Test func aCompassWorldWithASeedOnItsWayIsLeftAlone() {
        var pending = compassAligned
        pending.seedPending = true
        var rearm = AirborneSeedRearm()
        rearm.tookOff(pending)
        let action = rearm.next(pending, sessionPaused: false, restartAllowed: true)
        #expect(action == .none)
    }

    /// The AR view is not running: wait — the start that comes when it returns carries the compass
    /// alignment on — and arm the seed once it is.
    @Test func aPausedSessionWaitsAndArmsInPlaceWhenBack() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(compassAligned)
        let paused = rearm.next(compassAligned, sessionPaused: true, restartAllowed: true)
        #expect(paused == .none)
        #expect(rearm.pending == .groundCompass)
        let back = rearm.next(compassAligned, sessionPaused: false, restartAllowed: false)
        #expect(back == .armSeedInPlace(.groundCompass))
    }

    /// An anchor taken while the re-arm waits wins, and landing cancels it.
    @Test func anAnchorOrALandingCancelsAWaitingCompassRearm() {
        var rearm = AirborneSeedRearm()
        rearm.tookOff(compassAligned)
        _ = rearm.next(compassAligned, sessionPaused: true, restartAllowed: true)
        var anchored = compassAligned
        anchored.anchorInForce = true
        let afterAnchor = rearm.next(anchored, sessionPaused: false, restartAllowed: true)
        #expect(afterAnchor == .none)
        #expect(rearm.pending == nil)

        var landing = AirborneSeedRearm()
        landing.tookOff(compassAligned)
        _ = landing.next(compassAligned, sessionPaused: true, restartAllowed: true)
        landing.landed()
        let afterLanding = landing.next(compassAligned, sessionPaused: false, restartAllowed: true)
        #expect(afterLanding == .none)
    }
}
