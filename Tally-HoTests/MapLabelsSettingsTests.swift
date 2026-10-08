//
//  MapLabelsSettingsTests.swift
//  Tally-HoTests
//
//  Gev's ground test of build 395 (#18): the aircraft label obeys every label toggle (Show Callsign
//  included), the 2D map draws AR's label, and Settings leaves out air-only rows on the ground.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

/// The five label toggles, as one value, so every combination can be enumerated.
private struct LabelToggles: CustomStringConvertible {
    var callsign: Bool
    var type: Bool
    var altitude: Bool
    var speed: Bool
    var distance: Bool

    /// All 32 combinations.
    static var all: [LabelToggles] {
        (0..<32).map { bits in
            LabelToggles(callsign: bits & 1 != 0, type: bits & 2 != 0, altitude: bits & 4 != 0,
                         speed: bits & 8 != 0, distance: bits & 16 != 0)
        }
    }

    func applied(to base: ARVisualizationSettings = ARVisualizationSettings()) -> ARVisualizationSettings {
        var s = base
        s.showCallsign = callsign
        s.showAircraftType = type
        s.showAircraftAltitude = altitude
        s.showAircraftSpeed = speed
        s.showAircraftDistance = distance
        return s
    }

    var description: String {
        "cs=\(callsign) type=\(type) alt=\(altitude) spd=\(speed) dist=\(distance)"
    }
}

private enum Fixture {
    static let here = CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0)

    static func aircraft(callsign: String = "UAL123", type: String = "B738",
                         northNM: Double = 7.3) -> Aircraft {
        var ac = Aircraft(
            id: "a1b2c3",
            callsign: callsign,
            latitude: here.latitude + northNM / 60.0,
            longitude: here.longitude,
            altitude: 34_980,
            track: 90,
            groundSpeed: 452,
            verticalRate: 0,
            lastUpdate: Date(),
            source: .internet
        )
        ac.aircraftType = type
        return ac
    }
}

struct AircraftLabelTests {

    /// What the label must say, written out independently of the builder: callsign and type on one
    /// line (each when on and known), then altitude, speed and distance, each when on.
    private func expected(_ t: LabelToggles, callsign: String, type: String,
                          altitude: String, speed: String, distance: String) -> String {
        var lines: [String] = []
        var identity: [String] = []
        if t.callsign && !callsign.isEmpty { identity.append(callsign) }
        if t.type && !type.isEmpty { identity.append(type) }
        if !identity.isEmpty { lines.append(identity.joined(separator: " / ")) }
        if t.altitude { lines.append(altitude) }
        if t.speed { lines.append(speed) }
        if t.distance { lines.append(distance) }
        return lines.joined(separator: "\n")
    }

    /// Every toggle combination, all 32, all-off included.
    @Test func labelTextForEveryToggleCombination() {
        let ac = Fixture.aircraft()
        for t in LabelToggles.all {
            let text = ARComponentFactory.buildAircraftLabelText(aircraft: ac, distanceNM: 7.3,
                                                                 settings: t.applied())
            let want = expected(t, callsign: "UAL123", type: "B738",
                                altitude: "35000 ft", speed: "450 kts", distance: "7.5 NM")
            #expect(text == want)
        }
    }

    /// The bug from the ground test: Show Callsign off left the callsign on every label.
    @Test func showCallsignOffRemovesTheCallsign() {
        let ac = Fixture.aircraft()
        var s = ARVisualizationSettings()
        s.showCallsign = false
        let text = ARComponentFactory.buildAircraftLabelText(aircraft: ac, distanceNM: 7.3, settings: s)
        #expect(!text.contains("UAL123"))
        #expect(text.hasPrefix("B738"))
    }

    /// Every toggle off: no text, and the AR label is hidden (`showAircraftLabels`).
    @Test func allTogglesOffMeansNoLabel() {
        let s = LabelToggles(callsign: false, type: false, altitude: false, speed: false,
                             distance: false).applied()
        #expect(s.showAircraftLabels == false)
        #expect(ARComponentFactory.buildAircraftLabelText(aircraft: Fixture.aircraft(), distanceNM: 7.3,
                                                          settings: s).isEmpty)
    }

    /// A target that sent no callsign gets no empty first line: it used to read " / B738", or a
    /// blank line above the altitude.
    @Test func missingCallsignLeavesNoEmptyLine() {
        let noCallsign = Fixture.aircraft(callsign: "")
        let all = LabelToggles(callsign: true, type: true, altitude: true, speed: false, distance: false)
        #expect(ARComponentFactory.buildAircraftLabelText(aircraft: noCallsign, distanceNM: 7.3,
                                                          settings: all.applied()) == "B738\n35000 ft")
        let noType = Fixture.aircraft(callsign: "", type: "")
        let text = ARComponentFactory.buildAircraftLabelText(aircraft: noType, distanceNM: 7.3,
                                                             settings: all.applied())
        #expect(text == "35000 ft")
    }
}

@MainActor
struct MapLabelParityTests {

