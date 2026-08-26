//
//  FlightRecorder.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  A ring-buffered CSV diagnostic log, exportable via the share sheet.
//
//  This project has repeatedly shipped a plausible positioning fix, tested it on one flight,
//  and reverted it on an impression ("felt worse", "the marker was off to the left"). Two
//  north-correction attempts were reverted that way. Nothing recorded what the sensors were
//  actually reporting at the moment the marker looked wrong, so each round produced an
//  opinion rather than evidence.
//
//  The recorder captures every input that feeds target placement — both GPS chains, both
//  vertical datums, compass, ARKit camera attitude, ADS-B ownship, decoder health — plus a
//  marker per lift, since the app is used in seconds-long glances and accuracy has to be
//  judged per glance rather than averaged over a flight.
//
//  Cost: one CSV row per second, held in a bounded in-memory ring. At the cap the buffer is
//  a few megabytes and covers a long flight; oldest rows are dropped first.
//

import Foundation
import CoreLocation

final class FlightRecorder {

    static let shared = FlightRecorder()

    /// ~2.8 hours at 1 Hz. Rows are ~250 bytes, so the buffer stays a few MB — small enough
    /// not to matter next to SceneKit's texture memory, which is what drives jetsam here.
    private let maxRows = 10_000

    private let queue = DispatchQueue(label: "com.tallyoh.flightrecorder", qos: .utility)
    private var rows: [String] = []
    private var liftCounter: Int = 0
    private var currentLiftID: Int = 0
    private var currentLiftStart: Date?

