import Foundation
import Testing
@testable import Library

/// Deterministic clock for tests: advance it explicitly.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

@Suite struct WatchHistoryTests {
    @Test func firstRecordAddsNoWatchedTime() {
        let clock = TestClock()
        let history = WatchHistory(store: MemoryStore(), now: clock.now)
        history.record(contentId: 1, positionMs: 50_000, durationMs: 100_000)
        #expect(history.watchedMs(1) == 0)
    }

    @Test func contiguousRecordsAddElapsedTime() {
        let clock = TestClock()
        let history = WatchHistory(store: MemoryStore(), now: clock.now)
        history.record(contentId: 1, positionMs: 0, durationMs: 100_000)
        clock.advance(seconds: 10)
        history.record(contentId: 1, positionMs: 10_000, durationMs: 100_000)
        clock.advance(seconds: 15)
        history.record(contentId: 1, positionMs: 25_000, durationMs: 100_000)
        #expect(history.watchedMs(1) == 25_000)
    }

    @Test func gapOverFifteenSecondsDoesNotCount() {
        let clock = TestClock()
        let history = WatchHistory(store: MemoryStore(), now: clock.now)
        history.record(contentId: 1, positionMs: 0, durationMs: 100_000)
        clock.advance(seconds: 10)
        history.record(contentId: 1, positionMs: 10_000, durationMs: 100_000)
        clock.advance(seconds: 16)
        history.record(contentId: 1, positionMs: 60_000, durationMs: 100_000)
        #expect(history.watchedMs(1) == 10_000)
    }

    @Test func finishedAtNinetyPercent() {
        let clock = TestClock()
        let history = WatchHistory(store: MemoryStore(), now: clock.now)
        history.record(contentId: 1, positionMs: 0, durationMs: 100_000)
        for _ in 0..<8 {
            clock.advance(seconds: 10)
            history.record(contentId: 1, positionMs: 0, durationMs: 100_000)
        }
        // 80 s watched of 100 s: not finished yet.
        #expect(history.watchedMs(1) == 80_000)
        #expect(history.isFinished(1) == false)
        clock.advance(seconds: 10)
        history.record(contentId: 1, positionMs: 0, durationMs: 100_000)
        // 90 s watched of 100 s: finished.
        #expect(history.isFinished(1) == true)
    }

    @Test func unknownContentIsNotFinished() {
        let history = WatchHistory(store: MemoryStore(), now: TestClock().now)
        #expect(history.isFinished(42) == false)
        #expect(history.watchedMs(42) == 0)
    }

    @Test func zeroDurationIsNeverFinished() {
        let clock = TestClock()
        let history = WatchHistory(store: MemoryStore(), now: clock.now)
        history.record(contentId: 1, positionMs: 0, durationMs: 0)
        clock.advance(seconds: 5)
        history.record(contentId: 1, positionMs: 0, durationMs: 0)
        #expect(history.isFinished(1) == false)
    }

    @Test func capsAtThreeHundredDroppingLeastRecentlyRecorded() {
        let clock = TestClock()
        let history = WatchHistory(store: MemoryStore(), now: clock.now)
        // Each item gets 1 s of watched time so eviction is visible in watchedMs.
        for id in 1...301 {
            history.record(contentId: id, positionMs: 0, durationMs: 100_000)
            clock.advance(seconds: 1)
            history.record(contentId: id, positionMs: 1_000, durationMs: 100_000)
            clock.advance(seconds: 1)
        }
        // Id 1 was recorded least recently, so it was dropped; id 2 survives.
        #expect(history.watchedMs(1) == 0)
        #expect(history.watchedMs(2) == 1_000)
        #expect(history.watchedMs(301) == 1_000)

        // Touching id 2 makes id 3 the least recently recorded.
        history.record(contentId: 2, positionMs: 2_000, durationMs: 100_000)
        clock.advance(seconds: 1)
        history.record(contentId: 302, positionMs: 0, durationMs: 100_000)
        #expect(history.watchedMs(3) == 0)
        // The touch came ~600 s after id 2's last record, so it adds no watched time.
        #expect(history.watchedMs(2) == 1_000)
    }

    @Test func dataPersistsThroughNewInstanceOnSameStore() {
        let clock = TestClock()
        let backing = MemoryStore()
        let first = WatchHistory(store: backing, now: clock.now)
        first.record(contentId: 5, positionMs: 0, durationMs: 100_000)
        clock.advance(seconds: 90)
        first.record(contentId: 5, positionMs: 0, durationMs: 100_000)
        // 90 s gap is over 15 s, so nothing counted yet.
        #expect(first.watchedMs(5) == 0)
        clock.advance(seconds: 5)
        first.record(contentId: 5, positionMs: 0, durationMs: 100_000)
        let reopened = WatchHistory(store: backing, now: clock.now)
        #expect(reopened.watchedMs(5) == 5_000)
    }
}
