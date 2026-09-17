//
//  HeadingCorrection.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The estimators and policies behind azimuth alignment: how much a sensor follows
//  the phone, how fast the world drifts, when to seed, correct, or ask the user.
//

import Foundation

/// Measures how many degrees one angle turns per degree another turns, over a rolling window.
///
/// Two questions in this app reduce to exactly this, and both have to be answered before any
/// azimuth correction can be trusted again:
///
/// - Does the **compass** follow the **phone**? Slope 1 means it is measuring device azimuth;
///   slope 0 means it is reporting something else (in a cockpit, the aircraft's ground track)
///   and no alignment correction may be built on it.
/// - Does **ARKit's azimuth** follow the **aircraft's ground track** through a turn? Slope 1
///   means ARKit's world is Earth-referenced and its error is one constant per session; slope 0
///   means the world rides with the cabin and grows by every degree the aircraft turns.
///
/// **Why a least-squares slope and not a ratio of absolute changes.** The first version of this
/// summed `|Δresponse|` over `|Δdriver|`, which rectifies noise into apparent signal: sensor
/// jitter adds to the numerator on every sample whether or not the driver moved, and never
/// cancels. On a flight where the true slope was 0.018 that estimator reported 0.61 — it would
/// have certified a compass that was not tracking the phone at all as tracking it perfectly.
/// Regressing signed changes through the origin fixes it, because jitter is uncorrelated with
/// the driver and averages toward zero in the numerator instead of accumulating.
///
/// `correlation` is published beside the slope deliberately. A slope alone can be large and
/// meaningless when the driver barely moved, and this project has been burned repeatedly by
/// single numbers that could not distinguish a case from its opposite.
///
/// **Sample slowly.** The instinct is that more samples give a better estimate; here the
/// opposite holds, and getting it wrong cost a build. The estimator is unbiased at any rate,
/// but for a fixed total rotation `R` split into `n` steps each of size `R/n`,
///
///     Σ(Δdriver²) = n · (R/n)² = R²/n
///
/// and the slope's variance goes as `σ²/Σ(Δdriver²)` — so **variance grows linearly with
/// sampling rate**. Sensor noise arrives per *sample* while the signal arrives per *degree of
/// rotation*, so sampling faster piles up noise against a shrinking denominator. Simulated over
/// a 90° pan against a non-following sensor with ±2° of jitter: 10 Hz gives a standard deviation
/// of 0.071 and worst case 0.274; 1 Hz gives 0.022 and 0.062.
///
/// That is exactly what the first deployment showed. Sampled at ~10 Hz over 3 seconds it read a
/// median of +0.161 with excursions to +0.709 on a flight whose true slope was −0.039, because
/// a single brief compass jump that happened to coincide with a pan dominated the window. Prefer
/// roughly 1 Hz over tens of seconds: enough pairs to average, each carrying real rotation.
struct AngularResponse {

    struct Estimate {
        /// Degrees the response angle turns per degree the driver turns.
        var slope: Double
        /// Pearson correlation of the per-sample changes, −1…1. Near zero means the slope is
        /// describing noise rather than a relationship.
        var correlation: Double
        /// Total absolute driver rotation the estimate is drawn from, in degrees. Sums every
        /// per-sample change, so panning out and back counts as rotation rather than cancelling.
        var driverRotationDeg: Double
        /// How far the driver actually got from where it started, at its widest — max minus min
        /// of the unwrapped angle. A signal that dithers in place has a tiny excursion however
        /// large its summed changes, which is what tells real motion from quantisation noise.
        var driverExcursionDeg: Double
        var pairCount: Int
    }

    /// How long a span the estimate is drawn from.
    let window: TimeInterval
    /// Minimum total driver rotation before an estimate is published at all. Below this the
    /// ratio is noise over noise and says nothing.
    let minDriverRotationDeg: Double
    /// Minimum number of change pairs, so a single jump cannot produce a confident-looking slope.
    let minPairs: Int
    /// Minimum driver *excursion* before publishing — how far it actually travelled from where it
    /// started, not how much it jiggled.
    ///
    /// This gate exists because the rotation gate above sums absolute changes, and summing
    /// absolute changes rectifies noise into apparent signal. That is the same error that made
    /// the first compass-response estimator read 0.61 where the truth was 0.018; fixing the
    /// estimator and leaving the gate alone simply moved it. On one flight the GPS ground track
    /// dithered between 263.3° and 263.7° — an excursion of 0.4°, no turn at all — and 128
    /// samples of that quantisation flutter summed to 12.4°, clearing an 8° rotation gate and
    /// publishing slopes from −0.770 to +0.321 for an aircraft flying dead straight.
    ///
    /// Note that the correlation cannot be used as this guard instead. When a sensor genuinely
    /// does not respond, the honest answer is slope ≈ 0 *and* r ≈ 0 — which is exactly what noise
    /// looks like. Only the driver having really moved separates the two.
    let minDriverExcursionDeg: Double

    private var samples: [(t: TimeInterval, driver: Double, response: Double)] = []

    init(window: TimeInterval,
         minDriverRotationDeg: Double,
         minDriverExcursionDeg: Double,
         minPairs: Int = 8) {
        self.window = window
        self.minDriverRotationDeg = minDriverRotationDeg
        self.minDriverExcursionDeg = minDriverExcursionDeg
        self.minPairs = minPairs
    }

    mutating func add(driver: Double, response: Double, at time: TimeInterval) {
        samples.append((t: time, driver: driver, response: response))
        samples.removeAll { time - $0.t > window }
    }

    mutating func reset() { samples.removeAll() }

