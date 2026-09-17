//
//  AltitudeDatum.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The pressure-to-geometric altitude offset, measured off the traffic picture itself.
//

import Foundation

/// Measures the local conversion between pressure altitude and geometric altitude from the
/// traffic picture itself.
///
/// Aircraft report `alt_baro` against the 29.92 inHg standard datum and `alt_geom` against the
/// WGS-84 ellipsoid. Their difference is the local offset produced by the actual altimeter
/// setting and by temperature deviation from standard — the same offset that applies to the
/// viewer. Every aircraft nearby that reports both is therefore measuring it for us, which is
/// a better local estimate than any single station's altimeter setting.
///
/// The median is used rather than the mean because a handful of aircraft report a stale or
/// mis-set value, and the interquartile spread says how much the sample can be trusted: a
/// tight spread means the aircraft agree, a wide one means the sample is contaminated.
///
/// Target *placement* does not use this. Each target carries its own pair, so
/// `CalculationsLogic.geometricPlacementAltitude` converts it exactly, per aircraft, with no
/// estimator at all. What this is for is the one quantity no target can supply: the viewer's own
/// pressure altitude, which is unmeasurable on board — the phone's barometer reads cabin pressure
/// (5,474 ft at cruise in these logs), not outside static. For that, `deltaISAEstimate(from:)`
/// reads the air mass's temperature deviation off the traffic, at whatever altitude it is flying.
///
/// `estimate(from:)` itself is now a log column and nothing else. Its median mixes altitudes and is
/// only meaningful when the sample happens to be at one level; keep reading it as a diagnostic, not
/// as a number to act on.
enum AltitudeDatumOffset {

    struct Estimate {
        /// How many aircraft contributed a usable pair.
        var sampleCount: Int
        /// Geometric minus pressure altitude, in feet. Positive means geometric reads higher.
        var medianFt: Double
        var lowerQuartileFt: Double
        var upperQuartileFt: Double

        /// Interquartile spread. Small means the contributing aircraft agree with each other.
        var spreadFt: Double { upperQuartileFt - lowerQuartileFt }
    }

    /// Per-aircraft geometric-minus-pressure differences, for aircraft reporting both.
    static func offsets(from aircraft: [Aircraft]) -> [Double] {
        aircraft.compactMap { ac in
            guard let geometric = ac.geometricAltitudeFt,
                  let pressure  = ac.pressureAltitudeFt else { return nil }
            let difference = geometric - pressure
            // Reject values no atmosphere could produce; those are mis-set or stale reports.
            guard abs(difference) <= maxPlausibleOffsetFt else { return nil }
            return difference
        }
    }

    /// Widest offset attributable to altimeter setting plus temperature deviation. Beyond this
    /// the pair is a data error rather than an atmosphere.
    static let maxPlausibleOffsetFt: Double = 5_000.0

    static func estimate(from aircraft: [Aircraft]) -> Estimate? {
        estimate(from: offsets(from: aircraft), minSamples: 1)
    }

    /// Below this height the offset is a few tens of feet dominated by the geoid and the local
    /// altimeter setting, so dividing by the height turns that constant into an enormous apparent
    /// temperature deviation. Above it the temperature term dominates and the division is stable.
    static let minContributorAltitudeFt: Double = 5_000.0

    /// Widest temperature deviation from standard that is weather rather than a broken report.
    /// ±30 K spans everything from a Siberian winter to a desert summer.
    static let maxPlausibleDeltaISAK: Double = 30.0

    /// How far the air mass is from the standard atmosphere, in kelvin, as the traffic measures it.
    ///
    /// **Why a temperature and not an offset.** Build 35 estimated the offset directly, from
    /// traffic within ±4,000 ft of the viewer, and in a whole flight it returned a value in zero
    /// rows out of 191: the sky held a mean of 2.0 aircraft and none of them were at our level. The
    /// band was there because a fleet-wide median of offsets really does mix populations — surface
    /// traffic reads near zero while traffic at cruise reads near 1,900 ft.
    ///
    /// But those are not two populations. They are one measurement taken at two heights, and the
    /// ratio between them barely moves:
    ///
    ///     ~42,250 ft  +2,250 ft   0.053      (log 78fe1ae2)
    ///     ~42,000 ft  ~+1,850 ft  0.044      (log 6b73e28c)
    ///      ~3,000 ft    ~+125 ft  0.042      (log 6b73e28c, same session)
    ///
    /// which is what the atmosphere does: one temperature deviation describes the whole column, and
    /// the height error it produces scales with height. Read that way, **every aircraft in the sky
    /// measures the same number**, and the surface traffic that poisoned the median becomes a
    /// perfectly good sample. No band, no minimum count, and one reporting aircraft anywhere in
    /// view is enough — which is the difference between a readout that works in this user's
    /// airspace and one that never appeared.
    ///
    /// **Superseded as the estimator by `datumFit` in build 41, and kept for the log column.** The
    /// pure proportion has no constant term, and the offset has one: `alt_baro` is always
    /// referenced to 1013.25 hPa, so it carries the sea-level pressure deviation as well as the
    /// temperature. Forcing that through the origin tilts the slope, which showed as a temperature
    /// that rose with altitude across the very sample that validated it — 9.04 K at 5,475 ft
    /// against 10.69 K at 35,500 ft. `datumFit` fits both terms and is 13× closer at cruise.
    static func deltaISAEstimate(
        from aircraft: [Aircraft],
        minAltitudeFt: Double = minContributorAltitudeFt,
        maxDeltaK: Double = maxPlausibleDeltaISAK
    ) -> (kelvin: Double, sampleCount: Int)? {
        let deviations: [Double] = aircraft.compactMap { ac -> Double? in
            guard let geometric = ac.geometricAltitudeFt,
                  let pressure  = ac.pressureAltitudeFt,
                  geometric >= minAltitudeFt,
                  abs(geometric - pressure) <= maxPlausibleOffsetFt,
                  let delta = CalculationsLogic.deltaISAK(geometricAltitudeFt: geometric,
                                                          pressureAltitudeFt: pressure),
                  abs(delta) <= maxDeltaK
            else { return nil }
            return delta
        }.sorted()
        guard !deviations.isEmpty else { return nil }
        return (percentile(deviations, 0.50), deviations.count)
    }

