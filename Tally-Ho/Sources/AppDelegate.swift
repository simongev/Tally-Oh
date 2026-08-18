//
//  AppDelegate.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Main application delegate
//

import UIKit

// MARK: - App-lifecycle notification names

extension Notification.Name {
    /// Posted by AppDelegate when the app enters the background.
    /// ARTrafficViewController observes this to pause the ARSession so iOS
    /// does not issue a background-CPU watchdog kill.
    static let appDidBackground  = Notification.Name("com.tally-ho.appDidBackground")
    /// Posted by AppDelegate when the app is about to return to the foreground.
    static let appWillForeground = Notification.Name("com.tally-ho.appWillForeground")
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    // Started immediately at launch (alongside the calibration screen)
    // rather than waiting for ARTrafficViewController to be created, so
    // aircraft/airport data is already loading — and ideally ready — by
    // the time calibration finishes and the AR view appears.
    private let sharedConnectionLogic = ConnectionLogic()
    private var preloadedAirports: [Airport]?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // Create window
        window = UIWindow(frame: UIScreen.main.bounds)

        // Show calibration screen first; on completion transition to AR view.
        let calibration = CalibrationViewController()
        window?.rootViewController = calibration
        window?.makeKeyAndVisible()

        // ADS-B doesn't need a location fix at all — start listening right away.
        sharedConnectionLogic.startListening()

        // Airport CSV load doesn't need a location either — kick it off now.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let parsed = AirportDataParser.loadAirportsFromCSV()
            DispatchQueue.main.async { self?.preloadedAirports = parsed }
        }

        // As soon as calibration has any location fix, start the internet
        // traffic fetch — no need to wait for calibration's stricter
        // GPS/compass "ready" thresholds just to begin prefetching.
        calibration.onEarlyLocation = { [weak self] loc in
            self?.sharedConnectionLogic.updateLocation(
                loc.coordinate,
                altitudeFeet: loc.altitude * CalculationsLogic.metersToFeet
            )
        }

        calibration.onComplete = { [weak self] seedLocation in
            guard let self, let window = self.window else { return }
            let arVC = ARTrafficViewController()
            arVC.seedLocation = seedLocation
            arVC.preloadedConnectionLogic = self.sharedConnectionLogic
            arVC.preloadedAirports = self.preloadedAirports
            // Crossfade from calibration to AR
            UIView.transition(
                with: window,
                duration: 0.5,
                options: .transitionCrossDissolve,
                animations: { window.rootViewController = arVC },
                completion: nil
            )
        }

        // Configure appearance
        configureAppearance()

        return true
    }

    private func configureAppearance() {
        // Configure navigation bar appearance if needed
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // ARKit is not permitted to run in the background. If iOS backgrounds the app
        // without going through the normal view lifecycle (e.g. during a phone call,
        // Siri overlay, or rapid app switching), the ARSession will keep firing its
        // 60 Hz render callback, and iOS will issue a watchdog kill after a few seconds
        // with no crash report generated. Posting this notification lets the active
        // ARTrafficViewController pause its session from wherever it currently lives.
        NotificationCenter.default.post(name: .appDidBackground, object: nil)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Matching resume — lets ARTrafficViewController restart the session when
        // the user returns to the app, even if viewWillAppear is not called.
        NotificationCenter.default.post(name: .appWillForeground, object: nil)
    }


}
