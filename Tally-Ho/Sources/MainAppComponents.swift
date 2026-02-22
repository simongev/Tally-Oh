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
    static let labelFontSize: CGFloat        = 1.5
    static let labelFontSizeAirport: CGFloat = 1.6

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

    /// Like scaledPosition but for airports — preserves the computed elevation Y.
    static func scaledAirportPosition(_ raw: SCNVector3, relativeTo cam: SCNVector3 = .init()) -> SCNVector3 {
        return scaledPosition(raw, relativeTo: cam)
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

        if settings.showAircraftSpeed {
            parts.append(String(format: "%.0f kts", aircraft.groundSpeed))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Selection Appearance

    /// Apply or remove the selected visual state on a container node.
    /// Aircraft ring: yellow, larger. Airport cone: cyan, larger.
    static func applySelectedAppearance(to container: SCNNode, selected: Bool) {
        if selected {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.15
            container.scale = SCNVector3(1.35, 1.35, 1.35)
            SCNTransaction.commit()
            // Tint every geometry in the container
            container.enumerateChildNodes { node, _ in
                if let mat = node.geometry?.firstMaterial {
                    if node.geometry is SCNCone {
                        // Airport cone → cyan
                        mat.diffuse.contents  = UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
                        mat.emission.contents = UIColor(red: 0.0, green: 0.4,  blue: 0.6, alpha: 1.0)
                    } else if node.geometry is SCNTorus {
                        // Aircraft ring → yellow
                        mat.diffuse.contents  = UIColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 1.0)
                        mat.emission.contents = UIColor(red: 0.5, green: 0.4, blue: 0.0, alpha: 1.0)
                    }
                }
            }
        } else {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.15
            container.scale = SCNVector3(1.0, 1.0, 1.0)
            SCNTransaction.commit()
            // Restore original colours
            container.enumerateChildNodes { node, _ in
                if let mat = node.geometry?.firstMaterial {
                    if node.geometry is SCNCone {
                        mat.diffuse.contents  = UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)
                        mat.emission.contents = UIColor(red: 0.05, green: 0.25, blue: 0.6, alpha: 1.0)
                    } else if node.geometry is SCNTorus {
                        mat.diffuse.contents  = UIColor.red
                        mat.emission.contents = UIColor(red: 0.4, green: 0.0, blue: 0.0, alpha: 1.0)
                    }
                }
            }
        }
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

        // Main cone — small non-zero topRadius gives a blunt/flat tip instead of a sharp point
        let cone = SCNCone(topRadius: coneBaseRadius * 0.18, bottomRadius: coneBaseRadius, height: coneHeight)
        let coneMat = SCNMaterial()
        coneMat.diffuse.contents  = blue
        coneMat.emission.contents = UIColor(red: 0.05, green: 0.25, blue: 0.6, alpha: 1)
        coneMat.isDoubleSided     = true
        cone.materials = [coneMat]

        let coneNode = SCNNode(geometry: cone)
        coneNode.eulerAngles.x = .pi                      // tip points down
        coneNode.position = SCNVector3(0, Float(coneHeight / 2), 0)
        container.addChildNode(coneNode)

        // Slow rotation on the whole container
        container.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14.0)))

        // Label sits above the wide base (top) of the cone
        if settings.showAirportLabels {
            let text = buildAirportLabelText(airport: airport, distanceNM: distanceNM, settings: settings)
            let labelNode = createLabelNode(
                text: text,
                textColor: .white,
                bgColor: UIColor(red: 0.0, green: 0.15, blue: 0.45, alpha: 0.82),
                fontSize: labelFontSizeAirport,
                yOffset: CGFloat(coneHeight) + 1.0
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
            // Only regenerate the label image when the text actually changes —
            // altitude rounds to the nearest foot so re-renders are infrequent.
            if shouldShow, let plane = lbl.geometry as? SCNPlane {
                let newText = buildAircraftLabelText(aircraft: aircraft, settings: settings)
                if newText != lbl.name {
                    lbl.name = newText   // cache rendered text in node name
                    let image = makeLabelImage(text: newText, textColor: .white,
                                               bgColor: UIColor(white: 0, alpha: 0.72),
                                               fontSize: labelFontSize)
                    let scale: CGFloat = labelFontSize / 80.0
                    let w = CGFloat(image.size.width)  * scale
                    let h = CGFloat(image.size.height) * scale
                    SCNTransaction.begin()
                    SCNTransaction.disableActions = true
                    plane.width  = w
                    plane.height = h
                    plane.materials.first?.diffuse.contents  = image
                    plane.materials.first?.emission.contents = image
                    lbl.position = SCNVector3(0, Float(CGFloat(aircraftRingRadius) + 0.9 + h / 2), 0)
                    SCNTransaction.commit()
                }
            }
        }
    }
}

