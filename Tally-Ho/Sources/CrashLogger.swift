//
//  CrashLogger.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Captures crashes that produce no .ips file by installing signal and exception
//  handlers that write a short log to UserDefaults before the process terminates.
//  UserDefaults is backed by a memory-mapped plist that survives process death.
//
//  On the next launch, if a log exists, an alert is shown on screen so the crash
//  details can be read directly from the phone — no Xcode or USB required.
//
//  Usage: call CrashLogger.install() as the very first line of
//         AppDelegate.application(_:didFinishLaunchingWithOptions:)
//

import Foundation
import UIKit

// MARK: - CrashLogger

final class CrashLogger {

    private static let udKey = "com.tallyoh.lastCrashLog"

    // MARK: - Install

    static func install() {
        // On next launch, show any crash log from the previous run.
        // Call before setting up any other handlers so the alert fires early.
        showPreviousCrashLogIfNeeded()

        // Uncaught Swift/ObjC exceptions (force-unwrap nil, bad cast, etc.)
        NSSetUncaughtExceptionHandler { exception in
            let msg = """
            EXCEPTION: \(exception.name.rawValue)
            \(exception.reason ?? "no reason")
            \(exception.callStackSymbols.prefix(20).joined(separator: "\n"))
            """
            CrashLogger.save(msg)
        }

        // Low-level signal crashes: EXC_BAD_ACCESS, abort, bus error, etc.
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { signum in
                let name: String
                switch signum {
                case SIGSEGV: name = "SIGSEGV (EXC_BAD_ACCESS)"
                case SIGABRT: name = "SIGABRT (abort/assertion)"
                case SIGBUS:  name = "SIGBUS  (bus error)"
                case SIGILL:  name = "SIGILL  (illegal instruction)"
                case SIGFPE:  name = "SIGFPE  (float exception)"
                default:      name = "SIG\(signum)"
                }
                let msg = "SIGNAL: \(name)\nThread: \(Thread.current)\nisMainThread: \(Thread.isMainThread)"
                CrashLogger.save(msg)
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }

    // MARK: - Save

    /// Writes crash text to UserDefaults. UserDefaults is backed by a
    /// memory-mapped file that the OS flushes to disk even if the process
    /// is killed — making it reliable for crash-time writes.
    static func save(_ text: String) {
        let entry = "[\(Date())] Build \(buildNumber)\n\(text)"
        // Append to any existing log so multiple crashes in one session accumulate.
        let existing = UserDefaults.standard.string(forKey: udKey) ?? ""
        let combined = existing.isEmpty ? entry : existing + "\n\n---\n\n" + entry
        UserDefaults.standard.set(combined, forKey: udKey)
        UserDefaults.standard.synchronize()   // flush immediately before process dies
    }

    // MARK: - Show on next launch

    private static func showPreviousCrashLogIfNeeded() {
        guard let log = UserDefaults.standard.string(forKey: udKey),
              !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        // Clear it now so it doesn't show again next time.
        UserDefaults.standard.removeObject(forKey: udKey)
        UserDefaults.standard.synchronize()

        // Present the alert as soon as a window is available (after a short delay
        // to let the UI settle after launch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: { $0.isKeyWindow })
                      ?? scene.windows.first,
                  let root = window.rootViewController
            else { return }

            let alert = UIAlertController(
                title: "⚠️ Previous Session Crashed",
                message: log,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Copy & Dismiss", style: .default) { _ in
                UIPasteboard.general.string = log
            })
            alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel))

            // Find the topmost presented controller to avoid presentation conflicts.
            var presenter = root
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(alert, animated: true)
        }
    }

    // MARK: - Helpers

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}
