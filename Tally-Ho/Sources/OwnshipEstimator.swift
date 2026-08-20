//
//  OwnshipEstimator.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Single source of truth for where the user is, how fast they are moving, and how high.
//
//  Why this exists: position, velocity and timestamp used to be written by two independent
//  paths. The phone's CLLocation callback wrote position + velocity + the phone fix's
//  timestamp, while the 4 Hz UI tick separately overwrote the position with the ADS-B
//  ownship coordinate and left the timestamp and velocity untouched. Dead reckoning then
//  extrapolated a fresh ADS-B position by the time elapsed since an older phone fix, using
//  the phone's course — double-counting motion, and running on stale velocity entirely when
//  the phone's GPS was gated out inside a fuselage.
//
//  Here each source keeps its own timestamp and its own velocity, one source is chosen per
//  snapshot, and extrapolation always uses that source's own state. ADS-B ownship reports
//  arrive at ~1 Hz with their own ground speed and track, so they can be coasted correctly
//  between reports instead of being resampled by the UI tick.
//
//  Altitude is carried in both vertical datums (geometric and pressure) with validity flags.
//  Placement still uses `displayAltitudeFt`, which reproduces the previous selection exactly —
//  choosing between the datums is a separate change with its own field validation.
//

import Foundation
import CoreLocation

// MARK: - Source

enum OwnshipSource: String {
    case none  = "none"
    case adsb  = "ADS-B GPS"
    case phone = "iPhone GPS"
}

// MARK: - Pressurization

/// How far a cabin-sourced pressure altitude may sit from GPS geometric altitude before the
/// cabin is judged to be pressurized.
///
/// On an unpressurized aircraft the two differ only by the local altimeter setting and
/// temperature deviation from standard: a very low QNH plus a cold day reaches roughly 1,500 ft,
/// so 2,000 ft leaves margin without admitting a real pressurized cabin, where the difference
/// runs to tens of thousands of feet.
///
/// Currently used only to display a verdict. Acting on it — switching which vertical datum
/// targets are placed against — is a separate change that ships with its own field validation.
enum PressurizationHeuristic {
    static let maxPlausibleDeltaFeet: Double = 2_000.0

    /// True when the cabin barometer disagrees with GPS by more than atmospheric conditions
    /// could explain, meaning it is measuring cabin pressure rather than outside static.
    static func isCabinPressurized(cabinPressureAltitudeFt: Double, geometricAltitudeFt: Double) -> Bool {
        abs(cabinPressureAltitudeFt - geometricAltitudeFt) > maxPlausibleDeltaFeet
    }
}

// MARK: - Snapshot

/// An immutable estimate of ownship state at one instant, safe to read off any thread.
struct OwnshipSnapshot {
    var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var hasPosition: Bool = false
    var source: OwnshipSource = .none

    /// Horizontal accuracy of the underlying fix in metres; negative when unknown.
    var horizontalAccuracyM: Double = -1
    /// Age of the underlying fix at the moment this snapshot was taken.
    var fixAge: TimeInterval = 0
    /// True when `coordinate` was extrapolated forward from the fix rather than reported.
    var wasDeadReckoned: Bool = false

    var groundSpeedKt: Double = 0
    var trackDeg: Double = 0
    var hasVelocity: Bool = false
    var verticalRateFpm: Double = 0

    /// Altitude used for AR placement and range filtering (feet).
    var displayAltitudeFt: Double = 0

    // Both vertical datums, carried for diagnostics and for frame-aware placement later.
    /// Geometric altitude referenced to mean sea level (feet).
    var geometricAltitudeFt: Double = 0
    var hasGeometricAltitude: Bool = false
    /// Pressure altitude against the 29.92 inHg standard datum (feet).
    var pressureAltitudeFt: Double = 0
    var hasPressureAltitude: Bool = false
    /// Where the pressure altitude came from, which decides whether it can be trusted in a
    /// pressurized cabin: a cabin-side barometer measures cabin pressure, not outside static.
    var pressureAltitudeIsCabinSourced: Bool = false

    /// Height of the geoid above the WGS-84 ellipsoid at the current position (feet),
    /// derived from the phone reporting both MSL and ellipsoidal altitude. Lets an
    /// ADS-B geometric altitude (which is ellipsoid-referenced) be converted to MSL.
    var geoidSeparationFt: Double = 0
    var hasGeoidSeparation: Bool = false
}

// MARK: - Estimator

final class OwnshipEstimator {

    /// An ADS-B ownship report older than this is considered stale and the phone takes over.
    /// Receivers report at ~1 Hz, so this tolerates a single dropped report.
    static let adsbFreshnessLimit: TimeInterval = 2.0

    /// Dead reckoning is capped here. Brief GPS outages inside a fuselage last a few seconds;
    /// beyond this the constant-velocity assumption is no longer worth trusting.
    static let maxDeadReckonSeconds: TimeInterval = 5.0

    /// Below this speed extrapolation is noise, so the reported position is used as-is.
    static let minDeadReckonSpeedKt: Double = 5.0

