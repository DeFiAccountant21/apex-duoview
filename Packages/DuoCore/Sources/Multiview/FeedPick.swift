import Foundation
import F1TV

/// Which feed a multiview slot wants, independent of any one session's channel IDs.
public enum FeedPick: Codable, Hashable, Sendable {
    case worldFeed
    case f1Live
    case tracker
    case data
    case onboard(lastName: String)
    case other(title: String)

    public static let defaultFour: [FeedPick] = [.worldFeed, .f1Live, .tracker, .data]

    public init(_ channel: Channel) {
        let title = channel.title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch title {
        case "INTERNATIONAL": self = .worldFeed
        case "F1 LIVE": self = .f1Live
        case "TRACKER": self = .tracker
        case "DATA": self = .data
        default:
            if channel.isOnboard, !channel.driverLastName.isEmpty {
                self = .onboard(lastName: channel.driverLastName)
            } else {
                self = .other(title: channel.title)
            }
        }
    }

    public func matches(_ channel: Channel) -> Bool {
        switch self {
        case .onboard(let lastName):
            return channel.isOnboard
                && channel.driverLastName.compare(lastName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        case .other(let title):
            return FeedPick(channel) == .other(title: channel.title)
                && channel.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        default:
            return FeedPick(channel) == self
        }
    }

    /// One entry per pick: the first unused channel that matches, or nil. A channel is never used
    /// twice, and channels without an id are never used.
    public static func resolve(_ picks: [FeedPick?], in channels: [Channel]) -> [Channel?] {
        var used = Set<Int>()
        return picks.map { pick in
            guard let pick,
                  let found = channels.first(where: { ch in ch.id.map { !used.contains($0) } == true && pick.matches(ch) }),
                  let id = found.id else { return nil }
            used.insert(id)
            return found
        }
    }
}
