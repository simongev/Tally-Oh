//
//  MagneticFieldIntegrityTests.swift
//  Tally-HoTests
//
//  The compass field check (#21): measuring strength and dip from CoreMotion's field and gravity,
//  the disturbance thresholds, the gate on the ground seed and ground correction, and the
//  calibration screen's compass card.
//

import Testing
import Foundation
@testable import Tally_Ho

struct MagneticFieldIntegrityTests {

    // MARK: - Helpers

    private typealias Integrity = MagneticFieldIntegrity

    /// A model field of strength `ut` and dip `dipDeg`, pointing north.
    private func modelField(ut: Double, dipDeg: Double) -> MagneticFieldModel.Field {
        let rad = dipDeg * .pi / 180
        return MagneticFieldModel.Field(northNT: ut * 1_000 * cos(rad), eastNT: 0,
                                        downNT: ut * 1_000 * sin(rad))
    }

    /// The phone flat, face up and pointing north: gravity is −z, north is +y. A field of strength
    /// `ut` dipping `dipDeg` below the horizontal reads (0, B cos I, −B sin I) in the device frame.
    private func flatPhoneReading(ut: Double, dipDeg: Double, at time: TimeInterval) -> Integrity.Reading {
        let rad = dipDeg * .pi / 180
        return Integrity.reading(fieldUT: SIMD3(0, ut * cos(rad), -ut * sin(rad)),
                                 gravity: SIMD3(0, 0, -1), at: time)!
    }

    /// One second of identical readings at 10 Hz, ending at `end`.
    private func second(ut: Double, dipDeg: Double, endingAt end: TimeInterval = 100) -> [Integrity.Reading] {
        (0..<10).map { i in flatPhoneReading(ut: ut, dipDeg: dipDeg, at: end - 0.9 + Double(i) * 0.1) }
    }

    /// New York, from WMM2025: 50.78 µT dipping 65.56°.
    private let newYork = (ut: 50.78, dip: 65.56)

    private func verdict(ut: Double, dipDeg: Double) -> Integrity.Verdict {
        Integrity.assess(second(ut: ut, dipDeg: dipDeg),
                         expected: modelField(ut: newYork.ut, dipDeg: newYork.dip), at: 100).verdict
    }

    // MARK: - Measuring

    @Test func dipIsMeasuredAgainstGravityWhateverTheAttitude() throws {
        // Flat, face up.
        let flat = try #require(Integrity.reading(fieldUT: SIMD3(0, 20, -45), gravity: SIMD3(0, 0, -1), at: 0))
        #expect(abs(flat.intensityUT - (20.0 * 20 + 45 * 45).squareRoot()) < 1e-9)
        #expect(abs(flat.dipDeg - atan2(45, 20) * 180 / .pi) < 1e-9)
        // Held upright in portrait, top up: gravity is −y in the device frame; the same field,
        // turned with the phone, reads the same dip.
        let upright = try #require(Integrity.reading(fieldUT: SIMD3(0, -45, -20), gravity: SIMD3(0, -1, 0), at: 0))
        #expect(abs(upright.dipDeg - flat.dipDeg) < 1e-9)
        // Gravity's magnitude does not matter, only its direction.
        let scaled = try #require(Integrity.reading(fieldUT: SIMD3(0, 20, -45), gravity: SIMD3(0, 0, -0.98), at: 0))
        #expect(abs(scaled.dipDeg - flat.dipDeg) < 1e-9)
    }

    @Test func degenerateInputsGiveNoReading() {
        #expect(Integrity.reading(fieldUT: SIMD3(0, 0, 0), gravity: SIMD3(0, 0, -1), at: 0) == nil)
        #expect(Integrity.reading(fieldUT: SIMD3(0, 20, -45), gravity: SIMD3(0, 0, 0), at: 0) == nil)
        #expect(Integrity.reading(fieldUT: SIMD3(.nan, 20, -45), gravity: SIMD3(0, 0, -1), at: 0) == nil)
    }

    // MARK: - Thresholds

    @Test func theModelledFieldIsClean() {
        #expect(verdict(ut: newYork.ut, dipDeg: newYork.dip) == .clean)
    }

    @Test func strengthWithinSixPercentIsClean() {
        #expect(verdict(ut: newYork.ut * 1.059, dipDeg: newYork.dip) == .clean)
        #expect(verdict(ut: newYork.ut * 0.941, dipDeg: newYork.dip) == .clean)
    }

