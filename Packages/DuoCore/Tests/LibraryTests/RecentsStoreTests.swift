import Foundation
import Testing
@testable import Library

private func bookmark(
    _ id: Int,
    positionMs: Int64 = 1_000,
    durationMs: Int64 = 3_600_000,
    live: Bool = false
) -> WatchBookmark {
    WatchBookmark(
        contentId: id,
        title: "Item \(id)",
        picturePath: nil,
        channelId: nil,
        positionMs: positionMs,
        durationMs: durationMs,
        live: live,
        savedAt: Date(timeIntervalSince1970: 0)
    )
}

@Suite struct RecentsStoreTests {
    @Test func keepsNewestFourNewestFirst() {
        let store = RecentsStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 100) })
        for id in 1...5 { store.save(bookmark(id)) }
        #expect(store.all().map(\.contentId) == [5, 4, 3, 2])
    }

    @Test func resavingMovesToFrontWithoutDuplicate() {
        let store = RecentsStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 100) })
        store.save(bookmark(1))
        store.save(bookmark(2))
        store.save(bookmark(3))
        store.save(bookmark(1, positionMs: 5_000))
        #expect(store.all().map(\.contentId) == [1, 3, 2])
        #expect(store.all().first?.positionMs == 5_000)
    }

    @Test func replayNearEndIsRemovedInsteadOfStored() {
        let store = RecentsStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 100) })
        store.save(bookmark(1))
        store.save(bookmark(2, positionMs: 3_600_000 - 60_000, durationMs: 3_600_000))
        #expect(store.all().map(\.contentId) == [1])
    }

    @Test func replayNearEndRemovesExistingEntry() {
        let store = RecentsStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 100) })
        store.save(bookmark(1))
        store.save(bookmark(1, positionMs: 3_599_999, durationMs: 3_600_000))
        #expect(store.all().isEmpty)
    }

    @Test func liveItemIsKeptAtAnyPosition() {
        let store = RecentsStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 100) })
        store.save(bookmark(7, positionMs: 3_599_999, durationMs: 3_600_000, live: true))
        #expect(store.all().map(\.contentId) == [7])
    }

    @Test func zeroDurationIsStoredNormally() {
        let store = RecentsStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 100) })
        store.save(bookmark(9, positionMs: 0, durationMs: 0))
        #expect(store.all().map(\.contentId) == [9])
    }

    @Test func removeDeletesByContentId() {
        let store = RecentsStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 100) })
        store.save(bookmark(1))
        store.save(bookmark(2))
        store.remove(contentId: 1)
        #expect(store.all().map(\.contentId) == [2])
    }

    @Test func saveStampsSavedAtFromClock() {
        let store = RecentsStore(store: MemoryStore(), now: { Date(timeIntervalSince1970: 1_234) })
        store.save(bookmark(1))
        #expect(store.all().first?.savedAt == Date(timeIntervalSince1970: 1_234))
    }

    @Test func dataPersistsThroughNewInstanceOnSameStore() {
        let backing = MemoryStore()
        RecentsStore(store: backing, now: { Date(timeIntervalSince1970: 100) }).save(bookmark(4))
        let reopened = RecentsStore(store: backing, now: { Date(timeIntervalSince1970: 100) })
        #expect(reopened.all().map(\.contentId) == [4])
    }
}
