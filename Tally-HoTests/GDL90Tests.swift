//
//  GDL90Tests.swift
//  Tally-HoTests
//
//  Covers the two wire-format properties a naive parser gets wrong — byte stuffing and the
//  frame CRC — plus the "value not available" sentinels that used to decode as real numbers.
//

import Testing
import Foundation
@testable import Tally_Ho

struct GDL90Tests {

    // MARK: - Helpers

    /// A syntactically valid 28-byte traffic report with controllable fields.
    private func makeTrafficMessage(
        messageID: UInt8 = 0x14,
        latitudeRaw: Int32 = 0x0B_5B_5B,
        longitudeRaw: Int32 = 0x11_22_33,
        altitudeCode: UInt16 = 0x0C8,     // (200 * 25) - 1000 = 4000 ft
        misc: UInt8 = 0x9,                // airborne + true track
        speedCode: UInt16 = 0x0FA,        // 250 kt
        verticalCode: UInt16 = 0x001,     // +64 fpm
        track: UInt8 = 0x40,              // 90 degrees
        callsign: String = "TEST123"
    ) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: 28)
        message[0] = messageID
        message[1] = 0x00

        message[2] = 0xAB; message[3] = 0xCD; message[4] = 0xEF

        message[5] = UInt8((latitudeRaw >> 16) & 0xFF)
        message[6] = UInt8((latitudeRaw >> 8) & 0xFF)
        message[7] = UInt8(latitudeRaw & 0xFF)

        message[8]  = UInt8((longitudeRaw >> 16) & 0xFF)
        message[9]  = UInt8((longitudeRaw >> 8) & 0xFF)
        message[10] = UInt8(longitudeRaw & 0xFF)

        message[11] = UInt8((altitudeCode >> 4) & 0xFF)
        message[12] = UInt8(((altitudeCode & 0x0F) << 4)) | (misc & 0x0F)

        message[13] = 0xAA   // NIC | NACp

        message[14] = UInt8((speedCode >> 4) & 0xFF)
        message[15] = UInt8(((speedCode & 0x0F) << 4)) | UInt8((verticalCode >> 8) & 0x0F)
        message[16] = UInt8(verticalCode & 0xFF)

        message[17] = track
        message[18] = 0x01   // emitter category

        let padded = callsign.padding(toLength: 8, withPad: " ", startingAt: 0)
        for (offset, character) in Array(padded.utf8).enumerated() {
            message[19 + offset] = character
        }
        message[27] = 0x00
        return message
    }

    // MARK: - CRC

    @Test func crcOfEmptyInputIsSeed() {
        #expect(GDL90.crc([UInt8]()) == 0)
    }

    @Test func crcIsOrderSensitive() {
        #expect(GDL90.crc([0x01, 0x02]) != GDL90.crc([0x02, 0x01]))
    }

    @Test func encodedFrameRoundTrips() {
        let message = makeTrafficMessage()
        let frame = GDL90.encodeFrame(message)
        let result = GDL90.extractMessages(from: Data(frame))

        #expect(result.messages.count == 1)
        #expect(result.crcFailures == 0)
        #expect(result.messages.first == message)
    }

    @Test func corruptedPayloadIsRejectedByCRC() {
        var frame = GDL90.encodeFrame(makeTrafficMessage())
        // Flip a bit in the middle of the payload, leaving framing intact.
        frame[6] ^= 0x01
        let result = GDL90.extractMessages(from: Data(frame))

        #expect(result.messages.isEmpty)
        #expect(result.crcFailures == 1)
    }

    // MARK: - Byte stuffing

    @Test func escapedFlagBytesAreRestored() {
        // Force 0x7E and 0x7D into the latitude field, which is exactly the case that used to
        // decode as a corrupted position.
        let message = makeTrafficMessage(latitudeRaw: 0x7E_7D_7E)
        let frame = GDL90.encodeFrame(message)

        // The encoder must have escaped them, so the raw bytes are longer than the payload.
        #expect(frame.count > message.count + 4)

        let result = GDL90.extractMessages(from: Data(frame))
        #expect(result.messages.first == message)
        #expect(result.messages.first.flatMap { GDL90.parseTrafficReport($0) } != nil)
    }

    @Test func stuffedPayloadDecodesToTheSamePositionAsUnstuffed() {
        let message = makeTrafficMessage(latitudeRaw: 0x7E_7D_7E)
        let direct = GDL90.parseTrafficReport(message)
        let viaWire = GDL90.extractMessages(from: Data(GDL90.encodeFrame(message)))
            .messages.first
            .flatMap { GDL90.parseTrafficReport($0) }

        #expect(direct?.latitude == viaWire?.latitude)
        #expect(direct?.longitude == viaWire?.longitude)
    }

    // MARK: - Framing

    @Test func multipleFramesInOneDatagramAreAllExtracted() {
        let first  = makeTrafficMessage(callsign: "AAA1")
        let second = makeTrafficMessage(callsign: "BBB2")
        var datagram = GDL90.encodeFrame(first)
        datagram.append(contentsOf: GDL90.encodeFrame(second))

        let result = GDL90.extractMessages(from: Data(datagram))
        #expect(result.messages.count == 2)
    }

    @Test func sharedFlagBetweenAdjacentFramesIsHandled() {
        // Some transmitters emit a single 0x7E as both closing and opening flag.
        let first  = GDL90.encodeFrame(makeTrafficMessage(callsign: "AAA1"))
        let second = GDL90.encodeFrame(makeTrafficMessage(callsign: "BBB2"))
        var datagram = first
        datagram.append(contentsOf: second.dropFirst())   // drop the second frame's leading flag

        let result = GDL90.extractMessages(from: Data(datagram))
        #expect(result.messages.count == 2)
    }

    @Test func truncatedTrailingFrameIsDiscarded() {
        var datagram = GDL90.encodeFrame(makeTrafficMessage())
        datagram.removeLast()   // no closing flag
        let result = GDL90.extractMessages(from: Data(datagram))
        #expect(result.messages.isEmpty)
    }

    @Test func garbageBeforeFirstFlagIsIgnored() {
        var datagram: [UInt8] = [0x11, 0x22, 0x33]
        datagram.append(contentsOf: GDL90.encodeFrame(makeTrafficMessage()))
        let result = GDL90.extractMessages(from: Data(datagram))
        #expect(result.messages.count == 1)
    }

    // MARK: - Field decoding

    @Test func nominalFieldsDecodeCorrectly() {
        let message = makeTrafficMessage()
        let report = GDL90.parseTrafficReport(message)

        #expect(report?.icaoAddress == "ABCDEF")
        #expect(report?.callsign == "TEST123")
        #expect(report?.pressureAltitudeFt == 4000)
        #expect(report?.groundSpeedKt == 250)
        #expect(report?.verticalRateFpm == 64)
        #expect(report?.isAirborne == true)
        #expect(report?.trackType == .trueTrack)
        if let track = report?.track {
            #expect(abs(track - 90.0) < 0.001)
        }
    }

    @Test func invalidAltitudeCodeIsReportedAsMissingRatherThanZero() {
        let report = GDL90.parseTrafficReport(makeTrafficMessage(altitudeCode: 0xFFF))
        #expect(report?.pressureAltitudeFt == nil)
    }

    @Test func invalidSpeedCodeIsReportedAsMissing() {
        let report = GDL90.parseTrafficReport(makeTrafficMessage(speedCode: 0xFFF))
        #expect(report?.groundSpeedKt == nil)
    }

    /// 0x800 is the "vertical rate unavailable" code. Sign-extending it as data yields
    /// -2048 * 64 = -131,072 fpm, which would coast a target into the ground.
    @Test func unavailableVerticalRateIsNotDecodedAsExtremeDescent() {
        let report = GDL90.parseTrafficReport(makeTrafficMessage(verticalCode: 0x800))
        #expect(report?.verticalRateFpm == nil)
    }

    @Test func negativeVerticalRateSignExtends() {
        // 0xFFF is -1 in 12-bit two's complement → -64 fpm.
        let report = GDL90.parseTrafficReport(makeTrafficMessage(verticalCode: 0xFFF))
        #expect(report?.verticalRateFpm == -64)
    }

    @Test func invalidTrackTypeYieldsNoTrack() {
        // Misc bits 1-0 == 00 means the track field carries nothing usable.
        let report = GDL90.parseTrafficReport(makeTrafficMessage(misc: 0x8))
        #expect(report?.trackType == .invalid)
        #expect(report?.track == nil)
    }

    @Test func onGroundIsReadFromMiscBit() {
        let airborne = GDL90.parseTrafficReport(makeTrafficMessage(misc: 0x9))
        let onGround = GDL90.parseTrafficReport(makeTrafficMessage(misc: 0x1))
        #expect(airborne?.isAirborne == true)
        #expect(onGround?.isAirborne == false)
    }

    @Test func negativeLatitudeSignExtends() {
        // Bit 23 set means a negative semicircle value. 0xC00000 sign-extends to -4,194,304,
        // which at 180/2^23 degrees per count is exactly -90 degrees.
        let report = GDL90.parseTrafficReport(makeTrafficMessage(latitudeRaw: 0xC00000))
        #expect(report?.latitude == -90.0)
    }

    @Test func shortMessageIsRejected() {
        #expect(GDL90.parseTrafficReport([UInt8](repeating: 0, count: 27)) == nil)
    }

    // MARK: - Ownship geometric altitude

    @Test func geometricAltitudeDecodesInFiveFootUnits() {
        // 700 * 5 = 3500 ft, VFOM 12 m, no warning.
        let message: [UInt8] = [0x0B, 0x02, 0xBC, 0x00, 0x0C]
        let decoded = GDL90.parseOwnshipGeometricAltitude(message)
        #expect(decoded?.heightAboveEllipsoidFt == 3500)
        #expect(decoded?.verticalFigureOfMeritM == 12)
        #expect(decoded?.verticalWarning == false)
    }

    @Test func geometricAltitudeSignExtendsBelowSeaLevel() {
        // 0xFFFF = -1 → -5 ft.
        let message: [UInt8] = [0x0B, 0xFF, 0xFF, 0x00, 0x0C]
        #expect(GDL90.parseOwnshipGeometricAltitude(message)?.heightAboveEllipsoidFt == -5)
    }

    @Test func unavailableVerticalFigureOfMeritIsMissing() {
        let message: [UInt8] = [0x0B, 0x02, 0xBC, 0x7F, 0xFF]
        #expect(GDL90.parseOwnshipGeometricAltitude(message)?.verticalFigureOfMeritM == nil)
    }

    @Test func verticalWarningFlagIsDecoded() {
        let message: [UInt8] = [0x0B, 0x02, 0xBC, 0x80, 0x0C]
        #expect(GDL90.parseOwnshipGeometricAltitude(message)?.verticalWarning == true)
    }
}
