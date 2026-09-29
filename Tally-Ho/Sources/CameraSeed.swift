//
//  CameraSeed.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The direction of travel from the view out of the window, in shadow mode (issue #8).
//
//  In the cabin nothing else knows where the phone points. The compass repeats the GPS course
//  (build 42: slope −0.01 over 263° of phone yaw), and GPS knows where the aircraft goes, not
//  where the phone points. The camera does. Ground and cloud seen through a window stream away
//  from the focus of expansion (FOE), which is the direction of travel over the ground — the same
//  direction GPS reports as the track, so crab angle cancels. The FOE's azimuth in the ARKit world
//  against the GPS track is the world offset, with no aiming.
//
//  **Shadow mode.** Nothing here writes the world offset, the seed, the fade or anything shown.
//  It computes and records `camera_seed_*` flight-recorder events, and that is all.
//
//  Layout. Everything under `CameraSeed` is pure — Foundation and simd only, no ARKit, no Vision,
//  no CoreMotion types — so the tests drive it with synthetic scenes. `CameraSeedRunner` at the
//  bottom is the only part that touches the session, and it is plumbing.
//
//  One pair of frames, end to end:
//    1. The luma plane is reduced to ~480 px wide on the render thread and the ARFrame dropped.
//    2. Sparse pyramidal Lucas–Kanade between the two, forward–backward checked. Pure Swift
//       rather than Vision, so the flow's sign convention is this file's and the tests reach it.
//    3. The phone's own rotation between the frames, from device-motion attitude, is removed from
//       every track. What is left is translation only; the cabin, static relative to the phone
//       once the phone's rotation is gone, is left with about zero flow and is set aside.
//    4. Each derotated vector u at p constrains the FOE e by (p − e) × u = 0, linear in
//       homogeneous e. RANSAC on pairs, then reweighted least squares on the inliers. Homogeneous
//       throughout, so an FOE off-screen or at infinity (phone pointing sideways) is ordinary.
//    5. FOE → ARKit world through camera.transform → azimuth by `rawAzimuthDeg`'s own formula;
//       offset = signedDelta(foeAz, gpsTrack), the StartupSeed convention.
//

import Foundation
import simd
import CoreVideo
import CoreMotion
import ARKit

/// The pure half of the camera seed. No member of this namespace touches ARKit, Vision or
/// CoreMotion; see `CameraSeedRunner` for the half that does.
enum CameraSeed {

    // MARK: - Failure reasons

    /// Why a pair of frames produced no estimate. The raw value is what `camera_seed_none` logs.
    enum Failure: String, Error {
        /// Fewer tracked vectors than an estimate needs at all.
        case tooFewVectors = "too_few_vectors"
        /// Enough vectors, but almost all of them static once derotated: cabin, or no ground.
        case staticScene = "static_scene"
        /// Moving vectors that do not agree on any one FOE.
        case noConsensus = "no_consensus"
        /// No hypothesis could be formed at all.
        case degenerate
        /// The FOE came out too far from horizontal to be a direction of travel.
        case steepDirection = "steep_direction"
    }

    // MARK: - Deterministic randomness

    /// SplitMix64. RANSAC draws from this so a run is reproducible from its inputs alone.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Camera model

    /// Pinhole intrinsics in the computer-vision convention: x along image columns, y along image
    /// rows (down), z forward out of the lens. "Normalised" coordinates are (x/z, y/z).
    struct Pinhole: Equatable {
        var fx: Double
        var fy: Double
        var cx: Double
        var cy: Double

        func normalized(_ pixel: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2<Double>((pixel.x - cx) / fx, (pixel.y - cy) / fy)
        }

        func pixel(_ normalized: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2<Double>(normalized.x * fx + cx, normalized.y * fy + cy)
        }

        /// The same camera as seen through `GrayImage.downsampled(plane:…factor:)`, whose output
        /// pixel i is centred on input coordinate `factor · i + GrayImage.sampleOffset(factor)`.
        func downsampled(by factor: Int) -> Pinhole {
            let f = Double(max(1, factor))
            let offset = GrayImage.sampleOffset(forFactor: factor)
            return Pinhole(fx: fx / f, fy: fy / f, cx: (cx - offset) / f, cy: (cy - offset) / f)
        }
    }

    // MARK: - Images

    /// A single-channel image, 0–255 scale, row-major.
    struct GrayImage {
        let width: Int
        let height: Int
        var pixels: [Float]

        init(width: Int, height: Int, pixels: [Float]) {
            precondition(width >= 0 && height >= 0 && pixels.count == width * height)
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        /// Where output pixel i's centre falls in input coordinates, less `factor · i`.
        static func sampleOffset(forFactor factor: Int) -> Double {
            factor <= 1 ? 0 : Double(factor / 2 - 1) + 0.5
        }

        /// Reduce an 8-bit plane by an integer factor, averaging the 2×2 block at the centre of each
        /// factor×factor cell. Four reads per output pixel, because this runs on the render thread:
        /// at 1920→480 that is ~0.7 M byte reads, not the 2.8 M a full box filter would take.
        static func downsampled(plane base: UnsafeRawPointer, width: Int, height: Int,
                                bytesPerRow: Int, factor: Int) -> GrayImage? {
            let f = max(1, factor)
            let outW = width / f
            let outH = height / f
            guard outW >= 2, outH >= 2, bytesPerRow >= width else { return nil }
            let src = base.assumingMemoryBound(to: UInt8.self)
            var out = [Float](repeating: 0, count: outW * outH)
            if f == 1 {
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<outH {
                        let row = src + y * bytesPerRow
                        for x in 0..<outW {
                            dst[y * outW + x] = Float(row[x])
                        }
                    }
                }
            } else {
                let o = f / 2 - 1
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<outH {
                        let row0 = src + (y * f + o) * bytesPerRow
                        let row1 = row0 + bytesPerRow
                        for x in 0..<outW {
                            let sx = x * f + o
                            let sum = Int(row0[sx]) + Int(row0[sx + 1]) + Int(row1[sx]) + Int(row1[sx + 1])
                            dst[y * outW + x] = Float(sum) * 0.25
                        }
                    }
                }
            }
            return GrayImage(width: outW, height: outH, pixels: out)
        }

        /// Bilinear sample with edge clamping. Needs at least 2×2 pixels.
        @inline(__always)
        func sample(_ x: Double, _ y: Double) -> Float {
            guard x.isFinite, y.isFinite else { return 0 }
            let xc = min(max(x, 0), Double(width - 1))
            let yc = min(max(y, 0), Double(height - 1))
            let x0 = min(Int(xc), width - 2)
            let y0 = min(Int(yc), height - 2)
            let ax = Float(xc - Double(x0))
            let ay = Float(yc - Double(y0))
            let i = y0 * width + x0
            let p00 = pixels[i]
            let p10 = pixels[i + 1]
            let p01 = pixels[i + width]
            let p11 = pixels[i + width + 1]
            let top = p00 + (p10 - p00) * ax
            let bottom = p01 + (p11 - p01) * ax
            return top + (bottom - top) * ay
        }

