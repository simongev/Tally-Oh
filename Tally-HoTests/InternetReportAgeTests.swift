//
//  InternetReportAgeTests.swift
//  Tally-HoTests
//
//  adsb.lol says how old each position already is ("seen_pos"). ADSBLolClient turned that into
//  the report's own time, and ConnectionLogic then overwrote it with the fetch time on merge, so
//  every internet target was dead-reckoned from too late a moment and drawn behind where it was.
//  These lock in that the age survives the merge, that it is clamped to [0, 60] s, and that an
//  older report — now possible, since times are the reports' own — never replaces a newer one.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

struct InternetReportAgeTests {

    // MARK: - Helpers

    private let fetched = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// One adsb.lol "ac" entry; `seenPos` is the raw JSON value, nil to omit the field.
    private func entry(hex: String = "a1b2c3", seenPos: String? = "4.5",
                       lat: Double = 40.0, lon: Double = -100.0,
                       groundSpeed: Double = 480, track: Double = 90) -> String {
        var fields = [
            "\"hex\":\"\(hex)\"", "\"lat\":\(lat)", "\"lon\":\(lon)",
            "\"alt_baro\":35000", "\"alt_geom\":35600", "\"flight\":\"UAL123  \"",
            "\"track\":\(track)", "\"gs\":\(groundSpeed)",
        ]
        if let seenPos { fields.append("\"seen_pos\":\(seenPos)") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func response(_ entries: [String]) -> Data {
        Data(("{\"ac\":[" + entries.joined(separator: ",") + "]}").utf8)
    }

    private func parse(_ entries: [String], at now: Date) throws -> [Aircraft] {
        try ADSBLolClient.parseResponse(response(entries), now: now)
    }

    private func keyed(_ list: [Aircraft]) -> [String: Aircraft] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func aircraft(_ id: String, latitude: Double = 40.0, lastUpdate: Date) -> Aircraft {
        Aircraft(id: id, callsign: id, latitude: latitude, longitude: -100.0, altitude: 35_000,
                 track: 90, groundSpeed: 480, verticalRate: 0, lastUpdate: lastUpdate,
                 source: .internet)
    }

    // MARK: - The report time

    @Test func reportTimeIsReceiptMinusSeenPos() throws {
        let parsed = try parse([entry(seenPos: "4.5")], at: fetched)
        let ac = try #require(parsed.first)
        #expect(abs(ac.lastUpdate.timeIntervalSince(fetched) - (-4.5)) < 1e-6)
    }

    @Test func reportAgeSurvivesTheMerge() throws {
        let parsed = keyed(try parse([entry(hex: "a1b2c3", seenPos: "4.5"),
                                      entry(hex: "d4e5f6", seenPos: "1.2")], at: fetched))

        let merged = ConnectionLogic.merge(parsed, into: [:])
        let first = try #require(merged["A1B2C3"])
        let second = try #require(merged["D4E5F6"])
        // The report's own time, not the time it was merged.
        #expect(abs(first.lastUpdate.timeIntervalSince(fetched) - (-4.5)) < 1e-6)
        #expect(abs(second.lastUpdate.timeIntervalSince(fetched) - (-1.2)) < 1e-6)
    }

    @Test func aNewerReportReplacesTheStoredOneWithItsAgeIntact() throws {
        let store = ["A1B2C3": aircraft("A1B2C3", lastUpdate: fetched.addingTimeInterval(-20))]
        let parsed = keyed(try parse([entry(seenPos: "4.5")], at: fetched))
        let merged = ConnectionLogic.merge(parsed, into: store)
        let stored = try #require(merged["A1B2C3"])
        #expect(abs(stored.lastUpdate.timeIntervalSince(fetched) - (-4.5)) < 1e-6)
    }

    // MARK: - The clamp

    @Test func seenPosIsClampedToZeroAndSixtySeconds() {
        #expect(ADSBLolClient.reportAge(seenPos: nil) == 0)
        #expect(ADSBLolClient.reportAge(seenPos: -5) == 0)
        #expect(ADSBLolClient.reportAge(seenPos: 0.3) == 0.3)
        #expect(ADSBLolClient.reportAge(seenPos: 30) == 30)
        #expect(ADSBLolClient.reportAge(seenPos: 60) == 60)
        #expect(ADSBLolClient.reportAge(seenPos: 600) == 60)
        #expect(ADSBLolClient.reportAge(seenPos: .nan) == 0)
        #expect(ADSBLolClient.maxReportAgeSeconds == 60)
    }

    @Test func aNegativeSeenPosNeverDatesAReportInTheFuture() throws {
        let ac = try #require(try parse([entry(seenPos: "-5")], at: fetched).first)
        // At the receipt time, not five seconds after it: a future time would never go stale and
        // never be pruned.
        #expect(ac.lastUpdate == fetched)
    }

    @Test func anAbsurdSeenPosIsCappedAtSixtySeconds() throws {
        let ac = try #require(try parse([entry(seenPos: "86400")], at: fetched).first)
        #expect(abs(ac.lastUpdate.timeIntervalSince(fetched) - (-60)) < 1e-6)
    }

    @Test func aMissingSeenPosMeansAFreshReport() throws {
        let ac = try #require(try parse([entry(seenPos: nil)], at: fetched).first)
        #expect(ac.lastUpdate == fetched)
    }

    // MARK: - Newer always wins

    @Test func anOlderReportNeverReplacesANewerOne() {
        let newer = aircraft("A1B2C3", latitude: 40.0, lastUpdate: fetched)
        let older = aircraft("A1B2C3", latitude: 40.1, lastUpdate: fetched.addingTimeInterval(-3))

        let merged = ConnectionLogic.merge(["A1B2C3": older], into: ["A1B2C3": newer])
        #expect(merged["A1B2C3"]?.lastUpdate == fetched)
        #expect(merged["A1B2C3"]?.latitude == 40.0)

        // The other way round it does replace.
        let replaced = ConnectionLogic.merge(["A1B2C3": newer], into: ["A1B2C3": older])
        #expect(replaced["A1B2C3"]?.latitude == 40.0)
    }

    @Test func aStalePreloadLandingAfterAFetchDoesNotRollTheStoreBack() throws {
        // The regular fetch arrives first, then the calibration-screen preload taken 30 s earlier.
        let fresh = keyed(try parse([entry(hex: "a1b2c3", seenPos: "1.0", lat: 40.20),
                                     entry(hex: "d4e5f6", seenPos: "1.0", lat: 41.00)], at: fetched))
        let preload = keyed(try parse([entry(hex: "a1b2c3", seenPos: "1.0", lat: 40.10),
                                       entry(hex: "ffff01", seenPos: "1.0", lat: 42.00)],
                                      at: fetched.addingTimeInterval(-30)))

        let merged = ConnectionLogic.merge(preload, into: ConnectionLogic.merge(fresh, into: [:]))
        #expect(merged["A1B2C3"]?.latitude == 40.20)            // the newer report kept
        #expect(merged["D4E5F6"] != nil)                        // untouched
        #expect(merged["FFFF01"]?.latitude == 42.00)            // only the preload had it
        #expect(merged.count == 3)
    }

    @Test func anADSBReportNewerThanTheInternetCopyIsKept() {
        var adsb = aircraft("A1B2C3", latitude: 40.0, lastUpdate: fetched)
        adsb.source = .adsb
        let internet = aircraft("A1B2C3", latitude: 40.1, lastUpdate: fetched.addingTimeInterval(-2))
        let merged = ConnectionLogic.merge(["A1B2C3": internet], into: ["A1B2C3": adsb])
        #expect(merged["A1B2C3"]?.source == .adsb)
    }

    // MARK: - What reads lastUpdate

    @Test func deadReckoningExtrapolatesFromTheReportTime() throws {
        // Received now, position 10 s old, 480 kt due east: drawn 10 s further on, 1.33 NM.
        let ac = try #require(try parse([entry(seenPos: "10", groundSpeed: 480, track: 90)],
                                        at: Date()).first)
        let predicted = CalculationsLogic.predictedPosition(for: ac, aheadSeconds: 0).coordinate
        let shiftNM = CalculationsLogic.distanceInNauticalMiles(from: ac.coordinate, to: predicted)
        #expect(abs(shiftNM - 480.0 * 10.0 / 3_600.0) < 0.01)
        #expect(predicted.longitude > ac.coordinate.longitude)

        let fresh = try #require(try parse([entry(seenPos: nil)], at: Date()).first)
        let freshPredicted = CalculationsLogic.predictedPosition(for: fresh, aheadSeconds: 0).coordinate
        #expect(CalculationsLogic.distanceInNauticalMiles(from: fresh.coordinate, to: freshPredicted) < 0.01)
    }

    @Test func stalenessCountsTheReportAge() throws {
        let now = Date()
        let old = try #require(try parse([entry(seenPos: "25")], at: now).first)
        let recent = try #require(try parse([entry(seenPos: "5")], at: now).first)
        #expect(CalculationsLogic.isStale(old))
        #expect(!CalculationsLogic.isStale(recent))
    }
}