    /// Signed shortest angular difference, −180…180. Local to keep this type free-standing.
    static func signedDelta(_ from: Double, _ to: Double) -> Double {
        var d = to - from
        while d >  180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// Total absolute driver rotation currently in the window, regardless of whether that is
    /// enough to publish an estimate. Lets a caller say how close it came rather than only that
    /// it fell short.
    var driverRotationDeg: Double {
        guard samples.count >= 2 else { return 0 }
        var total = 0.0
        for (previous, current) in zip(samples, samples.dropFirst()) {
            total += abs(AngularResponse.signedDelta(previous.driver, current.driver))
        }
        return total
    }

    /// How far the driver travelled from its starting point at the widest, in degrees.
    ///
    /// Built by unwrapping — accumulating signed deltas — so a sweep across north reads as a few
    /// degrees rather than 358, and then taking the span of that walk. Dither stays near zero
    /// no matter how many samples it contains; a real turn spans its full size.
    var driverExcursionDeg: Double {
        guard samples.count >= 2 else { return 0 }
        var cumulative = 0.0, lowest = 0.0, highest = 0.0
        for (previous, current) in zip(samples, samples.dropFirst()) {
            cumulative += AngularResponse.signedDelta(previous.driver, current.driver)
            lowest  = min(lowest, cumulative)
            highest = max(highest, cumulative)
        }
        return highest - lowest
    }

    /// True when samples are accumulating but the driver has not rotated enough to publish.
    ///
    /// Distinct from having no data at all: an empty column looks identical whether the estimator
    /// is broken or simply waiting for the aircraft to turn, and only one of those is worth
    /// investigating.
    var isWaitingForRotation: Bool {
        guard samples.count >= minPairs + 1 else { return false }
        return estimate == nil
    }

    /// The current estimate, or nil when the window holds too little rotation to mean anything.
    var estimate: Estimate? {
        guard samples.count >= minPairs + 1 else { return nil }

        var dDriver: [Double] = []
        var dResponse: [Double] = []
        dDriver.reserveCapacity(samples.count - 1)
        dResponse.reserveCapacity(samples.count - 1)
        for (previous, current) in zip(samples, samples.dropFirst()) {
            dDriver.append(AngularResponse.signedDelta(previous.driver, current.driver))
            dResponse.append(AngularResponse.signedDelta(previous.response, current.response))
        }

        let rotation = dDriver.reduce(0) { $0 + abs($1) }
        guard rotation >= minDriverRotationDeg else { return nil }
        // Both gates, because they catch different things: rotation keeps a back-and-forth pan
        // counting as the real motion it is, excursion refuses a signal that only jiggled.
        let excursion = driverExcursionDeg
        guard excursion >= minDriverExcursionDeg else { return nil }

        // Slope through the origin: no intercept term, because zero driver rotation must mean
        // zero response rotation for this to be the quantity it claims to be.
        let denominator = dDriver.reduce(0) { $0 + $1 * $1 }
        guard denominator > 0 else { return nil }
        let slope = zip(dDriver, dResponse).reduce(0) { $0 + $1.0 * $1.1 } / denominator

        return Estimate(slope: slope,
                        correlation: AngularResponse.correlation(dDriver, dResponse),
                        driverRotationDeg: rotation,
                        driverExcursionDeg: excursion,
                        pairCount: dDriver.count)
    }

    static func correlation(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 1 else { return .nan }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            let dx = a - meanX, dy = b - meanY
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        let denominator = (sxx * syy).squareRoot()
        return denominator > 0 ? sxy / denominator : .nan
    }
}

/// How fast ARKit's world azimuth drifts while the phone is genuinely not being turned.
///
/// This bounds how long a one-time alignment survives, which decides whether a fixed per-session
/// azimuth offset is a real fix or a fantasy: near zero and an alignment captured once holds for
/// a whole glance; at half a degree per second it is 15° adrift after thirty seconds and nothing
/// captured once can help.
///
/// **Why the caller must gate this on the gyro, and not on ARKit's own attitude.** ARKit's yaw is
/// the quantity under test, so it cannot also be the evidence that the phone is still. Pitch and
/// roll are gravity-referenced and cannot drift, which makes them tempting — but a pure yaw
/// rotation of the wrist leaves both completely unchanged, and scanning for traffic *is* a pure
/// yaw rotation. A pitch/roll stillness gate therefore cannot tell drift from the user looking
/// around: it is non-discriminating in exactly the way that has cost this project three builds.
/// The gyro is the only independent source of true yaw rate.
///
/// A useful side effect of gating on the gyro: gyro-still means *inertially* still, so it also
/// rules out the aircraft turning beneath a motionless phone. No separate GPS gate is needed.
///
/// **Net change per run, never a sum of per-sample changes.** Each still run contributes
/// `(azimuth at end − azimuth at start) / duration`. Summing per-sample absolute changes would
/// rectify ARKit's per-frame jitter into apparent drift — the precise error that made the first
/// compass-response estimator read 0.61 where the truth was 0.018. A net difference across a run
/// is immune to it.
struct YawDriftAccumulator {

    struct Estimate {
        /// Duration-weighted mean drift, in degrees per second. Signed: a consistent sign across
        /// runs indicates real bias, an inconsistent one indicates a random walk.
        var degreesPerSecond: Double
        /// Total still time the estimate is drawn from. A thin estimate should look thin.
        var totalStillSeconds: TimeInterval
        /// Largest net rotation the gyro saw across any banked run, in degrees. Near zero means
        /// the phone really did end up where it started and the drift figure is clean; a large
        /// value means a run was contaminated and the number should not be trusted.
        var worstGyroNetDeg: Double
        var runCount: Int
    }

    /// A run shorter than this cannot separate drift from the noise at its two endpoints.
    let minRunSeconds: TimeInterval
    /// Total still time required before an estimate is published at all.
    let minTotalSeconds: TimeInterval
    /// Largest net rotation, per the gyro, that a run may end with and still be banked.
    ///
    /// Gating on *integrated* rotation rather than instantaneous rate is what makes this usable
    /// in an aircraft. The first version required the instantaneous yaw rate to stay under a
    /// threshold at every single 60 Hz sample for five continuous seconds, so one vibration spike
    /// ended a run: it collected 51 seconds in smooth cruise at FL415 and nothing at all in a
    /// descent through FL340.
    ///
    /// The integral is the right quantity anyway, because drift is measured as the **net** change
    /// across a run. What disqualifies a run is the phone having ended up rotated, not having
    /// jittered on the way. Vibration integrates to zero by construction, and a run where the
    /// phone swung out and came back stays valid because both sides of the comparison are nets.
    ///
    /// Checked **only at run end** — in `closeRun()` and in `estimate`, both against the net the
    /// run finished with. That is what makes the sentence above true rather than aspirational: a
    /// mid-run test cannot know whether the phone is on its way out or on its way back, so any
    /// such test refuses a cancelling swing as if it were a turn.
    let maxGyroNetDeg: Double

    private var runStartTime: TimeInterval?
    private var runStartAzimuth: Double = 0
    private var runLastTime: TimeInterval = 0
    private var runLastAzimuth: Double = 0
    /// Gyro-integrated net rotation across the run in progress, in degrees.
    private var runGyroNetDeg: Double = 0

    private var weightedRateSum: Double = 0      // Σ(rate · duration) = Σ(net change)
    private var totalSeconds: TimeInterval = 0
    private var runs: Int = 0
    private var worstGyroNet: Double = 0

    init(minRunSeconds: TimeInterval = 5.0,
         minTotalSeconds: TimeInterval = 10.0,
         maxGyroNetDeg: Double = 2.0) {
        self.minRunSeconds = minRunSeconds
        self.minTotalSeconds = minTotalSeconds
        self.maxGyroNetDeg = maxGyroNetDeg
    }

    /// Feed one sample.
    ///
    /// `gyroYawRateDps` must come from a source independent of ARKit — see the type comment for
    /// why ARKit's own attitude will not do. It is integrated across the run, and the run is
    /// banked only if the integral it **ends** with is small; nothing here judges it while the run
    /// is in progress. `isTracking` false ends the current run, since ARKit's azimuth means
    /// nothing then.
    mutating func add(azimuthDeg: Double,
                      gyroYawRateDps: Double,
                      isTracking: Bool,
                      at time: TimeInterval) {
        guard isTracking, gyroYawRateDps.isFinite else { closeRun(); return }

        guard let start = runStartTime else {
            runStartTime = time
            runStartAzimuth = azimuthDeg
            runLastTime = time
            runLastAzimuth = azimuthDeg
            runGyroNetDeg = 0
            return
        }
        // A gap means samples stopped arriving — tracking dropped, or the app was backgrounded.
        // Bridging across it would credit unobserved time as still.
        if time - runLastTime > 1.5 {
            closeRun()
            runStartTime = time
            runStartAzimuth = azimuthDeg
            runLastTime = time
            runLastAzimuth = azimuthDeg
            runGyroNetDeg = 0
            return
        }
        _ = start
        // Trapezoid over the interval since the last sample. Signed, so vibration cancels — and
        // accumulated only, never tested against maxGyroNetDeg here. A running total that has gone
        // wide says the phone is rotated *now*, which is not the question: the question is where it
        // ends up, and a half-cycle of vibration is wide at its peak and zero at its end. Ending
        // the run on the peak is the build 14 failure with an integral in place of a rate.
        runGyroNetDeg += gyroYawRateDps * (time - runLastTime)
        runLastTime = time
        runLastAzimuth = azimuthDeg
    }

    /// End the current run, banking it if it lasted long enough to mean anything.
    mutating func closeRun() {
        defer { runStartTime = nil; runGyroNetDeg = 0 }
        guard let start = runStartTime else { return }
        let duration = runLastTime - start
        guard duration >= minRunSeconds else { return }
        guard abs(runGyroNetDeg) <= maxGyroNetDeg else { return }
        // Net change across the run, not a sum of per-sample changes.
        weightedRateSum += AngularResponse.signedDelta(runStartAzimuth, runLastAzimuth)
        totalSeconds += duration
        runs += 1
        worstGyroNet = max(worstGyroNet, abs(runGyroNetDeg))
    }

