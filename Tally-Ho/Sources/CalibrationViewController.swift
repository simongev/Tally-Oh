//
//  CalibrationViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Pre-flight calibration screen shown before the AR view.
//  Waits for:
//   1. GPS fix with horizontalAccuracy ≤ 10 m
//   2. Compass heading with headingAccuracy ≤ 13°  (achieved by the user
//      performing a figure-8 motion with the phone)
//
//  - If both conditions are already satisfied on the first reading the screen
//    is bypassed instantly (no flash shown to the user).
//  - Once both conditions become satisfied the screen dismisses automatically.
//  - There is no "Start" button; a prominent "Skip" button lets the user
//    launch immediately without waiting.
//  - In flight it dismisses itself on the first fix that shows the phone airborne (#15): the 10 m
//    fix it waits for never comes in a cabin, and the user had to tap Skip on every launch.
//

import UIKit
import CoreLocation

// MARK: - Calibration in flight (#15)

/// Whether the phone is flying, for the calibration prompts — which belong on the ground.
///
/// In a cabin the launch screen waits for a ≤ 10 m GPS fix that never comes, so every launch in flight
/// ended in Skip; and the in-session prompts guard on the airborne estimate, which does not exist until
/// the first 4 Hz tick has computed it. A fix moving at 50 kt or more answers both: nothing on the
/// ground does that but a takeoff roll.
enum CalibrationFlightPolicy {
    static let airborneSpeedKt: Double = 50

    /// A fix that shows the phone airborne. `CLLocation.speed` is in m/s, negative when invalid.
    static func fixShowsFlight(speedMps: Double) -> Bool {
        speedMps.isFinite && speedMps >= 0 && speedMps * 3600.0 / 1852.0 >= airborneSpeedKt
    }

    /// Whether to treat the phone as in flight: the airborne estimate, or — before there is one — a
    /// GPS ground speed of 50 kt or more.
    static func inFlight(airborneEstimate: Bool, gpsSpeedKt: Double) -> Bool {
        airborneEstimate || (gpsSpeedKt.isFinite && gpsSpeedKt >= airborneSpeedKt)
    }

    // MARK: Positively on the ground (#21)

    /// A fix that positively shows the phone on the ground: a valid speed below `airborneSpeedKt`.
    ///
    /// Not the negation of `fixShowsFlight`. A fix with no valid speed — a cached, Wi-Fi or cell fix,
    /// often the first one delivered after `startUpdatingLocation` — shows neither, and on a flight
    /// launch that first fix must not count as ground.
    static func fixShowsGround(speedMps: Double) -> Bool {
        speedMps.isFinite && speedMps >= 0 && speedMps * 3600.0 / 1852.0 < airborneSpeedKt
    }

    /// Whether the phone is positively on the ground: not airborne by the estimate, and its latest
    /// valid GPS speed below `airborneSpeedKt`. With no valid speed yet it is not known to be on the
    /// ground — the window at a flight launch before the airborne estimate has any basis.
    static func positivelyOnGround(airborneEstimate: Bool, latestValidSpeedKt: Double?) -> Bool {
        guard !airborneEstimate, let speed = latestValidSpeedKt, speed.isFinite, speed >= 0 else {
            return false
        }
        return speed < airborneSpeedKt
    }

    /// What the calibration screen does with the field monitor on a fix.
    enum FieldMonitorStep: Equatable {
        /// The fix shows flight: stop it, and the screen goes.
        case stopForFlight
        /// The fix positively shows the ground: run it.
        case start
        /// The fix shows neither (no valid speed): change nothing.
        case leave
    }

    static func fieldMonitorStep(speedMps: Double) -> FieldMonitorStep {
        if fixShowsFlight(speedMps: speedMps) { return .stopForFlight }
        if fixShowsGround(speedMps: speedMps) { return .start }
        return .leave
    }
}

// MARK: - CalibrationViewController

class CalibrationViewController: UIViewController {

    // MARK: - Thresholds

