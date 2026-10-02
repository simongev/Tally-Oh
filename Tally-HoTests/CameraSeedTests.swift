//
//  CameraSeedTests.swift
//  Tally-HoTests
//
//  The camera seed's pure half on synthetic scenes: the FOE solver, derotation, the azimuth and
//  offset conventions, the tracker on synthetic images, and the gating around them. Nothing here
//  touches ARKit, the camera or device motion — those can only be checked on the phone.
//

import Testing
import Foundation
import simd
@testable import Tally_Ho

struct CameraSeedTests {

    // MARK: - Helpers

    /// Focal length of the working image: 480 px across a ~66° field of view.
    private static let focalPx = 370.0

    private static func solverConfig() -> CameraSeed.FOESolver.Config {
        CameraSeed.FOESolver.Config(focalPx: focalPx)
    }

    private static func angleDeg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let c = simd_dot(simd_normalize(a), simd_normalize(b))
        return acos(max(-1, min(1, c))) * 180 / .pi
    }

    private static func rotation(axis: SIMD3<Double>, degrees: Double) -> simd_double3x3 {
        simd_double3x3(simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis)))
    }

    private static func isNil<T>(_ value: T?) -> Bool {
        value == nil
    }

    private static func gaussian(_ rng: inout CameraSeed.SeededGenerator) -> Double {
        let u1 = Double.random(in: 1e-12..<1, using: &rng)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    private typealias Pair = (n1: SIMD2<Double>, n2: SIMD2<Double>)

    /// Scene points at 10–60 m in front of camera 1. Camera 2 has moved `step` along `direction`
    /// and turned by `rotation` (camera-1 → camera-2 coordinates of a fixed direction, CV frame).
    /// Returns each point's normalised position in both frames as observed — rotation included.
    private static func scene(direction: SIMD3<Double>, step: Double = 1.0,
                              rotation: simd_double3x3 = matrix_identity_double3x3,
                              count: Int = 300, seed: UInt64 = 1, noisePx: Double = 0) -> [Pair] {
        var rng = CameraSeed.SeededGenerator(seed: seed)
        let c = simd_normalize(direction) * step
        var out: [Pair] = []
        var attempts = 0
        while out.count < count && attempts < count * 50 {
            attempts += 1
            let n1 = SIMD2<Double>(Double.random(in: -0.6...0.6, using: &rng),
                                   Double.random(in: -0.45...0.45, using: &rng))
            let depth = Double.random(in: 10...60, using: &rng)
            let point = SIMD3<Double>(n1.x * depth, n1.y * depth, depth)
            let moved = point - c
            let seen = rotation * moved
            guard moved.z > 0.5, seen.z > 0.5 else { continue }
            var n2 = SIMD2<Double>(seen.x / seen.z, seen.y / seen.z)
            guard abs(n2.x) < 0.8, abs(n2.y) < 0.6 else { continue }
            if noisePx > 0 {
                n2 += SIMD2<Double>(gaussian(&rng), gaussian(&rng)) * (noisePx / focalPx)
            }
            out.append((n1: n1, n2: n2))
        }
        return out
    }

    private static func samples(_ pairs: [Pair],
                                derotating rotation: simd_double3x3 = matrix_identity_double3x3)
        -> [CameraSeed.FlowSample] {
        var out: [CameraSeed.FlowSample] = []
        for pair in pairs {
            guard let back = CameraSeed.Derotation.unrotate(pair.n2, rotation: rotation) else { continue }
            out.append(CameraSeed.FlowSample(p: pair.n1, u: back - pair.n1))
        }
        return out
    }

    /// Camera-to-world rotation for a boresight at ARKit azimuth `azimuthDeg`, pitched up
    /// `pitchDeg` and rolled `rollDeg` about its own axis.
    private static func cameraToWorld(azimuthDeg: Double, pitchDeg: Double = 0,
                                      rollDeg: Double = 0) -> simd_double3x3 {
        let yaw = rotation(axis: SIMD3<Double>(0, 1, 0), degrees: -azimuthDeg)
        let pitch = rotation(axis: SIMD3<Double>(1, 0, 0), degrees: pitchDeg)
        let roll = rotation(axis: SIMD3<Double>(0, 0, 1), degrees: rollDeg)
        return yaw * pitch * roll
    }

    /// A horizontal world direction at ARKit azimuth `degrees`.
    private static func worldDirection(azimuthDeg degrees: Double) -> SIMD3<Double> {
        let r = degrees * .pi / 180
        return SIMD3<Double>(sin(r), 0, -cos(r))
    }

    /// A world direction in a camera's CV frame.
    private static func inCV(_ world: SIMD3<Double>, cameraToWorld: simd_double3x3) -> SIMD3<Double> {
        let ar = cameraToWorld.transpose * world
        return SIMD3<Double>(ar.x, -ar.y, -ar.z)
    }

    // MARK: - FOE solver on synthetic flow

    @Test func foeStraightAheadIsRecoveredWithinOneDegree() throws {
        let truth = simd_normalize(SIMD3<Double>(0.08, -0.03, 1))
        let report = CameraSeed.FOESolver.solve(Self.samples(Self.scene(direction: truth)),
                                                config: Self.solverConfig())
        let direction = try #require(report.direction)
        #expect(report.failure == nil)
        #expect(Self.angleDeg(direction, truth) < 1.0)
    }

    @Test func foeAtInfinityWhenPointingSidewaysKeepsItsSign() throws {
        // Travel exactly across the view: every flow vector parallel, the FOE at infinity.
        let truth = SIMD3<Double>(1, 0, 0)
        let report = CameraSeed.FOESolver.solve(Self.samples(Self.scene(direction: truth)),
                                                config: Self.solverConfig())
        let direction = try #require(report.direction)
        #expect(Self.angleDeg(direction, truth) < 1.0)
        // Not the opposite way: scenery streams backward past a side window.
        #expect(direction.x > 0.99)
    }

    @Test func foeOffScreenIsRecovered() throws {
        // 70° off the boresight: far outside the ±33° field of view, but not at infinity.
        let truth = simd_normalize(SIMD3<Double>(sin(70 * .pi / 180), 0.03, cos(70 * .pi / 180)))
        let report = CameraSeed.FOESolver.solve(Self.samples(Self.scene(direction: truth)),
                                                config: Self.solverConfig())
        let direction = try #require(report.direction)
        #expect(Self.angleDeg(direction, truth) < 1.0)
    }

    @Test func focusOfContractionMeansTravelIsBehindTheCamera() throws {
        // Phone pointing back down the cabin: the scene contracts, and travel is behind the lens.
        let truth = simd_normalize(SIMD3<Double>(0.1, 0.02, -1))
        let report = CameraSeed.FOESolver.solve(Self.samples(Self.scene(direction: truth)),
                                                config: Self.solverConfig())
        let direction = try #require(report.direction)
        #expect(Self.angleDeg(direction, truth) < 1.0)
        #expect(direction.z < 0)
    }

    @Test func phoneRotationIsRemovedBeforeSolving() throws {
        let truth = simd_normalize(SIMD3<Double>(-0.05, 0.02, 1))
        let turn = Self.rotation(axis: SIMD3<Double>(0.3, 1, 0.2), degrees: 4)
        let pairs = Self.scene(direction: truth, rotation: turn)

        let derotated = CameraSeed.FOESolver.solve(Self.samples(pairs, derotating: turn),
                                                   config: Self.solverConfig())
        let direction = try #require(derotated.direction)
        #expect(Self.angleDeg(direction, truth) < 1.0)

        // And the rotation genuinely mattered: left in, the answer is refused or badly wrong.
        let raw = CameraSeed.FOESolver.solve(Self.samples(pairs), config: Self.solverConfig())
        if let wrong = raw.direction {
            #expect(Self.angleDeg(wrong, truth) > 3.0)
        }
    }

    @Test func thirtyPercentOutliersAreRejected() throws {
        let truth = simd_normalize(SIMD3<Double>(0.2, 0.05, 1))
        var samples = Self.samples(Self.scene(direction: truth))
        var rng = CameraSeed.SeededGenerator(seed: 99)
        let outlierCount = samples.count * 3 / 10
        for i in 0..<outlierCount {
            let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
            let magnitude = Double.random(in: 0.005...0.05, using: &rng)
            samples[i].u = SIMD2<Double>(cos(angle), sin(angle)) * magnitude
        }
        let report = CameraSeed.FOESolver.solve(samples, config: Self.solverConfig())
        let direction = try #require(report.direction)
        #expect(Self.angleDeg(direction, truth) < 1.0)
        #expect(report.inlierCount < samples.count - outlierCount / 2)
    }

    @Test func staticCabinPixelsAreSetAside() throws {
        let truth = simd_normalize(SIMD3<Double>(-0.15, 0.0, 1))
        var samples = Self.samples(Self.scene(direction: truth, count: 250))
        var rng = CameraSeed.SeededGenerator(seed: 7)
        let cabin = 200
        for _ in 0..<cabin {
            let p = SIMD2<Double>(Double.random(in: -0.6...0.6, using: &rng),
                                  Double.random(in: -0.45...0.45, using: &rng))
            // Tracking jitter only: a tenth of a pixel, far below the static threshold.
            let u = SIMD2<Double>(Self.gaussian(&rng), Self.gaussian(&rng)) * (0.1 / Self.focalPx)
            samples.append(CameraSeed.FlowSample(p: p, u: u))
        }
        let report = CameraSeed.FOESolver.solve(samples, config: Self.solverConfig())
        let direction = try #require(report.direction)
        #expect(Self.angleDeg(direction, truth) < 1.0)
        #expect(report.staticCount >= cabin)
        #expect(report.inlierCount <= report.movingCount)
    }

    @Test func noisyFlowStaysWithinOneDegree() throws {
        for (seed, truth) in [(UInt64(3), simd_normalize(SIMD3<Double>(0.1, -0.05, 1))),
                              (UInt64(4), SIMD3<Double>(-1, 0, 0))] {
            let pairs = Self.scene(direction: truth, seed: seed, noisePx: 0.3)
            let report = CameraSeed.FOESolver.solve(Self.samples(pairs), config: Self.solverConfig())
            let direction = try #require(report.direction)
            #expect(Self.angleDeg(direction, truth) < 1.0)
        }
    }

    @Test func aCabinWithNothingMovingIsRefused() {
        var rng = CameraSeed.SeededGenerator(seed: 11)
        var samples: [CameraSeed.FlowSample] = []
        for _ in 0..<200 {
            let p = SIMD2<Double>(Double.random(in: -0.6...0.6, using: &rng),
                                  Double.random(in: -0.45...0.45, using: &rng))
            let u = SIMD2<Double>(Self.gaussian(&rng), Self.gaussian(&rng)) * (0.1 / Self.focalPx)
            samples.append(CameraSeed.FlowSample(p: p, u: u))
        }
        let report = CameraSeed.FOESolver.solve(samples, config: Self.solverConfig())
        #expect(report.direction == nil)
        #expect(report.failure == .staticScene)
    }

    @Test func flowThatAgreesOnNothingIsRefused() {
        var rng = CameraSeed.SeededGenerator(seed: 12)
        var samples: [CameraSeed.FlowSample] = []
        for _ in 0..<300 {
            let p = SIMD2<Double>(Double.random(in: -0.6...0.6, using: &rng),
                                  Double.random(in: -0.45...0.45, using: &rng))
            let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
            let magnitude = Double.random(in: 0.005...0.05, using: &rng)
            samples.append(CameraSeed.FlowSample(p: p, u: SIMD2<Double>(cos(angle), sin(angle)) * magnitude))
        }
        let report = CameraSeed.FOESolver.solve(samples, config: Self.solverConfig())
        #expect(report.direction == nil)
        #expect(report.failure != nil)
    }

    @Test func smallestEigenvectorOfASymmetricMatrix() {
        let basis = Self.rotation(axis: SIMD3<Double>(1, 2, 3), degrees: 37)
        let m = basis * simd_double3x3(diagonal: SIMD3<Double>(5, 0.01, 2)) * basis.transpose
        let v = CameraSeed.FOESolver.Eigen.smallestEigenvector(ofSymmetric: m)
        #expect(abs(abs(simd_dot(simd_normalize(v), basis.columns.1)) - 1) < 1e-9)
    }

    // MARK: - World azimuth and offset

    /// The car test on paper. The vehicle travels along ARKit azimuth 30° and GPS says 42°, so the
    /// true offset is +12°. The phone looks forward, out of either side, and in between, pitched
    /// and rolled: every view must give the same offset, and foe_rel_cam_deg must say where it looked.
    @Test(arguments: [0.0, 35.0, 60.0, 90.0, -90.0, -120.0])
    func worldOffsetIsTheSameWhereverThePhonePoints(relativeDeg: Double) throws {
        let travelAzimuth = 30.0
        let track = 42.0
        let camera = Self.cameraToWorld(azimuthDeg: travelAzimuth - relativeDeg, pitchDeg: -5, rollDeg: 8)
        let travel = Self.inCV(Self.worldDirection(azimuthDeg: travelAzimuth), cameraToWorld: camera)
        let estimate = CameraSeed.WorldEstimate.make(samples: Self.samples(Self.scene(direction: travel)),
                                                     cameraToWorld: camera, trackDeg: track,
                                                     config: Self.solverConfig())
        #expect(estimate.failure == nil)
        #expect(abs(AngularResponse.signedDelta(estimate.offsetDeg, 12)) < 1.0)
        #expect(abs(AngularResponse.signedDelta(estimate.foeAzimuthDeg, travelAzimuth)) < 1.0)
        #expect(abs(AngularResponse.signedDelta(estimate.foeRelCamDeg, relativeDeg)) < 1.0)
        #expect(abs(estimate.foeElevationDeg) < 1.0)
    }

    @Test func travelToTheCameraRightIsPlusNinety() throws {
        // Phone looking north out of a left-hand window while the vehicle heads east.
        let camera = Self.cameraToWorld(azimuthDeg: 0)
        let travel = Self.inCV(Self.worldDirection(azimuthDeg: 90), cameraToWorld: camera)
        #expect(travel.x > 0.99)   // camera right is +x in the image
        let estimate = CameraSeed.WorldEstimate.make(samples: Self.samples(Self.scene(direction: travel)),
                                                     cameraToWorld: camera, trackDeg: 90,
                                                     config: Self.solverConfig())
        #expect(abs(estimate.foeRelCamDeg - 90) < 1.0)
        #expect(abs(estimate.offsetDeg) < 1.0)
    }

    @Test func offsetUsesTheStartupSeedConvention() throws {
        var seed = StartupSeed(minSeconds: 0, minSamples: 1)
        seed.begin(reference: .track)
        seed.add(arAzimuthDeg: 350, referenceDeg: 10, at: 0)
        let finished = seed.finish(at: 0)
        let published = try #require(finished)

        // The same geometry through the camera seed: FOE at ARKit azimuth 350°, track 10°.
        let camera = Self.cameraToWorld(azimuthDeg: 350)
        let travel = Self.inCV(Self.worldDirection(azimuthDeg: 350), cameraToWorld: camera)
        let estimate = CameraSeed.WorldEstimate.make(samples: Self.samples(Self.scene(direction: travel)),
                                                     cameraToWorld: camera, trackDeg: 10,
                                                     config: Self.solverConfig())
        #expect(abs(published.offsetDeg - 20) < 1e-9)
        #expect(abs(estimate.offsetDeg - published.offsetDeg) < 0.5)
    }

    @Test func azimuthMatchesTheRenderLoopFormula() {
        for azimuth in stride(from: -170.0, through: 180.0, by: 17.0) {
            let camera = Self.cameraToWorld(azimuthDeg: azimuth, pitchDeg: 10, rollDeg: -20)
            // updateWorldYawError: forward = −column 2 of the camera transform,
            // rawAzimuthDeg = atan2(forward.x, −forward.z).
            let forward = -camera.columns.2
            let raw = atan2(forward.x, -forward.z) * 180 / .pi
            let bore = CameraSeed.WorldEstimate.azimuthDeg(ofWorldDirection: camera * SIMD3<Double>(0, 0, -1))
            #expect(bore != nil)
            #expect(abs(AngularResponse.signedDelta(raw, bore ?? .nan)) < 1e-9)
            #expect(abs(AngularResponse.signedDelta(azimuth, raw)) < 1e-9)
        }
    }

    @Test func steepDirectionIsRefused() {
        // Straight down through the floor is not a direction of travel.
        let camera = Self.cameraToWorld(azimuthDeg: 0, pitchDeg: -80)
        let travel = Self.inCV(simd_normalize(SIMD3<Double>(0, -1, -0.2)), cameraToWorld: camera)
        let estimate = CameraSeed.WorldEstimate.make(samples: Self.samples(Self.scene(direction: travel)),
                                                     cameraToWorld: camera, trackDeg: 0,
                                                     config: Self.solverConfig())
        #expect(estimate.failure == .steepDirection)
        #expect(estimate.offsetDeg.isNaN)
    }

    // MARK: - Frames and attitude

    @Test func deviceAxesLandOnTheDocumentedCameraAxes() {
        let toAR = CameraSeed.Frames.deviceToARCamera
        // ARKit: camera x runs along the long axis toward the home-button end (device −y), y is up
        // in that landscape orientation (device +x), z comes out of the screen (device +z).
        #expect(toAR * SIMD3<Double>(0, -1, 0) == SIMD3<Double>(1, 0, 0))
        #expect(toAR * SIMD3<Double>(1, 0, 0) == SIMD3<Double>(0, 1, 0))
        #expect(toAR * SIMD3<Double>(0, 0, 1) == SIMD3<Double>(0, 0, 1))

        let toCV = CameraSeed.Frames.deviceToCV
        // The back camera looks out of the back of the phone: forward in the image.
        #expect(toCV * SIMD3<Double>(0, 0, -1) == SIMD3<Double>(0, 0, 1))
        // The top of the phone is image-left; the portrait right edge is image-up.
        #expect(toCV * SIMD3<Double>(0, 1, 0) == SIMD3<Double>(-1, 0, 0))
        #expect(toCV * SIMD3<Double>(1, 0, 0) == SIMD3<Double>(0, -1, 0))
        #expect(abs(simd_determinant(toCV) - 1) < 1e-12)
    }

    @Test func panningRightMovesTheSceneTowardTheScreenLeft() {
        // Upright portrait, looking along reference +X. Columns are the device axes in the
        // reference frame: x (right edge) = −Y, y (top) = +Z (up), z (screen) = −X.
        let deviceToReference = simd_double3x3(columns: (SIMD3<Double>(0, -1, 0),
                                                         SIMD3<Double>(0, 0, 1),
                                                         SIMD3<Double>(-1, 0, 0)))
        let pan = Self.rotation(axis: SIMD3<Double>(0, 0, 1), degrees: -3)   // clockwise from above
        let before = deviceToReference.transpose
        let after = (pan * deviceToReference).transpose
        let rotation = CameraSeed.Frames.cvRotation(fromDeviceRotation: after * before.transpose)
        // The point that was dead ahead. Image rows grow toward the portrait screen's left edge, so
        // the scene sliding left on screen is +y in the sensor image.
        let ray = rotation * SIMD3<Double>(0, 0, 1)
        #expect(abs(ray.x / ray.z) < 1e-9)
        #expect(abs(ray.y / ray.z - tan(3 * .pi / 180)) < 1e-9)
    }

    @Test func attitudeConventionIsReadFromGravity() {
        let upright = simd_double3x3(columns: (SIMD3<Double>(0, -1, 0),
                                               SIMD3<Double>(0, 0, 1),
                                               SIMD3<Double>(-1, 0, 0)))
        let deviceToReference = Self.rotation(axis: SIMD3<Double>(0, 0, 1), degrees: 40) * upright
        let gravity = deviceToReference.transpose * SIMD3<Double>(0, 0, -1)
        #expect(simd_length(gravity - SIMD3<Double>(0, -1, 0)) < 1e-12)   // upright: along −y

        var refToDev = CameraSeed.AttitudeConvention(votesNeeded: 3)
        for _ in 0..<3 { refToDev.observe(matrix: deviceToReference.transpose, gravity: gravity) }
        #expect(refToDev.resolved == .referenceToDevice)

        var devToRef = CameraSeed.AttitudeConvention(votesNeeded: 3)
        for _ in 0..<3 { devToRef.observe(matrix: deviceToReference, gravity: gravity) }
        #expect(devToRef.resolved == .deviceToReference)

        // Flat on a table both readings put gravity in the same place, so neither may vote.
        var flat = CameraSeed.AttitudeConvention(votesNeeded: 1)
        flat.observe(matrix: Self.rotation(axis: SIMD3<Double>(0, 0, 1), degrees: 30),
                     gravity: SIMD3<Double>(0, 0, -1))
        #expect(flat.resolved == nil)
    }

    @Test func attitudeIsInterpolatedBetweenSamples() throws {
        var history = CameraSeed.AttitudeHistory()
        history.append(time: 10.0, matrix: matrix_identity_double3x3)
        history.append(time: 10.05, matrix: Self.rotation(axis: SIMD3<Double>(0, 0, 1), degrees: 10))
        let middle = try #require(history.matrix(at: 10.025))
        #expect(abs(CameraSeed.Frames.rotationAngleDeg(middle) - 5) < 1e-6)
        #expect(Self.isNil(history.matrix(at: 10.2)))
        #expect(Self.isNil(history.matrix(at: 9.9)))
    }

    // MARK: - Tracker on synthetic images

    /// A smooth texture with structure in every direction, defined at any real position.
    private static func texture(_ x: Double, _ y: Double) -> Float {
        var v = 128.0
        v += 22 * sin(0.31 * x + 0.17 * y + 0.4)
        v += 18 * sin(-0.13 * x + 0.29 * y + 1.3)
        v += 15 * sin(0.21 * x - 0.23 * y + 2.1)
        v += 12 * sin(0.05 * x + 0.41 * y + 0.7)
        v += 10 * sin(0.37 * x + 0.02 * y + 2.9)
        v += 20 * sin(0.08 * x + 0.05 * y + 0.2)
        return Float(v)
    }

    private static func image(width: Int = 160, height: Int = 120,
                              _ f: (Double, Double) -> Float) -> CameraSeed.GrayImage {
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = f(Double(x), Double(y))
            }
        }
        return CameraSeed.GrayImage(width: width, height: height, pixels: pixels)
    }

    private static func trackerConfig() -> CameraSeed.Tracker.Config {
        var config = CameraSeed.Tracker.Config()
        config.maxLevels = 3
        config.cellSize = 12
        return config
    }

    @Test func trackerRecoversASubpixelShift() {
        let shift = SIMD2<Double>(2.3, -1.4)
        let first = Self.image { Self.texture($0, $1) }
        let second = Self.image { Self.texture($0 - shift.x, $1 - shift.y) }
        let output = CameraSeed.Tracker.track(from: first, to: second, config: Self.trackerConfig())
        #expect(output.tracks.count >= 40)
        let errors = output.tracks.map { simd_length(($0.p2 - $0.p1) - shift) }
        #expect((CameraSeed.Stats.median(errors) ?? .infinity) < 0.1)
    }

    @Test func trackerIgnoresAnExposureChange() {
        let shift = SIMD2<Double>(-1.7, 0.9)
        let first = Self.image { Self.texture($0, $1) }
        // Twenty grey levels brighter, as when the phone swings from the cabin to a window.
        let second = Self.image { Self.texture($0 - shift.x, $1 - shift.y) + 20 }
        let output = CameraSeed.Tracker.track(from: first, to: second, config: Self.trackerConfig())
        #expect(output.tracks.count >= 40)
        let errors = output.tracks.map { simd_length(($0.p2 - $0.p1) - shift) }
        #expect((CameraSeed.Stats.median(errors) ?? .infinity) < 0.1)
    }

    @Test func trackedExpansionPointsAtItsCentre() throws {
        // Image 2 is image 1 enlarged 4% about (92, 54): the view of a camera moving toward that point.
        let centre = SIMD2<Double>(92, 54)
        let scale = 1.04
        let first = Self.image { Self.texture($0, $1) }
        let second = Self.image { x, y in
            Self.texture(centre.x + (x - centre.x) / scale, centre.y + (y - centre.y) / scale)
        }
        let output = CameraSeed.Tracker.track(from: first, to: second, config: Self.trackerConfig())
        let pinhole = CameraSeed.Pinhole(fx: 140, fy: 140, cx: 80, cy: 60)
        let samples = CameraSeed.Derotation.samples(tracks: output.tracks, pinhole1: pinhole,
                                                    pinhole2: pinhole, rotation: matrix_identity_double3x3)
        let report = CameraSeed.FOESolver.solve(samples, config: CameraSeed.FOESolver.Config(focalPx: 140))
        let direction = try #require(report.direction)
        let expected = simd_normalize(SIMD3<Double>((centre.x - 80) / 140, (centre.y - 60) / 140, 1))
        #expect(Self.angleDeg(direction, expected) < 1.0)
    }

    @Test func aLongPairWithAPhoneTurnIsTrackedFromTheIMUPrediction() throws {
        // Two seconds apart the hand has turned 9° and the scene has expanded 4% about (92, 54).
        // Image 2 at (x, y): undo the turn, then the expansion, and sample the texture there.
        let pinhole = CameraSeed.Pinhole(fx: 140, fy: 140, cx: 80, cy: 60)
        let turn = Self.rotation(axis: SIMD3<Double>(0.2, 1, 0.1), degrees: 9)
        let inverse = turn.transpose
        let centre = SIMD2<Double>(92, 54)
        let scale = 1.04
        let first = Self.image { Self.texture($0, $1) }
        let second = Self.image { x, y in
            let unturned = CameraSeed.Derotation.rotatedPixel(SIMD2<Double>(x, y), from: pinhole,
                                                              to: pinhole, rotation: inverse)
                ?? SIMD2<Double>(x, y)
            return Self.texture(centre.x + (unturned.x - centre.x) / scale,
                                centre.y + (unturned.y - centre.y) / scale)
        }
        let predicted = CameraSeed.Tracker.track(
            from: first, to: second, config: Self.trackerConfig(),
            predict: { CameraSeed.Derotation.rotatedPixel($0, from: pinhole, to: pinhole, rotation: turn) },
            predictBack: { CameraSeed.Derotation.rotatedPixel($0, from: pinhole, to: pinhole, rotation: inverse) })
        #expect(predicted.tracks.count >= 40)

        let samples = CameraSeed.Derotation.samples(tracks: predicted.tracks, pinhole1: pinhole,
                                                    pinhole2: pinhole, rotation: turn)
        let report = CameraSeed.FOESolver.solve(samples, config: CameraSeed.FOESolver.Config(focalPx: 140))
        let direction = try #require(report.direction)
        let expected = simd_normalize(SIMD3<Double>((centre.x - 80) / 140, (centre.y - 60) / 140, 1))
        #expect(Self.angleDeg(direction, expected) < 1.0)

        // Without the prediction most of those tracks are simply lost.
        let unpredicted = CameraSeed.Tracker.track(from: first, to: second, config: Self.trackerConfig())
        #expect(unpredicted.tracks.count < predicted.tracks.count / 2)
    }

    @Test func featurelessImageGivesNoTracks() {
        let flat = Self.image { _, _ in 90 }
        let output = CameraSeed.Tracker.track(from: flat, to: flat, config: Self.trackerConfig())
        #expect(output.featureCount == 0)
        #expect(output.tracks.isEmpty)
    }

    @Test func lumaIsReducedAroundBlockCentresAndTheIntrinsicsFollow() throws {
        let width = 16
        let height = 8
        let rowBytes = 20
        var plane = [UInt8](repeating: 255, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                plane[y * rowBytes + x] = UInt8(x + 10 * y)
            }
        }
        let reduced = plane.withUnsafeBytes { raw in
            CameraSeed.GrayImage.downsampled(plane: raw.baseAddress!, width: width, height: height,
                                             bytesPerRow: rowBytes, factor: 4)
        }
        let image = try #require(reduced)
        #expect(image.width == 4)
        #expect(image.height == 2)
        for j in 0..<2 {
            for i in 0..<4 {
                // The 2×2 average at the centre of each 4×4 block: coordinate 4i + 1.5.
                let expected = Float(4 * i) + 1.5 + 10 * (Float(4 * j) + 1.5)
                #expect(abs(image.pixels[j * 4 + i] - expected) < 1e-4)
            }
        }

        // Any full-resolution pixel names the same ray at either resolution.
        let full = CameraSeed.Pinhole(fx: 10, fy: 12, cx: 8, cy: 4)
        let small = full.downsampled(by: 4)
        let fullPixel = SIMD2<Double>(13.5, 6.5)
        let smallPixel = (fullPixel - SIMD2<Double>(repeating: 1.5)) / 4
        #expect(simd_length(full.normalized(fullPixel) - small.normalized(smallPixel)) < 1e-12)
    }

    // MARK: - Gating, budget, pairing, logging

    @Test func gateOpensOnlyAtSpeedWithAGoodCourse() {
        typealias Gate = CameraSeed.Gate
        #expect(Gate.closed(speedKt: 15, courseDeg: 90, courseAccuracyDeg: 5, thermalOK: true) == nil)
        #expect(Gate.closed(speedKt: 14.9, courseDeg: 90, courseAccuracyDeg: 1, thermalOK: true) == .speed)
        #expect(Gate.closed(speedKt: 80, courseDeg: -1, courseAccuracyDeg: 1, thermalOK: true) == .course)
        #expect(Gate.closed(speedKt: 80, courseDeg: 90, courseAccuracyDeg: 5.1, thermalOK: true) == .courseAccuracy)
        #expect(Gate.closed(speedKt: 80, courseDeg: 90, courseAccuracyDeg: -1, thermalOK: true) == .courseAccuracy)
        #expect(Gate.closed(speedKt: 80, courseDeg: 90, courseAccuracyDeg: 1, thermalOK: false) == .thermal)
        #expect(Gate.closed(speedKt: .nan, courseDeg: 90, courseAccuracyDeg: 1, thermalOK: true) == .speed)
    }

    @Test func captureScheduleIsThrottledAndBounded() {
        var schedule = CameraSeed.CaptureSchedule(interval: 0.25, maxCaptures: 3)
        let first = schedule.isDue(at: 100.0)
        let tooSoon = schedule.isDue(at: 100.1)
        let next = schedule.isDue(at: 100.26)
        #expect(first)
        #expect(!tooSoon)
        #expect(next)
        #expect(!schedule.hasStarted)
        schedule.recordCapture()
        schedule.recordCapture()
        #expect(schedule.hasStarted)
        #expect(!schedule.isExhausted)
        schedule.recordCapture()
        #expect(schedule.isExhausted)

        // The default budget is the issue's "roughly the first 60 s", four frames a second.
        let standard = CameraSeed.CaptureSchedule()
        #expect(Double(standard.maxCaptures) * standard.interval == 60)
    }

    /// The eight frames the runner keeps, one per quarter second, as seen from t = 10 s.
    private static let keptLadder: [Double] = (1...8).reversed().map { 10.0 - 0.25 * Double($0) }

    /// Run the planner against ground moving `pxPerSecond`, choosing each pair from the ladder.
    /// Returns the last gap used.
    private static func settle(_ planner: inout CameraSeed.PairPlanner, pxPerSecond: Double,
                               pairs: Int = 8) -> Double {
        var gap = Double.nan
        for _ in 0..<pairs {
            guard let index = planner.partner(for: 10.0, among: keptLadder) else { break }
            gap = 10.0 - keptLadder[index]
            planner.update(gapUsed: gap, medianFlowPx: pxPerSecond * gap, movingCount: 150,
                           trackedFraction: 0.9)
        }
        return gap
    }

    @Test func pairGapReachesTwoSecondsWhenTheGroundCrawls() {
        // FL403 at 480 kt out of a side window: about 0.5°/s, ~4 px/s at the working scale. A
        // quarter-second pair would see 1 px of motion; two seconds sees 8.
        var planner = CameraSeed.PairPlanner()
        #expect(planner.targetGap == 0.25)
        let gap = Self.settle(&planner, pxPerSecond: 4)
        #expect(planner.targetGap == 2.0)
        #expect(gap == 2.0)
        // The pair it then forms is with the oldest kept frame, two seconds back.
        #expect(planner.partner(for: 10.0, among: Self.keptLadder) == 0)
    }

    @Test func pairGapStaysAtAQuarterSecondWhenTheGroundRaces() {
        // A car's roadside: tens of pixels in a quarter second.
        var planner = CameraSeed.PairPlanner()
        let gap = Self.settle(&planner, pxPerSecond: 160)
        #expect(gap == 0.25)
        #expect(planner.targetGap == 0.25)

        // And from two seconds, one fast pair brings it straight back down.
        var long = CameraSeed.PairPlanner()
        _ = Self.settle(&long, pxPerSecond: 4)
        long.update(gapUsed: 2.0, medianFlowPx: 80, movingCount: 150, trackedFraction: 0.9)
        #expect(long.targetGap == 0.25)
    }

    @Test func pairGapShortensWhenTracksAreLostAndLengthensWhenNothingMoves() {
        var planner = CameraSeed.PairPlanner()
        _ = Self.settle(&planner, pxPerSecond: 4)
        // Most features lost: the motion outran the tracker.
        planner.update(gapUsed: 2.0, medianFlowPx: .nan, movingCount: 3, trackedFraction: 0.1)
        #expect(planner.targetGap == 1.0)

        // Plenty tracked but nothing measurably moving: look further apart, a doubling at a time.
        var still = CameraSeed.PairPlanner()
        still.update(gapUsed: 0.25, medianFlowPx: .nan, movingCount: 0, trackedFraction: 0.9)
        #expect(still.targetGap == 0.5)
    }

    @Test func pairsAreOnlyFormedWithinTheirBounds() {
        let planner = CameraSeed.PairPlanner()
        #expect(planner.partner(for: 10.0, among: []) == nil)
        #expect(planner.partner(for: 10.0, among: [7.5]) == nil)    // 2.5 s: too old
        #expect(planner.partner(for: 10.0, among: [9.9]) == nil)    // 0.1 s: too close
        #expect(planner.partner(for: 10.0, among: [7.87]) == 0)     // 2.13 s: capture jitter allowed
    }

    @Test func midpointCourseGoesTheShortWayRound() {
        #expect(CameraSeed.Stats.midpointDeg(350, 10) == 0)
        #expect(CameraSeed.Stats.midpointDeg(10, 350) == 0)
        #expect(CameraSeed.Stats.midpointDeg(90, 100) == 95)
        #expect(CameraSeed.Stats.midpointDeg(359, 359) == 359)
    }

    @Test func keptFramesArePackedToOneBytePerPixel() {
        let image = CameraSeed.GrayImage(width: 5, height: 1, pixels: [0.25, 1.5, 254.7, 300, -3])
        let packed = CameraSeed.PackedImage(image)
        #expect(packed.bytes == [0, 2, 255, 255, 0])
        let back = packed.image
        #expect(back.width == 5)
        #expect(back.height == 1)
        #expect(back.pixels == [0, 2, 255, 255, 0])
    }

    @Test func noneEventsAreRateLimited() {
        var limiter = CameraSeed.EventLimiter(minInterval: 1, repeatInterval: 2, maxEvents: 3)
        let steps: [(reason: String, time: Double, expected: Int?)] = [
            ("a", 0, 0),
            ("a", 0.5, nil),   // same reason, too soon
            ("b", 0.7, nil),   // new reason, inside the minimum spacing
            ("b", 1.2, 2),     // logged, carrying the two held back
            ("b", 2.0, nil),
            ("b", 3.3, 1),     // the repeat interval has passed
            ("c", 10, nil),    // the cap of three is reached
        ]
        for step in steps {
            let got = limiter.admit(step.reason, at: step.time)
            #expect(got == step.expected, "\(step.reason) at \(step.time)")
        }

        var changesOnly = CameraSeed.EventLimiter(minInterval: 1, repeatInterval: nil, maxEvents: 50)
        let opened = changesOnly.admit("gate_speed", at: 0)
        let repeated = changesOnly.admit("gate_speed", at: 100)
        changesOnly.clearReason()
        let cleared = changesOnly.admit("gate_speed", at: 101)
        #expect(opened == 0)
        #expect(repeated == nil)
        #expect(cleared == 1)
    }

    @Test func offsetSummaryUnwrapsAcrossSouth() throws {
        let summary = try #require(CameraSeed.Stats.angularMedianAndIQR([178, -179, 179, -178, 180]))
        #expect(abs(AngularResponse.signedDelta(summary.median, 180)) < 1e-9)
        #expect(abs(summary.iqr - 2) < 1e-9)
        #expect(Self.isNil(CameraSeed.Stats.angularMedianAndIQR([])))
        #expect(CameraSeed.Stats.median([3, 1, 2, 10]) == 2.5)
    }
}
