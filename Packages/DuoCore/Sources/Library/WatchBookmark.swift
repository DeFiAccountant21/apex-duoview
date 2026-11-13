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
    /// Saved while watching multiview: Resume opens multiview again. Bookmarks saved before this
    /// existed have no such key and read as single feed.
    public var multiview: Bool

    public init(
        contentId: Int,
        title: String,
        picturePath: String?,
        channelId: Int?,
        positionMs: Int64,
        durationMs: Int64,
        live: Bool,
        savedAt: Date,
        multiview: Bool = false
    ) {
        self.contentId = contentId
        self.title = title
        self.picturePath = picturePath
        self.channelId = channelId
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.live = live
        self.savedAt = savedAt
        self.multiview = multiview
    }

    private enum CodingKeys: String, CodingKey {
        case contentId, title, picturePath, channelId, positionMs, durationMs, live, savedAt, multiview
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try container.decode(Int.self, forKey: .contentId)
        title = try container.decode(String.self, forKey: .title)
        picturePath = try container.decodeIfPresent(String.self, forKey: .picturePath)
        channelId = try container.decodeIfPresent(Int.self, forKey: .channelId)
        positionMs = try container.decode(Int64.self, forKey: .positionMs)
        durationMs = try container.decode(Int64.self, forKey: .durationMs)
        live = try container.decode(Bool.self, forKey: .live)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        multiview = try container.decodeIfPresent(Bool.self, forKey: .multiview) ?? false
    }
}