    mutating func reset() {
        runStartTime = nil
        runGyroNetDeg = 0
        weightedRateSum = 0
        totalSeconds = 0
        runs = 0
        worstGyroNet = 0
    }

    /// Includes the run in progress, so a long steady hold shows up without waiting for it to end.
    var estimate: Estimate? {
        var sum = weightedRateSum
        var seconds = totalSeconds
        var count = runs
        var worst = worstGyroNet
        if let start = runStartTime {
            let duration = runLastTime - start
            if duration >= minRunSeconds, abs(runGyroNetDeg) <= maxGyroNetDeg {
                sum += AngularResponse.signedDelta(runStartAzimuth, runLastAzimuth)
                seconds += duration
                count += 1
                worst = max(worst, abs(runGyroNetDeg))
            }
        }
        guard seconds >= minTotalSeconds, count > 0 else { return nil }
        return Estimate(degreesPerSecond: sum / seconds,
                        totalStillSeconds: seconds,
                        worstGyroNetDeg: worst,
                        runCount: count)
    }
}

/// Captures how far ARKit's world north is from true north, from a few seconds of the user
/// pointing the phone along the direction of flight.
///
/// **In the air only.** On the ground the compass measures the phone properly
/// (`compass_response` 1.00 against 0.018 in the cabin), so ARKit's own `.gravityAndHeading`
/// anchor is already right and this would replace a good reference with a worse one.
///
/// While the phone points along the flight direction the phone's true azimuth equals the
/// aircraft's ground track, so `offset = track − ARKit azimuth`. That is the same quantity
/// `worldYawErrorDeg` measures against the compass on the ground, with the same sign, and it is
/// what target placement must subtract from each bearing.
///
/// GPS ground course is an essentially exact reference here — `gps_course_acc_deg` medians 0.0–0.2°
/// in flight across eight logs. The residual error is not the reference, it is two other things:
/// the **drift angle** between ground track and where the nose points (5–10° at cruise in a
/// crosswind) and the user's own pointing accuracy. So this replaces an error of up to 90° with one
/// of 5–10°, and should be described that way rather than as exact.
///
/// Gated, not timed. Averaging only fights hand wobble, which is correlated over about a second, so
/// beyond a few seconds it is polishing a term already smaller than the drift-angle bias. What
/// matters is refusing a bad hold: the phone must have been held still and the aircraft must not
/// have been turning.
struct FlightDirectionAnchor {

    struct Estimate {
        /// Degrees to subtract from every bearing at placement time.
        var offsetDeg: Double
        var sampleCount: Int
        var seconds: TimeInterval
        /// How far the phone wandered during the hold, and how far the track moved. Both are
        /// recorded because they are the reasons a hold is accepted or thrown away.
        var azimuthSpreadDeg: Double
        var trackSpreadDeg: Double
    }

    /// `Error` because `Result`'s failure type requires it; the raw string is what the log records.
    enum Failure: String, Error {
        case tooShort         // released before the minimum hold
        case tooFewSamples    // tracking dropped out during the hold
        case phoneMoved       // the user panned instead of holding
        case aircraftTurning  // the track moved, so it was never one direction
    }

    let minSeconds: TimeInterval
    let minSamples: Int
    /// How far the phone may wander over the hold.
    ///
    /// Tightened from 25° to 5° in build 29. The old value was set to reject a pan rather than
    /// demand a tripod, on the reasoning that the median absorbs hand wander — which is true, but
    /// the anchor's error turned out not to be wander at all. It is *aim*: three captures against an
    /// unchanging track read 6.3°, 16.6° and 18.4°, and the user's eyes said the uncorrected world
    /// those replaced was the accurate one. Spread does not predict that error (the 8.2° capture and
    /// the 4.2° capture landed 1.8° apart), so this gate cannot fix the anchor; it only refuses the
    /// captures with least claim to be a considered aim.
    let maxAzimuthSpreadDeg: Double
    /// How far the ground track may move. Tight: if the aircraft turned during the hold then the
    /// samples were taken against different references and the median of them means nothing.
    let maxTrackSpreadDeg: Double

    private var startTime: TimeInterval?
    private var samples: [(t: TimeInterval, offset: Double, az: Double, track: Double)] = []

    init(minSeconds: TimeInterval = 3.0,
         minSamples: Int = 8,
         maxAzimuthSpreadDeg: Double = 5.0,
         maxTrackSpreadDeg: Double = 5.0) {
        self.minSeconds = minSeconds
        self.minSamples = minSamples
        self.maxAzimuthSpreadDeg = maxAzimuthSpreadDeg
        self.maxTrackSpreadDeg = maxTrackSpreadDeg
    }

    var isCapturing: Bool { startTime != nil }

    /// 0…1, for a progress ring. Reaches 1 when the hold is long enough to be finished.
    func progress(at time: TimeInterval) -> Double {
        guard let startTime else { return 0 }
        return max(0, min(1, (time - startTime) / minSeconds))
    }

    mutating func begin(at time: TimeInterval) {
        startTime = time
        samples.removeAll()
    }

    mutating func cancel() {
        startTime = nil
        samples.removeAll()
    }

    /// Feed one reading. Ignored unless a hold is running.
    mutating func add(arAzimuthDeg: Double, trackDeg: Double, at time: TimeInterval) {
        guard startTime != nil, arAzimuthDeg.isFinite, trackDeg.isFinite else { return }
        samples.append((t: time,
                        offset: AngularResponse.signedDelta(arAzimuthDeg, trackDeg),
                        az: arAzimuthDeg,
                        track: trackDeg))
    }

    /// Close the hold and either publish an offset or say why not. Clears either way, so a refused
    /// hold cannot leak samples into the next attempt.
    mutating func finish(at time: TimeInterval) -> Result<Estimate, Failure> {
        defer { cancel() }
        guard let startTime else { return .failure(.tooShort) }
        let seconds = time - startTime
        guard seconds >= minSeconds else { return .failure(.tooShort) }
        guard samples.count >= minSamples else { return .failure(.tooFewSamples) }

        let azSpread = FlightDirectionAnchor.spreadDeg(samples.map(\.az))
        let trackSpread = FlightDirectionAnchor.spreadDeg(samples.map(\.track))
        guard trackSpread <= maxTrackSpreadDeg else { return .failure(.aircraftTurning) }
        guard azSpread <= maxAzimuthSpreadDeg else { return .failure(.phoneMoved) }

        let offsets = samples.map(\.offset).sorted()
        let mid = offsets.count / 2
        let median = offsets.count % 2 == 0 ? (offsets[mid - 1] + offsets[mid]) / 2 : offsets[mid]

        return .success(Estimate(offsetDeg: median,
                                 sampleCount: samples.count,
                                 seconds: seconds,
                                 azimuthSpreadDeg: azSpread,
                                 trackSpreadDeg: trackSpread))
    }

    /// Max minus min of a wrapping angle series, unwrapped against the first sample so a hold that
    /// straddles north is not read as 360° of movement.
    static func spreadDeg(_ degrees: [Double]) -> Double {
        guard let first = degrees.first else { return 0 }
        let unwrapped = degrees.map { AngularResponse.signedDelta(first, $0) }
        guard let lo = unwrapped.min(), let hi = unwrapped.max() else { return 0 }
        return hi - lo
    }
}

/// The world's alignment, taken once at startup without asking the user for a gesture.
///
/// **Why the app takes this itself from build 30.** Until now ARKit did it: `.gravityAndHeading`
/// orients the world by assuming the device points where the compass says, and in a cabin the
/// compass reads the aircraft — median `hdg_true − track` of 0.00° over 204 samples. That accident
/// made the world correct whenever the phone happened to be held forward at startup, which is why
/// the one session that reported targets landing on the traffic ran with no correction at all.
///
/// But `.gravityAndHeading` does not seed once. ARKit keeps fusing the magnetometer, and a
/// magnetometer measuring the fuselage feeds it garbage: `compass_response` swung 0.105 → 0.02 →
/// 0.33 → 0.005 inside a single flight, and across three `limited:motion` episodes in twenty seconds
/// the world rotated about 176°, ending with the scene pointing backwards. So build 30 runs
/// `.gravity` — no magnetometer anywhere in ARKit's pipeline — and does the seeding here instead,
/// exactly once per world.
///
/// The arithmetic is the flight anchor's, in one second and with no gesture: the offset is the
/// median of `reference − arAzimuth`, asserting that the phone is currently pointing along the
/// reference direction. That assertion is what the startup card is on screen asking for.
struct StartupSeed {

