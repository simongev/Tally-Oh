//
//  ADSBLolClient.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Fetches aircraft data from adsb.lol API as backup data source
//  Compatible with ADSBExchange Rapid API format
//

import Foundation
import CoreLocation

/// Response from adsb.lol API
struct ADSBLolResponse: Codable {
    let ac: [ADSBLolAircraft]?
    let total: Int?
    let ctime: Double?
    let ptime: Double?
}

/// Aircraft data from adsb.lol API
struct ADSBLolAircraft: Codable {
    let hex: String?           // ICAO address
    let type: String?          // Type of message (adsb_icao, mlat, etc.)
    let flight: String?        // Callsign
    let r: String?             // Registration
    let t: String?             // Aircraft type
    let alt_baro: Int?         // Altitude (barometric) in feet
    let alt_geom: Int?         // Altitude (geometric) in feet
    let gs: Double?            // Ground speed in knots
    let track: Double?         // Track in degrees
    let baro_rate: Int?        // Vertical rate (barometric) in feet/min
    let geom_rate: Int?        // Vertical rate (geometric) in feet/min
    let lat: Double?           // Latitude
    let lon: Double?           // Longitude
    let seen_pos: Double?      // Seconds since last position
    let seen: Double?          // Seconds since last message
    let category: String?      // Emitter category

    // Additional fields
    let nav_altitude_mcp: Int? // Selected altitude
    let nav_heading: Double?   // Selected heading
    let squawk: String?        // Transponder code
    let emergency: String?     // Emergency status
}

/// Client for fetching aircraft data from adsb.lol
class ADSBLolClient {

    // MARK: - Properties

    private let baseURL = "https://api.adsb.lol/v2"
    private let session: URLSession
    private let maxDistance: Double = 100.0 // Maximum 100 NM as per API limit

    // MARK: - Initialization

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public Methods

    /// Fetch aircraft within radius of a location
    /// - Parameters:
    ///   - latitude: Center latitude
    ///   - longitude: Center longitude
    ///   - radiusNM: Radius in nautical miles (max 100)
    ///   - completion: Completion handler with aircraft array or error
    func fetchAircraft(
        latitude: Double,
        longitude: Double,
        radiusNM: Double,
        completion: @escaping (Result<[Aircraft], Error>) -> Void
    ) {
        // Clamp radius to API maximum
        let radius = min(radiusNM, maxDistance)

        // Build URL using ADSBExchange-compatible endpoint
        // Format: /v2/lat/{lat}/lon/{lon}/dist/{dist}/
        let urlString = "\(baseURL)/lat/\(latitude)/lon/\(longitude)/dist/\(Int(radius))/"

        guard let url = URL(string: urlString) else {
            completion(.failure(ADSBLolError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(ADSBLolError.invalidResponse))
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(ADSBLolError.httpError(statusCode: httpResponse.statusCode)))
                return
            }

            guard let data = data else {
                completion(.failure(ADSBLolError.noData))
                return
            }

            do {
                let decoder = JSONDecoder()
                let response = try decoder.decode(ADSBLolResponse.self, from: data)

                // Convert to Aircraft objects
                let aircraft = self.convertToAircraft(response.ac ?? [])

                print("✓ Fetched \(aircraft.count) aircraft from adsb.lol")
                completion(.success(aircraft))

            } catch {
                print("❌ Failed to decode adsb.lol response: \(error)")
                completion(.failure(error))
            }
        }

        task.resume()
    }

    /// Fetch aircraft asynchronously (async/await version)
    @available(iOS 15.0, *)
    func fetchAircraft(
        latitude: Double,
        longitude: Double,
        radiusNM: Double
    ) async throws -> [Aircraft] {
        try await withCheckedThrowingContinuation { continuation in
            fetchAircraft(latitude: latitude, longitude: longitude, radiusNM: radiusNM) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Private Methods

    /// Convert ADSBLol aircraft to our Aircraft model
    private func convertToAircraft(_ adsbAircraft: [ADSBLolAircraft]) -> [Aircraft] {
        var aircraft: [Aircraft] = []

        for ac in adsbAircraft {
            // Require minimum data: ICAO, position, altitude
            guard let icao = ac.hex,
                  let lat = ac.lat,
                  let lon = ac.lon,
                  let altitude = ac.alt_baro ?? ac.alt_geom else {
                continue
            }

            // Clean up callsign (remove trailing spaces)
            let callsign = ac.flight?.trimmingCharacters(in: .whitespaces) ?? "N/A"

            let aircraftItem = Aircraft(
                id: icao.uppercased(),
                callsign: callsign.isEmpty ? icao.uppercased() : callsign,
                latitude: lat,
                longitude: lon,
                altitude: Double(altitude),
                track: ac.track ?? 0.0,
                groundSpeed: ac.gs ?? 0.0,
                verticalRate: Double(ac.baro_rate ?? ac.geom_rate ?? 0),
                lastUpdate: Date(),
                source: .internet // Mark as internet source
            )

            aircraft.append(aircraftItem)
        }

        return aircraft
    }
}

// MARK: - Errors

enum ADSBLolError: LocalizedError {
    case invalidURL
    case invalidResponse
    case noData
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid server response"
        case .noData:
            return "No data received"
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}
