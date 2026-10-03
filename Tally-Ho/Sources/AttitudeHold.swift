//
//  AttitudeHold.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The camera's whole attitude from CoreMotion in the air (issue #12).
//
//  The yaw hold (#10, #11) put the heading on `cmYaw + K` and left pitch and roll to ARKit. On
//  build 393 (log 63b15922) the phone sat steady from 17:19 to 17:23 — CoreMotion's yaw −88.6 to
//  −89.0, held heading about 4° — while ARKit's `cam_pitch` climbed from about 4–8° to 20.6–27.5°
//  and `cam_roll` went −112° → −84.5°. The world tilted with it. ARKit levels its world from the
//  accelerometer at the start, and in a cabin that pitches and banks under a camera that sees only
//  the cabin, the level it keeps does not stay level.
//
//  In the air, with the yaw hold active, the camera's true attitude is built from CoreMotion — its
//  gravity-aligned attitude, with the yaw put on `cmYaw + K` — and every target is placed through
//  `R_ar · R_true⁻¹` about the camera, so where it lands on screen depends on `R_true` alone.
//
//  Everything here is pure (Foundation and simd), so the tests reach all of it.
//

import Foundation
import simd

enum AttitudeHold {

    // MARK: - Frames

    /// CoreMotion device axes (portrait: x right, y toward the top, z out of the screen) into ARKit
    /// camera axes. ARKit states its camera frame against the sensor's native landscape orientation:
    /// x along the long axis toward the home-button end (device −y), y the device's portrait right
    /// (device +x), z out of the screen (device +z).
    ///
    /// The camera seed's definition, deliberately the same object (`CameraSeed.Frames`), and that is
    /// where it has been checked against a device: the seed logs `rot_err_deg`, the angle between the
    /// phone's rotation over a frame pair from CoreMotion through this mapping and ARKit's own
    /// rotation over the same pair. Across the flight logs on file, the eleven pairs that turned more
    /// than 10° agree to a median 0.8° (worst 5.1°): 40.1° against ARKit's 40.3° to 1.8°, 28.1° against
    /// 28.1° to 0.5°. A wrong mapping turns about the wrong axis and misses by tens of degrees on
    /// those pairs. Relative rotations pin the axes; `Check` below pins the absolute level on the phone.
    static var deviceToARCamera: simd_double3x3 { CameraSeed.Frames.deviceToARCamera }

    /// CoreMotion's Z-vertical reference frame into the world frame placement and ARKit use: y up,
    /// azimuth clockwise from above starting at −z. Reference x lands on azimuth 0 and reference y on
    /// azimuth −90, which is exactly `GyroYawHold.cameraAzimuthDeg`'s convention (`atan2(−y, x)`), so a
    /// camera whose CoreMotion yaw is `cmYaw` points at azimuth `cmYaw` in this frame.
    static let referenceToWorld = simd_double3x3(columns: (
        SIMD3<Double>(0, 0, -1),
        SIMD3<Double>(-1, 0, 0),
        SIMD3<Double>(0, 1, 0)
    ))

    /// `CMAttitude.rotationMatrix` as the matrix that takes device vectors into the reference frame.
    ///
    /// Apple does not say which way the matrix maps, so gravity decides, exactly as
    /// `GyroYawHold.cameraAzimuthDeg` decides it: reference z is up, and only one reading puts it on
    /// the measured up. Nil when neither reading lands within about 25° of it.
    static func deviceToReference(_ m: GyroYawHold.Rotation, gravity: SIMD3<Double>) -> simd_double3x3? {
        let norm = simd_length(gravity)
        guard norm.isFinite, norm > 0.1 else { return nil }
        let up = -gravity / norm
        let zIfColumns = m.m13 * up.x + m.m23 * up.y + m.m33 * up.z
        let zIfRows    = m.m31 * up.x + m.m32 * up.y + m.m33 * up.z
        guard max(zIfColumns, zIfRows) > 0.9 else { return nil }
        let matrix = simd_double3x3(rows: [
            SIMD3<Double>(m.m11, m.m12, m.m13),
            SIMD3<Double>(m.m21, m.m22, m.m23),
            SIMD3<Double>(m.m31, m.m32, m.m33),
        ])
        // Reference axes as columns: the matrix takes reference vectors into device ones.
        return zIfColumns >= zIfRows ? matrix.transpose : matrix
    }

