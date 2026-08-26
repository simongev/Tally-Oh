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
        cameraWorldPosition: SCNVector3 = .init()   // camera's current position in the AR scene
    ) -> SCNVector3 {

        let horizontalDistanceM = distance(from: userCoord, to: targetCoord)
        let bearingRad = self.bearing(from: userCoord, to: targetCoord).toRadians()

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

    /// Beyond this report age, a target is flagged "stale" in the UI (dashed ring) —
    /// still shown and dead-reckoned, but visually marked as not a fresh position fix.
    /// Chosen to clear the internet-source 8s fetch cadence (ConnectionLogic.swift)
    /// plus jitter, while still catching a genuinely stale report promptly.
    static let staleAircraftAgeSeconds: Double = 10.0

    /// Hard ceiling on dead-reckoning extrapolation: beyond this age we stop projecting
    /// the aircraft further forward and freeze it at the 20s-extrapolated point, rather
    /// than coasting in a straight line indefinitely.
    static let maxCoastSeconds: Double = 20.0

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
        cameraWorldPosition: SCNVector3 = .init()
    ) -> SCNVector3 {
        return calculateARPosition(
            targetCoord: airportCoord,
            targetAltitude: airportElevation,
            userCoord: userCoord,
            userAltitude: userAltitude,
            userHeading: userHeading,
            cameraWorldPosition: cameraWorldPosition
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
struct AngularResponse {

    struct Estimate {
        /// Degrees the response angle turns per degree the driver turns.
        var slope: Double
        /// Pearson correlation of the per-sample changes, −1…1. Near zero means the slope is
        /// describing noise rather than a relationship.
        var correlation: Double
        /// Total absolute driver rotation the estimate is drawn from, in degrees.
        var driverRotationDeg: Double
        var pairCount: Int
    }

    /// How long a span the estimate is drawn from.
    let window: TimeInterval
    /// Minimum total driver rotation before an estimate is published at all. Below this the
    /// ratio is noise over noise and says nothing.
    let minDriverRotationDeg: Double
    /// Minimum number of change pairs, so a single jump cannot produce a confident-looking slope.
    let minPairs: Int

    private var samples: [(t: TimeInterval, driver: Double, response: Double)] = []

    init(window: TimeInterval, minDriverRotationDeg: Double, minPairs: Int = 8) {
        self.window = window
        self.minDriverRotationDeg = minDriverRotationDeg
        self.minPairs = minPairs
    }

    mutating func add(driver: Double, response: Double, at time: TimeInterval) {
        samples.append((t: time, driver: driver, response: response))
        samples.removeAll { time - $0.t > window }
    }

    mutating func reset() { samples.removeAll() }

    /// Signed shortest angular difference, −180…180. Local to keep this type free-standing.
    private static func delta(_ from: Double, _ to: Double) -> Double {
        var d = to - from
        while d >  180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// The current estimate, or nil when the window holds too little rotation to mean anything.
    var estimate: Estimate? {
        guard samples.count >= minPairs + 1 else { return nil }

        var dDriver: [Double] = []
        var dResponse: [Double] = []
        dDriver.reserveCapacity(samples.count - 1)
        dResponse.reserveCapacity(samples.count - 1)
        for (previous, current) in zip(samples, samples.dropFirst()) {
            dDriver.append(AngularResponse.delta(previous.driver, current.driver))
            dResponse.append(AngularResponse.delta(previous.response, current.response))
        }

        let rotation = dDriver.reduce(0) { $0 + abs($1) }
        guard rotation >= minDriverRotationDeg else { return nil }

        // Slope through the origin: no intercept term, because zero driver rotation must mean
        // zero response rotation for this to be the quantity it claims to be.
        let denominator = dDriver.reduce(0) { $0 + $1 * $1 }
        guard denominator > 0 else { return nil }
        let slope = zip(dDriver, dResponse).reduce(0) { $0 + $1.0 * $1.1 } / denominator

        return Estimate(slope: slope,
                        correlation: AngularResponse.correlation(dDriver, dResponse),
                        driverRotationDeg: rotation,
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
