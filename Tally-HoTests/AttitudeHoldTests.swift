//
//  AttitudeHoldTests.swift
//  Tally-HoTests
//
//  Issue #12: the camera's whole attitude from CoreMotion in the air.
//
//  - The chain CoreMotion → `R_true`, on known poses, against ARKit's camera frame as Apple defines
//    it: portrait, landscape-right, pitched, rolled, and both readings of CoreMotion's matrix.
//  - ARKit's pitch and roll drifting under a steady phone (+20°, +27°, the size 63b15922 saw) leaves
//    every target's screen position where `R_true` puts it.
//  - The runtime check: confirms the right chain, falls back on a wrong one.
//  - The ground, and the air without the hold: the yaw-only placement, untouched.
//

import Testing
import Foundation
import simd
@testable import Tally_Ho

struct AttitudeHoldTests {

    // MARK: - Poses

    private func rotation(_ axis: SIMD3<Double>, _ deg: Double) -> simd_double3x3 {
        simd_double3x3(simd_quatd(angle: deg * .pi / 180, axis: simd_normalize(axis)))
    }

    /// Device → reference for a phone whose line of sight has CoreMotion azimuth `azimuth`
    /// (`cameraAzimuthDeg`'s convention), raised `pitch` above the horizon, turned `roll` about the
    /// line of sight from portrait upright (+90 is landscape-right: the top edge to the left).
    ///
    /// Portrait upright facing reference x: device x (screen right) is reference −y, device y (top) is
    /// reference z (up), device z (out of the screen) is reference −x.
    private func pose(azimuth: Double, pitch: Double = 0, roll: Double = 0) -> simd_double3x3 {
        let upright = simd_double3x3(columns: (SIMD3<Double>(0, -1, 0),
                                               SIMD3<Double>(0, 0, 1),
                                               SIMD3<Double>(-1, 0, 0)))
        let yaw: simd_double3x3 = rotation(SIMD3<Double>(0, 0, 1), -azimuth)
        let raise: simd_double3x3 = rotation(SIMD3<Double>(1, 0, 0), pitch)
        let turn: simd_double3x3 = rotation(SIMD3<Double>(0, 0, 1), roll)
        let placed: simd_double3x3 = yaw * upright
        return placed * raise * turn
    }

    /// A horizontal world direction at azimuth `deg` (clockwise from above from −z).
    private func horizontal(_ deg: Double) -> SIMD3<Double> {
        direction(bearing: deg, elevation: 0)
    }

    /// A world direction at azimuth `bearing`, `elevation` above the horizon.
    private func direction(bearing: Double, elevation: Double) -> SIMD3<Double> {
        let b: Double = bearing * Double.pi / 180
        let e: Double = elevation * Double.pi / 180
        return SIMD3<Double>(sin(b) * cos(e), sin(e), -cos(b) * cos(e))
    }

    private func gyroRotation(_ m: simd_double3x3) -> GyroYawHold.Rotation {
        GyroYawHold.Rotation(m11: m[0][0], m12: m[1][0], m13: m[2][0],
                             m21: m[0][1], m22: m[1][1], m23: m[2][1],
                             m31: m[0][2], m32: m[1][2], m33: m[2][2])
    }

    private func maxDifference(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
        var worst = 0.0
        for c in 0..<3 { for r in 0..<3 { worst = max(worst, abs(a[c][r] - b[c][r])) } }
        return worst
    }

