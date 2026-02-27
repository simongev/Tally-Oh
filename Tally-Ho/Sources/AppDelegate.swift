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

        // Install crash logger FIRST — before any other setup — so signal and
        // exception handlers are in place before the AR session, SceneKit, and
        // network stack start up. On the next launch it prints any captured log
        // to the Xcode console so crashes with no .ips file can be investigated.
        CrashLogger.install()

        // Create window
        window = UIWindow(frame: UIScreen.main.bounds)

        // Show calibration screen first; on completion transition to AR view.
        let calibration = CalibrationViewController()
        window?.rootViewController = calibration
        window?.makeKeyAndVisible()

        calibration.onComplete = { [weak self] seedLocation in
            guard let window = self?.window else { return }
            let arVC = ARTrafficViewController()
            arVC.seedLocation = seedLocation
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

        print("✈️ TallyOh AR Aviation App Started")

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

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state
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

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused
    }
}
