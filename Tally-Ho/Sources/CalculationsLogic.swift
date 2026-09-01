//
//  CalculationsLogic.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Handles all calculations for positioning AR objects based on real-world
//  GPS coordinates, altitudes, and distances
//

import Foundation
import CoreLocation
import ARKit
import SceneKit
import UIKit

/// Handles all positioning calculations for AR visualization
class CalculationsLogic {

    // MARK: - Constants

    /// Mean spherical Earth radius (metres) — used as a fallback.
    static let earthRadiusMean: Double = 6_371_000.0
    /// WGS84 ellipsoid semi-major axis (equatorial radius, metres).
    static let earthRadiusEquatorial: Double = 6_378_137.0
    /// WGS84 ellipsoid semi-minor axis (polar radius, metres).
    static let earthRadiusPolar: Double = 6_356_752.3142

    /// Approximate WGS84 Earth radius at a given geodetic latitude (radians).
    /// Uses the parametric (geocentric) formula; error < 0.1% across all latitudes.
    static func earthRadius(at latitudeRadians: Double) -> Double {
        let cosL = cos(latitudeRadians)
        let sinL = sin(latitudeRadians)
        let a = earthRadiusEquatorial, b = earthRadiusPolar
        let num = (a * a * cosL) * (a * a * cosL) + (b * b * sinL) * (b * b * sinL)
        let den = (a * cosL) * (a * cosL) + (b * sinL) * (b * sinL)
        return sqrt(num / den)
    }

    // Keep the legacy name for any callers that still reference it.
    static var earthRadiusMeters: Double { earthRadiusMean }

    static let feetToMeters: Double = 0.3048
    static let metersToFeet: Double = 3.28084
    static let nauticalMileToMeters: Double = 1852.0
    static let knotsToMetersPerSecond: Double = 0.514444

    // MARK: - Atmosphere

    /// Standard sea-level pressure of the ISA atmosphere, in hectopascals (29.92 inHg).
    static let isaSeaLevelPressureHPa: Double = 1013.25

    /// Convert an absolute static pressure to a pressure altitude in feet, against the
    /// standard 29.92 inHg datum — the same datum ADS-B targets report `alt_baro` against.
    ///
    /// Uses the ISA troposphere relation, valid to ~36,000 ft; above the tropopause it drifts
    /// from the true standard atmosphere, which is acceptable here because the value is used
    /// to compare two altitudes in the same datum rather than as an absolute reference.
    static func pressureAltitudeFeet(hectopascals: Double) -> Double? {
        guard hectopascals > 0, hectopascals.isFinite else { return nil }
        let ratio = hectopascals / isaSeaLevelPressureHPa
        return 145_366.45 * (1.0 - pow(ratio, 0.190284))
    }

    // MARK: - Distance Calculations