    /// What the phone is being assumed to point at.
    enum Reference: String {
        /// Airborne: the aircraft's GPS ground track, which is the nose to within the drift angle.
        /// The compass cannot be used here — it measures the fuselage, not the phone.
        case track
        /// The phone's own true heading, used on the ground — but only as a *rough* first
        /// alignment, never as the whole of one.
        ///
        /// A single snapshot carries the magnetometer's full absolute bias. `compass_response` ≈ 1
        /// proves the compass *follows* the phone and says nothing about that bias: one ground log
        /// had `hdg_true` swing 273° → 345° while the phone turned 60° — ratios against the gyro of
        /// 1.16, 0.45, 0.65, 0.62 — while reporting `hdg_acc` 10–11° throughout. Build 31 seeded
        /// from exactly that and the scene jumped 38° the moment it landed.
        ///
        /// What makes it safe in build 33 is what follows it: `GroundYawCorrection` refines the
        /// offset from a fifteen-second rolling median across many phone headings, which averages
        /// the heading-dependent part of the error down. The snapshot's job is only to stop a
        /// `.gravity` world pointing nowhere for the first few seconds.
        case compass
    }

    struct Estimate {
        var offsetDeg: Double
        var referenceKind: Reference
        var sampleCount: Int
        var seconds: TimeInterval
        var azimuthSpreadDeg: Double
    }

    /// A second is enough at 5 Hz, and short enough that the aircraft's turn inside it is
    /// negligible — 0.2 °/s at cruise is 0.2° across the whole capture.
    let minSeconds: TimeInterval
    let minSamples: Int

    private(set) var reference: Reference?
    private var startTime: TimeInterval?
    private var samples: [(offset: Double, az: Double)] = []

    init(minSeconds: TimeInterval = 1.0, minSamples: Int = 5) {
        self.minSeconds = minSeconds
        self.minSamples = minSamples
    }

    var isCapturing: Bool { reference != nil }

    /// Arm the capture. Takes no time on purpose: the hold begins at the first sample, on the render
    /// clock, because `add` and `finish` are fed from there and the two sides must share one
    /// timebase or the duration check is meaningless. Arming happens on the display tick, which
    /// cannot see that clock.
    mutating func begin(reference: Reference) {
        self.reference = reference
        startTime = nil
        samples.removeAll()
    }

    mutating func add(arAzimuthDeg: Double, referenceDeg: Double, at time: TimeInterval) {
        guard reference != nil, arAzimuthDeg.isFinite, referenceDeg.isFinite else { return }
        if startTime == nil { startTime = time }
        samples.append((offset: AngularResponse.signedDelta(arAzimuthDeg, referenceDeg),
                        az: arAzimuthDeg))
    }

    mutating func cancel() {
        startTime = nil
        reference = nil
        samples.removeAll()
    }

    /// How far along the hold is, 0 to 1 — the lower of the elapsed and sample fractions, so both
    /// have to be satisfied. The caller polls this and only calls `finish` at 1.0.
    func progress(at time: TimeInterval) -> Double {
        guard let startTime, minSeconds > 0, minSamples > 0 else { return 0 }
        let elapsed = min(1.0, (time - startTime) / minSeconds)
        let filled = min(1.0, Double(samples.count) / Double(minSamples))
        return min(elapsed, filled)
    }

    /// Publish the seed, or nil.
    ///
    /// **Only clears when it has actually decided.** Build 30 opened this with `defer { cancel() }`,
    /// which cleared the capture on the not-ready-yet returns as well — and the caller polls after
    /// every sample. The result was one sample taken, discarded, and re-begun four times a second
    /// for a whole session: `yaw_src=none` throughout, and under `.gravity` that means a world with
    /// no alignment at all, which is how a ground test came back 192° out. Not ready is now a
    /// no-op, so the struct is correct however it is called rather than only if the caller
    /// remembers to gate on `progress`.
    ///
    /// Deliberately **not** gated on how far the phone wandered, unlike the manual anchor. The user
    /// is holding the phone up during initialisation, not performing an aim, and a refused seed
    /// under `.gravity` leaves the world with no alignment at all — which is worse than a seed a few
    /// degrees loose. The spread is published instead, so a bad one is visible in the log.
    mutating func finish(at time: TimeInterval) -> Estimate? {
        guard let startTime, let reference else { return nil }
        let seconds = time - startTime
        guard seconds >= minSeconds, samples.count >= minSamples else { return nil }
        defer { cancel() }

        let offsets = samples.map(\.offset).sorted()
        let mid = offsets.count / 2
        let median = offsets.count % 2 == 0 ? (offsets[mid - 1] + offsets[mid]) / 2 : offsets[mid]

        return Estimate(offsetDeg: median,
                        referenceKind: reference,
                        sampleCount: samples.count,
                        seconds: seconds,
                        azimuthSpreadDeg: FlightDirectionAnchor.spreadDeg(samples.map(\.az)))
    }
}

/// When a startup seed is worth applying, and when it is worth going back for a steadier one.
///
/// This lives here, apart from the capture and apart from the view controller, because it is the
/// part that has twice been wrong while the mechanism around it worked. Build 36 shipped resampling
/// that fired, re-armed and logged exactly as designed, and still left a world 31° out, because the
/// *policy* driving it was wrong in two ways: it budgeted three attempts when what mattered was
/// elapsed time, and it let the last capture win rather than the steadiest. Builds 29 through 33
/// each shipped a defect of the same shape — correct-looking code in a path no test could reach.
/// So the decision is pure, and tested.
enum SeedResamplePolicy {

    /// Azimuth spread above which a hold was taken while the phone was still moving.
    ///
    /// A seed measures where the nose is by assuming the phone points along it for one second, so a
    /// hold that swept 50° during that second is measuring an average of where the phone visited.
    /// In the airliner flight one capture logged `az_spread=54.3°`, another 50.0°; every good hold
    /// across every flight so far held to 0.1–4.5°, with one 10.9° outlier. Ten degrees clears all
    /// of those and catches all of these.
    static let spreadGateDeg: Double = 10.0

    /// How long one world keeps looking for a steadier hold.
    ///
    /// Time, not attempts. A resample is nearly free — it re-reads an azimuth stream already being
    /// sampled at 5 Hz — and build 36's budget of three attempts covered four seconds of a
    /// two-minute lift. The phone in that lift went still at t≈9 and stayed still for forty
    /// seconds; the app had stopped looking at t=5.6. Thirty seconds covers that with margin.
    static let windowSeconds: TimeInterval = 30.0

    /// Whether a fresh capture should replace the offset currently in force.
    ///
    /// The first capture of a world always applies: under `.gravity` an unapplied seed leaves the
    /// world pointing nowhere, which is worse than any loose seed. After that a capture must be
    /// *strictly* steadier than the best already applied. That makes every scene movement a genuine
    /// improvement and makes them self-limiting, since the spread only ever falls.
    static func shouldApply(spreadDeg: Double, bestAppliedSpreadDeg: Double?) -> Bool {
        guard let best = bestAppliedSpreadDeg else { return true }
        return spreadDeg < best
    }

