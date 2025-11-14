//
//  MainAppComponents.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Contains all AR visualization components:
//  - Red circles around aircraft
//  - Blue cones for airports
//  - Text labels
//

import Foundation
import SceneKit
import ARKit
import UIKit

// MARK: - AR Component Factory

/// Factory class for creating AR visualization components
class ARComponentFactory {

    // MARK: - Aircraft Components

    /// Create a red circle to represent an aircraft in AR
    /// - Parameters:
    ///   - radius: Radius of the circle in meters
    ///   - position: Position in AR scene
    ///   - aircraft: Aircraft data
    ///   - distance: Distance to aircraft in meters (for LOD scaling)
    /// - Returns: SCNNode containing the aircraft visualization
    static func createAircraftMarker(
        radius: Float,
        position: SCNVector3,
        aircraft: Aircraft,
        distance: Double
    ) -> SCNNode {

        let containerNode = SCNNode()
        containerNode.name = "aircraft_\(aircraft.id)"
        containerNode.position = position

        // Make container always face user
        let billboardConstraint = SCNBillboardConstraint()
        billboardConstraint.freeAxes = [.Y]
        containerNode.constraints = [billboardConstraint]

        // Calculate LOD scale based on distance
        // Farther objects are scaled up so they remain visible
        let lodScale = calculateLODScale(distance: distance)

        // Create red circle (torus with smaller thickness) - reduced size
        let smallerRadius = radius * 0.7 // Make airplane target smaller
        let circle = SCNTorus(ringRadius: CGFloat(smallerRadius), pipeRadius: 1.5)
        let circleMaterial = SCNMaterial()
        circleMaterial.diffuse.contents = UIColor.red
        circleMaterial.emission.contents = UIColor.red.withAlphaComponent(0.3)
        circleMaterial.isDoubleSided = true
        circleMaterial.lightingModel = .constant // Always visible regardless of lighting
        circle.materials = [circleMaterial]

        let circleNode = SCNNode(geometry: circle)

        // Rotate to be horizontal (parallel to ground)
        circleNode.eulerAngles.x = .pi / 2

        // Apply LOD scaling
        circleNode.scale = SCNVector3(lodScale, lodScale, lodScale)

        containerNode.addChildNode(circleNode)

        // NO pulsing animation - removed as requested

        // Add label with customizable information based on settings
        let labelText = AppSettings.shared.generateAircraftLabel(aircraft: aircraft)
        let labelNode = createTextLabelWithBackground(
            text: labelText,
            textColor: .white,
            position: SCNVector3(0, smallerRadius + 30, 0) // Hover higher above node
        )
        labelNode.scale = SCNVector3(lodScale, lodScale, lodScale)
        containerNode.addChildNode(labelNode)

        // Add velocity indicator (arrow showing direction)
        let arrowNode = createDirectionArrow(
            heading: Float(aircraft.track),
            length: smallerRadius * 1.5,
            color: .yellow
        )
        arrowNode.scale = SCNVector3(lodScale * 0.7, lodScale * 0.7, lodScale * 0.7)
        containerNode.addChildNode(arrowNode)

        return containerNode
    }

    /// Calculate LOD (Level of Detail) scale based on distance
    /// Farther objects are scaled up to remain visible at actual distances
    static func calculateLODScale(distance: Double) -> Float {
        // More conservative scaling - objects at true positions shouldn't look huge
        // Balance between visibility and realistic appearance

        if distance < 500 { // 200-500m range (minimum distance applied)
            return 0.5 // Small to not block view
        } else if distance < 1000 { // 500m-1km
            return Float(distance / 1000.0) // ~0.5x to 1x
        } else if distance < 1852 { // < 1 NM
            return Float(distance / 1200.0) // ~0.8x to 1.5x
        } else if distance < 9260 { // < 5 NM
            return Float(distance / 1500.0) // ~1.2x to 6x
        } else if distance < 18520 { // < 10 NM
            return Float(distance / 1200.0) // ~7.7x to 15x
        } else if distance < 37040 { // < 20 NM
            return Float(distance / 1000.0) // ~18.5x to 37x
        } else {
            return Float(distance / 800.0) // > 20 NM - moderate scaling
        }
    }

