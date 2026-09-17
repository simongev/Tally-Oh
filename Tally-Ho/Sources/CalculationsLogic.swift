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