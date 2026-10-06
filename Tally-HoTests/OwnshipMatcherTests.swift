//
//  OwnshipMatcherTests.swift
//  Tally-HoTests
//
//  Identifying the user's own aircraft (#13): the GDL90 ownship address captured from 0x0A and
//  its 0x14 echo filtered; on internet traffic, the automatic match against the ownship estimate
//  (single candidate, ambiguous then resolved, hysteresis once selected); and the precedence that
//  lets a manual pick override everything.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

struct OwnshipMatcherTests {

    // MARK: - Helpers

    private let origin = CLLocationCoordinate2D(latitude: 40.0, longitude: -100.0)

    private func offset(northNM: Double, eastNM: Double) -> CLLocationCoordinate2D {
        let latRad = origin.latitude * .pi / 180
        let radius = CalculationsLogic.earthRadius(at: latRad)
        let north = northNM * CalculationsLogic.nauticalMileToMeters
        let east = eastNM * CalculationsLogic.nauticalMileToMeters
        return CLLocationCoordinate2D(
            latitude: origin.latitude + north / radius * 180 / .pi,
            longitude: origin.longitude + east / (radius * cos(latRad)) * 180 / .pi)
    }

    /// Eastbound at FL350-ish, 450 kt.
    private func own(groundSpeed: Double = 450, track: Double = 90,
                     altitude: Double = 35_000) -> OwnshipMatcher.OwnState {
        OwnshipMatcher.OwnState(coordinate: origin, altitudeFt: altitude, groundSpeedKt: groundSpeed,
                                trackDeg: track, hasVelocity: true)
    }

    private func candidate(
        _ id: String, northNM: Double = 0, eastNM: Double = 0,
        altitude: Double = 35_000, groundSpeed: Double = 450, track: Double = 90,
        report: TimeInterval = 0
    ) -> OwnshipMatcher.Candidate {
        OwnshipMatcher.Candidate(id: id, coordinate: offset(northNM: northNM, eastNM: eastNM),
                                 altitudeFt: altitude, groundSpeedKt: groundSpeed, trackDeg: track,
                                 reportTime: report)
    }

    /// Run updates once a second from `from` to `to` inclusive, a fresh report every second, and
    /// return the first event.
    private func run(_ matcher: inout OwnshipMatcher, from: Int, to: Int,
                     candidates: (TimeInterval) -> [OwnshipMatcher.Candidate]) -> (event: OwnshipMatcher.Event, at: Int)? {
        for second in from...to {
            let now = TimeInterval(second)
            if let event = matcher.update(own: own(), candidates: candidates(now), at: now) {
                return (event, second)
            }
        }
        return nil
    }

    // MARK: - Single candidate

    @Test func oneClearCandidateIsSelectedAfterTheDwell() {
        var matcher = OwnshipMatcher()
        // 0.2 NM behind along track: the feed's latency, at 450 kt.
        let ownCopy = { (report: TimeInterval) in
            [self.candidate("OWN", eastNM: -0.2, altitude: 35_120, groundSpeed: 447, track: 91,
                            report: report)]
        }

        #expect(matcher.update(own: own(), candidates: ownCopy(0), at: 0) == nil)
        // Excluded from TCAS from the first tick, before it is confirmed.
        #expect(matcher.provisionalID == "OWN")
        #expect(matcher.selectedID == nil)
        // Two reports, but not yet three seconds.
        #expect(matcher.update(own: own(), candidates: ownCopy(2), at: 2.9) == nil)

        let event = matcher.update(own: own(), candidates: ownCopy(2), at: 3.0)
        guard case .selected(let match, let count)? = event else {
            Issue.record("expected a selection at 3 s")
            return
        }
        #expect(match.id == "OWN")
        #expect(count == 1)
        #expect(match.quality < 0.5)
        #expect(matcher.selectedID == "OWN")
        #expect(matcher.provisionalID == nil)
    }

