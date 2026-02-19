//
//  MainAppComponents.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Contains all AR visualization components:
//  - Red circles around aircraft
//  - Blue inverted cones for airports
//  - Text labels
//

import Foundation
import SceneKit
import ARKit
import UIKit

// MARK: - AR Component Factory

/// Factory class for creating AR visualization components
class ARComponentFactory {

    // MARK: - Sizing Constants

    /// Maximum distance (meters) any marker is placed from the camera in the AR scene.
    /// All real-world positions are scaled into this "viewable bubble" so they are always visible.
    static let maxARRadius: Float = 150.0

    /// Minimum AR placement distance (meters) — keeps very nearby targets off the nose.
    static let minARRadius: Float = 8.0

    /// Radius of the red torus ring around aircraft (meters in AR space).
    static let aircraftRingRadius: Float = 18.0
    static let aircraftPipeRadius: CGFloat = 1.8

    /// Airport cone dimensions (meters in AR space).
    static let coneHeight: CGFloat = 60.0
    static let coneBaseRadius: CGFloat = 14.0

    /// Label font size — SCNText uses points where 1 pt ≈ 1 m in scene units.
    static let labelFontSize: CGFloat = 4.0
    static let labelFontSizeAirport: CGFloat = 5.0

    // MARK: - Position Scaling

    /// Scale a raw AR position vector so it falls within [minARRadius, maxARRadius] metres
    /// from the origin while preserving direction. This keeps all targets visible in the
    /// AR "viewable bubble" regardless of real-world distance.
    static func scaledPosition(_ raw: SCNVector3) -> SCNVector3 {
        let len = sqrt(raw.x * raw.x + raw.y * raw.y + raw.z * raw.z)
        guard len > 0 else { return SCNVector3(0, minARRadius, 0) }
        let clamped = max(minARRadius, min(maxARRadius, len))
        let scale = clamped / len
        return SCNVector3(raw.x * scale, raw.y * scale, raw.z * scale)
    }

    // MARK: - Aircraft Components

    /// Create a red circle to represent an aircraft in AR.
    static func createAircraftMarker(
        rawPosition: SCNVector3,
        aircraft: Aircraft,
        settings: ARVisualizationSettings
    ) -> SCNNode {

        let containerNode = SCNNode()
        containerNode.name = "aircraft_\(aircraft.id)"
        containerNode.position = scaledPosition(rawPosition)

        // Red torus ring
        let circle = SCNTorus(ringRadius: CGFloat(aircraftRingRadius), pipeRadius: aircraftPipeRadius)
        let circleMaterial = SCNMaterial()
        circleMaterial.diffuse.contents = UIColor.red
        circleMaterial.emission.contents = UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.6)
        circleMaterial.isDoubleSided = true
        circle.materials = [circleMaterial]

        let circleNode = SCNNode(geometry: circle)
        // Rotate torus to lie in the horizontal plane (parallel to ground)
        circleNode.eulerAngles.x = .pi / 2
        containerNode.addChildNode(circleNode)

        // Pulsing animation
        let scaleUp   = SCNAction.scale(to: 1.15, duration: 0.9)
        let scaleDown = SCNAction.scale(to: 1.0,  duration: 0.9)
        circleNode.runAction(.repeatForever(.sequence([scaleUp, scaleDown])))

        // Label
        if settings.showAircraftLabels {
            let labelText = buildAircraftLabelText(aircraft: aircraft, settings: settings)
            let labelNode = createTextLabel(
                text: labelText,
                color: .white,
                fontSize: labelFontSize,
                position: SCNVector3(0, aircraftRingRadius + 6, 0)
            )
            containerNode.addChildNode(labelNode)
        }

        // Direction arrow
        let arrowNode = createDirectionArrow(
            heading: Float(aircraft.track),
            length: aircraftRingRadius * 1.4,
            color: .yellow
        )
        containerNode.addChildNode(arrowNode)

