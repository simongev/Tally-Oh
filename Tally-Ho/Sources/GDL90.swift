//
//  GDL90.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Pure decoding of the GDL90 datalink format broadcast by ForeFlight Sentry and
//  compatible ADS-B receivers.
//
//  Two properties of the wire format that a naive "split on 0x7E" parser gets wrong,
//  and which this decoder implements:
//
//   1. BYTE STUFFING. The flag byte 0x7E and the escape byte 0x7D may not appear
//      inside a message. A transmitter replaces either with 0x7D followed by the
//      original byte XOR 0x20. A 30-byte traffic report carries random-looking
//      position and callsign bytes, so roughly one report in five contains at
//      least one escape. Parsing the stuffed bytes directly yields corrupted
//      latitude/longitude/altitude, which shows up as targets that jump.
//
//   2. FRAME CRC. Every frame ends with a CRC-16-CCITT over the message bytes,
//      transmitted least-significant byte first. UDP delivers corrupt datagrams
//      intact-looking; without the CRC there is no way to reject them.
//
//  This file has no UIKit/ARKit dependencies so it can be unit-tested directly.
//

import Foundation

enum GDL90 {

    // MARK: - Message IDs

    enum MessageID: UInt8 {
        case heartbeat               = 0x00
        case ownshipReport           = 0x0A
        case ownshipGeometricAltitude = 0x0B
        case trafficReport           = 0x14
    }

    // MARK: - CRC-16-CCITT