    /// Calculate distance between two coordinates in metres using the Haversine formula
    /// with a WGS84 latitude-dependent Earth radius for improved accuracy at
    /// non-equatorial latitudes (reduces error from ~0.3% to < 0.05%).
    static func distance(
        from coord1: CLLocationCoordinate2D,
        to coord2: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = coord1.latitude.toRadians()
        let lon1 = coord1.longitude.toRadians()
        let lat2 = coord2.latitude.toRadians()
        let lon2 = coord2.longitude.toRadians()

        let dLat = lat2 - lat1
        let dLon = lon2 - lon1

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) *
                sin(dLon / 2) * sin(dLon / 2)

        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        // Use the radius at the mean latitude of the two points
        let meanLat = (lat1 + lat2) / 2.0
        return earthRadius(at: meanLat) * c
    }

    /// Calculate distance in nautical miles
    static func distanceInNauticalMiles(
        from coord1: CLLocationCoordinate2D,
        to coord2: CLLocationCoordinate2D
    ) -> Double {
        let meters = distance(from: coord1, to: coord2)
        return meters / nauticalMileToMeters
    }

    // MARK: - Bearing Calculations

    /// Calculate bearing (true heading) from one coordinate to another
    /// Returns bearing in degrees (0-360)
    static func bearing(
        from coord1: CLLocationCoordinate2D,
        to coord2: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = coord1.latitude.toRadians()
        let lon1 = coord1.longitude.toRadians()
        let lat2 = coord2.latitude.toRadians()
        let lon2 = coord2.longitude.toRadians()

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) -
                sin(lat1) * cos(lat2) * cos(dLon)

        let bearing = atan2(y, x).toDegrees()

        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - AR Position Calculations

    /// Convert real-world position to AR scene position
    /// - Parameters:
    ///   - targetCoord: GPS coordinate of the target
    ///   - targetAltitude: Altitude of target in feet MSL
    ///   - userCoord: GPS coordinate of user (ownship)
    ///   - userAltitude: Altitude of user in feet MSL
    ///   - userHeading: True heading of user in degrees
    /// - Returns: SCNVector3 position for AR scene
    /// Convert a real-world GPS position into an ARKit scene vector.
    ///
    /// Coordinate system (ARWorldTrackingConfiguration, .gravityAndHeading):
    ///   +X = East   -X = West
    ///   +Y = Up     -Y = Down
    ///   -Z = north  +Z = south
    /// The scene is world-fixed — the device camera moves through it.
    /// We compute positions relative to the camera's current world position
    /// (passed in as `cameraWorldPosition`) so that all markers stay correctly
    /// placed even as the aircraft flies kilometres from the AR origin.
    ///
    /// **No rotation is applied to the bearing, and two attempts to apply one have now failed.**
    ///
    /// The first subtracted the local magnetic declination, on the premise that
    /// `.gravityAndHeading` aligns −Z to magnetic north. Measurement disproved it: ARKit's raw
    /// world azimuth tracks *true* heading, so the term rotated every marker clockwise by ~12.5°
    /// while correcting nothing.
    ///
    /// The second subtracted `compass − ARKit azimuth`, on the premise that `CLHeading`
    /// reports where the phone is pointing. In a cockpit it does not. Measured on two flights,
    /// at FL270 and FL450 on different headings: the phone rotated 523.6° while the compass
    /// rotated 59.9°, the regression slope of one on the other was +0.018, and the median gap
    /// between compass and GPS ground track was 0.00°. The compass was echoing the aircraft's
    /// track. Individual pans are starker still — the phone swinging 58° moved the compass 0.6°.
    /// Subtracting that "error" counter-rotated the scene against every pan, so the traffic slid
    /// back toward the nose whenever the user turned to look sideways.
    ///
    /// A consequence worth stating, because it is easy to quote the wrong number: **ARKit's own
    /// in-flight alignment error has never been measured.** `heading_delta_deg` is
    /// `compass − ARKit`, so where the compass reports the track that difference is the
    /// phone-to-nose angle plus ARKit's error, not ARKit's error. Earlier claims of "17.7° off,
    /// decaying to 3°" conflated the two and should not be repeated.
    ///
    /// Both premises shared a failure mode worth naming, since it has now cost two builds: the
    /// evidence offered for each was equally consistent with its opposite. "Targets displaced by
    /// about the declination" does not say whether the correction is missing or wrongly present
    /// — only the *direction* does. "The compass agrees with ground track" does not say whether
    /// the compass is accurate or merely reporting the track — only whether it *moves when the
    /// phone moves* does. Before any future term is added here, state the observation that would
    /// distinguish it from its opposite, and go and measure that.
    ///
    /// So a true GPS bearing maps straight across, and ARKit's world alignment error — whatever
    /// its true size — remains uncorrected. That is a smaller harm than a scene that will not
    /// hold still, and until `compass_response` and `frame_lock` say which regime the app is in,
    /// it is the only honest option.
    static func calculateARPosition(
        targetCoord: CLLocationCoordinate2D,
        targetAltitude: Double,
        userCoord: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double,                        // unused — kept for API compat
        cameraWorldPosition: SCNVector3 = .init(),  // camera's current position in the AR scene
        worldYawOffsetDeg: Double = 0               // ARKit world north minus true north
    ) -> SCNVector3 {

        let horizontalDistanceM = distance(from: userCoord, to: targetCoord)
        // ARKit's world north is off true north by worldYawOffsetDeg, so a direction placed at
        // angle d in ARKit coordinates appears in the real world at d + offset. To make the target
        // appear on its true bearing, place it at bearing − offset.
        //
        // Zero until a FlightDirectionAnchor capture succeeds, which only happens in the air: on
        // the ground ARKit's own .gravityAndHeading anchor is already correct, because there the
        // compass genuinely measures the phone.
        let bearingRad = (self.bearing(from: userCoord, to: targetCoord) - worldYawOffsetDeg).toRadians()

        // Horizontal offsets in world space (metres)
        let dx = Float(horizontalDistanceM * sin(bearingRad))   // East
        let dz = Float(-horizontalDistanceM * cos(bearingRad))  // North

        // Vertical offset: compute the true elevation angle, then project it
        // onto the AR scene using the *scaled* horizontal radius so that the
        // marker appears at the correct angle above/below the horizon.
        // ARComponentFactory clamps horizontal distance to [minARRadius, maxARRadius];
        // we apply the same clamping here so Y is consistent with X/Z.
        let minR = Double(ARComponentFactory.minARRadius)
        let maxR = Double(ARComponentFactory.maxARRadius)
        let arHorizR = max(minR, min(maxR, horizontalDistanceM))

        // True elevation angle from user to target (positive = above horizon)
        let altDiffM = (targetAltitude - userAltitude) * feetToMeters
        let elevationRad = atan2(altDiffM, max(horizontalDistanceM, 1.0))

        // Map the elevation angle onto the scaled AR horizontal radius.
        // Cap to ±45° (tan ≈ 1.0) so markers stay within vertical FoV.
        let clampedElev = max(-Double.pi / 4, min(Double.pi / 4, elevationRad))
        let arY = Float(arHorizR * tan(clampedElev))

        // All positions are expressed relative to the camera's current world
        // position, not the fixed AR origin. This is the key fix for flight:
        // as the plane flies, the camera moves through the scene; without this
        // offset every marker would drift to wherever the AR origin was
        // initialised (typically the airport where the app launched).
        return SCNVector3(
            cameraWorldPosition.x + dx,
            cameraWorldPosition.y + arY,
            cameraWorldPosition.z + dz
        )
    }

    /// Hard ceiling on dead-reckoning extrapolation: beyond this age we stop projecting
    /// the aircraft further forward and freeze it at the 20s-extrapolated point, rather
    /// than coasting in a straight line indefinitely.
    static let maxCoastSeconds: Double = 20.0

    /// Beyond this report age, a target is flagged "stale" in the UI (dashed ring) —
    /// still shown, but visually marked as not a fresh position fix.
    ///
    /// Deliberately equal to `maxCoastSeconds`, so the dashed ring means something true: below it
    /// the target is being dead-reckoned forward from its last report and its drawn position is a
    /// live estimate; at exactly this age `predictedPosition` stops projecting and freezes it.
    /// Dashed therefore reads as "this has stopped being extrapolated" rather than as an arbitrary
    /// age. The two constants must move together — see the test that pins them.
    ///
    /// It was 10 s against an 8 s internet fetch cadence (ConnectionLogic.swift): two seconds of
    /// margin. Every internet aircraft shares one fetch timestamp, so a single late or failed
    /// fetch tipped all hundred past the threshold at once and the whole display went dashed and
    /// snapped back — 11 rows out of 76 in one ground log. Two full fetch cycles of margin now.
    static let staleAircraftAgeSeconds: Double = maxCoastSeconds

    /// Whether an aircraft's last report is old enough to be flagged as stale in the UI.
    static func isStale(_ aircraft: Aircraft) -> Bool {
        -aircraft.lastUpdate.timeIntervalSinceNow > staleAircraftAgeSeconds
    }

    /// Predict where an aircraft will be `aheadSeconds` in the future,
    /// compensating for ADS-B report latency and network delay.
    /// Extrapolation is capped at `maxCoastSeconds` past the last report: beyond that
    /// the straight-line/constant-speed assumption is too likely to have diverged from
    /// a maneuvering aircraft's real position, so the prediction freezes at that point
    /// instead of continuing to coast indefinitely.
    static func predictedPosition(
        for aircraft: Aircraft,
        aheadSeconds: Double = 0
    ) -> (coordinate: CLLocationCoordinate2D, altitude: Double) {
        let age = -aircraft.lastUpdate.timeIntervalSinceNow  // seconds since last report
        let total = min(age + aheadSeconds, maxCoastSeconds)
        // A report with no usable direction must not be coasted: extrapolating along a
        // placeholder track of 0 would march the target due north at its ground speed.
        guard total > 0, aircraft.groundSpeed > 0, aircraft.hasValidTrack else {
            return (aircraft.coordinate, aircraft.altitude)
        }
        return predictPosition(
            currentCoord:   aircraft.coordinate,
            currentAltitude: aircraft.altitude,
            track:           aircraft.track,
            groundSpeed:     aircraft.groundSpeed,
            // Applying a climb rate to an altitude the source never reported would invent
            // vertical motion from a placeholder zero.
            verticalRate:    aircraft.hasValidAltitude ? aircraft.verticalRate : 0,
            timeSeconds:     total
        )
    }

    /// Altitude to draw a target at, in feet.
    ///
    /// When the source reported no usable altitude the target is placed at the viewer's own
    /// altitude, so it appears on the horizon in the correct direction rather than being sunk
    /// to 0 ft MSL — which at a high-elevation airport would put ground traffic far below the
    /// viewer's feet, in a direction no one is looking.
    static func placementAltitude(for aircraft: Aircraft, targetAltitude: Double, userAltitudeFt: Double) -> Double {
        aircraft.hasValidAltitude ? targetAltitude : userAltitudeFt
    }

    /// Calculate position for airport marker
    static func calculateAirportARPosition(
        airportCoord: CLLocationCoordinate2D,
        airportElevation: Double,
        userCoord: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double,
        cameraWorldPosition: SCNVector3 = .init(),
        worldYawOffsetDeg: Double = 0
    ) -> SCNVector3 {
        return calculateARPosition(
            targetCoord: airportCoord,
            targetAltitude: airportElevation,
            userCoord: userCoord,
            userAltitude: userAltitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraWorldPosition,
            worldYawOffsetDeg: worldYawOffsetDeg
        )
    }

    // MARK: - Coordinate Filtering

    /// Filter airports within specified range, using a fast lat/lon bounding-box
    /// pre-check to skip expensive Haversine for obviously-distant airports.
    static func filterAirportsInRange(
        airports: [Airport],
        userCoord: CLLocationCoordinate2D,
        maxRangeNauticalMiles: Double
    ) -> [Airport] {
        let maxRangeMeters = maxRangeNauticalMiles * nauticalMileToMeters
        // 1° latitude ≈ 111,320 m — conservative (slightly over-includes near poles).
        let latDegrees  = maxRangeMeters / 111_320.0
        // Longitude degrees shrink with latitude — use cos(lat) for a tight box.
        let lonDegrees  = maxRangeMeters / (111_320.0 * max(cos(userCoord.latitude.toRadians()), 0.01))

        let minLat = userCoord.latitude  - latDegrees
        let maxLat = userCoord.latitude  + latDegrees
        let minLon = userCoord.longitude - lonDegrees
        let maxLon = userCoord.longitude + lonDegrees

        return airports.filter { airport in
            // Cheap bounding-box rejection first.
            guard airport.latitude  >= minLat && airport.latitude  <= maxLat,
                  airport.longitude >= minLon && airport.longitude <= maxLon
            else { return false }
            // Exact Haversine only for candidates that passed the box check.
            return distanceInNauticalMiles(from: userCoord, to: airport.coordinate) <= maxRangeNauticalMiles
        }
    }

    // MARK: - Velocity Vector Calculations

    /// Calculate future position based on current velocity
    static func predictPosition(
        currentCoord: CLLocationCoordinate2D,
        currentAltitude: Double,
        track: Double, // in degrees
        groundSpeed: Double, // in knots
        verticalRate: Double, // in feet per minute
        timeSeconds: Double
    ) -> (coordinate: CLLocationCoordinate2D, altitude: Double) {

        // Convert ground speed to meters per second
        let speedMPS = groundSpeed * knotsToMetersPerSecond

        // Calculate distance traveled
        let distanceMeters = speedMPS * timeSeconds

        // Calculate new position using bearing and distance
        let newCoord = coordinateOffset(
            from: currentCoord,
            bearing: track,
            distanceMeters: distanceMeters
        )

        // Calculate new altitude
        let verticalRateMPS = verticalRate * feetToMeters / 60.0
        let newAltitude = currentAltitude + (verticalRateMPS * timeSeconds / feetToMeters)

        return (newCoord, newAltitude)
    }

    /// Calculate a new coordinate offset by distance and bearing, using a
    /// WGS84 latitude-dependent Earth radius for improved accuracy.
    private static func coordinateOffset(
        from coord: CLLocationCoordinate2D,
        bearing: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {

        let bearingRad = bearing.toRadians()
        let lat1 = coord.latitude.toRadians()
        let lon1 = coord.longitude.toRadians()

        // Use the local Earth radius at the departure latitude
        let R = earthRadius(at: lat1)
        let angularDistance = distanceMeters / R

        let lat2 = asin(
            sin(lat1) * cos(angularDistance) +
            cos(lat1) * sin(angularDistance) * cos(bearingRad)
        )

        let lon2 = lon1 + atan2(
            sin(bearingRad) * sin(angularDistance) * cos(lat1),
            cos(angularDistance) - sin(lat1) * sin(lat2)
        )

        return CLLocationCoordinate2D(
            latitude: lat2.toDegrees(),
            longitude: lon2.toDegrees()
        )
    }
}

