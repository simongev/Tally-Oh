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
//

import UIKit
import CoreLocation

// MARK: - CalibrationViewController

class CalibrationViewController: UIViewController {

    // MARK: - Thresholds

    private let gpsAccuracyThreshold:     CLLocationAccuracy         = 10.0   // metres
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

    private var bestGPSAccuracy:     CLLocationAccuracy         = -1
    private var bestCompassAccuracy: CLLocationDirectionAccuracy = -1

    private var lastValidLocation: CLLocation?

    // MARK: - Callback

    var onComplete: ((CLLocation?) -> Void)?

    /// Fired once, the first time any location update arrives — well before
    /// gpsAccuracyThreshold is met and the screen actually dismisses. Lets the
    /// app kick off a network fetch that can overlap with the rest of
    /// calibration instead of waiting until this screen is fully done.
    var onEarlyLocation: ((CLLocation) -> Void)?
    private var earlyLocationSent = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupLocation()
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

        if gpsReady && compassReady {
            completeDismiss()
        }
    }

    private func completeDismiss() {
        guard !dismissed else { return }
        dismissed = true
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        onComplete?(lastValidLocation)
    }

    // MARK: - Actions

    @objc private func skipTapped() {
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