    /// Lookup table per the GDL90 specification (polynomial 0x1021, MSB-first, seed 0).
    private static let crcTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt16(i) << 8
            for _ in 0..<8 {
                let highBitSet = (crc & 0x8000) != 0
                crc = (crc << 1) ^ (highBitSet ? 0x1021 : 0)
            }
            table[i] = crc
        }
        return table
    }()

    /// CRC of a message body (excluding flags and the trailing CRC itself).
    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc = crcTable[Int(crc >> 8)] ^ (crc << 8) ^ UInt16(byte)
        }
        return crc
    }

    static func crc(_ bytes: [UInt8]) -> UInt16 {
        crc(bytes[bytes.startIndex..<bytes.endIndex])
    }

    /// Encode a message body into a complete on-the-wire frame (flags, stuffing, CRC).
    /// Used by the unit tests to build round-trip fixtures; not needed at runtime.
    static func encodeFrame(_ message: [UInt8]) -> [UInt8] {
        let sum = crc(message)
        var body = message
        body.append(UInt8(sum & 0x00FF))
        body.append(UInt8((sum >> 8) & 0x00FF))

        var out: [UInt8] = [0x7E]
        for byte in body {
            if byte == 0x7E || byte == 0x7D {
                out.append(0x7D)
                out.append(byte ^ 0x20)
            } else {
                out.append(byte)
            }
        }
        out.append(0x7E)
        return out
    }

    // MARK: - Framing

    struct Extraction {
        var messages: [[UInt8]] = []
        /// Frames that were well-formed but whose CRC did not match — corrupted in transit.
        var crcFailures: Int = 0
        /// Frames too short to contain a message plus CRC, or absurdly long (framing desync).
        var malformed: Int = 0
    }

    /// Longest plausible GDL90 message. Anything beyond this means we have lost framing
    /// (e.g. a dropped flag byte merged two frames), so the accumulated bytes are discarded.
    private static let maxFrameLength = 1024

    /// Extract every complete, CRC-valid message from a raw datagram.
    ///
    /// A single 0x7E serves as both the closing flag of one frame and the opening flag of
    /// the next, so consecutive frames share delimiters. Bytes before the first flag, and a
    /// trailing frame with no closing flag, are discarded: they cannot be CRC-verified.
    static func extractMessages(from data: Data) -> Extraction {
        var result = Extraction()
        var current: [UInt8] = []
        current.reserveCapacity(64)
        var inFrame = false
        var escaped = false

        for byte in data {
            if byte == 0x7E {
                if inFrame && !current.isEmpty {
                    switch validate(current) {
                    case .valid(let message): result.messages.append(message)
                    case .badCRC:             result.crcFailures += 1
                    case .tooShort:           result.malformed += 1
                    }
                }
                current.removeAll(keepingCapacity: true)
                inFrame = true
                escaped = false
                continue
            }

            guard inFrame else { continue }

            if escaped {
                current.append(byte ^ 0x20)
                escaped = false
            } else if byte == 0x7D {
                escaped = true
            } else {
                current.append(byte)
            }

            if current.count > maxFrameLength {
                result.malformed += 1
                current.removeAll(keepingCapacity: true)
                inFrame = false
                escaped = false
            }
        }
        return result
    }

    private enum Validation {
        case valid([UInt8])
        case badCRC
        case tooShort
    }

    private static func validate(_ frame: [UInt8]) -> Validation {
        // Smallest legal frame is a 1-byte message plus a 2-byte CRC.
        guard frame.count >= 3 else { return .tooShort }
        let bodyEnd = frame.count - 2
        let transmitted = UInt16(frame[bodyEnd]) | (UInt16(frame[bodyEnd + 1]) << 8)
        guard crc(frame[0..<bodyEnd]) == transmitted else { return .badCRC }
        return .valid(Array(frame[0..<bodyEnd]))
    }

    // MARK: - Traffic / Ownship report (message 0x14 / 0x0A)

    /// How the `track` field of a traffic report should be interpreted. Reported in the
    /// Misc nibble; a value of `.invalid` means the aircraft supplied no usable direction,
    /// in which case dead reckoning must not extrapolate along it.
    enum TrackType: Int {
        case invalid         = 0
        case trueTrack       = 1
        case magneticHeading = 2
        case trueHeading     = 3
    }

    struct TrafficReport {
        var icaoAddress: String
        var callsign: String
        var latitude: Double
        var longitude: Double
        /// Pressure altitude in feet (29.92 inHg reference). `nil` when the report carried
        /// the 0xFFF "altitude unavailable" code — which must NOT be treated as 0 ft.
        var pressureAltitudeFt: Double?
        /// Ground speed in knots; `nil` when the 0xFFF "unavailable" code was reported.
        var groundSpeedKt: Double?
        /// Vertical rate in feet per minute; `nil` when the 0x800 "unavailable" code was reported.
        var verticalRateFpm: Double?
        /// Direction in degrees; `nil` when `trackType` is `.invalid`.
        var track: Double?
        var trackType: TrackType
        var isAirborne: Bool
        /// True when the transmitter says this report is extrapolated rather than a fresh fix.
        var isExtrapolated: Bool
        var emitterCategory: UInt8
    }

    /// Byte layout (1-based, per the GDL90 spec) mapped to 0-based indices:
    ///   1 message ID · 2 alert/address type · 3-5 address · 6-8 latitude · 9-11 longitude
    ///   12-13 altitude(12b)+misc(4b) · 14 NIC/NACp · 15-17 horiz vel(12b)+vert vel(12b)
    ///   18 track · 19 emitter category · 20-27 callsign · 28 emergency code
    static func parseTrafficReport(_ message: [UInt8]) -> TrafficReport? {
        guard message.count >= 28 else { return nil }

        let icao = String(format: "%02X%02X%02X", message[2], message[3], message[4])

        let latitude  = semicircles(message[5],  message[6],  message[7])
        let longitude = semicircles(message[8],  message[9],  message[10])

        let altitudeCode = (UInt16(message[11]) << 4) | (UInt16(message[12]) >> 4)
        let pressureAltitudeFt: Double? =
            altitudeCode == 0xFFF ? nil : Double(altitudeCode) * 25.0 - 1000.0

        let misc = message[12] & 0x0F
        let trackType      = TrackType(rawValue: Int(misc & 0x03)) ?? .invalid
        let isExtrapolated = (misc & 0x04) != 0
        let isAirborne     = (misc & 0x08) != 0

        let speedCode = (UInt16(message[14]) << 4) | (UInt16(message[15]) >> 4)
        let groundSpeedKt: Double? = speedCode == 0xFFF ? nil : Double(speedCode)

        let vertCode = (UInt16(message[15] & 0x0F) << 8) | UInt16(message[16])
        let verticalRateFpm: Double?
        if vertCode == 0x800 {
            verticalRateFpm = nil                       // "unavailable", not −131072 fpm
        } else {
            let signed = vertCode > 0x7FF ? Int(vertCode) - 0x1000 : Int(vertCode)
            verticalRateFpm = Double(signed) * 64.0
        }

        let track: Double? = trackType == .invalid
            ? nil
            : Double(message[17]) * (360.0 / 256.0)

        var callsign = icao
        let rawCallsign = String(bytes: message[19...26], encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if let rawCallsign, !rawCallsign.isEmpty { callsign = rawCallsign }

        return TrafficReport(
            icaoAddress: icao,
            callsign: callsign,
            latitude: latitude,
            longitude: longitude,
            pressureAltitudeFt: pressureAltitudeFt,
            groundSpeedKt: groundSpeedKt,
            verticalRateFpm: verticalRateFpm,
            track: track,
            trackType: trackType,
            isAirborne: isAirborne,
            isExtrapolated: isExtrapolated,
            emitterCategory: message[18]
        )
    }

    /// 24-bit signed semicircle position value → degrees.
    private static func semicircles(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Double {
        var raw = Int32(b0) << 16 | Int32(b1) << 8 | Int32(b2)
        if raw & 0x800000 != 0 { raw |= Int32(bitPattern: 0xFF000000) }
        return Double(raw) * (180.0 / 8_388_608.0)
    }

    // MARK: - Ownship geometric altitude (message 0x0B)

    /// The receiver's own GNSS altitude, referenced to the WGS-84 ellipsoid (HAE) — a
    /// different vertical datum from the pressure altitude in the 0x0A ownship report.
    /// This is the message that makes correct vertical placement possible in a pressurized
    /// cabin, where the receiver's internal barometer measures cabin pressure rather than
    /// outside static pressure.
    struct OwnshipGeometricAltitude {
        var heightAboveEllipsoidFt: Double
        /// Vertical accuracy estimate in metres; `nil` when the receiver reports it unavailable.
        var verticalFigureOfMeritM: Double?
        var verticalWarning: Bool
    }

    /// Byte layout: 1 message ID · 2-3 geometric altitude (signed, 5 ft units)
    ///              4-5 vertical metrics (bit 15 warning, bits 14-0 VFOM in metres)
    static func parseOwnshipGeometricAltitude(_ message: [UInt8]) -> OwnshipGeometricAltitude? {
        guard message.count >= 5 else { return nil }

        let rawAltitude = Int16(bitPattern: (UInt16(message[1]) << 8) | UInt16(message[2]))
        let metrics     = (UInt16(message[3]) << 8) | UInt16(message[4])
        let vfomRaw     = metrics & 0x7FFF

        return OwnshipGeometricAltitude(
            heightAboveEllipsoidFt: Double(rawAltitude) * 5.0,
            verticalFigureOfMeritM: vfomRaw == 0x7FFF ? nil : Double(vfomRaw),
            verticalWarning: (metrics & 0x8000) != 0
        )
    }
}
