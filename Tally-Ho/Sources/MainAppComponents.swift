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
    static let aircraftRingRadius: Float    = 3.6
    /// Ring radius for TA threats — slightly larger so they stand out.
    static let aircraftRingRadiusTA: Float  = 4.6
    /// Ring radius for RA threats — even larger, impossible to miss.
    static let aircraftRingRadiusRA: Float  = 5.5

    static let aircraftRingThickness: Float   = 0.42   // normal ring stroke half-width
    static let aircraftRingThicknessTA: Float = 0.66   // TA — noticeably thicker
    static let aircraftRingThicknessRA: Float = 0.90   // RA — boldest

    /// Airport cone dimensions (metres in AR space).
    static let coneHeight: CGFloat = 9.6
    static let coneBaseRadius: CGFloat = 2.4

    /// Label font size (1 scene-unit ≈ 1 m).
    static let labelFontSize: CGFloat        = 1.8
    static let labelFontSizeAirport: CGFloat = 1.9

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
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer  = false
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
    /// (altitude, speed, distance), so cache hits are very frequent after value quantization.
    /// Bounded to 200 entries and 40 MB total. Because callsigns are unique per aircraft,
    /// each aircraft produces its own cache key, so the byte budget is the primary guard
    /// against OOM kills in dense traffic. NSCache evicts automatically under memory pressure
    /// when cost is tracked.
    private static let labelImageCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 40_000_000   // 40 MB — at 1× scale (~200–400 KB per image) this
                                        // holds 100–200 labels; evicts before iOS kills us.
        return c
    }()

    /// Flush the label image cache. Called from pruneForMemoryPressure() so that
    /// both SceneKit nodes and their backing textures are released together.
    static func evictLabelCache() {
        labelImageCache.removeAllObjects()
    }

    // MARK: - Pre-cached ring images & materials per TCAS level
    // Images and SCNMaterials are created once and shared across all aircraft nodes.
    // Each level gets its own radius + thickness so TCAS rings are visually distinct.

    // Default (no selection): all rings are RED — the most visible colour on a sky background.
    // When a selection is active: selected ring stays RED, all other rings dim to YELLOW
    // so the selected target stands out clearly.

    private static let ringImageNormal: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadius),
        thickness:   CGFloat(aircraftRingThickness),
        color: UIColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1.0))  // red — default, no selection

    private static let ringImageTA: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadiusTA),
        thickness:   CGFloat(aircraftRingThicknessTA),
        color: UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1.0))    // amber for TA

    private static let ringImageRA: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadiusRA),
        thickness:   CGFloat(aircraftRingThicknessRA),
        color: UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0))    // deep red for RA

    /// Yellow ring used for UNSELECTED aircraft when a selection is active.
    /// Must be an image (not a flat UIColor) so the SCNPlane stays an annulus, not a rectangle.
    private static let ringImageSelected: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadius),
        thickness:   CGFloat(aircraftRingThickness),
        color: UIColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0))   // yellow — dimmed, not selected

    // Dashed variants — same colors/sizes per TCAS level, used when the aircraft's
    // last report is older than CalculationsLogic.staleAircraftAgeSeconds, so a
    // dead-reckoned/uncertain position reads visually differently from a live fix.
    private static let ringImageNormalStale: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadius),
        thickness:   CGFloat(aircraftRingThickness),
        color: UIColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1.0), dashed: true)

    private static let ringImageTAStale: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadiusTA),
        thickness:   CGFloat(aircraftRingThicknessTA),
        color: UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1.0), dashed: true)

    private static let ringImageRAStale: UIImage = makeRingImage(
        outerRadius: CGFloat(aircraftRingRadiusRA),
        thickness:   CGFloat(aircraftRingThicknessRA),
        color: UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0), dashed: true)

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
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer  = false
        return m
    }()
    private static let ringMaterialTA: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents  = ringImageTA
        m.emission.contents = ringImageTA
        m.isDoubleSided     = true
        m.transparencyMode  = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer  = false
        return m
    }()
    private static let ringMaterialRA: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents  = ringImageRA
        m.emission.contents = ringImageRA
        m.isDoubleSided     = true
        m.transparencyMode  = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer  = false
        return m
    }()
    private static let ringMaterialNormalStale: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents  = ringImageNormalStale
        m.emission.contents = ringImageNormalStale
        m.isDoubleSided     = true
        m.transparencyMode  = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer  = false
        return m
    }()
    private static let ringMaterialTAStale: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents  = ringImageTAStale
        m.emission.contents = ringImageTAStale
        m.isDoubleSided     = true
        m.transparencyMode  = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer  = false
        return m
    }()
    private static let ringMaterialRAStale: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents  = ringImageRAStale
        m.emission.contents = ringImageRAStale
        m.isDoubleSided     = true
        m.transparencyMode  = .aOne
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer  = false
        return m
    }()

    static func ringMaterial(for level: TCASAlertLevel, isStale: Bool = false) -> SCNMaterial {
        if isStale {
            switch level {
            case .none:               return ringMaterialNormalStale
            case .trafficAdvisory:    return ringMaterialTAStale
            case .resolutionAdvisory: return ringMaterialRAStale
            }
        }
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


    // MARK: - Distance Scaling

    /// Uniform scale factor for aircraft/airport marker container nodes.
    /// 1.0 at 0 NM, ~0.74 at 10 NM, ~0.36 at 50 NM, floored at 0.3.
    /// Stored in node userData["distanceScale"] so applySelectedAppearance can
    /// override it with exactly 1.0 when the node is selected.
    static func markerDistanceScale(_ distanceNM: Double) -> Float {
        Float(max(0.3, 1.0 / (1.0 + 0.035 * distanceNM)))
    }

    /// Draw order for marker container + child nodes based on real-world distance.
    /// Closer targets (higher value) render on top of farther ones (lower value).
    /// Range: 0 NM → 1000 (topmost), 50 NM → 0 (bottommost).
    static func markerRenderingOrder(_ distanceNM: Double) -> Int {
        max(0, 1000 - Int(distanceNM * 20))
    }

    // MARK: - Aircraft Marker

    /// Create a flat ring billboard with an optional label.
    static func createAircraftMarker(
        rawPosition: SCNVector3,
        aircraft: Aircraft,
        distanceNM: Double = 0,
        cameraWorldPosition: SCNVector3 = .init(),
        settings: ARVisualizationSettings,
        tcasLevel: TCASAlertLevel = .none,
        isStale: Bool = false
    ) -> SCNNode {

        let container = SCNNode()
        container.name = "aircraft_\(aircraft.id)"
        container.position = scaledPosition(rawPosition, relativeTo: cameraWorldPosition)

        // Ring plane — uses shared material per TCAS level so the GPU texture is
        // uploaded only once and reused across all aircraft nodes at that level.
        let ringSize = ringPlaneSize(for: tcasLevel)
        let plane = SCNPlane(width: ringSize, height: ringSize)
        plane.materials = [ringMaterial(for: tcasLevel, isStale: isStale)]

        let ringNode = SCNNode(geometry: plane)
        ringNode.name = "ring"
        ringNode.accessibilityLabel = String(tcasLevel.rawValue)   // level tag for material restore
        ringNode.setValue(isStale ? "\(tcasLevel.rawValue)s" : "\(tcasLevel.rawValue)", forKey: "ringMatTag")
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        ringNode.constraints = [billboard]


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

        // Seed distance scale so applySelectedAppearance can compose it on first selection pass.
        container.setValue(NSNumber(value: markerDistanceScale(distanceNM)), forKey: "distanceScale")
        // Seed staleness so applySelectedAppearance restores the correct (dashed vs solid)
        // ring material when a selection change requires reapplying it.
        container.setValue(NSNumber(value: isStale), forKey: "isStale")

        // Rings render above all labels; within each layer, closer beats farther.
        let ro = markerRenderingOrder(distanceNM)
        container.renderingOrder = ro
        ringNode.renderingOrder  = ro + 2000   // ring layer (2000–3000) — above labels
        labelNode.renderingOrder = ro           // label layer (0–1000)

        return container
    }

    /// Draw a ring (annulus) into a UIImage for use as a plane texture.
    private static func makeRingImage(
        outerRadius: CGFloat,
        thickness: CGFloat,
        color: UIColor,
        dashed: Bool = false
    ) -> UIImage {
        let dim = Int((outerRadius * 2 + 4).rounded()) * 16
        let size = CGSize(width: dim, height: dim)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let centre  = CGPoint(x: CGFloat(dim) / 2, y: CGFloat(dim) / 2)
            let scale   = CGFloat(dim) / (outerRadius * 2 + 4)
            let outerPx = outerRadius * scale
            let innerPx = (outerRadius - thickness) * scale
            if dashed {
                // Stroke the ring's midline with a dashed pattern instead of filling a
                // solid annulus, so a stale (dead-reckoned, not freshly reported)
                // aircraft is visually distinct from one with a live position fix.
                let midRadius   = (outerPx + innerPx) / 2
                let strokeWidth = outerPx - innerPx
                let path = UIBezierPath(
                    arcCenter: centre, radius: midRadius,
                    startAngle: 0, endAngle: .pi * 2, clockwise: true)
                path.lineWidth = strokeWidth
                let dashLen = strokeWidth * 1.8
                path.setLineDash([dashLen, dashLen], count: 2, phase: 0)
                color.setStroke()
                path.stroke()
            } else {
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
            // Quantize to nearest 100 ft so the label text (and its texture cache key) only
            // changes when altitude meaningfully changes, not on every raw ADS-B update.
            let altQ = Int((aircraft.altitude / 100).rounded()) * 100
            parts.append("\(altQ) ft")
        }
        if settings.showAircraftSpeed {
            // Quantize to nearest 10 kts.
            let spdQ = Int((aircraft.groundSpeed / 10).rounded()) * 10
            parts.append("\(spdQ) kts")
        }
        if settings.showAircraftDistance {
            // Quantize to nearest 0.5 NM so distance jitter doesn't thrash the cache.
            let distQ = (distanceNM * 2).rounded() / 2
            parts.append(String(format: "%.1f NM", distQ))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Selection Appearance

    /// Apply selection visual state to a container node.
    ///
    /// Ring colour rules:
    ///   - No selection active  → all rings RED (default, `ringMaterial` / `ringImageNormal`)
    ///   - Selection active, this node IS selected   → ring stays RED + scale up
    ///   - Selection active, this node is NOT selected → ring dims to YELLOW (`ringImageSelected`)
    ///
    /// - Parameters:
    ///   - selected:     True only when this specific container is the chosen target.
    ///   - hasSelection: True when any node is currently selected (even if not this one).
    static func applySelectedAppearance(to container: SCNNode, selected: Bool, hasSelection: Bool = false) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        let distScale = (container.value(forKey: "distanceScale") as? NSNumber)?.floatValue ?? 1.0
        let finalScale: Float = selected ? 1.0 : distScale
        container.scale = SCNVector3(finalScale, finalScale, finalScale)
        let isStale = (container.value(forKey: "isStale") as? NSNumber)?.boolValue ?? false
        container.enumerateChildNodes { node, _ in
            guard node.name != "label" else { return }
            if node.geometry is SCNCone, let mat = node.geometry?.firstMaterial {
                // Airport cone: highlight selected one cyan, keep others blue
                mat.diffuse.contents  = selected
                    ? UIColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
                    : UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 1.0)
                mat.emission.contents = selected
                    ? UIColor(red: 0.0, green: 0.4,  blue: 0.6, alpha: 1.0)
                    : UIColor(red: 0.05, green: 0.25, blue: 0.6, alpha: 1.0)
            } else if node.name == "ring", let plane = node.geometry as? SCNPlane {
                // The ring plane uses a *shared* SCNMaterial per TCAS level.
                // NEVER mutate the shared material directly — clone for any per-node override.
                let levelRaw = node.accessibilityLabel.flatMap { Int($0) } ?? 0
                let level    = TCASAlertLevel(rawValue: levelRaw) ?? .none

                if hasSelection && !selected {
                    // A different node is selected — dim this ring to yellow so the
                    // selected target stands out. Clone to avoid mutating the shared material.
                    if let existing = plane.materials.first {
                        let copy = existing.copy() as! SCNMaterial
                        copy.diffuse.contents  = ringImageSelected   // yellow
                        copy.emission.contents = ringImageSelected
                        plane.materials = [copy]
                    }
                } else {
                    // Either no selection is active (all rings red) or this IS the selected
                    // node (selected ring stays red). Restore the shared red material,
                    // preserving the dashed/stale appearance if applicable.
                    plane.materials = [ringMaterial(for: level, isStale: isStale)]
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
        coneNode.name = "cone"
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

        // Seed distance scale so applySelectedAppearance can compose it on first selection pass.
        container.setValue(NSNumber(value: markerDistanceScale(distanceNM)), forKey: "distanceScale")

        // Cones render above all labels; within each layer, closer beats farther.
        let ro = markerRenderingOrder(distanceNM)
        container.renderingOrder = ro
        coneNode.renderingOrder  = ro + 2000   // cone layer (2000–3000) — above labels
        labelNode.renderingOrder = ro           // label layer (0–1000)

        return container
    }

    static func buildAirportLabelText(airport: Airport, distanceNM: Double, settings: ARVisualizationSettings) -> String {
        var parts: [String] = [airport.icao]
        if settings.showAirportDistance {
            // Quantize to nearest 0.5 NM — airports move very slowly relative to user
            // so 0.5 NM steps are plenty of precision and greatly reduce texture thrashing.
            let distQ = (distanceNM * 2).rounded() / 2
            parts.append(String(format: "%.1f NM", distQ))
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
        mat.lightingModel      = .constant   // unlit: full brightness without emission copy
        mat.diffuse.contents   = image       // single GPU texture upload (no emission duplicate)
        mat.isDoubleSided      = true
        mat.transparencyMode   = .aOne
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer  = false
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

        // Render at 1× instead of UIScreen.main.scale (2× or 3× on modern iPhones).
        // Label textures are displayed on SCNPlanes in AR world space — the plane is
        // scaled to fit the scene in metres, not screen points — so @2x/@3x bitmaps
        // waste 4–9× the memory with no visible improvement at typical viewing distances
        // (labels are viewed at 0.1 – 25 NM, where even 1× looks perfectly sharp).
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: imgW, height: imgH), format: format)
        let image = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: imgW, height: imgH)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: corner)
            bgColor.setFill()
            path.fill()
            let textRect = CGRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height)
            attrStr.draw(in: textRect)
        }
        // Pass a byte-level cost so totalCostLimit can enforce the 40 MB budget.
        let cost = Int(imgW * imgH * 4)
        labelImageCache.setObject(image, forKey: cacheKey, cost: cost)
        return image
    }

    // MARK: - Update

    static func updateAircraftMarker(
        node: SCNNode,
        aircraft: Aircraft,
        distanceNM: Double = 0,
        settings: ARVisualizationSettings,
        selectedNodeID: String? = nil,
        tcasLevel: TCASAlertLevel = .none,
        isStale: Bool = false
    ) {
        // Keep staleness current on the container so applySelectedAppearance can
        // restore the correct (dashed vs solid) ring material on a selection change.
        node.setValue(NSNumber(value: isStale), forKey: "isStale")
        // Refresh label
        let labelNode = node.childNode(withName: "label", recursively: false)

        let shouldShow = settings.showAircraftLabels
        if let lbl = labelNode {
            // Only update text content when labels are shown — visibility is managed
            // by applySelectionToAllNodes() which correctly handles both selection state
            // and the showAircraftLabels flag in a single consistent pass.
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
                    plane.materials.first?.diffuse.contents  = image  // .constant lighting: no emission needed
                    lbl.position = SCNVector3(0, Float(CGFloat(aircraftRingRadius) + 0.9 + h / 2), 0)
                    SCNTransaction.commit()
                }
            }
        }

        // Update ring size/material only when TCAS level or staleness changes.
        // "accessibilityLabel" stays a pure numeric level tag ("0"/"1"/"2") since
        // applySelectedAppearance parses it as Int; staleness is tracked separately
        // via "ringMatTag" so either change alone triggers a material refresh.
        if let ringNode = node.childNode(withName: "ring", recursively: false) {
            let levelTag = String(tcasLevel.rawValue)   // "0" = none, "1" = TA, "2" = RA
            let combinedTag = levelTag + (isStale ? "s" : "")
            if (ringNode.value(forKey: "ringMatTag") as? String) != combinedTag {
                let levelChanged = ringNode.accessibilityLabel != levelTag
                ringNode.accessibilityLabel = levelTag
                ringNode.setValue(combinedTag, forKey: "ringMatTag")
                if let plane = ringNode.geometry as? SCNPlane {
                    SCNTransaction.begin()
                    SCNTransaction.disableActions = true
                    if levelChanged {
                        let newSize = ringPlaneSize(for: tcasLevel)
                        plane.width  = newSize
                        plane.height = newSize
                    }
                    // Swap to the shared material for this level/staleness combination
                    plane.materials = [ringMaterial(for: tcasLevel, isStale: isStale)]
                    SCNTransaction.commit()
                }
            }
        }

        // Update distance-based scale at 4 Hz so it stays current as the aircraft moves.
        // The selected node is always rendered at scale 1.0; all others use the distance factor.
        // NOTE: selectedNodeID stores the full node name ("aircraft_<id>"), not the bare aircraft id.
        let distScale = markerDistanceScale(distanceNM)
        node.setValue(NSNumber(value: distScale), forKey: "distanceScale")
        let isSelected = selectedNodeID == "aircraft_\(aircraft.id)"
        let s: Float = isSelected ? 1.0 : distScale
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        node.scale = SCNVector3(s, s, s)
        SCNTransaction.commit()

        // Update rendering order at 4 Hz so depth sorting stays correct as aircraft move.
        let ro = markerRenderingOrder(distanceNM)
        node.renderingOrder = ro
        node.enumerateChildNodes { child, _ in
            child.renderingOrder = child.name == "ring" ? ro + 2000 : ro
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

    /// Callsign of the user's own aircraft when flying on WiFi.
    /// When nil (default), all aircraft within 2 NM are hidden.
    /// When set, only the aircraft with this callsign is hidden and all others are visible.
    /// Never persisted — reset to nil at every app launch.
    var wifiOwnshipCallsign: String? = nil

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

    // MARK: HUD
    var showHUD: Bool = true
    var hudBrightness: HUDBrightness = .medium
}

