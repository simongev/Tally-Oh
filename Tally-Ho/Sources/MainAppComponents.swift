//
//  MainAppComponents.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Contains all AR visualization components:
//  - Flat billboard red ring around aircraft (always faces camera)
//  - Solid blue rounded-base inverted cones for airports
//  - Text labels with opaque background panels
//

import Foundation
import SceneKit
import ARKit
import UIKit

// MARK: - AR Component Factory

class ARComponentFactory {

    // MARK: - Sizing Constants

    static let maxARRadius: Float = 80.0
    static let minARRadius: Float = 5.0

    /// Radius of the flat red ring (metres in AR space).
    static let aircraftRingRadius: Float  = 3.0
    static let aircraftRingThickness: Float = 0.35   // half-width of the ring stroke

    /// Airport cone dimensions (metres in AR space).
    static let coneHeight: CGFloat = 8.0
    static let coneBaseRadius: CGFloat = 2.0

    /// Label font size (1 scene-unit ≈ 1 m).
    static let labelFontSize: CGFloat        = 1.1
    static let labelFontSizeAirport: CGFloat = 1.2

    /// Padding added around the label text background (scene units).
    static let labelPadding: Float = 0.35

    // MARK: - Position Scaling

    /// Scale the horizontal distance from the camera into [minARRadius, maxARRadius],
    /// preserving the compass bearing. `raw` is already camera-relative
    /// (calculateARPosition adds cameraWorldPosition). We subtract it back,
    /// scale the offset, then re-add it so the final position is in world space.
    static func scaledPosition(_ raw: SCNVector3, relativeTo cam: SCNVector3 = .init()) -> SCNVector3 {
        let dx = raw.x - cam.x
        let dz = raw.z - cam.z
        let horizLen = sqrt(dx * dx + dz * dz)
        guard horizLen > 0 else { return SCNVector3(cam.x, raw.y, cam.z - minARRadius) }
        let clamped = max(minARRadius, min(maxARRadius, horizLen))
        let scale   = clamped / horizLen
        return SCNVector3(cam.x + dx * scale, raw.y, cam.z + dz * scale)
    }

    /// Like scaledPosition but for airports — forces Y 2 m above camera.
    static func scaledAirportPosition(_ raw: SCNVector3, relativeTo cam: SCNVector3 = .init()) -> SCNVector3 {
        var s = scaledPosition(raw, relativeTo: cam)
        s.y = cam.y + 2.0
        return s
    }

    // MARK: - Aircraft Marker

    /// Create a flat red ring that always faces the camera, with an optional label.
    static func createAircraftMarker(
        rawPosition: SCNVector3,
        aircraft: Aircraft,
        cameraWorldPosition: SCNVector3 = .init(),
        settings: ARVisualizationSettings
    ) -> SCNNode {

        let container = SCNNode()
        container.name = "aircraft_\(aircraft.id)"
        container.position = scaledPosition(rawPosition, relativeTo: cameraWorldPosition)

        // -- Flat ring: a thin torus with zero extrusion depth, billboard-constrained --
        // We use an SCNPlane textured with a ring image drawn via Core Graphics,
        // so it is always perfectly flat and camera-facing.
        let ringSize = aircraftRingRadius * 2.2   // overall diameter with some margin
        let plane = SCNPlane(width: CGFloat(ringSize), height: CGFloat(ringSize))
        plane.cornerRadius = 0

        let ringImage = makeRingImage(
            outerRadius: CGFloat(aircraftRingRadius),
            thickness:   CGFloat(aircraftRingThickness),
            color:       UIColor(red: 1, green: 0.15, blue: 0.15, alpha: 1)
        )
        let planeMat = SCNMaterial()
        planeMat.diffuse.contents   = ringImage
        planeMat.emission.contents  = ringImage
        planeMat.isDoubleSided      = true
        planeMat.transparencyMode   = .aOne
        plane.materials = [planeMat]

        let ringNode = SCNNode(geometry: plane)
        // Billboard: always face camera on ALL axes so the ring stays flat to screen
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all   // fully camera-facing on all axes
        ringNode.constraints = [billboard]

        // Pulsing scale animation
        let scaleUp   = SCNAction.scale(to: 1.12, duration: 0.85)
        let scaleDown = SCNAction.scale(to: 1.0,  duration: 0.85)
        scaleUp.timingMode   = .easeInEaseOut
        scaleDown.timingMode = .easeInEaseOut
        ringNode.runAction(.repeatForever(.sequence([scaleUp, scaleDown])))

        container.addChildNode(ringNode)

        // -- Label --
        if settings.showAircraftLabels {
            let text = buildAircraftLabelText(aircraft: aircraft, settings: settings)
            let labelNode = createLabelNode(
                text: text,
                textColor: .white,
                bgColor: UIColor(white: 0, alpha: 0.72),
                fontSize: labelFontSize,
                yOffset: CGFloat(aircraftRingRadius) + 0.9
            )
            container.addChildNode(labelNode)
        }

        return container
    }

