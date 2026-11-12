import Foundation

/// A saved place in a piece of content, shown in Recents and resumed on tap.
public struct WatchBookmark: Codable, Sendable, Equatable {
    public var contentId: Int
    public var title: String
    public var picturePath: String?
    public var channelId: Int?
    public var positionMs: Int64
    public var durationMs: Int64
    public var live: Bool
    public var savedAt: Date

    public init(
        contentId: Int,
        title: String,
        picturePath: String?,
        channelId: Int?,
        positionMs: Int64,
        durationMs: Int64,
        live: Bool,
        savedAt: Date
    ) {
        self.contentId = contentId
        self.title = title
        self.picturePath = picturePath
        self.channelId = channelId
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.live = live
        self.savedAt = savedAt
    }
}