/// HUD stroke/background brightness preset. Drives alpha only (not color),
/// so the HUD stays readable while letting AR content underneath show
/// through — see HUDOverlayView.setBrightness(_:) in ARTrafficViewController.swift.
enum HUDBrightness: Int, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2

    var displayName: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    var alpha: CGFloat {
        switch self {
        case .low:    return 0.5
        case .medium: return 0.7
        case .high:   return 0.9
        }
    }
}

// MARK: - Scene Manager

class ARSceneManager {

    private weak var sceneView: ARSCNView?
    private var aircraftNodes: [String: SCNNode] = [:]
    private var airportNodes:  [String: SCNNode] = [:]

    /// Snapshot of aircraftNodes consumed by tickAircraftPositions() on the SceneKit
    /// rendering thread at 60 Hz. Both reads (SceneKit thread) and writes (main thread)
    /// are protected by nodesLock to prevent a data race — Swift Dictionary's
    /// copy-on-write does NOT guarantee thread safety; concurrent read+write on the
    /// underlying buffer causes EXC_BAD_ACCESS with no crash report.
    private var tickNodeSnapshot: [String: SCNNode] = [:]

    /// Protects tickNodeSnapshot across the main thread (writer) and the SceneKit
    /// rendering thread (reader). Also guards aircraftNodes during stale-node removal.
    private let nodesLock = NSLock()
    var settings = ARVisualizationSettings()
    /// Magnetic declination = trueHeading − magneticHeading, smoothed and written
    /// by ARTrafficViewController on each CLHeading callback.  Used to convert the
    /// true GPS bearing into a magnetic bearing that matches ARKit's magnetic-north
    /// world coordinate system.
    var arKitNorthCorrectionDeg: Double = 0