    @Test func strengthBeyondSixPercentIsDisturbed() {
        #expect(verdict(ut: newYork.ut * 1.061, dipDeg: newYork.dip) == .disturbed)
        #expect(verdict(ut: newYork.ut * 0.939, dipDeg: newYork.dip) == .disturbed)
        // A car or a railing at arm's length: tens of µT.
        #expect(verdict(ut: newYork.ut + 20, dipDeg: newYork.dip) == .disturbed)
    }

    @Test func dipWithinThreeDegreesIsClean() {
        #expect(verdict(ut: newYork.ut, dipDeg: newYork.dip + 2.9) == .clean)
        #expect(verdict(ut: newYork.ut, dipDeg: newYork.dip - 2.9) == .clean)
    }

    @Test func dipBeyondThreeDegreesIsDisturbed() {
        #expect(verdict(ut: newYork.ut, dipDeg: newYork.dip + 3.1) == .disturbed)
        #expect(verdict(ut: newYork.ut, dipDeg: newYork.dip - 3.1) == .disturbed)
    }

    @Test func thresholdsAreTheSpecifiedOnes() {
        #expect(Integrity.maxIntensityErrorFraction == 0.06)
        #expect(Integrity.maxDipErrorDeg == 3.0)
    }

    @Test func oneWildSampleDoesNotFlipTheVerdict() {
        var window = second(ut: newYork.ut, dipDeg: newYork.dip)
        window[4] = flatPhoneReading(ut: newYork.ut * 2, dipDeg: 20, at: window[4].time)
        let result = Integrity.assess(window, expected: modelField(ut: newYork.ut, dipDeg: newYork.dip), at: 100)
        #expect(result.verdict == .clean)
    }

    @Test func noVerdictWithoutEnoughSamplesAPositionOrFreshData() {
        let expected = modelField(ut: newYork.ut, dipDeg: newYork.dip)
        // Too few samples.
        let few = Array(second(ut: newYork.ut, dipDeg: newYork.dip).suffix(4))
        #expect(Integrity.assess(few, expected: expected, at: 100).verdict == .pending)
        // No position to evaluate the model at.
        #expect(Integrity.assess(second(ut: newYork.ut, dipDeg: newYork.dip), expected: nil, at: 100).verdict == .pending)
        // The window stopped filling two seconds ago.
        #expect(Integrity.assess(second(ut: newYork.ut, dipDeg: newYork.dip), expected: expected, at: 102).verdict == .pending)
    }

    @Test func theAssessmentCarriesWhatItMeasuredAndExpected() throws {
        let result = Integrity.assess(second(ut: 54, dipDeg: 66),
                                      expected: modelField(ut: newYork.ut, dipDeg: newYork.dip), at: 100)
        let measured = try #require(result.measuredUT)
        let dip = try #require(result.dipDeg)
        let expectedUT = try #require(result.expectedUT)
        let expectedDip = try #require(result.expectedDipDeg)
        #expect(abs(measured - 54) < 1e-9)
        #expect(abs(dip - 66) < 1e-9)
        #expect(abs(expectedUT - newYork.ut) < 1e-9)
        #expect(abs(expectedDip - newYork.dip) < 1e-9)
        #expect(result.verdict == .disturbed)   // 54 is 6.3% above 50.78
    }

    // MARK: - Ground seed and correction gate

    @Test func aCleanFieldOpensTheCorrectionAndTheSeedIsClean() {
        var gate = GroundCompassGate()
        gate.update(.clean)
        #expect(gate.correctionMayUseCompass)
        #expect(!gate.seedIsUnclean)
    }

    @Test func aDisturbedOrPendingFieldStopsTheCorrectionAndFlagsTheSeed() {
        for unclean in [Integrity.Verdict.disturbed, .pending] {
            var gate = GroundCompassGate()
            gate.update(unclean)
            #expect(!gate.correctionMayUseCompass)
            #expect(gate.seedIsUnclean)
        }
    }

    @Test func aDeviceThatCannotMeasureKeepsTheOldBehaviour() {
        var gate = GroundCompassGate()
        gate.update(.unavailable)
        #expect(gate.correctionMayUseCompass)
        #expect(!gate.seedIsUnclean)
    }

