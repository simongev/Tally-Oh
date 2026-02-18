//
//  AirportDataParser.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Parses airport data from the bundled airports.csv file (OurAirports format)
//

import Foundation

/// Parses airports.csv and returns Airport objects
class AirportDataParser {

    // Column indices in the OurAirports CSV format
    private enum Column: Int {
        case id = 0
        case ident = 1
        case type = 2
        case name = 3
        case latitude = 4
        case longitude = 5
        case elevation = 6
        case continent = 7
        case isoCountry = 8
        case isoRegion = 9
        case municipality = 10
        case scheduledService = 11
        case icaoCode = 12
        case iataCode = 13
        case gpsCode = 14
        case localCode = 15
        // remaining columns not needed
    }

    /// Load and parse airports from the bundled airports.csv
    /// Returns nil if the file cannot be found or parsed
    static func loadAirportsFromCSV() -> [Airport]? {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "csv") else {
            print("⚠️ airports.csv not found in bundle")
            return nil
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            print("⚠️ Could not read airports.csv")
            return nil
        }

        var airports: [Airport] = []
        let lines = content.components(separatedBy: "\n")

        // Skip header row (index 0)
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let airport = parseCSVLine(trimmed) else { continue }
            airports.append(airport)
        }

        print("✅ Loaded \(airports.count) airports from CSV")
        return airports
    }

    // MARK: - Private

    /// Parse a single CSV line into an Airport, returning nil for invalid/unusable rows
    private static func parseCSVLine(_ line: String) -> Airport? {
        let fields = parseCSVFields(line)

        guard fields.count > Column.elevation.rawValue else { return nil }

        // Latitude and longitude are required
        guard let latitude = Double(fields[Column.latitude.rawValue]),
              let longitude = Double(fields[Column.longitude.rawValue]) else {
            return nil
        }

        // Use icao_code first, fall back to gps_code, then ident
        let icao = bestIdentifier(fields: fields)
        guard !icao.isEmpty else { return nil }

        let name = fields[Column.name.rawValue]
        guard !name.isEmpty else { return nil }

        let elevationRaw = fields[Column.elevation.rawValue]
        let elevation = Double(elevationRaw) ?? 0.0

        return Airport(
            id: icao,
            icao: icao,
            name: name,
            latitude: latitude,
            longitude: longitude,
            elevation: elevation
        )
    }

    /// Pick the best ICAO identifier from the available columns
    private static func bestIdentifier(fields: [String]) -> String {
        // Prefer icao_code column (col 12), then gps_code (col 14), then ident (col 1)
        let icaoCode = fields.count > Column.icaoCode.rawValue ? fields[Column.icaoCode.rawValue] : ""
        if !icaoCode.isEmpty { return icaoCode }

        let gpsCode = fields.count > Column.gpsCode.rawValue ? fields[Column.gpsCode.rawValue] : ""
        if !gpsCode.isEmpty { return gpsCode }

        let ident = fields.count > Column.ident.rawValue ? fields[Column.ident.rawValue] : ""
        return ident
    }

    /// Parse a CSV line respecting quoted fields (fields may contain commas inside quotes)
    private static func parseCSVFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false

        for char in line {
            switch char {
            case "\"":
                insideQuotes.toggle()
            case ",":
                if insideQuotes {
                    current.append(char)
                } else {
                    fields.append(current)
                    current = ""
                }
            default:
                current.append(char)
            }
        }
        fields.append(current) // last field

        return fields
    }
}
