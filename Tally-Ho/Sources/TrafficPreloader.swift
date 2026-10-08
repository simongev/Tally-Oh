//
//  TrafficPreloader.swift
//  TallyOh - AR Aviation Traffic Visualization
//
//  The calibration screen's aircraft preload, kept fresh until the AR view takes it (#19).
//
//  The preload used to be one fetch, made at the first rough fix. Since #17 every aircraft keeps
//  its true report time (receipt minus "seen_pos") rather than being restamped on merge, so a
//  preload carried through a ground calibration of half a minute arrived already past the stale
//  threshold, and every target started dashed until the first live fetch replaced it.
//
//  Repeating the fetch at the live interval bounds the hand-over's age at one interval, plus the
//  request's own round trip, plus "seen_pos" — inside the stale threshold — without restamping
//  anything. The report times are the feed's own throughout.
//
//  Main-thread confined: call everything on the main thread, and complete fetches there.
//

import Foundation
import CoreLocation

final class TrafficPreloader {

    /// The live fetch interval, so the hand-over is never older than the AR view's own traffic
    /// would be between two of its fetches.
    static let refreshInterval: TimeInterval = ConnectionLogic.internetFetchInterval

    /// Starts one fetch around `coordinate`; `completion` gets the aircraft, or nil on failure, on
    /// the main thread. Returns a way to cancel the request, if it has one.
    typealias Fetch = (_ coordinate: CLLocationCoordinate2D, _ radiusNM: Double,
                       _ completion: @escaping ([Aircraft]?) -> Void) -> (() -> Void)?

    /// Schedules the repeating refresh. Injected so tests can drive the ticks themselves.
    typealias Schedule = (_ interval: TimeInterval, _ tick: @escaping () -> Void) -> Timer

    /// The freshest preload received, report times untouched. Nil until a fetch succeeds.
    private(set) var aircraft: [Aircraft]?
    private(set) var isHandedOver = false
    /// Whether the refresh timer is running.
    var isRefreshing: Bool { timer != nil }

    private let fetch: Fetch
    private let schedule: Schedule
    private var coordinate: CLLocationCoordinate2D?
    private var radiusNM: Double = 0
    private var timer: Timer?
    private var cancelInFlight: (() -> Void)?
    private var requestInFlight = false
    /// Tags each request, so a callback from a request that is no longer current — cancelled at
    /// hand-over — is ignored.
    private var generation = 0

    init(fetch: @escaping Fetch, schedule: @escaping Schedule = TrafficPreloader.scheduleOnCurrentRunLoop) {
        self.fetch = fetch
        self.schedule = schedule
    }

    deinit {
        timer?.invalidate()
        cancelInFlight?()
    }

    /// The production schedule: a repeating timer on the calling (main) run loop.
    static func scheduleOnCurrentRunLoop(_ interval: TimeInterval, _ tick: @escaping () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in tick() }
    }

    /// Fetch now, then every `refreshInterval` until `handOver`. Does nothing once started or
    /// handed over.
    func start(at coordinate: CLLocationCoordinate2D, radiusNM: Double) {
        guard !isHandedOver, timer == nil else { return }
        self.coordinate = coordinate
        self.radiusNM = radiusNM
        refresh()
        timer = schedule(Self.refreshInterval) { [weak self] in
            self?.refresh()
        }
    }

    /// One fetch — unless one is still running, so results land in the order they were asked for
    /// and an older snapshot can never replace a newer one.
    func refresh() {
        guard !isHandedOver, !requestInFlight, let coordinate else { return }
        requestInFlight = true
        generation += 1
        let request = generation
        let cancel = fetch(coordinate, radiusNM) { [weak self] list in
            self?.receive(list, request: request)
        }
        // A fetch may complete before it returns; only keep the handle if it is still running.
        if requestInFlight && request == generation {
            cancelInFlight = cancel
        }
    }

    /// Stop for good: the timer invalidated, any request still running cancelled, and nothing
    /// accepted afterwards. Returns the freshest preload for the AR view.
    func handOver() -> [Aircraft]? {
        isHandedOver = true
        timer?.invalidate()
        timer = nil
        cancelInFlight?()
        cancelInFlight = nil
        requestInFlight = false
        generation += 1
        return aircraft
    }

    private func receive(_ list: [Aircraft]?, request: Int) {
        guard request == generation, !isHandedOver else { return }
        requestInFlight = false
        cancelInFlight = nil
        // A failed refresh keeps the last good preload: it is older, but still the best there is,
        // and its age is honest.
        guard let list else { return }
        // Each fetch is the whole picture around us, so the newer one replaces the older outright,
        // dropping aircraft that have left.
        aircraft = list
    }
}
