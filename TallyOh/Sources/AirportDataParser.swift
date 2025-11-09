//
//  AirportDataParser.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Parses airports.csv file to load airport data
//

import Foundation

class AirportDataParser {

    /// Load airports from CSV file in the app bundle
    /// Expected CSV format: ICAO,Name,Latitude,Longitude,Elevation
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

        // Skip header line if present
        let startIndex = lines.first?.contains("ICAO") == true ? 1 : 0

        for (index, line) in lines.enumerated() {
            if index < startIndex { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if let airport = parseCSVLine(line, lineNumber: index + 1) {
                airports.append(airport)
            }
        }

        print("✓ Loaded \(airports.count) airports from CSV")
        return airports
    }

    /// Parse a single CSV line
    /// Expected format: ICAO,Name,Latitude,Longitude,Elevation
    /// Alternative format: ICAO,Name,Country,Latitude,Longitude,Elevation
    private static func parseCSVLine(_ line: String, lineNumber: Int) -> Airport? {

        // Handle CSV with quoted fields
        let components = parseCSVFields(line)

        guard components.count >= 5 else {
            // Skip invalid lines silently (could be blank or malformed)
            return nil
        }

        let icao = components[0].trimmingCharacters(in: .whitespaces)
        guard icao.count == 4 else {
            // ICAO codes must be exactly 4 characters
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

    /// Create a sample airports.csv for testing
    static func createSampleCSV(at path: String) {
        let sampleData = """
        ICAO,Name,Latitude,Longitude,Elevation
        KJFK,John F Kennedy International Airport,40.6398,-73.7789,13
        KLAX,Los Angeles International Airport,33.9425,-118.4081,125
        KORD,Chicago O'Hare International Airport,41.9786,-87.9048,672
        KATL,Hartsfield-Jackson Atlanta International Airport,33.6367,-84.4281,1026
        KDFW,Dallas Fort Worth International Airport,32.8968,-97.0380,607
        KDEN,Denver International Airport,39.8617,-104.6731,5434
        KSFO,San Francisco International Airport,37.6213,-122.3790,13
        KLAS,McCarran International Airport,36.0840,-115.1537,2181
        KSEA,Seattle-Tacoma International Airport,47.4502,-122.3088,433
        KMIA,Miami International Airport,25.7959,-80.2870,8
        KPHX,Phoenix Sky Harbor International Airport,33.4342,-112.0080,1135
        KIAH,George Bush Intercontinental Airport,29.9844,-95.3414,97
        KBOS,Boston Logan International Airport,42.3656,-71.0096,19
        KMSP,Minneapolis-St Paul International Airport,44.8848,-93.2223,841
        KDTW,Detroit Metropolitan Wayne County Airport,42.2124,-83.3534,645
        KPHL,Philadelphia International Airport,39.8744,-75.2424,36
        KCLT,Charlotte Douglas International Airport,35.2144,-80.9473,748
        KBWI,Baltimore/Washington International Airport,39.1774,-76.6684,146
        KMDW,Chicago Midway International Airport,41.7868,-87.7522,620
        KOAK,Oakland International Airport,37.7213,-122.2208,9
        """

        do {
            try sampleData.write(toFile: path, atomically: true, encoding: .utf8)
            print("✓ Created sample airports.csv at \(path)")
        } catch {
            print("❌ Error creating sample CSV: \(error.localizedDescription)")
        }
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
 Expected CSV Formats:

 Format 1 (Simple):
 ICAO,Name,Latitude,Longitude,Elevation
 KJFK,John F Kennedy International Airport,40.6398,-73.7789,13

 Format 2 (With Country):
 ICAO,Name,Country,Latitude,Longitude,Elevation
 KJFK,John F Kennedy International Airport,United States,40.6398,-73.7789,13

 Notes:
 - ICAO code must be exactly 4 characters
 - Latitude: -90 to 90 degrees
 - Longitude: -180 to 180 degrees
 - Elevation: in feet MSL
 - Fields with commas should be quoted
 - Header line is optional but recommended
 */