    private let gpsAccuracyThreshold:     CLLocationAccuracy         = 10.0   // metres
    /// **This gate has never once held.** `CLHeading.headingAccuracy` reads exactly 10.0 in 34 of
    /// 35 flight logs and is never beaten, so it passes on the first reading every time and the
    /// screen bypasses itself instantly, exactly as the header above describes — which means the
    /// figure-8 this file exists to ask for has never been performed. Left at 13° deliberately:
    /// tightening it would make the screen block every launch on a number that means nothing, and
    /// "lift the phone, see the traffic, put it down" is the standing requirement. The compass gets
    /// calibrated instead by `locationManagerShouldDisplayHeadingCalibration`, which lets iOS raise
    /// its own prompt when the magnetometer genuinely needs one, plus a single deliberate offer per
    /// install. See `CompassCalibrationPolicy`.
    private let compassAccuracyThreshold: CLLocationDirectionAccuracy = 13.0   // degrees

    // MARK: - UI

    private let titleLabel      = UILabel()
    private let subtitleLabel   = UILabel()
    private let gpsCard         = CalibrationCard(icon: "📍", title: "GPS Signal")
    private let compassCard     = CalibrationCard(icon: "🧭", title: "Compass")
    private let figureEightView = FigureEightInstructionView()
    private let skipButton      = UIButton(type: .system)

    // MARK: - Location

    private let locationManager = CLLocationManager()
    private var gpsReady     = false
    private var compassReady = false
    private var dismissed    = false   // prevent double-dismiss
    /// True when the user dismissed this screen with Skip rather than the sensors converging.
    /// Reported to the caller so it can stop re-presenting a screen the user has declined.
    private var wasSkipped   = false

    private var bestGPSAccuracy:     CLLocationAccuracy         = -1
    private var bestCompassAccuracy: CLLocationDirectionAccuracy = -1

    private var lastValidLocation: CLLocation?

    // MARK: - Callback

    /// Called once when the screen is finished with. The flag reports whether the user chose
    /// Skip: the caller needs that to avoid re-presenting a screen the user just dismissed,
    /// since skipping means the sensors never reached the thresholds and will keep failing
    /// whatever check the caller applies next.
    var onComplete: ((CLLocation?, _ wasSkipped: Bool) -> Void)?

    /// Fired once, the first time any location update arrives — well before
    /// gpsAccuracyThreshold is met and the screen actually dismisses. Lets the
    /// app kick off a network fetch that can overlap with the rest of
    /// calibration instead of waiting until this screen is fully done.
    var onEarlyLocation: ((CLLocation) -> Void)?
    private var earlyLocationSent = false

    // MARK: - Field check (#21)

