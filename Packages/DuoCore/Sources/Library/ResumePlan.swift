import Foundation

/// Where playback should begin.
public enum Start: Equatable, Sendable {
    case liveEdge
    case position(Int64)
}

/// How to resume a bookmark given what the feed offers now. Never fails: falls back
/// to the default channel, the start, or the live edge.
public struct ResumePlan: Equatable, Sendable {
    public let channelId: Int?
    public let start: Start

    public init(channelId: Int?, start: Start) {
        self.channelId = channelId
        self.start = start
    }

    public static func make(
        bookmark: WatchBookmark,
        availableChannelIds: [Int?],
        defaultChannelId: Int?,
        isLiveNow: Bool,
        durationMs: Int64?
    ) -> ResumePlan {
        let channel = availableChannelIds.contains(bookmark.channelId) ? bookmark.channelId : defaultChannelId

        if isLiveNow || bookmark.live {
            return ResumePlan(channelId: channel, start: .liveEdge)
        }
        var position = bookmark.positionMs
        if position < 0 { position = 0 }
        if let durationMs, durationMs > 0, position >= durationMs { position = 0 }
        return ResumePlan(channelId: channel, start: .position(position))
    }
}

/// What the player finds out once the item is ready: live (no fixed end) or a replay of this length.
public enum Timeline: Equatable, Sendable {
    case live
    case replay(durationMs: Int64)
}

extension Start {
    /// The start to really use, once the item's timeline is known. Never fails:
    /// - now live: the live edge (a saved replay position means nothing on a live stream);
    /// - a live-edge start on a replay: the beginning;
    /// - a position at or past the end (or negative): the beginning;
    /// - otherwise unchanged (a replay of unknown length, `durationMs <= 0`, keeps its position).
    public func resolved(for timeline: Timeline) -> Start {
        switch timeline {
        case .live:
            return .liveEdge
        case .replay(let durationMs):
            switch self {
            case .liveEdge:
                return .position(0)
            case .position(let ms):
                if ms < 0 { return .position(0) }
                if durationMs > 0 && ms >= durationMs { return .position(0) }
                return .position(ms)
            }
        }
    }
}
