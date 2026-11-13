import Foundation
import Testing
@testable import Library

@Suite struct LiveStartTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Asking "From the start" or "Watch live"

    @Test func liveOnAirMoreThanAMinuteAsks() {
        #expect(LiveStart.asks(isLive: true, sessionStart: Self.now.addingTimeInterval(-61), now: Self.now))
        #expect(LiveStart.asks(isLive: true, sessionStart: Self.now.addingTimeInterval(-3_600), now: Self.now))
    }

    @Test func liveForAMinuteOrLessDoesNotAsk() {
        #expect(!LiveStart.asks(isLive: true, sessionStart: Self.now.addingTimeInterval(-60), now: Self.now))
        #expect(!LiveStart.asks(isLive: true, sessionStart: Self.now.addingTimeInterval(-5), now: Self.now))
        // Scheduled later than now (an early start): nothing to go back to.
        #expect(!LiveStart.asks(isLive: true, sessionStart: Self.now.addingTimeInterval(120), now: Self.now))
    }

    @Test func liveWithUnknownStartAsks() {
        // "Live now" items carry no start: as Android, a live session always offers the choice.
        #expect(LiveStart.asks(isLive: true, sessionStart: nil, now: Self.now))
    }

    @Test func replayNeverAsks() {
        #expect(!LiveStart.asks(isLive: false, sessionStart: Self.now.addingTimeInterval(-3_600), now: Self.now))
        #expect(!LiveStart.asks(isLive: false, sessionStart: nil, now: Self.now))
    }

    // MARK: Where "From the start" begins

    @Test func noSessionStartIsTheEarliestKeptMoment() {
        let t = LiveStart.beginning(seekable: 0...3_000, current: 2_990, currentDate: Self.now, sessionStart: nil)
        #expect(t == 0)
    }

    @Test func noProgramDateIsTheEarliestKeptMoment() {
        let t = LiveStart.beginning(
            seekable: 12...3_000, current: 2_990, currentDate: nil,
            sessionStart: Self.now.addingTimeInterval(-600))
        #expect(t == 12)
    }

    @Test func sessionStartInsideTheWindowIsUsed() {
        // The stream began 50 min ago with a build-up; the session began 30 min ago.
        let t = LiveStart.beginning(
            seekable: 0...3_000, current: 3_000, currentDate: Self.now,
            sessionStart: Self.now.addingTimeInterval(-1_800))
        #expect(t == 1_200)
    }

    @Test func sessionStartBeforeTheWindowIsTheWindowStart() {
        // The stream only keeps the last 20 minutes.
        let t = LiveStart.beginning(
            seekable: 1_800...3_000, current: 3_000, currentDate: Self.now,
            sessionStart: Self.now.addingTimeInterval(-3_600))
        #expect(t == 1_800)
    }

    @Test func sessionStartPastTheLivePointIsTheWindowStart() {
        let t = LiveStart.beginning(
            seekable: 0...3_000, current: 3_000, currentDate: Self.now,
            sessionStart: Self.now.addingTimeInterval(600))
        #expect(t == 0)
    }

    @Test func nonFiniteValuesFallBackToTheWindowStart() {
        let t = LiveStart.beginning(
            seekable: 5...3_000, current: .nan, currentDate: Self.now,
            sessionStart: Self.now.addingTimeInterval(-60))
        #expect(t == 5)
    }
}