    /// The field-check client name for `MagneticFieldMonitor.shared`.
    private static let fieldMonitorClient = "calibration"
    /// When the compass card was first held back by the field alone, on the media clock.
    private var fieldWaitStart: CFTimeInterval?
    /// Re-evaluates the cards twice a second, so the field verdict and the ten-second wait move
    /// the card even when no heading update arrives. Invalidated on dismissal.
    private var readinessTimer: Timer?
    private var lastCompassCard: CompassCardStatus?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupLocation()
        // The field monitor starts on the first fix that positively shows the phone on the ground,
        // below — a valid speed under 50 kt. Never on a fix without a valid speed, so never in flight.
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateReadiness()
        }
    }

    deinit {
        readinessTimer?.invalidate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        figureEightView.startAnimation()
    }

    // MARK: - Setup UI

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.12, alpha: 1)

        titleLabel.text          = "✈️  Tally-Ho"
        titleLabel.font          = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textColor     = .white
        titleLabel.textAlignment = .center

        subtitleLabel.text          = "Calibrating sensors for best AR accuracy"
        subtitleLabel.font          = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor     = UIColor(white: 0.7, alpha: 1)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2

        // Skip button — prominent rounded style
        skipButton.setTitle("Skip and start now", for: .normal)
        skipButton.titleLabel?.font   = .systemFont(ofSize: 17, weight: .semibold)
        skipButton.setTitleColor(.white, for: .normal)
        skipButton.backgroundColor    = UIColor(white: 0.22, alpha: 1)
        skipButton.layer.cornerRadius = 14
        skipButton.layer.borderWidth  = 1.5
        skipButton.layer.borderColor  = UIColor(white: 0.45, alpha: 1).cgColor
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)

        figureEightView.translatesAutoresizingMaskIntoConstraints = false

        let topStack  = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        topStack.axis    = .vertical
        topStack.spacing = 6

        let cardStack = UIStackView(arrangedSubviews: [gpsCard, compassCard])
        cardStack.axis    = .vertical
        cardStack.spacing = 12

        let rootStack = UIStackView(arrangedSubviews: [
            topStack, cardStack, figureEightView, skipButton
        ])
        rootStack.axis      = .vertical
        rootStack.spacing   = 28
        rootStack.alignment = .fill
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            figureEightView.heightAnchor.constraint(equalToConstant: 130),
            skipButton.heightAnchor.constraint(equalToConstant: 54),
        ])
    }

    // MARK: - Setup Location

    private func setupLocation() {
        locationManager.delegate        = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType    = .airborne
        locationManager.distanceFilter  = kCLDistanceFilterNone
        locationManager.headingFilter   = kCLHeadingFilterNone
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    // MARK: - State Update

    private func updateReadiness() {
        // GPS card
        if bestGPSAccuracy < 0 {
            gpsCard.setState(.waiting, detail: "Acquiring satellite fix…")
        } else if bestGPSAccuracy <= gpsAccuracyThreshold {
            gpsCard.setState(.ready, detail: String(format: "±%.0f m  ✓", bestGPSAccuracy))
            gpsReady = true
        } else {
            gpsCard.setState(.improving, detail: String(format: "±%.0f m  (need ≤ %.0f m)", bestGPSAccuracy, gpsAccuracyThreshold))
            gpsReady = false
        }

        // Compass card — decided entirely by `compassCardStatus` (#21).
        let now = CACurrentMediaTime()
        let card = Self.compassCardStatus(
            headingAccuracyDeg: bestCompassAccuracy,
            thresholdDeg: compassAccuracyThreshold,
            field: MagneticFieldMonitor.shared.assessment().verdict,
            fieldWaitedSeconds: fieldWaitStart.map { now - $0 } ?? 0)
        if card.heldByField, fieldWaitStart == nil { fieldWaitStart = now }
        let look: CalibrationState
        switch card.look {
        case .waiting:   look = .waiting
        case .improving: look = .improving
        case .ready:     look = .ready
        }
        compassCard.setState(look, detail: card.detail)
        compassReady = card.isReady
        lastCompassCard = card

        if gpsReady && compassReady {
            completeDismiss()
        }
    }

    private func completeDismiss(seedLocation: CLLocation? = nil) {
        guard !dismissed else { return }
        dismissed = true
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        readinessTimer?.invalidate()
        readinessTimer = nil
        recordCompassOutcome()
        MagneticFieldMonitor.shared.stop(client: Self.fieldMonitorClient)
        onComplete?(seedLocation ?? lastValidLocation, wasSkipped)
    }

    // MARK: - Compass card criterion (#21)

    /// How long the compass card waits for a clean field before letting the launch go on without
    /// one. Long enough to step back from a railing or a car; short enough that a user who cannot
    /// is not stuck. The AR view then shows a "compass disturbed" note while it lasts.
    static let fieldWaitSeconds: TimeInterval = 10.0

    /// What the compass card shows, and whether it lets the screen finish.
    struct CompassCardStatus: Equatable {
        enum Look { case waiting, improving, ready }
        var look: Look
        var detail: String
        /// The compass half of the screen's completion.
        var isReady: Bool
        /// Ready only because the wait for a clean field ran out.
        var proceededWithoutCleanField = false
        /// Held back by the field alone: the heading accuracy itself is good enough.
        var heldByField = false
    }

    /// The compass card's whole criterion, in one place.
    ///
    /// It used to be iOS's `headingAccuracy` alone, which reads 10–12.5° almost always and passed on
    /// the first reading every time, local iron or not. Now the heading must also be steering by the
    /// Earth's field: green only when `MagneticFieldIntegrity` finds the field's strength and dip
    /// matching WMM. A disturbed field holds the card with the instruction to move; after
    /// `fieldWaitSeconds` it lets the launch proceed anyway, without going green. A device that cannot
    /// measure the field keeps the old rule.
    static func compassCardStatus(headingAccuracyDeg: Double,
                                  thresholdDeg: Double,
                                  field: MagneticFieldIntegrity.Verdict,
                                  fieldWaitedSeconds: TimeInterval) -> CompassCardStatus {
        if headingAccuracyDeg < 0 {
            return CompassCardStatus(look: .waiting, detail: "Move phone in a figure-8…", isReady: false)
        }
        if headingAccuracyDeg > thresholdDeg {
            return CompassCardStatus(
                look: .improving,
                detail: String(format: "±%.0f°  (need ≤ %.0f°)  Move in ∞", headingAccuracyDeg, thresholdDeg),
                isReady: false)
        }
        switch field {
        case .clean:
            return CompassCardStatus(look: .ready,
                                     detail: String(format: "±%.0f°  ✓  field checked", headingAccuracyDeg),
                                     isReady: true)
        case .unavailable:
            return CompassCardStatus(look: .ready,
                                     detail: String(format: "±%.0f°  ✓", headingAccuracyDeg),
                                     isReady: true)
        case .disturbed, .pending:
            if fieldWaitedSeconds >= fieldWaitSeconds {
                let detail = field == .disturbed
                    ? "Compass disturbed — continuing anyway"
                    : "Compass field not verified — continuing anyway"
                return CompassCardStatus(look: .improving, detail: detail, isReady: true,
                                         proceededWithoutCleanField: true, heldByField: true)
            }
            let detail = field == .disturbed
                ? "Compass disturbed — move away from metal or cars"
                : String(format: "±%.0f°  checking the magnetic field…", headingAccuracyDeg)
            return CompassCardStatus(look: .improving, detail: detail, isReady: false, heldByField: true)
        }
    }

    /// One line on how the compass card ended, with the field it was judged on.
    private func recordCompassOutcome() {
        let assessment = MagneticFieldMonitor.shared.assessment()
        let card = lastCompassCard
        let outcome: String
        if wasSkipped {
            outcome = "skipped"
        } else if card?.proceededWithoutCleanField == true {
            outcome = "proceeded_unclean"
        } else if card?.isReady == true {
            outcome = "ready"
        } else {
            outcome = "not_ready"
        }
        func value(_ x: Double?, _ decimals: Int) -> String {
            guard let x, x.isFinite else { return "-" }
            return String(format: "%.\(decimals)f", x)
        }
        let accuracy: Double? = bestCompassAccuracy >= 0 ? bestCompassAccuracy : nil
        let waited: Double? = fieldWaitStart.map { CACurrentMediaTime() - $0 }
        let parts: [String] = [
            "outcome=\(outcome)",
            "field=\(assessment.verdict.rawValue)",
            "field_ut=\(value(assessment.measuredUT, 1))",
            "expected_ut=\(value(assessment.expectedUT, 1))",
            "dip=\(value(assessment.dipDeg, 1))",
            "expected_dip=\(value(assessment.expectedDipDeg, 1))",
            "hdg_acc=\(value(accuracy, 1))",
            "waited=\(value(waited, 1))",
        ]
        FlightRecorder.shared.record(event: "calibration_compass", detail: parts.joined(separator: " "))
    }

    // MARK: - Actions

    @objc private func skipTapped() {
        wasSkipped = true
        completeDismiss()
    }
}

