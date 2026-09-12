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

    /// Steepest elevation a marker is placed at, in radians (85°). A bound on `tan`, not on the
    /// field of view — see `calculateARPosition`.
    static let maxPlacementElevationRad: Double = 85.0 * .pi / 180.0

    /// ISA sea-level temperature, in kelvin.
    static let isaSeaLevelTemperatureK: Double = 288.15
    /// ISA tropopause: above this the standard atmosphere is isothermal.
    static let isaTropopauseFt: Double = 36_089.0
    static let isaTropopauseTemperatureK: Double = 216.65
    /// ISA temperature lapse below the tropopause, kelvin per foot.
    static let isaLapseKPerFt: Double = (isaSeaLevelTemperatureK - isaTropopauseTemperatureK) / isaTropopauseFt

    /// Mean ISA temperature of the air column from sea level up to `altitudeFt`, in kelvin.
    ///
    /// Linear lapse to the tropopause, isothermal above it — so this is the average of a ramp for
    /// the first 36,089 ft and a ramp-plus-constant beyond. It is the denominator of the
    /// pressure-to-geometric conversion below: what separates the two datums is how much warmer
    /// the real column is than the standard one, averaged over its whole height.
    static func isaMeanColumnTemperatureK(toAltitudeFt altitudeFt: Double) -> Double {
        let h = max(0, altitudeFt)
        guard h > 0 else { return isaSeaLevelTemperatureK }
        if h <= isaTropopauseFt {
            // Mean of a linear ramp is its midpoint value.
            return isaSeaLevelTemperatureK - 0.5 * isaLapseKPerFt * h
        }
        let tropopauseMean = isaSeaLevelTemperatureK - 0.5 * isaLapseKPerFt * isaTropopauseFt
        let aboveFt = h - isaTropopauseFt
        return (isaTropopauseFt * tropopauseMean + aboveFt * isaTropopauseTemperatureK) / h
    }

    /// Geometric altitude minus pressure altitude at `altitudeFt`, for an air mass `deltaISAK`
    /// kelvin from standard. Positive means geometric reads higher, which a warm air mass produces.
    ///
    /// A column warmer than standard is less dense, so a given pressure sits physically higher than
    /// the standard atmosphere puts it. The height error is the fractional temperature excess times
    /// the height itself — the same relation behind the altimetry rule of thumb of four feet per
    /// thousand feet per degree of deviation.
    ///
    /// This is what makes traffic at *any* altitude a usable measurement of the offset. The offset
    /// itself is not one number for the sky; `deltaISAK` is.
    static func datumOffsetFt(atAltitudeFt altitudeFt: Double, deltaISAK: Double) -> Double {
        guard altitudeFt.isFinite, deltaISAK.isFinite, altitudeFt > 0 else { return 0 }
        return deltaISAK * altitudeFt / isaMeanColumnTemperatureK(toAltitudeFt: altitudeFt)
    }

    /// The inverse: the temperature deviation implied by one aircraft reporting both datums.
    /// Nil when `geometricAltitudeFt` is too low for the division to mean anything.
    static func deltaISAK(geometricAltitudeFt: Double, pressureAltitudeFt: Double) -> Double? {
        guard geometricAltitudeFt.isFinite, pressureAltitudeFt.isFinite,
              geometricAltitudeFt > 0 else { return nil }
        return (geometricAltitudeFt - pressureAltitudeFt)
            * isaMeanColumnTemperatureK(toAltitudeFt: geometricAltitudeFt) / geometricAltitudeFt
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

    /// How far below the horizon something sits, in degrees, from its slant geometry.
    ///
    /// Positive means below the horizon, which is where every airport is from an aircraft. Negative
    /// would mean above, which is what traffic higher than the viewer gives.
    ///
    /// This exists as the one *independent* check on vertical placement. An airport's elevation is
    /// surveyed MSL and ownship altitude is GPS MSL — the same datum, with no pressure conversion
    /// and no ΔISA model anywhere in the path — so the angle is exactly computable and owes nothing
    /// to the altitude work. Logged so that "the marker sat too low" becomes a number.
    ///
    /// Flat-Earth over the horizontal distance: at the ranges markers are drawn (≤ 40 NM for
    /// airports) Earth curvature adds a few tenths of a degree, which is far below what an eye
    /// check can resolve.
    static func depressionAngleDeg(
        viewerAltitudeFt: Double,
        targetAltitudeFt: Double,
        horizontalDistanceNM: Double
    ) -> Double? {
        guard horizontalDistanceNM > 0, horizontalDistanceNM.isFinite,
              viewerAltitudeFt.isFinite, targetAltitudeFt.isFinite else { return nil }
        let horizontalFt = horizontalDistanceNM * nauticalMileToMeters * metersToFeet
        return atan2(viewerAltitudeFt - targetAltitudeFt, horizontalFt).toDegrees()
    }

    /// Wrap a compass direction into [0, 360). Handles inputs already out of range in either
    /// direction, which a raw azimuth plus a world-yaw offset routinely is.
    static func normalizedAzimuth(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
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
        //
        // The cap was ±45°, "so markers stay within vertical FoV", and that reasoning is backwards:
        // a marker outside the field of view is simply not on screen, which is correct and is what
        // the off-screen arrow exists for — clamping it to 45° instead puts a *wrong* marker inside
        // the view, at an elevation the target does not have. Anything steeper was drawn at 45°.
        //
        // It bites whenever the vertical separation exceeds the horizontal distance. A ground
        // screenshot caught it exactly: AAL1744 at 35,000 ft and 4.5 NM is 52° up, and was drawn
        // seven degrees low. Overhead traffic does this routinely from the ground, and a climb or
        // descent with traffic a few miles off does it in the air.
        //
        // ±85° now, which is not a field-of-view judgement at all — it only keeps `tan` away from
        // its singularity. At 85° the marker sits 11.4 radii up, which SceneKit places without
        // complaint, and every elevation a target realistically has is reproduced exactly.
        let clampedElev = max(-maxPlacementElevationRad, min(maxPlacementElevationRad, elevationRad))
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

    /// Altitude to draw a target at, in feet — converted into the viewer's own vertical datum.
    ///
    /// When the source reported no usable altitude the target is placed at the viewer's own
    /// altitude, so it appears on the horizon in the correct direction rather than being sunk
    /// to 0 ft MSL — which at a high-elevation airport would put ground traffic far below the
    /// viewer's feet, in a direction no one is looking.
    static func placementAltitude(
        for aircraft: Aircraft,
        targetAltitude: Double,
        userAltitudeFt: Double,
        geoidSeparationFt: Double? = nil,
        datumFit: AltitudeDatumOffset.DatumFit? = nil
    ) -> Double {
        guard aircraft.hasValidAltitude else { return userAltitudeFt }
        return geometricPlacementAltitude(
            for: aircraft,
            reportedAltitudeFt: targetAltitude,
            geoidSeparationFt: geoidSeparationFt,
            datumFit: datumFit
        )
    }

    /// Convert a target's reported altitude into geometric MSL — the datum the viewer's own
    /// altitude is measured in.
    ///
    /// The viewer's altitude is GPS geometric MSL. Traffic reports `alt_baro`, referenced to the
    /// 29.92 inHg standard datum, and `Aircraft.altitude` carries that value whenever one was
    /// reported. Subtracting one from the other leaves the local altimeter-setting and
    /// temperature-deviation offset in the answer, as a bias on every target at once: measured at
    /// roughly 1,900 ft at cruise in the FL420 logs, which is 3.8° of vertical error at 5 NM and
    /// 9.4° at 2 NM.
    ///
    /// Every aircraft that reports both datums is measuring that offset for us *at its own
    /// altitude*, which is the only place the measurement is valid — the offset grows with height,
    /// so a fleet-wide median mixes traffic on the ground with traffic at our level (see
    /// `AltitudeDatumOffset`). Using each target's own pair needs no estimator, no convergence and
    /// no minimum sample count: one aircraft in view is enough, and it is exact for that aircraft.
    ///
    /// `alt_geom` is referenced to the WGS-84 ellipsoid, so it becomes MSL by subtracting the
    /// geoid separation the phone reports for our own fix (HAE − MSL, −108.9 ft in these logs).
    ///
    /// A target reporting pressure altitude only — every GDL90 traffic report, and about 2% of
    /// internet traffic — has no pair of its own, and build 35 left those unconverted because there
    /// was no air-mass model to fall back on. There is now: `datumFit` inverts the fitted line to
    /// recover the geometric height. Without a fit the reported altitude is returned unchanged,
    /// which is what the app did before and is never worse for any target.
    static func geometricPlacementAltitude(
        for aircraft: Aircraft,
        reportedAltitudeFt: Double,
        geoidSeparationFt: Double?,
        datumFit: AltitudeDatumOffset.DatumFit? = nil
    ) -> Double {
        // How far `reportedAltitudeFt` has to move to become an ellipsoid-referenced height.
        // Mirrors the source's own precedence (pressure altitude when present, else geometric),
        // so the shift matches whichever datum `Aircraft.altitude` was populated from — and
        // carries across the vertical-rate extrapolation already applied to it.
        let toEllipsoidFt: Double
        switch (aircraft.pressureAltitudeFt, aircraft.geometricAltitudeFt) {
        case let (pressure?, geometric?):
            let offset = geometric - pressure
            // A pair no atmosphere could produce is a mis-set or stale report, not a measurement.
            guard abs(offset) <= AltitudeDatumOffset.maxPlausibleOffsetFt else {
                return reportedAltitudeFt
            }
            toEllipsoidFt = offset
        case (nil, _?):
            // The reported altitude is already the geometric one.
            toEllipsoidFt = 0
        case (.some, nil):
            // Pressure only. No pair of its own, so the air-mass fit stands in — the same line the
            // ownship readout uses, inverted. At cruise this is worth 1,500–2,000 ft, the
            // difference between a target on the horizon and one well below it.
            guard let fit = datumFit else { return reportedAltitudeFt }
            let geometric = fit.geometricAltitudeFt(fromPressureFt: reportedAltitudeFt)
            guard abs(geometric - reportedAltitudeFt) <= AltitudeDatumOffset.maxPlausibleOffsetFt
            else { return reportedAltitudeFt }
            toEllipsoidFt = geometric - reportedAltitudeFt
        default:
            // Neither datum: nothing to convert with.
            return reportedAltitudeFt
        }
        return reportedAltitudeFt + toEllipsoidFt - (geoidSeparationFt ?? 0)
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
    /// Changes smaller than this are not worth moving the scene for.
    ///
    /// Raised 0.5° → 1.5° in build 33. At 0.5° the correction walked 0.59 → −3.02 → +4.56 across one
    /// ground session, chasing a median that was mostly noise around 1.5° — four degrees of
    /// continuous scene motion for no gain. The median is the signal; its jitter is not.
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
        guard abs(delta) >= deadbandDeg || !hasOffset else { return .refused(.withinDeadband) }

        lastUpdateTime = time
        let step = min(abs(delta), maxSlewPerUpdateDeg) * (delta < 0 ? -1.0 : 1.0)
        appliedOffsetDeg += step
        hasOffset = true
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
        lastUpdateTime = -.greatestFiniteMagnitude
    }

    /// Clear with the world. The offset describes one ARKit session's frame and means nothing about
    /// the next one.
    mutating func reset() {
        appliedOffsetDeg = 0
        hasOffset = false
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
/// Target *placement* does not use this. Each target carries its own pair, so
/// `CalculationsLogic.geometricPlacementAltitude` converts it exactly, per aircraft, with no
/// estimator at all. What this is for is the one quantity no target can supply: the viewer's own
/// pressure altitude, which is unmeasurable on board — the phone's barometer reads cabin pressure
/// (5,474 ft at cruise in these logs), not outside static. For that, `deltaISAEstimate(from:)`
/// reads the air mass's temperature deviation off the traffic, at whatever altitude it is flying.
///
/// `estimate(from:)` itself is now a log column and nothing else. Its median mixes altitudes and is
/// only meaningful when the sample happens to be at one level; keep reading it as a diagnostic, not
/// as a number to act on.
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
        estimate(from: offsets(from: aircraft), minSamples: 1)
    }

    /// Below this height the offset is a few tens of feet dominated by the geoid and the local
    /// altimeter setting, so dividing by the height turns that constant into an enormous apparent
    /// temperature deviation. Above it the temperature term dominates and the division is stable.
    static let minContributorAltitudeFt: Double = 5_000.0

    /// Widest temperature deviation from standard that is weather rather than a broken report.
    /// ±30 K spans everything from a Siberian winter to a desert summer.
    static let maxPlausibleDeltaISAK: Double = 30.0

    /// How far the air mass is from the standard atmosphere, in kelvin, as the traffic measures it.
    ///
    /// **Why a temperature and not an offset.** Build 35 estimated the offset directly, from
    /// traffic within ±4,000 ft of the viewer, and in a whole flight it returned a value in zero
    /// rows out of 191: the sky held a mean of 2.0 aircraft and none of them were at our level. The
    /// band was there because a fleet-wide median of offsets really does mix populations — surface
    /// traffic reads near zero while traffic at cruise reads near 1,900 ft.
    ///
    /// But those are not two populations. They are one measurement taken at two heights, and the
    /// ratio between them barely moves:
    ///
    ///     ~42,250 ft  +2,250 ft   0.053      (log 78fe1ae2)
    ///     ~42,000 ft  ~+1,850 ft  0.044      (log 6b73e28c)
    ///      ~3,000 ft    ~+125 ft  0.042      (log 6b73e28c, same session)
    ///
    /// which is what the atmosphere does: one temperature deviation describes the whole column, and
    /// the height error it produces scales with height. Read that way, **every aircraft in the sky
    /// measures the same number**, and the surface traffic that poisoned the median becomes a
    /// perfectly good sample. No band, no minimum count, and one reporting aircraft anywhere in
    /// view is enough — which is the difference between a readout that works in this user's
    /// airspace and one that never appeared.
    ///
    /// **Superseded as the estimator by `datumFit` in build 41, and kept for the log column.** The
    /// pure proportion has no constant term, and the offset has one: `alt_baro` is always
    /// referenced to 1013.25 hPa, so it carries the sea-level pressure deviation as well as the
    /// temperature. Forcing that through the origin tilts the slope, which showed as a temperature
    /// that rose with altitude across the very sample that validated it — 9.04 K at 5,475 ft
    /// against 10.69 K at 35,500 ft. `datumFit` fits both terms and is 13× closer at cruise.
    static func deltaISAEstimate(
        from aircraft: [Aircraft],
        minAltitudeFt: Double = minContributorAltitudeFt,
        maxDeltaK: Double = maxPlausibleDeltaISAK
    ) -> (kelvin: Double, sampleCount: Int)? {
        let deviations: [Double] = aircraft.compactMap { ac -> Double? in
            guard let geometric = ac.geometricAltitudeFt,
                  let pressure  = ac.pressureAltitudeFt,
                  geometric >= minAltitudeFt,
                  abs(geometric - pressure) <= maxPlausibleOffsetFt,
                  let delta = CalculationsLogic.deltaISAK(geometricAltitudeFt: geometric,
                                                          pressureAltitudeFt: pressure),
                  abs(delta) <= maxDeltaK
            else { return nil }
            return delta
        }.sorted()
        guard !deviations.isEmpty else { return nil }
        return (percentile(deviations, 0.50), deviations.count)
    }

    // MARK: - The two-term fit

    /// Geometric minus pressure altitude as a straight line in height: `offset = slope·H + intercept`.
    ///
    /// Both terms are physical. The slope is the temperature deviation — a column warmer than
    /// standard is less dense, so a given pressure sits higher, by a fraction of the height. The
    /// intercept is the sea-level pressure deviation, roughly 30 ft per hPa, and it does **not**
    /// scale with height: `alt_baro` is referenced to 1013.25 hPa whatever the local altimeter
    /// setting, so every report carries it.
    struct DatumFit: Equatable {
        var slope: Double
        var interceptFt: Double
        var sampleCount: Int

        /// Geometric minus pressure at a height.
        func offsetFt(atAltitudeFt altitudeFt: Double) -> Double {
            slope * altitudeFt + interceptFt
        }

        /// The temperature half alone, without the pressure constant.
        ///
        /// This is what an altimeter set to the local QNH still gets wrong, because setting QNH is
        /// precisely what removes the constant. Above the transition altitude the altimeter is on
        /// 29.92 and both terms apply; below it, only this one does.
        func temperatureOffsetFt(atAltitudeFt altitudeFt: Double) -> Double {
            slope * altitudeFt
        }

        /// Geometric altitude of a target that reported only pressure altitude, by inverting the
        /// fit: `H = (pressure + intercept) / (1 − slope)`.
        func geometricAltitudeFt(fromPressureFt pressureFt: Double) -> Double {
            let denominator = 1.0 - slope
            guard abs(denominator) > 0.5 else { return pressureFt }
            return (pressureFt + interceptFt) / denominator
        }
    }

    /// Fewest contributors, and the least altitude they must span, before a line is worth fitting.
    /// Two points define a line exactly and so cannot disagree; three can. The span matters more
    /// than the count — a line through aircraft all at one level says nothing about the slope.
    static let minFitSamples = 3
    static let minFitSpanFt: Double = 5_000.0

    /// Plausible bounds on the fitted terms, so a pathological sample cannot move the readout far.
    /// A slope of 0.10 is roughly ISA +28 K; 1,000 ft of intercept is 33 hPa from standard.
    static let maxFitSlope: Double = 0.10
    static let maxFitInterceptFt: Double = 1_000.0

    /// Fit the offset against height across the traffic, robustly.
    ///
    /// **Theil–Sen rather than least squares**, because the sample is a handful of aircraft and
    /// ADS-B carries the occasional nonsense report. On the five contributors that validated the
    /// previous model, adding one absurd extra (9,000 ft reporting −400 ft) moves the Theil–Sen
    /// answer by 19 ft at cruise while least squares is visibly dragged. The median of pairwise
    /// slopes simply ignores it.
    ///
    /// Nil when there are too few contributors or too little altitude spread between them, which
    /// is not a failure: the caller falls back to the proportional model, and with no spread to fit
    /// through, a line anchored at the origin is the better-conditioned answer.
    static func datumFit(
        from aircraft: [Aircraft],
        minAltitudeFt: Double = minContributorAltitudeFt
    ) -> DatumFit? {
        let points: [(h: Double, offset: Double)] = aircraft.compactMap { ac in
            guard let geometric = ac.geometricAltitudeFt,
                  let pressure  = ac.pressureAltitudeFt,
                  geometric >= minAltitudeFt,
                  abs(geometric - pressure) <= maxPlausibleOffsetFt
            else { return nil }
            return (geometric, geometric - pressure)
        }
        guard points.count >= minFitSamples else { return nil }
        guard let lowest = points.map(\.h).min(), let highest = points.map(\.h).max(),
              highest - lowest >= minFitSpanFt else { return nil }

        // Median of the pairwise slopes, over pairs far enough apart in height that the slope
        // between them means something. A pair a hundred feet apart divides two noisy offsets by a
        // tiny denominator and produces a wild slope.
        var slopes: [Double] = []
        for i in points.indices {
            for j in points.index(after: i)..<points.endIndex {
                let dh = points[j].h - points[i].h
                guard abs(dh) >= minFitSpanFt / 2 else { continue }
                slopes.append((points[j].offset - points[i].offset) / dh)
            }
        }
        guard !slopes.isEmpty else { return nil }
        let slope = percentile(slopes.sorted(), 0.50)
        guard abs(slope) <= maxFitSlope else { return nil }

        // The intercept that leaves the residuals balanced, which for a median slope is the median
        // residual rather than the mean.
        let intercept = percentile(points.map { $0.offset - slope * $0.h }.sorted(), 0.50)
        guard abs(intercept) <= maxFitInterceptFt else { return nil }

        return DatumFit(slope: slope, interceptFt: intercept, sampleCount: points.count)
    }

    private static func estimate(from unsorted: [Double], minSamples: Int) -> Estimate? {
        let values = unsorted.sorted()
        guard values.count >= max(1, minSamples) else { return nil }
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
