//
//  TrafficPreloaderTests.swift
//  Tally-HoTests
//
//  The calibration screen's aircraft preload (#19). Since #17 a target keeps its true report time,
//  so a preload fetched once at the start of a long ground calibration arrived stale and every
//  target started dashed. These lock in the fix: a preload refreshed within one interval is not
//  stale, a newer preload replaces an older one with its report times untouched, and the refresh
//  stops — timer and request — at hand-over.
//
//  The fetch and the timer source are injected: the feed completes when a test says so, and ticks
//  are driven by hand. The timers are real, installed on the test thread's run loop at an hour's
//  interval so they never fire on their own, which is what lets `isValid` show the invalidation.
//

import Testing
import Foundation
import CoreLocation
@testable import Tally_Ho

struct TrafficPreloaderTests {

    // MARK: - Fakes

    /// Records each request and completes it only when told to.
    private final class FakeFeed {
        struct Request {
            var coordinate: CLLocationCoordinate2D
            var radiusNM: Double
            var completion: ([Aircraft]?) -> Void
        }
        var requests: [Request] = []
        var cancelled: [Int] = []

        func fetch(_ coordinate: CLLocationCoordinate2D, _ radiusNM: Double,
                   _ completion: @escaping ([Aircraft]?) -> Void) -> (() -> Void)? {
            let index = requests.count
            requests.append(Request(coordinate: coordinate, radiusNM: radiusNM, completion: completion))
            return { [weak self] in self?.cancelled.append(index) }
        }

        func complete(_ index: Int, with aircraft: [Aircraft]?) {
            requests[index].completion(aircraft)
        }
    }

    /// Hands out real timers that never fire on their own, and keeps their ticks for the test.
    private final class FakeClock {
        var intervals: [TimeInterval] = []
        var ticks: [() -> Void] = []
        var timers: [Timer] = []

        func schedule(_ interval: TimeInterval, _ tick: @escaping () -> Void) -> Timer {
            intervals.append(interval)
            ticks.append(tick)
            let timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { _ in }
            timers.append(timer)
            return timer
        }

        func tick() {
            ticks.last?()
        }
    }

    private let field = CLLocationCoordinate2D(latitude: 37.6188, longitude: -122.3750)

    private func makePreloader() -> (TrafficPreloader, FakeFeed, FakeClock) {
        let feed = FakeFeed()
        let clock = FakeClock()
        let preloader = TrafficPreloader(
            fetch: { coordinate, radiusNM, completion in feed.fetch(coordinate, radiusNM, completion) },
            schedule: { interval, tick in clock.schedule(interval, tick) })
        return (preloader, feed, clock)
    }

    private func aircraft(_ id: String, reportedAt time: Date) -> Aircraft {
        Aircraft(id: id, callsign: id, latitude: 37.65, longitude: -122.40, altitude: 4_000,
                 track: 90, groundSpeed: 160, verticalRate: 0, lastUpdate: time, source: .internet)
    }

    /// An adsb.lol response, parsed exactly as the app parses it, received at `receivedAt`.
    private func feedResponse(seenPos: Double, receivedAt: Date) throws -> [Aircraft] {
        let json = "{\"ac\":[{\"hex\":\"a1b2c3\",\"lat\":37.65,\"lon\":-122.40,\"alt_baro\":4000,"
            + "\"track\":90.0,\"gs\":160.0,\"seen_pos\":\(seenPos)}]}"
        return try ADSBLolClient.parseResponse(Data(json.utf8), now: receivedAt)
    }

    // MARK: - Fresh enough not to be stale

    @Test func aPreloadWithinOneIntervalIsNotStale() throws {
        let (preloader, feed, _) = makePreloader()
        preloader.start(at: field, radiusNM: 25)
        // Received a full interval before the hand-over, and already 3 s old on the server.
        let received = Date().addingTimeInterval(-TrafficPreloader.refreshInterval)
        feed.complete(0, with: try feedResponse(seenPos: 3, receivedAt: received))

        let handedOver = try #require(preloader.handOver())
        let target = try #require(handedOver.first)
        #expect(!CalculationsLogic.isStale(target))
    }

    @Test func aSingleFetchFromALongCalibrationWasStale() throws {
        // The regression this fixes: one fetch at the first fix, handed over 30 s later.
        let target = try #require(try feedResponse(seenPos: 3, receivedAt: Date().addingTimeInterval(-30)).first)
        #expect(CalculationsLogic.isStale(target))
    }

    @Test func theRefreshIsTheLiveIntervalWithRoomForOneMissedRefresh() {
        #expect(TrafficPreloader.refreshInterval == ConnectionLogic.internetFetchInterval)
        // Even with one refresh failed the hand-over is two intervals old, still short of stale.
        #expect(2 * TrafficPreloader.refreshInterval < CalculationsLogic.staleAircraftAgeSeconds)
    }

