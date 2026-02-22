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

    // MARK: - Shared geometry / material (created once, reused for every node)
    //
    // SCNGeometry and SCNMaterial are reference types — sharing them across nodes
    // is safe and avoids redundant GPU uploads of identical mesh/texture data.
    // SceneKit renders shared geometry with a single draw call per unique geometry.

    private static let sharedRingGeometry: SCNPlane = {
        let ringSize = aircraftRingRadius * 2.2
        let plane = SCNPlane(width: CGFloat(ringSize), height: CGFloat(ringSize))
        plane.cornerRadius = 0
        let ringImage = makeRingImage(
            outerRadius: CGFloat(aircraftRingRadius),
            thickness:   CGFloat(aircraftRingThickness),
            color:       UIColor(red: 1, green: 0.15, blue: 0.15, alpha: 1)
        )
        let mat = SCNMaterial()
        mat.diffuse.contents   = ringImage
        mat.emission.contents  = ringImage
        mat.isDoubleSided      = true
        mat.transparencyMode   = .aOne
        plane.materials = [mat]
        return plane
    }()

    private static let sharedConeGeometry: SCNCone = {
        let cone = SCNCone(
            topRadius:    coneBaseRadius * 0.18,
            bottomRadius: coneBaseRadius,
            height:       coneHeight
        )
        let mat = SCNMaterial()
        mat.diffuse.contents  = UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)
        mat.emission.contents = UIColor(red: 0.05, green: 0.25, blue: 0.6, alpha: 1)
        mat.isDoubleSided     = true
        cone.materials = [mat]
        return cone
    }()

    /// Cached bold font — UIFont construction is surprisingly expensive when
    /// called hundreds of times per second; create it once per font size.
    private static let labelFont: UIFont =
        UIFont.boldSystemFont(ofSize: labelFontSize * 80)
    static let labelFontAirport: UIFont =
        UIFont.boldSystemFont(ofSize: labelFontSizeAirport * 80)

    // MARK: - Position Scaling

    /// Scale the horizontal distance from the camera into [minARRadius, maxARRadius],
    /// preserving the compass bearing.
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

        // Reuse the shared ring geometry so all aircraft share a single GPU mesh.
        let ringNode = SCNNode(geometry: sharedRingGeometry)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
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
                font: labelFont,
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
        let dim = Int((outerRadius * 2 + 4).rounded()) * 16
        let size = CGSize(width: dim, height: dim)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let centre  = CGPoint(x: CGFloat(dim) / 2, y: CGFloat(dim) / 2)
            let scale   = CGFloat(dim) / (outerRadius * 2 + 4)
            let outerPx = outerRadius * scale
            let innerPx = (outerRadius - thickness) * scale
            ctx.cgContext.addEllipse(in: CGRect(
                x: centre.x - outerPx, y: centre.y - outerPx,
                width: outerPx * 2, height: outerPx * 2))
            ctx.cgContext.addEllipse(in: CGRect(
                x: centre.x - innerPx, y: centre.y - innerPx,
                width: innerPx * 2, height: innerPx * 2))
            ctx.cgContext.setFillColor(color.cgColor)
            ctx.cgContext.fillPath(using: .evenOdd)
        }
    }

    // MARK: - Aircraft Label Text

    static func buildAircraftLabelText(aircraft: Aircraft, settings: ARVisualizationSettings) -> String {
        var parts: [String] = []
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
    /// Aircraft ring: yellow glow. Airport cone: cyan. All wrapped in a single
    /// SCNTransaction so the render thread never observes a partial update.
    static func applySelectedAppearance(to container: SCNNode, selected: Bool) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15
        container.scale = selected ? SCNVector3(1.35, 1.35, 1.35) : SCNVector3(1.0, 1.0, 1.0)
        container.enumerateChildNodes { node, _ in
            guard node.name != "label",
                  let mat = node.geometry?.firstMaterial else { return }
            if node.geometry is SCNCone {
                mat.diffuse.contents  = selected
                    ? UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
                    : UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)
                mat.emission.contents = selected
                    ? UIColor(red: 0.0, green: 0.4,  blue: 0.6, alpha: 1.0)
                    : UIColor(red: 0.05, green: 0.25, blue: 0.6, alpha: 1.0)
            } else if node.geometry is SCNPlane {
                // Aircraft ring: keep diffuse texture, tint via emission only.
                mat.emission.contents = selected
                    ? UIColor(red: 0.6, green: 0.55, blue: 0.0, alpha: 0.7)
                    : UIColor(red: 0.4, green: 0.0,  blue: 0.0, alpha: 1.0)
            }
        }
        SCNTransaction.commit()
    }

    // MARK: - Airport Marker

    /// Solid blue inverted cone with a rounded (sphere-capped) base at the top.
    /// Shares geometry across all airport nodes — no rotation (saves CPU/GPU).
    static func createAirportMarker(
        rawPosition: SCNVector3,
        airport: Airport,
        distanceNM: Double,
        cameraWorldPosition: SCNVector3 = .init(),
        settings: ARVisualizationSettings
    ) -> SCNNode {

        let container = SCNNode()
        container.name = "airport_\(airport.icao)"
        container.position = scaledAirportPosition(rawPosition, relativeTo: cameraWorldPosition)

        // Reuse shared cone geometry.
        let coneNode = SCNNode(geometry: sharedConeGeometry)
        coneNode.eulerAngles.x = .pi                      // tip points down
        coneNode.position = SCNVector3(0, Float(coneHeight / 2), 0)
        container.addChildNode(coneNode)

        if settings.showAirportLabels {
            let text = buildAirportLabelText(airport: airport, distanceNM: distanceNM, settings: settings)
            let labelNode = createLabelNode(
                text: text,
                textColor: .white,
                bgColor: UIColor(red: 0.0, green: 0.15, blue: 0.45, alpha: 0.82),
                fontSize: labelFontSizeAirport,
                font: labelFontAirport,
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

    /// Creates a label node: billboard-constrained SCNPlane textured with rendered text.
    static func createLabelNode(
        text: String,
        textColor: UIColor,
        bgColor: UIColor,
        fontSize: CGFloat,
        font: UIFont,
        yOffset: CGFloat
    ) -> SCNNode {

        let image = makeLabelImage(text: text, textColor: textColor, bgColor: bgColor,
                                   fontSize: fontSize, font: font)
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
        node.name = "label"
        node.position = SCNVector3(0, Float(yOffset + h / 2), 0)

        let bill = SCNBillboardConstraint()
        bill.freeAxes = .all
        node.constraints = [bill]

        return node
    }

    /// Render multi-line text with a semi-opaque rounded-rect background into a UIImage.
    /// Accepts a pre-cached `font` to avoid redundant UIFont construction.
    static func makeLabelImage(
        text: String,
        textColor: UIColor,
        bgColor: UIColor,
        fontSize: CGFloat,
        font: UIFont? = nil
    ) -> UIImage {
        let resolvedFont = font ?? UIFont.boldSystemFont(ofSize: fontSize * 80)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = .center
        paraStyle.lineSpacing = fontSize * 6

        let attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont,
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
            let rect = CGRect(x: 0, y: 0, width: imgW, height: imgH)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: corner)
            bgColor.setFill()
            path.fill()
            let textRect = CGRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height)
            attrStr.draw(in: textRect)
        }
    }

    // MARK: - Update

    static func updateAircraftMarker(
        node: SCNNode,
        aircraft: Aircraft,
        settings: ARVisualizationSettings,
        selectedNodeID: String? = nil
    ) {
        // Refresh label: find the node named "label".
        let labelNode = node.childNode(withName: "label", recursively: false)

        let shouldShow = settings.showAircraftLabels
        if let lbl = labelNode {
            // When no selection is active, enforce settings-driven visibility.
            // When a selection IS active, applySelectionToAllNodes owns visibility.
            if selectedNodeID == nil {
                lbl.isHidden = !shouldShow
                lbl.opacity  = 1
            }

            // Only regenerate the label image when the text actually changes.
            if shouldShow, let plane = lbl.geometry as? SCNPlane {
                let newText = buildAircraftLabelText(aircraft: aircraft, settings: settings)
                if newText != plane.name {
                    plane.name = newText
                    let image = makeLabelImage(text: newText, textColor: .white,
                                               bgColor: UIColor(white: 0, alpha: 0.72),
                                               fontSize: labelFontSize, font: labelFont)
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
    var showCallsign:        Bool = true
    var showAircraftType:    Bool = true
    var showAircraftAltitude:Bool = true

    // Callsign filter — empty string = show all
    var callsignFilter: String = ""

    // Whether to show ground speed in the aircraft label
    var showAircraftSpeed: Bool = true

    /// Derived: show label if any label field is enabled
    var showAircraftLabels: Bool { showAircraftType || showAircraftAltitude || showCallsign || showAircraftSpeed }

    /// Pre-processed filter string (trimmed + uppercased) for fast matching.
    /// Recomputed only when callsignFilter changes.
    private var _normalizedFilter: String = ""
    mutating func updateFilter() {
        _normalizedFilter = callsignFilter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Returns true if this aircraft passes the callsign filter.
    func passes(callsign: String) -> Bool {
        guard !_normalizedFilter.isEmpty else { return true }
        return callsign.uppercased().contains(_normalizedFilter)
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
    private let nodesLock = NSLock()
    var settings = ARVisualizationSettings()

    // MARK: Selection
    private(set) var selectedNodeID: String? = nil
    private var lastAppliedSelectionID: String? = "___unset___"
    var onSelectionInvalidated: (() -> Void)?

    // Live snapshot written on main thread, read on render thread.
    private(set) var liveAircraft: [Aircraft] = []
    private(set) var liveUserLocation: CLLocationCoordinate2D = CLLocationCoordinate2D()
    private(set) var liveUserAltitude: Double = 0

    /// ARKit-north vs compass-north correction in degrees.
    /// Double assignment is atomic on 64-bit ARM — no lock needed.
    var arKitNorthCorrectionDeg: Double = 0

    init(sceneView: ARSCNView) {
        self.sceneView = sceneView
        // Disable SceneKit's default lighting pipeline — this app uses
        // emission-only materials so the lighting engine just wastes CPU/GPU.
        sceneView.autoenablesDefaultLighting  = false
        sceneView.automaticallyUpdatesLighting = false
    }

    // MARK: - 60 Hz Position Update

    func tickAircraftPositions(cameraWorldPosition: SCNVector3) {
        guard settings.showAircraft else { return }

        let aircraft = liveAircraft
        let userLoc  = liveUserLocation
        let userAlt  = liveUserAltitude

        nodesLock.lock()
        let nodeSnapshot = aircraftNodes
        nodesLock.unlock()

        let northCorrection = arKitNorthCorrectionDeg

        for ac in aircraft {
            guard let node = nodeSnapshot[ac.id], !node.isHidden else { continue }
            let (predCoord, predAlt) = CalculationsLogic.predictedPosition(for: ac, aheadSeconds: 0)
            let rawPos = CalculationsLogic.calculateARPosition(
                targetCoord: predCoord,
                targetAltitude: predAlt,
                userCoord: userLoc,
                userAltitude: userAlt,
                userHeading: 0,
                cameraWorldPosition: cameraWorldPosition,
                northCorrectionDeg: northCorrection
            )
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
            guard ac.altitude > 50 else { continue }

            let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: ac.coordinate)
            guard distNM <= settings.aircraftMaxDistance else { continue }
            guard settings.passes(callsign: ac.callsign) else { continue }

            currentIDs.insert(ac.id)
            visibleAircraft.append(ac)

            let (predCoord, predAlt) = CalculationsLogic.predictedPosition(for: ac, aheadSeconds: 0)
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
                ARComponentFactory.updateAircraftMarker(
                    node: existing,
                    aircraft: ac,
                    settings: settings,
                    selectedNodeID: selectedNodeID
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

        liveAircraft     = visibleAircraft
        liveUserLocation = userLocation
        liveUserAltitude = userAltitude

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
                let scaled = ARComponentFactory.scaledAirportPosition(rawPos, relativeTo: cameraWorldPosition)
                existing.position = scaled
                let labelNode = existing.childNode(withName: "label", recursively: false)
                if let lbl = labelNode, let plane = lbl.geometry as? SCNPlane {
                    let newText = ARComponentFactory.buildAirportLabelText(
                        airport: airport, distanceNM: distNM, settings: settings)
                    if newText != plane.name {
                        plane.name = newText
                        let image = ARComponentFactory.makeLabelImage(
                            text: newText, textColor: .white,
                            bgColor: UIColor(red: 0.0, green: 0.15, blue: 0.45, alpha: 0.82),
                            fontSize: ARComponentFactory.labelFontSizeAirport,
                            font: ARComponentFactory.labelFontAirport)
                        let scale: CGFloat = ARComponentFactory.labelFontSizeAirport / 80.0
                        let w = CGFloat(image.size.width)  * scale
                        let h = CGFloat(image.size.height) * scale
                        SCNTransaction.begin()
                        SCNTransaction.disableActions = true
                        plane.width  = w
                        plane.height = h
                        plane.materials.first?.diffuse.contents  = image
                        plane.materials.first?.emission.contents = image
                        SCNTransaction.commit()
                    }
                    if selectedNodeID == nil {
                        lbl.isHidden = !settings.showAirportLabels
                        lbl.opacity  = 1
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

        for icao in Set(airportNodes.keys).subtracting(visibleIDs) {
            airportNodes[icao]?.isHidden = true
        }

        if airportNodesAdded {
            lastAppliedSelectionID = "___unset___"
        }
        applySelectionToAllNodes()
    }

    // MARK: - Selection

    func setSelection(nodeID: String?) {
        selectedNodeID = nodeID
        lastAppliedSelectionID = "___unset___"
        applySelectionToAllNodes()
    }

    func applySelectionToAllNodes() {
        let sel = selectedNodeID
        guard sel != lastAppliedSelectionID else { return }
        lastAppliedSelectionID = sel

        nodesLock.lock()
        let acSnap = aircraftNodes
        nodesLock.unlock()
        let apSnap = airportNodes

        let allContainers = Array(acSnap.values) + Array(apSnap.values)
        for container in allContainers {
            let isSelected   = (container.name == sel)
            let hasSelection = (sel != nil)
            if let lbl = container.childNode(withName: "label", recursively: false) {
                let shouldHide = hasSelection && !isSelected
                if lbl.isHidden != shouldHide {
                    if shouldHide {
                        lbl.isHidden = false
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0.18
                        SCNTransaction.completionBlock = { lbl.isHidden = true }
                        lbl.opacity = 0
                        SCNTransaction.commit()
                    } else {
                        lbl.isHidden = false
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0.18
                        lbl.opacity = 1
                        SCNTransaction.commit()
                    }
                }
            }
            ARComponentFactory.applySelectedAppearance(to: container, selected: isSelected)
        }
    }

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
        let acNodes = Array(aircraftNodes.values)
        let apNodes = Array(airportNodes.values)
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
