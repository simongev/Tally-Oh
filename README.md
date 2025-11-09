# TallyOh - AR Aviation Traffic Visualization

An iOS augmented reality app for visualizing aircraft traffic and nearby airports while flying. The app connects to Sentri (ForeFlight) ADS-B receivers to display real-time traffic data in AR.

## Features

- 🔴 **Real-time Aircraft Tracking**: Shows red circles around nearby aircraft in AR
- 🔵 **Airport Visualization**: Displays blue cones for airports within 20 nautical miles
- 📡 **Dual Data Sources**:
  - **Primary**: Sentri (ForeFlight) ADS-B receiver via GDL 90 protocol
  - **Secondary**: Internet-based data from adsb.lol API (automatic fallback)
  - **Smart Priority**: ADS-B data always takes priority over internet data
- 🌐 **Internet Connectivity**: Automatically fetches aircraft data when internet is available
- 🧭 **Accurate Positioning**: Uses GPS and compass data for precise AR placement
- ✈️ **Flight Information**: Shows callsigns, altitudes, and heading indicators

## Architecture

The app is divided into three main components as requested:

### 1. ConnectionLogic.swift
**Responsible for ADS-B connection and data reception (dual data sources)**

- Connects to Sentri (ForeFlight) ADS-B receiver via UDP
- Implements GDL 90 protocol parsing
- Fetches aircraft data from adsb.lol when internet is available
- Intelligently merges data from both sources (ADS-B priority)
- Manages aircraft data structures with source tracking
- Handles connection states and error recovery
- Monitors network connectivity
- Provides test aircraft for development

**Key Classes:**
- `ConnectionLogic`: Main connection manager (ObservableObject)
- `Aircraft`: Data structure for aircraft information with source tracking
- `AircraftSource`: Enum for data source (adsb, internet)
- `ConnectionStatus`: Enum for connection states

### 2. CalculationsLogic.swift
**Responsible for all positioning calculations**

- Converts GPS coordinates to AR scene positions
- Calculates distances using Haversine formula
- Determines bearings and elevation angles
- Handles coordinate transformations
- Filters objects by distance range

**Key Functions:**
- `calculateARPosition()`: Converts real-world coordinates to AR positions
- `distance()`: Calculates distances between coordinates
- `bearing()`: Determines heading to target
- `filterAirportsInRange()`: Filters nearby airports
- `calculateAircraftCircleRadius()`: Determines circle size based on distance

### 3. MainAppComponents.swift
**Contains all AR visualization components**

- Creates red circles for aircraft
- Generates blue cones for airports
- Renders text labels with ICAO codes
- Manages 3D scene objects
- Handles animations and visual effects

**Key Classes:**
- `ARComponentFactory`: Factory for creating AR components
- `ARSceneManager`: Manages the AR scene and updates
- `ARVisualizationSettings`: Configuration options

## Additional Files

### ARTrafficViewController.swift
Main view controller that integrates all three components:
- Sets up AR session with world tracking
- Manages location services
- Coordinates updates between components
- Provides user interface controls
- Displays data source statistics

### ADSBLolClient.swift
Internet-based aircraft data fetching:
- Connects to adsb.lol API
- Fetches aircraft within specified radius (up to 100 NM)
- Parses ADSBExchange-compatible format
- Converts to internal Aircraft model

### NetworkReachability.swift
Network connectivity monitoring:
- Monitors internet connectivity status
- Detects connection type (WiFi, Cellular, Ethernet)
- Provides real-time connectivity updates
- Enables automatic internet data fetching

### AirportDataParser.swift
Utility for parsing airports.csv:
- Loads airport data from CSV files
- Supports multiple CSV formats
- Validates ICAO codes and coordinates
- Provides async loading

## Requirements

- iOS 13.0+
- iPhone or iPad with ARKit support
- Camera and Location permissions
- Sentri (ForeFlight) ADS-B receiver (optional for testing)

## Setup

### 1. Add airports.csv

