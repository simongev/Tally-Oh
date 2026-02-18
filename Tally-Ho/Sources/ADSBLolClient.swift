//
//  ADSBLolClient.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Fetches live aircraft positions from the adsb.lol public API
//  Endpoint: GET /v2/lat/{lat}/lon/{lon}/dist/{dist}
//

import Foundation
import CoreLocation

/// Fetches live aircraft data from the adsb.lol public API
class ADSBLolClient {

    private let baseURL = "https://api.adsb.lol/v2"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch aircraft within a radius of the given position
    /// - Parameters:
    ///   - latitude: Center latitude in decimal degrees
    ///   - longitude: Center longitude in decimal degrees
    ///   - radiusNM: Search radius in nautical miles
    ///   - completion: Called on a background queue with the result
    func fetchAircraft(
        latitude: Double,
        longitude: Double,
        radiusNM: Double,
        completion: @escaping (Result<[Aircraft], Error>) -> Void
    ) {
        // adsb.lol /v2 endpoint expects distance in nautical miles (integer)
        let distNM = max(1, Int(radiusNM.rounded()))
        let urlString = "\(baseURL)/lat/\(latitude)/lon/\(longitude)/dist/\(distNM)"

        guard let url = URL(string: urlString) else {
            completion(.failure(ADSBError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(ADSBError.noData))
                return
            }

            do {
                let aircraft = try Self.parseResponse(data)
                completion(.success(aircraft))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Private

    /// Parse the adsb.lol JSON response into Aircraft objects
    private static func parseResponse(_ data: Data) throws -> [Aircraft] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acArray = json["ac"] as? [[String: Any]] else {
            throw ADSBError.invalidResponse
        }

        var aircraft: [Aircraft] = []

        for ac in acArray {
            guard let parsed = parseAircraftObject(ac) else { continue }
            aircraft.append(parsed)
        }

        return aircraft
    }

    /// Parse a single aircraft JSON object
    private static func parseAircraftObject(_ ac: [String: Any]) -> Aircraft? {
        // ICAO hex address is required
        guard let hex = ac["hex"] as? String, !hex.isEmpty else { return nil }
        let icao = hex.uppercased()

        // Position is required
        guard let lat = ac["lat"] as? Double,
              let lon = ac["lon"] as? Double else { return nil }

        // Altitude — prefer barometric, fall back to geometric
        let altitude: Double
        if let altBaro = ac["alt_baro"] as? Double {
            altitude = altBaro
        } else if let altBaro = ac["alt_baro"] as? Int {
            altitude = Double(altBaro)
        } else if let altGeom = ac["alt_geom"] as? Double {
            altitude = altGeom
        } else if let altGeom = ac["alt_geom"] as? Int {
            altitude = Double(altGeom)
        } else {
            altitude = 0
        }

        // Callsign — use flight number, fall back to registration, then ICAO
        let callsign: String
        if let flight = ac["flight"] as? String, !flight.trimmingCharacters(in: .whitespaces).isEmpty {
            callsign = flight.trimmingCharacters(in: .whitespaces)
        } else if let reg = ac["r"] as? String, !reg.isEmpty {
            callsign = reg
        } else {
            callsign = icao
        }

        // Track / heading
        let track = ac["track"] as? Double ?? 0.0

        // Ground speed in knots
        let groundSpeed = ac["gs"] as? Double ?? 0.0

        // Vertical rate in feet per minute
        let verticalRate: Double
        if let rate = ac["baro_rate"] as? Double {
            verticalRate = rate
        } else if let rate = ac["baro_rate"] as? Int {
            verticalRate = Double(rate)
        } else if let rate = ac["geom_rate"] as? Double {
            verticalRate = rate
        } else {
            verticalRate = 0
        }

        return Aircraft(
            id: icao,
            callsign: callsign,
            latitude: lat,
            longitude: lon,
            altitude: altitude,
            track: track,
            groundSpeed: groundSpeed,
            verticalRate: verticalRate,
            lastUpdate: Date(),
            source: .internet
        )
    }
}

// MARK: - Errors

enum ADSBError: LocalizedError {
    case invalidURL
    case noData
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:      return "Invalid adsb.lol API URL"
        case .noData:          return "No data received from adsb.lol"
        case .invalidResponse: return "Unexpected response format from adsb.lol"
        }
    }
}
