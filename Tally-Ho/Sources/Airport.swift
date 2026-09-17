//
//  Airport.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The airport model, as parsed from the bundled OurAirports data.
//

import Foundation
import CoreLocation

struct Airport: Identifiable {
    let id: String // ICAO code
    let icao: String
    let name: String
    let type: String // e.g. "large_airport", "medium_airport", "small_airport", "heliport", etc.
    let latitude: Double
    let longitude: Double
    let elevation: Double // in feet MSL

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