    // MARK: - The two-term fit

    /// Geometric minus pressure altitude as a straight line in height: `offset = slope·H + intercept`.
    ///
    /// Both terms are physical. The slope is the temperature deviation — a column warmer than
    /// standard is less dense, so a given pressure sits higher, by a fraction of the height. The
    /// intercept is the sea-level pressure deviation, roughly 30 ft per hPa, and it does **not**
    /// scale with height: `alt_baro` is referenced to 1013.25 hPa whatever the local altimeter
    /// setting, so every report carries it.
    struct DatumFit: Equatable {
        var slope: Double
        var interceptFt: Double
        var sampleCount: Int

        /// Geometric minus pressure at a height.
        func offsetFt(atAltitudeFt altitudeFt: Double) -> Double {
            slope * altitudeFt + interceptFt
        }

        /// The temperature half alone, without the pressure constant.
        ///
        /// This is what an altimeter set to the local QNH still gets wrong, because setting QNH is
        /// precisely what removes the constant. Above the transition altitude the altimeter is on
        /// 29.92 and both terms apply; below it, only this one does.
        func temperatureOffsetFt(atAltitudeFt altitudeFt: Double) -> Double {
            slope * altitudeFt
        }

        /// Geometric altitude of a target that reported only pressure altitude, by inverting the
        /// fit: `H = (pressure + intercept) / (1 − slope)`.
        func geometricAltitudeFt(fromPressureFt pressureFt: Double) -> Double {
            let denominator = 1.0 - slope
            guard abs(denominator) > 0.5 else { return pressureFt }
            return (pressureFt + interceptFt) / denominator
        }
    }

    /// Fewest contributors, and the least altitude they must span, before a line is worth fitting.
    /// Two points define a line exactly and so cannot disagree; three can. The span matters more
    /// than the count — a line through aircraft all at one level says nothing about the slope.
    static let minFitSamples = 3
    static let minFitSpanFt: Double = 5_000.0

    /// Plausible bounds on the fitted terms, so a pathological sample cannot move the readout far.
    /// A slope of 0.10 is roughly ISA +28 K; 1,000 ft of intercept is 33 hPa from standard.
    static let maxFitSlope: Double = 0.10
    static let maxFitInterceptFt: Double = 1_000.0

    /// Fit the offset against height across the traffic, robustly.
    ///
    /// **Theil–Sen rather than least squares**, because the sample is a handful of aircraft and
    /// ADS-B carries the occasional nonsense report. On the five contributors that validated the
    /// previous model, adding one absurd extra (9,000 ft reporting −400 ft) moves the Theil–Sen
    /// answer by 19 ft at cruise while least squares is visibly dragged. The median of pairwise
    /// slopes simply ignores it.
    ///
    /// Nil when there are too few contributors or too little altitude spread between them, which
    /// is not a failure: the caller falls back to the proportional model, and with no spread to fit
    /// through, a line anchored at the origin is the better-conditioned answer.
    static func datumFit(
        from aircraft: [Aircraft],
        minAltitudeFt: Double = minContributorAltitudeFt
    ) -> DatumFit? {
        let points: [(h: Double, offset: Double)] = aircraft.compactMap { ac in
            guard let geometric = ac.geometricAltitudeFt,
                  let pressure  = ac.pressureAltitudeFt,
                  geometric >= minAltitudeFt,
                  abs(geometric - pressure) <= maxPlausibleOffsetFt
            else { return nil }
            return (geometric, geometric - pressure)
        }
        guard points.count >= minFitSamples else { return nil }
        guard let lowest = points.map(\.h).min(), let highest = points.map(\.h).max(),
              highest - lowest >= minFitSpanFt else { return nil }

        // Median of the pairwise slopes, over pairs far enough apart in height that the slope
        // between them means something. A pair a hundred feet apart divides two noisy offsets by a
        // tiny denominator and produces a wild slope.
        var slopes: [Double] = []
        for i in points.indices {
            for j in points.index(after: i)..<points.endIndex {
                let dh = points[j].h - points[i].h
                guard abs(dh) >= minFitSpanFt / 2 else { continue }
                slopes.append((points[j].offset - points[i].offset) / dh)
            }
        }
        guard !slopes.isEmpty else { return nil }
        let slope = percentile(slopes.sorted(), 0.50)
        guard abs(slope) <= maxFitSlope else { return nil }

        // The intercept that leaves the residuals balanced, which for a median slope is the median
        // residual rather than the mean.
        let intercept = percentile(points.map { $0.offset - slope * $0.h }.sorted(), 0.50)
        guard abs(intercept) <= maxFitInterceptFt else { return nil }

        return DatumFit(slope: slope, interceptFt: intercept, sampleCount: points.count)
    }

    private static func estimate(from unsorted: [Double], minSamples: Int) -> Estimate? {
        let values = unsorted.sorted()
        guard values.count >= max(1, minSamples) else { return nil }
        return Estimate(
            sampleCount: values.count,
            medianFt: percentile(values, 0.50),
            lowerQuartileFt: percentile(values, 0.25),
            upperQuartileFt: percentile(values, 0.75)
        )
    }

    /// Nearest-rank percentile of an already-sorted array.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = max(0.0, min(1.0, fraction))
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }
}
