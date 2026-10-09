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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        // The screen stays on for the whole app while it is active (#20): set here at launch and
        // again on every return to active, and never cleared by anything closing — the calibration
        // card, Settings, the map. It used to be owned by the AR view's lifetime.
        application.isIdleTimerDisabled = true

        window = UIWindow(frame: UIScreen.main.bounds)

        // The AR view is the root from launch (#20). It starts its own session, location,
        // ConnectionLogic and seed at once, and puts the calibration card over itself as a child
        // overlay, so the camera, the traffic and the alignment all come up under the card instead
        // of after it.
        //
        // TRIPWIRE: nothing is preloaded here and nothing is handed over between objects. An earlier
        // attempt at preloading ConnectionLogic itself — shared, lazily constructed, handed to the
        // AR view when calibration finished — was followed by the camera freezing after
        // calibration. The plain-data preloads that replaced it (airports parsed here, a standalone
        // adsb.lol fetch, #19) existed only because the AR view did not exist until the card
        // closed. It does now, so they are gone: the AR view constructs its own ConnectionLogic,
        // as it always has, and nothing crosses from this object to it.
        window?.rootViewController = ARTrafficViewController()
        window?.makeKeyAndVisible()

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

    /// Every return to active, not just launch (#20). iOS can clear the flag behind the app's back,
    /// and nothing else sets it again.
    func applicationDidBecomeActive(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
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
