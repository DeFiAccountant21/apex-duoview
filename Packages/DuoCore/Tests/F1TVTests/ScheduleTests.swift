import Foundation
import Testing
@testable import F1TV

@Suite struct ScheduleTests {
    static func at(_ hours: Int) -> Date { Date(timeIntervalSince1970: Double(hours) * 3600) }
    static func event(_ hours: Int, live: Bool = false) -> CatalogItem {
        CatalogItem(contentId: hours, title: "Event", subtype: live ? "LIVE" : "", start: at(hours))
    }
    static func weekend(_ events: CatalogItem...) -> WeekendContent { WeekendContent(schedule: events) }

    static let lastStart = 100
    static let race = weekend(event(lastStart - 2), event(lastStart))

    @Test func stillShowingDuringTheLastEvent() {
        #expect(!Self.race.scheduleOver(now: Self.at(Self.lastStart + 1)))
    }

    @Test func goneAfterTheLastEventHasHadTimeToFinish() {
        #expect(Self.race.scheduleOver(now: Self.at(Self.lastStart + 4)))
    }

    @Test func stillShowingWhileAnEventRunsLate() {
        let w = Self.weekend(Self.event(Self.lastStart, live: true))
        #expect(!w.scheduleOver(now: Self.at(Self.lastStart + 4)))
    }

    // Thursday: a show. Friday: two practices. Saturday: a practice, then qualifying and its show.
    static func ev(_ id: Int, _ hours: Int) -> CatalogItem { CatalogItem(contentId: id, title: "Event", start: at(hours)) }
    static let days: [[CatalogItem]] = [
        [ev(1, 10)],
        [ev(2, 34), ev(3, 38)],
        [ev(4, 58), ev(5, 62), ev(6, 63)],
    ]
    static let sessions: Set<Int> = [2, 3, 4, 5]

    static func open(_ today: Int, _ now: Int, _ watched: Int...) -> Int {
        scheduleDayToOpen(days: days, today: today, now: at(now), sessions: sessions) { watched.contains($0) }
    }

    @Test func todayOnceSomethingOfTodaysHasStarted() { #expect(Self.open(1, 35) == 1) }

    @Test func yesterdayWhileTodayHasNotStarted() { #expect(Self.open(2, 50) == 1) }

    @Test func todayIfYesterdaysSessionsAreWatched() { #expect(Self.open(2, 50, 2, 3) == 2) }

    @Test func yesterdayIfOnlySomeOfItIsWatched() { #expect(Self.open(2, 50, 2) == 1) }

    @Test func aDayOfOnlyShowsCountsTheShow() {
        #expect(Self.open(1, 30) == 0)
        #expect(Self.open(1, 30, 1) == 1)
    }

    @Test func theFirstDayHasNothingToFallBackTo() { #expect(Self.open(0, 5) == 0) }

    @Test func outsideTheWeekendItsStartOrEnd() {
        #expect(Self.open(-1, 1) == 0)
        #expect(Self.open(-1, 200) == 2)
    }
}
