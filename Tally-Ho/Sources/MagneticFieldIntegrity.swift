//
//  MagneticFieldIntegrity.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Is the field the compass steers by the Earth's, or has something nearby bent it? (#21)
//
//  iOS's `headingAccuracy` cannot say: it reads 10–12.5° almost always, the compass card went green
//  on it, and on Gev's balcony near KTEB the ground seed still came out 5–10° off. A disturbance
//  from local iron — a railing, rebar, a car — adds its own field to the Earth's, and that changes
//  two things the World Magnetic Model knows independently of the phone: the total intensity |B|
//  and the dip of the field below the horizontal. CoreMotion's *calibrated* field has the phone's
//  own magnetisation removed, and gravity gives the vertical, so both can be measured and compared.
//
//  What it cannot catch, stated plainly: a disturbance lying horizontal and at right angles to the
//  field changes neither |B| nor the dip to first order, yet turns the heading by atan(δ/H). Real
//  iron rarely produces that geometry alone, but this is a filter for gross disturbances, not a
//  proof of a good compass. The ground correction's dispersion and response gates still stand.
//

import Foundation
import CoreMotion

enum MagneticFieldIntegrity {

    // MARK: - Thresholds

    /// Largest tolerated |B| − F, as a fraction of F.
    ///
    /// What an undisturbed reading can legitimately differ by:
    ///  - the model: WMM's global error budget for F is about 145 nT (1σ), 0.3% of the ~50 µT
    ///    found at mid-latitudes;
    ///  - the crust, which the model does not include: anomalies at the surface are typically a few
    ///    hundred nT, about 1%;
    ///  - the phone: CoreMotion's calibrated field still carries a residual offset of the order of
    ///    1 µT after calibration, about 2%, plus noise the one-second median removes.
    /// Together about 3%; 6% (3 µT near New York, where F is 50.8 µT) is twice that. A car or a
    /// steel railing at arm's length adds tens of µT, far outside it.
    static let maxIntensityErrorFraction: Double = 0.06

    /// Largest tolerated difference between measured and modelled dip, degrees.
    ///
    /// The model's inclination error is about 0.2° (1σ) and crustal anomalies a few tenths more;
    /// the phone's residual offset of ~1 µT at an unknown angle tilts a 50 µT field by up to ~1.1°,
    /// and gravity from CoreMotion is good to a fraction of a degree with the phone held. About
    /// 1.5° in all; 3° is twice that. A field tilted 3° has a disturbing component of ~2.7 µT in
    /// the vertical plane — at New York's 21 µT horizontal field, the same size that turns a heading
    /// by about 7° when it lies horizontal.
    static let maxDipErrorDeg: Double = 3.0

    /// The verdict is taken over this much recent data, so a single noisy sample cannot flip it.
    static let windowSeconds: TimeInterval = 1.0
    /// Fewest samples in the window for a verdict at all (the monitor runs at 10 Hz).
    static let minSamples = 5

    // MARK: - Measurement

    /// One measured sample: the calibrated field's strength and its dip below the horizontal.
    struct Reading: Equatable {
        var intensityUT: Double
        var dipDeg: Double
        var time: TimeInterval
    }

    /// Strength and dip of a calibrated field vector (µT) given gravity, both in the device frame.
    ///
    /// CoreMotion's gravity points toward the Earth, so the dip is the angle between the field and
    /// the horizontal plane, positive when the field points down — the same sign convention as the
    /// model's inclination. Nil for a degenerate input: no field, or no gravity to define down.
    static func reading(fieldUT field: SIMD3<Double>, gravity: SIMD3<Double>,
                        at time: TimeInterval) -> Reading? {
        let fieldNorm = (field * field).sum().squareRoot()
        let gravityNorm = (gravity * gravity).sum().squareRoot()
        guard fieldNorm.isFinite, gravityNorm.isFinite, fieldNorm > 1e-6, gravityNorm > 1e-6 else {
            return nil
        }
        let sinDip = max(-1, min(1, (field * gravity).sum() / (fieldNorm * gravityNorm)))
        return Reading(intensityUT: fieldNorm, dipDeg: asin(sinDip) * 180 / .pi, time: time)
    }

    // MARK: - Verdict

