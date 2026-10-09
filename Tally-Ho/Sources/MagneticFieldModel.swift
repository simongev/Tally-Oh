//
//  MagneticFieldModel.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The World Magnetic Model, WMM2025 (#21): the Earth's main field at a place and time, to check
//  what the phone's magnetometer measures against what it should measure there.
//
//  The compass card used to go green on iOS's `headingAccuracy`, which reads 10–12.5° almost
//  always and cannot see local metal. A balcony railing, rebar or a parked car bends the field the
//  compass steers by, and the ground seed and the ground correction both follow the compass. The
//  field's strength and its dip below the horizontal are the two things such a disturbance changes
//  and the model knows independently; `MagneticFieldIntegrity` compares them.
//
//  Coefficients: NOAA NCEI / BGS, WMM2025 (released 2024-11-13, valid 2025.0–2030.0), US public
//  domain, transcribed mechanically from WMM.COF. The evaluation follows the WMM2025 technical
//  report: geodetic to geocentric coordinates on WGS-84, Schmidt semi-normalised associated
//  Legendre functions to degree and order 12, secular variation applied linearly from the epoch,
//  and the field rotated back to the geodetic frame. Checked against NOAA's 100 published test
//  values in MagneticFieldModelTests.
//
//  Pure, no state: safe from any thread.
//

import Foundation

struct MagneticFieldModel {

    /// The field at one point, in the geodetic (local north, east, down) frame.
    struct Field: Equatable {
        /// North, east and vertical (positive down) components, nanotesla.
        var northNT: Double
        var eastNT: Double
        var downNT: Double

        /// Horizontal intensity H, nanotesla.
        var horizontalNT: Double { (northNT * northNT + eastNT * eastNT).squareRoot() }
        /// Total intensity F, nanotesla.
        var totalNT: Double { (horizontalNT * horizontalNT + downNT * downNT).squareRoot() }
        /// Total intensity F, microtesla — the unit CoreMotion reports in.
        var totalUT: Double { totalNT / 1_000 }
        /// Inclination (dip) I: degrees below the horizontal, positive when the field points down.
        var inclinationDeg: Double { atan2(downNT, horizontalNT) * 180 / .pi }
        /// Declination D: degrees east of true north.
        var declinationDeg: Double { atan2(eastNT, northNT) * 180 / .pi }
    }

    /// WMM2025's epoch and the end of its validity.
    static let epoch: Double = 2025.0
    static let validUntil: Double = 2030.0
    static let maxDegree = 12

    /// Whether a decimal year lies inside the model's five-year life. Outside it the secular
    /// variation is extrapolated past what NOAA vouches for.
    static func isValid(decimalYear: Double) -> Bool {
        decimalYear >= epoch && decimalYear <= validUntil
    }

    /// A date as a decimal year in UTC, the time argument the model takes: 2025-07-02 12:00 is 2025.5.
    static func decimalYear(from date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let year = calendar.component(.year, from: date)
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        else { return Double(year) }
        return Double(year) + date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    /// The main field at a geodetic latitude and longitude (degrees), a height above the WGS-84
    /// ellipsoid (kilometres) and a decimal year.
    ///
    /// Using MSL height for the ellipsoidal one costs nothing that matters here: the field changes
    /// by about 0.02 nT per metre of height, so even a 100 m geoid separation is 2 nT out of 50,000.
    static func field(latitudeDeg: Double, longitudeDeg: Double,
                      altitudeKm: Double, decimalYear: Double) -> Field {
        let n = maxDegree

        // ── Geodetic to geocentric spherical (WGS-84) ────────────────────────────────────────
        let a = 6378.137
        let f = 1 / 298.257223563
        let e2 = f * (2 - f)
        let phi = latitudeDeg * .pi / 180
        let lambda = longitudeDeg * .pi / 180
        let sinPhi = sin(phi)
        let rc = a / (1 - e2 * sinPhi * sinPhi).squareRoot()
        let p = (rc + altitudeKm) * cos(phi)
        let z = (rc * (1 - e2) + altitudeKm) * sinPhi
        let r = (p * p + z * z).squareRoot()
        let phiC = asin(z / r)

        // ── Coefficients at the requested time, Schmidt-normalised ───────────────────────────
        let dt = decimalYear - epoch
        var g = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n + 1)
        var h = g
        var index = 0
        for degree in 1...n {
            for order in 0...degree {
                let base = index * 4
                g[degree][order] = coefficients[base] + dt * coefficients[base + 2]
                h[degree][order] = coefficients[base + 1] + dt * coefficients[base + 3]
                index += 1
            }
        }
        let schmidt = schmidtFactors

        // ── Associated Legendre functions of the geocentric colatitude, and their derivatives ──
        let theta = .pi / 2 - phiC
        let cosT = cos(theta)
        let sinT = sin(theta)
        var pnm = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n + 1)
        var dpnm = pnm
        pnm[0][0] = 1
        for degree in 1...n {
            for order in 0...degree {
                if degree == order {
                    pnm[degree][order] = sinT * pnm[degree - 1][order - 1]
                    dpnm[degree][order] = sinT * dpnm[degree - 1][order - 1]
                        + cosT * pnm[degree - 1][order - 1]
                } else if degree == 1 || order == degree - 1 {
                    pnm[degree][order] = cosT * pnm[degree - 1][order]
                    dpnm[degree][order] = cosT * dpnm[degree - 1][order] - sinT * pnm[degree - 1][order]
                } else {
                    let dm = Double(degree - 1)
                    let k = (dm * dm - Double(order * order))
                        / Double((2 * degree - 1) * (2 * degree - 3))
                    pnm[degree][order] = cosT * pnm[degree - 1][order] - k * pnm[degree - 2][order]
                    dpnm[degree][order] = cosT * dpnm[degree - 1][order] - sinT * pnm[degree - 1][order]
                        - k * dpnm[degree - 2][order]
                }
            }
        }