Place your `airports.csv` file in the `TallyOh/Resources` directory. Expected format:

```csv
ICAO,Name,Latitude,Longitude,Elevation
KJFK,John F Kennedy International Airport,40.6398,-73.7789,13
KLAX,Los Angeles International Airport,33.9425,-118.4081,125
```

**CSV Format Options:**

- **Simple**: `ICAO,Name,Latitude,Longitude,Elevation`
- **With Country**: `ICAO,Name,Country,Latitude,Longitude,Elevation`

**Field Requirements:**
- ICAO: Exactly 4 characters
- Latitude: -90 to 90 degrees
- Longitude: -180 to 180 degrees
- Elevation: in feet MSL

### 2. Configure Xcode Project

1. Open Xcode and create a new iOS App project
2. Set bundle identifier (e.g., `com.yourcompany.tallyoh`)
3. Add all `.swift` files from `TallyOh/Sources` to the project
4. Add `Info.plist` to the project
5. Add `airports.csv` to the project (ensure it's added to target)

### 3. Enable Capabilities

In Xcode project settings:
- Enable **Camera** usage
- Enable **Location** (When In Use)
- Enable **Local Network** access

### 4. Configure Sentri Connection

Default connection settings:
- **Host**: 192.168.10.1 (typical Sentri IP)
- **Port**: 4000 (GDL 90 over UDP)

To modify, update in `ConnectionLogic.swift`:
```swift
private let defaultHost = "192.168.10.1"
private let defaultPort: UInt16 = 4000
```

## Usage

### Running the App

1. **Start the app** on your device
2. **Grant permissions** for camera and location
3. **Connect to Sentri**:
   - Ensure your device is on the same network as Sentri
   - Tap "Connect to Sentri" button
4. **View AR traffic**:
   - Point camera around to see aircraft and airports
   - Red circles show aircraft with callsigns
   - Blue cones show airports with ICAO codes

### Testing Without Sentri

For development and testing without a physical Sentri device:

1. Tap the settings button (⚙️)
2. Select "Add Test Aircraft"
3. Test aircraft will appear in the AR view

### Settings

Access settings via the ⚙️ button:
- **Toggle Aircraft**: Show/hide aircraft markers
- **Toggle Airports**: Show/hide airport markers
- **Add Test Aircraft**: Add simulated traffic
- **Clear All**: Remove all AR objects

## How It Works

### Data Flow

```
                    ┌─────────────────┐
                    │ Sentri ADS-B    │ (Primary - High Priority)
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ ConnectionLogic │ ◄─── Internet Monitor
                    │  - Merges data  │
                    │  - ADS-B priority│
                    └────────┬────────┘
                             ▲
                             │
                    ┌────────┴────────┐
                    │ adsb.lol API    │ (Secondary - Auto Fallback)
                    └─────────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ Aircraft Data   │
                    └────────┬────────┘
                             │
GPS/Compass → User Position ─┤
                             ▼
                    ┌─────────────────┐
                    │ CalculationsLogic│
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ AR Scene Positions│
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │MainAppComponents│
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ AR Visualization│
                    └─────────────────┘
```

### Data Source Priority Logic

The app uses an intelligent merging system for aircraft data:

1. **ADS-B Data (Priority 1)**: Direct from Sentri receiver
   - Low latency (~1 second)
   - Most accurate for nearby aircraft
   - Limited range (depends on receiver)

2. **Internet Data (Priority 2)**: From adsb.lol API
   - Activated automatically when internet is available
   - Fetches aircraft within 50 NM radius
   - Updates every 10 seconds
   - Supplements ADS-B coverage

3. **Merging Rules**:
   - If aircraft exists in both sources, ADS-B data is used
   - Internet data fills in gaps for aircraft not visible to ADS-B
   - Each aircraft is tagged with its source
   - Status display shows count from each source

### AR Positioning

1. **User Position**: GPS provides latitude, longitude, altitude
2. **Target Position**: Aircraft or airport coordinates
3. **Calculation**: CalculationsLogic converts to relative position
4. **Transformation**: Apply user heading and bearing
5. **Rendering**: MainAppComponents creates 3D objects

### Aircraft Visualization

- **Red Circle**: Torus geometry, size based on distance
- **Callsign Label**: 3D text above circle
- **Altitude Label**: 3D text showing height
- **Direction Arrow**: Yellow arrow indicating heading
- **Pulsing Animation**: Subtle scale animation

### Airport Visualization

- **Blue Cone**: Points downward from elevation
- **ICAO Label**: 4-letter code above cone
- **Distance Filter**: Only shows within 20 NM
- **Rotation Animation**: Subtle spin for visibility

## Configuration Options

### ARVisualizationSettings

Modify in `MainAppComponents.swift`:

```swift
var settings = ARVisualizationSettings()
settings.aircraftMaxDistance = 10.0 // nautical miles
settings.airportMaxDistance = 20.0 // nautical miles
settings.showLabels = true
settings.labelScale = 1.0
```

### Aircraft Circle Sizing

Circles scale with distance for better visibility:
- **< 0.27 NM**: 10m radius
- **< 1 NM**: 20m radius
- **< 3 NM**: 30m radius
- **< 10 NM**: 50m radius
- **> 10 NM**: 100m radius

## GDL 90 Protocol

The app implements the GDL 90 protocol for ADS-B data:

**Supported Messages:**
- `0x00`: Heartbeat
- `0x0A`: Ownship Report
- `0x14`: Traffic Report
- `0x0B`: Ownship Geometric Altitude

**Message Format:**
```
0x7E [Message ID] [Data...] [FCS] 0x7E
```

## Troubleshooting

### Connection Issues

**Problem**: Can't connect to Sentri
**Solutions**:
- Verify Sentri IP address (check ForeFlight settings)
- Ensure WiFi is connected to Sentri network
- Try port 2000 (TCP) instead of 4000 (UDP)
- Check firewall settings

### GPS Issues

**Problem**: "Waiting for GPS"
**Solutions**:
- Ensure Location permission is granted
- Wait for GPS lock (may take 30-60 seconds)
- Try moving to an area with clear sky view
- Restart the app

### AR Tracking Issues

**Problem**: Objects appear in wrong locations
**Solutions**:
- Calibrate compass (move device in figure-8 pattern)
- Ensure good lighting conditions
- Point camera at textured surfaces
- Reset AR session (restart app)

### No Airports Showing

**Problem**: Airports not visible
**Solutions**:
- Verify `airports.csv` is added to Xcode target
- Check CSV format matches specification
- Ensure airports exist within 20 NM
- Toggle airports in settings

## Performance

- **Update Rate**: 1 Hz (configurable)
- **Maximum Aircraft**: Limited by memory (~100 typical)
- **Maximum Airports**: Filtered to 20 NM radius
- **AR Frame Rate**: 60 FPS (device dependent)

## Safety Warning

⚠️ **IMPORTANT**: This app is for situational awareness only and should NOT be used as a primary means of traffic detection or collision avoidance. Always follow proper visual scanning procedures and established aviation safety practices.

- Not certified for flight operations
- ADS-B has limitations and latency
- Not all aircraft transmit ADS-B
- AR display may not be accurate in all conditions
- Never rely solely on electronic traffic systems

## Future Enhancements

Potential improvements:
- NMEA GPS input support
- Traffic alerts and collision warnings
- Terrain and weather overlays
- Flight plan integration
- Record and replay functionality
- Multiple ADS-B source support

## Credits

Developed for AR aviation visualization using:
- ARKit for augmented reality
- SceneKit for 3D graphics
- CoreLocation for positioning
- GDL 90 protocol for ADS-B data

## License

This project is provided as-is for educational and development purposes.

## Support

For issues, questions, or contributions, please contact the development team.

---

**Fly Safe! ✈️**
