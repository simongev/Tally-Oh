//
//  CrashLogger.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  Captures crashes that produce no .ips file (EXC_BAD_ACCESS, watchdog kills,
//  uncaught exceptions) by installing a signal handler and an exception handler
//  that write a plain-text log to the app's Documents directory before the
//  process terminates. On the next launch the log is read and printed to the
//  Xcode console (and stored so the user can retrieve it via Files).
//
//  Usage: call CrashLogger.install() once in AppDelegate.application(_:didFinishLaunchingWithOptions:)
//

import Foundation
import UIKit

// MARK: - CrashLogger

final class CrashLogger {

    static let logFileName = "tally_crash.log"

    private static var logURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(logFileName)
    }

    // MARK: - Install

    /// Call once at app startup. Installs both an uncaught-exception handler and
    /// POSIX signal handlers so crashes that bypass the normal crash reporter are
    /// captured in a file that persists across launches.
    static func install() {
        // Check for a crash log from the previous run first.
        readAndPrintPreviousCrashLog()

        // Uncaught Swift/ObjC exceptions (e.g. force-unwrap of nil, bad cast).
        NSSetUncaughtExceptionHandler { exception in
            let info = """
            === Tally-Ho Uncaught Exception ===
            Date: \(Date())
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "nil")
            Call Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            User Info: \(exception.userInfo ?? [:])
            """
            CrashLogger.write(info)
        }

        // POSIX signals: SIGSEGV (bad access), SIGABRT (abort/assertion),
        // SIGBUS (bus error), SIGILL (illegal instruction), SIGFPE (float exception).
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { signum in
                let name: String
                switch signum {
                case SIGSEGV: name = "SIGSEGV (EXC_BAD_ACCESS)"
                case SIGABRT: name = "SIGABRT (abort / assertion failed)"
                case SIGBUS:  name = "SIGBUS  (bus error)"
                case SIGILL:  name = "SIGILL  (illegal instruction)"
                case SIGFPE:  name = "SIGFPE  (floating point exception)"
                default:      name = "SIG\(signum)"
                }
                let info = """
                === Tally-Ho Signal Crash ===
                Date: \(Date())
                Signal: \(name)
                Thread: \(Thread.current) isMain=\(Thread.isMainThread)
                """
                CrashLogger.write(info)
                // Re-raise so the OS default handler runs (generates a real crash report
                // if conditions allow, and terminates the process).
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }

    // MARK: - Write

    /// Write crash info to the persistent log file. Must be async-signal-safe enough
    /// to run from a signal handler — uses only low-level file I/O.
    static func write(_ text: String) {
        guard let url = logURL else { return }
        let entry = text + "\n\n"
        if let data = entry.data(using: .utf8) {
            // Append so multiple crashes in the same session accumulate.
            if FileManager.default.fileExists(atPath: url.path) {
                if let fh = try? FileHandle(forWritingTo: url) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Read previous log

    private static func readAndPrintPreviousCrashLog() {
        guard let url = logURL,
              FileManager.default.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        print("""

        ╔══════════════════════════════════════════════╗
        ║   TALLY-HO CRASH LOG FROM PREVIOUS SESSION   ║
        ╚══════════════════════════════════════════════╝
        \(contents)
        ══════════════════════════════════════════════
        Log saved at: \(url.path)
        ══════════════════════════════════════════════

        """)

        // Archive and clear so it doesn't print again next launch.
        let archiveURL = url.deletingLastPathComponent()
            .appendingPathComponent("tally_crash_archive_\(Int(Date().timeIntervalSince1970)).log")
        try? FileManager.default.moveItem(at: url, to: archiveURL)
    }

    // MARK: - Log path helper (for Settings display)

    static var logDirectoryPath: String {
        logURL?.deletingLastPathComponent().path ?? "unavailable"
    }
}
