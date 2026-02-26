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

    /// Base ring radius for normal traffic (metres in AR space).
    static let aircraftRingRadius: Float    = 3.0
    /// Ring radius for TA threats — slightly larger so they stand out.
    static let aircraftRingRadiusTA: Float  = 3.8
    /// Ring radius for RA threats — even larger, impossible to miss.
    static let aircraftRingRadiusRA: Float  = 4.6

    static let aircraftRingThickness: Float   = 0.35   // normal ring stroke half-width
    static let aircraftRingThicknessTA: Float = 0.55   // TA — noticeably thicker
    static let aircraftRingThicknessRA: Float = 0.75   // RA — boldest

    /// Airport cone dimensions (metres in AR space).
    static let coneHeight: CGFloat = 8.0
    static let coneBaseRadius: CGFloat = 2.0

    /// Label font size (1 scene-unit ≈ 1 m).
    static let labelFontSize: CGFloat        = 1.5
    static let labelFontSizeAirport: CGFloat = 1.6

    /// Ring geometry params (radius + thickness) per TCAS level.
    static func ringParams(for level: TCASAlertLevel) -> (radius: Float, thickness: Float) {
        switch level {
        case .none:               return (aircraftRingRadius,   aircraftRingThickness)
        case .trafficAdvisory:    return (aircraftRingRadiusTA, aircraftRingThicknessTA)
        case .resolutionAdvisory: return (aircraftRingRadiusRA, aircraftRingThicknessRA)
        }
    }

    // MARK: - Shared geometry / material (created once, reused for every node)

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

    /// Label image cache — avoids re-rendering UIGraphicsImageRenderer for text
    /// that hasn't changed. Aircraft labels update at most a few times per minute
    /// (altitude, speed, distance), so cache hits are very frequent.
    /// Bounded to 50 entries (~2 MB max) so it can't grow unbounded.
    private static let labelImageCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 50
        return c
    }()

    // MARK: - Pre-cached ring images & materials per TCAS level
    // Images and SCNMaterials are created once and shared across all aircraft nodes.
    // Each level gets its own radius + thickness so TCAS rings are visually distinct.

    private static let ringImageNormal: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadius),
        thickness:   CGFloat(aircraftRingThickness),
        color: UIColor(red: 1, green: 0.15, blue: 0.15, alpha: 1))

    private static let ringImageTA: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadiusTA),
        thickness:   CGFloat(aircraftRingThicknessTA),
        color: UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1.0))

    private static let ringImageRA: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadiusRA),
        thickness:   CGFloat(aircraftRingThicknessRA),
        color: UIColor(red: 1.0, green: 0.15, blue: 0.0, alpha: 1.0))

    static func ringImage(for level: TCASAlertLevel) -> UIImage {
        switch level {
        case .none:               return ringImageNormal
        case .trafficAdvisory:    return ringImageTA
        case .resolutionAdvisory: return ringImageRA
        }
    }

    /// Shared SCNMaterial per TCAS level — all aircraft of the same level share one
    /// material object, cutting GPU texture uploads from N to 3.
    /// NOTE: selection appearance must copy the material before mutating it.
    private static let ringMaterialNormal: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents  = ringImageNormal
        m.emission.contents = ringImageNormal
        m.isDoubleSided     = true
        m.transparencyMode  = .aOne
        return m
    }()
    private static let ringMaterialTA: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents  = ringImageTA
        m.emission.contents = ringImageTA
        m.isDoubleSided     = true
        m.transparencyMode  = .aOne
        return m
    }()
    private static let ringMaterialRA: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents  = ringImageRA
        m.emission.contents = ringImageRA
        m.isDoubleSided     = true
        m.transparencyMode  = .aOne
        return m
    }()

    static func ringMaterial(for level: TCASAlertLevel) -> SCNMaterial {
        switch level {
        case .none:               return ringMaterialNormal
        case .trafficAdvisory:    return ringMaterialTA
        case .resolutionAdvisory: return ringMaterialRA
        }
    }

    /// The SCNPlane size needed to fit a ring at the given TCAS level.
    private static func ringPlaneSize(for level: TCASAlertLevel) -> CGFloat {
        CGFloat(ringParams(for: level).radius) * 2.2
    }

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

    // MARK: - TCAS Colors

    /// Ring color and glow for a given TCAS alert level.
    static func aircraftRingColors(for tcasLevel: TCASAlertLevel) -> (fill: UIColor, glow: UIColor) {
        switch tcasLevel {
        case .none:
            return (UIColor(red: 1, green: 0.15, blue: 0.15, alpha: 1),
                    UIColor(red: 1, green: 0.2,  blue: 0.2,  alpha: 0.6))
        case .trafficAdvisory:
            return (UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1.0),
                    UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.8))
        case .resolutionAdvisory:
            return (UIColor(red: 1.0, green: 0.2, blue: 0.0, alpha: 1.0),
                    UIColor(red: 1.0, green: 0.3, blue: 0.0, alpha: 1.0))
        }
    }

    /// Pulse parameters (peak scale, half-cycle duration) for a given TCAS level.
    /// Higher urgency = faster cycle + larger scale pop.
    static func pulseParams(for tcasLevel: TCASAlertLevel) -> (maxScale: CGFloat, halfDuration: Double) {
        switch tcasLevel {
        case .none:               return (1.12, 0.90)   // subtle, slow
        case .trafficAdvisory:    return (1.30, 0.45)   // noticeable, moderate speed
        case .resolutionAdvisory: return (1.50, 0.22)   // urgent, fast, large pop
        }
    }

    // MARK: - Aircraft Marker

    /// Create a flat ring billboard with an optional label.
    static func createAircraftMarker(
        rawPosition: SCNVector3,
        aircraft: Aircraft,
        distanceNM: Double = 0,
        cameraWorldPosition: SCNVector3 = .init(),
        settings: ARVisualizationSettings,
        tcasLevel: TCASAlertLevel = .none
    ) -> SCNNode {

        let container = SCNNode()
        container.name = "aircraft_\(aircraft.id)"
        container.position = scaledPosition(rawPosition, relativeTo: cameraWorldPosition)

        // Ring plane — uses shared material per TCAS level so the GPU texture is
        // uploaded only once and reused across all aircraft nodes at that level.
        let ringSize = ringPlaneSize(for: tcasLevel)
        let plane = SCNPlane(width: ringSize, height: ringSize)
        plane.materials = [ringMaterial(for: tcasLevel)]

        let ringNode = SCNNode(geometry: plane)
        ringNode.name = "ring"
        ringNode.accessibilityLabel = String(tcasLevel.rawValue)   // level tag for material restore
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        ringNode.constraints = [billboard]

        // Pulsing animation — speed AND scale amplitude reflect TCAS urgency
        let (pulseMax, halfDur) = pulseParams(for: tcasLevel)
        let scaleUp   = SCNAction.scale(to: pulseMax, duration: halfDur)
        let scaleDown = SCNAction.scale(to: 1.0,      duration: halfDur)
        scaleUp.timingMode   = .easeInEaseOut
        scaleDown.timingMode = .easeInEaseOut
        ringNode.runAction(.repeatForever(.sequence([scaleUp, scaleDown])))

        container.addChildNode(ringNode)

        // Label — always created so it can be shown/hidden dynamically
        let text = buildAircraftLabelText(aircraft: aircraft, distanceNM: distanceNM, settings: settings)
        let labelNode = createLabelNode(
            text: text,
            textColor: .white,
            bgColor: UIColor(white: 0, alpha: 0.72),
            fontSize: labelFontSize,
            font: labelFont,
            yOffset: CGFloat(aircraftRingRadius) + 0.9
        )
        labelNode.isHidden = !settings.showAircraftLabels
        container.addChildNode(labelNode)

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

    static func buildAircraftLabelText(aircraft: Aircraft, distanceNM: Double = 0, settings: ARVisualizationSettings) -> String {
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
        if settings.showAircraftDistance {
            parts.append(String(format: "%.1f NM", distanceNM))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Selection Appearance

    /// Apply or remove the selected visual state on a container node.
    /// Selected aircraft rings get a bright white emission halo + larger scale.
    static func applySelectedAppearance(to container: SCNNode, selected: Bool) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15
        // Selected node is scaled up more prominently so it dominates the scene
        container.scale = selected ? SCNVector3(1.55, 1.55, 1.55) : SCNVector3(1.0, 1.0, 1.0)
        container.enumerateChildNodes { node, _ in
            guard node.name != "label" else { return }
            if node.geometry is SCNCone, let mat = node.geometry?.firstMaterial {
                mat.diffuse.contents  = selected
                    ? UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
                    : UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)
                mat.emission.contents = selected
                    ? UIColor(red: 0.0, green: 0.4,  blue: 0.6, alpha: 1.0)
                    : UIColor(red: 0.05, green: 0.25, blue: 0.6, alpha: 1.0)
            } else if node.name == "ring", let plane = node.geometry as? SCNPlane {
                // The ring plane uses a *shared* SCNMaterial per TCAS level.
                // NEVER mutate it directly — clone it for selection, restore shared on deselect.
                if selected {
                    if let existing = plane.materials.first {
                        let copy = existing.copy() as! SCNMaterial
                        copy.emission.contents = UIColor(red: 1.0, green: 0.95, blue: 0.6, alpha: 1.0)
                        plane.materials = [copy]
                    }
                } else {
                    // Restore the shared material using the stored TCAS level tag
                    let levelRaw = node.accessibilityLabel.flatMap { Int($0) } ?? 0
                    let level = TCASAlertLevel(rawValue: levelRaw) ?? .none
                    plane.materials = [ringMaterial(for: level)]
                }
            }
        }
        SCNTransaction.commit()
    }

    // MARK: - Airport Marker

    /// Solid blue inverted cone with a label.
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

        let coneNode = SCNNode(geometry: sharedConeGeometry)
        coneNode.eulerAngles.x = .pi
        coneNode.position = SCNVector3(0, Float(coneHeight / 2), 0)
        container.addChildNode(coneNode)

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
    /// Results are cached by a composite key (text + fontSize) so repeated calls with
    /// the same content skip the UIGraphicsImageRenderer entirely, cutting both CPU and
    /// GPU upload work. The cache is bounded to 50 entries.
    static func makeLabelImage(
        text: String,
        textColor: UIColor,
        bgColor: UIColor,
        fontSize: CGFloat,
        font: UIFont? = nil
    ) -> UIImage {
        // Cache key encodes both content and size so different font sizes don't collide.
        let cacheKey = "\(text)__\(fontSize)" as NSString
        if let cached = labelImageCache.object(forKey: cacheKey) { return cached }

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
        let image = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: imgW, height: imgH)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: corner)
            bgColor.setFill()
            path.fill()
            let textRect = CGRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height)
            attrStr.draw(in: textRect)
        }
        labelImageCache.setObject(image, forKey: cacheKey)
        return image
    }

    // MARK: - Update

    static func updateAircraftMarker(
        node: SCNNode,
        aircraft: Aircraft,
        distanceNM: Double = 0,
        settings: ARVisualizationSettings,
        selectedNodeID: String? = nil,
        tcasLevel: TCASAlertLevel = .none
    ) {
        // Refresh label
        let labelNode = node.childNode(withName: "label", recursively: false)

        let shouldShow = settings.showAircraftLabels
        if let lbl = labelNode {
            if selectedNodeID == nil {
                lbl.isHidden = !shouldShow
                lbl.opacity  = 1
            }

            if shouldShow, let plane = lbl.geometry as? SCNPlane {
                let newText = buildAircraftLabelText(aircraft: aircraft, distanceNM: distanceNM, settings: settings)
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

        // Update ring size, shared material, and pulse only when TCAS level changes.
        // Use the node's "accessibilityLabel" as a cheap String level-tag ("0"/"1"/"2")
        // to skip no-op updates and allow applySelectedAppearance to restore the right material.
        if let ringNode = node.childNode(withName: "ring", recursively: false) {
            let levelTag = String(tcasLevel.rawValue)   // "0" = none, "1" = TA, "2" = RA
            if ringNode.accessibilityLabel != levelTag {
                ringNode.accessibilityLabel = levelTag
                let newSize = ringPlaneSize(for: tcasLevel)
                if let plane = ringNode.geometry as? SCNPlane {
                    SCNTransaction.begin()
                    SCNTransaction.disableActions = true
                    plane.width  = newSize
                    plane.height = newSize
                    // Swap to the shared material for this level
                    plane.materials = [ringMaterial(for: tcasLevel)]
                    SCNTransaction.commit()
                }
                ringNode.removeAllActions()
                let (pulseMax, halfDur) = pulseParams(for: tcasLevel)
                let scaleUp   = SCNAction.scale(to: pulseMax, duration: halfDur)
                let scaleDown = SCNAction.scale(to: 1.0,      duration: halfDur)
                scaleUp.timingMode   = .easeInEaseOut
                scaleDown.timingMode = .easeInEaseOut
                ringNode.runAction(.repeatForever(.sequence([scaleUp, scaleDown])))
            }
        }
    }
}

// MARK: - Settings

struct ARVisualizationSettings {

    // MARK: Aircraft
    var showAircraft: Bool = true
    var aircraftMaxDistance: Double = 20.0

    var showCallsign:        Bool = true
    var showAircraftType:    Bool = true
    var showAircraftAltitude:Bool = true

    var callsignFilter: String = ""

    var showAircraftSpeed: Bool = true

    var showAircraftDistance: Bool = false

    /// When false (default), aircraft at or below 50 ft AGL are hidden (ground traffic).
    var showGroundAircraft: Bool = false

    var showAircraftLabels: Bool { showAircraftType || showAircraftAltitude || showCallsign || showAircraftSpeed || showAircraftDistance }

    private var _normalizedFilter: String = ""
    mutating func updateFilter() {
        _normalizedFilter = callsignFilter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

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

    var showAirportLabels: Bool { true }

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
    private let nodesLock = NSLock()
    var settings = ARVisualizationSettings()

    // MARK: Selection
    private(set) var selectedNodeID: String? = nil
    private var lastAppliedSelectionID: String? = "___unset___"
    var onSelectionInvalidated: (() -> Void)?

    private(set) var liveAircraft: [Aircraft] = []
    private(set) var liveUserLocation: CLLocationCoordinate2D = CLLocationCoordinate2D()
    private(set) var liveUserAltitude: Double = 0

    var arKitNorthCorrectionDeg: Double = 0

    /// When true, only aircraft whose IDs are in raFilterThreatIDs are shown.
    private var raFilterActive: Bool = false
    private var raFilterThreatIDs: Set<String> = []

    init(sceneView: ARSCNView) {
        self.sceneView = sceneView
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
            if raFilterActive && !raFilterThreatIDs.contains(ac.id) { continue }
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
        cameraWorldPosition: SCNVector3 = .init(),
        tcasEvaluation: TCASEvaluation = .clear,
        onGround: Bool = false
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
        /// Hard ceiling on concurrent aircraft nodes. Each aircraft = 3 SceneKit nodes
        /// (cone + ring plane + label plane), each with a GPU texture.
        /// On the ground with ADS-B connected we reduce this sharply — the user is
        /// surrounded by ground traffic that burns VRAM and is irrelevant to flight safety.
        let maxTotalNodes      = onGround ? 50 : 200
        /// Cap new node creation per tick to avoid a main-thread spike when a filter
        /// suddenly makes many aircraft visible at once (e.g. enabling ground traffic).
        let maxNewNodesPerTick = 20
        var newNodesThisTick   = 0

        for ac in aircraft {
            // Filter out ground aircraft unless the user has enabled them
            if !settings.showGroundAircraft && ac.altitude <= 50 { continue }

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

            let tcasLevel = tcasEvaluation.threats[ac.id] ?? .none

            if let existing = aircraftNodes[ac.id] {
                // In RA isolation mode only show threat aircraft
                existing.isHidden = raFilterActive && !raFilterThreatIDs.contains(ac.id)
                ARComponentFactory.updateAircraftMarker(
                    node: existing,
                    aircraft: ac,
                    distanceNM: distNM,
                    settings: settings,
                    selectedNodeID: selectedNodeID,
                    tcasLevel: tcasLevel
                )
            } else {
                // Enforce hard total-node cap and per-tick creation rate limit
                guard aircraftNodes.count < maxTotalNodes else { continue }
                guard newNodesThisTick < maxNewNodesPerTick else { continue }
                newNodesThisTick += 1

                let node = ARComponentFactory.createAircraftMarker(
                    rawPosition: rawPos,
                    aircraft: ac,
                    distanceNM: distNM,
                    cameraWorldPosition: cameraWorldPosition,
                    settings: settings,
                    tcasLevel: tcasLevel
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

    /// Hard cap on the number of airport nodes allowed in the scene simultaneously.
    /// Airports are sorted by distance first, so the nearest ones always win.
    /// This limits peak VRAM from airport cone + label textures without affecting
    /// which airports are *eligible* — all existing type and distance filters still apply.
    private static let maxAirportNodes = 30

    func updateAirports(
        _ airports: [Airport],
        userLocation: CLLocationCoordinate2D,
        userAltitude: Double,
        userHeading: Double,
        cameraWorldPosition: SCNVector3 = .init()
    ) {
        let nearby: [Airport]
        if settings.showAirports {
            // Apply type + distance filters, then keep only the nearest N.
            // Sorting by distance ensures the cap removes the furthest airports first.
            let filtered = CalculationsLogic.filterAirportsInRange(
                airports: airports,
                userCoord: userLocation,
                maxRangeNauticalMiles: settings.airportMaxDistance
            ).filter { settings.shouldShow(airportType: $0.type) }
             .sorted {
                 CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: $0.coordinate)
               < CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: $1.coordinate)
             }
            nearby = filtered.count <= ARSceneManager.maxAirportNodes
                ? filtered
                : Array(filtered.prefix(ARSceneManager.maxAirportNodes))
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

        let hasSelection = (sel != nil)

        // Aircraft: hide labels when another aircraft is selected (keep rings/geometry visible)
        for container in acSnap.values {
            let isSelected = (container.name == sel)
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

        // Airports: labels always visible regardless of selection; only highlight the selected one
        for container in apSnap.values {
            let isSelected = (container.name == sel)
            if let lbl = container.childNode(withName: "label", recursively: false) {
                if lbl.isHidden {
                    lbl.isHidden = false
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0.18
                    lbl.opacity = 1
                    SCNTransaction.commit()
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

    // MARK: - RA Filter (Resolution Advisory isolation)

    /// Activates or deactivates RA isolation mode.
    /// When active, only aircraft in `threatIDs` are visible; all others are hidden.
    func setRAFilterActive(_ active: Bool, threatIDs: Set<String>) {
        raFilterActive    = active
        raFilterThreatIDs = threatIDs

        nodesLock.lock()
        let snapshot = aircraftNodes
        nodesLock.unlock()

        for (id, node) in snapshot {
            if active {
                node.isHidden = !threatIDs.contains(id)
            } else {
                // Restore — the next updateAircraft tick will set visibility correctly,
                // but unhide immediately so there's no flash when returning to normal.
                node.isHidden = false
            }
        }
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

    // MARK: - Memory Pressure

    /// Called when iOS sends a memory warning (before a potential jetsam kill).
    /// Removes all hidden aircraft nodes and all airport nodes from the scene to
    /// free SceneKit texture memory immediately. The next update tick will rebuild
    /// only what's needed.
    func pruneForMemoryPressure() {
        nodesLock.lock()
        var hiddenIDs: [String] = []
        for (id, node) in aircraftNodes where node.isHidden {
            hiddenIDs.append(id)
        }
        var pruned: [SCNNode] = []
        for id in hiddenIDs {
            if let n = aircraftNodes.removeValue(forKey: id) { pruned.append(n) }
        }
        // Also evict all airport nodes — they re-appear on the next tick.
        let apNodes = Array(airportNodes.values)
        airportNodes.removeAll()
        nodesLock.unlock()

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        pruned.forEach { $0.removeFromParentNode() }
        apNodes.forEach { $0.removeFromParentNode() }
        SCNTransaction.commit()
    }
}