    /// Create a direction arrow showing aircraft heading
    private static func createDirectionArrow(
        heading: Float,
        length: Float,
        color: UIColor
    ) -> SCNNode {

        let arrow = SCNNode()

        // Create arrow shaft - moderate size
        let shaft = SCNCylinder(radius: 0.5, height: CGFloat(length))
        let shaftMaterial = SCNMaterial()
        shaftMaterial.diffuse.contents = color
        shaftMaterial.lightingModel = .constant // Always visible
        shaft.materials = [shaftMaterial]

        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.eulerAngles.x = .pi / 2
        shaftNode.position = SCNVector3(0, 0, -length / 2)

        // Create arrow head (cone) - moderate size
        let head = SCNCone(topRadius: 0, bottomRadius: 1.5, height: 3.0)
        let headMaterial = SCNMaterial()
        headMaterial.diffuse.contents = color
        headMaterial.lightingModel = .constant // Always visible
        head.materials = [headMaterial]

        let headNode = SCNNode(geometry: head)
        headNode.eulerAngles.x = .pi / 2
        headNode.position = SCNVector3(0, 0, -length)

        arrow.addChildNode(shaftNode)
        arrow.addChildNode(headNode)

        // Rotate to match heading
        arrow.eulerAngles.y = -heading.toRadians()

        return arrow
    }

    // MARK: - Airport Components

    /// Create a blue cone marker with rounded bottom for an airport
    /// - Parameters:
    ///   - position: Position in AR scene
    ///   - airport: Airport data
    ///   - distance: Distance to airport in meters (for LOD scaling)
    /// - Returns: SCNNode containing the airport visualization
    static func createAirportMarker(
        position: SCNVector3,
        airport: Airport,
        distance: Double
    ) -> SCNNode {

        let containerNode = SCNNode()
        containerNode.name = "airport_\(airport.icao)"
        containerNode.position = position

        // Make container always face user
        let billboardConstraint = SCNBillboardConstraint()
        billboardConstraint.freeAxes = [.Y]
        containerNode.constraints = [billboardConstraint]

        // Calculate LOD scale based on distance
        let lodScale = calculateLODScale(distance: distance)

        // Create larger cone with rounded bottom - much bigger than before
        let coneHeight: CGFloat = 60.0 // Bigger
        let coneRadius: CGFloat = 25.0 // Bigger radius

        let cone = SCNCone(topRadius: 0, bottomRadius: coneRadius, height: coneHeight)
        let coneMaterial = SCNMaterial()
        coneMaterial.diffuse.contents = UIColor.systemBlue
        coneMaterial.emission.contents = UIColor.systemBlue.withAlphaComponent(0.5)
        coneMaterial.transparency = 0.7
        coneMaterial.isDoubleSided = true
        coneMaterial.lightingModel = .constant // Always visible
        cone.materials = [coneMaterial]

        let coneNode = SCNNode(geometry: cone)

        // Point cone downward
        coneNode.eulerAngles.x = .pi // 180 degrees

        // Position cone above ground
        coneNode.position = SCNVector3(0, Float(coneHeight / 2), 0)

        // Apply LOD scaling
        coneNode.scale = SCNVector3(lodScale, lodScale, lodScale)

        containerNode.addChildNode(coneNode)

        // Add rounded bottom using a hemisphere
        let hemisphere = SCNSphere(radius: coneRadius)
        hemisphere.segmentCount = 24 // Smooth sphere

        let hemisphereMaterial = SCNMaterial()
        hemisphereMaterial.diffuse.contents = UIColor.systemBlue
        hemisphereMaterial.emission.contents = UIColor.systemBlue.withAlphaComponent(0.5)
        hemisphereMaterial.transparency = 0.7
        hemisphereMaterial.lightingModel = .constant
        hemisphere.materials = [hemisphereMaterial]

        let hemisphereNode = SCNNode(geometry: hemisphere)
        hemisphereNode.position = SCNVector3(0, 0, 0) // At bottom of cone
        hemisphereNode.scale = SCNVector3(lodScale, lodScale * 0.3, lodScale) // Flatten to hemisphere

        containerNode.addChildNode(hemisphereNode)

        // Add ICAO code label hovering above the cone
        let labelNode = createTextLabelWithBackground(
            text: airport.icao,
            textColor: .white,
            position: SCNVector3(0, Float(coneHeight) + 40, 0) // Hover higher above node
        )
        labelNode.scale = SCNVector3(1.0 * lodScale, 1.0 * lodScale, 1.0 * lodScale)
        containerNode.addChildNode(labelNode)

        // Add subtle rotation animation to the cone
        let rotate = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 10.0)
        let repeatRotate = SCNAction.repeatForever(rotate)
        coneNode.runAction(repeatRotate)
        hemisphereNode.runAction(repeatRotate)

