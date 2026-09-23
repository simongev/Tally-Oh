//
//  AirportDataParserTests.swift
//  Tally-HoTests
//
//  Locks in that airports render with no internet and no ADS-B: AirportDataParser reads a local
//  CSV file and CalculationsLogic.filterAirportsInRange needs nothing but that parsed data plus
//  a coordinate. Every test here feeds AirportDataParser.loadAirports(from:) a URL to a fixture
//  file written to the temp directory in-process — never Bundle.main, never a network client —
//  so the "no network dependency" claim is proven by construction rather than by mocking
//  anything out.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

struct AirportDataParserTests {

    private let ksfo = CLLocationCoordinate2D(latitude: 37.6188, longitude: -122.3750)

    /// Writes `content` to a fresh temp file and returns its URL. Each test that creates one
    /// removes it again via `defer`, so fixtures never linger between test runs.
    private func fixtureFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airports-fixture-\(UUID().uuidString).csv")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let header =
        "id,ident,type,name,latitude_deg,longitude_deg,elevation_ft,continent,iso_country," +
        "iso_region,municipality,scheduled_service,icao_code,iata_code,gps_code,local_code"

    // MARK: - Correct values from a well-formed CSV

    @Test func parsesValidRowsAndFollowsTheIdentifierFallbackChain() throws {
        let rows = [
            header,
            // icao_code present -> used directly.
            "1,KSFO,large_airport,San Francisco International Airport,37.6188,-122.3750,13," +
                "NA,US,US-CA,San Francisco,yes,KSFO,SFO,KSFO,SFO",
            // icao_code blank, gps_code present -> falls back to gps_code.
            "2,00WI,small_airport,Gps Fallback Field,37.6288,-122.3650,50," +
                "NA,US,US-CA,Testville,no,,,00WI,00WI",
            // icao_code and gps_code both blank -> falls back to ident.
            "3,00XY,medium_airport,Ident Fallback Field,37.6088,-122.3850,100," +
                "NA,US,US-CA,Identville,no,,,,",
            // Non-public type (heliport) -> excluded regardless of otherwise-valid fields.
            "4,00CA,heliport,Some Heliport,37.6000,-122.4000,20,NA,US,US-CA,Helitown,no,,,,00CA"
        ]
        let url = try fixtureFile(rows)
        defer { try? FileManager.default.removeItem(at: url) }

        let airports = try #require(AirportDataParser.loadAirports(from: url))
        #expect(airports.count == 3)

        let byId = Dictionary(uniqueKeysWithValues: airports.map { ($0.id, $0) })

        let sfo = try #require(byId["KSFO"])
        #expect(sfo.name == "San Francisco International Airport")
        #expect(sfo.type == "large_airport")
        #expect(sfo.icao == "KSFO")
        #expect(sfo.latitude == 37.6188)
        #expect(sfo.longitude == -122.3750)
        #expect(sfo.elevation == 13)

        let gpsFallback = try #require(byId["00WI"])
        #expect(gpsFallback.name == "Gps Fallback Field")

        let identFallback = try #require(byId["00XY"])
        #expect(identFallback.name == "Ident Fallback Field")

        #expect(byId["00CA"] == nil, "heliport is not a public airport type and should be dropped")
    }

    // MARK: - Malformed / partial rows

    @Test func skipsMalformedRowsWithoutCrashingAndKeepsParsingAfterThem() throws {
        let rows = [
            header,
            "5,00BAD",                                                                  // too few fields
            "6,00BAD2,small_airport,Bad Coordinate Field,notanumber,alsobad,10," +
                "NA,US,US-CA,Badtown,no,,,00BAD2,00BAD2",                                // non-numeric lat/lon
            "7,00BAD3,small_airport,,37.7000,-122.5000,10," +
                "NA,US,US-CA,Badtown,no,,,00BAD3,00BAD3",                                // empty name
            "8,,small_airport,No Identifier Field,37.8000,-122.6000,10," +
                "NA,US,US-CA,Badtown,no,,,,",                                            // no identifier at all
            "",                                                                          // blank line
            // A valid row after every bad one, proving a bad row doesn't abort the rest of the parse.
            "9,KKKK,large_airport,Good After Bad,38.0000,-122.7000,100," +
                "NA,US,US-CA,Goodtown,yes,KKKK,KKK,KKKK,KKK"
        ]
        let url = try fixtureFile(rows)
        defer { try? FileManager.default.removeItem(at: url) }

        // The contract here is "skip the bad row", not "throw" — loadAirports(from:) returns a
        // non-nil array with only the good rows in it.
        let airports = try #require(AirportDataParser.loadAirports(from: url))
        #expect(airports.count == 1)
        #expect(airports.first?.id == "KKKK")
        #expect(airports.first?.name == "Good After Bad")
    }

    // MARK: - CSV -> filter chain needs only local data + a coordinate

    @Test func filterAirportsInRangeReturnsOnlyTheAirportsWithinDistance() throws {
        let rows = [
            header,
            // ~0.06 NM from ksfo.
            "1,KNEAR,small_airport,Near Field,37.6198,-122.3750,10," +
                "NA,US,US-CA,Neartown,no,KNEAR,,KNEAR,KNEAR",
            // ~30 NM from ksfo (0.5 deg latitude).
            "2,KMID,small_airport,Mid Field,38.1188,-122.3750,10," +
                "NA,US,US-CA,Midtown,no,KMID,,KMID,KMID",
            // ~300 NM from ksfo (5 deg latitude).
            "3,KFAR,small_airport,Far Field,42.6188,-122.3750,10," +
                "NA,US,US-CA,Fartown,no,KFAR,,KFAR,KFAR"
        ]
        let url = try fixtureFile(rows)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try #require(AirportDataParser.loadAirports(from: url))
        #expect(parsed.count == 3)

        let tight = CalculationsLogic.filterAirportsInRange(
            airports: parsed, userCoord: ksfo, maxRangeNauticalMiles: 10)
        #expect(Set(tight.map(\.id)) == ["KNEAR"])

        let wider = CalculationsLogic.filterAirportsInRange(
            airports: parsed, userCoord: ksfo, maxRangeNauticalMiles: 50)
        #expect(Set(wider.map(\.id)) == ["KNEAR", "KMID"])

        let veryWide = CalculationsLogic.filterAirportsInRange(
            airports: parsed, userCoord: ksfo, maxRangeNauticalMiles: 500)
        #expect(Set(veryWide.map(\.id)) == ["KNEAR", "KMID", "KFAR"])
    }
}