    private let lock = NSLock()

    // MARK: ADS-B state

    private var adsbCoordinate: CLLocationCoordinate2D?
    private var adsbFixTime: Date = .distantPast
    private var adsbGroundSpeedKt: Double = 0
    private var adsbTrackDeg: Double = 0
    private var adsbHasVelocity: Bool = false
    private var adsbVerticalRateFpm: Double = 0

    private var adsbPressureAltitudeFt: Double?
    private var adsbPressureAltitudeTime: Date = .distantPast

    private var adsbEllipsoidalAltitudeFt: Double?
    private var adsbGeometricAltitudeTime: Date = .distantPast

    // MARK: Phone state

    private var phoneCoordinate: CLLocationCoordinate2D?
    private var phoneFixTime: Date = .distantPast
    private var phoneHorizontalAccuracyM: Double = -1
    private var phoneGroundSpeedKt: Double = 0
    private var phoneTrackDeg: Double = 0
    private var phoneHasVelocity: Bool = false

    /// Barometrically-smoothed MSL altitude maintained by the view controller.
    private var phoneFusedAltitudeFt: Double = 0
    private var phoneHasFusedAltitude: Bool = false
    /// Pressure altitude derived from the phone's absolute barometer (cabin-sourced).
    private var phonePressureAltitudeFt: Double?
    private var phoneGeoidSeparationFt: Double?

    // MARK: - Ingest: ADS-B

    /// Feed an ADS-B ownship report. Called straight off the receiver's parsing queue so the
    /// report keeps its own arrival time rather than being resampled by the UI tick.
    func ingestADSBOwnship(
        coordinate: CLLocationCoordinate2D?,
        pressureAltitudeFt: Double?,
        groundSpeedKt: Double?,
        trackDeg: Double?,
        verticalRateFpm: Double?,
        timestamp: Date
    ) {
        lock.lock()
        defer { lock.unlock() }

        if let coordinate, coordinate.latitude != 0 || coordinate.longitude != 0 {
            adsbCoordinate = coordinate
            adsbFixTime    = timestamp
        }
        if let pressureAltitudeFt {
            adsbPressureAltitudeFt   = pressureAltitudeFt
            adsbPressureAltitudeTime = timestamp
        }
        if let groundSpeedKt, let trackDeg {
            adsbGroundSpeedKt = groundSpeedKt
            adsbTrackDeg      = trackDeg
            adsbHasVelocity   = true
        }
        if let verticalRateFpm {
            adsbVerticalRateFpm = verticalRateFpm
        }
    }

    /// Feed the receiver's geometric (ellipsoid-referenced) altitude from message 0x0B.
    func ingestADSBGeometricAltitude(heightAboveEllipsoidFt: Double, timestamp: Date) {
        lock.lock()
        defer { lock.unlock() }
        adsbEllipsoidalAltitudeFt  = heightAboveEllipsoidFt
        adsbGeometricAltitudeTime  = timestamp
    }

    /// Drop ADS-B state when the link goes away, so a stale ownship position cannot be
    /// selected once the receiver has stopped reporting.
    func clearADSB() {
        lock.lock()
        defer { lock.unlock() }
        adsbCoordinate = nil
        adsbFixTime = .distantPast
        adsbHasVelocity = false
        adsbPressureAltitudeFt = nil
        adsbEllipsoidalAltitudeFt = nil
    }

    // MARK: - Ingest: phone

    func ingestPhoneLocation(
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracyM: Double,
        groundSpeedKt: Double?,
        trackDeg: Double?,
        timestamp: Date
    ) {
        lock.lock()
        defer { lock.unlock() }
        phoneCoordinate          = coordinate
        phoneFixTime             = timestamp
        phoneHorizontalAccuracyM = horizontalAccuracyM
        if let groundSpeedKt, let trackDeg {
            phoneGroundSpeedKt = groundSpeedKt
            phoneTrackDeg      = trackDeg
            phoneHasVelocity   = true
        }
    }

    /// The barometrically-smoothed MSL altitude the view controller maintains.
    func ingestPhoneAltitude(fusedMSLFt: Double) {
        lock.lock()
        defer { lock.unlock() }
        phoneFusedAltitudeFt   = fusedMSLFt
        phoneHasFusedAltitude  = true
    }

    /// Pressure altitude from the phone's absolute barometer, and the local geoid separation
    /// derived from the phone reporting MSL and ellipsoidal altitude for the same fix.
    func ingestPhoneVerticalReferences(pressureAltitudeFt: Double?, geoidSeparationFt: Double?) {
        lock.lock()
        defer { lock.unlock() }
        if let pressureAltitudeFt { phonePressureAltitudeFt = pressureAltitudeFt }
        if let geoidSeparationFt  { phoneGeoidSeparationFt  = geoidSeparationFt }
    }

    // MARK: - Query

    /// Best estimate of ownship state, dead-reckoned to `date` from whichever source is
    /// currently authoritative. Safe to call from the render thread.
    func snapshot(at date: Date = Date()) -> OwnshipSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = OwnshipSnapshot()

