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
    /// - Returns: SCNNode containing the aircraft visualization
    static func createAircraftMarker(
        radius: Float,
        position: SCNVector3,
        aircraft: Aircraft
    ) -> SCNNode {

        let containerNode = SCNNode()
        containerNode.name = "aircraft_\(aircraft.id)"
        containerNode.position = position

        // Create red circle (torus with small thickness)
        let circle = SCNTorus(ringRadius: CGFloat(radius), pipeRadius: 2.0)
        let circleMaterial = SCNMaterial()
        circleMaterial.diffuse.contents = UIColor.red
        circleMaterial.emission.contents = UIColor.red.withAlphaComponent(0.3)
        circleMaterial.isDoubleSided = true
        circle.materials = [circleMaterial]

        let circleNode = SCNNode(geometry: circle)

        // Rotate to be horizontal (parallel to ground)
        circleNode.eulerAngles.x = .pi / 2

        containerNode.addChildNode(circleNode)

        // Add pulsing animation
        let scaleUp = SCNAction.scale(to: 1.1, duration: 1.0)
        let scaleDown = SCNAction.scale(to: 1.0, duration: 1.0)
        let pulse = SCNAction.sequence([scaleUp, scaleDown])
        let repeatPulse = SCNAction.repeatForever(pulse)
        circleNode.runAction(repeatPulse)

        // Add callsign label above the circle
        let labelNode = createTextLabel(
            text: aircraft.callsign,
            color: .red,
            position: SCNVector3(0, radius + 10, 0)
        )
        containerNode.addChildNode(labelNode)

        // Add altitude label below the callsign
        let altitudeText = String(format: "%.0f ft", aircraft.altitude)
        let altitudeNode = createTextLabel(
            text: altitudeText,
            color: .white,
            position: SCNVector3(0, radius + 5, 0)
        )
        altitudeNode.scale = SCNVector3(0.7, 0.7, 0.7)
        containerNode.addChildNode(altitudeNode)

        // Add velocity indicator (arrow showing direction)
        let arrowNode = createDirectionArrow(
            heading: Float(aircraft.track),
            length: radius * 1.5,
            color: .yellow
        )
        containerNode.addChildNode(arrowNode)

        return containerNode
    }

    /// Create a direction arrow showing aircraft heading
    private static func createDirectionArrow(
        heading: Float,
        length: Float,
        color: UIColor
    ) -> SCNNode {

        let arrow = SCNNode()

        // Create arrow shaft
        let shaft = SCNCylinder(radius: 0.5, height: CGFloat(length))
        let shaftMaterial = SCNMaterial()
        shaftMaterial.diffuse.contents = color
        shaft.materials = [shaftMaterial]

        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.eulerAngles.x = .pi / 2
        shaftNode.position = SCNVector3(0, 0, -length / 2)

        // Create arrow head (cone)
        let head = SCNCone(topRadius: 0, bottomRadius: 2, height: 4)
        let headMaterial = SCNMaterial()
        headMaterial.diffuse.contents = color
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

    /// Create a blue cone marker for an airport
    /// - Parameters:
    ///   - position: Position in AR scene
    ///   - airport: Airport data
    /// - Returns: SCNNode containing the airport visualization
    static func createAirportMarker(
        position: SCNVector3,
        airport: Airport
    ) -> SCNNode {

        let containerNode = SCNNode()
        containerNode.name = "airport_\(airport.icao)"
        containerNode.position = position

        // Create blue cone pointing down
        let coneHeight: CGFloat = 50.0
        let coneRadius: CGFloat = 15.0

        let cone = SCNCone(topRadius: 0, bottomRadius: coneRadius, height: coneHeight)
        let coneMaterial = SCNMaterial()
        coneMaterial.diffuse.contents = UIColor.systemBlue
        coneMaterial.emission.contents = UIColor.systemBlue.withAlphaComponent(0.5)
        coneMaterial.transparency = 0.8
        coneMaterial.isDoubleSided = true
        cone.materials = [coneMaterial]

        let coneNode = SCNNode(geometry: cone)

        // Point cone downward
        coneNode.eulerAngles.x = .pi // 180 degrees

        // Position cone above ground
        coneNode.position = SCNVector3(0, Float(coneHeight / 2), 0)

        containerNode.addChildNode(coneNode)

        // Add ICAO code label above the cone
        let labelNode = createTextLabel(
            text: airport.icao,
            color: .cyan,
            position: SCNVector3(0, Float(coneHeight) + 10, 0)
        )
        labelNode.scale = SCNVector3(1.5, 1.5, 1.5)
        containerNode.addChildNode(labelNode)

        // Add subtle rotation animation
        let rotate = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 10.0)
        let repeatRotate = SCNAction.repeatForever(rotate)
        coneNode.runAction(repeatRotate)

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

    /// Update an existing aircraft marker with new data
    static func updateAircraftMarker(
        node: SCNNode,
        aircraft: Aircraft,
        newPosition: SCNVector3
    ) {
        // Smoothly animate to new position
        let moveAction = SCNAction.move(to: newPosition, duration: 1.0)
        node.runAction(moveAction)

        // Update label if callsign changed
        if let labelNode = node.childNode(withName: "label", recursively: false) {
            if let textGeometry = labelNode.geometry as? SCNText {
                textGeometry.string = aircraft.callsign
            }
        }

        // Update direction arrow
        if let arrowNode = node.childNode(withName: "arrow", recursively: false) {
            let rotateAction = SCNAction.rotateTo(
                x: 0,
                y: CGFloat(-aircraft.track.toRadians()),
                z: 0,
                duration: 0.5
            )
            arrowNode.runAction(rotateAction)
        }
    }
}