        return containerNode
    }

    /// Build the aircraft label string based on settings toggles.
    static func buildAircraftLabelText(aircraft: Aircraft, settings: ARVisualizationSettings) -> String {
        var parts: [String] = []

        // Line 1: callsign [/ type]
        var line1 = aircraft.callsign
        if settings.showAircraftType && !aircraft.aircraftType.isEmpty {
            line1 += " / \(aircraft.aircraftType)"
        }
        parts.append(line1)

        // Line 2: altitude
        if settings.showAircraftAltitude {
            parts.append(String(format: "%.0f ft", aircraft.altitude))
        }

        return parts.joined(separator: "\n")
    }

    /// Create a direction arrow showing aircraft heading.
    private static func createDirectionArrow(
        heading: Float,
        length: Float,
        color: UIColor
    ) -> SCNNode {

        let arrow = SCNNode()

        let shaft = SCNCylinder(radius: 0.4, height: CGFloat(length))
        let shaftMat = SCNMaterial()
        shaftMat.diffuse.contents = color
        shaft.materials = [shaftMat]
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.eulerAngles.x = .pi / 2
        shaftNode.position = SCNVector3(0, 0, -length / 2)

        let head = SCNCone(topRadius: 0, bottomRadius: 1.8, height: 3.5)
        let headMat = SCNMaterial()
        headMat.diffuse.contents = color
        head.materials = [headMat]
        let headNode = SCNNode(geometry: head)
        headNode.eulerAngles.x = .pi / 2
        headNode.position = SCNVector3(0, 0, -length)

        arrow.addChildNode(shaftNode)
        arrow.addChildNode(headNode)
        arrow.eulerAngles.y = -heading.toRadians()

        return arrow
    }

    // MARK: - Airport Components

    /// Create a blue inverted-cone marker for an airport.
    /// The cone tip points down toward the airport, base extends upward — like a beacon
    /// hanging from the sky above the airport location.
    static func createAirportMarker(
        rawPosition: SCNVector3,
        airport: Airport,
        distanceNM: Double,
        settings: ARVisualizationSettings
    ) -> SCNNode {

        let containerNode = SCNNode()
        containerNode.name = "airport_\(airport.icao)"
        // Place at the scaled horizontal position but force the Y to a comfortable
        // eye-level height so the cone is always visible (airports are on the ground,
        // user may be at similar altitude — the cone hangs above the location).
        var scaled = scaledPosition(rawPosition)
        // Ensure the cone is at least 10 m above the user's eye level so it's visible
        if scaled.y < 10 { scaled.y = 10 }
        containerNode.position = scaled

        let cone = SCNCone(topRadius: 0, bottomRadius: coneBaseRadius, height: coneHeight)
        let coneMat = SCNMaterial()
        coneMat.diffuse.contents = UIColor.systemBlue
        coneMat.emission.contents = UIColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.5)
        coneMat.transparency = 0.35
        coneMat.isDoubleSided = true
        cone.materials = [coneMat]

        let coneNode = SCNNode(geometry: cone)
        // Flip 180° → topRadius (0, the tip) is now at the BOTTOM, base at the TOP
        coneNode.eulerAngles.x = .pi
        // Move so the tip (bottom) sits exactly at the container origin (airport ground point)
        // SCNCone origin is at its centre, height is coneHeight, so centre is coneHeight/2 above tip
        coneNode.position = SCNVector3(0, Float(coneHeight / 2), 0)
        containerNode.addChildNode(coneNode)

        // Subtle slow rotation
        coneNode.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 12.0)))

        // Label above the cone base
        if settings.showAirportLabels {
            let labelText = buildAirportLabelText(airport: airport, distanceNM: distanceNM, settings: settings)
            let labelNode = createTextLabel(
                text: labelText,
                color: .cyan,
                fontSize: labelFontSizeAirport,
                position: SCNVector3(0, Float(coneHeight) + 8, 0)
            )
            containerNode.addChildNode(labelNode)
        }

        return containerNode
    }

    /// Build the airport label string based on settings toggles.
    static func buildAirportLabelText(airport: Airport, distanceNM: Double, settings: ARVisualizationSettings) -> String {
        var parts: [String] = [airport.icao]

        if settings.showAirportDistance {
            parts.append(String(format: "%.1f NM", distanceNM))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Text Labels

    /// Create a 3D text label that always faces the camera.
    static func createTextLabel(
        text: String,
        color: UIColor,
        fontSize: CGFloat,
        position: SCNVector3
    ) -> SCNNode {

        let textGeometry = SCNText(string: text, extrusionDepth: 0.2)
        textGeometry.font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        textGeometry.flatness = 0.05
        textGeometry.alignmentMode = CATextLayerAlignmentMode.center.rawValue

        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.7)
        mat.isDoubleSided = true
        textGeometry.materials = [mat]

        let textNode = SCNNode(geometry: textGeometry)
        textNode.position = position

        // Centre the text horizontally
        let (minB, maxB) = textNode.boundingBox
        let w = maxB.x - minB.x
        let h = maxB.y - minB.y
        textNode.pivot = SCNMatrix4MakeTranslation(w / 2, h / 2, 0)

        // Billboard — always face the camera, free to rotate around Y
        let constraint = SCNBillboardConstraint()
        constraint.freeAxes = [.Y]
        textNode.constraints = [constraint]

        return textNode
    }

    // MARK: - Update Methods

    /// Smoothly move an existing aircraft node to a new raw position and refresh its label.
    static func updateAircraftMarker(
        node: SCNNode,
        aircraft: Aircraft,
        rawPosition: SCNVector3,
        settings: ARVisualizationSettings
    ) {
        let newPos = scaledPosition(rawPosition)
        node.runAction(.move(to: newPos, duration: 1.0))

        // Refresh label text
        if let labelNode = node.childNodes.first(where: { $0.geometry is SCNText }) {
            if let geo = labelNode.geometry as? SCNText {
                geo.string = buildAircraftLabelText(aircraft: aircraft, settings: settings)
            }
            labelNode.isHidden = !settings.showAircraftLabels
        }
    }
}

// MARK: - Settings and Configuration

struct ARVisualizationSettings {

    // MARK: Aircraft
    var showAircraft: Bool = true
    var aircraftMaxDistance: Double = 50.0  // nautical miles