        /// Half size by 2×2 averaging. Output pixel i sits at this image's coordinate 2i + 0.5.
        func halved() -> GrayImage {
            let w = width / 2
            let h = height / 2
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let r0 = (2 * y) * width
                let r1 = r0 + width
                for x in 0..<w {
                    let sx = 2 * x
                    out[y * w + x] = (pixels[r0 + sx] + pixels[r0 + sx + 1]
                                      + pixels[r1 + sx] + pixels[r1 + sx + 1]) * 0.25
                }
            }
            return GrayImage(width: w, height: h, pixels: out)
        }

        /// Central-difference gradients, zero on the one-pixel border.
        func gradients() -> (x: GrayImage, y: GrayImage) {
            var gx = [Float](repeating: 0, count: width * height)
            var gy = gx
            if width >= 3 && height >= 3 {
                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) {
                        let i = y * width + x
                        gx[i] = (pixels[i + 1] - pixels[i - 1]) * 0.5
                        gy[i] = (pixels[i + width] - pixels[i - width]) * 0.5
                    }
                }
            }
            return (GrayImage(width: width, height: height, pixels: gx),
                    GrayImage(width: width, height: height, pixels: gy))
        }
    }

    /// An image pyramid by repeated 2×2 averaging, with gradients at every level.
    struct Pyramid {
        let levels: [GrayImage]
        let gradX: [GrayImage]
        let gradY: [GrayImage]

        init(_ base: GrayImage, maxLevels: Int, minSize: Int) {
            var images = [base]
            while images.count < maxLevels {
                let last = images[images.count - 1]
                guard last.width / 2 >= minSize, last.height / 2 >= minSize else { break }
                images.append(last.halved())
            }
            var gx: [GrayImage] = []
            var gy: [GrayImage] = []
            for image in images {
                let g = image.gradients()
                gx.append(g.x)
                gy.append(g.y)
            }
            levels = images
            gradX = gx
            gradY = gy
        }

        /// A level-0 position in level-L coordinates. Level L+1 pixel i sits at level-L coordinate
        /// 2i + 0.5, so the shift accumulates to (2^L − 1)/2 before the scale.
        static func position(_ p: SIMD2<Double>, atLevel level: Int) -> SIMD2<Double> {
            let scale = Double(1 << level)
            let shift = (scale - 1) / 2
            return (p - SIMD2<Double>(repeating: shift)) / scale
        }
    }

    // MARK: - Sparse optical flow

    /// Pyramidal Lucas–Kanade on corners chosen one per grid cell, forward–backward checked.
    ///
    /// Each window is compared with its mean removed, so a change of exposure between the two
    /// frames — routine when the phone swings from the cabin to a bright window — is not read as
    /// motion.
    enum Tracker {

        struct Config {
            var maxLevels = 4
            var windowRadius = 4
            var maxIterations = 12
            /// Stop iterating once a step is smaller than this, in pixels of the level.
            var epsilon = 0.01
            /// One corner per cell of this size, so tracks cover the view rather than one texture.
            var cellSize = 24
            var margin = 8
            /// Minimum eigenvalue of the 5×5 structure tensor for a corner, in grey levels².
            var minCornerScore: Float = 60
            /// Minimum eigenvalue of the tracking window's centred gradient matrix, per pixel.
            var minEigenPerPixel = 0.25
            /// Tracking back from the end must land this close to the start, in level-0 pixels.
            var forwardBackwardPx = 0.5
        }

        struct Track {
            var p1: SIMD2<Double>
            var p2: SIMD2<Double>
        }

        struct Output {
            var featureCount: Int
            var tracks: [Track]
        }

        static func track(from first: GrayImage, to second: GrayImage,
                          config: Config = Config()) -> Output {
            guard first.width == second.width, first.height == second.height,
                  first.width >= 2, first.height >= 2 else {
                return Output(featureCount: 0, tracks: [])
            }
            let minSize = 2 * config.windowRadius + 3
            let a = Pyramid(first, maxLevels: config.maxLevels, minSize: minSize)
            let b = Pyramid(second, maxLevels: config.maxLevels, minSize: minSize)
            let features = corners(gradX: a.gradX[0], gradY: a.gradY[0], config: config)
            let maxX = Double(first.width - 1)
            let maxY = Double(first.height - 1)
            var tracks: [Track] = []
            tracks.reserveCapacity(features.count)
            for start in features {
                guard let flow = pyramidal(from: a, to: b, point: start, config: config) else { continue }
                let end = start + flow
                guard end.x >= 0, end.y >= 0, end.x <= maxX, end.y <= maxY else { continue }
                guard let back = pyramidal(from: b, to: a, point: end, config: config) else { continue }
                guard simd_length(end + back - start) <= config.forwardBackwardPx else { continue }
                tracks.append(Track(p1: start, p2: end))
            }
            return Output(featureCount: features.count, tracks: tracks)
        }

        /// The strongest corner in each grid cell (Shi–Tomasi score over a 5×5 window, candidates on
        /// a stride of two), if it clears the floor.
        static func corners(gradX: GrayImage, gradY: GrayImage, config: Config) -> [SIMD2<Double>] {
            let w = gradX.width
            let h = gradX.height
            let r = 2
            let m = max(config.margin, r + 1)
            let cell = max(4, config.cellSize)
            guard w > 2 * m, h > 2 * m else { return [] }
            var found: [SIMD2<Double>] = []
            var y0 = m
            while y0 < h - m {
                let y1 = min(y0 + cell, h - m)
                var x0 = m
                while x0 < w - m {
                    let x1 = min(x0 + cell, w - m)
                    var bestScore = config.minCornerScore
                    var best: SIMD2<Double>?
                    var y = y0
                    while y < y1 {
                        var x = x0
                        while x < x1 {
                            var a: Float = 0
                            var b: Float = 0
                            var c: Float = 0
                            for dy in -r...r {
                                let row = (y + dy) * w
                                for dx in -r...r {
                                    let gxv = gradX.pixels[row + x + dx]
                                    let gyv = gradY.pixels[row + x + dx]
                                    a += gxv * gxv
                                    b += gxv * gyv
                                    c += gyv * gyv
                                }
                            }
                            let halfDiff = (a - c) * 0.5
                            let score = (a + c) * 0.5 - (halfDiff * halfDiff + b * b).squareRoot()
                            if score > bestScore {
                                bestScore = score
                                best = SIMD2<Double>(Double(x), Double(y))
                            }
                            x += 2
                        }
                        y += 2
                    }
                    if let best { found.append(best) }
                    x0 += cell
                }
                y0 += cell
            }
            return found
        }

        /// Displacement of the level-0 `point` from pyramid `a` to pyramid `b`, coarse to fine.
        static func pyramidal(from a: Pyramid, to b: Pyramid, point: SIMD2<Double>,
                              config: Config) -> SIMD2<Double>? {
            let top = min(a.levels.count, b.levels.count) - 1
            guard top >= 0 else { return nil }
            var guess = SIMD2<Double>(0, 0)
            for level in stride(from: top, through: 0, by: -1) {
                let x = Pyramid.position(point, atLevel: level)
                guard let d = refine(image: a.levels[level], gradX: a.gradX[level],
                                     gradY: a.gradY[level], target: b.levels[level],
                                     at: x, guess: guess, config: config) else { return nil }
                guess = level > 0 ? d * 2 : d
            }
            return guess
        }

        /// One level of Lucas–Kanade, with a free brightness offset: gradients and differences are
        /// both taken about their window means. Returns the total displacement at this level.
        static func refine(image: GrayImage, gradX: GrayImage, gradY: GrayImage,
                           target: GrayImage, at point: SIMD2<Double>, guess: SIMD2<Double>,
                           config: Config) -> SIMD2<Double>? {
            let r = config.windowRadius
            let side = 2 * r + 1
            let count = side * side
            var templ = [Float](repeating: 0, count: count)
            var tx = [Float](repeating: 0, count: count)
            var ty = [Float](repeating: 0, count: count)
            var window = [Float](repeating: 0, count: count)
            var sumI: Float = 0
            var sumX: Float = 0
            var sumY: Float = 0
            var k = 0
            for dy in -r...r {
                for dx in -r...r {
                    let sx = point.x + Double(dx)
                    let sy = point.y + Double(dy)
                    let iv = image.sample(sx, sy)
                    let xv = gradX.sample(sx, sy)
                    let yv = gradY.sample(sx, sy)
                    templ[k] = iv
                    tx[k] = xv
                    ty[k] = yv
                    sumI += iv
                    sumX += xv
                    sumY += yv
                    k += 1
                }
            }
            let n = Float(count)
            let meanI = sumI / n
            let meanX = sumX / n
            let meanY = sumY / n
            var gxx = 0.0
            var gxy = 0.0
            var gyy = 0.0
            for i in 0..<count {
                tx[i] -= meanX
                ty[i] -= meanY
                gxx += Double(tx[i] * tx[i])
                gxy += Double(tx[i] * ty[i])
                gyy += Double(ty[i] * ty[i])
            }
            let det = gxx * gyy - gxy * gxy
            let halfDiff = (gxx - gyy) / 2
            let minEigen = (gxx + gyy) / 2 - (halfDiff * halfDiff + gxy * gxy).squareRoot()
            guard det > 1e-9, minEigen / Double(count) >= config.minEigenPerPixel else { return nil }

            var v = guess
            let slack = Double(r)
            for _ in 0..<config.maxIterations {
                var sumJ: Float = 0
                k = 0
                for dy in -r...r {
                    for dx in -r...r {
                        let jv = target.sample(point.x + v.x + Double(dx), point.y + v.y + Double(dy))
                        window[k] = jv
                        sumJ += jv
                        k += 1
                    }
                }
                let meanJ = sumJ / n
                var bx = 0.0
                var by = 0.0
                for i in 0..<count {
                    let diff = Double((templ[i] - meanI) - (window[i] - meanJ))
                    bx += diff * Double(tx[i])
                    by += diff * Double(ty[i])
                }
                let ex = (gyy * bx - gxy * by) / det
                let ey = (gxx * by - gxy * bx) / det
                v.x += ex
                v.y += ey
                guard v.x.isFinite, v.y.isFinite else { return nil }
                let px = point.x + v.x
                let py = point.y + v.y
                guard px > -slack, py > -slack,
                      px < Double(target.width - 1) + slack,
                      py < Double(target.height - 1) + slack else { return nil }
                if ex * ex + ey * ey < config.epsilon * config.epsilon { break }
            }
            return v
        }
    }

    // MARK: - Coordinate frames

    enum Frames {
        /// CoreMotion device axes (x right, y toward the top, z out of the screen, all in portrait)
        /// into ARKit camera axes. ARKit states its camera frame against the sensor's native
        /// landscape orientation: x along the long axis toward the home-button end (device −y), y up
        /// in that orientation (device +x), z out of the screen (device +z).
        static let deviceToARCamera = simd_double3x3(rows: [
            SIMD3<Double>(0, -1, 0),
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 0, 1),
        ])

        /// ARKit camera axes into the computer-vision convention of the image and the solver: x
        /// along image columns, y along image rows (down), z forward out of the lens.
        static let arCameraToCV = simd_double3x3(diagonal: SIMD3<Double>(1, -1, -1))

        static let deviceToCV = arCameraToCV * deviceToARCamera

        /// A relative rotation expressed in device coordinates, re-expressed in CV coordinates.
        static func cvRotation(fromDeviceRotation r: simd_double3x3) -> simd_double3x3 {
            deviceToCV * r * deviceToCV.transpose
        }

        /// A relative rotation expressed in ARKit camera coordinates, re-expressed in CV ones.
        static func cvRotation(fromARCameraRotation r: simd_double3x3) -> simd_double3x3 {
            arCameraToCV * r * arCameraToCV.transpose
        }

        static func arCameraDirection(fromCV v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3<Double>(v.x, -v.y, -v.z)
        }

        /// The rotation part of an ARKit transform, in double precision.
        static func rotation(of t: simd_float4x4) -> simd_double3x3 {
            simd_double3x3(columns: (
                SIMD3<Double>(Double(t.columns.0.x), Double(t.columns.0.y), Double(t.columns.0.z)),
                SIMD3<Double>(Double(t.columns.1.x), Double(t.columns.1.y), Double(t.columns.1.z)),
                SIMD3<Double>(Double(t.columns.2.x), Double(t.columns.2.y), Double(t.columns.2.z))
            ))
        }

        /// How far a rotation turns, in degrees.
        static func rotationAngleDeg(_ r: simd_double3x3) -> Double {
            let trace = r[0][0] + r[1][1] + r[2][2]
            let c = max(-1.0, min(1.0, (trace - 1) / 2))
            return acos(c) * 180 / .pi
        }
    }

    // MARK: - Device attitude

    /// Which way `CMAttitude.rotationMatrix` maps — reference into device, or device into
    /// reference — read from the data instead of assumed.
    ///
    /// Derotation needs the relative rotation between two attitudes, and the two readings of the
    /// matrix give rotations about different axes, so a wrong guess would silently corrupt every
    /// estimate and nothing off-device could catch it. `CMDeviceMotion.gravity` settles it: it is
    /// the gravity vector in device coordinates, and gravity is (0, 0, −1) in any Z-vertical
    /// reference frame, so only one reading of the matrix carries the one onto the other. Only
    /// samples where the two readings disagree vote; a phone lying flat cannot tell them apart.
    struct AttitudeConvention {
        enum Kind: String {
            case referenceToDevice = "ref_to_dev"
            case deviceToReference = "dev_to_ref"

            /// The matrix that takes reference-frame vectors into device coordinates.
            func referenceToDeviceMatrix(_ m: simd_double3x3) -> simd_double3x3 {
                self == .referenceToDevice ? m : m.transpose
            }
        }

        let votesNeeded: Int
        private(set) var resolved: Kind?
        private(set) var refToDevVotes = 0
        private(set) var devToRefVotes = 0

        init(votesNeeded: Int = 5) {
            self.votesNeeded = votesNeeded
        }

        mutating func observe(matrix m: simd_double3x3, gravity: SIMD3<Double>) {
            guard resolved == nil else { return }
            let length = simd_length(gravity)
            guard length.isFinite, length > 0.5 else { return }
            let measured = gravity / length
            let down = SIMD3<Double>(0, 0, -1)
            let ifRefToDev = simd_length(m * down - measured)
            let ifDevToRef = simd_length(m.transpose * down - measured)
            guard abs(ifRefToDev - ifDevToRef) > 0.3, min(ifRefToDev, ifDevToRef) < 0.15 else { return }
            if ifRefToDev < ifDevToRef {
                refToDevVotes += 1
            } else {
                devToRefVotes += 1
            }
            if refToDevVotes >= votesNeeded, devToRefVotes * 4 <= refToDevVotes {
                resolved = .referenceToDevice
            } else if devToRefVotes >= votesNeeded, refToDevVotes * 4 <= devToRefVotes {
                resolved = .deviceToReference
            }
        }
    }

    /// Recent device-motion attitude matrices, interpolated to a frame's timestamp.
    ///
    /// Device motion runs at 20 Hz. At 30°/s of hand motion, taking the nearest sample instead
    /// would be up to 0.75° wrong — more than the whole ground motion between two frames at
    /// altitude — so the attitude is slerped between the samples either side.
    struct AttitudeHistory {
        let capacity: Int
        /// How far outside the sampled span a query may be clamped to its end.
        let tolerance: TimeInterval
        /// Two samples further apart than this are not interpolated between.
        let maxGap: TimeInterval
        private var times: [TimeInterval] = []
        private var orientations: [simd_quatd] = []

        init(capacity: Int = 64, tolerance: TimeInterval = 0.01, maxGap: TimeInterval = 0.15) {
            self.capacity = capacity
            self.tolerance = tolerance
            self.maxGap = maxGap
        }

        var latestTime: TimeInterval? { times.last }

        mutating func append(time: TimeInterval, matrix: simd_double3x3) {
            guard time.isFinite else { return }
            if let last = times.last, time <= last { return }
            times.append(time)
            orientations.append(simd_quatd(matrix))
            if times.count > capacity {
                let drop = times.count - capacity
                times.removeFirst(drop)
                orientations.removeFirst(drop)
            }
        }

        mutating func removeAll() {
            times.removeAll()
            orientations.removeAll()
        }

        /// The raw attitude matrix at `time`, or nil if the samples do not cover it.
        func matrix(at time: TimeInterval) -> simd_double3x3? {
            guard let first = times.first, let last = times.last, time.isFinite else { return nil }
            guard time >= first - tolerance, time <= last + tolerance else { return nil }
            if time <= first { return simd_double3x3(orientations[0]) }
            if time >= last { return simd_double3x3(orientations[orientations.count - 1]) }
            var upper = times.count - 1
            while upper > 0 && times[upper - 1] > time { upper -= 1 }
            let lower = upper - 1
            let span = times[upper] - times[lower]
            guard span > 0, span <= maxGap else { return nil }
            let fraction = (time - times[lower]) / span
            return simd_double3x3(simd_slerp(orientations[lower], orientations[upper], fraction))
        }
    }

    // MARK: - Derotation

    /// One flow vector, in normalised CV camera coordinates of the first frame.
    struct FlowSample {
        /// Where the point was in frame 1.
        var p: SIMD2<Double>
        /// Where it went by frame 2, less the phone's rotation.
        var u: SIMD2<Double>
    }

    enum Derotation {
        /// Where a point seen at `normalized` in frame 2 would have appeared had the camera kept
        /// frame 1's orientation. `rotation` takes frame-1 CV coordinates of a fixed direction to
        /// frame-2 ones. Nil when the ray falls behind frame 1's image plane.
        static func unrotate(_ normalized: SIMD2<Double>, rotation: simd_double3x3) -> SIMD2<Double>? {
            let ray = rotation.transpose * SIMD3<Double>(normalized.x, normalized.y, 1)
            guard ray.z > 1e-6 else { return nil }
            return SIMD2<Double>(ray.x / ray.z, ray.y / ray.z)
        }

        static func samples(tracks: [Tracker.Track], pinhole1: Pinhole, pinhole2: Pinhole,
                            rotation: simd_double3x3) -> [FlowSample] {
            var out: [FlowSample] = []
            out.reserveCapacity(tracks.count)
            for track in tracks {
                let start = pinhole1.normalized(track.p1)
                guard let end = unrotate(pinhole2.normalized(track.p2), rotation: rotation) else { continue }
                out.append(FlowSample(p: start, u: end - start))
            }
            return out
        }
    }

    // MARK: - FOE solver

    /// The direction of travel from derotated flow.
    ///
    /// Under pure translation T (CV camera coordinates), a point at normalised p with depth Z moves
    /// by u = (T.z·p − (T.x, T.y)) / Z. So every u lies along w(p) = T.z·p − (T.x, T.y), pointing
    /// the same way as w — which is what fixes the sign: expansion from an FOE ahead, contraction
    /// toward one behind, and parallel flow for T.z = 0, the FOE at infinity. The line through p
    /// along u, l = (−u.y, u.x, p.x·u.y − p.y·u.x), satisfies l · T = 0, linear in T.
    enum FOESolver {

        struct Config {
            /// Shorter than this, a vector is taken as static — cabin — and set aside. Normalised.
            var minFlow: Double
            /// Perpendicular residual allowed however short the vector. Normalised.
            var inlierAbsolute: Double
            /// Plus this fraction of the vector's own length.
            var inlierRelative = 0.1
            var iterations = 300
            var minInliers = 20
            /// Inliers as a share of the moving vectors.
            var minInlierFraction = 0.4
            var refinementPasses = 3
            /// Floor on |w| in the reweighting, so a point sitting on the FOE cannot dominate.
            var weightFloor = 0.02
            var seed: UInt64 = 0x5EED

            init(minFlow: Double, inlierAbsolute: Double) {
                self.minFlow = minFlow
                self.inlierAbsolute = inlierAbsolute
            }

            /// Thresholds stated in pixels of an image with focal length `focalPx`.
            init(focalPx: Double, minFlowPx: Double = 0.75, inlierPx: Double = 0.5) {
                self.init(minFlow: minFlowPx / focalPx, inlierAbsolute: inlierPx / focalPx)
            }
        }

        struct Report {
            var totalCount = 0
            var staticCount = 0
            var movingCount = 0
            var inlierCount = 0
            /// Median length of the moving vectors, normalised units.
            var medianMovingFlow = Double.nan
            /// Median length of the inliers, normalised units.
            var medianInlierFlow = Double.nan
            /// RMS perpendicular residual of the inliers, normalised units.
            var rmsResidual = Double.nan
            /// Unit direction of travel in frame 1's CV camera coordinates. Nil on failure.
            var direction: SIMD3<Double>?
            var failure: Failure?
        }

        static func solve(_ samples: [FlowSample], config: Config) -> Report {
            var report = Report()
            var moving: [FlowSample] = []
            moving.reserveCapacity(samples.count)
            for s in samples {
                let length = simd_length(s.u)
                guard length.isFinite, s.p.x.isFinite, s.p.y.isFinite else { continue }
                report.totalCount += 1
                if length >= config.minFlow {
                    moving.append(s)
                } else {
                    report.staticCount += 1
                }
            }
            report.movingCount = moving.count
            report.medianMovingFlow = Stats.median(moving.map { simd_length($0.u) }) ?? .nan
            guard report.totalCount >= config.minInliers else {
                report.failure = .tooFewVectors
                return report
            }
            guard moving.count >= max(2, config.minInliers) else {
                report.failure = .staticScene
                return report
            }

            let lines = moving.map { unitLine($0) }
            var rng = SeededGenerator(seed: config.seed)
            var bestCount = 0
            var bestDirection: SIMD3<Double>?
            for _ in 0..<config.iterations {
                let i = Int.random(in: 0..<moving.count, using: &rng)
                var j = Int.random(in: 0..<(moving.count - 1), using: &rng)
                if j >= i { j += 1 }
                var t = simd_cross(lines[i], lines[j])
                let norm = simd_length(t)
                guard norm > 1e-9 else { continue }
                t /= norm
                let vote = consensus(t, moving, config)
                if vote.flip { t = -t }
                if vote.count > bestCount {
                    bestCount = vote.count
                    bestDirection = t
                }
            }
            guard var direction = bestDirection, bestCount >= 2 else {
                report.failure = .degenerate
                return report
            }

            // Reweighted least squares on the inliers. Dividing l · T by |w| makes each residual the
            // flow component perpendicular to the predicted direction, which has the same noise
            // everywhere; left unweighted, points far from the FOE would count for more.
            var inliers = inlierIndices(direction, moving, config)
            for _ in 0..<config.refinementPasses {
                guard inliers.count >= 2 else { break }
                var normal = simd_double3x3()
                for index in inliers {
                    let s = moving[index]
                    let weight = 1 / max(simd_length(predicted(direction, at: s.p)), config.weightFloor)
                    let a = rawLine(s) * weight
                    normal = normal + simd_double3x3(columns: (a * a.x, a * a.y, a * a.z))
                }
                var refined = Eigen.smallestEigenvector(ofSymmetric: normal)
                guard simd_length(refined) > 0.5 else { break }
                if simd_dot(refined, direction) < 0 { refined = -refined }
                direction = simd_normalize(refined)
                inliers = inlierIndices(direction, moving, config)
            }

            report.inlierCount = inliers.count
            report.medianInlierFlow = Stats.median(inliers.map { simd_length(moving[$0].u) }) ?? .nan
            if !inliers.isEmpty {
                var squares = 0.0
                for index in inliers {
                    let r = perpendicular(direction, moving[index])
                    squares += r * r
                }
                report.rmsResidual = (squares / Double(inliers.count)).squareRoot()
            }
            guard inliers.count >= config.minInliers,
                  Double(inliers.count) >= config.minInlierFraction * Double(moving.count) else {
                report.failure = .noConsensus
                return report
            }
            report.direction = direction
            return report
        }

        /// The flow line through p along u, homogeneous and unnormalised.
        static func rawLine(_ s: FlowSample) -> SIMD3<Double> {
            SIMD3<Double>(-s.u.y, s.u.x, s.p.x * s.u.y - s.p.y * s.u.x)
        }

        static func unitLine(_ s: FlowSample) -> SIMD3<Double> {
            let line = rawLine(s)
            let norm = simd_length(line)
            return norm > 0 ? line / norm : line
        }

        /// The direction translation along `t` moves a point seen at p, up to a positive 1/depth.
        static func predicted(_ t: SIMD3<Double>, at p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2<Double>(t.z * p.x - t.x, t.z * p.y - t.y)
        }

        /// The part of the sample's flow perpendicular to what `t` predicts.
        static func perpendicular(_ t: SIMD3<Double>, _ s: FlowSample) -> Double {
            let w = predicted(t, at: s.p)
            let length = simd_length(w)
            guard length > 1e-12 else { return simd_length(s.u) }
            let dir = w / length
            return abs(s.u.x * dir.y - s.u.y * dir.x)
        }

        /// How many samples agree with `t` either way round, and whether the reverse sign won.
        static func consensus(_ t: SIMD3<Double>, _ samples: [FlowSample],
                              _ config: Config) -> (count: Int, flip: Bool) {
            var forward = 0
            var backward = 0
            for s in samples {
                let w = predicted(t, at: s.p)
                let length = simd_length(w)
                guard length > 1e-12 else { continue }
                let dir = w / length
                let perp = abs(s.u.x * dir.y - s.u.y * dir.x)
                guard perp <= config.inlierAbsolute + config.inlierRelative * simd_length(s.u) else { continue }
                if simd_dot(s.u, dir) > 0 {
                    forward += 1
                } else {
                    backward += 1
                }
            }
            return backward > forward ? (backward, true) : (forward, false)
        }

        /// Samples that agree with `t`, the right way round.
        static func inlierIndices(_ t: SIMD3<Double>, _ samples: [FlowSample], _ config: Config) -> [Int] {
            var out: [Int] = []
            for (index, s) in samples.enumerated() {
                let w = predicted(t, at: s.p)
                let length = simd_length(w)
                guard length > 1e-12 else { continue }
                let dir = w / length
                guard simd_dot(s.u, dir) > 0 else { continue }
                let perp = abs(s.u.x * dir.y - s.u.y * dir.x)
                if perp <= config.inlierAbsolute + config.inlierRelative * simd_length(s.u) {
                    out.append(index)
                }
            }
            return out
        }

        enum Eigen {
            /// Unit eigenvector of the smallest eigenvalue of a symmetric 3×3, by cyclic Jacobi.
            static func smallestEigenvector(ofSymmetric m: simd_double3x3) -> SIMD3<Double> {
                var a: [[Double]] = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
                for row in 0..<3 {
                    for col in 0..<3 {
                        a[row][col] = m[col][row]
                    }
                }
                var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
                for _ in 0..<50 {
                    let off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2]
                    if off < 1e-30 { break }
                    for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                        let apq = a[p][q]
                        guard abs(apq) > 1e-300 else { continue }
                        let theta = (a[q][q] - a[p][p]) / (2 * apq)
                        let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                        let c = 1 / (t * t + 1).squareRoot()
                        let s = t * c
                        // A ← Jᵀ A J and V ← V J, with J the identity except J[p][p] = J[q][q] = c,
                        // J[p][q] = s, J[q][p] = −s. That choice of t zeroes A[p][q].
                        for k in 0..<3 {
                            let akp = a[k][p]
                            let akq = a[k][q]
                            a[k][p] = c * akp - s * akq
                            a[k][q] = s * akp + c * akq
                        }
                        for k in 0..<3 {
                            let apk = a[p][k]
                            let aqk = a[q][k]
                            a[p][k] = c * apk - s * aqk
                            a[q][k] = s * apk + c * aqk
                        }
                        for k in 0..<3 {
                            let vkp = v[k][p]
                            let vkq = v[k][q]
                            v[k][p] = c * vkp - s * vkq
                            v[k][q] = s * vkp + c * vkq
                        }
                    }
                }
                var smallest = 0
                for i in 1..<3 where a[i][i] < a[smallest][smallest] {
                    smallest = i
                }
                return SIMD3<Double>(v[0][smallest], v[1][smallest], v[2][smallest])
            }
        }
    }

    // MARK: - World azimuth and offset

    /// The FOE carried into the ARKit world and compared with the GPS track.
    struct WorldEstimate {
        /// Steeper than this is not a direction of travel for a car or an aircraft.
        static let maxElevationDeg = 25.0

        var report: FOESolver.Report
        var failure: Failure?
        var foeAzimuthDeg = Double.nan
        var foeElevationDeg = Double.nan
        /// Azimuth of the camera boresight — `rawAzimuthDeg` for this frame.
        var cameraAzimuthDeg = Double.nan
        /// FOE azimuth minus boresight azimuth: 0 pointing forward, +90 when travel is to the
        /// camera's right (phone out of a left-hand window), −90 out of a right-hand window.
        var foeRelCamDeg = Double.nan
        /// `signedDelta(foeAz, track)` — the StartupSeed convention.
        var offsetDeg = Double.nan

        /// `rawAzimuthDeg`'s formula in ARTrafficViewController.updateWorldYawError, kept
        /// identical so the two are comparable: world −z is 0°, +x is 90°, and a direction within
        /// 0.2 of vertical has no azimuth.
        static func azimuthDeg(ofWorldDirection d: SIMD3<Double>) -> Double? {
            let horizontal = (d.x * d.x + d.z * d.z).squareRoot()
            guard horizontal > 0.2 * simd_length(d) else { return nil }
            return atan2(d.x, -d.z) * 180 / .pi
        }

        /// `cameraToWorld` is the rotation part of frame 1's `camera.transform`.
        static func make(samples: [FlowSample], cameraToWorld: simd_double3x3,
                         trackDeg: Double, config: FOESolver.Config) -> WorldEstimate {
            let report = FOESolver.solve(samples, config: config)
            var estimate = WorldEstimate(report: report, failure: report.failure)
            let boresight = cameraToWorld * SIMD3<Double>(0, 0, -1)
            estimate.cameraAzimuthDeg = azimuthDeg(ofWorldDirection: boresight) ?? .nan
            guard let direction = report.direction else { return estimate }

            let world = cameraToWorld * Frames.arCameraDirection(fromCV: direction)
            let horizontal = (world.x * world.x + world.z * world.z).squareRoot()
            estimate.foeElevationDeg = atan2(world.y, horizontal) * 180 / .pi
            guard abs(estimate.foeElevationDeg) <= maxElevationDeg,
                  let foeAzimuth = azimuthDeg(ofWorldDirection: world),
                  trackDeg.isFinite else {
                estimate.failure = .steepDirection
                return estimate
            }
            estimate.foeAzimuthDeg = foeAzimuth
            if estimate.cameraAzimuthDeg.isFinite {
                estimate.foeRelCamDeg = AngularResponse.signedDelta(estimate.cameraAzimuthDeg, foeAzimuth)
            }
            estimate.offsetDeg = AngularResponse.signedDelta(foeAzimuth, trackDeg)
            return estimate
        }
    }

    // MARK: - When it runs

    enum Gate {
        /// Low enough for a car test; the flight anchor's 80 kt would rule that out.
        static let minSpeedKt = 15.0
        static let maxCourseAccuracyDeg = 5.0

        /// Why the gate is shut. The raw value is the `camera_seed_none` reason.
        enum Closed: String {
            case speed = "gate_speed"
            case course = "gate_course"
            case courseAccuracy = "gate_course_acc"
            case thermal = "gate_thermal"
            case tracking = "gate_tracking"
        }

        static func closed(speedKt: Double, courseDeg: Double, courseAccuracyDeg: Double,
                           thermalOK: Bool) -> Closed? {
            guard speedKt.isFinite, speedKt >= minSpeedKt else { return .speed }
            guard courseDeg.isFinite, courseDeg >= 0 else { return .course }
            guard courseAccuracyDeg.isFinite, courseAccuracyDeg >= 0,
                  courseAccuracyDeg <= maxCourseAccuracyDeg else { return .courseAccuracy }
            guard thermalOK else { return .thermal }
            return nil
        }
    }

    /// At most one capture per interval, and a fixed budget of captures in all. The budget is only
    /// spent by frames actually taken, so a phone in a pocket or a car parked does not use it up.
    struct CaptureSchedule {
        let interval: TimeInterval
        let maxCaptures: Int
        private(set) var capturesTaken = 0
        private var lastCheck: TimeInterval?

        /// 240 × 0.25 s: the issue's "roughly the first 60 s", at four frames a second.
        init(interval: TimeInterval = 0.25, maxCaptures: Int = 240) {
            self.interval = interval
            self.maxCaptures = maxCaptures
        }

        var hasStarted: Bool { capturesTaken > 0 }
        var isExhausted: Bool { capturesTaken >= maxCaptures }

        /// True at most once per interval. A clock that runs backwards restarts the throttle.
        mutating func isDue(at time: TimeInterval) -> Bool {
            if let last = lastCheck, time >= last, time - last < interval { return false }
            lastCheck = time
            return true
        }

        mutating func recordCapture() {
            capturesTaken += 1
        }
    }

    /// Which earlier frame to pair a new one with. A quarter second normally; half a second when
    /// the flow is small, as over the ground from altitude (about 1°/s), where a longer baseline
    /// doubles the signal against the same tracking noise.
    struct PairPlanner {
        static let shortGap: TimeInterval = 0.25
        static let longGap: TimeInterval = 0.5
        static let minGap: TimeInterval = 0.15
        static let maxGap: TimeInterval = 0.65
        static let lengthenBelowPx = 2.5
        static let shortenAbovePx = 6.0

        private(set) var targetGap: TimeInterval = PairPlanner.shortGap

        /// Index into `earlier` of the frame to pair with one taken at `time`, or nil.
        func partner(for time: TimeInterval, among earlier: [TimeInterval]) -> Int? {
            var best: Int?
            var bestError = Double.infinity
            for (index, t) in earlier.enumerated() {
                let gap = time - t
                guard gap >= PairPlanner.minGap, gap <= PairPlanner.maxGap else { continue }
                let error = abs(gap - targetGap)
                if error < bestError {
                    bestError = error
                    best = index
                }
            }
            return best
        }

        /// Feed the median moving flow of the last pair, in working-image pixels.
        mutating func update(medianFlowPx: Double) {
            guard medianFlowPx.isFinite else { return }
            if medianFlowPx < PairPlanner.lengthenBelowPx {
                targetGap = PairPlanner.longGap
            } else if medianFlowPx > PairPlanner.shortenAbovePx {
                targetGap = PairPlanner.shortGap
            }
        }
    }

    /// Keeps `camera_seed_none` from flooding the 10,000-row recorder ring. A new reason is logged
    /// once `minInterval` has passed; the same reason again only after `repeatInterval` (never, if
    /// nil); and never more than `maxEvents` in all. What it holds back is counted and reported
    /// with the next line that does get through.
    struct EventLimiter {
        let minInterval: TimeInterval
        let repeatInterval: TimeInterval?
        let maxEvents: Int
        private(set) var emitted = 0
        private var lastReason: String?
        private var lastTime: TimeInterval?
        private var held = 0

        init(minInterval: TimeInterval, repeatInterval: TimeInterval?, maxEvents: Int) {
            self.minInterval = minInterval
            self.repeatInterval = repeatInterval
            self.maxEvents = maxEvents
        }

        /// Nil to stay quiet; otherwise how many occurrences were held back since the last line.
        mutating func admit(_ reason: String, at time: TimeInterval) -> Int? {
            guard emitted < maxEvents else {
                held += 1
                return nil
            }
            if let lastTime {
                let elapsed = time - lastTime
                let due: Bool
                if elapsed < 0 {
                    due = true
                } else if reason != lastReason {
                    due = elapsed >= minInterval
                } else if let repeatInterval {
                    due = elapsed >= repeatInterval
                } else {
                    due = false
                }
                guard due else {
                    held += 1
                    return nil
                }
            }
            let count = held
            held = 0
            lastReason = reason
            lastTime = time
            emitted += 1
            return count
        }

        /// The condition last logged has cleared, so its next occurrence counts as new.
        mutating func clearReason() {
            lastReason = nil
        }
    }

    // MARK: - Statistics

    enum Stats {
        /// Linear-interpolated quantile of an already sorted array.
        static func quantile(sorted values: [Double], _ q: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let position = max(0, min(1, q)) * Double(values.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, values.count - 1)
            let fraction = position - Double(lower)
            return values[lower] + (values[upper] - values[lower]) * fraction
        }

        static func median(_ values: [Double]) -> Double? {
            quantile(sorted: values.sorted(), 0.5)
        }

        /// Median and interquartile range of angles, unwrapped about the first so a spread that
        /// straddles ±180° is not read as 360° wide. The median is wrapped back to −180…180.
        static func angularMedianAndIQR(_ degrees: [Double]) -> (median: Double, iqr: Double)? {
            guard let first = degrees.first else { return nil }
            let unwrapped = degrees.map { first + AngularResponse.signedDelta(first, $0) }.sorted()
            guard let median = quantile(sorted: unwrapped, 0.5),
                  let q1 = quantile(sorted: unwrapped, 0.25),
                  let q3 = quantile(sorted: unwrapped, 0.75) else { return nil }
            return (AngularResponse.signedDelta(0, median), q3 - q1)
        }
    }
}

