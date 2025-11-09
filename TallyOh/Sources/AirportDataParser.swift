//
//  AirportDataParser.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Parses airports.csv file to load airport data
//  Supports both simple format and OurAirports.com format
//

import Foundation

class AirportDataParser {

    /// Load airports from CSV file in the app bundle
    static func loadAirportsFromCSV(filename: String = "airports") -> [Airport]? {

        guard let filepath = Bundle.main.path(forResource: filename, ofType: "csv") else {
            print("❌ Could not find \(filename).csv in bundle")
            return nil
        }

        return loadAirportsFromFile(path: filepath)
    }

    /// Load airports from a specific file path
    static func loadAirportsFromFile(path: String) -> [Airport]? {

        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            return parseCSVContent(content)
        } catch {
            print("❌ Error reading file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parse CSV content string
    private static func parseCSVContent(_ content: String) -> [Airport] {

        var airports: [Airport] = []
        let lines = content.components(separatedBy: .newlines)

        guard let headerLine = lines.first else {
            print("❌ Empty CSV file")
            return []
        }

        // Detect format based on header
        let isOurAirportsFormat = headerLine.contains("latitude_deg") || headerLine.contains("longitude_deg")

        print("📋 Detected format: \(isOurAirportsFormat ? "OurAirports.com" : "Simple")")

        for (index, line) in lines.enumerated() {
            if index == 0 { continue } // Skip header
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if isOurAirportsFormat {
                if let airport = parseOurAirportsLine(line, lineNumber: index + 1) {
                    airports.append(airport)
                }
            } else {
                if let airport = parseSimpleLine(line, lineNumber: index + 1) {
                    airports.append(airport)
                }
            }
        }

        print("✓ Loaded \(airports.count) airports from CSV")
        return airports
    }

    /// Parse OurAirports.com format
    /// Format: id,ident,type,name,latitude_deg,longitude_deg,elevation_ft,continent,iso_country,iso_region,municipality,scheduled_service,icao_code,iata_code,gps_code,local_code,home_link,wikipedia_link,keywords
    private static func parseOurAirportsLine(_ line: String, lineNumber: Int) -> Airport? {

        let components = parseCSVFields(line)

        guard components.count >= 15 else {
            return nil
        }

        // Extract fields
        let ident = components[1].trimmingCharacters(in: .whitespaces)
        let name = components[3].trimmingCharacters(in: .whitespaces)
        let latString = components[4].trimmingCharacters(in: .whitespaces)
        let lonString = components[5].trimmingCharacters(in: .whitespaces)
        let elevString = components[6].trimmingCharacters(in: .whitespaces)
        let icaoCode = components[12].trimmingCharacters(in: .whitespaces)
        let gpsCode = components[14].trimmingCharacters(in: .whitespaces)

        // Determine ICAO code (priority: icao_code, gps_code, ident)
        var finalIcao = ""
        if !icaoCode.isEmpty && icaoCode.count == 4 {
            finalIcao = icaoCode
        } else if !gpsCode.isEmpty && gpsCode.count == 4 {
            finalIcao = gpsCode
        } else if ident.count == 4 {
            finalIcao = ident
        }

        // Only include airports with valid 4-character ICAO codes
        guard finalIcao.count == 4 else {
            return nil
        }

        // Parse coordinates
        guard let latitude = Double(latString),
              let longitude = Double(lonString) else {
            return nil
        }

        // Parse elevation (default to 0 if empty, for seaplane bases)
        let elevation = Double(elevString) ?? 0.0

        // Validate coordinates
        guard latitude >= -90 && latitude <= 90,
              longitude >= -180 && longitude <= 180 else {
            return nil
        }

        return Airport(
            id: finalIcao,
            icao: finalIcao,
            name: name.isEmpty ? ident : name,
            latitude: latitude,
            longitude: longitude,
            elevation: elevation
        )
    }

    /// Parse simple CSV format
    /// Expected format: ICAO,Name,Latitude,Longitude,Elevation
    /// Alternative format: ICAO,Name,Country,Latitude,Longitude,Elevation
    private static func parseSimpleLine(_ line: String, lineNumber: Int) -> Airport? {

        let components = parseCSVFields(line)

        guard components.count >= 5 else {
            return nil
        }

        let icao = components[0].trimmingCharacters(in: .whitespaces)
        guard icao.count == 4 else {
            return nil
        }

        // Determine format based on number of fields
        var nameIndex = 1
        var latIndex = 2
        var lonIndex = 3
        var elevIndex = 4

        // If we have 6+ fields, assume format with country: ICAO,Name,Country,Lat,Lon,Elev
        if components.count >= 6 {
            latIndex = 3
            lonIndex = 4
            elevIndex = 5
        }

        let name = components[nameIndex].trimmingCharacters(in: .whitespaces)

        guard let latitude = Double(components[latIndex].trimmingCharacters(in: .whitespaces)),
              let longitude = Double(components[lonIndex].trimmingCharacters(in: .whitespaces)),
              let elevation = Double(components[elevIndex].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        // Validate coordinates
        guard latitude >= -90 && latitude <= 90,
              longitude >= -180 && longitude <= 180 else {
            return nil
        }

        return Airport(
            id: icao,
            icao: icao,
            name: name,
            latitude: latitude,
            longitude: longitude,
            elevation: elevation
        )
    }

    /// Parse CSV fields, handling quoted fields with commas
    private static func parseCSVFields(_ line: String) -> [String] {
        var fields: [String] = []
        var currentField = ""
        var insideQuotes = false

        for char in line {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == "," && !insideQuotes {
                fields.append(currentField)
                currentField = ""
            } else {
                currentField.append(char)
            }
        }

        // Add the last field
        fields.append(currentField)

        return fields.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    /// Load airports asynchronously
    static func loadAirportsAsync(
        filename: String = "airports",
        completion: @escaping ([Airport]?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let airports = loadAirportsFromCSV(filename: filename)
            DispatchQueue.main.async {
                completion(airports)
            }
        }
    }
}

// MARK: - CSV Format Documentation

/*
 Supported CSV Formats:

 Format 1 (Simple):
 ICAO,Name,Latitude,Longitude,Elevation
 KJFK,John F Kennedy International Airport,40.6398,-73.7789,13

 Format 2 (Simple with Country):
 ICAO,Name,Country,Latitude,Longitude,Elevation
 KJFK,John F Kennedy International Airport,United States,40.6398,-73.7789,13

 Format 3 (OurAirports.com):
 id,ident,type,name,latitude_deg,longitude_deg,elevation_ft,continent,iso_country,iso_region,municipality,scheduled_service,icao_code,iata_code,gps_code,local_code,home_link,wikipedia_link,keywords
 3622,"KJFK","large_airport","John F Kennedy International Airport",40.639447,-73.779317,13,"NA","US","US-NY","New York","yes","KJFK","JFK","KJFK","JFK","https://www.jfkairport.com/","https://en.wikipedia.org/wiki/John_F._Kennedy_International_Airport","Manhattan, New York City, NYC, Idlewild, IDL, KIDL"

 Notes:
 - ICAO code must be exactly 4 characters
 - For OurAirports format, priority: icao_code field -> gps_code field -> ident field
 - Only airports with valid 4-character ICAO codes are included
 - Latitude: -90 to 90 degrees
 - Longitude: -180 to 180 degrees
 - Elevation: in feet MSL (defaults to 0 if empty)
 - Fields with commas should be quoted
 */