// MARK: - CLLocationManagerDelegate

extension CalibrationViewController: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy > 0 else { return }
        if bestGPSAccuracy < 0 || loc.horizontalAccuracy < bestGPSAccuracy {
            bestGPSAccuracy = loc.horizontalAccuracy
        }
        if loc.horizontalAccuracy <= gpsAccuracyThreshold {
            lastValidLocation = loc
        }
        if !earlyLocationSent {
            earlyLocationSent = true
            onEarlyLocation?(loc)
        }
        // In flight there is nothing to calibrate for and the fix it waits for will not come: go,
        // after the early fetch above has been kicked off, as if the sensors had converged — not as a
        // Skip, which would also silence the ground's prompts after landing.
        //
        // The field check (#21) runs only once a fix positively shows the ground; a fix with no valid
        // speed changes nothing, so a flight launch whose first fix is cached never starts it.
        switch CalibrationFlightPolicy.fieldMonitorStep(speedMps: loc.speed) {
        case .stopForFlight:
            MagneticFieldMonitor.shared.setOnGround(false)
            completeDismiss(seedLocation: lastValidLocation ?? loc)
            return
        case .start:
            MagneticFieldMonitor.shared.setOnGround(true)
            MagneticFieldMonitor.shared.start(client: Self.fieldMonitorClient)
        case .leave:
            break
        }
        MagneticFieldMonitor.shared.updatePosition(latitudeDeg: loc.coordinate.latitude,
                                                   longitudeDeg: loc.coordinate.longitude,
                                                   altitudeMeters: loc.altitude)
        updateReadiness()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy > 0 else { return }
        if bestCompassAccuracy < 0 || newHeading.headingAccuracy < bestCompassAccuracy {
            bestCompassAccuracy = newHeading.headingAccuracy
        }
        updateReadiness()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }
}