// MARK: - Live wiring

/// Feeds `CameraSeed` from the live session. **Shadow mode:** it reads frames, device motion and
/// the plain values it is handed, holds no reference to the view controller, and writes nothing but
/// flight-recorder events.
///
/// Threads. `offer` runs on the SceneKit render thread and does only the gate, the throttle and the
/// luma reduction there — the ARFrame is never kept past the call. `ingest` runs on the device-
/// motion queue. Everything else runs on a private utility queue. State shared between them is
/// behind one lock; state the worker alone touches is not.
final class CameraSeedRunner {

    /// What the view controller hands over with each frame, copied by value.
    struct Inputs {
        var speedKt: Double
        var courseDeg: Double
        var courseAccuracyDeg: Double
        /// `appliedWorldYawOffsetDeg`: the offset in force, logged beside the camera's.
        var activeOffsetDeg: Double
        /// `worldYawSource`, so a row can say what the active offset came from.
        var yawSource: String
    }

    /// The luma plane is reduced to about this width before anything else touches it.
    private static let workingWidth = 480.0
    /// Processing waits this long, so device motion (20 Hz) has a sample after the newer frame.
    private static let processingDelay: TimeInterval = 0.12
    /// Captures waiting for the worker. Past this the render thread skips rather than queues.
    private static let maxInFlight = 2
    /// Earlier captures kept for pairing: enough to reach back half a second.
    private static let keptCaptures = 3