// MARK: - Settings and Configuration

struct ARVisualizationSettings {
    // Aircraft settings
    var showAircraft: Bool = true
    var aircraftMinDistance: Double = 0.0 // nautical miles
    var aircraftMaxDistance: Double = 10.0 // nautical miles

    // Airport settings
    var showAirports: Bool = true
    var airportMaxDistance: Double = 20.0 // nautical miles

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
        guard settings.showAircraft else { return }

        var currentAircraftIDs = Set<String>()

        for ac in aircraft {
            currentAircraftIDs.insert(ac.id)

            // Calculate AR position
            let position = CalculationsLogic.calculateARPosition(
                targetCoord: ac.coordinate,
                targetAltitude: ac.altitude,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading
            )

            // Calculate circle radius
            let distance = CalculationsLogic.distance(
                from: userLocation,
                to: ac.coordinate
            )
            let radius = CalculationsLogic.calculateAircraftCircleRadius(distance: distance)

            // Update or create node
            if let existingNode = aircraftNodes[ac.id] {
                ARComponentFactory.updateAircraftMarker(
                    node: existingNode,
                    aircraft: ac,
                    newPosition: position
                )
            } else {
                let node = ARComponentFactory.createAircraftMarker(
                    radius: radius,
                    position: position,
                    aircraft: ac
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
        }
    }

    /// Update airport visualizations
    func updateAirports(
        _ airports: [Airport],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double
    ) {
        guard settings.showAirports else { return }

        // Filter airports in range
        let nearbyAirports = CalculationsLogic.filterAirportsInRange(
            airports: airports,
            userCoord: userLocation,
            maxRangeNauticalMiles: settings.airportMaxDistance
        )

        var currentAirportIDs = Set<String>()

        for airport in nearbyAirports {
            currentAirportIDs.insert(airport.icao)

            // Calculate AR position
            let position = CalculationsLogic.calculateAirportARPosition(
                airportCoord: airport.coordinate,
                airportElevation: airport.elevation,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading
            )

            // Create or update node
            if airportNodes[airport.icao] == nil {
                let node = ARComponentFactory.createAirportMarker(
                    position: position,
                    airport: airport
                )
                sceneView?.scene.rootNode.addChildNode(node)
                airportNodes[airport.icao] = node
            }
        }

        // Remove airports that are out of range
        let removedAirports = Set(airportNodes.keys).subtracting(currentAirportIDs)
        for icao in removedAirports {
            airportNodes[icao]?.removeFromParentNode()
            airportNodes.removeValue(forKey: icao)
        }
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