// MARK: - CalibrationCard

private enum CalibrationState { case waiting, improving, ready }

private final class CalibrationCard: UIView {

    private let iconLabel   = UILabel()
    private let titleLabel  = UILabel()
    private let detailLabel = UILabel()
    private let indicator   = UIView()

    init(icon: String, title: String) {
        super.init(frame: .zero)
        backgroundColor    = UIColor(white: 0.12, alpha: 1)
        layer.cornerRadius = 12
        clipsToBounds      = true

        iconLabel.text = icon
        iconLabel.font = .systemFont(ofSize: 28)
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.text      = title
        titleLabel.font      = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white

        detailLabel.font          = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor     = UIColor(white: 0.65, alpha: 1)
        detailLabel.numberOfLines = 2

        indicator.layer.cornerRadius = 5
        indicator.backgroundColor    = UIColor(white: 0.3, alpha: 1)
        indicator.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis    = .vertical
        textStack.spacing = 3

        let row = UIStackView(arrangedSubviews: [iconLabel, textStack, indicator])
        row.axis      = .horizontal
        row.spacing   = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            indicator.widthAnchor.constraint(equalToConstant: 10),
            indicator.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setState(_ state: CalibrationState, detail: String) {
        detailLabel.text = detail
        UIView.animate(withDuration: 0.3) {
            switch state {
            case .waiting:   self.indicator.backgroundColor = UIColor(white: 0.35, alpha: 1)
            case .improving: self.indicator.backgroundColor = UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 1)
            case .ready:     self.indicator.backgroundColor = UIColor(red: 0.2, green: 0.85, blue: 0.3, alpha: 1)
            }
        }
    }
}

// MARK: - FigureEightInstructionView

private final class FigureEightInstructionView: UIView {

    private let instructionLabel = UILabel()
    private let phoneLayer       = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        instructionLabel.text          = "Move your phone in a figure-8 pattern to calibrate the compass"
        instructionLabel.font          = .systemFont(ofSize: 13, weight: .regular)
        instructionLabel.textColor     = UIColor(white: 0.65, alpha: 1)
        instructionLabel.textAlignment = .center
        instructionLabel.numberOfLines = 2
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(instructionLabel)
        NSLayoutConstraint.activate([
            instructionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            instructionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            instructionLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        phoneLayer.backgroundColor = UIColor(red: 0.1, green: 0.45, blue: 1.0, alpha: 0.9).cgColor
        phoneLayer.cornerRadius    = 6
        phoneLayer.bounds          = CGRect(x: 0, y: 0, width: 18, height: 28)
        layer.addSublayer(phoneLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        phoneLayer.position = CGPoint(x: bounds.midX, y: bounds.midY - 20)
    }

    func startAnimation() {
        phoneLayer.removeAllAnimations()

        let midX = Float(bounds.midX)
        let midY = Float(bounds.midY) - 20
        let rx:   Float = 42
        let ry:   Float = 22

        let steps = 120
        var pathPoints: [CGPoint] = []
        for i in 0...steps {
            let t = Float(i) / Float(steps) * 2 * .pi
            let x = CGFloat(midX + rx * sin(t))
            let y = CGFloat(midY + ry * sin(2 * t))
            pathPoints.append(CGPoint(x: x, y: y))
        }

        let path = UIBezierPath()
        path.move(to: pathPoints[0])
        pathPoints.dropFirst().forEach { path.addLine(to: $0) }

        let pathAnim = CAKeyframeAnimation(keyPath: "position")
        pathAnim.path            = path.cgPath
        pathAnim.duration        = 3.5
        pathAnim.repeatCount     = .infinity
        pathAnim.calculationMode = .paced
        pathAnim.timingFunction  = CAMediaTimingFunction(name: .linear)
        phoneLayer.add(pathAnim, forKey: "figure8")
    }
}