// MARK: - Settings

struct ARVisualizationSettings {

    // MARK: Aircraft
    var showAircraft: Bool = true
    var aircraftMaxDistance: Double = 20.0

    // Aircraft label fields
    var showCallsign:        Bool = true   // always included in label when labels on
    var showAircraftType:    Bool = true
    var showAircraftAltitude:Bool = true

    // Callsign filter — empty string = show all
    var callsignFilter: String = ""

    // Whether to show ground speed in the aircraft label
    var showAircraftSpeed: Bool = true

    /// Derived: show label if any label field is enabled
    var showAircraftLabels: Bool { showAircraftType || showAircraftAltitude || showCallsign || showAircraftSpeed }

    /// Returns true if this aircraft passes the callsign filter.
    func passes(callsign: String) -> Bool {
        let f = callsignFilter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !f.isEmpty else { return true }
        return callsign.uppercased().contains(f)
    }

    // MARK: Airports
    var showAirports: Bool = true
    var airportMaxDistance: Double = 40.0

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
    /// Protected by `nodesLock` — read on render thread, written on main thread.
    private var aircraftNodes: [String: SCNNode] = [:]
    private var airportNodes:  [String: SCNNode] = [:]
    /// Serialises access to `aircraftNodes` between the main thread (4 Hz writes)
    /// and the SceneKit render thread (60 Hz reads in tickAircraftPositions).
    private let nodesLock = NSLock()
    var settings = ARVisualizationSettings()

    // MARK: Selection
    private(set) var selectedNodeID: String? = nil
    /// The last selection ID for which `applySelectionToAllNodes` was fully applied.
    /// Used to skip redundant re-application on every 4 Hz tick (which caused blinking).
    private var lastAppliedSelectionID: String? = "___unset___"
    /// Called on the main thread when the currently selected node is removed.
    var onSelectionInvalidated: (() -> Void)?

    // Live snapshot written on main thread, read on render thread.
    // Replacing the whole array value is atomic on 64-bit ARM; elements are
    // never mutated in-place, so no lock is needed for this snapshot.
    private(set) var liveAircraft: [Aircraft] = []
    private(set) var liveUserLocation: CLLocationCoordinate2D = CLLocationCoordinate2D()
    private(set) var liveUserAltitude: Double = 0

    /// Continuously-updated correction for the angular offset between ARKit's
    /// world-north (frozen at session start) and the live compass true-north.
    /// Written on the main thread by ARTrafficViewController.didUpdateHeading;
    /// read on the render thread by tickAircraftPositions — a Double assignment
    /// is atomic on 64-bit ARM so no lock is needed.
    var arKitNorthCorrectionDeg: Double = 0

    init(sceneView: ARSCNView) {
        self.sceneView = sceneView
        sceneView.autoenablesDefaultLighting = true
        sceneView.automaticallyUpdatesLighting = true
    }

    // MARK: - 60 Hz Position Update (called from ARSCNViewDelegate renderer)

    /// Update only node *positions* — called every display frame for maximum accuracy.
    /// Labels, visibility and node creation are handled by the 4 Hz `updateAircraft`.
    func tickAircraftPositions(cameraWorldPosition: SCNVector3) {
        guard settings.showAircraft else { return }

        // Snapshot aircraft data (written by main thread — array replacement is atomic).
        let aircraft = liveAircraft
        let userLoc  = liveUserLocation
        let userAlt  = liveUserAltitude

        // Take a locked snapshot of the node references so the render thread
        // never races with main-thread insertions/removals in aircraftNodes.
        nodesLock.lock()
        let nodeSnapshot = aircraftNodes   // [String: SCNNode] value-copy of the dict
        nodesLock.unlock()

        let northCorrection = arKitNorthCorrectionDeg   // snapshot for this tick

        for ac in aircraft {
            guard let node = nodeSnapshot[ac.id], !node.isHidden else { continue }
            // No fixed latency offset — `lastUpdate` is stamped with the actual response
            // receipt time (ConnectionLogic.mergeInternetAircraft), so `predictedPosition`
            // already compensates for the real data age dynamically for both ADS-B and
            // internet sources.
            let (predCoord, predAlt) = CalculationsLogic.predictedPosition(
                for: ac, aheadSeconds: 0)
            let rawPos = CalculationsLogic.calculateARPosition(
                targetCoord: predCoord,
                targetAltitude: predAlt,
                userCoord: userLoc,
                userAltitude: userAlt,
                userHeading: 0,
                cameraWorldPosition: cameraWorldPosition,
                northCorrectionDeg: northCorrection
            )
            // Direct assignment — no SCNAction, no interpolation lag.
            let scaled = ARComponentFactory.scaledPosition(rawPos, relativeTo: cameraWorldPosition)
            node.simdPosition = simd_float3(scaled.x, scaled.y, scaled.z)
        }
    }

