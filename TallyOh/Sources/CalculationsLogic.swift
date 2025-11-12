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

    static let earthRadiusMeters: Double = 6_371_000.0 // Earth radius in meters
    static let feetToMeters: Double = 0.3048
    static let metersToFeet: Double = 3.28084
    static let nauticalMileToMeters: Double = 1852.0
    static let knotsToMetersPerSecond: Double = 0.514444

    // MARK: - Distance Calculations

    /// Calculate distance between two coordinates in meters using Haversine formula
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

        return earthRadiusMeters * c
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
    /// Uses Pythagorean theorem on the great circle distance and altitude
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

    /// Calculate slant range (line-of-sight distance) between two points
    /// More accurate for long distances as it accounts for Earth curvature
    static func slantRange(
        from coord1: CLLocationCoordinate2D,
        altitude1: Double, // in feet MSL
        to coord2: CLLocationCoordinate2D,
        altitude2: Double // in feet MSL
    ) -> Double {
        // Convert altitudes to meters
        let alt1Meters = altitude1 * feetToMeters
        let alt2Meters = altitude2 * feetToMeters

        // Calculate positions from Earth's center
        let r1 = earthRadiusMeters + alt1Meters
        let r2 = earthRadiusMeters + alt2Meters

        // Get angular distance using Haversine
        let lat1 = coord1.latitude.toRadians()
        let lon1 = coord1.longitude.toRadians()
        let lat2 = coord2.latitude.toRadians()
        let lon2 = coord2.longitude.toRadians()

        let dLat = lat2 - lat1
        let dLon = lon2 - lon1

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) *
                sin(dLon / 2) * sin(dLon / 2)

        let angularDistance = 2 * atan2(sqrt(a), sqrt(1 - a))

        // Use law of cosines for spherical coordinates
        // d² = r1² + r2² - 2*r1*r2*cos(angular_distance)
        let slantRangeSq = r1 * r1 + r2 * r2 - 2 * r1 * r2 * cos(angularDistance)

        return sqrt(max(0, slantRangeSq))
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

    /// Convert real-world position to AR scene position with Earth curvature correction
    /// - Parameters:
    ///   - targetCoord: GPS coordinate of the target
    ///   - targetAltitude: Altitude of target in feet MSL
    ///   - userCoord: GPS coordinate of user (ownship)
    ///   - userAltitude: Altitude of user in feet MSL
    ///   - userHeading: True heading of user in degrees
    /// - Returns: SCNVector3 position for AR scene
    static func calculateARPosition(
        targetCoord: CLLocationCoordinate2D,
        targetAltitude: Double,
        userCoord: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double
    ) -> SCNVector3 {

        // Calculate horizontal distance and bearing using great circle formulas
        let horizontalDistance = distance(from: userCoord, to: targetCoord)
        let bearing = self.bearing(from: userCoord, to: targetCoord)

        // Calculate relative bearing (bearing relative to user's heading)
        var relativeBearing = bearing - userHeading
        if relativeBearing < 0 {
            relativeBearing += 360
        }
        if relativeBearing > 180 {
            relativeBearing -= 360
        }

        let relativeBearingRad = relativeBearing.toRadians()

        // Calculate altitude difference with Earth curvature correction
        // For distant objects, Earth's curvature causes them to appear lower
        var altitudeDifference = (targetAltitude - userAltitude) * feetToMeters

        // Earth curvature correction (drop in meters)
        // Formula: drop = distance² / (2 * Earth radius)
        // This accounts for the horizon drop at distance
        let curvatureDrop = (horizontalDistance * horizontalDistance) / (2.0 * earthRadiusMeters)

        // Apply curvature correction - distant objects appear lower
        altitudeDifference -= curvatureDrop

        // Optional: Atmospheric refraction correction (light bends around Earth)
        // Standard refraction is about 1/7 of the geometric curvature
        // This makes distant objects appear slightly higher than geometric calculation
        let refractionCorrection = curvatureDrop * 0.14286 // 1/7 of curvature
        altitudeDifference += refractionCorrection

        // Convert to AR coordinates with high precision
        // In ARKit: +X is right, +Y is up, -Z is forward
        // Use actual distances - far clipping plane will handle rendering limits

        // Calculate X and Z positions using horizontal distance and bearing
        // These use the great circle distance projected onto the local tangent plane
        let x = Float(horizontalDistance * sin(relativeBearingRad))
        let z = Float(-horizontalDistance * cos(relativeBearingRad))

        // Y is the corrected altitude difference
        let y = Float(altitudeDifference)

        return SCNVector3(x, y, z)
    }

    /// Calculate position for airport marker
    /// Airports are shown at ground level (elevation)
    static func calculateAirportARPosition(
        airportCoord: CLLocationCoordinate2D,
        airportElevation: Double, // in feet MSL
        userCoord: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double
    ) -> SCNVector3 {
        return calculateARPosition(
            targetCoord: airportCoord,
            targetAltitude: airportElevation,
            userCoord: userCoord,
            userAltitude: userAltitude,
            userHeading: userHeading
        )
    }

    // MARK: - Aircraft Circle Radius Calculation

    /// Calculate the radius for the red circle around an aircraft
    /// The circle represents the approximate size/uncertainty of the aircraft position
    /// - Parameter distance: Distance to the aircraft in meters
    /// - Returns: Radius in meters for the AR circle
    static func calculateAircraftCircleRadius(distance: Double) -> Float {
        // Moderate base radius for visibility without being obtrusive
        // Combined with LOD scaling for clear visualization at all distances

        let baseRadius: Double

        if distance < 500 { // Very close (< 0.27 NM)
            baseRadius = 8.0 // 8 meters
        } else if distance < 1852 { // < 1 NM
            baseRadius = 12.0 // 12 meters
        } else if distance < 5556 { // < 3 NM
            baseRadius = 18.0 // 18 meters
        } else if distance < 18520 { // < 10 NM
            baseRadius = 25.0 // 25 meters
        } else {
            baseRadius = 35.0 // 35 meters for distant aircraft
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

    /// Calculate elevation angle from user to target with Earth curvature correction
    /// Returns angle in degrees (positive = above horizon, negative = below)
    static func elevationAngle(
        targetCoord: CLLocationCoordinate2D,
        targetAltitude: Double,
        userCoord: CLLocationCoordinate2D,
        userAltitude: Double
    ) -> Double {
        let horizontalDistance = distance(from: userCoord, to: targetCoord)
        var verticalDistance = (targetAltitude - userAltitude) * feetToMeters

        // Apply Earth curvature correction
        let curvatureDrop = (horizontalDistance * horizontalDistance) / (2.0 * earthRadiusMeters)
        verticalDistance -= curvatureDrop

        // Apply atmospheric refraction
        let refractionCorrection = curvatureDrop * 0.14286
        verticalDistance += refractionCorrection

        return atan2(verticalDistance, horizontalDistance).toDegrees()
    }

    /// Calculate geometric horizon distance from altitude
    /// Returns distance in meters to the horizon
    static func horizonDistance(altitude: Double) -> Double {
        // altitude in feet MSL
        let altitudeMeters = altitude * feetToMeters
        let r = earthRadiusMeters

        // Geometric horizon distance: d = sqrt(2*r*h + h²)
        // For h << r, this simplifies to: d ≈ sqrt(2*r*h)
        return sqrt(2.0 * r * altitudeMeters + altitudeMeters * altitudeMeters)
    }

    /// Check if target is above the horizon from user's perspective
    static func isAboveHorizon(
        targetCoord: CLLocationCoordinate2D,
        targetAltitude: Double,
        userCoord: CLLocationCoordinate2D,
        userAltitude: Double
    ) -> Bool {
        let horizontalDistance = distance(from: userCoord, to: targetCoord)
        let userHorizon = horizonDistance(altitude: userAltitude)
        let targetHorizon = horizonDistance(altitude: targetAltitude)

        // If target is within combined horizon distance, it's visible
        return horizontalDistance <= (userHorizon + targetHorizon)
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

    /// Calculate a new coordinate offset by distance and bearing
    private static func coordinateOffset(
        from coord: CLLocationCoordinate2D,
        bearing: Double,
        distanceMeters: Double
    ) -> CLLocationCoordinate2D {

        let bearingRad = bearing.toRadians()
        let lat1 = coord.latitude.toRadians()
        let lon1 = coord.longitude.toRadians()

        let angularDistance = distanceMeters / earthRadiusMeters

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
    let latitude: Double
    let longitude: Double
    let elevation: Double // in feet MSL
    let type: String? // Airport type: large_airport, medium_airport, small_airport, etc.

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