    @Test func startFetchesAtOnceThenSchedulesTheRefresh() {
        let (preloader, feed, clock) = makePreloader()
        preloader.start(at: field, radiusNM: 25)
        #expect(feed.requests.count == 1)
        #expect(feed.requests.first?.radiusNM == 25)
        #expect(clock.intervals == [TrafficPreloader.refreshInterval])
        #expect(preloader.isRefreshing)
        // Starting again changes nothing: one timer, one request.
        preloader.start(at: field, radiusNM: 25)
        #expect(feed.requests.count == 1)
        #expect(clock.timers.count == 1)
    }

    // MARK: - Newer replaces older, times untouched

    @Test func anOldPreloadIsReplacedByANewerOne() throws {
        let (preloader, feed, clock) = makePreloader()
        let now = Date()
        let older = [aircraft("OLD", reportedAt: now.addingTimeInterval(-25)),
                     aircraft("BOTH", reportedAt: now.addingTimeInterval(-25))]
        let newer = [aircraft("BOTH", reportedAt: now.addingTimeInterval(-2)),
                     aircraft("NEW", reportedAt: now.addingTimeInterval(-1))]

        preloader.start(at: field, radiusNM: 25)
        feed.complete(0, with: older)
        #expect(preloader.aircraft?.count == 2)

        clock.tick()
        #expect(feed.requests.count == 2)
        feed.complete(1, with: newer)

        let handedOver = try #require(preloader.handOver())
        #expect(Set(handedOver.map(\.id)) == ["BOTH", "NEW"])   // the aircraft that left is gone
        // Report times exactly as the feed gave them: never restamped (#17).
        let both = try #require(handedOver.first { $0.id == "BOTH" })
        #expect(both.lastUpdate == now.addingTimeInterval(-2))
        let new = try #require(handedOver.first { $0.id == "NEW" })
        #expect(new.lastUpdate == now.addingTimeInterval(-1))
    }

    @Test func aFailedRefreshKeepsTheLastGoodPreload() {
        let (preloader, feed, clock) = makePreloader()
        let good = [aircraft("A", reportedAt: Date())]
        preloader.start(at: field, radiusNM: 25)
        feed.complete(0, with: good)
        clock.tick()
        feed.complete(1, with: nil)
        #expect(preloader.aircraft?.map(\.id) == ["A"])
    }

    @Test func noSecondRequestWhileOneIsStillRunning() {
        let (preloader, feed, clock) = makePreloader()
        preloader.start(at: field, radiusNM: 25)
        // The first request has not come back: a tick must not stack a second on top of it, or an
        // older snapshot could land after a newer one.
        clock.tick()
        #expect(feed.requests.count == 1)
        feed.complete(0, with: [])
        clock.tick()
        #expect(feed.requests.count == 2)
    }

    // MARK: - Hand-over

    @Test func theTimerStopsOnHandOver() throws {
        let (preloader, feed, clock) = makePreloader()
        preloader.start(at: field, radiusNM: 25)
        let timer = try #require(clock.timers.first)
        #expect(timer.isValid)

        _ = preloader.handOver()
        #expect(!timer.isValid)
        #expect(!preloader.isRefreshing)
        #expect(preloader.isHandedOver)
        // The request still running was cancelled: no fetch outlives the screen.
        #expect(feed.cancelled == [0])

        // A tick that was already queued does nothing.
        clock.tick()
        #expect(feed.requests.count == 1)
    }

    @Test func aLateResultAfterHandOverIsIgnored() {
        let (preloader, feed, _) = makePreloader()
        preloader.start(at: field, radiusNM: 25)
        #expect(preloader.handOver() == nil)
        // The cancelled request's callback still arrives (URLSession reports the cancellation, or
        // the response had already landed): it must not change anything.
        feed.complete(0, with: [aircraft("LATE", reportedAt: Date())])
        #expect(preloader.aircraft == nil)
    }

    @Test func nothingStartsAfterHandOver() {
        let (preloader, feed, clock) = makePreloader()
        _ = preloader.handOver()
        preloader.start(at: field, radiusNM: 25)
        preloader.refresh()
        #expect(feed.requests.isEmpty)
        #expect(clock.timers.isEmpty)
    }

    @Test func handOverWithoutAnyFixHandsOverNothing() {
        // Skip before the first location: never started, nothing to hand over, nothing to stop.
        let (preloader, feed, clock) = makePreloader()
        #expect(preloader.handOver() == nil)
        #expect(feed.requests.isEmpty)
        #expect(clock.timers.isEmpty)
    }

    @Test func aFlightLaunchHandsOverBeforeTheFirstResult() {
        // In flight the calibration screen goes on the same fix that started the preload: the
        // first request is still out, so the AR view gets no preload — as before — and the request
        // is cancelled rather than left running.
        let (preloader, feed, clock) = makePreloader()
        preloader.start(at: field, radiusNM: 25)
        #expect(preloader.handOver() == nil)
        #expect(feed.cancelled == [0])
        #expect(clock.timers.allSatisfy { !$0.isValid })
    }
}