    /// Whether to arm another capture after applying (or skipping) one with this spread.
    ///
    /// Stops as soon as a hold comes in under the gate — that is the answer, not a step toward it —
    /// and stops at the deadline whatever the spread, so a phone that never settles cannot resample
    /// for the whole flight.
    static func shouldKeepResampling(
        spreadDeg: Double,
        now: TimeInterval,
        deadline: TimeInterval
    ) -> Bool {
        guard spreadDeg > spreadGateDeg else { return false }
        return now < deadline
    }
}

/// When to offer the compass calibration screen.
///
/// **Why this needed writing at all.** Every alignment path on the ground rests on the
/// magnetometer, and this app had never let anything calibrate it. Two remedies exist and both
/// were dead: `locationManagerShouldDisplayHeadingCalibration` was not implemented, so iOS —
/// whose delegate default is `false` — was never permitted to show its own figure-8 dance; and the
/// app's own `CalibrationViewController` was reached only by an edge crossing of 20° in
/// `CLHeading.headingAccuracy`, a value that reads **exactly 10.0 in 34 of 35 flight logs and is
/// never once beaten**. A constant is not a measurement, so that edge never happened.
///
/// The symptom matches: the user reports an offset of the same size and the same side whichever
/// way they face, roughly 5–15°, which is what an uncalibrated magnetometer's hard-iron bias looks
/// like. Direction-*dependent* error was tested against the logs and rejected (Theil–Sen slopes of
/// +0.007 and −0.006 on the two best-sampled lifts, 213° and 175° of heading coverage), as was a
/// tilt dependence and a rotating ARKit world.
///
/// Offering is deliberately conservative, because an interruption at the wrong moment is its own
/// fault: build 24's edge detector fired at CoreLocation's 10 Hz and stalled ARKit's
/// initialisation, presenting as a frozen camera.
enum CompassCalibrationPolicy {

    /// Whether to put the calibration screen up now.
    ///
    /// - `alreadySkipped`: the user dismissed it once; never ask again this launch. One refusal is
    ///   an answer, and a second prompt is a nag.
    /// - `modalShowing`: something is already on screen. Never stack.
    /// - `seedCapturing`: the startup seed is mid-hold. The dance is a metre of vigorous phone
    ///   waving, which would destroy the very hold being measured.
    /// - `airborne`: in the air the alignment comes from the GPS track, not the compass, so a
    ///   calibration buys nothing and costs the user the view out of the window.
    static func shouldOffer(
        alreadySkipped: Bool,
        modalShowing: Bool,
        seedCapturing: Bool,
        airborne: Bool
    ) -> Bool {
        !alreadySkipped && !modalShowing && !seedCapturing && !airborne
    }

    /// Key for "this install has been offered the deliberate figure-8 once".
    static let offeredDefaultsKey = "compassCalibrationOffered"

    /// Whether that has happened. **Once per install, not once per launch**, and the distinction
    /// carries the whole standing requirement: *"This app should be instant and automatic. The user
    /// should lift up his phone, see where the traffic is, and put the phone down."* A full-screen
    /// calibration on every ground launch would break exactly that. One deliberate offer, ever,
    /// with `locationManagerShouldDisplayHeadingCalibration` handling everything afterwards —
    /// iOS raises that itself only when the magnetometer actually needs it.
    static var hasCalibratedOnce: Bool {
        UserDefaults.standard.bool(forKey: offeredDefaultsKey)
    }

    static func markCalibrationOffered() {
        UserDefaults.standard.set(true, forKey: offeredDefaultsKey)
    }
}

/// How far ARKit's world azimuth has drifted from the compass, as a rolling median.
///
/// Used for exactly one decision: whether a world is worth re-anchoring when the user next returns
/// to the AR view. ARKit's yaw drifts about 0.07 °/s — roughly 4° a minute — and re-anchoring
/// clears that, at the cost of a second of stalled camera while tracking re-initialises. Worth
/// paying occasionally, not on every return.
///
/// **Only meaningful on the ground.** The gap it measures is ARKit's azimuth minus the compass, and
/// the compass only measures the phone outside a fuselage (`compass_response` ≈ 1.00 on the ground,
/// 0.018 in the air). Airborne the compass reports the aircraft's ground track, so the gap grows
/// with every degree the user pans and says nothing about drift: rolling 15 s medians run 85–126°
/// across four flight logs, against 4.05° and 5.33° on two clean ground logs. A caller that fed
/// this airborne would re-anchor almost continuously — the precise failure build 19 exists to stop.
///
/// A **median**, not a mean or a single sample, because the instantaneous gap is spiky: the ground
/// log that medians 2.0° spans −31.6° to +19.4°, since a fast pan briefly outruns the compass.
/// Signed, so that symmetric pan noise medians toward zero rather than rectifying into apparent
/// drift — the same mistake that made the first compass-response estimator read 0.61 against a
/// truth of 0.018. The sign is discarded only at the comparison.
struct AlignmentDriftMonitor {

    /// How far back the median looks.
    let window: TimeInterval
    /// Below this many samples nothing is published: a median of three readings is not a median.
    let minSamples: Int
    /// Caller-side rate limit. The feeding site runs at 60 Hz; re-sorting a 900-entry array every
    /// frame to answer a question asked a few times a minute would be absurd.
    let minSampleInterval: TimeInterval

    private var samples: [(t: TimeInterval, deg: Double)] = []
    private var lastSampleTime: TimeInterval = -.greatestFiniteMagnitude

    init(window: TimeInterval = 15.0, minSamples: Int = 10, minSampleInterval: TimeInterval = 0.5) {
        self.window = window
        self.minSamples = minSamples
        self.minSampleInterval = minSampleInterval
    }

    /// Feed one ARKit-minus-compass reading. Ignored if it arrives sooner than `minSampleInterval`
    /// after the last one kept.
    mutating func add(errorDeg: Double, at time: TimeInterval) {
        guard errorDeg.isFinite else { return }
        guard time - lastSampleTime >= minSampleInterval else { return }
        lastSampleTime = time
        samples.append((t: time, deg: errorDeg))
        samples.removeAll { time - $0.t > window }
    }

    /// Signed median of the readings in the window, or nil until there are enough of them.
    var medianErrorDeg: Double? {
        guard samples.count >= minSamples else { return nil }
        let sorted = samples.map(\.deg).sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// How far apart the readings behind that median are — the interquartile range, in degrees.
    ///
    /// A median says where the middle is and nothing about whether the sample agrees with itself,
    /// and until build 38 that was the only thing published, so `GroundYawCorrection` had no way to
    /// tell a settled compass from a disturbed one. In the Teterboro ground log the magnetometer
    /// spent seven seconds forty degrees away from its own cluster; the median dutifully followed
    /// it and walked the scene four degrees off, then four degrees back, over eighty seconds. Every
    /// correction that excursion produced sat behind an IQR above 41°, and every good one behind an
    /// IQR under 6°. One number separates them.
    var interquartileRangeDeg: Double? {
        guard samples.count >= minSamples else { return nil }
        let sorted = samples.map(\.deg).sorted()
        return AltitudeDatumOffset.percentile(sorted, 0.75)
             - AltitudeDatumOffset.percentile(sorted, 0.25)
    }

    /// Clear after a re-anchor. Without this the large readings that *caused* a reset would still
    /// be in the window afterwards and would immediately demand another.
    mutating func reset() {
        samples.removeAll()
        lastSampleTime = -.greatestFiniteMagnitude
    }
}

/// Turns `AlignmentDriftMonitor`'s median into an applied correction — **on the ground only**.
///
/// ARKit seeds its world azimuth from the compass once, at session start (`.gravityAndHeading`),
/// and then leaves it to drift at about 0.07 °/s. On a ground log that showed up as a rolling
/// `world_yaw_corr` median of about −2.5°, which is exactly the "close but not spot on" the user
/// reported. Feeding that median back in re-slaves ARKit's azimuth to the *current* compass and
/// removes the drift since the seed.
///
/// **What it cannot do:** remove the compass's own bias against true north. That same log reported
/// `hdg_acc_deg` = 10° for its whole duration. This makes ARKit agree with the compass; it does not
/// make the compass right.
///
/// **Why the gates are not negotiable.** Build 8 applied a compass-derived correction with no
/// airborne gate and no check that the compass was measuring the *phone*. Inside a fuselage
/// `CLHeading` reports the aircraft's ground track (`compass_response` 0.018 against 1.00 on the
/// ground), so what it actually subtracted was the angle between the phone and the nose, swinging
/// the whole scene back toward the nose every time the user looked out of a side window. Two gates
/// here exist solely so that cannot recur: `airborne` refuses outright, and `compassResponse` must
/// have just proved, by regression against ARKit's own azimuth, that the compass follows the phone.
/// The second is the discriminating one — it would have caught build 8 even without the first.
///
/// The response estimator needs the phone to have been panned about 40° before it publishes
/// anything, so on a phone held perfectly still from launch nothing is applied. That is the correct
/// behaviour, not a gap: with no rotation there is no evidence about which sensor is measuring what.
struct GroundYawCorrection {