    enum Verdict: String {
        /// Strength and dip both match the model.
        case clean
        /// One or both are off: something nearby is bending the field.
        case disturbed
        /// No verdict yet: no position to evaluate the model at, too few calibrated samples, or the
        /// magnetometer not yet calibrated by CoreMotion.
        case pending
        /// This device cannot produce a calibrated field at all. The compass is then trusted as it
        /// always was, rather than blocked forever by a check that can never run.
        case unavailable
    }

    struct Assessment: Equatable {
        var verdict: Verdict
        /// Median measured |B| and dip over the window; nil when there were no samples.
        var measuredUT: Double?
        var dipDeg: Double?
        /// What WMM says they should be here; nil without a position.
        var expectedUT: Double?
        var expectedDipDeg: Double?

        static let pending = Assessment(verdict: .pending)
        static let unavailable = Assessment(verdict: .unavailable)

        init(verdict: Verdict, measuredUT: Double? = nil, dipDeg: Double? = nil,
             expectedUT: Double? = nil, expectedDipDeg: Double? = nil) {
            self.verdict = verdict
            self.measuredUT = measuredUT
            self.dipDeg = dipDeg
            self.expectedUT = expectedUT
            self.expectedDipDeg = expectedDipDeg
        }
    }

    /// Judge the readings of the last `windowSeconds` against the model.
    ///
    /// Medians rather than means, so a sample taken mid-swing — when CoreMotion's gravity briefly
    /// lags the hand — cannot drag the verdict.
    static func assess(_ readings: [Reading], expected: MagneticFieldModel.Field?,
                       at time: TimeInterval) -> Assessment {
        let recent = readings.filter { time - $0.time <= windowSeconds && $0.time <= time }
        let measured = recent.isEmpty ? nil : median(recent.map(\.intensityUT))
        let dip = recent.isEmpty ? nil : median(recent.map(\.dipDeg))
        let expectedUT = expected?.totalUT
        let expectedDip = expected?.inclinationDeg
        var result = Assessment(verdict: .pending, measuredUT: measured, dipDeg: dip,
                                expectedUT: expectedUT, expectedDipDeg: expectedDip)
        guard recent.count >= minSamples, let measured, let dip,
              let expectedUT, let expectedDip, expectedUT > 0 else { return result }
        let intensityOK = abs(measured - expectedUT) <= maxIntensityErrorFraction * expectedUT
        let dipOK = abs(dip - expectedDip) <= maxDipErrorDeg
        result.verdict = intensityOK && dipOK ? .clean : .disturbed
        return result
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

// MARK: - Ground compass gate

/// Which compass samples the ground seed and the ground correction may use (#21). Ground only:
/// in the air the caller does not consult it, and the air seed and holds are untouched.
///
/// - The **correction** uses clean samples only. While the field is disturbed its window stops
///   filling and ages out, so it holds the offset it has; once the field is clean again, it refines
///   toward the clean median.
/// - The **seed** prefers a clean field too, but cannot wait for one indefinitely: until it lands a
///   `.gravity` world points nowhere, and after ten seconds without a reference the seed falls back
///   to restarting the session on ARKit's own compass alignment — the same disturbed compass, plus a
///   restart. So after `seedGraceSeconds` of an unclean field it proceeds on the compass it has, as
///   the calibration card does after its ten seconds, the HUD says so, and the correction takes over
///   once the field is clean.
struct GroundCompassGate {
    /// How long the seed waits for a clean field before proceeding without one. Short against the
    /// seed's 10 s deadline; the calibration card has usually given the user ten seconds already.
    static let seedGraceSeconds: TimeInterval = 3.0

    private(set) var verdict: MagneticFieldIntegrity.Verdict = .pending
    private var notCleanSince: TimeInterval?

    /// Feed the current verdict, once a tick.
    mutating func update(_ verdict: MagneticFieldIntegrity.Verdict, at time: TimeInterval) {
        self.verdict = verdict
        switch verdict {
        case .clean, .unavailable:
            notCleanSince = nil
        case .disturbed, .pending:
            if notCleanSince == nil { notCleanSince = time }
        }
    }

    /// Whether the ground correction may take compass samples now.
    var correctionMayUseCompass: Bool {
        verdict == .clean || verdict == .unavailable
    }

    /// Whether the ground seed may take the compass as its reference now.
    func seedMayUseCompass(at time: TimeInterval) -> Bool {
        if correctionMayUseCompass { return true }
        guard let since = notCleanSince else { return false }
        return time - since >= Self.seedGraceSeconds
    }

    /// True when the seed would be proceeding on a field that is not known to be clean.
    func seedProceedsUnclean(at time: TimeInterval) -> Bool {
        !correctionMayUseCompass && seedMayUseCompass(at: time)
    }

    mutating func reset() {
        verdict = .pending
        notCleanSince = nil
    }
}

// MARK: - Monitor

/// CoreMotion's calibrated magnetic field and gravity, judged against WMM at the current position.
///
/// A separate `CMMotionManager`, deliberately. The calibrated field needs a magnetometer-corrected
/// reference frame, and the app's main device-motion stream must stay in `xArbitraryZVertical` —
/// gyro and gravity only — because the gyro yaw hold, the attitude hold and the camera seed are
/// built on a frame the cabin's field cannot reach. Apple advises one manager per app because
/// several can affect the delivered rates; this one asks for 10 Hz against the main stream's
/// 100 Hz, so the hardware rate is unchanged, and it runs only on the ground and on the calibration
/// screen, never in the air.
///
/// Shared, with named clients, so the calibration screen and the AR view can both hold it — they may
/// overlap once the card becomes an overlay (#20) — and it stops when the last lets go.
/// `start`, `stop` and `updatePosition` are main-thread calls; `assessment` is safe from any thread.
final class MagneticFieldMonitor {

    static let shared = MagneticFieldMonitor()

    /// 10 Hz: ten samples per one-second window, and far below the main stream's rate.
    static let updateInterval: TimeInterval = 0.1

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()
    private let lock = NSLock()
    private var clients = Set<String>()
    // Under `lock`:
    private var readings: [MagneticFieldIntegrity.Reading] = []
    private var expected: MagneticFieldModel.Field?
    private var expectedAt: (latitude: Double, longitude: Double)?

    /// Whether this device can produce a calibrated field at all. Fixed for the device, so
    /// decided once; read from any thread.
    let isAvailable: Bool

    private init() {
        // A magnetometer-corrected frame is only offered by a device with device motion and a
        // magnetometer, so this one test covers both.
        isAvailable = CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryCorrectedZVertical)
    }

    func start(client: String) {
        clients.insert(client)
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = Self.updateInterval
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // An uncalibrated field still carries the phone's own magnetisation: no verdict from it.
            guard motion.magneticField.accuracy != .uncalibrated else { return }
            let f = motion.magneticField.field
            let g = motion.gravity
            guard let reading = MagneticFieldIntegrity.reading(
                fieldUT: SIMD3(f.x, f.y, f.z), gravity: SIMD3(g.x, g.y, g.z), at: motion.timestamp)
            else { return }
            self.lock.lock()
            self.readings.append(reading)
            let cutoff = motion.timestamp - MagneticFieldIntegrity.windowSeconds
            self.readings.removeAll { $0.time < cutoff }
            self.lock.unlock()
        }
    }