        return containerNode
    }

    // MARK: - Text Labels

    /// Create a 3D text label
    /// - Parameters:
    ///   - text: Text to display
    ///   - color: Text color
    ///   - position: Position relative to parent
    /// - Returns: SCNNode containing the text
    static func createTextLabel(
        text: String,
        color: UIColor,
        position: SCNVector3
    ) -> SCNNode {

        let textGeometry = SCNText(string: text, extrusionDepth: 1.0)
        textGeometry.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        textGeometry.flatness = 0.1

        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = color
        textMaterial.emission.contents = color.withAlphaComponent(0.5)
        textGeometry.materials = [textMaterial]

        let textNode = SCNNode(geometry: textGeometry)
        textNode.position = position

        // Center the text
        let (min, max) = textNode.boundingBox
        let width = max.x - min.x
        textNode.pivot = SCNMatrix4MakeTranslation(width / 2, 0, 0)

        // Make text always face the camera (billboard effect)
        let constraint = SCNBillboardConstraint()
        constraint.freeAxes = [.Y]
        textNode.constraints = [constraint]

        return textNode
    }

    /// Create a 3D text label with gray rounded rectangle background
    /// - Parameters:
    ///   - text: Text to display
    ///   - textColor: Text color
    ///   - position: Position relative to parent
    /// - Returns: SCNNode containing the text with background
    static func createTextLabelWithBackground(
        text: String,
        textColor: UIColor,
        position: SCNVector3
    ) -> SCNNode {

        let containerNode = SCNNode()
        containerNode.position = position

        // Create text - larger size
        let textGeometry = SCNText(string: text, extrusionDepth: 0.5)
        textGeometry.font = UIFont.systemFont(ofSize: 16, weight: .bold) // Bigger text
        textGeometry.flatness = 0.1
        textGeometry.alignmentMode = CATextLayerAlignmentMode.center.rawValue

        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = textColor
        textMaterial.emission.contents = textColor.withAlphaComponent(0.8)
        textMaterial.lightingModel = .constant
        textGeometry.materials = [textMaterial]

        let textNode = SCNNode(geometry: textGeometry)

        // Center the text
        let (minBound, maxBound) = textNode.boundingBox
        let textWidth = maxBound.x - minBound.x
        let textHeight = maxBound.y - minBound.y
        textNode.pivot = SCNMatrix4MakeTranslation((minBound.x + maxBound.x) / 2, (minBound.y + maxBound.y) / 2, 0)

        // Create gray rounded rectangle background
        let padding: CGFloat = 4.0
        let bgWidth = CGFloat(textWidth) + padding * 2
        let bgHeight = CGFloat(textHeight) + padding * 2
        let cornerRadius = bgHeight * 0.3 // Rounded corners

        let background = SCNPlane(width: bgWidth, height: bgHeight)
        background.cornerRadius = cornerRadius

        let bgMaterial = SCNMaterial()
        bgMaterial.diffuse.contents = UIColor.darkGray.withAlphaComponent(0.85)
        bgMaterial.lightingModel = .constant
        bgMaterial.isDoubleSided = true
        background.materials = [bgMaterial]

        let backgroundNode = SCNNode(geometry: background)
        backgroundNode.position = SCNVector3(0, 0, -1) // Behind text

        // Add background and text to container
        containerNode.addChildNode(backgroundNode)
        containerNode.addChildNode(textNode)

        // Make entire container face camera (billboard effect)
        let constraint = SCNBillboardConstraint()
        constraint.freeAxes = [.Y]
        containerNode.constraints = [constraint]

        return containerNode
    }

    // MARK: - Helper Components

    /// Create a ground reference grid (optional, for debugging)
    static func createReferenceGrid(size: Float, divisions: Int) -> SCNNode {
        let gridNode = SCNNode()

        let step = size / Float(divisions)
        let halfSize = size / 2

        for i in 0...divisions {
            let offset = Float(i) * step - halfSize

            // Vertical lines
            let vLine = createLine(
                from: SCNVector3(offset, 0, -halfSize),
                to: SCNVector3(offset, 0, halfSize),
                color: .gray
            )
            gridNode.addChildNode(vLine)

            // Horizontal lines
            let hLine = createLine(
                from: SCNVector3(-halfSize, 0, offset),
                to: SCNVector3(halfSize, 0, offset),
                color: .gray
            )
            gridNode.addChildNode(hLine)
        }

        return gridNode
    }

    /// Create a line between two points
    private static func createLine(
        from: SCNVector3,
        to: SCNVector3,
        color: UIColor
    ) -> SCNNode {

        let vector = SCNVector3(to.x - from.x, to.y - from.y, to.z - from.z)
        let length = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)

        let cylinder = SCNCylinder(radius: 0.1, height: CGFloat(length))
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(0.3)
        cylinder.materials = [material]

        let lineNode = SCNNode(geometry: cylinder)

        // Position and orient the line
        lineNode.position = SCNVector3(
            (from.x + to.x) / 2,
            (from.y + to.y) / 2,
            (from.z + to.z) / 2
        )

        // Orient the line to point from 'from' to 'to'
        lineNode.look(at: to, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))

        return lineNode
    }

    // MARK: - Update Methods

    /// Update an existing aircraft marker with new data and smooth prediction
    static func updateAircraftMarker(
        node: SCNNode,
        aircraft: Aircraft,
        newPosition: SCNVector3,
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double
    ) {
        // Calculate time since last update
        let timeSinceUpdate = Date().timeIntervalSince(aircraft.lastUpdate)

        // Predict future position to smooth out updates
        // Assume next update will come in ~3 seconds (typical ADSB update rate)
        let predictionTime = 3.0

        let (predictedCoord, predictedAlt) = CalculationsLogic.predictPosition(
            currentCoord: aircraft.coordinate,
            currentAltitude: aircraft.altitude,
            track: aircraft.track,
            groundSpeed: aircraft.groundSpeed,
            verticalRate: aircraft.verticalRate,
            timeSeconds: predictionTime
        )

        // Calculate AR position for predicted location
        let predictedPosition = CalculationsLogic.calculateARPosition(
            targetCoord: predictedCoord,
            targetAltitude: predictedAlt,
            userCoord: userLocation,
            userAltitude: userAltitude,
            userHeading: userHeading
        )

        // Use SCNTransaction for smooth, non-synchronized animation
        SCNTransaction.begin()
        SCNTransaction.animationDuration = predictionTime
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .linear)

        // Animate to predicted position over the prediction time
        node.position = predictedPosition

        SCNTransaction.commit()

        // Update label if callsign changed
        if let labelNode = node.childNode(withName: "label", recursively: false) {
            if let textGeometry = labelNode.geometry as? SCNText {
                textGeometry.string = aircraft.callsign
            }
        }

        // Smoothly update direction arrow to match track
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 1.0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        if let arrowNode = node.childNode(withName: "arrow", recursively: false) {
            arrowNode.eulerAngles.y = -Float(aircraft.track).toRadians()
        }

        SCNTransaction.commit()
    }
}