    /// A magnitude cap on the offset. **180° from build 34, i.e. no cap.**
    ///
    /// It was 20°, on build 24's reasoning that ARKit was already compass-aligned so a larger gap
    /// meant a broken sensor rather than a genuinely wrong world. Under `.gravity` that premise is
    /// void: ARKit takes no alignment of its own, the median handed in here is the *total* offset
    /// measured against the uncorrected azimuth, and it is arbitrary by construction. Two ground
    /// sessions had it refuse `median=-150.74` and `median=149.00` at `response` 1.06 and 1.08 with
    /// `r` 0.97 and 0.98 — a healthy compass, rejected on magnitude alone, so the refinement never
    /// ran once and the offset stayed pinned at the seed's value for both whole sessions.
    ///
    /// The gates that discriminate are the other ones — airborne, `compass_response` near 1 with a
    /// real correlation, heading accuracy. This one never did. Removing it does mean a badly wrong
    /// compass can now drive a badly wrong offset, and on a `.gravity` world there is no second
    /// reference to cross-check against; the response gate is the protection, and it is the one that
    /// has held up in testing.
    let maxOffsetDeg: Double
    /// How far `compassResponse` may sit from 1.0 and still count as "measuring the phone".
    let responseToleranceFromOne: Double
    /// Correlation floor behind that slope. A slope fitted through noise is not evidence.
    let minResponseCorrelation: Double
    /// Compass accuracy past which the heading is not worth correcting to.
    let maxHeadingAccuracyDeg: Double
    /// Minimum gap between applied updates.
    let minUpdateInterval: TimeInterval
    /// How far the median must have moved for a correction to **start**. A trigger, not a filter.
    ///
    /// Raised 0.5° → 1.5° in build 33. At 0.5° the correction walked 0.59 → −3.02 → +4.56 across one
    /// ground session, chasing a median that was mostly noise around 1.5° — four degrees of
    /// continuous scene motion for no gain. The median is the signal; its jitter is not.
    ///
    /// It used to be consulted on every tick, which is a different thing entirely and cost more
    /// than it saved: a move stopped as soon as the *remaining* error fell inside the band, so
    /// every correction settled up to the full 1.5° short of the median it was chasing.
    /// `docs/AR_ACCURACY_PLAN.md` budgets 1–2° of total angular error, so that floor alone
    /// consumed nearly all of it, and a standing residual of exactly that shape is what builds
    /// 34–39 were chasing. Now it gates only whether a move begins; once one has, the correction
    /// converges the whole way, and the band re-arms the moment it arrives. Jitter inside the
    /// band still moves nothing, which is the property build 33 raised it for.
    let deadbandDeg: Double
    /// Most the applied offset may move in one update, so the correction converges over a few
    /// seconds rather than stepping every marker at once.
    let maxSlewPerUpdateDeg: Double
    /// Widest the readings behind the median may disagree and still be worth acting on.
    ///
    /// The deadband above asks whether the median has moved enough to be worth chasing. This asks
    /// the prior question — whether the median means anything — and until build 38 nothing did.
    /// In the Teterboro log a magnetometer disturbance dragged the 15 s median from 137.7 to 133.4
    /// and the correction followed, walking the scene four degrees off over twenty-three seconds
    /// before the compass recovered and it walked back. Every correction from that excursion had an
    /// IQR of 41–47°; every good one in the same session had 3.8–5.9°, and the session's median IQR
    /// was 6.1°. Twelve degrees is loose in ordinary conditions and bites only while the compass
    /// cannot agree with itself.
    let maxDispersionDeg: Double

    /// The correction currently in force, in the same sense as `worldYawOffsetDeg`: ARKit's world
    /// north minus true north, subtracted from every bearing.
    private(set) var appliedOffsetDeg: Double = 0
    /// Whether anything has been applied yet, so a legitimate 0.0° reads differently from "never ran".
    private(set) var hasOffset: Bool = false
    /// Whether a correction is part-way through slewing to the median that triggered it. The
    /// deadband is not consulted while this is set — that is the whole of "trigger, not filter".
    private var isConverging: Bool = false
    private var lastUpdateTime: TimeInterval = -.greatestFiniteMagnitude

    init(maxOffsetDeg: Double = 180.0,
         responseToleranceFromOne: Double = 0.3,
         minResponseCorrelation: Double = 0.8,
         maxHeadingAccuracyDeg: Double = 25.0,
         minUpdateInterval: TimeInterval = 1.0,
         deadbandDeg: Double = 1.5,
         maxSlewPerUpdateDeg: Double = 1.0,
         maxDispersionDeg: Double = 12.0) {
        self.maxOffsetDeg = maxOffsetDeg
        self.responseToleranceFromOne = responseToleranceFromOne
        self.minResponseCorrelation = minResponseCorrelation
        self.maxHeadingAccuracyDeg = maxHeadingAccuracyDeg
        self.minUpdateInterval = minUpdateInterval
        self.deadbandDeg = deadbandDeg
        self.maxSlewPerUpdateDeg = maxSlewPerUpdateDeg
        self.maxDispersionDeg = maxDispersionDeg
    }

    /// Why an update did nothing. Recorded rather than returned as a bare nil so a log can say which
    /// gate is holding — "no correction" and "no correction *because the compass is track-slaved*"
    /// are very different states to read back afterwards.
    enum Refusal: String {
        case airborne
        case worldUnusable
        case noMedian
        /// The compass is following the phone but cannot agree with itself: the readings behind
        /// the median are spread too widely to act on. Distinct from `compassNotMeasuringPhone`,
        /// which is the compass reporting something that is not the phone at all.
        case dispersed
        case compassNotMeasuringPhone
        case headingInaccurate
        case implausibleOffset
        case rateLimited
        case withinDeadband
    }

    enum Outcome: Equatable {
        case applied(Double)
        case refused(Refusal)
    }

