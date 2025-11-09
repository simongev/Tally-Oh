# TallyOh Project Structure

## Directory Layout

```
Tally-Oh/
├── README.md                          # Main documentation
├── PROJECT_STRUCTURE.md               # This file
├── TallyOh/
│   ├── Sources/                       # Swift source files
│   │   ├── ConnectionLogic.swift      # ADS-B connection management
│   │   ├── CalculationsLogic.swift    # AR positioning calculations
│   │   ├── MainAppComponents.swift    # AR visualization components
│   │   ├── ARTrafficViewController.swift  # Main view controller
│   │   ├── AppDelegate.swift          # App lifecycle
│   │   └── AirportDataParser.swift    # CSV parsing utility
│   ├── Resources/                     # Resources
│   │   └── airports.csv               # Airport database
│   └── Info.plist                     # App configuration
```

## File Descriptions

### Core Components (Required Files)

#### 1. ConnectionLogic.swift
**Purpose**: Manages connection to Sentri (ForeFlight) ADS-B receiver

**Key Components**:
- `ConnectionLogic` class: ObservableObject for connection management
- `Aircraft` struct: Data model for aircraft information
- `ConnectionStatus` enum: Connection state tracking
- GDL 90 protocol parsing
- UDP network communication
- Aircraft timeout management

**Dependencies**:
- Foundation
- Network (NWConnection)
- CoreLocation
- Combine (for ObservableObject)

**Public Interface**:
```swift
func connect(host: String?, port: UInt16?)
func disconnect()
func addTestAircraft()
@Published var connectionStatus: ConnectionStatus
@Published var detectedAircraft: [String: Aircraft]
@Published var ownshipData: Aircraft?
```

#### 2. CalculationsLogic.swift
**Purpose**: All mathematical calculations for AR positioning

**Key Components**:
- Distance calculations (Haversine formula)
- Bearing calculations
- 3D position transformations
- Coordinate filtering
- `Airport` struct definition

**Static Methods**:
```swift
static func distance(from:to:) -> Double
static func bearing(from:to:) -> Double
static func calculateARPosition(...) -> SCNVector3
static func filterAirportsInRange(...) -> [Airport]
static func calculateAircraftCircleRadius(distance:) -> Float
```

**No Dependencies** (pure calculation logic)

#### 3. MainAppComponents.swift
**Purpose**: AR visualization components and scene management

**Key Components**:
- `ARComponentFactory`: Factory for creating AR objects
- `ARSceneManager`: Scene update management
- `ARVisualizationSettings`: Configuration struct

**Public Interface**:
```swift
// Factory methods
static func createAircraftMarker(...) -> SCNNode
static func createAirportMarker(...) -> SCNNode
static func createTextLabel(...) -> SCNNode

// Scene management
func updateAircraft(...)
func updateAirports(...)
func clearAll()
```

**Dependencies**:
- Foundation
- SceneKit
- ARKit
- UIKit

### Supporting Files

#### 4. ARTrafficViewController.swift
**Purpose**: Main view controller integrating all components

**Responsibilities**:
- AR session management
- Location services
- UI controls
- Update loop coordination
- Combines ConnectionLogic, CalculationsLogic, and MainAppComponents

**Dependencies**:
- UIKit
- ARKit
- CoreLocation
- Combine

#### 5. AirportDataParser.swift
**Purpose**: Parse and load airport data from CSV

**Key Methods**:
```swift
static func loadAirportsFromCSV(filename:) -> [Airport]?
static func loadAirportsFromFile(path:) -> [Airport]?
static func createSampleCSV(at:)
```

**Supports**:
- CSV parsing with quoted fields
- Multiple CSV formats
- Async loading
- Data validation

#### 6. AppDelegate.swift
**Purpose**: Application lifecycle management

**Responsibilities**:
- Window setup
- Root view controller initialization
- App appearance configuration

#### 7. Info.plist
**Purpose**: App configuration and permissions

**Key Configurations**:
- Camera usage permission
- Location usage permissions
- Local network usage permission
- ARKit requirement
- Network security settings

### Resources

#### 8. airports.csv
**Purpose**: Database of worldwide airports

**Format**:
```
ICAO,Name,Latitude,Longitude,Elevation
```

**Current Data**: 100+ major airports worldwide

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                   ARTrafficViewController                    │
│  - Coordinates all components                               │
│  - Manages UI and user input                                │
└────────┬──────────────────────────┬──────────────────┬──────┘
         │                          │                  │
         ▼                          ▼                  ▼