        // ── Source selection ───────────────────────────────────────────────────────────
        // ADS-B wins while its reports are fresh: its GNSS receiver has an unobstructed
        // antenna, while the phone is inside the cabin.
        let adsbAge = date.timeIntervalSince(adsbFixTime)
        let adsbUsable = adsbCoordinate != nil
            && adsbAge >= 0
            && adsbAge <= OwnshipEstimator.adsbFreshnessLimit

        if adsbUsable, let coordinate = adsbCoordinate {
            snapshot.source              = .adsb
            snapshot.hasPosition         = true
            snapshot.coordinate          = coordinate
            snapshot.horizontalAccuracyM = -1          // GDL90 reports NIC/NACp, not metres
            snapshot.fixAge              = adsbAge
            snapshot.groundSpeedKt       = adsbGroundSpeedKt
            snapshot.trackDeg            = adsbTrackDeg
            snapshot.hasVelocity         = adsbHasVelocity
            snapshot.verticalRateFpm     = adsbVerticalRateFpm
        } else if let coordinate = phoneCoordinate {
            let phoneAge = date.timeIntervalSince(phoneFixTime)
            snapshot.source              = .phone
            snapshot.hasPosition         = true
            snapshot.coordinate          = coordinate
            snapshot.horizontalAccuracyM = phoneHorizontalAccuracyM
            snapshot.fixAge              = max(0, phoneAge)
            snapshot.groundSpeedKt       = phoneGroundSpeedKt
            snapshot.trackDeg            = phoneTrackDeg
            snapshot.hasVelocity         = phoneHasVelocity
        }

        // ── Dead reckoning, always from the chosen source's own fix time and velocity ──
        if snapshot.hasPosition,
           snapshot.hasVelocity,
           snapshot.groundSpeedKt > OwnshipEstimator.minDeadReckonSpeedKt,
           snapshot.fixAge > 0,
           snapshot.fixAge < OwnshipEstimator.maxDeadReckonSeconds {
            let predicted = CalculationsLogic.predictPosition(
                currentCoord:    snapshot.coordinate,
                currentAltitude: 0,
                track:           snapshot.trackDeg,
                groundSpeed:     snapshot.groundSpeedKt,
                verticalRate:    0,
                timeSeconds:     snapshot.fixAge
            )
            snapshot.coordinate      = predicted.coordinate
            snapshot.wasDeadReckoned = true
        }

        // ── Vertical datums ───────────────────────────────────────────────────────────
        if let separation = phoneGeoidSeparationFt {
            snapshot.geoidSeparationFt    = separation
            snapshot.hasGeoidSeparation   = true
        }

        // Geometric: prefer the receiver's GNSS altitude (converted from ellipsoidal to MSL
        // using the phone-derived geoid separation when available), else the phone's own.
        let adsbGeometricAge = date.timeIntervalSince(adsbGeometricAltitudeTime)
        if let hae = adsbEllipsoidalAltitudeFt,
           adsbGeometricAge >= 0,
           adsbGeometricAge <= OwnshipEstimator.adsbFreshnessLimit {
            snapshot.geometricAltitudeFt  = hae - (phoneGeoidSeparationFt ?? 0)
            snapshot.hasGeometricAltitude = true
        } else if phoneHasFusedAltitude {
            snapshot.geometricAltitudeFt  = phoneFusedAltitudeFt
            snapshot.hasGeometricAltitude = true
        }

        // Pressure: the receiver's 0x0A altitude is the aircraft's own static source when the
        // cabin is unpressurized; the phone's barometer is always cabin-sourced.
        let adsbPressureAge = date.timeIntervalSince(adsbPressureAltitudeTime)
        if let pressure = adsbPressureAltitudeFt,
           adsbPressureAge >= 0,
           adsbPressureAge <= OwnshipEstimator.adsbFreshnessLimit {
            snapshot.pressureAltitudeFt = pressure
            snapshot.hasPressureAltitude = true
            snapshot.pressureAltitudeIsCabinSourced = true
        } else if let pressure = phonePressureAltitudeFt {
            snapshot.pressureAltitudeFt = pressure
            snapshot.hasPressureAltitude = true
            snapshot.pressureAltitudeIsCabinSourced = true
        }

        // ── Display altitude ──────────────────────────────────────────────────────────
        // Deliberately reproduces the previous selection: the receiver's reported altitude
        // when it is fresh and valid, the phone's barometrically-smoothed MSL otherwise.
        // Choosing between datums by cabin pressurization is a separate, field-validated change.
        if let pressure = adsbPressureAltitudeFt,
           adsbPressureAge >= 0,
           adsbPressureAge <= OwnshipEstimator.adsbFreshnessLimit {
            snapshot.displayAltitudeFt = pressure
        } else {
            snapshot.displayAltitudeFt = phoneFusedAltitudeFt
        }

        return snapshot
    }

    /// True when ADS-B is currently the authoritative position source.
    func isUsingADSB(at date: Date = Date()) -> Bool {
        snapshot(at: date).source == .adsb
    }
}