    /// Feed the current measurements and get back what was done. `appliedOffsetDeg` is unchanged on
    /// every refusal — including `airborne`, which freezes the last ground value rather than
    /// discarding it: the ARKit world survives takeoff, so a correction measured minutes ago is
    /// still the better estimate, it just stops being updated by a sensor that no longer measures
    /// the phone.
    @discardableResult
    mutating func update(medianErrorDeg: Double?,
                         dispersionDeg: Double?,
                         compassResponse: Double,
                         compassResponseR: Double,
                         headingAccuracyDeg: Double,
                         airborne: Bool,
                         worldUsable: Bool,
                         at time: TimeInterval) -> Outcome {
        guard !airborne else { return .refused(.airborne) }
        guard worldUsable else { return .refused(.worldUnusable) }
        guard let median = medianErrorDeg, median.isFinite else { return .refused(.noMedian) }
        // Asked before the response gate, and deliberately: a compass that is following the phone
        // but disagreeing with itself is a different fault from one reporting the aircraft, and the
        // log is only useful if it names the right one.
        if let dispersion = dispersionDeg, dispersion.isFinite, dispersion > maxDispersionDeg {
            return .refused(.dispersed)
        }
        guard compassResponse.isFinite, compassResponseR.isFinite,
              abs(compassResponse - 1.0) <= responseToleranceFromOne,
              abs(compassResponseR) >= minResponseCorrelation
        else { return .refused(.compassNotMeasuringPhone) }
        guard headingAccuracyDeg >= 0, headingAccuracyDeg <= maxHeadingAccuracyDeg
        else { return .refused(.headingInaccurate) }
        guard abs(median) <= maxOffsetDeg else { return .refused(.implausibleOffset) }
        guard time - lastUpdateTime >= minUpdateInterval else { return .refused(.rateLimited) }

        let delta = median - appliedOffsetDeg
        // Asked only of a correction that is not already running. A move that has started is
        // finished, because a move abandoned inside the band leaves precisely the band's worth of
        // standing error behind it — see `deadbandDeg`.
        if !isConverging {
            guard abs(delta) >= deadbandDeg || !hasOffset else { return .refused(.withinDeadband) }
        }

        lastUpdateTime = time
        let step = min(abs(delta), maxSlewPerUpdateDeg) * (delta < 0 ? -1.0 : 1.0)
        appliedOffsetDeg += step
        hasOffset = true
        // Arrived when the step covered the whole remaining gap, which re-arms the deadband.
        // Decided on the gap rather than on the new residual: that residual is the difference of
        // two nearly equal doubles and is not reliably zero even when the move is exactly done.
        isConverging = abs(delta) > maxSlewPerUpdateDeg
        return .applied(appliedOffsetDeg)
    }

    /// Start from an offset somebody else established, so the slew limit only has the *residual* to
    /// walk off rather than the whole thing.
    ///
    /// Build 33 primes this with `StartupSeed`'s value. Without it the correction would begin at 0
    /// and crawl toward the seed's offset at 1°/s — minutes, for an offset the seed already had
    /// within a second. Primed, the two compose the way they are meant to: the seed gets the world
    /// roughly right immediately, and the rolling median refines it.
    mutating func prime(offsetDeg: Double) {
        guard offsetDeg.isFinite else { return }
        appliedOffsetDeg = offsetDeg
        hasOffset = true
        // Somebody else's absolute measurement, not a move in progress, so the deadband gates the
        // next one normally.
        isConverging = false
        lastUpdateTime = -.greatestFiniteMagnitude
    }

    /// Clear with the world. The offset describes one ARKit session's frame and means nothing about
    /// the next one.
    mutating func reset() {
        appliedOffsetDeg = 0
        hasOffset = false
        isConverging = false
        lastUpdateTime = -.greatestFiniteMagnitude
    }
}

/// Decides when to tell the user the alignment is available and has not been taken.
///
/// **Why this exists.** Across two flights the align button was offered on every healthy-tracking
/// row — 154 of 154 at FL402 — and was never tapped once, so `yaw_src` read `none` for both entire
/// flights. Every correction this app can make in the air depends on somebody saying which direction
/// is the nose, and nothing on the phone can say it: the cabin compass measures the aircraft's track
/// (`compass_response` 0.009 at FL402), and ARKit's own `.gravityAndHeading` seed inherits that same
/// compass. So the button has to ask, and asking is a scheduling problem rather than a sensing one.
///
/// The whole design is about not becoming noise. A prompt the user learns to dismiss is worse than
/// no prompt: it trains them past the one thing the app needs from them. So it fires when the
/// opportunity first appears, then rarely, then stops — and it goes silent the moment an offset
/// exists, because at that point there is nothing to ask for.
struct AlignPromptScheduler {

    /// Shortest gap between prompts. Five minutes is long enough that a declined prompt reads as
    /// declined rather than as a bug.
    let minIntervalSeconds: TimeInterval
    /// After this many, the user has decided. Stop.
    let maxPrompts: Int

    private(set) var promptCount: Int = 0
    private var lastPromptTime: TimeInterval = -.greatestFiniteMagnitude
    /// When the opportunity first appeared, so the log can say how long it went untaken.
    private(set) var firstAvailableTime: TimeInterval?

    init(minIntervalSeconds: TimeInterval = 300, maxPrompts: Int = 3) {
        self.minIntervalSeconds = minIntervalSeconds
        self.maxPrompts = maxPrompts
    }

    /// How long the alignment has been on offer, for the prompt's log line.
    func secondsAvailable(at time: TimeInterval) -> Double {
        guard let first = firstAvailableTime else { return 0 }
        return max(0, time - first)
    }

    /// Call from the display tick. True exactly on the ticks a prompt should be shown.
    mutating func shouldPrompt(available: Bool,
                               hasOffset: Bool,
                               capturing: Bool,
                               at time: TimeInterval) -> Bool {
        guard available else {
            // The opportunity going away resets the clock, so a prompt is not owed the instant it
            // returns — a flight that dips in and out of usable tracking must not prompt each time.
            firstAvailableTime = nil
            return false
        }
        if firstAvailableTime == nil { firstAvailableTime = time }

        // Nothing to ask for once an offset is in force, and nothing to ask for mid-capture.
        guard !hasOffset, !capturing else { return false }
        guard promptCount < maxPrompts else { return false }
        guard time - lastPromptTime >= minIntervalSeconds else { return false }

        lastPromptTime = time
        promptCount += 1
        return true
    }

    /// Clear with the world: a new ARKit session needs its own alignment, so it gets its own asking.
    mutating func reset() {
        promptCount = 0
        lastPromptTime = -.greatestFiniteMagnitude
        firstAvailableTime = nil
    }
}

/// Holds the world-yaw offset, and — **currently disabled, see the gain** — can carry it forward
/// through the aircraft's heading changes.
///
/// **Retracted in build 28.** This existed because build 25 read the FL317 log as saying ARKit's
/// world rides with the fuselage: over 71 seconds the aircraft turned 12.7° while ARKit's azimuth
/// moved 0.7°, which looks exactly like a cabin-locked frame. It was not. That reading had two
/// endpoints and no correlation behind it, and it is what an *Earth-locked* frame also produces when
/// the user happens to hold the phone on a fixed feature out of the window — the phone's Earth
/// azimuth then stays constant by construction, whatever the aircraft does. Non-discriminating
/// evidence, which is the mistake this project keeps making.
///
/// The FL362 log settled it with an actual turn — 30.6° of heading change over 110 s — and every
/// measure agrees that ARKit is **Earth-locked**:
///
/// | method | d(ARKit azimuth) / d(track) |
/// |---|---|
/// | least squares, n=103 | **0.893, r = 0.978** |
/// | endpoints | 1.023 |
/// | first third vs last third | 0.881 |
/// | `frame_lock` in-app | 0.696 |
/// | `follow_gain`, gyro-referenced and pan-immune | 0.129, i.e. Earth-locked on its own scale |
///
/// 1.0 means ARKit turns with the aircraft, so the offset an anchor measures is a **constant** and
/// following the track is not a correction but an injected error. In that same log following
/// accumulated −30.6° and dragged the applied offset from −35.5° to −66.1° — thirty degrees of pure
/// error added on top of an anchor the user had given correctly.
///
/// (The 0.11 shortfall below unity needs no mechanism. The phone is fuselage-referenced, so it
/// follows *heading*, while `track` carries the drift angle, which changes with wind through a 30°
/// turn. Not enough to build a partial gain on.)
///
/// **So `gain` is 0 and this applies nothing.** `followedDeg` still accumulates and is still logged,
/// as the counterfactual — what following *would* have added — so `follow_gain` keeps measuring the
/// one thing that would justify turning it back on. If a log ever shows a slope near 0 with a
/// correlation worth trusting, the gain goes back up, with evidence this time.
struct TrackFollowingYawOffset {