        // ── Field in geocentric spherical coordinates ─────────────────────────────────────────
        let referenceRadius = 6371.2
        var bRadial = 0.0
        var bTheta = 0.0
        var bPhi = 0.0
        for degree in 1...n {
            let ratio = pow(referenceRadius / r, Double(degree + 2))
            for order in 0...degree {
                let gs = g[degree][order] * schmidt[degree][order]
                let hs = h[degree][order] * schmidt[degree][order]
                let cosM = cos(Double(order) * lambda)
                let sinM = sin(Double(order) * lambda)
                let term = gs * cosM + hs * sinM
                bRadial += Double(degree + 1) * ratio * term * pnm[degree][order]
                bTheta -= ratio * term * dpnm[degree][order]
                bPhi += ratio * Double(order) * (gs * sinM - hs * cosM) * pnm[degree][order]
            }
        }
        // sin θ is zero only exactly at a pole; floored there rather than divided by.
        bPhi /= max(sinT, 1e-12)

        // ── Back to the geodetic frame ────────────────────────────────────────────────────────
        let northC = -bTheta
        let eastC = bPhi
        let downC = -bRadial
        let psi = phiC - phi
        return Field(northNT: northC * cos(psi) - downC * sin(psi),
                     eastNT: eastC,
                     downNT: northC * sin(psi) + downC * cos(psi))
    }

    /// The field at a date rather than a decimal year.
    static func field(latitudeDeg: Double, longitudeDeg: Double,
                      altitudeKm: Double, date: Date) -> Field {
        field(latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg,
              altitudeKm: altitudeKm, decimalYear: decimalYear(from: date))
    }

    /// Schmidt semi-normalisation factors S(n, m), applied to the Gauss coefficients.
    private static let schmidtFactors: [[Double]] = {
        let n = maxDegree
        var s = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n + 1)
        s[0][0] = 1
        for degree in 1...n {
            s[degree][0] = s[degree - 1][0] * Double(2 * degree - 1) / Double(degree)
            for order in 1...degree {
                let factor = Double((degree - order + 1) * (order == 1 ? 2 : 1)) / Double(degree + order)
                s[degree][order] = s[degree][order - 1] * factor.squareRoot()
            }
        }
        return s
    }()

    /// WMM2025 Gauss coefficients: g, h (nT) and their secular variation ġ, ḣ (nT/year), four per
    /// (n, m), in WMM.COF order — n from 1 to 12, m from 0 to n.
    private static let coefficients: [Double] = [
        -29351.8, 0.0, 12.0, 0.0,   //  1  0
        -1410.8, 4545.4, 9.7, -21.5,   //  1  1
        -2556.6, 0.0, -11.6, 0.0,   //  2  0
        2951.1, -3133.6, -5.2, -27.7,   //  2  1
        1649.3, -815.1, -8.0, -12.1,   //  2  2
        1361.0, 0.0, -1.3, 0.0,   //  3  0
        -2404.1, -56.6, -4.2, 4.0,   //  3  1
        1243.8, 237.5, 0.4, -0.3,   //  3  2
        453.6, -549.5, -15.6, -4.1,   //  3  3
        895.0, 0.0, -1.6, 0.0,   //  4  0
        799.5, 278.6, -2.4, -1.1,   //  4  1
        55.7, -133.9, -6.0, 4.1,   //  4  2
        -281.1, 212.0, 5.6, 1.6,   //  4  3
        12.1, -375.6, -7.0, -4.4,   //  4  4
        -233.2, 0.0, 0.6, 0.0,   //  5  0
        368.9, 45.4, 1.4, -0.5,   //  5  1
        187.2, 220.2, 0.0, 2.2,   //  5  2
        -138.7, -122.9, 0.6, 0.4,   //  5  3
        -142.0, 43.0, 2.2, 1.7,   //  5  4
        20.9, 106.1, 0.9, 1.9,   //  5  5
        64.4, 0.0, -0.2, 0.0,   //  6  0
        63.8, -18.4, -0.4, 0.3,   //  6  1
        76.9, 16.8, 0.9, -1.6,   //  6  2
        -115.7, 48.8, 1.2, -0.4,   //  6  3
        -40.9, -59.8, -0.9, 0.9,   //  6  4
        14.9, 10.9, 0.3, 0.7,   //  6  5
        -60.7, 72.7, 0.9, 0.9,   //  6  6
        79.5, 0.0, -0.0, 0.0,   //  7  0
        -77.0, -48.9, -0.1, 0.6,   //  7  1
        -8.8, -14.4, -0.1, 0.5,   //  7  2
        59.3, -1.0, 0.5, -0.8,   //  7  3
        15.8, 23.4, -0.1, 0.0,   //  7  4
        2.5, -7.4, -0.8, -1.0,   //  7  5
        -11.1, -25.1, -0.8, 0.6,   //  7  6
        14.2, -2.3, 0.8, -0.2,   //  7  7
        23.2, 0.0, -0.1, 0.0,   //  8  0
        10.8, 7.1, 0.2, -0.2,   //  8  1
        -17.5, -12.6, 0.0, 0.5,   //  8  2
        2.0, 11.4, 0.5, -0.4,   //  8  3
        -21.7, -9.7, -0.1, 0.4,   //  8  4
        16.9, 12.7, 0.3, -0.5,   //  8  5
        15.0, 0.7, 0.2, -0.6,   //  8  6
        -16.8, -5.2, -0.0, 0.3,   //  8  7
        0.9, 3.9, 0.2, 0.2,   //  8  8
        4.6, 0.0, -0.0, 0.0,   //  9  0
        7.8, -24.8, -0.1, -0.3,   //  9  1
        3.0, 12.2, 0.1, 0.3,   //  9  2
        -0.2, 8.3, 0.3, -0.3,   //  9  3
        -2.5, -3.3, -0.3, 0.3,   //  9  4
        -13.1, -5.2, 0.0, 0.2,   //  9  5
        2.4, 7.2, 0.3, -0.1,   //  9  6
        8.6, -0.6, -0.1, -0.2,   //  9  7
        -8.7, 0.8, 0.1, 0.4,   //  9  8
        -12.9, 10.0, -0.1, 0.1,   //  9  9
        -1.3, 0.0, 0.1, 0.0,   // 10  0
        -6.4, 3.3, 0.0, 0.0,   // 10  1
        0.2, 0.0, 0.1, -0.0,   // 10  2
        2.0, 2.4, 0.1, -0.2,   // 10  3
        -1.0, 5.3, -0.0, 0.1,   // 10  4
        -0.6, -9.1, -0.3, -0.1,   // 10  5
        -0.9, 0.4, 0.0, 0.1,   // 10  6
        1.5, -4.2, -0.1, 0.0,   // 10  7
        0.9, -3.8, -0.1, -0.1,   // 10  8
        -2.7, 0.9, -0.0, 0.2,   // 10  9
        -3.9, -9.1, -0.0, -0.0,   // 10 10
        2.9, 0.0, 0.0, 0.0,   // 11  0
        -1.5, 0.0, -0.0, -0.0,   // 11  1
        -2.5, 2.9, 0.0, 0.1,   // 11  2
        2.4, -0.6, 0.0, -0.0,   // 11  3
        -0.6, 0.2, 0.0, 0.1,   // 11  4
        -0.1, 0.5, -0.1, -0.0,   // 11  5
        -0.6, -0.3, 0.0, -0.0,   // 11  6
        -0.1, -1.2, -0.0, 0.1,   // 11  7
        1.1, -1.7, -0.1, -0.0,   // 11  8
        -1.0, -2.9, -0.1, 0.0,   // 11  9
        -0.2, -1.8, -0.1, 0.0,   // 11 10
        2.6, -2.3, -0.1, 0.0,   // 11 11
        -2.0, 0.0, 0.0, 0.0,   // 12  0
        -0.2, -1.3, 0.0, -0.0,   // 12  1
        0.3, 0.7, -0.0, 0.0,   // 12  2
        1.2, 1.0, -0.0, -0.1,   // 12  3
        -1.3, -1.4, -0.0, 0.1,   // 12  4
        0.6, -0.0, -0.0, -0.0,   // 12  5
        0.6, 0.6, 0.1, -0.0,   // 12  6
        0.5, -0.1, -0.0, -0.0,   // 12  7
        -0.1, 0.8, 0.0, 0.0,   // 12  8
        -0.4, 0.1, 0.0, -0.0,   // 12  9
        -0.2, -1.0, -0.1, -0.0,   // 12 10
        -1.3, 0.1, -0.0, 0.0,   // 12 11
        -0.7, 0.2, -0.1, -0.1,   // 12 12
    ]
}