    // MARK: Selection
    private(set) var selectedNodeID: String? = nil
    private var lastAppliedSelectionID: String? = "___unset___"
    var onSelectionInvalidated: (() -> Void)?

    private(set) var liveAircraft: [Aircraft] = []
    private(set) var liveUserLocation: CLLocationCoordinate2D = CLLocationCoordinate2D()
    private(set) var liveUserAltitude: Double = 0

    /// Ownship position, velocity and altitude for the 60 Hz ticks.
    ///
    /// Dead reckoning used to run on state this class kept itself, which mixed the phone's
    /// timestamp and course with an ADS-B position written by a different code path. The
    /// estimator owns that state now, keeps each source's own timing, and is internally
    /// locked, so the render thread can sample it directly.
    weak var ownshipEstimator: OwnshipEstimator?

    /// Number of aircraft nodes positioned on the most recent 4 Hz pass, for the flight log.
    private(set) var renderedAircraftCount: Int = 0

    /// Airport node snapshot for the 60 Hz airport tick — analogous to tickNodeSnapshot.
    /// Protected by nodesLock: written on the main thread at 4 Hz (end of updateAirports),
    /// read on the SceneKit thread at 60 Hz (tickAirportPositions).
    private var tickAirportSnapshot: [(airport: Airport, node: SCNNode)] = []