// MARK: - Settings and Configuration

struct ARVisualizationSettings {
    // Aircraft settings
    var showAircraft: Bool = true
    var aircraftMinDistance: Double = 200.0 // Don't show aircraft closer than 200 meters

    // Airport settings
    var showAirports: Bool = true
    var airportMinDistance: Double = 300.0 // Don't show airports closer than 300 meters

    // Display settings
    var showGrid: Bool = false
    var showLabels: Bool = true
    var labelScale: Float = 1.0

    // Update settings
    var updateInterval: TimeInterval = 1.0 // seconds

    // Colors
    var aircraftColor: UIColor = .red
    var airportColor: UIColor = .systemBlue
    var labelColor: UIColor = .white

    // Use AppSettings for user-configurable options
    var aircraftMaxDistance: Double {
        return AppSettings.shared.aircraftMaxDistance.rawValue
    }

    var airportMaxDistance: Double {
        return AppSettings.shared.airportMaxDistance.rawValue
    }
}

// MARK: - Scene Manager

/// Manages the AR scene and updates visualizations
class ARSceneManager {

    private weak var sceneView: ARSCNView?
    private var aircraftNodes: [String: SCNNode] = [:]
    private var airportNodes: [String: SCNNode] = [:]
    var settings = ARVisualizationSettings()