    /// The map draws AR's label for the same settings, at the distance the filter judged — the
    /// distance AR labels the marker with — for every toggle combination.
    @Test func mapLabelIsTheARLabelForEveryToggleCombination() {
        let observer = TrafficFilter.Observer(coordinate: Fixture.here, altitudeFt: 36_000)
        let ac = Fixture.aircraft()
        for t in LabelToggles.all {
            let s = t.applied()
            let verdict = TrafficFilter(settings: s, airborne: true).verdict(for: ac, from: observer)
            #expect(verdict.isShown)
            let map = MapViewController.labelText(for: verdict, settings: s)
            let ar = ARComponentFactory.buildAircraftLabelText(aircraft: ac, distanceNM: verdict.distanceNM,
                                                               settings: s)
            #expect(map == ar)
        }
    }

    /// With distance on, the map's distance is the judged one, not something of its own.
    @Test func mapLabelDistanceIsTheJudgedDistance() {
        let observer = TrafficFilter.Observer(coordinate: Fixture.here, altitudeFt: 36_000)
        let s = LabelToggles(callsign: false, type: false, altitude: false, speed: false,
                             distance: true).applied()
        let verdict = TrafficFilter(settings: s, airborne: true)
            .verdict(for: Fixture.aircraft(northNM: 7.3), from: observer)
        #expect(MapViewController.labelText(for: verdict, settings: s) == "7.5 NM")
    }
}

@MainActor
struct SettingsRowsTests {

    private static let bandRow = "Only traffic within ±10,000 ft"
    private static let myAirplane = "🛩️  My Airplane"

    private func settingsVC(airborne: Bool, wifi: Bool, adsbCallsign: String? = nil,
                            settings: ARVisualizationSettings = ARVisualizationSettings()) -> SettingsViewController {
        SettingsViewController(settings: settings, airborne: airborne,
                               allowsOwnshipSelection: wifi,
                               nearbyCallsigns: ["UAL123"],
                               adsbOwnshipCallsign: adsbCallsign,
                               onDismiss: { _ in })
    }

    private func allRowTitles(_ vc: SettingsViewController) -> [String] {
        vc.rowTitles.flatMap { $0 }
    }

    @Test func onTheGroundTheBandRowAndMyAirplaneAreLeftOut() {
        for (wifi, adsb) in [(true, nil), (false, "N123AB")] as [(Bool, String?)] {
            let vc = settingsVC(airborne: false, wifi: wifi, adsbCallsign: adsb)
            #expect(!allRowTitles(vc).contains(Self.bandRow))
            #expect(!vc.sectionHeaders.contains(Self.myAirplane))
            #expect(!allRowTitles(vc).contains("I'm Flying"))
        }
    }

    @Test func inTheAirTheBandRowAndThePickerAreOffered() {
        let vc = settingsVC(airborne: true, wifi: true)
        #expect(allRowTitles(vc).contains(Self.bandRow))
        #expect(vc.sectionHeaders.contains(Self.myAirplane))
        #expect(allRowTitles(vc).contains("I'm Flying"))
    }

    /// With a receiver, the air shows its read-only answer under the same section.
    @Test func inTheAirWithADSBTheReadOnlyRowIsOffered() {
        let vc = settingsVC(airborne: true, wifi: false, adsbCallsign: "N123AB")
        #expect(allRowTitles(vc).contains(Self.bandRow))
        #expect(vc.sectionHeaders.contains(Self.myAirplane))
        #expect(allRowTitles(vc).contains("I'm Flying"))
    }

    /// The band row sits with the aircraft filters, after the ground row, when it is shown.
    @Test func bandRowFollowsTheGroundRowInTheAir() throws {
        let vc = settingsVC(airborne: true, wifi: true)
        let aircraftIndex = try #require(vc.sectionHeaders.firstIndex(of: "✈️  Aircraft"))
        let rows = vc.rowTitles[aircraftIndex]
        let ground = try #require(rows.firstIndex(of: "Show Aircraft on Ground"))
        #expect(rows[ground + 1] == Self.bandRow)
    }

    /// Hiding a row never changes what it stores: a band switched off and a pick made in the air
    /// come back from a ground Settings exactly as they went in.
    @Test func hiddenRowsKeepTheirStoredValues() {
        var s = ARVisualizationSettings()
        s.limitTrafficToAltitudeBand = false
        s.wifiOwnshipCallsign = "UAL123"
        let vc = settingsVC(airborne: false, wifi: true, settings: s)
        #expect(vc.settings.limitTrafficToAltitudeBand == false)
        #expect(vc.settings.wifiOwnshipCallsign == "UAL123")
    }

    /// Everything else is the same on the ground and in the air.
    @Test func groundAndAirDifferOnlyInTheAirOnlyRows() {
        let ground = allRowTitles(settingsVC(airborne: false, wifi: true))
        let air = allRowTitles(settingsVC(airborne: true, wifi: true))
        let airOnly = air.filter { $0 == Self.bandRow || $0 == "I'm Flying" }
        let airMinusAirOnly = air.filter { $0 != Self.bandRow && $0 != "I'm Flying" }
        #expect(airOnly.count == 2)
        #expect(airMinusAirOnly == ground)
    }
}
