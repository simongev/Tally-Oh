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

    /// Calculate 3D distance including altitude difference
    static func distance3D(
        from coord1: CLLocationCoordinate2D,
        altitude1: Double, // in feet
        to coord2: CLLocationCoordinate2D,
        altitude2: Double // in feet
    ) -> Double {
        let horizontalDistance = distance(from: coord1, to: coord2)
        let verticalDistance = abs(altitude1 - altitude2) * feetToMeters

        return sqrt(horizontalDistance * horizontalDistance +
                   verticalDistance * verticalDistance)
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
    ///   -Z = North  +Z = South
    /// The scene is world-fixed — the device camera moves through it.
    /// We compute positions relative to the camera's current world position
    /// (passed in as `cameraWorldPosition`) so that all markers stay correctly
    /// placed even as the aircraft flies kilometres from the AR origin.
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

    /// Predict where an aircraft will be `aheadSeconds` in the future,
    /// compensating for ADS-B report latency and network delay.
    static func predictedPosition(
        for aircraft: Aircraft,
        aheadSeconds: Double = 0
    ) -> (coordinate: CLLocationCoordinate2D, altitude: Double) {
        let age = -aircraft.lastUpdate.timeIntervalSinceNow  // seconds since last report
        let total = age + aheadSeconds
        guard total > 0, aircraft.groundSpeed > 0 else {
            return (aircraft.coordinate, aircraft.altitude)
        }
        return predictPosition(
            currentCoord:   aircraft.coordinate,
            currentAltitude: aircraft.altitude,
            track:           aircraft.track,
            groundSpeed:     aircraft.groundSpeed,
            verticalRate:    aircraft.verticalRate,
            timeSeconds:     total
        )
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

    // MARK: - Aircraft Circle Radius Calculation

    /// Calculate the radius for the red circle around an aircraft
    /// The circle represents the approximate size/uncertainty of the aircraft position
    /// - Parameter distance: Distance to the aircraft in meters
    /// - Returns: Radius in meters for the AR circle
    static func calculateAircraftCircleRadius(distance: Double) -> Float {
        // Base radius: larger for distant aircraft, smaller for close ones
        // This accounts for visual perspective and accuracy uncertainty

        let baseRadius: Double

        if distance < 500 { // Very close (< 0.27 NM)
            baseRadius = 10.0 // 10 meters
        } else if distance < 1852 { // < 1 NM
            baseRadius = 20.0 // 20 meters
        } else if distance < 5556 { // < 3 NM
            baseRadius = 30.0 // 30 meters
        } else if distance < 18520 { // < 10 NM
            baseRadius = 50.0 // 50 meters
        } else {
            baseRadius = 100.0 // 100 meters for distant aircraft
        }

        return Float(baseRadius)
    }

    // MARK: - Coordinate Filtering

    /// Check if a coordinate is within range
    static func isWithinRange(
        targetCoord: CLLocationCoordinate2D,
        userCoord: CLLocationCoordinate2D,
        maxRangeNauticalMiles: Double
    ) -> Bool {
        let distance = distanceInNauticalMiles(from: userCoord, to: targetCoord)
        return distance <= maxRangeNauticalMiles
    }

    /// Filter airports within specified range
    static func filterAirportsInRange(
        airports: [Airport],
        userCoord: CLLocationCoordinate2D,
        maxRangeNauticalMiles: Double
    ) -> [Airport] {
        return airports.filter { airport in
            isWithinRange(
                targetCoord: airport.coordinate,
                userCoord: userCoord,
                maxRangeNauticalMiles: maxRangeNauticalMiles
            )
        }
    }

    // MARK: - Elevation Angle Calculation

    /// Calculate elevation angle from user to target
    /// Returns angle in degrees (positive = above horizon, negative = below)
    static func elevationAngle(
        targetCoord: CLLocationCoordinate2D,
        targetAltitude: Double,
        userCoord: CLLocationCoordinate2D,
        userAltitude: Double
    ) -> Double {
        let horizontalDistance = distance(from: userCoord, to: targetCoord)
        let verticalDistance = (targetAltitude - userAltitude) * feetToMeters

        return atan2(verticalDistance, horizontalDistance).toDegrees()
    }

    // MARK: - Label Position Calculation

    /// Calculate position for a text label above an object
    static func calculateLabelPosition(
        basePosition: SCNVector3,
        offsetMeters: Float
    ) -> SCNVector3 {
        return SCNVector3(
            basePosition.x,
            basePosition.y + offsetMeters,
            basePosition.z
        )
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