    init(sceneView: ARSCNView) {
        self.sceneView = sceneView
        setupScene()
    }

    private func setupScene() {
        sceneView?.autoenablesDefaultLighting = true
        sceneView?.automaticallyUpdatesLighting = true
    }

    /// Update aircraft visualizations
    func updateAircraft(
        _ aircraft: [Aircraft],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double
    ) {
        guard settings.showAircraft else {
            print("⚠️ Aircraft display is disabled in settings")
            return
        }

        if aircraft.isEmpty {
            return // Silent when no aircraft
        }

        let userMsg = "🔄 Updating \(aircraft.count) aircraft. User: lat=\(String(format: "%.4f", userLocation.latitude)), lon=\(String(format: "%.4f", userLocation.longitude)), alt=\(Int(userAltitude))ft MSL, hdg=\(Int(userHeading))°"
        print(userMsg)
        DebugConsole.shared.log(userMsg)

        var currentAircraftIDs = Set<String>()

        for ac in aircraft {
            // Apply app settings filters
            if !AppSettings.shared.shouldShowAircraft(ac) {
                print("⏭️  Skipping \(ac.callsign) - filtered by settings (ground aircraft)")
                continue
            }

            // Calculate distance first to check minimum distance
            let distance = CalculationsLogic.distance(
                from: userLocation,
                to: ac.coordinate
            )

            // Skip aircraft that are too close (would block user's view)
            if distance < settings.aircraftMinDistance {
                print("⏭️  Skipping \(ac.callsign) - too close (\(Int(distance))m < \(Int(settings.aircraftMinDistance))m minimum)")
                // Don't add to currentAircraftIDs so it will be removed by cleanup logic
                continue
            }

            // Track that we're displaying this aircraft
            currentAircraftIDs.insert(ac.id)

            // Calculate AR position
            let position = CalculationsLogic.calculateARPosition(
                targetCoord: ac.coordinate,
                targetAltitude: ac.altitude,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading
            )

            let distanceNM = distance / CalculationsLogic.nauticalMileToMeters
            let radius = CalculationsLogic.calculateAircraftCircleRadius(distance: distance)
            let bearing = CalculationsLogic.bearing(from: userLocation, to: ac.coordinate)

            // Comprehensive debug logging for ALL aircraft
            let altDiff = ac.altitude - userAltitude
            let isNew = aircraftNodes[ac.id] == nil
            let statusIcon = isNew ? "✨ NEW" : "🔄 UPD"
            let lodScale = ARComponentFactory.calculateLODScale(distance: distance)

            if isNew {
                // Log new aircraft to debug console
                let acMsg = "\(statusIcon) [\(ac.source)] \(ac.callsign): \(String(format: "%.1f", distanceNM))NM, \(Int(ac.altitude))ft, bearing \(Int(bearing))°"
                DebugConsole.shared.log(acMsg)
            }

            print("\(statusIcon) [\(ac.source)] \(ac.callsign):")
            print("     Target: lat=\(String(format: "%.4f", ac.latitude)), lon=\(String(format: "%.4f", ac.longitude)), alt=\(Int(ac.altitude))ft MSL")
            print("     Distance: \(String(format: "%.1f", distanceNM))NM (\(Int(distance))m), Bearing: \(Int(bearing))°")
            print("     Alt diff: \(Int(altDiff))ft (\(altDiff > 0 ? "ABOVE" : "BELOW") user)")
            print("     AR position: x=\(String(format: "%.1f", position.x))m, y=\(String(format: "%.1f", position.y))m, z=\(String(format: "%.1f", position.z))m")
            print("     Circle radius: \(Int(radius))m, LOD scale: \(String(format: "%.1f", lodScale))x")

            // Check if position is reasonable for AR visibility
            let positionMagnitude = sqrt(position.x * position.x + position.y * position.y + position.z * position.z)
            if positionMagnitude > 100000 { // > 100km
                print("     ⚠️  WARNING: Position magnitude very large (\(Int(positionMagnitude))m) - may not be visible!")
            }
            if abs(position.y) > 10000 { // > 10km vertical
                print("     ⚠️  WARNING: Large vertical separation (\(Int(position.y))m) - may not be visible!")
            }

            // Update or create node
            if let existingNode = aircraftNodes[ac.id] {
                ARComponentFactory.updateAircraftMarker(
                    node: existingNode,
                    aircraft: ac,
                    newPosition: position,
                    userLocation: userLocation,
                    userAltitude: userAltitude,
                    userHeading: userHeading
                )
            } else {
                let node = ARComponentFactory.createAircraftMarker(
                    radius: radius,
                    position: position,
                    aircraft: ac,
                    distance: distance
                )
                sceneView?.scene.rootNode.addChildNode(node)
                aircraftNodes[ac.id] = node
            }
        }

        // Remove aircraft that are no longer present
        let removedAircraft = Set(aircraftNodes.keys).subtracting(currentAircraftIDs)
        for id in removedAircraft {
            aircraftNodes[id]?.removeFromParentNode()
            aircraftNodes.removeValue(forKey: id)
            print("🗑️  Removed AR node for aircraft \(id)")
        }

        let statusMsg = "📊 AR Scene Status: \(aircraftNodes.count) aircraft nodes active"
        print(statusMsg)
        DebugConsole.shared.log(statusMsg)
    }

