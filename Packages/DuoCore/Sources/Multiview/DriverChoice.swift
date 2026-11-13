import Foundation
import F1TV

/// The drivers offered for "My driver": the onboard feeds of the latest race F1 TV lists.
public enum DriverChoice {
    /// The race that ran last: the latest start date, or without dates the latest year. The
    /// archive's own order is "most watched", not newest.
    public static func newestRace(_ items: [CatalogItem]) -> CatalogItem? {
        items.max { rank($0) < rank($1) }
    }

    /// The races newest first, by the same rule as `newestRace`; ties keep the list's order.
    public static func newestFirst(_ items: [CatalogItem]) -> [CatalogItem] {
        items.enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra > rb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// One onboard per driver (by last name, ignoring case and accents), by racing number, those
    /// without a number last by name. Onboards without a driver's last name are left out: a pick
    /// is made by last name.
    public static func drivers(in channels: [Channel]) -> [Channel] {
        var seen = Set<String>()
        let onboards = channels.filter { channel in
            let name = channel.driverLastName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard channel.isOnboard, !name.isEmpty else { return false }
            return seen.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted
        }
        return onboards.sorted { a, b in
            switch (a.racingNumber, b.racingNumber) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.driverLastName.localizedStandardCompare(b.driverLastName) == .orderedAscending
            }
        }
    }

    /// Dated items above undated ones; then by date, then by year.
    private static func rank(_ item: CatalogItem) -> (Int, Double, Int) {
        if let start = item.start { return (1, start.timeIntervalSince1970, item.year ?? 0) }
        return (0, 0, item.year ?? 0)
    }
}