    /// The rotation about world up that subtracts `deg` from every azimuth.
    static func yawRotation(subtractingDeg deg: Double) -> simd_double3x3 {
        let r = deg * .pi / 180
        let c = cos(r), s = sin(r)
        return simd_double3x3(columns: (
            SIMD3<Double>(c, 0, -s),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(s, 0, c)
        ))
    }

    /// Azimuth of a world direction, clockwise from above from −z, as `rawAzimuthDeg` computes it.
    /// Nil within about 12° of vertical.
    static func azimuthDeg(_ v: SIMD3<Double>) -> Double? {
        guard (v.x * v.x + v.z * v.z).squareRoot() > 0.2 * simd_length(v) else { return nil }
        return atan2(v.x, -v.z) * 180 / .pi
    }

    // MARK: - The true attitude and the correction

    /// The camera's true attitude, camera → world, expressed in ARKit's world as placement sees it.
    ///
    /// `CoreMotion (device → reference) → ARKit camera axes`, carried into the y-up world by
    /// `referenceToWorld` — where its azimuth is `cmYaw` — then turned so the azimuth is `cmYaw + K`
    /// (true), less the placement's own yaw offset, which placement subtracts from every bearing:
    ///
    ///     R_true = R_y(offset − K) · referenceToWorld · A · deviceToARCamera⁻¹
    ///
    /// A target at true bearing B is placed at azimuth `B − offset`; seen from a camera with this
    /// attitude it sits where a camera with azimuth `cmYaw + K` would see bearing B. The offset
    /// cancels, so the screen does not depend on it.
    static func trueCameraToWorld(deviceToReference a: simd_double3x3,
                                  anchorConstantDeg k: Double,
                                  placementOffsetDeg offset: Double) -> simd_double3x3 {
        yawRotation(subtractingDeg: offset - k) * referenceToWorld * a * deviceToARCamera.transpose
    }

    /// The rotation about the camera that every placed position goes through: `R_ar · R_true⁻¹`.
    /// Rendered by ARKit's camera, a direction `v` placed as `C · v` appears exactly where `R_true`
    /// would show `v`, since `R_ar⁻¹ · C = R_true⁻¹`.
    static func correction(arCameraToWorld r: simd_double3x3,
                           trueCameraToWorld t: simd_double3x3) -> simd_double3x3 {
        r * t.transpose
    }

    /// `p` turned by `rotation` about `cam`; `p` itself without one — the yaw-only placement, which
    /// is the ground's, and the air's whenever the attitude hold is off.
    static func placed(_ p: SIMD3<Float>, about cam: SIMD3<Float>, rotation: simd_float3x3?) -> SIMD3<Float> {
        guard let rotation else { return p }
        return cam + rotation * (p - cam)
    }