    /// Update airport visualizations
    func updateAirports(
        _ airports: [Airport],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double
    ) {
        guard settings.showAirports else {
            print("⚠️ Airport display is disabled in settings")
            return
        }

        // Filter airports in range
        let nearbyAirports = CalculationsLogic.filterAirportsInRange(
            airports: airports,
            userCoord: userLocation,
            maxRangeNauticalMiles: settings.airportMaxDistance
        )

        if !nearbyAirports.isEmpty && airportNodes.isEmpty {
            let airportMsg = "🛫 Found \(nearbyAirports.count) nearby airports (within \(Int(settings.airportMaxDistance))NM of \(airports.count) total)"
            print(airportMsg)
            DebugConsole.shared.log(airportMsg)
        }

        var currentAirportIDs = Set<String>()

        for airport in nearbyAirports {
            // Apply app settings filters for airport type
            if !AppSettings.shared.shouldShowAirport(airport) {
                print("⏭️  Skipping airport \(airport.icao) - filtered by settings (type: \(airport.type ?? "unknown"))")
                continue
            }

            // Calculate distance first to check minimum distance
            let distance = CalculationsLogic.distance(
                from: userLocation,
                to: airport.coordinate
            )

            // Skip airports that are too close (would block user's view)
            if distance < settings.airportMinDistance {
                print("⏭️  Skipping airport \(airport.icao) - too close (\(Int(distance))m < \(Int(settings.airportMinDistance))m minimum)")
                // Don't add to currentAirportIDs so it will be removed by cleanup logic
                continue
            }

            // Track that we're displaying this airport
            currentAirportIDs.insert(airport.icao)

            // Calculate AR position
            let position = CalculationsLogic.calculateAirportARPosition(
                airportCoord: airport.coordinate,
                airportElevation: airport.elevation,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading
            )

            let distanceNM = distance / CalculationsLogic.nauticalMileToMeters
            let bearing = CalculationsLogic.bearing(from: userLocation, to: airport.coordinate)
            let altDiff = airport.elevation - userAltitude

            // Create or update node
            if airportNodes[airport.icao] == nil {
                let node = ARComponentFactory.createAirportMarker(
                    position: position,
                    airport: airport,
                    distance: distance
                )
                sceneView?.scene.rootNode.addChildNode(node)
                airportNodes[airport.icao] = node

                let lodScale = ARComponentFactory.calculateLODScale(distance: distance)
                print("✨ NEW Airport \(airport.icao) (\(airport.name)):")
                print("     Location: lat=\(String(format: "%.4f", airport.latitude)), lon=\(String(format: "%.4f", airport.longitude)), elev=\(Int(airport.elevation))ft MSL")
                print("     Distance: \(String(format: "%.1f", distanceNM))NM (\(Int(distance))m), Bearing: \(Int(bearing))°")
                print("     Elev diff: \(Int(altDiff))ft (\(altDiff > 0 ? "ABOVE" : "BELOW") user)")
                print("     AR position: x=\(String(format: "%.1f", position.x))m, y=\(String(format: "%.1f", position.y))m, z=\(String(format: "%.1f", position.z))m")
                print("     LOD scale: \(String(format: "%.1f", lodScale))x")

                // Check if position is reasonable
                let positionMagnitude = sqrt(position.x * position.x + position.y * position.y + position.z * position.z)
                if positionMagnitude > 100000 {
                    print("     ⚠️  WARNING: Position magnitude very large (\(Int(positionMagnitude))m) - may not be visible!")
                }
                if abs(position.y) > 10000 {
                    print("     ⚠️  WARNING: Large vertical separation (\(Int(position.y))m) - may not be visible!")
                }
            }
        }

        // Remove airports that are out of range
        let removedAirports = Set(airportNodes.keys).subtracting(currentAirportIDs)
        for icao in removedAirports {
            airportNodes[icao]?.removeFromParentNode()
            airportNodes.removeValue(forKey: icao)
            print("🗑️  Removed AR node for airport \(icao)")
        }

        print("📊 AR Scene Status: \(airportNodes.count) airport nodes active")
    }

    /// Clear all visualizations
    func clearAll() {
        for node in aircraftNodes.values {
            node.removeFromParentNode()
        }
        aircraftNodes.removeAll()

        for node in airportNodes.values {
            node.removeFromParentNode()
        }
        airportNodes.removeAll()
    }
}