    /// Draw a ring (annulus) into a UIImage for use as a plane texture.
    private static func makeRingImage(
        outerRadius: CGFloat,
        thickness: CGFloat,
        color: UIColor
    ) -> UIImage {
        let dim = Int((outerRadius * 2 + 4).rounded()) * 16   // high-res for crisp anti-aliasing
        let size = CGSize(width: dim, height: dim)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let centre  = CGPoint(x: CGFloat(dim) / 2, y: CGFloat(dim) / 2)
            let scale   = CGFloat(dim) / (outerRadius * 2 + 4)
            let outerPx = outerRadius * scale
            let innerPx = (outerRadius - thickness) * scale

            // outer circle
            ctx.cgContext.addEllipse(in: CGRect(
                x: centre.x - outerPx, y: centre.y - outerPx,
                width: outerPx * 2, height: outerPx * 2))
            // inner circle (clip out centre)
            ctx.cgContext.addEllipse(in: CGRect(
                x: centre.x - innerPx, y: centre.y - innerPx,
                width: innerPx * 2, height: innerPx * 2))

            ctx.cgContext.setFillColor(color.cgColor)
            // even-odd rule cuts the inner hole
            ctx.cgContext.fillPath(using: .evenOdd)
        }
    }

    // MARK: - Aircraft Label Text

    static func buildAircraftLabelText(aircraft: Aircraft, settings: ARVisualizationSettings) -> String {
        var parts: [String] = []

        // Line 1: callsign (always shown as part of label if labels are on)
        var line1 = aircraft.callsign
        if settings.showAircraftType && !aircraft.aircraftType.isEmpty {
            line1 += " / \(aircraft.aircraftType)"
        }
        parts.append(line1)

        if settings.showAircraftAltitude {
            parts.append(String(format: "%.0f ft", aircraft.altitude))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Airport Marker

    /// Solid blue inverted cone with a rounded (sphere-capped) base at the top.
    static func createAirportMarker(
        rawPosition: SCNVector3,
        airport: Airport,
        distanceNM: Double,
        cameraWorldPosition: SCNVector3 = .init(),
        settings: ARVisualizationSettings
    ) -> SCNNode {

        let container = SCNNode()
        container.name = "airport_\(airport.icao)"
        let scaled = scaledAirportPosition(rawPosition, relativeTo: cameraWorldPosition)
        container.position = scaled

        let blue = UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)

        // Main cone (solid, no transparency)
        let cone = SCNCone(topRadius: 0, bottomRadius: coneBaseRadius, height: coneHeight)
        let coneMat = SCNMaterial()
        coneMat.diffuse.contents  = blue
        coneMat.emission.contents = UIColor(red: 0.05, green: 0.25, blue: 0.6, alpha: 1)
        coneMat.isDoubleSided     = true
        cone.materials = [coneMat]

        let coneNode = SCNNode(geometry: cone)
        coneNode.eulerAngles.x = .pi                      // tip points down
        coneNode.position = SCNVector3(0, Float(coneHeight / 2), 0)
        container.addChildNode(coneNode)

        // Rounded cap: sphere sitting at the base (top) of the inverted cone
        let capRadius = coneBaseRadius * 0.55
        let sphere = SCNSphere(radius: capRadius)
        let sphereMat = SCNMaterial()
        sphereMat.diffuse.contents  = blue
        sphereMat.emission.contents = UIColor(red: 0.05, green: 0.25, blue: 0.6, alpha: 1)
        sphere.materials = [sphereMat]
        let capNode = SCNNode(geometry: sphere)
        capNode.position = SCNVector3(0, Float(coneHeight), 0)   // top of cone
        container.addChildNode(capNode)

        // Slow rotation on the whole container
        container.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14.0)))

        // Label
        if settings.showAirportLabels {
            let text = buildAirportLabelText(airport: airport, distanceNM: distanceNM, settings: settings)
            let labelNode = createLabelNode(
                text: text,
                textColor: .white,
                bgColor: UIColor(red: 0.0, green: 0.15, blue: 0.45, alpha: 0.82),
                fontSize: labelFontSizeAirport,
                yOffset: CGFloat(coneHeight) + CGFloat(capRadius) + 1.0
            )
            container.addChildNode(labelNode)
        }

        return container
    }

    static func buildAirportLabelText(airport: Airport, distanceNM: Double, settings: ARVisualizationSettings) -> String {
        var parts: [String] = [airport.icao]
        if settings.showAirportDistance {
            parts.append(String(format: "%.1f NM", distanceNM))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Label with Background

    /// Creates a label node: 3D text with an opaque rounded-rect background that
    /// auto-sizes to the text. The whole node is billboard-constrained to always
    /// face the camera.
    static func createLabelNode(
        text: String,
        textColor: UIColor,
        bgColor: UIColor,
        fontSize: CGFloat,
        yOffset: CGFloat
    ) -> SCNNode {

        // Render text + background into a UIImage so we get crisp pixels at any angle
        let image = makeLabelImage(text: text, textColor: textColor, bgColor: bgColor, fontSize: fontSize)

        // Scale: 1 scene-unit wide per ~80 pts of image width keeps text readable
        let scale: CGFloat = fontSize / 80.0
        let w = CGFloat(image.size.width)  * scale
        let h = CGFloat(image.size.height) * scale

        let plane = SCNPlane(width: w, height: h)
        plane.cornerRadius = 0
        let mat = SCNMaterial()
        mat.diffuse.contents   = image
        mat.emission.contents  = image
        mat.isDoubleSided      = true
        mat.transparencyMode   = .aOne
        plane.materials = [mat]

        let node = SCNNode(geometry: plane)
        node.position = SCNVector3(0, Float(yOffset + h / 2), 0)

        let bill = SCNBillboardConstraint()
        bill.freeAxes = .all   // fully camera-facing on all axes
        node.constraints = [bill]

        return node
    }

    /// Render multi-line text with a semi-opaque rounded-rect background into a UIImage.
    static func makeLabelImage(
        text: String,
        textColor: UIColor,
        bgColor: UIColor,
        fontSize: CGFloat
    ) -> UIImage {
        let font      = UIFont.boldSystemFont(ofSize: fontSize * 80)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = .center
        paraStyle.lineSpacing = fontSize * 6

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paraStyle
        ]
        let attrStr  = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.boundingRect(
            with: CGSize(width: 2000, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size

        let hPad: CGFloat = fontSize * 28
        let vPad: CGFloat = fontSize * 20
        let imgW  = ceil(textSize.width  + hPad * 2)
        let imgH  = ceil(textSize.height + vPad * 2)
        let corner = fontSize * 22

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: imgW, height: imgH))
        return renderer.image { ctx in
            // Background rounded rect
            let rect = CGRect(x: 0, y: 0, width: imgW, height: imgH)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: corner)
            bgColor.setFill()
            path.fill()

            // Text centred in the rect
            let textRect = CGRect(
                x: hPad, y: vPad,
                width: textSize.width, height: textSize.height
            )
            attrStr.draw(in: textRect)
        }
    }

    // MARK: - Update

    static func updateAircraftMarker(
        node: SCNNode,
        aircraft: Aircraft,
        rawPosition: SCNVector3,
        cameraWorldPosition: SCNVector3 = .init(),
        settings: ARVisualizationSettings
    ) {
        // Position update is handled by the caller (ARSceneManager) with duration 0.22s
        let _ = scaledPosition(rawPosition, relativeTo: cameraWorldPosition) // computed but move done by caller

        // Refresh label: find the plane node used for the label (not the ring plane)
        // Ring plane is the first child; label is the second child if present.
        let labelNode = node.childNodes.first(where: {
            $0.geometry is SCNPlane && $0 !== node.childNodes.first
        })

        let shouldShow = settings.showAircraftLabels
        if let lbl = labelNode {
            lbl.isHidden = !shouldShow
            if shouldShow, let plane = lbl.geometry as? SCNPlane {
                let text  = buildAircraftLabelText(aircraft: aircraft, settings: settings)
                let image = makeLabelImage(text: text, textColor: .white,
                                           bgColor: UIColor(white: 0, alpha: 0.72),
                                           fontSize: labelFontSize)
                let scale: CGFloat = labelFontSize / 80.0
                let w = CGFloat(image.size.width)  * scale
                let h = CGFloat(image.size.height) * scale
                plane.width  = w
                plane.height = h
                plane.materials.first?.diffuse.contents  = image
                plane.materials.first?.emission.contents = image
                lbl.position = SCNVector3(0, Float(CGFloat(aircraftRingRadius) + 0.9 + h / 2), 0)
            }
        }
    }
}