    // Aircraft label fields
    var showAircraftLabels: Bool  = true
    var showAircraftType:   Bool  = true   // e.g. "B738"
    var showAircraftAltitude: Bool = true  // e.g. "35000 ft"

    // MARK: Airports
    var showAirports: Bool = true
    var airportMaxDistance: Double = 50.0  // nautical miles

    // Airport type filters
    var showLargeAirports:  Bool = true
    var showMediumAirports: Bool = true
    var showSmallAirports:  Bool = true

    // Airport label fields
    var showAirportLabels:   Bool = true
    var showAirportDistance: Bool = true   // e.g. "14.3 NM"

    // MARK: Misc
    var showGrid: Bool = false

    /// Returns true if the given airport type should be displayed.
    func shouldShow(airportType: String) -> Bool {
        switch airportType {
        case "large_airport":  return showLargeAirports
        case "medium_airport": return showMediumAirports
        case "small_airport":  return showSmallAirports
        default:               return false
        }
    }
}

// MARK: - Scene Manager

/// Manages the AR scene and updates visualizations.
class ARSceneManager {

    private weak var sceneView: ARSCNView?
    private var aircraftNodes: [String: SCNNode] = [:]
    private var airportNodes:  [String: SCNNode] = [:]
    var settings = ARVisualizationSettings()

    init(sceneView: ARSCNView) {
        self.sceneView = sceneView
        sceneView.autoenablesDefaultLighting = true
        sceneView.automaticallyUpdatesLighting = true
    }

    // MARK: Update Aircraft

    func updateAircraft(
        _ aircraft: [Aircraft],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double
    ) {
        guard settings.showAircraft else {
            // Hide all existing nodes
            aircraftNodes.values.forEach { $0.isHidden = true }
            return
        }

        var currentIDs = Set<String>()

        for ac in aircraft {
            // Distance filter
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: ac.coordinate)
            guard distNM <= settings.aircraftMaxDistance else { continue }

            currentIDs.insert(ac.id)

            let rawPos = CalculationsLogic.calculateARPosition(
                targetCoord: ac.coordinate,
                targetAltitude: ac.altitude,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading
            )

            if let existing = aircraftNodes[ac.id] {
                existing.isHidden = false
                ARComponentFactory.updateAircraftMarker(
                    node: existing,
                    aircraft: ac,
                    rawPosition: rawPos,
                    settings: settings
                )
            } else {
                let node = ARComponentFactory.createAircraftMarker(
                    rawPosition: rawPos,
                    aircraft: ac,
                    settings: settings
                )
                sceneView?.scene.rootNode.addChildNode(node)
                aircraftNodes[ac.id] = node
            }
        }

        // Remove stale aircraft
        for id in Set(aircraftNodes.keys).subtracting(currentIDs) {
            aircraftNodes[id]?.removeFromParentNode()
            aircraftNodes.removeValue(forKey: id)
        }
    }

    // MARK: Update Airports

    func updateAirports(
        _ airports: [Airport],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double
    ) {
        guard settings.showAirports else {
            airportNodes.values.forEach { $0.isHidden = true }
            return
        }

        let nearby = CalculationsLogic.filterAirportsInRange(
            airports: airports,
            userCoord: userLocation,
            maxRangeNauticalMiles: settings.airportMaxDistance
        ).filter { settings.shouldShow(airportType: $0.type) }

        var currentIDs = Set<String>()

        for airport in nearby {
            currentIDs.insert(airport.icao)

            let rawPos = CalculationsLogic.calculateAirportARPosition(
                airportCoord: airport.coordinate,
                airportElevation: airport.elevation,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading
            )
            let distNM = CalculationsLogic.distanceInNauticalMiles(
                from: userLocation,
                to: airport.coordinate
            )

            if let existing = airportNodes[airport.icao] {
                existing.isHidden = false
                // Update label distance (user may have moved)
                if let labelNode = existing.childNodes.first(where: { $0.geometry is SCNText }),
                   let geo = labelNode.geometry as? SCNText {
                    geo.string = ARComponentFactory.buildAirportLabelText(
                        airport: airport,
                        distanceNM: distNM,
                        settings: settings
                    )
                    labelNode.isHidden = !settings.showAirportLabels
                }
            } else {
                let node = ARComponentFactory.createAirportMarker(
                    rawPosition: rawPos,
                    airport: airport,
                    distanceNM: distNM,
                    settings: settings
                )
                sceneView?.scene.rootNode.addChildNode(node)
                airportNodes[airport.icao] = node
            }
        }

        // Remove out-of-range airports
        for icao in Set(airportNodes.keys).subtracting(currentIDs) {
            airportNodes[icao]?.removeFromParentNode()
            airportNodes.removeValue(forKey: icao)
        }
    }

    // MARK: Clear

    func clearAll() {
        aircraftNodes.values.forEach { $0.removeFromParentNode() }
        aircraftNodes.removeAll()
        airportNodes.values.forEach { $0.removeFromParentNode() }
        airportNodes.removeAll()
    }
}
