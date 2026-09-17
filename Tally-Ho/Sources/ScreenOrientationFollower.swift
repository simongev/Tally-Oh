//
//  ScreenOrientationFollower.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Decides which way up the phone physically is, so the interface can follow it.
//

import Foundation
import CoreLocation
import UIKit

/// Decides which way up the phone physically is, from ARKit's gravity-referenced camera attitude,
/// so the interface can be asked to follow it.
///
/// iOS normally decides this itself, but it does so from a raw accelerometer heuristic and it
/// declines to act on the answer at all while the rotation lock is on. Neither is good enough
/// here. This app is used inside a vibrating, manoeuvring cabin — the worst case for the
/// accelerometer heuristic — and its whole promise is that the user lifts the phone and sees the
/// traffic, which cannot depend on a Control Center toggle. ARKit already maintains a
/// gravity-aligned world (`.gravityAndHeading`) to a far higher standard, so the orientation is
/// read off the AR frame instead and `requestGeometryUpdate` is used to rotate the interface,
/// which works regardless of the lock.
///
/// This is a pure state machine so the mapping, the hysteresis and the dwell are testable without
/// a device.
struct ScreenOrientationFollower {

    // MARK: - Reading the phone's roll off an AR frame

    /// The angle of world "up" within the camera image, in degrees, from a camera transform's
    /// first two columns. `nil` when the phone is too close to flat for the angle to mean
    /// anything.
    ///
    /// **Feed this `ARFrame.camera.transform`, never `ARSCNView.pointOfView.worldTransform`.**
    /// The two differ by exactly the interface rotation — which is the quantity being measured, so
    /// using the node makes the whole thing circular. Build 16 used the node and oscillated
    /// portrait/landscape once a second on a phone that never moved; the flight log showed the two
    /// frames differing by exactly 90.000° in portrait and exactly 0.000° in landscape-right,
    /// seventeen rows out of seventeen. The camera's own frame is fixed to the device and is the
    /// only non-circular source.
    ///
    /// The world's up axis is (0, 1, 0) under `.gravityAndHeading`, so the dot product of world up
    /// with a camera axis is simply that axis's `y` component — which is why this takes two
    /// scalars rather than two vectors.
    ///
    /// The flatness guard is the same idea as `updateHUDLadder`'s `horizLen > 0.05` horizon guard:
    /// pointed within about 11° of straight up or straight down, both components go to zero and
    /// the angle is pure noise. Rotating the interface on that noise would be worse than not
    /// rotating at all.
    static func imageRollDeg(cameraRightY: Double, cameraUpY: Double) -> Double? {
        let magnitude = (cameraRightY * cameraRightY + cameraUpY * cameraUpY).squareRoot()
        guard magnitude > 0.2 else { return nil }
        return atan2(cameraRightY, cameraUpY) * 180.0 / Double.pi
    }

    /// The roll each interface orientation corresponds to.
    ///
    /// Apple defines the ARKit camera frame geometrically: the x-axis "points along the long axis
    /// of the device, from the front-facing camera toward the Home button" — device *down* — and
    /// the frame is right-handed with +z out of the screen, which puts +y along the device's
    /// portrait *right*. So for a phone held upright in portrait, world up lies on camera −x and
    /// the angle is −90°.
    ///
    /// That prediction is what anchors the rest of the table, because it is checkable: the FL340
    /// log this work came from holds −90° for the 180 seconds the display looked right, then steps
    /// to −180° in a single sample at the moment the user reported the picture going sideways.
    /// A roll of −180° means the device's portrait-right edge is pointing at the ground, which
    /// puts its top edge — and the front camera — on the right: `landscapeLeft`.
    ///
    /// Derivation and log agree, but the mapping is still logged per sample (`img_roll_deg`
    /// against `ui_orient`) so a flight confirms it rather than it being taken on trust.
    static let idealRollDeg: [(orientation: UIInterfaceOrientation, rollDeg: Double)] = [
        (orientation: .landscapeRight,     rollDeg:   0),
        (orientation: .portrait,           rollDeg: -90),
        (orientation: .landscapeLeft,      rollDeg: 180),
        (orientation: .portraitUpsideDown, rollDeg:  90)
    ]

