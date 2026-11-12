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