    private func angleDeg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        atan2(simd_length(simd_cross(a, b)), simd_dot(a, b)) * 180 / .pi
    }

    // MARK: - The device → camera chain on known poses

    /// Portrait upright, facing CoreMotion azimuth 30. `R_true` (K and offset 0) is ARKit's camera frame
    /// exactly as Apple defines it — x along the long axis toward the home button (down), y the
    /// portrait right, z out of the screen — so the forward azimuth is CoreMotion's 30, the pitch 0,
    /// and the picture's roll −90, what `img_roll_deg` logs in portrait.
    @Test func portraitMatchesARKitsCameraFrame() {
        let truth = AttitudeHold.trueCameraToWorld(deviceToReference: pose(azimuth: 30),
                                                   anchorConstantDeg: 0, placementOffsetDeg: 0)
        let forward = horizontal(30)
        let arkit = simd_double3x3(columns: (SIMD3<Double>(0, -1, 0), horizontal(120), -forward))
        #expect(maxDifference(truth, arkit) < 1e-12)
        #expect(abs(AttitudeHold.pitchDeg(truth)) < 1e-9)
        #expect(abs((AttitudeHold.rollDeg(truth) ?? .nan) - (-90)) < 1e-9)
    }

    /// Landscape-right — the top edge to the left, home button right: ARKit's native orientation, so
    /// camera x is the screen's right, y up, and the roll 0.
    @Test func landscapeRightMatchesARKitsCameraFrame() {
        let truth = AttitudeHold.trueCameraToWorld(deviceToReference: pose(azimuth: 30, roll: 90),
                                                   anchorConstantDeg: 0, placementOffsetDeg: 0)
        let arkit = simd_double3x3(columns: (horizontal(120), SIMD3<Double>(0, 1, 0), -horizontal(30)))
        #expect(maxDifference(truth, arkit) < 1e-12)
        #expect(abs(AttitudeHold.rollDeg(truth) ?? .nan) < 1e-9)
    }

    /// Pitched up 20° in portrait: the line of sight rises 20°, the roll stays −90, the azimuth 30.
    @Test func pitchedPoseRaisesTheLineOfSight() throws {
        let truth = AttitudeHold.trueCameraToWorld(deviceToReference: pose(azimuth: 30, pitch: 20),
                                                   anchorConstantDeg: 0, placementOffsetDeg: 0)
        #expect(abs(AttitudeHold.pitchDeg(truth) - 20) < 1e-9)
        #expect(abs((AttitudeHold.rollDeg(truth) ?? .nan) - (-90)) < 1e-9)
        let azimuth = try #require(AttitudeHold.azimuthDeg(-truth.columns.2))
        #expect(abs(azimuth - 30) < 1e-9)
    }

    /// Rolled 30° from portrait toward landscape-right: the picture's roll goes −90 → −60, the line of
    /// sight does not move.
    @Test func rolledPoseRollsThePicture() throws {
        let truth = AttitudeHold.trueCameraToWorld(deviceToReference: pose(azimuth: 30, roll: 30),
                                                   anchorConstantDeg: 0, placementOffsetDeg: 0)
        #expect(abs((AttitudeHold.rollDeg(truth) ?? .nan) - (-60)) < 1e-9)
        #expect(abs(AttitudeHold.pitchDeg(truth)) < 1e-9)
        let azimuth = try #require(AttitudeHold.azimuthDeg(-truth.columns.2))
        #expect(abs(azimuth - 30) < 1e-9)
    }

    /// `R_true`'s forward azimuth is the yaw hold's own `cmYaw` plus K, less the placement offset — the
    /// same yaw `GyroYawHold.cameraAzimuthDeg` reads from the same matrix, on an awkward pose.
    @Test func trueYawIsTheYawHoldsCMYawPlusK() throws {
        let attitude = pose(azimuth: -120, pitch: 10, roll: -20)
        let gravity = attitude.transpose * SIMD3<Double>(0, 0, -1)
        let cmYaw = try #require(GyroYawHold.cameraAzimuthDeg(rotation: gyroRotation(attitude.transpose),
                                                              gravity: gravity))
        #expect(abs(AngularResponse.signedDelta(-120, cmYaw)) < 1e-9)
        let truth = AttitudeHold.trueCameraToWorld(deviceToReference: attitude,
                                                   anchorConstantDeg: 40, placementOffsetDeg: 25)
        let azimuth = try #require(AttitudeHold.azimuthDeg(-truth.columns.2))
        #expect(abs(AngularResponse.signedDelta(cmYaw + 40 - 25, azimuth)) < 1e-9)
        #expect(abs(AttitudeHold.pitchDeg(truth) - 10) < 1e-9)
    }

    /// Whichever way round CoreMotion's matrix maps, gravity picks the reading that puts reference
    /// up on the measured up, and both come back as the same device → reference matrix.
    @Test func eitherReadingOfCoreMotionsMatrixGivesTheSameAttitude() throws {
        let attitude = pose(azimuth: 75, pitch: 12, roll: 8)
        let gravity = attitude.transpose * SIMD3<Double>(0, 0, -1)     // device coordinates
        let fromRefToDev = try #require(AttitudeHold.deviceToReference(gyroRotation(attitude.transpose),
                                                                       gravity: gravity))
        let fromDevToRef = try #require(AttitudeHold.deviceToReference(gyroRotation(attitude),
                                                                       gravity: gravity))
        #expect(maxDifference(fromRefToDev, attitude) < 1e-12)
        #expect(maxDifference(fromDevToRef, attitude) < 1e-12)
        // Gravity that neither reading explains is refused.
        #expect(AttitudeHold.deviceToReference(gyroRotation(attitude), gravity: SIMD3<Double>(0, 0, 0)) == nil)
        #expect(AttitudeHold.deviceToReference(gyroRotation(attitude),
                                               gravity: -(attitude.transpose * SIMD3<Double>(0, 0, -1))) == nil)
    }

    // MARK: - ARKit's tilt drifting under a steady phone

    /// The 63b15922 shape: the phone steady, CoreMotion steady, ARKit's level drifting until its line of
    /// sight reads 20° higher and its picture 27° more rolled. Placed through `R_ar · R_true⁻¹`, every
    /// target — a grid of bearings and elevations around the camera, and the one straight ahead — is
    /// seen exactly where `R_true` puts it, before the drift and after; uncorrected, they move by up to
    /// tens of degrees.
    @Test func arkitPitchAndRollDriftLeavesEveryTargetWhereRTruePutsIt() throws {
        let k = 40.0, offset = 25.0
        let attitude = pose(azimuth: 10, pitch: 5)
        let truth = AttitudeHold.trueCameraToWorld(deviceToReference: attitude,
                                                   anchorConstantDeg: k, placementOffsetDeg: offset)
        let arBefore = truth
        let right = arBefore.columns.1                       // portrait: camera y is screen right
        let raised = rotation(right, 20) * arBefore
        let arAfter = rotation(-raised.columns.2, 27) * raised
        #expect(abs(AttitudeHold.pitchDeg(arAfter) - AttitudeHold.pitchDeg(arBefore) - 20) < 0.01)
        let rollChange = AngularResponse.signedDelta(try #require(AttitudeHold.rollDeg(arBefore)),
                                                     try #require(AttitudeHold.rollDeg(arAfter)))
        #expect(abs(abs(rollChange) - 27) < 0.5)
        #expect(abs(AttitudeHold.tiltDiscrepancyDeg(arAfter, truth) - 32.7) < 0.1)

        let cam = SIMD3<Double>(1.2, -0.3, 4.0)
        let place = AttitudeHold.yawRotation(subtractingDeg: offset)  // bearing B lands at B − offset
        var worstHeld = 0.0, worstUnheld = 0.0
        for bearing in stride(from: 0.0, to: 360.0, by: 45.0) {
            for elevation in [-10.0, 0.0, 15.0, 40.0] {
                let vTrue = direction(bearing: bearing, elevation: elevation)
                let p: SIMD3<Double> = cam + 80.0 * (place * vTrue)
                let expected = truth.transpose * (p - cam)
                for ar in [arBefore, arAfter] {
                    let c = AttitudeHold.correction(arCameraToWorld: ar, trueCameraToWorld: truth)
                    let seen = ar.transpose * (c * (p - cam))
                    worstHeld = max(worstHeld, angleDeg(seen, expected))
                    // The Float path the scene manager takes.
                    let held = AttitudeHold.placed(SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)),
                                                   about: SIMD3<Float>(Float(cam.x), Float(cam.y), Float(cam.z)),
                                                   rotation: AttitudeHold.float(c))
                    let heldD = SIMD3<Double>(Double(held.x), Double(held.y), Double(held.z))
                    #expect(angleDeg(ar.transpose * (heldD - cam), expected) < 1e-3)
                }
                worstUnheld = max(worstUnheld, angleDeg(arAfter.transpose * (p - cam), expected))
            }
        }
        #expect(worstHeld < 1e-9)
        #expect(worstUnheld > 20)

        // Straight ahead on the true heading (cmYaw 10 + K 40 = 50) at the true pitch (5): the centre of
        // the screen, whatever ARKit says and whatever the offset.
        let ahead = direction(bearing: 50, elevation: 5)
        let pAhead: SIMD3<Double> = cam + 80.0 * (place * ahead)
        let c = AttitudeHold.correction(arCameraToWorld: arAfter, trueCameraToWorld: truth)
        let seenAhead = arAfter.transpose * (c * (pAhead - cam))
        #expect(angleDeg(seenAhead, SIMD3<Double>(0, 0, -1)) < 1e-9)
    }

    /// The offset placement used cancels: two offsets, the same screen.
    @Test func thePlacementOffsetCancels() {
        let attitude = pose(azimuth: -40, pitch: 3, roll: 5)
        let ar = rotation(SIMD3<Double>(1, 0, 0.3), 14) * AttitudeHold.referenceToWorld * attitude
            * AttitudeHold.deviceToARCamera.transpose
        let vTrue = simd_normalize(SIMD3<Double>(0.4, 0.1, -0.9))
        var seen: [SIMD3<Double>] = []
        for offset in [-60.0, 12.5] {
            let truth = AttitudeHold.trueCameraToWorld(deviceToReference: attitude, anchorConstantDeg: 33,
                                                       placementOffsetDeg: offset)
            let placed = AttitudeHold.yawRotation(subtractingDeg: offset) * vTrue
            let c = AttitudeHold.correction(arCameraToWorld: ar, trueCameraToWorld: truth)
            seen.append(ar.transpose * (c * placed))
        }
        #expect(angleDeg(seen[0], seen[1]) < 1e-9)
    }

    // MARK: - The runtime check

    /// Feed a check `seconds` of 60 Hz frames, normal, steady and level, at a fixed discrepancy.
    private func run(_ check: inout AttitudeHold.Check, discrepancy: Double, seconds: Double,
                     sessionAge: Double = 1, normal: Bool = true, rate: Double = 2,
                     level: Bool = true) -> AttitudeHold.Check.State? {
        var decided: AttitudeHold.Check.State?
        for i in 0..<Int(seconds * 60) {
            let t = Double(i) / 60
            if let d = check.add(discrepancyDeg: discrepancy, isNormal: normal,
                                 secondsSinceStart: sessionAge + t, rateDps: rate, level: level, at: t) {
                decided = d
            }
        }
        return decided
    }

    @Test func theRightChainIsConfirmed() {
        var check = AttitudeHold.Check()
        let decided = run(&check, discrepancy: 1.2, seconds: 4)
        #expect(decided == .confirmed)
        #expect(check.state == .confirmed)
        #expect(abs(check.decidedMedianDeg - 1.2) < 1e-9)
        #expect(AttitudeHold.isActive(airHoldActive: true, check: check.state))
    }

    /// A chain that disagrees with ARKit about up by more than 5° while ARKit's level is fresh is
    /// wrong, and the hold falls back to yaw-only for good.
    @Test func aDisagreeingChainFallsBackToYawOnly() {
        var check = AttitudeHold.Check()
        let decided = run(&check, discrepancy: 25, seconds: 4)
        #expect(decided == .disabled)
        #expect(!AttitudeHold.isActive(airHoldActive: true, check: check.state))
        // Latched: a later world that agrees does not turn it back on.
        check.sessionStarted()
        let later = run(&check, discrepancy: 0.5, seconds: 4)
        #expect(later == nil)
        #expect(check.state == .disabled)
    }

    /// The check catches the mistake it exists for: the same physical pose, with the device → camera
    /// mapping left out, disagrees with ARKit about up by 90° and is disabled.
    @Test func aMissingDeviceToCameraMappingIsCaught() {
        let attitude = pose(azimuth: 30, pitch: 4)
        let arkit = AttitudeHold.trueCameraToWorld(deviceToReference: attitude, anchorConstantDeg: 0,
                                                   placementOffsetDeg: 0)
        let wrong = AttitudeHold.referenceToWorld * attitude          // device axes taken as camera axes
        let discrepancy = AttitudeHold.tiltDiscrepancyDeg(arkit, wrong)
        #expect(discrepancy > 45)
        var check = AttitudeHold.Check()
        let decided1 = run(&check, discrepancy: discrepancy, seconds: 4)
        #expect(decided1 == .disabled)
    }

    /// Only a fresh world's level counts, and only frames that are normal, steady and level: anything
    /// else leaves the check pending, and the hold yaw-only, until a world where they are.
    @Test func theCheckWaitsForAFreshSteadyLevelWorld() {
        var old = AttitudeHold.Check()
        let decided2 = run(&old, discrepancy: 1, seconds: 5, sessionAge: 31)
        #expect(decided2 == nil)
        var limited = AttitudeHold.Check()
        let decided3 = run(&limited, discrepancy: 1, seconds: 5, normal: false)
        #expect(decided3 == nil)
        var turning = AttitudeHold.Check()
        let decided4 = run(&turning, discrepancy: 1, seconds: 5, rate: 40)
        #expect(decided4 == nil)
        var banked = AttitudeHold.Check()
        let decided5 = run(&banked, discrepancy: 1, seconds: 5, level: false)
        #expect(decided5 == nil)
        for check in [old, limited, turning, banked] {
            #expect(check.state == .pending)
            #expect(!AttitudeHold.isActive(airHoldActive: true, check: check.state))
        }
        // A new world: the count starts again from it.
        old.sessionStarted()
        let decided6 = run(&old, discrepancy: 1, seconds: 4)
        #expect(decided6 == .confirmed)
    }

    /// In the air the GPS bank gates the check, unknown counting as level; on the ground the phone must
    /// be standing still, since a taxi turn tilts apparent gravity by tens of degrees.
    @Test func levelMeansWingsLevelInTheAirAndStoppedOnTheGround() {
        #expect(AttitudeHold.levelForCheck(airborne: true, groundSpeedKt: 450, gpsBankDeg: 2))
        #expect(!AttitudeHold.levelForCheck(airborne: true, groundSpeedKt: 450, gpsBankDeg: -12))
        #expect(AttitudeHold.levelForCheck(airborne: true, groundSpeedKt: 450, gpsBankDeg: .nan))
        #expect(AttitudeHold.levelForCheck(airborne: false, groundSpeedKt: 1, gpsBankDeg: .nan))
        #expect(!AttitudeHold.levelForCheck(airborne: false, groundSpeedKt: 20, gpsBankDeg: 0))
    }

    // MARK: - A confirmation remembered (QA round 1)

    private func scratchDefaults() -> UserDefaults {
        let name = "AttitudeHoldTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A confirmation covers exactly the build and device model it was made on.
    @Test func aConfirmationCoversOnlyItsBuildAndModel() {
        let here = AttitudeHold.MappingConfirmation(build: "394", deviceModel: "iPhone16,1")
        let stored = here.valueToStore(after: .confirmed)
        #expect(stored == "build=394 model=iPhone16,1")
        #expect(here.isConfirmed(stored: stored))
        #expect(!AttitudeHold.MappingConfirmation(build: "395", deviceModel: "iPhone16,1").isConfirmed(stored: stored))
        #expect(!AttitudeHold.MappingConfirmation(build: "394", deviceModel: "iPhone17,2").isConfirmed(stored: stored))
        #expect(!here.isConfirmed(stored: nil))
    }

    /// Only a confirmation is ever stored: a disable or a pending check writes nothing, so a disable
    /// can neither be remembered nor erase an earlier confirmation.
    @Test func onlyConfirmationsAreStored() {
        let here = AttitudeHold.MappingConfirmation(build: "394", deviceModel: "iPhone16,1")
        #expect(here.valueToStore(after: .disabled) == nil)
        #expect(here.valueToStore(after: .pending) == nil)

        let defaults = scratchDefaults()
        let disabledWrote = here.record(.disabled, in: defaults)
        #expect(!disabledWrote)
        #expect(!here.isConfirmed(in: defaults))
        let confirmedWrote = here.record(.confirmed, in: defaults)
        #expect(confirmedWrote)
        #expect(here.isConfirmed(in: defaults))
        let laterDisable = here.record(.disabled, in: defaults)
        #expect(!laterDisable)
        #expect(here.isConfirmed(in: defaults))
    }

    /// A new build checks again; once it confirms, the record is its own and the old build's is gone.
    @Test func aNewBuildChecksAgain() {
        let defaults = scratchDefaults()
        let old = AttitudeHold.MappingConfirmation(build: "393", deviceModel: "iPhone16,1")
        let new = AttitudeHold.MappingConfirmation(build: "394", deviceModel: "iPhone16,1")
        old.record(.confirmed, in: defaults)
        #expect(!new.isConfirmed(in: defaults))
        new.record(.confirmed, in: defaults)
        #expect(new.isConfirmed(in: defaults))
        #expect(!old.isConfirmed(in: defaults))
    }

    /// Without a build number or a model, nothing is trusted and nothing is stored.
    @Test func anUnknownBuildOrModelIsNeverTrusted() {
        let noBuild = AttitudeHold.MappingConfirmation(build: "", deviceModel: "iPhone16,1")
        let noModel = AttitudeHold.MappingConfirmation(build: "394", deviceModel: " ")
        for identity in [noBuild, noModel] {
            #expect(!identity.isUsable)
            #expect(identity.valueToStore(after: .confirmed) == nil)
            #expect(!identity.isConfirmed(stored: identity.identity))
        }
    }

    /// Confirmed from the record, the check is skipped: the hold is on at once, and no disagreement this
    /// run's frames show — the flight, not the code — can disable it.
    @Test func aRememberedConfirmationSkipsTheCheck() {
        var check = AttitudeHold.Check()
        check.confirmFromRecord()
        #expect(check.state == .confirmed)
        #expect(check.confirmedFromRecord)
        #expect(check.logDescription == "confirmed_before")
        #expect(AttitudeHold.isActive(airHoldActive: true, check: check.state))
        let decided = run(&check, discrepancy: 25, seconds: 4)
        #expect(decided == nil)
        #expect(check.state == .confirmed)
        // A disabled check stays disabled: a record never overrides this run's own verdict.
        var disabled = AttitudeHold.Check()
        let verdict = run(&disabled, discrepancy: 25, seconds: 4)
        #expect(verdict == .disabled)
        disabled.confirmFromRecord()
        #expect(disabled.state == .disabled)
    }

    // MARK: - The ground, and the air without the hold

    /// On the ground — or in the air with the yaw hold off — placement is the yaw-only one, bit for
    /// bit: no correction is made, and a position with no correction is returned unchanged.
    @Test func theGroundIsUntouched() {
        #expect(!AttitudeHold.isActive(airHoldActive: false, check: .confirmed))
        #expect(!AttitudeHold.isActive(airHoldActive: false, check: .pending))
        #expect(!AttitudeHold.isActive(airHoldActive: true, check: .pending))
        let p = SIMD3<Float>(12.5, -3.25, -79.0)
        let cam = SIMD3<Float>(0.4, 1.1, -0.2)
        let unchanged = AttitudeHold.placed(p, about: cam, rotation: nil)
        #expect(unchanged == p)
    }

    // MARK: - CoreMotion at the frame's timestamp

    @Test func attitudeIsSlerpedBetweenSamples() throws {
        let a = simd_quatd(pose(azimuth: 0))
        let b = simd_quatd(pose(azimuth: 10))
        let mid = try #require(AttitudeHold.interpolatedAttitude([(t: 0, q: a), (t: 0.05, q: b)], at: 0.025))
        let truth = AttitudeHold.trueCameraToWorld(deviceToReference: simd_double3x3(mid),
                                                   anchorConstantDeg: 0, placementOffsetDeg: 0)
        let azimuth = try #require(AttitudeHold.azimuthDeg(-truth.columns.2))
        #expect(abs(azimuth - 5) < 1e-9)
    }

    /// Up to 0.1 s past the newest sample it carries on at the last pair's rate; beyond, nothing.
    @Test func attitudeExtrapolatesOnlyALittle() throws {
        let a = simd_quatd(pose(azimuth: 0, pitch: 2))
        let b = simd_quatd(pose(azimuth: 4, pitch: 2))
        let samples: [(t: TimeInterval, q: simd_quatd)] = [(t: 0, q: a), (t: 0.05, q: b)]
        let ahead = try #require(AttitudeHold.interpolatedAttitude(samples, at: 0.08))
        let truth = AttitudeHold.trueCameraToWorld(deviceToReference: simd_double3x3(ahead),
                                                   anchorConstantDeg: 0, placementOffsetDeg: 0)
        let azimuth = try #require(AttitudeHold.azimuthDeg(-truth.columns.2))
        #expect(abs(azimuth - 6.4) < 1e-6)
        #expect(AttitudeHold.interpolatedAttitude(samples, at: 0.2) == nil)
        #expect(AttitudeHold.interpolatedAttitude(samples, at: -0.5) == nil)
        #expect(AttitudeHold.interpolatedAttitude([], at: 0) == nil)
    }

    // MARK: - GPS bank (shadow)

    /// A standard-rate turn (3°/s) at 250 kt needs about 34.5° of bank; level flight none.
    @Test func gpsBankIsTheCoordinatedTurnsBank() {
        #expect(abs(AttitudeHold.gpsBankDeg(groundSpeedKt: 250, turnRateDps: 3) - 34.48) < 0.05)
        #expect(abs(AttitudeHold.gpsBankDeg(groundSpeedKt: 450, turnRateDps: -1) - (-22.39)) < 0.05)
        #expect(AttitudeHold.gpsBankDeg(groundSpeedKt: 450, turnRateDps: 0) == 0)
        #expect(AttitudeHold.gpsBankDeg(groundSpeedKt: 450, turnRateDps: .nan).isNaN)
    }

    /// The course's rate over the last three seconds of fixes, the short way across north; an unusable
    /// course clears it rather than bridging.
    @Test func turnRateFromGPSCourse() {
        var rate = AttitudeHold.TurnRate()
        rate.add(courseDeg: 357, courseAccuracyDeg: 0.5, at: 100)
        #expect(rate.rateDps.isNaN)
        rate.add(courseDeg: 0, courseAccuracyDeg: 0.5, at: 101)
        rate.add(courseDeg: 3, courseAccuracyDeg: 0.5, at: 102)
        #expect(abs(rate.rateDps - 3) < 1e-9)
        rate.add(courseDeg: 4, courseAccuracyDeg: 40, at: 103)
        #expect(rate.rateDps.isNaN)
    }
}