// MARK: - Settings

struct ARVisualizationSettings {

    // MARK: Aircraft
    var showAircraft: Bool = true
    var aircraftMaxDistance: Double = 50.0

    // Aircraft label fields
    var showCallsign:        Bool = true   // always included in label when labels on
    var showAircraftType:    Bool = true
    var showAircraftAltitude:Bool = true

    // Callsign filter — empty string = show all
    var callsignFilter: String = ""

    /// Derived: show label if any label field is enabled
    var showAircraftLabels: Bool { showAircraftType || showAircraftAltitude || showCallsign }

    /// Returns true if this aircraft passes the callsign filter.
    func passes(callsign: String) -> Bool {
        let f = callsignFilter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !f.isEmpty else { return true }
        return callsign.uppercased().contains(f)
    }

    // MARK: Airports
    var showAirports: Bool = true
    var airportMaxDistance: Double = 50.0

    var showLargeAirports:  Bool = true
    var showMediumAirports: Bool = true
    var showSmallAirports:  Bool = true

    var showAirportDistance: Bool = true

    var showAirportLabels: Bool { showAirportDistance }

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
        userHeading: Double,
        cameraWorldPosition: SCNVector3 = .init()
    ) {
        guard settings.showAircraft else {
            aircraftNodes.values.forEach { $0.isHidden = true }
            return
        }

        var currentIDs = Set<String>()

        for ac in aircraft {
            // Distance filter against reported position (not predicted)
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: ac.coordinate)
            guard distNM <= settings.aircraftMaxDistance else { continue }

            // Callsign filter
            guard settings.passes(callsign: ac.callsign) else { continue }

            currentIDs.insert(ac.id)

            // Predict where this aircraft is right now, accounting for report age
            // and the typical ~5 s one-way propagation delay via internet.
            let extrapolationSecs: Double = (ac.source == .internet) ? 5.0 : 0.0
            let (predCoord, predAlt) = CalculationsLogic.predictedPosition(
                for: ac, aheadSeconds: extrapolationSecs)

            let rawPos = CalculationsLogic.calculateARPosition(
                targetCoord: predCoord,
                targetAltitude: predAlt,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading,
                cameraWorldPosition: cameraWorldPosition
            )

            if let existing = aircraftNodes[ac.id] {
                existing.isHidden = false
                // Move smoothly: duration 0.25 s matches the 4 Hz update rate
                let scaled = ARComponentFactory.scaledPosition(rawPos, relativeTo: cameraWorldPosition)
                existing.runAction(.move(to: scaled, duration: 0.22))
                ARComponentFactory.updateAircraftMarker(
                    node: existing,
                    aircraft: ac,
                    rawPosition: rawPos,
                    cameraWorldPosition: cameraWorldPosition,
                    settings: settings
                )
            } else {
                let node = ARComponentFactory.createAircraftMarker(
                    rawPosition: rawPos,
                    aircraft: ac,
                    cameraWorldPosition: cameraWorldPosition,
                    settings: settings
                )
                sceneView?.scene.rootNode.addChildNode(node)
                aircraftNodes[ac.id] = node
            }
        }

        // Remove aircraft that are out of range, filtered, or stale
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
        userHeading: Double,
        cameraWorldPosition: SCNVector3 = .init()
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
                userHeading: userHeading,
                cameraWorldPosition: cameraWorldPosition
            )
            let distNM = CalculationsLogic.distanceInNauticalMiles(
                from: userLocation,
                to: airport.coordinate
            )

            if let existing = airportNodes[airport.icao] {
                existing.isHidden = false
                // Smooth repositioning for airports (they don't move, but user does)
                let scaled = ARComponentFactory.scaledAirportPosition(rawPos, relativeTo: cameraWorldPosition)
                existing.runAction(.move(to: scaled, duration: 0.22))
                // Update label distance
                let labelNode = existing.childNodes.first(where: { ($0.geometry as? SCNPlane) != nil })
                if let lbl = labelNode, let plane = lbl.geometry as? SCNPlane {
                    let text  = ARComponentFactory.buildAirportLabelText(
                        airport: airport, distanceNM: distNM, settings: settings)
                    let image = ARComponentFactory.makeLabelImage(
                        text: text, textColor: .white,
                        bgColor: UIColor(red: 0.0, green: 0.15, blue: 0.45, alpha: 0.82),
                        fontSize: ARComponentFactory.labelFontSizeAirport)
                    let scale: CGFloat = ARComponentFactory.labelFontSizeAirport / 80.0
                    let w = CGFloat(image.size.width)  * scale
                    let h = CGFloat(image.size.height) * scale
                    plane.width  = w
                    plane.height = h
                    plane.materials.first?.diffuse.contents  = image
                    plane.materials.first?.emission.contents = image
                    lbl.isHidden = !settings.showAirportLabels
                }
            } else {
                let node = ARComponentFactory.createAirportMarker(
                    rawPosition: rawPos,
                    airport: airport,
                    distanceNM: distNM,
                    cameraWorldPosition: cameraWorldPosition,
                    settings: settings
                )
                sceneView?.scene.rootNode.addChildNode(node)
                airportNodes[airport.icao] = node
            }
        }

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
