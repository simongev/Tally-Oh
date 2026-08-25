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

    /// Airport CSV parsed in the background while the calibration screen is up,
    /// so it's ready by the time the AR view needs it. Deliberately just a data
    /// array with no ConnectionLogic/network/ARSession involvement — an earlier
    /// attempt at preloading ConnectionLogic itself froze the AR camera after
    /// calibration, so this round keeps the preload to this one isolated piece.
    private var preloadedAirports: [Airport]?

    /// Aircraft from one standalone adsb.lol fetch, kicked off as soon as
    /// calibration reports its first (rough) location — well before the AR
    /// view exists. This is a single plain-data network call via ADSBLolClient
    /// directly; no ConnectionLogic instance is created or shared here, so
    /// none of its timers/sockets/Combine publishers cross the AppDelegate/
    /// ARTrafficViewController boundary — deliberately avoiding the structural
    /// change (a shared, lazily-constructed ConnectionLogic) suspected in the
    /// earlier camera-freeze regression.
    private var preloadedAircraft: [Aircraft]?
    private let earlyADSBClient = ADSBLolClient()

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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parsed = AirportDataParser.loadAirportsFromCSV()
            DispatchQueue.main.async {
                self?.preloadedAirports = parsed
            }
        }

        calibration.onEarlyLocation = { [weak self] loc in
            guard let self else { return }
            // Match the radius ConnectionLogic itself would use once the AR view
            // is up (see ConnectionLogic.updateInternetQueryRadius / its 25 NM
            // default), so the preloaded set lines up with what a real fetch
            // would return for the user's configured range.
            let maxDistance = ARVisualizationSettings.load()?.aircraftMaxDistance ?? 20.0
            let radiusNM = max(10, maxDistance * 1.25)
            self.earlyADSBClient.fetchAircraft(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                radiusNM: radiusNM
            ) { [weak self] result in
                guard case .success(let aircraft) = result else { return }
                DispatchQueue.main.async {
                    self?.preloadedAircraft = aircraft
                }
            }
        }

        calibration.onComplete = { [weak self] seedLocation, wasSkipped in
            guard let window = self?.window else { return }
            let arVC = ARTrafficViewController()
            arVC.seedLocation = seedLocation
            // Carried through so the AR view does not immediately re-present a calibration
            // screen the user has just declined.
            arVC.calibrationWasSkipped = wasSkipped
            arVC.preloadedAirports = self?.preloadedAirports
            arVC.preloadedAircraft = self?.preloadedAircraft
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