    @Test func oneReportIsNotEnoughHoweverLongItLasts() {
        var matcher = OwnshipMatcher()
        let single = [candidate("OWN", eastNM: -0.1, report: 0)]
        for second in 0...10 {
            #expect(matcher.update(own: own(), candidates: single, at: TimeInterval(second)) == nil)
        }
        #expect(matcher.selectedID == nil)
        // A second report confirms it.
        let event = matcher.update(own: own(), candidates: [candidate("OWN", eastNM: -0.1, report: 8)], at: 11)
        #expect(event != nil)
        #expect(matcher.selectedID == "OWN")
    }

    // MARK: - Ambiguous, then resolved

    @Test func twoCandidatesWaitForOneToWinForFiveSeconds() {
        var matcher = OwnshipMatcher()
        // Both inside the acquisition tolerance (0.525 NM at 450 kt); A is the better match.
        let pair = { (report: TimeInterval) in
            [self.candidate("A", eastNM: -0.05, report: report),
             self.candidate("B", northNM: 0.3, report: report)]
        }
        guard let result = run(&matcher, from: 0, to: 10, candidates: pair) else {
            Issue.record("expected a selection")
            return
        }
        // Not at 3 s, where one candidate would have been taken: ambiguity needs 5.
        #expect(result.at == 5)
        guard case .selected(let match, let count) = result.event else {
            Issue.record("expected a selection event")
            return
        }
        #expect(match.id == "A")
        #expect(count == 2)
    }

    @Test func aChangeOfLeaderRestartsTheWait() {
        var matcher = OwnshipMatcher()
        // A leads for two seconds, then B becomes the better match and holds it.
        let shifting = { (now: TimeInterval) -> [OwnshipMatcher.Candidate] in
            if now < 2 {
                return [self.candidate("A", eastNM: -0.05, report: now),
                        self.candidate("B", northNM: 0.3, report: now)]
            }
            return [self.candidate("A", northNM: 0.4, report: now),
                    self.candidate("B", eastNM: -0.05, report: now)]
        }
        guard let result = run(&matcher, from: 0, to: 12, candidates: shifting) else {
            Issue.record("expected a selection")
            return
        }
        // Five seconds from B taking the lead at 2 s.
        #expect(result.at == 7)
        #expect(matcher.selectedID == "B")
    }

    @Test func ambiguityThatResolvesStillWaitsTheFullFiveSeconds() {
        var matcher = OwnshipMatcher()
        // B drops out after one second; A was ambiguous at the start of its streak.
        let resolving = { (now: TimeInterval) -> [OwnshipMatcher.Candidate] in
            var list = [self.candidate("A", eastNM: -0.05, report: now)]
            if now < 1 { list.append(self.candidate("B", northNM: 0.3, report: now)) }
            return list
        }
        let result = run(&matcher, from: 0, to: 10, candidates: resolving)
        #expect(result?.at == 5)
        #expect(matcher.selectedID == "A")
    }

    // MARK: - Hysteresis once selected

    /// A matcher that selected `id` at 3 s (one candidate, a fresh report every second).
    private func selected(_ id: String = "OWN") -> OwnshipMatcher {
        var matcher = OwnshipMatcher()
        let result = run(&matcher, from: 0, to: 5) { [self.candidate(id, eastNM: -0.1, report: $0)] }
        #expect(result?.at == 3)
        return matcher
    }

    @Test func aLooserMatchIsKeptOnceSelected() {
        var matcher = selected()
        #expect(matcher.selectedID == "OWN")
        // 0.8 NM and 30 deg off: would never be acquired (0.525 NM, 20 deg), but within retention
        // (1.05 NM, 45 deg) — what a turn does to the feed's last reported track.
        for second in 6...40 {
            let drifted = [candidate("OWN", eastNM: -0.8, track: 120, report: TimeInterval(second))]
            #expect(matcher.update(own: own(), candidates: drifted, at: TimeInterval(second)) == nil)
        }
        #expect(matcher.selectedID == "OWN")
    }