    static func float(_ m: simd_double3x3) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(Float(m.columns.0.x), Float(m.columns.0.y), Float(m.columns.0.z)),
            SIMD3<Float>(Float(m.columns.1.x), Float(m.columns.1.y), Float(m.columns.1.z)),
            SIMD3<Float>(Float(m.columns.2.x), Float(m.columns.2.y), Float(m.columns.2.z))
        ))
    }

    // MARK: - Pitch, roll and their disagreement

    /// How far two attitudes disagree about which way is up, seen from the camera: the angle between
    /// world up in one camera frame and in the other. Pitch and roll together; yaw cannot enter it.
    static func tiltDiscrepancyDeg(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
        let up = SIMD3<Double>(0, 1, 0)
        let ua = a.transpose * up, ub = b.transpose * up
        return atan2(simd_length(simd_cross(ua, ub)), simd_dot(ua, ub)) * 180 / .pi
    }

    /// Elevation of the line of sight (camera −z) above the horizon.
    static func pitchDeg(_ cameraToWorld: simd_double3x3) -> Double {
        let forward = -cameraToWorld.columns.2
        return asin(max(-1, min(1, forward.y / simd_length(forward)))) * 180 / .pi
    }

    /// The picture's roll, as `img_roll_deg` measures it: −90 for a phone upright in portrait, 0 in
    /// landscape-right. Nil within about 11° of looking straight up or down.
    static func rollDeg(_ cameraToWorld: simd_double3x3) -> Double? {
        ScreenOrientationFollower.imageRollDeg(cameraRightY: cameraToWorld.columns.0.y,
                                               cameraUpY: cameraToWorld.columns.1.y)
    }

    // MARK: - Attitude at a frame's timestamp

    /// CoreMotion's attitude (device → reference) at `time`, slerped between the samples either side —
    /// the attitude counterpart of `GyroYawHold.interpolatedYawDeg`, with the same bounds. Past the
    /// newest sample it extrapolates at the last pair's rotation rate, at most
    /// `maxExtrapolationSeconds`; before the oldest it holds the oldest within the same bound. Nil
    /// further out either way. `samples` must be in time order.
    static func interpolatedAttitude(_ samples: [(t: TimeInterval, q: simd_quatd)],
                                     at time: TimeInterval,
                                     maxExtrapolationSeconds: TimeInterval = 0.1) -> simd_quatd? {
        let usable = samples.filter { $0.t.isFinite }
        guard time.isFinite, let first = usable.first, let last = usable.last else { return nil }
        if time >= last.t {
            let ahead = time - last.t
            guard ahead <= maxExtrapolationSeconds else { return nil }
            guard usable.count >= 2, ahead > 0 else { return last.q }
            let previous = usable[usable.count - 2]
            let span = last.t - previous.t
            guard span > 0 else { return last.q }
            // The rotation from the previous sample to the newest, in the reference frame, the short way.
            var step = last.q * previous.q.inverse
            if step.real < 0 { step = simd_quatd(real: -step.real, imag: -step.imag) }
            let angle = step.angle
            guard angle > 1e-12 else { return last.q }
            let partial = simd_quatd(angle: angle * ahead / span, axis: step.axis)
            return simd_normalize(partial * last.q)
        }
        if time <= first.t {
            return first.t - time <= maxExtrapolationSeconds ? first.q : nil
        }
        for i in 1..<usable.count where usable[i].t >= time {
            let a = usable[i - 1], b = usable[i]
            let span = b.t - a.t
            guard span > 0 else { return b.q }
            return simd_slerp(a.q, b.q, (time - a.t) / span)
        }
        return last.q
    }

    // MARK: - GPS bank (shadow)

    static let standardGravity = 9.80665

    /// The bank a coordinated turn at this ground speed and turn rate needs: `atan(v · ω / g)`.
    /// Positive turning right. NaN for a non-finite input.
    static func gpsBankDeg(groundSpeedKt: Double, turnRateDps: Double) -> Double {
        guard groundSpeedKt.isFinite, turnRateDps.isFinite else { return .nan }
        let speed = groundSpeedKt * 1852.0 / 3600.0
        let rate = turnRateDps * .pi / 180
        return atan(speed * rate / standardGravity) * 180 / .pi
    }

    /// The GPS course's rate of turn over the last few seconds of fixes.
    struct TurnRate {
        /// Fixes kept: the newest, and those up to this far behind it.
        let windowSeconds: TimeInterval
        /// The fixes must span at least this long to give a rate.
        let minSpanSeconds: TimeInterval
        /// A course worse than this is not a direction.
        let maxCourseAccuracyDeg: Double
        private var fixes: [(t: TimeInterval, courseDeg: Double)] = []

        init(windowSeconds: TimeInterval = 3, minSpanSeconds: TimeInterval = 1.5,
             maxCourseAccuracyDeg: Double = 5) {
            self.windowSeconds = windowSeconds
            self.minSpanSeconds = minSpanSeconds
            self.maxCourseAccuracyDeg = maxCourseAccuracyDeg
        }

        /// One fix. An unusable course clears the window rather than bridging across it.
        mutating func add(courseDeg: Double, courseAccuracyDeg: Double, at time: TimeInterval) {
            guard courseDeg.isFinite, courseDeg >= 0, courseAccuracyDeg.isFinite,
                  courseAccuracyDeg >= 0, courseAccuracyDeg <= maxCourseAccuracyDeg, time.isFinite else {
                fixes.removeAll()
                return
            }
            if let last = fixes.last, time <= last.t { return }
            fixes.append((t: time, courseDeg: courseDeg))
            fixes.removeAll { time - $0.t > windowSeconds }
        }

        /// Degrees per second, positive turning right; NaN without enough fixes.
        var rateDps: Double {
            guard let first = fixes.first, let last = fixes.last else { return .nan }
            let span = last.t - first.t
            guard span >= minSpanSeconds else { return .nan }
            return AngularResponse.signedDelta(first.courseDeg, last.courseDeg) / span
        }
    }

    // MARK: - Runtime check

    /// Whether the check may count a frame as level: in the air, not banked more than `maxBankDeg` by
    /// the GPS estimate (unknown counts as level — the check's own median is the guard); on the
    /// ground, standing still. A taxi turn at 20 kt and 30°/s tilts apparent gravity by 28°, which
    /// both ARKit and CoreMotion would partly follow, differently.
    static func levelForCheck(airborne: Bool, groundSpeedKt: Double, gpsBankDeg: Double,
                              maxBankDeg: Double = 5, maxGroundSpeedKt: Double = 3) -> Bool {
        if airborne { return !gpsBankDeg.isFinite || abs(gpsBankDeg) <= maxBankDeg }
        return groundSpeedKt.isFinite && groundSpeedKt <= maxGroundSpeedKt
    }

    /// The one check that can be made only on the phone: that `R_true` and ARKit agree about which way
    /// is up while ARKit's own level is fresh.
    ///
    /// ARKit levels each new world from gravity, so in the first seconds of steady normal tracking its
    /// pitch and roll are as good as they get. A mapping error in the chain above — a wrong axis, the
    /// matrix read the wrong way, a sign — shows there as tens of degrees, where the right chain shows
    /// noise. So: from frames in the first `maxSessionAgeSeconds` of a world, in normal tracking that
    /// has held `settleSeconds`, with the phone turning less than `maxRateDps` and level, one every
    /// `sampleIntervalSeconds`, until `minSamples` span `spanSeconds`. Their median within
    /// `maxDiscrepancyDeg` confirms the hold; beyond it disables it. Either is latched for the rest of
    /// the app's run — what is being checked is code, not the flight. A world that ages out first
    /// leaves the check pending for the next world, and the hold stays yaw-only until then.
    struct Check {
        enum State: String {
            case pending
            case confirmed
            case disabled
        }

        let maxDiscrepancyDeg: Double
        let settleSeconds: TimeInterval
        let spanSeconds: TimeInterval
        let minSamples: Int
        let sampleIntervalSeconds: TimeInterval
        let maxSessionAgeSeconds: TimeInterval
        let maxRateDps: Double

        private(set) var state: State = .pending
        /// Confirmed from a record of an earlier run on this build and device (`MappingConfirmation`)
        /// rather than by this run's frames.
        private(set) var confirmedFromRecord = false
        /// The median that decided it; NaN until then.
        private(set) var decidedMedianDeg: Double = .nan
        private(set) var decidedSampleCount = 0
        private var samples: [(t: TimeInterval, deg: Double)] = []
        private var normalSince: TimeInterval?

        init(maxDiscrepancyDeg: Double = 5, settleSeconds: TimeInterval = 0.5,
             spanSeconds: TimeInterval = 2, minSamples: Int = 15,
             sampleIntervalSeconds: TimeInterval = 0.1, maxSessionAgeSeconds: TimeInterval = 30,
             maxRateDps: Double = 15) {
            self.maxDiscrepancyDeg = maxDiscrepancyDeg
            self.settleSeconds = settleSeconds
            self.spanSeconds = spanSeconds
            self.minSamples = minSamples
            self.sampleIntervalSeconds = sampleIntervalSeconds
            self.maxSessionAgeSeconds = maxSessionAgeSeconds
            self.maxRateDps = maxRateDps
        }

        /// The state as the log writes it: `confirmed_before` when a record confirmed it.
        var logDescription: String { confirmedFromRecord ? "confirmed_before" : state.rawValue }

        /// An earlier run on this build and device confirmed the chain (`MappingConfirmation`): skip the
        /// check. Nothing this run's frames show can then disable the hold — which is the point, since
        /// a disagreement after a confirmed chain is the flight, not the code.
        mutating func confirmFromRecord() {
            guard state == .pending else { return }
            state = .confirmed
            confirmedFromRecord = true
            samples.removeAll()
        }

        /// A new world: frames from the last one were measured against a level that has gone.
        mutating func sessionStarted() {
            samples.removeAll()
            normalSince = nil
        }

        /// Feed one frame. Returns the state when this frame decided it, nil otherwise.
        mutating func add(discrepancyDeg: Double?, isNormal: Bool, secondsSinceStart: TimeInterval,
                          rateDps: Double, level: Bool, at time: TimeInterval) -> State? {
            guard state == .pending else { return nil }
            guard isNormal else {
                normalSince = nil
                return nil
            }
            let since = normalSince ?? time
            normalSince = since
            guard secondsSinceStart <= maxSessionAgeSeconds,
                  time - since >= settleSeconds,
                  let deg = discrepancyDeg, deg.isFinite,
                  rateDps.isFinite, abs(rateDps) <= maxRateDps,
                  level else { return nil }
            if let last = samples.last, time - last.t < sampleIntervalSeconds { return nil }
            samples.append((t: time, deg: deg))
            guard samples.count >= minSamples, let first = samples.first,
                  time - first.t >= spanSeconds else { return nil }
            let sorted = samples.map(\.deg).sorted()
            let mid = sorted.count / 2
            let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            decidedMedianDeg = median
            decidedSampleCount = sorted.count
            state = median <= maxDiscrepancyDeg ? .confirmed : .disabled
            samples.removeAll()
            return state
        }
    }

    /// A confirmed check, remembered for the build and device it was made on (#12, QA round 1).
    ///
    /// What the check verifies is code and the device's axis conventions, not the flight. So once a
    /// run confirms it, later runs of the same build on the same model of phone skip the check and
    /// use the hold at once — which covers the app opened while taxiing, where no world is ever fresh
    /// while stopped or level, and a world whose first seconds happen to be flown hard. A new build or
    /// another device model checks again. Only a confirmation is stored: a disable is never
    /// remembered, and never erases one that was.
    ///
    /// Kept in an internal `UserDefaults` key. It is not a setting, so it is not in
    /// `ARVisualizationSettings` or the settings table.
    struct MappingConfirmation {
        static let defaultsKey = "TallyOh.attitudeHold.mappingConfirmed"

        /// `CFBundleVersion`, which CI sets from the workflow run.
        let build: String
        /// The hardware model identifier (`utsname.machine`, e.g. `iPhone16,1`).
        let deviceModel: String

        /// What a stored confirmation must equal to cover this run.
        var identity: String { "build=\(build) model=\(deviceModel)" }

        /// Both parts known. Without them nothing is stored or trusted.
        var isUsable: Bool {
            !build.trimmingCharacters(in: .whitespaces).isEmpty
                && !deviceModel.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// Whether a stored value confirms this build on this device model.
        func isConfirmed(stored: String?) -> Bool {
            isUsable && stored == identity
        }

        /// What to store once the check has decided: this identity on a confirmation, nothing
        /// otherwise.
        func valueToStore(after state: Check.State) -> String? {
            state == .confirmed && isUsable ? identity : nil
        }

        func isConfirmed(in defaults: UserDefaults) -> Bool {
            isConfirmed(stored: defaults.string(forKey: MappingConfirmation.defaultsKey))
        }

        /// Store the confirmation, if `state` is one. Returns whether anything was written.
        @discardableResult
        func record(_ state: Check.State, in defaults: UserDefaults) -> Bool {
            guard let value = valueToStore(after: state) else { return false }
            defaults.set(value, forKey: MappingConfirmation.defaultsKey)
            return true
        }
    }

    /// Whether placement goes through the attitude correction this frame: the yaw hold is placing the
    /// scene (airborne, K, sign check intact, aligned) and the runtime check has confirmed the chain.
    /// Anything else — the ground above all — is the yaw-only placement, unchanged.
    static func isActive(airHoldActive: Bool, check: Check.State) -> Bool {
        airHoldActive && check == .confirmed
    }
}