    /// When true, only aircraft whose IDs are in raFilterThreatIDs are shown.
    private var raFilterActive: Bool = false
    private var raFilterThreatIDs: Set<String> = []

    // Airport stable-set cache — recomputed only when the user moves >0.1 NM,
    // not on every 4 Hz tick. GPS jitter within a stationary position previously
    // caused slightly different airports to win the distance-sort cap each tick,
    // producing the "blinking" effect.
    private var cachedNearbyAirports: [Airport] = []
    var lastAirportComputeLocation: CLLocationCoordinate2D? = nil   // internal(set) exposed for cache invalidation
    private let airportRecomputeThresholdNM: Double = 0.1

    init(sceneView: ARSCNView) {
        self.sceneView = sceneView
        sceneView.autoenablesDefaultLighting  = false
        sceneView.automaticallyUpdatesLighting = false
    }

    // MARK: - 60 Hz Position Update

    func tickAircraftPositions(cameraWorldPosition: SCNVector3) {
        guard settings.showAircraft else { return }

        let aircraft = liveAircraft
        var userLoc = liveUserLocation
        var userAlt = liveUserAltitude
        if let ownship = ownshipEstimator?.snapshot(), ownship.hasPosition {
            userLoc = ownship.coordinate
            userAlt = ownship.displayAltitudeFt
        }

        // Take the snapshot under the lock — the main thread writes tickNodeSnapshot
        // at 4 Hz and this runs at 60 Hz on the SceneKit thread; without the lock
        // a concurrent read+write causes EXC_BAD_ACCESS (Swift Dictionary is not
        // thread-safe; copy-on-write does not protect against concurrent mutation).
        nodesLock.lock()
        let nodeSnapshot = tickNodeSnapshot
        nodesLock.unlock()

        for ac in aircraft {
            guard let node = nodeSnapshot[ac.id], !node.isHidden else { continue }
            if raFilterActive && !raFilterThreatIDs.contains(ac.id) { continue }
            let (predCoord, predAlt) = CalculationsLogic.predictedPosition(for: ac, aheadSeconds: 0)
            let targetAlt = CalculationsLogic.placementAltitude(
                for: ac, targetAltitude: predAlt, userAltitudeFt: userAlt)
            let rawPos = CalculationsLogic.calculateARPosition(
                targetCoord: predCoord,
                targetAltitude: targetAlt,
                userCoord: userLoc,
                userAltitude: userAlt,
                userHeading: 0,
                cameraWorldPosition: cameraWorldPosition,
                northCorrectionDeg: arKitNorthCorrectionDeg
            )
            let scaled = ARComponentFactory.scaledPosition(rawPos, relativeTo: cameraWorldPosition)
            node.simdPosition = simd_float3(scaled.x, scaled.y, scaled.z)
        }
    }