// MARK: - Vertical Datum Offset

/// Measures the local conversion between pressure altitude and geometric altitude from the
/// traffic picture itself.
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
    /// banked only if that integral stays small. `isTracking` false ends the current run, since
    /// ARKit's azimuth means nothing then.
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
        // Trapezoid over the interval since the last sample. Signed, so vibration cancels.
        runGyroNetDeg += gyroYawRateDps * (time - runLastTime)
        runLastTime = time
        runLastAzimuth = azimuthDeg
        // A run that has already rotated too far cannot be rescued by continuing, and letting it
        // run on would bank a contaminated stretch the moment it passed the duration minimum.
        if abs(runGyroNetDeg) > maxGyroNetDeg {
            runStartTime = nil
            runGyroNetDeg = 0
        }
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
    /// How far the phone may wander over the hold. Generous, because a handheld phone at arm's
    /// length in turbulence will not sit still — and the median absorbs the wander anyway. This is
    /// here to reject a *pan*, not to demand a tripod.
    let maxAzimuthSpreadDeg: Double
    /// How far the ground track may move. Tight: if the aircraft turned during the hold then the
    /// samples were taken against different references and the median of them means nothing.
    let maxTrackSpreadDeg: Double

    private var startTime: TimeInterval?
    private var samples: [(t: TimeInterval, offset: Double, az: Double, track: Double)] = []

    init(minSeconds: TimeInterval = 3.0,
         minSamples: Int = 8,
         maxAzimuthSpreadDeg: Double = 25.0,
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

/// Whether ARKit's world is established enough that a marker drawn in it means anything.
///
/// Target nodes are repositioned every frame from the live camera transform, which is what makes
/// ARKit's translation error cancel out. The cost is that when the transform is *not* yet
/// meaningful, the markers ride it: a build-20 relocalization had `cam_yaw_deg` swinging
/// 176.9 → −108.3 → −65.3 → −74.1, and the user sees traffic swing with it for 1.4 s at every app
/// open and about 5 s on an airborne resume.
///
/// The split is between "there is no world yet" and "there is a world, of degraded quality":
///
/// - `.initializing` and `.relocalizing` mean no usable world — nothing drawn in it is placed.
/// - `.excessiveMotion` and `.insufficientFeatures` mean the world exists and tracking is noisy.
///   Blanking the display every time the phone is moved briskly would be far worse than a marker
///   that wobbles, so these stay usable.
/// - `.notAvailable` has nothing at all.
func worldIsUsableForDisplay(_ state: ARCamera.TrackingState) -> Bool {
    switch state {
    case .normal:
        return true
    case .notAvailable:
        return false
    case .limited(let reason):
        switch reason {
        case .initializing, .relocalizing:            return false
        case .excessiveMotion, .insufficientFeatures: return true
        @unknown default:                             return true
        }
    @unknown default:
        return true
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

    /// Clear after a re-anchor. Without this the large readings that *caused* a reset would still
    /// be in the window afterwards and would immediately demand another.
    mutating func reset() {
        samples.removeAll()
        lastSampleTime = -.greatestFiniteMagnitude
    }
}

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

///
/// Aircraft report `alt_baro` against the 29.92 inHg standard datum and `alt_geom` against the
/// WGS-84 ellipsoid. Their difference is the local offset produced by the actual altimeter
/// setting and by temperature deviation from standard — the same offset that applies to the
/// viewer. Every aircraft nearby that reports both is therefore measuring it for us, which is
/// a better local estimate than any single station's altimeter setting.
///
/// The median is used rather than the mean because a handful of aircraft report a stale or
/// mis-set value, and the interquartile spread says how much the sample can be trusted: a
/// tight spread means the aircraft agree, a wide one means the sample is contaminated.
///
/// Currently measured and logged only. Applying it to target placement is the next phase.
enum AltitudeDatumOffset {

    struct Estimate {
        /// How many aircraft contributed a usable pair.
        var sampleCount: Int
        /// Geometric minus pressure altitude, in feet. Positive means geometric reads higher.
        var medianFt: Double
        var lowerQuartileFt: Double
        var upperQuartileFt: Double

        /// Interquartile spread. Small means the contributing aircraft agree with each other.
        var spreadFt: Double { upperQuartileFt - lowerQuartileFt }
    }

    /// Per-aircraft geometric-minus-pressure differences, for aircraft reporting both.
    static func offsets(from aircraft: [Aircraft]) -> [Double] {
        aircraft.compactMap { ac in
            guard let geometric = ac.geometricAltitudeFt,
                  let pressure  = ac.pressureAltitudeFt else { return nil }
            let difference = geometric - pressure
            // Reject values no atmosphere could produce; those are mis-set or stale reports.
            guard abs(difference) <= maxPlausibleOffsetFt else { return nil }
            return difference
        }
    }

    /// Widest offset attributable to altimeter setting plus temperature deviation. Beyond this
    /// the pair is a data error rather than an atmosphere.
    static let maxPlausibleOffsetFt: Double = 5_000.0

    static func estimate(from aircraft: [Aircraft]) -> Estimate? {
        let values = offsets(from: aircraft).sorted()
        guard !values.isEmpty else { return nil }
        return Estimate(
            sampleCount: values.count,
            medianFt: percentile(values, 0.50),
            lowerQuartileFt: percentile(values, 0.25),
            upperQuartileFt: percentile(values, 0.75)
        )
    }

    /// Nearest-rank percentile of an already-sorted array.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = max(0.0, min(1.0, fraction))
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }
}

// MARK: - Airport Data Structure

struct Airport: Identifiable {
    let id: String // ICAO code
    let icao: String
    let name: String
    let type: String // e.g. "large_airport", "medium_airport", "small_airport", "heliport", etc.
    let latitude: Double
    let longitude: Double
    let elevation: Double // in feet MSL

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Extensions

extension Double {
    func toRadians() -> Double {
        return self * .pi / 180.0
    }

    func toDegrees() -> Double {
        return self * 180.0 / .pi
    }
}

extension Float {
    func toRadians() -> Float {
        return self * .pi / 180.0
    }

    func toDegrees() -> Float {
        return self * 180.0 / .pi
    }
}
