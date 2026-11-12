import Foundation

/// Per-content watched time and finished state, persisted as JSON under "history".
public final class WatchHistory: @unchecked Sendable {
    static let key = "history"
    static let capacity = 300
    /// Gaps between records longer than this are treated as not watching.
    static let maxCountedGapSeconds: TimeInterval = 15

    struct Entry: Codable, Equatable {
        var contentId: Int
        var watchedMs: Int64
        var durationMs: Int64
        var lastPositionMs: Int64
        var lastRecordedAt: Date
    }

    private let lock = NSLock()
    private let store: any KeyValueStore
    private let now: @Sendable () -> Date

    public init(store: any KeyValueStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Records playback progress. Wall-clock time since this content's previous record
    /// counts as watched only when that gap is at most 15 s.
    public func record(contentId: Int, positionMs: Int64, durationMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        var entries = load()
        let current = now()
        if let index = entries.firstIndex(where: { $0.contentId == contentId }) {
            var entry = entries[index]
            let gap = current.timeIntervalSince(entry.lastRecordedAt)
            if gap >= 0 && gap <= Self.maxCountedGapSeconds {
                entry.watchedMs += Int64((gap * 1_000).rounded())
            }
            entry.durationMs = durationMs
            entry.lastPositionMs = positionMs
            entry.lastRecordedAt = current
            entries[index] = entry
        } else {
            entries.append(Entry(
                contentId: contentId,
                watchedMs: 0,
                durationMs: durationMs,
                lastPositionMs: positionMs,
                lastRecordedAt: current
            ))
        }
        if entries.count > Self.capacity {
            entries.sort { $0.lastRecordedAt > $1.lastRecordedAt }
            entries = Array(entries.prefix(Self.capacity))
        }
        persist(entries)
    }

    /// True once watched time reaches 90% of a known (non-zero) duration.
    public func isFinished(_ contentId: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = load().first(where: { $0.contentId == contentId }),
              entry.durationMs > 0 else { return false }
        return entry.watchedMs * 10 >= entry.durationMs * 9
    }

    public func watchedMs(_ contentId: Int) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return load().first(where: { $0.contentId == contentId })?.watchedMs ?? 0
    }

    private func load() -> [Entry] {
        guard let data = store.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func persist(_ entries: [Entry]) {
        let data = try? JSONEncoder().encode(entries)
        store.set(data, forKey: Self.key)
    }
}
