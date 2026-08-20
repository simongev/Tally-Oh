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

    // MARK: - Codable models (typed — faster and safer than JSONSerialization)

    private struct Response: Decodable {
        let ac: [AircraftEntry]
    }

    /// Raw JSON entry. Fields are Optional because adsb.lol omits absent values.
    /// alt_baro / baro_rate / geom_rate may arrive as Int OR Double — use
    /// a custom decoder that accepts both.
    private struct AircraftEntry: Decodable {
        let hex:      String
        let lat:      Double?
        let lon:      Double?
        let altBaro:  FlexDouble?   // "alt_baro"
        let altGeom:  FlexDouble?   // "alt_geom"
        let flight:   String?
        let r:        String?       // registration
        let track:    Double?
        let gs:       Double?       // ground speed (knots)
        let baroRate: FlexDouble?   // "baro_rate"
        let geomRate: FlexDouble?   // "geom_rate"
        let t:        String?       // aircraft type e.g. "B738"
        let seenPos:  Double?       // "seen_pos" — seconds since this aircraft's
                                     // position was last updated server-side

        enum CodingKeys: String, CodingKey {
            case hex, lat, lon, flight, r, track, gs, t
            case altBaro  = "alt_baro"
            case altGeom  = "alt_geom"
            case baroRate = "baro_rate"
            case geomRate = "geom_rate"
            case seenPos  = "seen_pos"
        }
    }

    /// Decodes a JSON value that may be an Int, a Double, or the string "ground".
    ///
    /// adsb.lol sends `"alt_baro": "ground"` for an aircraft on the surface. Reading that as
    /// 0 ft MSL is wrong everywhere the field is not at sea level — at a 5,400 ft airport it
    /// places parked traffic a mile underground — so the sentinel is preserved as its own case
    /// and the altitude is reported as absent rather than zero.
    private struct FlexDouble: Decodable {
        let value: Double?
        let isGround: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d; isGround = false; return }
            if let i = try? c.decode(Int.self)    { value = Double(i); isGround = false; return }
            if let s = try? c.decode(String.self) {
                let normalized = s.trimmingCharacters(in: .whitespaces).lowercased()
                value = nil
                isGround = (normalized == "ground")
                return
            }
            value = nil
            isGround = false
        }
    }

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 10.0
        config.timeoutIntervalForResource = 15.0
        // Allow the system to reuse TCP connections across fetches.
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch aircraft within a radius of the given position.
    /// Completion is called on a background queue.
    func fetchAircraft(
        latitude:  Double,
        longitude: Double,
        radiusNM:  Double,
        completion: @escaping (Result<[Aircraft], Error>) -> Void
    ) {
        let distNM = max(1, Int(radiusNM.rounded()))
        let urlString = "\(baseURL)/lat/\(latitude)/lon/\(longitude)/dist/\(distNM)"

        guard let url = URL(string: urlString) else {
            completion(.failure(ADSBError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data else { completion(.failure(ADSBError.noData)); return }

            do {
                let aircraft = try Self.parseResponse(data)
                completion(.success(aircraft))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Private

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // No Date-typed fields are decoded here — "seen_pos" is read as a plain
        // Double (seconds of staleness) and applied in makeAircraft(from:) below,
        // not via JSONDecoder's date-decoding strategy.
        return d
    }()

    private static func parseResponse(_ data: Data) throws -> [Aircraft] {
        let response: Response
        do {
            response = try decoder.decode(Response.self, from: data)
        } catch {
            throw ADSBError.invalidResponse
        }

        var result: [Aircraft] = []
        result.reserveCapacity(response.ac.count)

        for entry in response.ac {
            guard let parsed = makeAircraft(from: entry) else { continue }
            result.append(parsed)
        }
        return result
    }

    private static func makeAircraft(from e: AircraftEntry) -> Aircraft? {
        let icao = e.hex.uppercased()
        guard !icao.isEmpty, let lat = e.lat, let lon = e.lon else { return nil }

        // "ground" in alt_baro means on the surface, not at 0 ft. Fall back to alt_geom only
        // when alt_baro carried no usable number at all.
        let isOnGround = (e.altBaro?.isGround ?? false) || (e.altGeom?.isGround ?? false)
        let reportedAltitude: Double? =
            e.altBaro.flatMap({ $0.value }) ?? e.altGeom.flatMap({ $0.value })

        let callsign: String
        if let flight = e.flight?.trimmingCharacters(in: .whitespaces), !flight.isEmpty {
            callsign = flight
        } else if let reg = e.r, !reg.isEmpty {
            callsign = reg
        } else {
            callsign = icao
        }

        let verticalRate: Double =
            e.baroRate.flatMap({ $0.value }) ?? e.geomRate.flatMap({ $0.value }) ?? 0

        // adsb.lol reports "seen_pos": how many seconds old this aircraft's
        // position already was server-side when it was served to us. Without
        // this, lastUpdate would only reflect local parse time, understating
        // true position age and causing predictedPosition()'s dead-reckoning to
        // lag behind a fast-moving aircraft's real current position.
        let positionStaleness = e.seenPos ?? 0

        return Aircraft(
            id:           icao,
            callsign:     callsign,
            aircraftType: e.t ?? "",
            latitude:     lat,
            longitude:    lon,
            altitude:     reportedAltitude ?? 0,
            track:        e.track ?? 0,
            groundSpeed:  e.gs    ?? 0,
            verticalRate: verticalRate,
            lastUpdate:   Date().addingTimeInterval(-positionStaleness),
            source:       .internet,
            isOnGround:       isOnGround,
            hasValidAltitude: reportedAltitude != nil,
            hasValidTrack:    e.track != nil
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
