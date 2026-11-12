import Foundation

/// Newest-first list of up to 4 bookmarks, persisted as JSON under "recents".
public final class RecentsStore: @unchecked Sendable {
    static let key = "recents"
    static let capacity = 4
    /// A replay this close to the end counts as finished and is not kept.
    static let finishedToleranceMs: Int64 = 60_000

    private let lock = NSLock()
    private let store: any KeyValueStore
    private let now: @Sendable () -> Date

    public init(store: any KeyValueStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Saves (or moves to the front) a bookmark. A finished replay is removed instead.
    public func save(_ bookmark: WatchBookmark) {
        lock.lock()
        defer { lock.unlock() }
        var items = load()
        items.removeAll { $0.contentId == bookmark.contentId }
        let finished = !bookmark.live
            && bookmark.durationMs > 0
            && bookmark.positionMs >= bookmark.durationMs - Self.finishedToleranceMs
        if !finished {
            var stamped = bookmark
            stamped.savedAt = now()
            items.insert(stamped, at: 0)
            items = Array(items.prefix(Self.capacity))
        }
        persist(items)
    }

    public func all() -> [WatchBookmark] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    public func remove(contentId: Int) {
        lock.lock()
        defer { lock.unlock() }
        var items = load()
        items.removeAll { $0.contentId == contentId }
        persist(items)
    }

    private func load() -> [WatchBookmark] {
        guard let data = store.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([WatchBookmark].self, from: data)) ?? []
    }

    private func persist(_ items: [WatchBookmark]) {
        let data = try? JSONEncoder().encode(items)
        store.set(data, forKey: Self.key)
    }
}
