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

/// Which compass samples the ground correction may use (#21). Ground only: in the air the caller does
/// not consult it, and the air seed and holds are untouched.
///
/// - The **correction** uses clean samples only. While the field is disturbed its window stops
///   filling and ages out, so it holds the offset it has; once the field is clean again, it refines
///   toward the clean median — fast, after an unclean seed (`FastGroundCorrection`).
/// - The **seed** does not wait for a clean field (#21 follow-up, Gev's decision): it takes the
///   compass as soon as it is otherwise ready, and a field that is disturbed or still pending flags it
///   `unclean`. The card no longer holds for the compass either; the HUD's ⚠️ note says so.
struct GroundCompassGate {
    private(set) var verdict: MagneticFieldIntegrity.Verdict = .pending

    /// Feed the current verdict, once a tick.
    mutating func update(_ verdict: MagneticFieldIntegrity.Verdict) {
        self.verdict = verdict
    }

    /// Whether the ground correction may take compass samples now.
    var correctionMayUseCompass: Bool {
        verdict == .clean || verdict == .unavailable
    }

    /// Whether a ground seed taken now is unclean: the field disturbed, or not yet judged. A device
    /// that cannot measure the field is not — it keeps the behaviour from before #21.
    var seedIsUnclean: Bool {
        !correctionMayUseCompass
    }

    /// The seed's compass reference: the true heading whenever the compass is otherwise usable. The
    /// field is not an input — there is no clean-field wait (#21 follow-up); it decides only whether
    /// the seed is flagged `seedIsUnclean`.
    static func seedCompassReferenceDeg(trueHeadingDeg: Double, headingAccuracyDeg: Double,
                                        maxHeadingAccuracyDeg: Double) -> Double? {
        guard trueHeadingDeg >= 0, headingAccuracyDeg >= 0, headingAccuracyDeg <= maxHeadingAccuracyDeg
        else { return nil }
        return trueHeadingDeg
    }

    mutating func reset() {
        verdict = .pending
    }
}

// MARK: - Fast correction after an unclean seed

/// The heading correction after a seed taken on an unclean field (#21 follow-up, Gev's "no wait").
///
/// The card no longer waits for a clean compass, so beside a car or a railing the seed takes the
/// compass it has and the targets can sit 5–10° off. The ordinary ground correction is slow to fix
/// that by design: its window needs ten samples half a second apart, its response gate wants the
/// phone panned through about 40° before it trusts the compass, and it then moves a degree a second.
/// So once the field has stayed clean for `cleanHoldSeconds`, this takes the clean compass at once —
/// the median of the clean readings over that hold — and slews to it over `slewSeconds`, so the
/// targets slide rather than jump, then hands back to the ordinary correction from where it ends.
///
/// Only after an unclean seed, and only on a clean field: a disturbed or pending field resets the
/// hold, and nothing moves while it lasts. Armed again by the next unclean seed.
struct FastGroundCorrection {
    /// How long the field must stay clean before the correction applies.
    static let cleanHoldSeconds: TimeInterval = 2.0
    /// How long the slew to the clean compass takes.
    static let slewSeconds: TimeInterval = 1.0
    /// Fewest clean readings over the hold (the 4 Hz tick gives about nine).
    static let minSamples = 4
    /// Widest the clean readings may disagree — the ordinary correction's own dispersion limit.
    static let maxDispersionDeg: Double = 12.0

    /// One step of the slew: the offset to apply now.
    struct Step: Equatable {
        var offsetDeg: Double
        /// The clean compass offset the slew is heading for.
        var targetDeg: Double
        var isFirst: Bool
        var isLast: Bool
    }

    /// Waiting for a clean field after an unclean seed.
    private(set) var isArmed = false
    private var cleanSince: TimeInterval?
    private var samples: [(time: TimeInterval, deg: Double)] = []
    private var slew: (from: Double, delta: Double, start: TimeInterval, target: Double)?

    /// Part-way through the slew. The ordinary correction stands aside meanwhile.
    var isSlewing: Bool { slew != nil }

    /// A seed has just been applied on the ground; arm only if it was unclean.
    mutating func seedApplied(unclean: Bool) {
        self = FastGroundCorrection()
        isArmed = unclean
    }

    mutating func reset() {
        self = FastGroundCorrection()
    }