    // MARK: - 4 Hz Update (node lifecycle + labels)

    func updateAircraft(
        _ aircraft: [Aircraft],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double,
        cameraWorldPosition: SCNVector3 = .init()
    ) {
        guard settings.showAircraft else {
            nodesLock.lock()
            let all = Array(aircraftNodes.values)
            nodesLock.unlock()
            all.forEach { $0.isHidden = true }
            liveAircraft = []
            return
        }

        var currentIDs = Set<String>()
        var visibleAircraft: [Aircraft] = []
        var nodesAdded = false

        for ac in aircraft {
            // Skip aircraft on or very near the ground (≤ 50 ft MSL — taxiing, parked)
            guard ac.altitude > 50 else { continue }

            // Distance filter against reported position (not predicted)
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: ac.coordinate)
            guard distNM <= settings.aircraftMaxDistance else { continue }

            // Callsign filter
            guard settings.passes(callsign: ac.callsign) else { continue }

            currentIDs.insert(ac.id)
            visibleAircraft.append(ac)

            let (predCoord, predAlt) = CalculationsLogic.predictedPosition(
                for: ac, aheadSeconds: 0)
            let rawPos = CalculationsLogic.calculateARPosition(
                targetCoord: predCoord,
                targetAltitude: predAlt,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading,
                cameraWorldPosition: cameraWorldPosition,
                northCorrectionDeg: arKitNorthCorrectionDeg
            )

            if let existing = aircraftNodes[ac.id] {
                existing.isHidden = false
                // Position is now driven at 60 Hz by tickAircraftPositions —
                // just update the label here.
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
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                sceneView?.scene.rootNode.addChildNode(node)
                SCNTransaction.commit()
                nodesLock.lock()
                aircraftNodes[ac.id] = node
                nodesLock.unlock()
                nodesAdded = true
            }
        }

        // Store snapshot for 60 Hz position ticking
        liveAircraft      = visibleAircraft
        liveUserLocation  = userLocation
        liveUserAltitude  = userAltitude

        // Remove aircraft that are out of range, filtered, or stale
        nodesLock.lock()
        let staleIDs = Set(aircraftNodes.keys).subtracting(currentIDs)
        var staleNodes: [SCNNode] = []
        var selectedWasRemoved = false
        for id in staleIDs {
            if let n = aircraftNodes[id] { staleNodes.append(n) }
            if "aircraft_\(id)" == selectedNodeID { selectedWasRemoved = true }
            aircraftNodes.removeValue(forKey: id)
        }
        nodesLock.unlock()
        for n in staleNodes {
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            n.removeFromParentNode()
            SCNTransaction.commit()
        }
        if selectedWasRemoved {
            DispatchQueue.main.async { [weak self] in self?.onSelectionInvalidated?() }
        }

