//
//  CalibrationViewController.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The calibration card. At launch it is a child overlay over the AR view, which is already
//  running underneath — session, location, traffic and seed all start at once (#20) — and it
//  closes when GPS is ready and the world is aligned, on Skip, in flight, or after a timeout
//  (`CalibrationCardPolicy`). Presented on its own (the in-session popup) it keeps the rule below.
//  The popup waits for:
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
}

// MARK: - The launch card over the AR view (#20)

/// When the launch card closes.
///
/// It used to stand in front of everything: the AR view, its session, location, traffic and seed
/// were created only when it closed, so the first targets came up faded and waited out ARKit's
/// start and the seed afterwards (log 849c560a: faded from 1.07 s, `normal` at 2.62 s,
/// `seed_captured` at 3.77 s, all after the card). Now all of that runs under the card from launch,
/// and the card waits for the thing the user is waiting for: targets solid and placed.
enum CalibrationCardPolicy {
    enum CloseReason: String {
        /// GPS ready and the world aligned: the targets underneath are solid and placed.
        case ready
        case skipped
        /// A fix shows the phone flying: skipped, as since #15.
        case inFlight = "in_flight"
        /// Neither came in `timeoutSeconds` — GPS indoors, a seed that never lands — so the card gets
        /// out of the way rather than holding the view hostage.
        case timeout
    }

    static let timeoutSeconds: TimeInterval = 15

    /// Why the card closes now, or nil to keep it up. Skip first, then flight, then ready, then the
    /// timeout. `worldAligned` means aligned **and** tracking normal: that is when the fade lifts.
    static func closeReason(gpsReady: Bool, worldAligned: Bool, skipped: Bool, inFlight: Bool,
                            secondsShown: TimeInterval,
                            timeoutSeconds: TimeInterval = timeoutSeconds) -> CloseReason? {
        if skipped { return .skipped }
        if inFlight { return .inFlight }
        if gpsReady && worldAligned { return .ready }
        if secondsShown.isFinite, secondsShown >= timeoutSeconds { return .timeout }
        return nil
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
    /// whatever check the caller applies next. Nothing else is handed back: the AR view has its
    /// own location from launch (#20).
    var onComplete: ((_ wasSkipped: Bool) -> Void)?

    /// Set by the AR view before the card is added over it at launch (#20): the card then closes by
    /// `CalibrationCardPolicy`, on the world the parent reports through `updateWorld`. Left false
    /// for the in-session popup, which closes when GPS and compass are ready, as before.
    var isOverARView = false
    /// Why the card closed, for the parent's `card_closed` line. Nil until it has.
    private(set) var closeReason: CalibrationCardPolicy.CloseReason?
    /// Over the AR view: whether its world is aligned with tracking normal and a position to place
    /// from, and whether the phone is flying, as the parent last reported.
    private var worldAligned = false
    private var parentSaysInFlight = false
    private var shownAt: TimeInterval = .nan

    /// Seconds since the card was created, for the parent's `card_closed` line.
    var secondsShown: TimeInterval { CACurrentMediaTime() - shownAt }
    /// Whether the GPS row has reached its threshold, for the same line.
    var gpsIsReady: Bool { gpsReady }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        shownAt = CACurrentMediaTime()
        setupUI()
        setupLocation()
    }

    /// The AR view underneath reports its world, about four times a second (#20). Also what drives
    /// the card's timeout.
    func updateWorld(aligned: Bool, inFlight: Bool) {
        worldAligned = aligned
        parentSaysInFlight = inFlight
        evaluateClose()
        // Both rows can be green with the world still lining up, and a card with nothing left to
        // wait for looks stuck. Say what it is waiting on.
        guard !dismissed, isOverARView else { return }
        let subtitle = gpsReady && !aligned ? CalibrationViewController.aligningSubtitle
                                            : CalibrationViewController.calibratingSubtitle
        if subtitleLabel.text != subtitle { subtitleLabel.text = subtitle }
    }

    private static let calibratingSubtitle = "Calibrating sensors for best AR accuracy"
    private static let aligningSubtitle = "Aligning the view…"

    /// Close if the rule for how this card is shown says so.
    private func evaluateClose() {
        guard !dismissed else { return }
        if isOverARView {
            if let reason = CalibrationCardPolicy.closeReason(
                gpsReady: gpsReady, worldAligned: worldAligned, skipped: false,
                inFlight: parentSaysInFlight, secondsShown: secondsShown) {
                completeDismiss(reason: reason)
            }
        } else if gpsReady && compassReady {
            completeDismiss(reason: .ready)
        }
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

        // Compass card
        if bestCompassAccuracy < 0 {
            compassCard.setState(.waiting, detail: "Move phone in a figure-8…")
        } else if bestCompassAccuracy <= compassAccuracyThreshold {
            compassCard.setState(.ready, detail: String(format: "±%.0f°  ✓", bestCompassAccuracy))
            compassReady = true
        } else {
            compassCard.setState(.improving, detail: String(format: "±%.0f°  (need ≤ %.0f°)  Move in ∞", bestCompassAccuracy, compassAccuracyThreshold))
            compassReady = false
        }

        evaluateClose()
    }

    private func completeDismiss(reason: CalibrationCardPolicy.CloseReason) {
        guard !dismissed else { return }
        dismissed = true
        closeReason = reason
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        onComplete?(wasSkipped)
    }

    // MARK: - Actions

    @objc private func skipTapped() {
        wasSkipped = true
        completeDismiss(reason: .skipped)
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
        // In flight there is nothing to calibrate for and the fix it waits for will not come: go, as
        // if the sensors had converged — not as a Skip, which would also silence the ground's prompts
        // after landing.
        if CalibrationFlightPolicy.fixShowsFlight(speedMps: loc.speed) {
            completeDismiss(reason: .inFlight)
            return
        }
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
