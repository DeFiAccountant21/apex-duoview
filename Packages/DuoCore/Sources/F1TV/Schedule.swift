import Foundation

/// Which day of a weekend's schedule to open on: today, once something of today's has started.
/// Until then the day before, unless its sessions are all watched (`finished`; shows don't count,
/// and a day of only shows counts them). `today` is -1 outside the weekend: then its start or its end.
public func scheduleDayToOpen(
    days: [[CatalogItem]], today: Int, now: Date, sessions: Set<Int>, finished: (Int) -> Bool
) -> Int {
    func start(_ item: CatalogItem) -> Date { item.start ?? Date(timeIntervalSince1970: 0) }
    guard !days.isEmpty else { return 0 }
    if !days.indices.contains(today) {
        guard let first = days.first?.first else { return 0 }
        return start(first) > now ? 0 : days.count - 1
    }
    if today == 0 || days[today].contains(where: { $0.isLive || start($0) <= now }) { return today }
    let before = days[today - 1]
    let inSessions = before.filter { sessions.contains($0.contentId) }
    let needed = inSessions.isEmpty ? before : inSessions
    return needed.allSatisfy { finished($0.contentId) } ? today : today - 1
}