┌────────────────┐         ┌────────────────┐  ┌──────────────┐
│ConnectionLogic │         │CalculationsLogic│  │ARSceneManager│
│                │         │                │  │              │
│- Receives      │         │- Converts      │  │- Updates     │
│  ADS-B data    │         │  coordinates   │  │  AR scene    │
│- Parses        │─────────│- Calculates    │─▶│- Renders     │
│  aircraft      │         │  positions     │  │  objects     │
│                │         │- Filters       │  │              │
└────────────────┘         └────────────────┘  └──────────────┘
         │                          ▲
         │                          │
         ▼                          │
┌────────────────┐         ┌────────────────┐
│  Sentri ADS-B  │         │   GPS/Compass  │
│   Receiver     │         │                │
└────────────────┘         └────────────────┘
```

## Class Relationships

```
ARTrafficViewController
├── owns: ConnectionLogic
├── owns: ARSceneManager
│   └── uses: ARComponentFactory
├── uses: CLLocationManager
└── uses: CalculationsLogic (static methods)

ConnectionLogic
├── publishes: Aircraft[]
└── publishes: ConnectionStatus

ARSceneManager
├── owns: ARSCNView (weak reference)
├── manages: SCNNode dictionary
└── uses: CalculationsLogic
    └── uses: Airport[]
```

## Key Design Patterns

### 1. Observable Pattern
- `ConnectionLogic` uses `@Published` properties
- View controller observes changes via Combine

### 2. Factory Pattern
- `ARComponentFactory` creates all AR objects
- Centralizes visualization logic

### 3. Manager Pattern
- `ARSceneManager` manages scene updates
- Separates concerns from view controller

### 4. Static Utility Pattern
- `CalculationsLogic` provides pure functions
- No state, just calculations

## Extension Points

### Adding New Aircraft Data Sources
1. Create new class similar to `ConnectionLogic`
2. Publish `Aircraft` array
3. Subscribe in `ARTrafficViewController`

### Adding New Visualizations
1. Add factory method to `ARComponentFactory`
2. Add update method to `ARSceneManager`
3. Call from `ARTrafficViewController`

### Adding New Settings
1. Update `ARVisualizationSettings`
2. Use in `ARSceneManager`
3. Expose in settings UI

## Build Requirements

### Minimum Requirements
- Xcode 13.0+
- iOS 13.0+
- Swift 5.5+

### Device Requirements
- ARKit compatible device (iPhone 6s or later)
- Camera
- GPS
- Compass

### Frameworks
- ARKit
- SceneKit
- CoreLocation
- Network
- Combine
- UIKit
- Foundation

## Testing Strategy

### Unit Testing
- Test `CalculationsLogic` functions
- Test `AirportDataParser` parsing
- Test coordinate transformations

### Integration Testing
- Test ConnectionLogic with mock data
- Test ARSceneManager updates
- Test end-to-end data flow

### Manual Testing
- Test with real Sentri device
- Test in flight conditions
- Test AR tracking accuracy

## Performance Considerations

### Optimization Points
1. **Airport Filtering**: Filter by distance before rendering
2. **Update Rate**: Throttle updates to 1 Hz
3. **Object Pooling**: Reuse SCNNodes when possible
4. **LOD**: Vary detail based on distance

### Memory Management
- Weak references in scene manager
- Remove old aircraft after timeout
- Limit visible airports to 20 NM

## Security Considerations

### Network Security
- Local network only (Sentri)
- No internet connectivity required
- UDP protocol (no authentication)

### Privacy
- Location data stays on device
- No data transmission to servers
- Camera used only for AR

## Known Limitations

1. **GDL 90 Implementation**: Basic implementation, not all messages supported
2. **ADS-B Coverage**: Only shows ADS-B equipped aircraft
3. **Accuracy**: Depends on GPS and compass accuracy
4. **Latency**: ADS-B has inherent latency (~1 second)
5. **Range**: Limited by ADS-B receiver range

## Future Architecture Improvements

1. **Protocol Abstraction**: Abstract GDL 90 to support multiple protocols
2. **Data Persistence**: Cache airport data
3. **Offline Mode**: Support operation without ADS-B
4. **Unit Tests**: Add comprehensive test coverage
5. **Dependency Injection**: Improve testability