    /// Fold in one tick, and get the offset to apply now, if any.
    ///
    /// - Parameters:
    ///   - fieldClean: the field check's verdict is `.clean`.
    ///   - compassSampleDeg: this tick's ARKit-minus-compass reading — the offset the compass says the
    ///     world needs, the quantity the ordinary correction takes the median of — or nil when the
    ///     compass is not usable this tick.
    ///   - appliedOffsetDeg: the offset in force, where the slew starts.
    ///   - canApply: on the ground, the world usable and aligned, no flight anchor.
    mutating func update(fieldClean: Bool, compassSampleDeg: Double?, appliedOffsetDeg: Double,
                         canApply: Bool, at time: TimeInterval) -> Step? {
        if let current = slew {
            guard canApply else {
                // The world stopped being ours to move part-way through — tracking lost, a flight
                // anchor. Stop where it stands (the offset already applied stays) and wait for
                // another clean hold.
                slew = nil
                cleanSince = nil
                samples.removeAll()
                return nil
            }
            let progress = min(1, max(0, (time - current.start) / Self.slewSeconds))
            let isLast = progress >= 1
            if isLast {
                slew = nil
                isArmed = false
            }
            let offset = isLast
                ? current.target
                : AngularResponse.wrappedDeg(current.from + current.delta * progress)
            return Step(offsetDeg: offset, targetDeg: current.target, isFirst: false, isLast: isLast)
        }
        guard isArmed, fieldClean, canApply else {
            cleanSince = nil
            samples.removeAll()
            return nil
        }
        if cleanSince == nil { cleanSince = time }
        if let deg = compassSampleDeg, deg.isFinite { samples.append((time: time, deg: deg)) }
        samples.removeAll { time - $0.time > Self.cleanHoldSeconds }
        guard let since = cleanSince, time - since >= Self.cleanHoldSeconds,
              samples.count >= Self.minSamples else { return nil }
        let values = samples.map { $0.deg }
        guard AngularResponse.circularInterquartileRangeDeg(values) <= Self.maxDispersionDeg else { return nil }
        let target = AngularResponse.circularMedianDeg(values)
        let delta = AngularResponse.signedDelta(appliedOffsetDeg, target)
        slew = (from: appliedOffsetDeg, delta: delta, start: time, target: target)
        return Step(offsetDeg: appliedOffsetDeg, targetDeg: target, isFirst: true, isLast: false)
    }
}

// MARK: - Monitor lifecycle

/// When the field monitor's CoreMotion stream runs (#21): while a client wants it and the phone is
/// *positively* on the ground (`CalibrationFlightPolicy.positivelyOnGround`), never otherwise.
///
/// Off until someone has said the phone is on the ground, so a flight launch — whose first fix may
/// carry no speed, and whose first AR tick may come before the airborne estimate has any basis —
/// never starts it. Leaving the ground stops it at once, whoever still holds it (the calibration
/// card included, which with #20 may still be up over the AR view); back on the ground it runs again
/// only if a client still wants it.
struct FieldMonitorDemand: Equatable {
    private(set) var clients: Set<String> = []
    private(set) var onGround = false

    var shouldRun: Bool { onGround && !clients.isEmpty }

    mutating func add(_ client: String) { clients.insert(client) }
    mutating func remove(_ client: String) { clients.remove(client) }
    mutating func setOnGround(_ value: Bool) { onGround = value }
}

/// The delivered rate of a sample stream between two reads of its running count (#21) — used to log
/// whether the main 100 Hz device-motion stream slows while the field monitor's second manager runs.
struct SampleRateMeter {
    /// Reads closer together than this are ignored rather than measured over a sliver of time.
    static let minIntervalSeconds: TimeInterval = 0.2
    /// A longer gap — the app backgrounded, the tick stopped — gives no rate, rather than an
    /// average over the gap that would read as a slowdown.
    static let maxIntervalSeconds: TimeInterval = 5.0

    private var last: (count: Int, time: TimeInterval)?

    /// Samples per second since the previous read; nil on the first read, after a gap, or when the
    /// count went backwards (the stream was restarted).
    mutating func rate(count: Int, at time: TimeInterval) -> Double? {
        guard let previous = last else {
            last = (count, time)
            return nil
        }
        let interval = time - previous.time
        guard interval >= Self.minIntervalSeconds else { return nil }
        last = (count, time)
        let delivered = count - previous.count
        guard interval <= Self.maxIntervalSeconds, delivered >= 0 else { return nil }
        return Double(delivered) / interval
    }

    mutating func reset() {
        last = nil
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
/// 100 Hz, so the hardware rate should be unchanged — and the flight log's `motion_hz` column
/// measures the main stream so that a slowdown would show. It runs only on the ground and on the
/// calibration screen, only once the phone is positively on the ground, and stops the moment it is
/// not (`FieldMonitorDemand`).
///
/// Shared, with named clients, so the calibration screen and the AR view can both hold it — they may
/// overlap once the card becomes an overlay (#20) — and it stops when the last lets go.
/// `start`, `stop`, `setOnGround` and `updatePosition` are main-thread calls; `assessment` and
/// `deliveredSampleCount` are safe from any thread.
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
    /// Main thread.
    private var demand = FieldMonitorDemand()
    // Under `lock`:
    private var delivered = 0
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

    /// Whether the stream is running now.
    var isRunning: Bool { manager.isDeviceMotionActive }

    /// Samples delivered since launch, for `SampleRateMeter`. Safe from any thread.
    var deliveredSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    /// Hold the monitor for `client`. Runs it once the phone is positively on the ground.
    func start(client: String) {
        demand.add(client)
        apply()
    }

    /// Let go for `client`; the stream stops when the last client lets go.
    func stop(client: String) {
        demand.remove(client)
        apply()
    }

    /// Whether the phone is positively on the ground. False — airborne, or not yet known to be on the
    /// ground — stops the stream at once, whoever holds it; true runs it if a client wants it.
    func setOnGround(_ onGround: Bool) {
        guard demand.onGround != onGround else { return }
        demand.setOnGround(onGround)
        apply()
    }

    private func apply() {
        if demand.shouldRun {
            guard isAvailable, !manager.isDeviceMotionActive else { return }
            startStream()
        } else if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
            lock.lock()
            readings.removeAll()
            lock.unlock()
        }
    }

    private func startStream() {
        manager.deviceMotionUpdateInterval = Self.updateInterval
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.lock.lock()
            self.delivered &+= 1
            self.lock.unlock()
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