    // MARK: - 60 Hz Airport Position Update

    /// Repositions all airport nodes every SceneKit frame (60 Hz), eliminating the
    /// 4 Hz drift/snap cycle that was visible when panning the phone on a fast-moving
    /// aircraft. Mirrors tickAircraftPositions — see that method for thread-safety rationale.
    func tickAirportPositions(cameraWorldPosition: SCNVector3) {
        guard settings.showAirports else { return }

        nodesLock.lock()
        let snapshot = tickAirportSnapshot
        nodesLock.unlock()

        var userLoc = liveUserLocation
        var userAlt = liveUserAltitude
        if let ownship = ownshipEstimator?.snapshot(), ownship.hasPosition {
            userLoc = ownship.coordinate
            userAlt = ownship.displayAltitudeFt
        }

        for entry in snapshot {
            let rawPos = CalculationsLogic.calculateAirportARPosition(
                airportCoord:        entry.airport.coordinate,
                airportElevation:    entry.airport.elevation,
                userCoord:           userLoc,
                userAltitude:        userAlt,
                userHeading:         0,
                cameraWorldPosition: cameraWorldPosition,
                northCorrectionDeg:  arKitNorthCorrectionDeg
            )
            let scaled = ARComponentFactory.scaledAirportPosition(rawPos, relativeTo: cameraWorldPosition)
            entry.node.simdPosition = simd_float3(scaled.x, scaled.y, scaled.z)
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
        ///
        /// The tight ceiling exists for one situation: parked on an airfield with ground
        /// traffic switched on, where the user is surrounded by aircraft that burn VRAM and
        /// carry no flight-safety value. It is scoped to exactly that, because applying it
        /// whenever the user is on the ground also throttled the airborne traffic overhead,
        /// which is the entire traffic picture from the ground.
        let maxTotalNodes      = (onGround && settings.showGroundAircraft) ? 50 : 200
        /// Cap new node creation per tick to avoid a main-thread spike when a filter
        /// suddenly makes many aircraft visible at once (e.g. enabling ground traffic).
        let maxNewNodesPerTick = 20
        var newNodesThisTick   = 0

        // Nearest first. Both the node ceiling and the per-tick creation limit stop partway
        // through this loop, so whatever order it runs in decides which aircraft get drawn.
        // Dictionary order is arbitrary, which in dense airspace meant the closest traffic
        // could be dropped in favour of traffic twenty miles away.
        let aircraftNearestFirst = aircraft
            .map { (aircraft: $0,
                    distNM: CalculationsLogic.distanceInNauticalMiles(
                        from: userLocation,
                        to: CalculationsLogic.predictedPosition(for: $0, aheadSeconds: 0).coordinate)) }
            .sorted { $0.distNM < $1.distNM }
            .map { $0.aircraft }

        for ac in aircraftNearestFirst {
            // Filter out ground aircraft unless the user has enabled them. Uses the source's
            // own on-ground flag where available; the altitude threshold alone misclassified
            // traffic at high-elevation airports.
            if !settings.showGroundAircraft && ac.isGroundTraffic { continue }

            // Cull/order/label using the same dead-reckoned position the marker is
            // actually drawn at — mixing the raw last-reported coordinate here with
            // the predicted coordinate below caused pop-in/pop-out and wrong depth
            // stacking whenever a report was stale and the aircraft fast-moving.
            let (predCoord, predAlt) = CalculationsLogic.predictedPosition(for: ac, aheadSeconds: 0)
            let distNM = CalculationsLogic.distanceInNauticalMiles(from: userLocation, to: predCoord)
            guard distNM <= settings.aircraftMaxDistance else { continue }
            guard settings.passes(callsign: ac.callsign) else { continue }
            // While airborne, traffic more than 10,000ft above/below the user's own
            // altitude isn't relevant for visual traffic awareness — e.g. no reason to
            // show 5,000ft traffic while cruising at 40,000ft.
            //
            // Only applied to targets that actually reported an altitude. A target whose
            // altitude is unknown carries a placeholder zero, which at cruise would read as
            // 35,000 ft of separation and cull it — hiding traffic precisely because the
            // source said nothing about its altitude, rather than because it is far away.
            if !onGround, ac.hasValidAltitude, abs(predAlt - userAltitude) > 10_000 { continue }
            let isStale = CalculationsLogic.isStale(ac)

            currentIDs.insert(ac.id)
            visibleAircraft.append(ac)

            let targetAlt = CalculationsLogic.placementAltitude(
                for: ac, targetAltitude: predAlt, userAltitudeFt: userAltitude)
            let rawPos = CalculationsLogic.calculateARPosition(
                targetCoord: predCoord,
                targetAltitude: targetAlt,
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
                    tcasLevel: tcasLevel,
                    isStale: isStale
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
                    tcasLevel: tcasLevel,
                    isStale: isStale
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

        liveAircraft          = visibleAircraft
        liveUserLocation      = userLocation
        liveUserAltitude      = userAltitude
        renderedAircraftCount = visibleAircraft.count

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

        // Refresh the lock-free snapshot consumed by tickAircraftPositions().
        // This always runs on the main thread, so the write is safe.
        nodesLock.lock()
        tickNodeSnapshot = aircraftNodes
        nodesLock.unlock()
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
            // Recompute the visible airport set only when the user has moved more than
            // 0.1 NM from the last compute location. GPS jitter at a stationary position
            // used to cause slightly different airports to win the distance-sort cap on
            // every tick, making airport nodes blink as stale ones were removed and new
            // ones were added. The cache keeps the set stable between meaningful moves.
            let needsRecompute: Bool
            if let last = lastAirportComputeLocation {
                needsRecompute = CalculationsLogic.distanceInNauticalMiles(
                    from: last, to: userLocation) > airportRecomputeThresholdNM
            } else {
                needsRecompute = true
            }

            if needsRecompute {
                let filtered = CalculationsLogic.filterAirportsInRange(
                    airports: airports,
                    userCoord: userLocation,
                    maxRangeNauticalMiles: settings.airportMaxDistance
                ).filter { settings.shouldShow(airportType: $0.type) }

                let withDist = filtered.map { airport -> (airport: Airport, dist: Double) in
                    (airport, CalculationsLogic.distanceInNauticalMiles(from: userLocation,
                                                                         to: airport.coordinate))
                }.sorted { $0.dist < $1.dist }

                let capped = withDist.count <= ARSceneManager.maxAirportNodes
                    ? withDist : Array(withDist.prefix(ARSceneManager.maxAirportNodes))
                cachedNearbyAirports = capped.map { $0.airport }
                lastAirportComputeLocation = userLocation
            }
            nearby = cachedNearbyAirports
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
                        plane.materials.first?.diffuse.contents  = image  // .constant lighting: no emission needed
                        SCNTransaction.commit()
                    }
                    if selectedNodeID == nil {
                        lbl.isHidden = !settings.showAirportLabels
                        lbl.opacity  = 1
                    }
                }
                // Update distance-based scale at 4 Hz so it shrinks as the user moves away.
                // NOTE: selectedNodeID stores the full node name ("airport_<icao>"), not the bare ICAO.
                let distScale = ARComponentFactory.markerDistanceScale(distNM)
                existing.setValue(NSNumber(value: distScale), forKey: "distanceScale")
                let isSelected = selectedNodeID == "airport_\(airport.icao)"
                let selMult: Float = isSelected ? 1.55 : 1.0
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                existing.scale = SCNVector3(distScale * selMult, distScale * selMult, distScale * selMult)
                SCNTransaction.commit()

                // Update rendering order so closer airports always render on top.
                let ro = ARComponentFactory.markerRenderingOrder(distNM)
                existing.renderingOrder = ro
                existing.enumerateChildNodes { child, _ in
                    child.renderingOrder = child.name == "cone" ? ro + 2000 : ro
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

        // Remove airport nodes that are no longer visible (out of range, filtered out,
        // or bumped by the node cap). Previously these were only hidden, which meant
        // airportNodes could grow beyond the cap and cause the visible set to oscillate
        // each tick as slightly different airports won the cap — the "blinking" effect.
        // Removing them outright keeps airportNodes ≤ maxAirportNodes and stable.
        let staleAirportIDs = Set(airportNodes.keys).subtracting(visibleIDs)
        var staleAirportNodes: [SCNNode] = []
        for icao in staleAirportIDs {
            if let n = airportNodes.removeValue(forKey: icao) {
                staleAirportNodes.append(n)
            }
        }
        if !staleAirportNodes.isEmpty {
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            staleAirportNodes.forEach { $0.removeFromParentNode() }
            SCNTransaction.commit()
        }

        if airportNodesAdded || !staleAirportNodes.isEmpty {
            lastAppliedSelectionID = "___unset___"
        }
        applySelectionToAllNodes()

        // Refresh the lock-protected snapshot consumed by tickAirportPositions() at 60 Hz.
        // Runs on the main thread here (4 Hz timer), so the write is safe as long as
        // we hold nodesLock to protect the concurrent SceneKit thread reader.
        nodesLock.lock()
        tickAirportSnapshot = nearby.compactMap { airport in
            guard let node = airportNodes[airport.icao] else { return nil }
            return (airport: airport, node: node)
        }
        nodesLock.unlock()
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

        // Aircraft: hide labels when another aircraft is selected (keep rings/geometry visible).
        // When no selection is active, respect settings.showAircraftLabels so label-only
        // toggles (altitude, speed, etc.) actually take effect.
        let labelsEnabled = settings.showAircraftLabels
        for container in acSnap.values {
            let isSelected = (container.name == sel)
            if let lbl = container.childNode(withName: "label", recursively: false) {
                // Hide when: (a) another node is selected, or (b) all label settings are off
                let shouldHide = (hasSelection && !isSelected) || !labelsEnabled
                if lbl.isHidden != shouldHide {
                    lbl.opacity   = shouldHide ? 0 : 1
                    lbl.isHidden  = shouldHide
                }
            }
            ARComponentFactory.applySelectedAppearance(to: container, selected: isSelected, hasSelection: hasSelection)
        }

        // Airports: labels always visible regardless of selection; only highlight the selected one.
        // hasSelection is NOT passed here — airport cones never change colour when an aircraft
        // is selected (and vice versa). Airport cone appearance only changes when an airport itself
        // is the selected target.
        let airportSelected = sel?.hasPrefix("airport_") ?? false
        for container in apSnap.values {
            let isSelected = (container.name == sel)
            if let lbl = container.childNode(withName: "label", recursively: false) {
                lbl.opacity  = 1
                lbl.isHidden = false
            }
            // Pass hasSelection only within the airport set so non-selected airports
            // aren't affected when an aircraft (not an airport) is selected.
            ARComponentFactory.applySelectedAppearance(to: container, selected: isSelected, hasSelection: airportSelected)
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

    /// Remove only airport nodes. Used when airport-specific settings change
    /// so aircraft nodes are not unnecessarily destroyed and recreated.
    func clearAirports() {
        let apNodes = Array(airportNodes.values)
        airportNodes.removeAll()
        cachedNearbyAirports = []
        lastAirportComputeLocation = nil
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        apNodes.forEach { $0.removeFromParentNode() }
        SCNTransaction.commit()
    }

    /// Remove only aircraft nodes. Used when aircraft-specific settings change
    /// so airport nodes are not unnecessarily destroyed and recreated.
    func clearAircraft() {
        nodesLock.lock()
        let acNodes = Array(aircraftNodes.values)
        aircraftNodes.removeAll()
        tickNodeSnapshot.removeAll()
        nodesLock.unlock()
        liveAircraft = []
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        acNodes.forEach { $0.removeFromParentNode() }
        SCNTransaction.commit()
    }

    func clearAll() {
        nodesLock.lock()
        let acNodes = Array(aircraftNodes.values)
        let apNodes = Array(airportNodes.values)
        aircraftNodes.removeAll()
        airportNodes.removeAll()
        tickNodeSnapshot.removeAll()
        nodesLock.unlock()

        liveAircraft = []
        // Invalidate the airport stable-set cache so the next tick recomputes
        // using the new settings rather than the stale pre-change set.
        cachedNearbyAirports = []
        lastAirportComputeLocation = nil

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

        // Flush the label texture cache — each image is a few hundred KB at 1× scale,
        // and holding 200 of them can reach 40+ MB. Evicting here frees that memory
        // immediately alongside the SceneKit node removal above. Labels will be
        // regenerated (and re-cached) as nodes are rebuilt on the next tick.
        ARComponentFactory.evictLabelCache()

        // Refresh the tick snapshot so the rendering thread doesn't try to
        // position nodes that have just been removed from the scene.
        nodesLock.lock()
        tickNodeSnapshot = aircraftNodes
        nodesLock.unlock()
    }
}