    /// Running counts of decoder health since launch, surfaced in the log and info panel.
    /// Guarded by their own lock rather than the logging queue so the info panel can read
    /// them synchronously at UI refresh rate without hopping threads.
    private let counterLock = NSLock()
    private var gdl90Valid: Int = 0
    private var gdl90CRCFailures: Int = 0
    private var gdl90Malformed: Int = 0

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        rows.reserveCapacity(1024)
        appendRaw(FlightRecorder.header)
    }

    // MARK: - Schema

    private static let columns: [String] = [
        "time", "lift_id", "t_since_lift_s", "event", "detail",
        "pos_source", "lat", "lon", "h_acc_m", "fix_age_s", "dead_reckoned",
        "gs_kt", "track_deg",
        "display_alt_ft", "geom_alt_ft", "has_geom", "press_alt_ft", "has_press",
        "cabin_sourced_press", "geoid_sep_ft",
        "gps_msl_ft", "gps_hae_ft", "v_acc_m", "gps_course_deg", "gps_course_acc_deg",
        "baro_cabin_press_alt_ft",
        "adsb_press_alt_ft", "adsb_hae_ft",
        "hdg_mag_deg", "hdg_true_deg", "hdg_acc_deg", "declination_deg",
        "world_yaw_corr_deg", "course_residual_deg", "compass_response",
        "ar_heading_deg", "heading_delta_deg",
        "cam_yaw_deg", "cam_pitch_deg", "cam_roll_deg", "ar_state", "airborne", "airborne_basis",
        "gdl90_ok", "gdl90_crc_fail", "gdl90_malformed",
        "n_aircraft", "n_adsb", "n_internet", "n_stale", "n_rendered",
        "n_targets_press", "n_targets_geom",
        "datum_offset_n", "datum_offset_median_ft", "datum_offset_p25_ft", "datum_offset_p75_ft"
    ]

    private static let header = columns.joined(separator: ",")

    // MARK: - Sample

    /// One periodic row. Optionals are written as empty CSV fields so a missing value is
    /// distinguishable from a real zero — the distinction that makes altitude bugs visible.
    struct Sample {
        var ownship: OwnshipSnapshot = OwnshipSnapshot()

        var gpsMSLFt: Double?
        var gpsHAEFt: Double?
        var verticalAccuracyM: Double?
        var gpsCourseDeg: Double?
        var gpsCourseAccuracyDeg: Double?
        var cabinPressureAltitudeFt: Double?

        var adsbPressureAltitudeFt: Double?
        var adsbHAEFt: Double?

        var headingMagneticDeg: Double?
        var headingTrueDeg: Double?
        var headingAccuracyDeg: Double?
        var declinationDeg: Double?
        /// Gap between ARKit's raw azimuth and the compass, or nil before the first valid
        /// measurement — a different thing from a measured zero. Diagnostic only; nothing is
        /// rotated by it. See ARTrafficViewController.worldYawErrorDeg for why not.
        var worldYawCorrectionDeg: Double?
        /// How far the compass turned per degree the phone turned, over a rolling window.
        ///
        /// Near 1: the compass is measuring the phone's azimuth, and an alignment correction
        /// built on it would be sound. Near 0: it is slaved to something else — in the flight
        /// that prompted this column, the aircraft's ground track, where the phone rotated
        /// 704.8 degrees while the compass rotated 273.3 and their correlation was +0.29.
        /// Empty when the phone has not turned enough for the ratio to mean anything.
        var compassResponse: Double?
        /// ARKit's raw azimuth minus GPS ground track. Diagnostic only, and meaningful only
        /// while the phone points near the aircraft's nose. Read it alongside compassResponse:
        /// where the compass is track-slaved, this and heading_delta_deg carry the same
        /// information, and that agreement is itself the evidence for it.
        var courseResidualDeg: Double?

        /// ARKit's raw, uncorrected world azimuth — what the AR world believes north is.
        var arHeadingDeg: Double?
        /// Compass heading minus ARKit's raw azimuth, signed, −180…180.
        ///
        /// Where the compass is genuinely measuring the phone, this is ARKit's world-alignment
        /// error: its north is fixed from one compass sample at session start and refines only
        /// slowly thereafter, so expect it large early and decaying. Where the compass is
        /// track-slaved — see compassResponse — it is instead mostly the angle between the phone
        /// and the aircraft's nose, and says nothing about ARKit at all. That ambiguity is why
        /// nothing may be rotated by this number until compassResponse says which case applies.
        var headingDeltaDeg: Double?

        var cameraYawDeg: Double?
        var cameraPitchDeg: Double?
        var cameraRollDeg: Double?
        var arTrackingState: String?
        /// Whether the app judged the user to be flying, and what it judged that from —
        /// the input that decides TCAS, the altitude-band cull and the GPS accuracy gate.
        var airborne: Bool?
        var airborneBasis: String?

        var aircraftCount: Int?
        var adsbAircraftCount: Int?
        var internetAircraftCount: Int?
        var staleAircraftCount: Int?
        var renderedNodeCount: Int?

        /// How many nearby targets reported each vertical datum, and the measured conversion
        /// between them. This is the input the frame-aware vertical placement is built on:
        /// without it the offset would have to be assumed rather than measured.
        var targetsWithPressureAltitude: Int?
        var targetsWithGeometricAltitude: Int?
        var datumOffset: AltitudeDatumOffset.Estimate?
    }

    // MARK: - Recording

    func record(_ sample: Sample) {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            self.appendRaw(self.row(for: sample, event: "", detail: "", at: now))
        }
    }

    /// Record a discrete event (state change, decoder anomaly, session transition).
    /// `detail` is sanitised for CSV, so callers may pass free text.
    func record(event: String, detail: String = "", sample: Sample? = nil) {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            self.appendRaw(self.row(for: sample ?? Sample(), event: event, detail: detail, at: now))
        }
    }

    /// Mark the start of a glance. Every foreground begins a new lift segment, because
    /// lift-and-look quality is only meaningful per lift: how long until traffic was drawn,
    /// which tracking state the session started in, and what alignment was in force.
    func beginLift(reason: String) {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            self.liftCounter += 1
            self.currentLiftID = self.liftCounter
            self.currentLiftStart = now
            self.appendRaw(self.row(for: Sample(), event: "lift_begin", detail: reason, at: now))
        }
    }

    func endLift(reason: String) {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            self.appendRaw(self.row(for: Sample(), event: "lift_end", detail: reason, at: now))
            self.currentLiftStart = nil
        }
    }

    struct GDL90Counters {
        var valid: Int = 0
        var crcFailures: Int = 0
        var malformed: Int = 0

        /// Share of frames rejected, 0–1. The headline number for receiver link health.
        var rejectionRate: Double {
            let total = valid + crcFailures + malformed
            guard total > 0 else { return 0 }
            return Double(crcFailures + malformed) / Double(total)
        }
    }

    /// Accumulate GDL90 decoder health. Called per datagram; only the totals are logged.
    func recordGDL90(valid: Int, crcFailures: Int, malformed: Int) {
        guard valid > 0 || crcFailures > 0 || malformed > 0 else { return }
        counterLock.lock()
        gdl90Valid       += valid
        gdl90CRCFailures += crcFailures
        gdl90Malformed   += malformed
        counterLock.unlock()
    }

    /// Snapshot of decoder health, safe to read from any thread.
    func gdl90Counters() -> GDL90Counters {
        counterLock.lock()
        defer { counterLock.unlock() }
        return GDL90Counters(valid: gdl90Valid, crcFailures: gdl90CRCFailures, malformed: gdl90Malformed)
    }

    // MARK: - Row building

    private func row(for sample: Sample, event: String, detail: String, at date: Date) -> String {
        let ownship = sample.ownship
        let sinceLift = currentLiftStart.map { date.timeIntervalSince($0) }

        var fields: [String] = []
        fields.append(FlightRecorder.isoFormatter.string(from: date))
        fields.append(String(currentLiftID))
        fields.append(format(sinceLift, decimals: 2))
        fields.append(escape(event))
        fields.append(escape(detail))

        fields.append(ownship.hasPosition ? ownship.source.rawValue : "")
        fields.append(ownship.hasPosition ? format(ownship.coordinate.latitude,  decimals: 7) : "")
        fields.append(ownship.hasPosition ? format(ownship.coordinate.longitude, decimals: 7) : "")
        fields.append(ownship.horizontalAccuracyM >= 0 ? format(ownship.horizontalAccuracyM, decimals: 1) : "")
        fields.append(ownship.hasPosition ? format(ownship.fixAge, decimals: 2) : "")
        fields.append(ownship.hasPosition ? (ownship.wasDeadReckoned ? "1" : "0") : "")
        fields.append(ownship.hasVelocity ? format(ownship.groundSpeedKt, decimals: 1) : "")
        fields.append(ownship.hasVelocity ? format(ownship.trackDeg,      decimals: 1) : "")

        fields.append(format(ownship.displayAltitudeFt, decimals: 0))
        fields.append(ownship.hasGeometricAltitude ? format(ownship.geometricAltitudeFt, decimals: 0) : "")
        fields.append(ownship.hasGeometricAltitude ? "1" : "0")
        fields.append(ownship.hasPressureAltitude ? format(ownship.pressureAltitudeFt, decimals: 0) : "")
        fields.append(ownship.hasPressureAltitude ? "1" : "0")
        fields.append(ownship.pressureAltitudeIsCabinSourced ? "1" : "0")
        fields.append(ownship.hasGeoidSeparation ? format(ownship.geoidSeparationFt, decimals: 1) : "")

        fields.append(format(sample.gpsMSLFt,             decimals: 0))
        fields.append(format(sample.gpsHAEFt,             decimals: 0))
        fields.append(format(sample.verticalAccuracyM,    decimals: 1))
        fields.append(format(sample.gpsCourseDeg,         decimals: 1))
        fields.append(format(sample.gpsCourseAccuracyDeg, decimals: 1))
        fields.append(format(sample.cabinPressureAltitudeFt, decimals: 0))

        fields.append(format(sample.adsbPressureAltitudeFt, decimals: 0))
        fields.append(format(sample.adsbHAEFt,              decimals: 0))

        fields.append(format(sample.headingMagneticDeg, decimals: 1))
        fields.append(format(sample.headingTrueDeg,     decimals: 1))
        fields.append(format(sample.headingAccuracyDeg, decimals: 1))
        fields.append(format(sample.declinationDeg,        decimals: 2))
        fields.append(format(sample.worldYawCorrectionDeg, decimals: 2))
        fields.append(format(sample.courseResidualDeg,     decimals: 1))
        fields.append(format(sample.compassResponse,       decimals: 2))
        fields.append(format(sample.arHeadingDeg,   decimals: 1))
        fields.append(format(sample.headingDeltaDeg, decimals: 1))

        fields.append(format(sample.cameraYawDeg,   decimals: 1))
        fields.append(format(sample.cameraPitchDeg, decimals: 1))
        fields.append(format(sample.cameraRollDeg,  decimals: 1))
        fields.append(escape(sample.arTrackingState ?? ""))
        fields.append(sample.airborne.map { $0 ? "1" : "0" } ?? "")
        fields.append(escape(sample.airborneBasis ?? ""))

        let counters = gdl90Counters()
        fields.append(String(counters.valid))
        fields.append(String(counters.crcFailures))
        fields.append(String(counters.malformed))

        fields.append(sample.aircraftCount.map(String.init)         ?? "")
        fields.append(sample.adsbAircraftCount.map(String.init)     ?? "")
        fields.append(sample.internetAircraftCount.map(String.init) ?? "")
        fields.append(sample.staleAircraftCount.map(String.init)    ?? "")
        fields.append(sample.renderedNodeCount.map(String.init)     ?? "")

        fields.append(sample.targetsWithPressureAltitude.map(String.init)  ?? "")
        fields.append(sample.targetsWithGeometricAltitude.map(String.init) ?? "")
        fields.append(sample.datumOffset.map { String($0.sampleCount) } ?? "")
        fields.append(format(sample.datumOffset?.medianFt,        decimals: 0))
        fields.append(format(sample.datumOffset?.lowerQuartileFt, decimals: 0))
        fields.append(format(sample.datumOffset?.upperQuartileFt, decimals: 0))

        return fields.joined(separator: ",")
    }

    private func format(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    private func format(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    /// Quote a field only when it could break the CSV, so most rows stay quote-free.
    private func escape(_ text: String) -> String {
        guard text.contains(",") || text.contains("\"") || text.contains("\n") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Append with ring-buffer trimming. The header is row 0 and is preserved when trimming.
    private func appendRaw(_ row: String) {
        rows.append(row)
        guard rows.count > maxRows else { return }
        // Drop the oldest data rows in a batch rather than one per append, so trimming does
        // not turn into an O(n) memmove on every single sample once the buffer is full.
        let overflow = rows.count - maxRows
        let dropCount = max(overflow, maxRows / 10)
        let firstDataRow = 1
        let end = min(firstDataRow + dropCount, rows.count)
        guard end > firstDataRow else { return }
        rows.removeSubrange(firstDataRow..<end)
    }

    // MARK: - Export

    /// Serialise the buffer to a file in the temporary directory and hand back its URL.
    /// Completion is delivered on the main queue.
    func exportLog(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let text = self.rows.joined(separator: "\n")
            let stamp = FlightRecorder.isoFormatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tallyoh-flightlog-\(stamp).csv")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { completion(url) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// Number of data rows currently buffered (excludes the header).
    func rowCount(completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            let count = max(0, (self?.rows.count ?? 1) - 1)
            DispatchQueue.main.async { completion(count) }
        }
    }
}