        // Reapply selection visuals if any node was added or removed (new nodes
        // won't have the correct label-hidden / colour state yet).
        if nodesAdded || !staleNodes.isEmpty {
            lastAppliedSelectionID = "___unset___"
        }
        applySelectionToAllNodes()
    }

    // MARK: Update Airports

    func updateAirports(
        _ airports: [Airport],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double,
        cameraWorldPosition: SCNVector3 = .init()
    ) {
        // Build the set of airports that should be visible right now
        let nearby: [Airport]
        if settings.showAirports {
            nearby = CalculationsLogic.filterAirportsInRange(
                airports: airports,
                userCoord: userLocation,
                maxRangeNauticalMiles: settings.airportMaxDistance
            ).filter { settings.shouldShow(airportType: $0.type) }
        } else {
            nearby = []
        }

        let visibleIDs = Set(nearby.map { $0.icao })

        // Build the set of all airports tracked in our node dict so we can
        // look up any airport that has a node but is not currently in range.
        // We need the full airport list for hiding/showing existing nodes.
        let allTrackedAirports: [String: Airport] = Dictionary(
            uniqueKeysWithValues: airports.compactMap { a in
                airportNodes[a.icao] != nil ? (a.icao, a) : nil
            }
        )

        var airportNodesAdded = false
        for airport in nearby {
            let rawPos = CalculationsLogic.calculateAirportARPosition(
                airportCoord: airport.coordinate,
                airportElevation: airport.elevation,
                userCoord: userLocation,
                userAltitude: userAltitude,
                userHeading: userHeading,
                cameraWorldPosition: cameraWorldPosition,
                northCorrectionDeg: arKitNorthCorrectionDeg
            )
            let distNM = CalculationsLogic.distanceInNauticalMiles(
                from: userLocation,
                to: airport.coordinate
            )

            if let existing = airportNodes[airport.icao] {
                existing.isHidden = false
                // Airports are static — update position directly, no animation needed.
                let scaled = ARComponentFactory.scaledAirportPosition(rawPos, relativeTo: cameraWorldPosition)
                existing.position = scaled
                // Only regenerate the label image when the displayed text changes
                let labelNode = existing.childNodes.first(where: { ($0.geometry as? SCNPlane) != nil })
                if let lbl = labelNode, let plane = lbl.geometry as? SCNPlane {
                    let newText = ARComponentFactory.buildAirportLabelText(
                        airport: airport, distanceNM: distNM, settings: settings)
                    if newText != lbl.name {
                        lbl.name = newText
                        let image = ARComponentFactory.makeLabelImage(
                            text: newText, textColor: .white,
                            bgColor: UIColor(red: 0.0, green: 0.15, blue: 0.45, alpha: 0.82),
                            fontSize: ARComponentFactory.labelFontSizeAirport)
                        let scale: CGFloat = ARComponentFactory.labelFontSizeAirport / 80.0
                        let w = CGFloat(image.size.width)  * scale
                        let h = CGFloat(image.size.height) * scale
                        SCNTransaction.begin()
                        SCNTransaction.disableActions = true
                        plane.width  = w
                        plane.height = h
                        plane.materials.first?.diffuse.contents  = image
                        plane.materials.first?.emission.contents = image
                        lbl.isHidden = !settings.showAirportLabels
                        SCNTransaction.commit()
                    }
                }
            } else {
                let node = ARComponentFactory.createAirportMarker(
                    rawPosition: rawPos,
                    airport: airport,
                    distanceNM: distNM,
                    cameraWorldPosition: cameraWorldPosition,
                    settings: settings
                )
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                sceneView?.scene.rootNode.addChildNode(node)
                SCNTransaction.commit()
                airportNodes[airport.icao] = node
                airportNodesAdded = true
            }
        }

        // Hide (not remove) nodes for airports outside current range/filter —
        // hiding avoids the flicker caused by re-creating them each time the
        // pre-filter window shifts or the CSV reloads.
        for icao in Set(airportNodes.keys).subtracting(visibleIDs) {
            airportNodes[icao]?.isHidden = true
        }

        // Reapply selection visuals only if new airport nodes were added.
        if airportNodesAdded {
            lastAppliedSelectionID = "___unset___"
        }
        applySelectionToAllNodes()
    }

    // MARK: - Selection

    /// Set the selected node. Pass nil to deselect all.
    func setSelection(nodeID: String?) {
        selectedNodeID = nodeID
        lastAppliedSelectionID = "___unset___"   // force re-apply on next tick
        applySelectionToAllNodes()
    }

    /// Update label visibility and visual state for all nodes to reflect current selection.
    /// Only re-applies when the selection has actually changed; this prevents the
    /// repeated isHidden assignments that caused labels to blink on every 4 Hz tick.
    func applySelectionToAllNodes() {
        let sel = selectedNodeID
        // Skip if the selection state hasn't changed since last full apply.
        guard sel != lastAppliedSelectionID else { return }
        lastAppliedSelectionID = sel

        nodesLock.lock()
        let acSnap = aircraftNodes
        nodesLock.unlock()
        let apSnap = airportNodes

        let allContainers = Array(acSnap.values) + Array(apSnap.values)
        for container in allContainers {
            let isSelected  = (container.name == sel)
            let hasSelection = (sel != nil)
            // Hide only the label planes of unselected nodes — the ring/cone itself
            // stays visible so the user can still see all traffic.
            for child in container.childNodes {
                if child.geometry is SCNPlane {
                    child.isHidden = hasSelection && !isSelected
                }
            }
            ARComponentFactory.applySelectedAppearance(to: container, selected: isSelected)
        }
    }

    /// Thread-safe lookup of a container node by its prefixed name
    /// (e.g. "aircraft_ABC123" or "airport_KLAX").
    func node(forID nodeID: String) -> SCNNode? {
        if nodeID.hasPrefix("aircraft_") {
            let id = String(nodeID.dropFirst("aircraft_".count))
            nodesLock.lock()
            defer { nodesLock.unlock() }
            return aircraftNodes[id]
        } else if nodeID.hasPrefix("airport_") {
            let icao = String(nodeID.dropFirst("airport_".count))
            return airportNodes[icao]
        }
        return nil
    }

    // MARK: Clear

    func clearAll() {
        nodesLock.lock()
        let acNodes  = Array(aircraftNodes.values)
        let apNodes  = Array(airportNodes.values)
        aircraftNodes.removeAll()
        airportNodes.removeAll()
        nodesLock.unlock()

        liveAircraft = []

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        acNodes.forEach { $0.removeFromParentNode() }
        apNodes.forEach { $0.removeFromParentNode() }
        SCNTransaction.commit()
    }
}