    @Test func resetStartsPending() {
        var gate = GroundCompassGate()
        gate.update(.clean)
        gate.reset()
        #expect(gate.verdict == .pending)
        #expect(gate.seedIsUnclean)
    }

    /// The seed does not wait for a clean field (#21 follow-up): its compass reference is the heading
    /// whenever the compass is otherwise usable — the field is not even an input — and only the flag
    /// says the field was not clean.
    @Test func theSeedDoesNotWaitForACleanField() {
        for verdict in [Integrity.Verdict.disturbed, .pending, .clean, .unavailable] {
            var gate = GroundCompassGate()
            gate.update(verdict)
            let reference = GroundCompassGate.seedCompassReferenceDeg(
                trueHeadingDeg: 132, headingAccuracyDeg: 11.6, maxHeadingAccuracyDeg: 25)
            #expect(reference == 132)
            #expect(gate.seedIsUnclean == (verdict == .disturbed || verdict == .pending))
        }
        // The compass's own conditions still apply.
        #expect(GroundCompassGate.seedCompassReferenceDeg(trueHeadingDeg: -1, headingAccuracyDeg: 10,
                                                          maxHeadingAccuracyDeg: 25) == nil)
        #expect(GroundCompassGate.seedCompassReferenceDeg(trueHeadingDeg: 132, headingAccuracyDeg: 30,
                                                          maxHeadingAccuracyDeg: 25) == nil)
        #expect(GroundCompassGate.seedCompassReferenceDeg(trueHeadingDeg: 132, headingAccuracyDeg: -1,
                                                          maxHeadingAccuracyDeg: 25) == nil)
    }

    // MARK: - Monitor lifecycle

    @Test func theMonitorRunsOnlyWhileAGroundClientWantsIt() {
        var demand = FieldMonitorDemand()
        demand.setOnGround(true)
        #expect(!demand.shouldRun)
        demand.add("calibration")
        #expect(demand.shouldRun)
        demand.add("ar_ground")
        demand.remove("calibration")
        #expect(demand.shouldRun)            // the AR view still holds it
        demand.remove("ar_ground")
        #expect(!demand.shouldRun)           // the last one let go
    }

    @Test func nothingRunsUntilThePhoneIsPositivelyOnTheGround() {
        var demand = FieldMonitorDemand()
        demand.add("calibration")
        demand.add("ar_ground")
        // A flight launch: held by both, but nobody has said the phone is on the ground.
        #expect(!demand.shouldRun)
    }

    @Test func leavingTheGroundStopsItWhoeverStillHoldsIt() {
        var demand = FieldMonitorDemand()
        demand.add("calibration")             // the card still up over the AR view (#20)
        demand.add("ar_ground")
        demand.setOnGround(true)
        #expect(demand.shouldRun)
        demand.setOnGround(false)
        #expect(!demand.shouldRun)
        // Still held, so landing starts it again: the ground path needs it.
        demand.setOnGround(true)
        #expect(demand.shouldRun)
    }

    @Test func landingDoesNotStartItIfNobodyNeedsIt() {
        var demand = FieldMonitorDemand()
        demand.add("ar_ground")
        demand.setOnGround(false)
        demand.remove("ar_ground")
        demand.setOnGround(true)
        #expect(!demand.shouldRun)
    }

    // MARK: - Positively on the ground (QA #21 round 1)

    private let knots = 1852.0 / 3600.0   // m/s per knot

    @Test func aFixWithNoValidSpeedStartsNothing() {
        // speed = -1: CoreLocation's "invalid" — a cached, Wi-Fi or cell fix.
        #expect(CalibrationFlightPolicy.fieldMonitorStep(speedMps: -1) == .leave)
        #expect(!CalibrationFlightPolicy.fixShowsGround(speedMps: -1))
        #expect(!CalibrationFlightPolicy.fixShowsFlight(speedMps: -1))
        #expect(CalibrationFlightPolicy.fieldMonitorStep(speedMps: .nan) == .leave)
    }

    @Test func aGroundFixStartsItAndAFlightFixStopsIt() {
        #expect(CalibrationFlightPolicy.fieldMonitorStep(speedMps: 0) == .start)
        #expect(CalibrationFlightPolicy.fieldMonitorStep(speedMps: 49.9 * knots) == .start)
        #expect(CalibrationFlightPolicy.fieldMonitorStep(speedMps: 50.1 * knots) == .stopForFlight)
        #expect(CalibrationFlightPolicy.fieldMonitorStep(speedMps: 460 * knots) == .stopForFlight)
    }

    @Test func positivelyOnGroundNeedsAValidSpeedAndNoAirborneEstimate() {
        typealias Policy = CalibrationFlightPolicy
        // The AR view's first tick at a flight launch: not yet airborne, no valid speed yet.
        #expect(!Policy.positivelyOnGround(airborneEstimate: false, latestValidSpeedKt: nil))
        #expect(Policy.positivelyOnGround(airborneEstimate: false, latestValidSpeedKt: 0))
        #expect(Policy.positivelyOnGround(airborneEstimate: false, latestValidSpeedKt: 12))
        // A takeoff roll before the estimate flips.
        #expect(!Policy.positivelyOnGround(airborneEstimate: false, latestValidSpeedKt: 60))
        #expect(!Policy.positivelyOnGround(airborneEstimate: true, latestValidSpeedKt: 0))
        #expect(!Policy.positivelyOnGround(airborneEstimate: false, latestValidSpeedKt: -1))
        #expect(!Policy.positivelyOnGround(airborneEstimate: false, latestValidSpeedKt: .nan))
    }

    // MARK: - Delivered rate

    @Test func theRateIsSamplesOverTheInterval() {
        var meter = SampleRateMeter()
        #expect(meter.rate(count: 1_000, at: 10) == nil)      // first read: no interval yet
        let hz = meter.rate(count: 1_100, at: 11)
        #expect(hz == 100)
        // A slowed stream reads as one.
        #expect(meter.rate(count: 1_160, at: 12) == 60)
    }

    @Test func aReadTooSoonKeepsTheWindowOpen() {
        var meter = SampleRateMeter()
        _ = meter.rate(count: 0, at: 0)
        #expect(meter.rate(count: 5, at: 0.05) == nil)
        // Measured from t = 0, not from the ignored read.
        #expect(meter.rate(count: 100, at: 1) == 100)
    }

    @Test func aGapOrARestartGivesNoRate() {
        var meter = SampleRateMeter()
        _ = meter.rate(count: 0, at: 0)
        // Backgrounded for a minute: no average over the gap.
        #expect(meter.rate(count: 200, at: 60) == nil)
        // The next second measures normally again.
        #expect(meter.rate(count: 300, at: 61) == 100)
        // The stream restarted and its count went backwards.
        #expect(meter.rate(count: 10, at: 62) == nil)
        meter.reset()
        #expect(meter.rate(count: 0, at: 70) == nil)
    }

    // MARK: - Calibration card

    private typealias Card = CalibrationViewController

    private func card(accuracy: Double = 11.6, field: Integrity.Verdict)
        -> CalibrationViewController.CompassCardStatus {
        Card.compassCardStatus(headingAccuracyDeg: accuracy, thresholdDeg: 13, field: field)
    }

    @Test func theCardGoesGreenOnlyOnACleanField() {
        let clean = card(field: .clean)
        #expect(clean.look == .ready && clean.isReady && clean.isVerified)
        for unclean in [Integrity.Verdict.disturbed, .pending] {
            let amber = card(field: unclean)
            #expect(amber.look == .improving)
            #expect(!amber.isVerified)
        }
    }

    /// The field no longer holds the card (#21 follow-up): a disturbed or pending field still counts
    /// as ready once the heading is inside its threshold.
    @Test func theFieldNeverHoldsTheCard() {
        #expect(card(field: .disturbed).isReady)
        #expect(card(field: .pending).isReady)
    }

    @Test func aDisturbedFieldTellsTheUserWhatToDo() {
        #expect(card(field: .disturbed).detail == "Compass disturbed — move away from metal or cars")
    }

    @Test func headingAccuracyStillComesFirst() {
        let waiting = card(accuracy: -1, field: .clean)
        #expect(waiting.look == .waiting && !waiting.isReady && !waiting.isVerified)
        let poor = card(accuracy: 20, field: .clean)
        #expect(poor.look == .improving && !poor.isReady && !poor.isVerified)
    }

    @Test func aDeviceThatCannotMeasureTheFieldKeepsTheOldRule() {
        let legacy = card(field: .unavailable)
        #expect(legacy.look == .ready && legacy.isReady && legacy.isVerified)
    }
}
