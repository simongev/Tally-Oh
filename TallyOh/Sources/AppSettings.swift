//
//  AppSettings.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Manages all app settings with UserDefaults persistence
//

import Foundation

/// App-wide settings with persistence
class AppSettings {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        // Aircraft label settings
        static let showCallsign = "showCallsign"
        static let showAltitude = "showAltitude"
        static let showGroundSpeed = "showGroundSpeed"
        static let showVerticalRate = "showVerticalRate"
        static let showTrack = "showTrack"

        // Distance filters (now continuous)
        static let aircraftMaxDistance = "aircraftMaxDistance"
        static let airportMaxDistance = "airportMaxDistance"

        // Airport type filters
        static let showLargeAirports = "showLargeAirports"
        static let showMediumAirports = "showMediumAirports"
        static let showSmallAirports = "showSmallAirports"
        static let showHeliports = "showHeliports"
        static let showSeaplaneBases = "showSeaplaneBases"
        static let showBalloonports = "showBalloonports"

        // Aircraft filters
        static let showGroundAircraft = "showGroundAircraft"
    }

    // MARK: - Aircraft Label Settings

    var showCallsign: Bool {
        get { defaults.object(forKey: Keys.showCallsign) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showCallsign) }
    }

    var showAltitude: Bool {
        get { defaults.object(forKey: Keys.showAltitude) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showAltitude) }
    }

    var showGroundSpeed: Bool {
        get { defaults.object(forKey: Keys.showGroundSpeed) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showGroundSpeed) }
    }

    var showVerticalRate: Bool {
        get { defaults.object(forKey: Keys.showVerticalRate) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showVerticalRate) }
    }

    var showTrack: Bool {
        get { defaults.object(forKey: Keys.showTrack) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showTrack) }
    }

    // MARK: - Distance Filters (Continuous)

    // Distance range: 10-50 NM
    static let minDistance: Double = 10.0
    static let maxDistance: Double = 50.0

    var aircraftMaxDistance: Double {
        get { defaults.object(forKey: Keys.aircraftMaxDistance) as? Double ?? 40.0 }
        set { defaults.set(newValue, forKey: Keys.aircraftMaxDistance) }
    }

    var airportMaxDistance: Double {
        get { defaults.object(forKey: Keys.airportMaxDistance) as? Double ?? 30.0 }
        set { defaults.set(newValue, forKey: Keys.airportMaxDistance) }
    }

    // MARK: - Airport Type Filters

    var showLargeAirports: Bool {
        get { defaults.object(forKey: Keys.showLargeAirports) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showLargeAirports) }
    }

    var showMediumAirports: Bool {
        get { defaults.object(forKey: Keys.showMediumAirports) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showMediumAirports) }
    }

    var showSmallAirports: Bool {
        get { defaults.object(forKey: Keys.showSmallAirports) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showSmallAirports) }
    }

    var showHeliports: Bool {
        get { defaults.object(forKey: Keys.showHeliports) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showHeliports) }
    }

    var showSeaplaneBases: Bool {
        get { defaults.object(forKey: Keys.showSeaplaneBases) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showSeaplaneBases) }
    }

    var showBalloonports: Bool {
        get { defaults.object(forKey: Keys.showBalloonports) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showBalloonports) }
    }

    // MARK: - Aircraft Filters

    var showGroundAircraft: Bool {
        get { defaults.object(forKey: Keys.showGroundAircraft) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showGroundAircraft) }
    }

    // MARK: - Helper Methods

    /// Generate label text based on current settings
    func generateAircraftLabel(aircraft: Aircraft) -> String {
        var components: [String] = []

        if showCallsign {
            components.append(aircraft.callsign)
        }

        if showAltitude {
            let altText = String(format: "%.0fft", aircraft.altitude)
            components.append(altText)
        }

        if showGroundSpeed {
            let gsText = String(format: "%.0fkts", aircraft.groundSpeed)
            components.append(gsText)
        }

        if showVerticalRate && abs(aircraft.verticalRate) > 100 {
            let vrSymbol = aircraft.verticalRate > 0 ? "↑" : "↓"
            let vrText = String(format: "%@%.0ffpm", vrSymbol, abs(aircraft.verticalRate))
            components.append(vrText)
        }

        if showTrack {
            let trackText = String(format: "%.0f°", aircraft.track)
            components.append(trackText)
        }

        return components.isEmpty ? aircraft.callsign : components.joined(separator: "\n")
    }

    /// Check if an airport should be shown based on type
    func shouldShowAirport(_ airport: Airport) -> Bool {
        guard let type = airport.type else { return false } // Don't show airports without type

        // Exclude closed airports
        if type.contains("closed") {
            return false
        }

        if type.contains("large_airport") && showLargeAirports {
            return true
        }
        if type.contains("medium_airport") && showMediumAirports {
            return true
        }
        if type.contains("small_airport") && showSmallAirports {
            return true
        }
        if type.contains("heliport") && showHeliports {
            return true
        }
        if type.contains("seaplane_base") && showSeaplaneBases {
            return true
        }
        if type.contains("balloonport") && showBalloonports {
            return true
        }

        return false
    }

    /// Check if an aircraft should be shown based on filters
    func shouldShowAircraft(_ aircraft: Aircraft) -> Bool {
        // Check ground filter
        if !showGroundAircraft && aircraft.altitude < 500 {
            return false
        }

        return true
    }

    /// Reset to defaults
    func resetToDefaults() {
        showCallsign = true
        showAltitude = true
        showGroundSpeed = false
        showVerticalRate = false
        showTrack = false

        aircraftMaxDistance = 40.0
        airportMaxDistance = 30.0

        showLargeAirports = true
        showMediumAirports = true
        showSmallAirports = true
        showHeliports = false
        showSeaplaneBases = false
        showBalloonports = false

        showGroundAircraft = true
    }
}

// MARK: - Aircraft Extension for Label Generation

extension Aircraft {
    var labelText: String {
        return AppSettings.shared.generateAircraftLabel(aircraft: self)
    }
}