    /// Log-friendly name. `UIInterfaceOrientation` has no useful description of its own, and a raw
    /// integer in a flight log is a lookup the reader should not have to do.
    static func describe(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portraitDown"
        case .landscapeLeft:      return "landscapeLeft"
        case .landscapeRight:     return "landscapeRight"
        default:                  return "unknown"
        }
    }

    /// The CoreLocation device orientation matching an interface orientation.
    ///
    /// `CLLocationManager.headingOrientation` tells CoreLocation which physical axis of the device
    /// to report a heading for. Leave it at `.portrait` while the app renders in landscape and the
    /// compass comes back 90° out — measured on the ground at exactly −87° for twenty-five
    /// consecutive samples in landscape-right, against −2° in portrait either side of it.
    ///
    /// The two enumerations are crossed for landscape, and that is not a naming quirk to route
    /// around: `UIInterfaceOrientation.landscapeRight` is the *interface* rotated so the home
    /// button sits on the right, and CoreLocation names that same physical position
    /// `CLDeviceOrientation.landscapeLeft`. Both are defined by where the home button is, which is
    /// the one unambiguous anchor, so that is what this maps on.
    ///
    /// Checkable in the log rather than taken on trust: `world_yaw_corr_deg` is the gap between
    /// the compass and ARKit's azimuth, and it must stay near zero in landscape exactly as it does
    /// in portrait. A wrong mapping here would leave it at ±90 or put it at 180.
    static func headingOrientation(for orientation: UIInterfaceOrientation) -> CLDeviceOrientation {
        switch orientation {
        case .portrait:           return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft:      return .landscapeRight
        case .landscapeRight:     return .landscapeLeft
        default:                  return .portrait
        }
    }

    /// The orientation whose ideal roll is nearest, or `nil` if none is within `tolerance`.
    static func nearestOrientation(toRollDeg roll: Double, withinDeg tolerance: Double) -> UIInterfaceOrientation? {
        var best: UIInterfaceOrientation?
        var bestDelta = Double.greatestFiniteMagnitude
        for entry in idealRollDeg {
            let delta = abs(AngularResponse.signedDelta(entry.rollDeg, roll))
            if delta < bestDelta {
                bestDelta = delta
                best = entry.orientation
            }
        }
        return bestDelta <= tolerance ? best : nil
    }

    // MARK: - Configuration

    /// How close to an orientation's ideal roll the phone must be before that orientation is even
    /// a candidate. 30° leaves a 60° dead band between neighbours, so a phone held at 45° — the
    /// genuinely ambiguous case — stays where it is instead of flip-flopping.
    let toleranceDeg: Double
    /// How long the phone must hold a new orientation before the interface follows. Long enough
    /// that turbulence, or a hand passing through landscape on the way somewhere else, is ignored.
    let dwellSeconds: TimeInterval
    /// The orientations the app declares. A physical orientation outside the set is held, not
    /// chased: `requestGeometryUpdate` refuses an undeclared orientation, and repeatedly asking
    /// for one would look from the outside exactly like the bug this exists to fix.
    let supported: [UIInterfaceOrientation]
    /// How many changes may happen inside `changeWindowSeconds` before following gives up.
    ///
    /// A screen flipping in the pilot's hand is far worse than a screen that fails to rotate, and
    /// this feature has now produced that failure once. The cutoff exists so it cannot run for a
    /// whole flight again whatever is wrong upstream: it does not need to know *why* the decisions
    /// are oscillating, only that they are. Four changes in twenty seconds is well above anything
    /// a person does deliberately and far below the fifteen-in-twenty-two that build 16 produced.
    let maxChangesInWindow: Int
    let changeWindowSeconds: TimeInterval

    // MARK: - State

    private(set) var current: UIInterfaceOrientation
    private var pending: UIInterfaceOrientation?
    private var pendingSince: TimeInterval = 0
    private var changeTimes: [TimeInterval] = []
    /// Why following stopped, or nil while it is still running.
    private(set) var disabledReason: String?
    var isFollowing: Bool { disabledReason == nil }

    init(current: UIInterfaceOrientation = .portrait,
         toleranceDeg: Double = 30,
         dwellSeconds: TimeInterval = 0.5,
         supported: [UIInterfaceOrientation] = [.portrait, .landscapeLeft, .landscapeRight],
         maxChangesInWindow: Int = 4,
         changeWindowSeconds: TimeInterval = 20) {
        self.current = current
        self.toleranceDeg = toleranceDeg
        self.dwellSeconds = dwellSeconds
        self.supported = supported
        self.maxChangesInWindow = maxChangesInWindow
        self.changeWindowSeconds = changeWindowSeconds
    }

    /// Adopt an orientation the interface reached without being asked — a normal iOS rotation with
    /// the lock off. Keeps the follower from fighting a change it would have made anyway.
    mutating func sync(to orientation: UIInterfaceOrientation) {
        guard orientation != current, orientation != .unknown else { return }
        current = orientation
        pending = nil
    }

    /// Feed one reading. Returns the new orientation on the tick it changes, `nil` otherwise —
    /// so the caller issues a geometry request only on an actual transition.
    mutating func update(imageRollDeg roll: Double?, at time: TimeInterval) -> UIInterfaceOrientation? {
        guard isFollowing else { return nil }

        // Too flat to mean anything: hold, and make the next candidate earn its dwell afresh
        // rather than resuming a half-served one from before the phone went level.
        guard let roll,
              let candidate = Self.nearestOrientation(toRollDeg: roll, withinDeg: toleranceDeg),
              candidate != current,
              supported.contains(candidate)
        else {
            pending = nil
            return nil
        }

        guard pending == candidate else {
            pending = candidate
            pendingSince = time
            return nil
        }
        guard time - pendingSince >= dwellSeconds else { return nil }

        // Count the change before making it, so the one that would tip the rate over the limit is
        // refused rather than performed and then regretted.
        changeTimes.removeAll { time - $0 > changeWindowSeconds }
        changeTimes.append(time)
        if changeTimes.count > maxChangesInWindow {
            disabledReason = "thrash"
            pending = nil
            return nil
        }

        current = candidate
        pending = nil
        return candidate
    }
}