    @Test func aClearlyBrokenMatchIsReleasedAfterTenSeconds() {
        var matcher = selected()
        let gone = { (now: TimeInterval) in [self.candidate("OWN", eastNM: -3.0, report: now)] }
        #expect(matcher.update(own: own(), candidates: gone(10), at: 10) == nil)
        #expect(matcher.update(own: own(), candidates: gone(19), at: 19.9) == nil)
        #expect(matcher.selectedID == "OWN")
        let event = matcher.update(own: own(), candidates: gone(20), at: 20)
        #expect(event == .released(id: "OWN", reason: "mismatch"))
        #expect(matcher.selectedID == nil)
    }

    @Test func aBriefMismatchDoesNotRelease() {
        var matcher = selected()
        let broken = [candidate("OWN", eastNM: -3.0, report: 10)]
        let good = [candidate("OWN", eastNM: -0.1, report: 18)]
        _ = matcher.update(own: own(), candidates: broken, at: 10)
        _ = matcher.update(own: own(), candidates: good, at: 18)
        // The failure clock restarted at 18 s, so 25 s is only 3 s into a new run.
        _ = matcher.update(own: own(), candidates: broken, at: 22)
        #expect(matcher.update(own: own(), candidates: broken, at: 25) == nil)
        #expect(matcher.selectedID == "OWN")
    }

    @Test func aBetterCandidateNeverStealsAHeldSelection() {
        var matcher = selected("OWN")
        for second in 6...30 {
            let now = TimeInterval(second)
            let both = [candidate("OWN", eastNM: -0.4, report: now),
                        candidate("OTHER", eastNM: 0, report: now)]
            #expect(matcher.update(own: own(), candidates: both, at: now) == nil)
        }
        #expect(matcher.selectedID == "OWN")
    }

    @Test func anAbsentSelectionIsKeptForThirtySeconds() {
        var matcher = selected()
        // Selected, and so last seen, at 3 s.
        #expect(matcher.update(own: own(), candidates: [], at: 32.9) == nil)
        #expect(matcher.selectedID == "OWN")
        #expect(matcher.update(own: own(), candidates: [], at: 33) == .released(id: "OWN", reason: "absent"))
    }

    @Test func suspendingAcquisitionKeepsAConfirmedMatch() {
        var matcher = selected()
        matcher.suspendAcquisition()
        #expect(matcher.selectedID == "OWN")

        var fresh = OwnshipMatcher()
        _ = fresh.update(own: own(), candidates: [candidate("OWN", report: 0)], at: 0)
        #expect(fresh.provisionalID == "OWN")
        fresh.suspendAcquisition()
        #expect(fresh.provisionalID == nil)
    }

    // MARK: - Tolerances

    @Test func candidatesOutsideAnyToleranceAreNotCandidates() {
        let o = own()
        let t = OwnshipMatcher.Tolerances.acquire
        #expect(OwnshipMatcher.match(candidate("X", eastNM: -0.1), own: o, tolerances: t) != nil)
        // An adjacent RVSM level, co-located.
        #expect(OwnshipMatcher.match(candidate("X", altitude: 36_000), own: o, tolerances: t) == nil)
        // Opposite direction on the same airway.
        #expect(OwnshipMatcher.match(candidate("X", track: 270), own: o, tolerances: t) == nil)
        // Same track, much slower.
        #expect(OwnshipMatcher.match(candidate("X", groundSpeed: 380), own: o, tolerances: t) == nil)
        // A mile away.
        #expect(OwnshipMatcher.match(candidate("X", northNM: 1.0), own: o, tolerances: t) == nil)
    }

    @Test func trackToleranceWrapsThroughNorth() {
        let o = own(track: 355)
        let t = OwnshipMatcher.Tolerances.acquire
        #expect(OwnshipMatcher.match(candidate("X", track: 5), own: o, tolerances: t) != nil)
        #expect(OwnshipMatcher.match(candidate("X", track: 30), own: o, tolerances: t) == nil)
    }