    private struct Working {
        let image: CameraSeed.GrayImage
        let pinhole: CameraSeed.Pinhole
    }

    private struct Capture {
        let generation: Int
        let timestamp: TimeInterval
        let image: CameraSeed.GrayImage
        let pinhole: CameraSeed.Pinhole
        let cameraToWorld: simd_double3x3
        let inputs: Inputs
        let isLast: Bool
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.tallyoh.cameraseed", qos: .utility)

    // Guarded by `lock`.
    private var running = false
    /// Bumped by every start and stop, so no pair ever spans a pause or a world reset.
    private var generation = 0
    private var schedule = CameraSeed.CaptureSchedule()
    private var attitudes = CameraSeed.AttitudeHistory()
    private var convention = CameraSeed.AttitudeConvention()
    private var gateLimiter = CameraSeed.EventLimiter(minInterval: 1.0, repeatInterval: nil, maxEvents: 50)
    private var inFlight = 0

    // Worker queue only.
    private var kept: [Capture] = []
    private var planner = CameraSeed.PairPlanner()
    private var pairLimiter = CameraSeed.EventLimiter(minInterval: 0.5, repeatInterval: 2.0, maxEvents: 200)
    private var offsets: [Double] = []
    private let trackerConfig = CameraSeed.Tracker.Config()