    func stop(client: String) {
        clients.remove(client)
        guard clients.isEmpty else { return }
        manager.stopDeviceMotionUpdates()
        lock.lock()
        readings.removeAll()
        lock.unlock()
    }

    /// Re-evaluate the model where the phone is. Recomputed only after moving a kilometre or so —
    /// the main field changes by a few nT over that distance.
    func updatePosition(latitudeDeg: Double, longitudeDeg: Double, altitudeMeters: Double,
                        date: Date = Date()) {
        guard latitudeDeg.isFinite, longitudeDeg.isFinite else { return }
        lock.lock()
        let last = expectedAt
        lock.unlock()
        if let last, abs(last.latitude - latitudeDeg) < 0.01, abs(last.longitude - longitudeDeg) < 0.01 {
            return
        }
        let field = MagneticFieldModel.field(latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg,
                                             altitudeKm: altitudeMeters.isFinite ? altitudeMeters / 1_000 : 0,
                                             date: date)
        lock.lock()
        expected = field
        expectedAt = (latitudeDeg, longitudeDeg)
        lock.unlock()
    }

    /// The current verdict, from the last second of samples. Safe from any thread.
    func assessment() -> MagneticFieldIntegrity.Assessment {
        guard isAvailable else { return .unavailable }
        lock.lock()
        let window = readings
        let model = expected
        lock.unlock()
        // CoreMotion timestamps count from boot, as `systemUptime` does, so a window that stopped
        // filling — updates paused, the app backgrounded — reads as pending rather than as a
        // verdict on old samples.
        return MagneticFieldIntegrity.assess(window, expected: model,
                                             at: ProcessInfo.processInfo.systemUptime)
    }
}