    @Test func horizontalToleranceGrowsWithSpeed() {
        let t = OwnshipMatcher.Tolerances.acquire
        // 0.15 NM + 3 s of travel: 0.25 NM at 120 kt, 0.55 NM at 480 kt.
        #expect(abs(t.horizontalNM(atGroundSpeedKt: 120) - 0.25) < 1e-9)
        #expect(abs(t.horizontalNM(atGroundSpeedKt: 480) - 0.55) < 1e-9)
        let slow = candidate("X", eastNM: -0.4, groundSpeed: 120)
        let fast = candidate("X", eastNM: -0.4, groundSpeed: 480)
        #expect(OwnshipMatcher.match(slow, own: own(groundSpeed: 120), tolerances: t) == nil)
        #expect(OwnshipMatcher.match(fast, own: own(groundSpeed: 480), tolerances: t) != nil)
    }

    @Test func nothingIsAcquiredBelowMinimumSpeed() {
        var matcher = OwnshipMatcher()
        let slowOwn = own(groundSpeed: 20)
        for second in 0...10 {
            let c = [candidate("X", groundSpeed: 20, report: TimeInterval(second))]
            #expect(matcher.update(own: slowOwn, candidates: c, at: TimeInterval(second)) == nil)
        }
        #expect(matcher.selectedID == nil)
        #expect(matcher.provisionalID == nil)
    }