    /// Where the base offset came from. Recorded so a log can tell an automatic seed from a
    /// user-captured one without inferring it from timing.
    enum Source: String {
        /// StartupSeed, taken once when the world was created. The normal case from build 30.
        case seed
        case ground
        case anchor
    }

    /// Course accuracy past which `course` is not a direction worth integrating.
    let maxCourseAccuracyDeg: Double
    /// Below this the aircraft is not going anywhere in particular and `course` is noise.
    let minGroundSpeedKt: Double
    /// Fastest plausible heading change. Anything above this in one increment is a GPS course
    /// glitch, not a turn — a 737 rolled to 30° at 440 kt turns about 3 °/s.
    let maxTurnRateDps: Double
    /// After this long without a usable sample, re-baseline instead of accumulating. Swallowing an
    /// unknown amount of turning as one step would be worse than under-correcting.
    let maxGapSeconds: TimeInterval
    /// **Zero, and the measurement above is why.** How much of the accumulated heading change to add
    /// to the base offset: 0 holds the offset constant, which is what an Earth-locked ARKit needs;
    /// 1 would fully follow the aircraft, which is what build 25 shipped and what cost 30°.
    /// Configurable rather than deleted so the tests can still exercise the accumulator, and so
    /// turning it back on is a one-number change if a future log ever earns it.
    let gain: Double

    private(set) var baseOffsetDeg: Double = 0
    /// Heading change accumulated since the seed, unwrapped. With `gain` at 0 this is a pure
    /// counterfactual — what following would have added — kept so the log can still show it.
    private(set) var followedDeg: Double = 0
    private(set) var source: Source?
    private var lastTrackDeg: Double = -1
    private var lastSampleTime: TimeInterval = -.greatestFiniteMagnitude

    init(maxCourseAccuracyDeg: Double = 5.0,
         minGroundSpeedKt: Double = 80.0,
         maxTurnRateDps: Double = 6.0,
         maxGapSeconds: TimeInterval = 30.0,
         gain: Double = 0.0) {
        self.maxCourseAccuracyDeg = maxCourseAccuracyDeg
        self.minGroundSpeedKt = minGroundSpeedKt
        self.maxTurnRateDps = maxTurnRateDps
        self.maxGapSeconds = maxGapSeconds
        self.gain = gain
    }

    /// The offset to apply, or nil while nothing has been seeded. At `gain` 0 this is exactly what
    /// the last anchor measured, held constant.
    var offsetDeg: Double? {
        guard source != nil else { return nil }
        return TrackFollowingYawOffset.wrap180(baseOffsetDeg + gain * followedDeg)
    }

    var hasSeed: Bool { source != nil }

    /// Take a fresh absolute measurement as the new base and start following from this heading.
    mutating func seed(offsetDeg: Double, trackDeg: Double, source: Source, at time: TimeInterval) {
        baseOffsetDeg = offsetDeg
        followedDeg = 0
        self.source = source
        lastTrackDeg = trackDeg
        lastSampleTime = time
    }

    /// What the offset would be if a fresh measurement said `candidate` — used to compare a new
    /// anchor against what following predicts, without disturbing the current state.
    func disagreementDeg(with candidateOffsetDeg: Double) -> Double? {
        guard let current = offsetDeg else { return nil }
        return TrackFollowingYawOffset.wrap180(candidateOffsetDeg - current)
    }

    /// Feed the current GPS course. Accumulates the increment since the last accepted sample.
    ///
    /// Increments are accumulated, never differenced against the seed's heading: a flight that turns
    /// through more than 180° would wrap and invert the correction. Each increment is small, so no
    /// wrap ambiguity arises.
    ///
    /// Returns true when this sample was accumulated, false when it was rejected or re-baselined.
    @discardableResult
    mutating func update(trackDeg: Double,
                         courseAccuracyDeg: Double,
                         groundSpeedKt: Double,
                         at time: TimeInterval) -> Bool {
        guard source != nil else { return false }
        guard trackDeg >= 0, trackDeg.isFinite,
              courseAccuracyDeg >= 0, courseAccuracyDeg <= maxCourseAccuracyDeg,
              groundSpeedKt >= minGroundSpeedKt
        else { return false }

        let dt = time - lastSampleTime
        guard lastTrackDeg >= 0, dt > 0, dt <= maxGapSeconds else {
            // First sample after a seed with no heading, or a long blackout: start from here rather
            // than booking an unknown amount of turning as one step.
            lastTrackDeg = trackDeg
            lastSampleTime = time
            return false
        }

        let delta = TrackFollowingYawOffset.wrap180(trackDeg - lastTrackDeg)
        guard abs(delta) <= maxTurnRateDps * dt else {
            // A jump no aircraft could fly. Re-baseline on it rather than accumulating it, and
            // rather than pinning lastTrack to a value the aircraft has already left.
            lastTrackDeg = trackDeg
            lastSampleTime = time
            return false
        }

        followedDeg += delta
        lastTrackDeg = trackDeg
        lastSampleTime = time
        return true
    }

    /// Clear with the world, or when the offset it carries is withdrawn.
    mutating func clear() {
        baseOffsetDeg = 0
        followedDeg = 0
        source = nil
        lastTrackDeg = -1
        lastSampleTime = -.greatestFiniteMagnitude
    }

    static func wrap180(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}

/// Integrates the device gyro's vertical-axis rate into an azimuth, so ARKit's azimuth can be
/// compared against an inertial one.
///
/// **What this buys.** The gyro is inertial: it senses the aircraft's turn whether or not ARKit
/// does. So with ARKit's azimuth, the gyro's, and GPS track all in hand,
///
///     gain = (Δgyro − ΔARKit) / Δtrack
///
/// is 1 when ARKit rides with the cabin and 0 when it stays Earth-locked — and, unlike `frame_lock`,
/// it assumes **nothing about the phone being held still**, because a pan moves Δgyro and ΔARKit
/// together and cancels out of the numerator. That is what makes it worth adding: `frame_lock` on
/// the FL317 log read 0.225 at r=0.05, no signal at all, in exactly the regime that mattered.
///
/// Absolute value is meaningless — gyro bias walks it away over minutes. Only differences over tens
/// of seconds are used, which is what the regression consumes.
struct GyroAzimuthIntegrator {

    /// Rates below this are bias and vibration rather than rotation, and integrating them is what
    /// makes a gyro walk. A cruise turn is 0.2 °/s, so the floor has to sit well under that.
    let deadbandDps: Double
    /// A gap longer than this means device motion stopped reporting; integrating across it would
    /// invent rotation that may or may not have happened.
    let maxGapSeconds: TimeInterval

    private(set) var azimuthDeg: Double = 0
    private(set) var hasSamples: Bool = false
    private var lastTime: TimeInterval = -.greatestFiniteMagnitude

    init(deadbandDps: Double = 0.05, maxGapSeconds: TimeInterval = 1.0) {
        self.deadbandDps = deadbandDps
        self.maxGapSeconds = maxGapSeconds
    }

    /// Feed one vertical-axis yaw rate, in degrees per second. NaN (device motion not reporting)
    /// breaks the integration rather than contributing zero.
    mutating func add(yawRateDps: Double, at time: TimeInterval) {
        // The clock advances even when the sample is unusable, so the next interval starts here
        // rather than spanning — and silently integrating across — the part we could not measure.
        let dt = time - lastTime
        lastTime = time
        guard yawRateDps.isFinite, dt > 0, dt <= maxGapSeconds else { return }
        hasSamples = true
        guard abs(yawRateDps) >= deadbandDps else { return }
        azimuthDeg += yawRateDps * dt
    }

    mutating func reset() {
        azimuthDeg = 0
        hasSamples = false
        lastTime = -.greatestFiniteMagnitude
    }
}