    // MARK: Lifecycle — main thread

    /// A session (re)started. Resumes capturing if any budget is left.
    func start() {
        lock.lock()
        generation += 1
        running = !schedule.isExhausted
        attitudes.removeAll()
        lock.unlock()
    }

    /// A session paused. Drops anything in flight.
    func stop() {
        lock.lock()
        generation += 1
        running = false
        lock.unlock()
    }

    // MARK: Device motion — motion queue

    func ingest(motion: CMDeviceMotion) {
        let r = motion.attitude.rotationMatrix
        let matrix = simd_double3x3(rows: [
            SIMD3<Double>(r.m11, r.m12, r.m13),
            SIMD3<Double>(r.m21, r.m22, r.m23),
            SIMD3<Double>(r.m31, r.m32, r.m33),
        ])
        let gravity = SIMD3<Double>(motion.gravity.x, motion.gravity.y, motion.gravity.z)
        let time = motion.timestamp
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        convention.observe(matrix: matrix, gravity: gravity)
        attitudes.append(time: time, matrix: matrix)
    }

    // MARK: Frames — render thread

    func offer(session: ARSession, at time: TimeInterval, inputs: Inputs) {
        lock.lock()
        guard running, schedule.isDue(at: time) else {
            lock.unlock()
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        let closed = CameraSeed.Gate.closed(speedKt: inputs.speedKt,
                                            courseDeg: inputs.courseDeg,
                                            courseAccuracyDeg: inputs.courseAccuracyDeg,
                                            thermalOK: thermal != .serious && thermal != .critical)
        if let closed {
            // Silent until the first capture: before that a closed gate is simply the normal state
            // of a phone that is not moving.
            let held = schedule.hasStarted ? gateLimiter.admit(closed.rawValue, at: time) : nil
            lock.unlock()
            if let held { logGate(closed.rawValue, held: held, inputs: inputs) }
            return
        }
        guard inFlight < CameraSeedRunner.maxInFlight else {
            let held = gateLimiter.admit("busy", at: time)
            lock.unlock()
            if let held { logGate("busy", held: held, inputs: inputs) }
            return
        }
        let generationAtCapture = generation
        let startedBefore = schedule.hasStarted
        lock.unlock()

        guard let frame = session.currentFrame else { return }
        guard case .normal = frame.camera.trackingState else {
            if startedBefore { gateClosed(CameraSeed.Gate.Closed.tracking.rawValue, at: time, inputs: inputs) }
            return
        }
        guard let working = CameraSeedRunner.workingImage(of: frame) else {
            gateClosed("pixel_format", at: time, inputs: inputs)
            return
        }
        let timestamp = frame.timestamp
        let cameraToWorld = CameraSeed.Frames.rotation(of: frame.camera.transform)

        lock.lock()
        guard running, generation == generationAtCapture else {
            lock.unlock()
            return
        }
        let isFirst = !schedule.hasStarted
        schedule.recordCapture()
        let isLast = schedule.isExhausted
        if isLast { running = false }
        let budget = schedule.maxCaptures
        let interval = schedule.interval
        gateLimiter.clearReason()
        inFlight += 1
        lock.unlock()

        if isFirst {
            let detail = [
                "speed_kt=" + CameraSeedRunner.fmt(inputs.speedKt, 1),
                "course=" + CameraSeedRunner.fmt(inputs.courseDeg, 1),
                "course_acc=" + CameraSeedRunner.fmt(inputs.courseAccuracyDeg, 1),
                "budget=\(budget)",
                "interval_s=" + CameraSeedRunner.fmt(interval, 2),
                "work_px=\(working.image.width)x\(working.image.height)",
            ].joined(separator: " ")
            FlightRecorder.shared.record(event: "camera_seed_start", detail: detail)
        }

        let capture = Capture(generation: generationAtCapture, timestamp: timestamp,
                              image: working.image, pinhole: working.pinhole,
                              cameraToWorld: cameraToWorld, inputs: inputs, isLast: isLast)
        worker.asyncAfter(deadline: .now() + CameraSeedRunner.processingDelay) { [weak self] in
            self?.process(capture)
        }
    }

    /// Luma plane reduced to the working size, and the intrinsics to match.
    private static func workingImage(of frame: ARFrame) -> Working? {
        let buffer = frame.capturedImage
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let factor = max(1, Int((Double(width) / workingWidth).rounded()))
        guard let image = CameraSeed.GrayImage.downsampled(plane: UnsafeRawPointer(base),
                                                           width: width, height: height,
                                                           bytesPerRow: rowBytes,
                                                           factor: factor) else { return nil }
        // The intrinsics are stated for camera.imageResolution, which is the luma plane's size;
        // rescaled anyway in case a format ever makes them differ.
        let k = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        let sx = resolution.width > 0 ? Double(width) / Double(resolution.width) : 1
        let sy = resolution.height > 0 ? Double(height) / Double(resolution.height) : 1
        let full = CameraSeed.Pinhole(fx: Double(k[0][0]) * sx, fy: Double(k[1][1]) * sy,
                                      cx: Double(k[2][0]) * sx, cy: Double(k[2][1]) * sy)
        return Working(image: image, pinhole: full.downsampled(by: factor))
    }

    private func gateClosed(_ reason: String, at time: TimeInterval, inputs: Inputs) {
        lock.lock()
        let held = gateLimiter.admit(reason, at: time)
        lock.unlock()
        if let held { logGate(reason, held: held, inputs: inputs) }
    }

    private func logGate(_ reason: String, held: Int, inputs: Inputs) {
        let detail = [
            "reason=" + reason,
            "held=\(held)",
            "speed_kt=" + CameraSeedRunner.fmt(inputs.speedKt, 1),
            "course_acc=" + CameraSeedRunner.fmt(inputs.courseAccuracyDeg, 1),
        ].joined(separator: " ")
        FlightRecorder.shared.record(event: "camera_seed_none", detail: detail)
    }

    // MARK: Pairs — worker queue

    private func process(_ capture: Capture) {
        defer {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }
        lock.lock()
        let current = generation
        lock.unlock()

        if let newest = kept.last, newest.generation != capture.generation {
            kept.removeAll()
        }
        if capture.generation == current {
            let partnerIndex = planner.partner(for: capture.timestamp, among: kept.map { $0.timestamp })
            let partner = partnerIndex.map { kept[$0] }
            kept.append(capture)
            if kept.count > CameraSeedRunner.keptCaptures {
                kept.removeFirst(kept.count - CameraSeedRunner.keptCaptures)
            }
            if let partner { estimate(from: partner, to: capture) }
        }
        if capture.isLast { finish() }
    }

    private func estimate(from a: Capture, to b: Capture) {
        let gap = b.timestamp - a.timestamp
        lock.lock()
        let kind = convention.resolved
        let m1 = attitudes.matrix(at: a.timestamp)
        let m2 = attitudes.matrix(at: b.timestamp)
        let latestMotion = attitudes.latestTime
        lock.unlock()

        guard let kind else {
            none("attitude_convention", b, gap: gap)
            return
        }
        guard let m1, let m2 else {
            // Positive means motion is ahead of the frame. Hundreds of seconds either way would
            // mean the two clocks are not the same clock.
            let lead = latestMotion.map { ($0 - b.timestamp) * 1000 } ?? .nan
            none("attitude_gap", b, gap: gap, extra: "motion_lead_ms=" + CameraSeedRunner.fmt(lead, 0))
            return
        }

        // Relative rotation, frame 1 → frame 2, of a fixed direction: device coordinates, then CV.
        let a1 = kind.referenceToDeviceMatrix(m1)
        let a2 = kind.referenceToDeviceMatrix(m2)
        let rotation = CameraSeed.Frames.cvRotation(fromDeviceRotation: a2 * a1.transpose)
        // ARKit's own view of the same rotation, logged only. Agreement says the inertial chain —
        // convention, axes, timestamps — is right; disagreement is the first thing to look at.
        let arRotation = CameraSeed.Frames.cvRotation(
            fromARCameraRotation: b.cameraToWorld.transpose * a.cameraToWorld)
        let rotationIMU = CameraSeed.Frames.rotationAngleDeg(rotation)
        let rotationAR = CameraSeed.Frames.rotationAngleDeg(arRotation)
        let rotationError = CameraSeed.Frames.rotationAngleDeg(arRotation.transpose * rotation)

        let tracked = CameraSeed.Tracker.track(from: a.image, to: b.image, config: trackerConfig)
        let samples = CameraSeed.Derotation.samples(tracks: tracked.tracks, pinhole1: a.pinhole,
                                                    pinhole2: b.pinhole, rotation: rotation)
        let focal = a.pinhole.fx
        let result = CameraSeed.WorldEstimate.make(samples: samples, cameraToWorld: a.cameraToWorld,
                                                   trackDeg: b.inputs.courseDeg,
                                                   config: CameraSeed.FOESolver.Config(focalPx: focal))
        let report = result.report
        planner.update(medianFlowPx: report.movingCount >= 10 ? report.medianMovingFlow * focal : 0)

        let counts = [
            "features=\(tracked.featureCount)",
            "tracks=\(tracked.tracks.count)",
            "moving=\(report.movingCount)",
            "static=\(report.staticCount)",
            "inliers=\(report.inlierCount)",
        ].joined(separator: " ")
        let rotations = [
            "rot_imu_deg=" + CameraSeedRunner.fmt(rotationIMU, 2),
            "rot_ar_deg=" + CameraSeedRunner.fmt(rotationAR, 2),
            "rot_err_deg=" + CameraSeedRunner.fmt(rotationError, 2),
            "att=" + kind.rawValue,
        ].joined(separator: " ")

        if let failure = result.failure {
            let extra = [
                counts,
                "med_flow_px=" + CameraSeedRunner.fmt(report.medianMovingFlow * focal, 2),
                "foe_elev_deg=" + CameraSeedRunner.fmt(result.foeElevationDeg, 1),
                rotations,
            ].joined(separator: " ")
            none(failure.rawValue, b, gap: gap, extra: extra)
            return
        }

        offsets.append(result.offsetDeg)
        let active = b.inputs.activeOffsetDeg
        let difference = active.isFinite ? AngularResponse.signedDelta(active, result.offsetDeg) : .nan
        let inlierFlow = report.medianInlierFlow
        let degreesPerSecond = gap > 0 ? inlierFlow / gap * 180 / .pi : .nan
        let detail = [
            "offset=" + CameraSeedRunner.fmt(result.offsetDeg, 1),
            "active=" + CameraSeedRunner.fmt(active, 1),
            "diff=" + CameraSeedRunner.fmt(difference, 1),
            "yaw_src=" + b.inputs.yawSource,
            "foe_az=" + CameraSeedRunner.fmt(result.foeAzimuthDeg, 1),
            "cam_az=" + CameraSeedRunner.fmt(result.cameraAzimuthDeg, 1),
            "foe_rel_cam_deg=" + CameraSeedRunner.fmt(result.foeRelCamDeg, 1),
            "foe_elev_deg=" + CameraSeedRunner.fmt(result.foeElevationDeg, 1),
            counts,
            "med_flow_px=" + CameraSeedRunner.fmt(inlierFlow * focal, 2),
            "med_flow_dps=" + CameraSeedRunner.fmt(degreesPerSecond, 2),
            "resid_px=" + CameraSeedRunner.fmt(report.rmsResidual * focal, 2),
            "gap_ms=" + CameraSeedRunner.fmt(gap * 1000, 0),
            rotations,
            "speed_kt=" + CameraSeedRunner.fmt(b.inputs.speedKt, 1),
            "course=" + CameraSeedRunner.fmt(b.inputs.courseDeg, 1),
            "course_acc=" + CameraSeedRunner.fmt(b.inputs.courseAccuracyDeg, 1),
        ].joined(separator: " ")
        FlightRecorder.shared.record(event: "camera_seed", detail: detail)
    }

    private func none(_ reason: String, _ capture: Capture, gap: TimeInterval, extra: String = "") {
        guard let held = pairLimiter.admit(reason, at: capture.timestamp) else { return }
        var parts = [
            "reason=" + reason,
            "held=\(held)",
            "gap_ms=" + CameraSeedRunner.fmt(gap * 1000, 0),
        ]
        if !extra.isEmpty { parts.append(extra) }
        parts.append("speed_kt=" + CameraSeedRunner.fmt(capture.inputs.speedKt, 1))
        parts.append("course_acc=" + CameraSeedRunner.fmt(capture.inputs.courseAccuracyDeg, 1))
        FlightRecorder.shared.record(event: "camera_seed_none", detail: parts.joined(separator: " "))
    }

    /// The budget is spent: one summary line, then nothing more for the life of this runner.
    private func finish() {
        lock.lock()
        let captures = schedule.capturesTaken
        lock.unlock()
        let summary = CameraSeed.Stats.angularMedianAndIQR(offsets)
        let detail = [
            "reason=budget",
            "captures=\(captures)",
            "estimates=\(offsets.count)",
            "median_offset=" + CameraSeedRunner.fmt(summary?.median ?? .nan, 1),
            "iqr=" + CameraSeedRunner.fmt(summary?.iqr ?? .nan, 1),
        ].joined(separator: " ")
        FlightRecorder.shared.record(event: "camera_seed_end", detail: detail)
        kept.removeAll()
    }

    private static func fmt(_ value: Double, _ decimals: Int) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%.\(decimals)f", value)
    }
}