    @Test func groundAndAltitudelessAircraftAreNeverCandidates() {
        let base = Aircraft(id: "AAA111", callsign: "TEST", latitude: origin.latitude,
                            longitude: origin.longitude, altitude: 35_000, track: 90,
                            groundSpeed: 450, verticalRate: 0, lastUpdate: Date(), source: .internet)
        #expect(OwnshipMatcher.candidate(from: base, ownAltitudeFt: 35_000, geoidSeparationFt: nil,
                                         datumFit: nil)?.id == "AAA111")
        var onGround = base
        onGround.isOnGround = true
        #expect(OwnshipMatcher.candidate(from: onGround, ownAltitudeFt: 35_000, geoidSeparationFt: nil,
                                         datumFit: nil) == nil)
        var noAltitude = base
        noAltitude.hasValidAltitude = false
        #expect(OwnshipMatcher.candidate(from: noAltitude, ownAltitudeFt: 35_000, geoidSeparationFt: nil,
                                         datumFit: nil) == nil)
    }

    // MARK: - Precedence and the manual pick

    @Test func aManualPickOverridesTheAutomaticOne() {
        #expect(OwnshipSelection.resolve(manualID: "MAN", adsbID: nil, autoID: "AUTO")
                == OwnshipSelection(id: "MAN", source: .manual))
        #expect(OwnshipSelection.resolve(manualID: "MAN", adsbID: "RX", autoID: "AUTO")
                == OwnshipSelection(id: "MAN", source: .manual))
        #expect(OwnshipSelection.resolve(manualID: nil, adsbID: "RX", autoID: "AUTO")
                == OwnshipSelection(id: "RX", source: .adsb))
        #expect(OwnshipSelection.resolve(manualID: nil, adsbID: nil, autoID: "AUTO")
                == OwnshipSelection(id: "AUTO", source: .auto))
        #expect(OwnshipSelection.resolve(manualID: nil, adsbID: nil, autoID: nil) == nil)
    }

    @Test func aManualCallsignResolvesToTheNearestAircraftCarryingIt() {
        func aircraft(_ id: String, _ callsign: String, northNM: Double) -> Aircraft {
            let position = offset(northNM: northNM, eastNM: 0)
            return Aircraft(id: id, callsign: callsign, latitude: position.latitude,
                            longitude: position.longitude, altitude: 35_000, track: 90,
                            groundSpeed: 450, verticalRate: 0, lastUpdate: Date(), source: .internet)
        }
        // Callsigns are not unique: the same flight number on two airframes, one far away.
        let traffic = [aircraft("FAR001", "UAL123", northNM: 40),
                       aircraft("NEAR01", "UAL123", northNM: 0.2),
                       aircraft("OTHER1", "DAL456", northNM: 0.1)]
        #expect(OwnshipSelection.nearestID(withCallsign: "UAL123", in: traffic, near: origin) == "NEAR01")
        #expect(OwnshipSelection.nearestID(withCallsign: "SWA789", in: traffic, near: origin) == nil)
    }

    // MARK: - GDL90 ownship address

    /// A 28-byte traffic/ownship report with the given ICAO address.
    private func report(messageID: UInt8, icao: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: 28)
        message[0] = messageID
        message[2] = icao.0
        message[3] = icao.1
        message[4] = icao.2
        let altitudeCode: UInt16 = 0x0C8                       // 4,000 ft
        message[11] = UInt8((altitudeCode >> 4) & 0xFF)
        message[12] = UInt8((altitudeCode & 0x0F) << 4) | 0x09  // airborne, true track
        let speedCode: UInt16 = 0x0FA                          // 250 kt, level
        message[14] = UInt8((speedCode >> 4) & 0xFF)
        message[15] = UInt8((speedCode & 0x0F) << 4)
        message[17] = 0x40                                     // 90 degrees
        message[18] = 0x01
        for (index, byte) in Array("TEST1   ".utf8).enumerated() { message[19 + index] = byte }
        return message
    }

    /// Through the wire — framing, stuffing and CRC — exactly as ConnectionLogic receives it.
    private func decoded(_ message: [UInt8]) -> GDL90.TrafficReport? {
        GDL90.extractMessages(from: Data(GDL90.encodeFrame(message))).messages.first
            .flatMap { GDL90.parseTrafficReport($0) }
    }

    @Test func ownshipReportAddressIsCaptured() throws {
        var filter = GDL90.OwnshipFilter()
        let ownship = try #require(decoded(report(messageID: 0x0A, icao: (0xA1, 0xB2, 0xC3))))
        #expect(filter.noteOwnshipReport(ownship) == "A1B2C3")
        #expect(filter.ownshipICAO == "A1B2C3")
        // Published once, not at the receiver's 1 Hz.
        #expect(filter.noteOwnshipReport(ownship) == nil)
    }

    @Test func trafficEchoOfOwnshipIsFiltered() throws {
        var filter = GDL90.OwnshipFilter()
        let echo = try #require(decoded(report(messageID: 0x14, icao: (0xA1, 0xB2, 0xC3))))
        let other = try #require(decoded(report(messageID: 0x14, icao: (0xAB, 0xCD, 0xEF))))
        // Nothing is filtered before the receiver has said who we are.
        #expect(filter.isOwnshipEcho(echo) == false)

        let ownship = try #require(decoded(report(messageID: 0x0A, icao: (0xA1, 0xB2, 0xC3))))
        _ = filter.noteOwnshipReport(ownship)
        #expect(filter.isOwnshipEcho(echo) == true)
        #expect(filter.isOwnshipEcho(other) == false)
    }

    @Test func placeholderOwnshipAddressesAreIgnored() throws {
        var filter = GDL90.OwnshipFilter()
        let zero = try #require(decoded(report(messageID: 0x0A, icao: (0x00, 0x00, 0x00))))
        let ones = try #require(decoded(report(messageID: 0x0A, icao: (0xFF, 0xFF, 0xFF))))
        #expect(filter.noteOwnshipReport(zero) == nil)
        #expect(filter.noteOwnshipReport(ones) == nil)
        #expect(filter.ownshipICAO == nil)
        let traffic = try #require(decoded(report(messageID: 0x14, icao: (0x00, 0x00, 0x00))))
        #expect(filter.isOwnshipEcho(traffic) == false)
    }

    @Test func internetIDsMatchTheOwnshipAddressRegardlessOfCase() {
        #expect(GDL90.OwnshipFilter.matches(id: "a1b2c3", ownshipID: "A1B2C3"))
        #expect(GDL90.OwnshipFilter.matches(id: "A1B2C3", ownshipID: "A1B2C3"))
        #expect(!GDL90.OwnshipFilter.matches(id: "A1B2C4", ownshipID: "A1B2C3"))
        #expect(!GDL90.OwnshipFilter.matches(id: "A1B2C3", ownshipID: nil))
    }
}
