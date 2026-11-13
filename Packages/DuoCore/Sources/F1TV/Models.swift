import Foundation

/// Something to watch: a session, a live event, highlights or a show; or a series page
/// (a show or documentary bundle, which has a `pageId`).
public struct CatalogItem: Sendable, Hashable, Identifiable {
    public var contentId: Int
    public var title: String
    /// F1 TV's content subtype: REPLAY, RACE HIGHLIGHTS, PRESS CONFERENCE, LIVE, LIVE_EVENT...
    public var subtype: String
    public var contentType: String
    /// F1 TV's first genre: Race, Post-Race Show, Weekend Warm-Up, Tech Talk...
    public var genre: String
    public var picturePath: String?
    public var durationSeconds: Int?
    public var year: Int?
    /// The race weekend it belongs to ("Mexico City Grand Prix"), if any.
    public var meeting: String
    /// When the session starts or ran.
    public var start: Date?
    /// Set for a show or documentary series: F1 TV's page of its episodes.
    public var pageId: Int?

    public init(
        contentId: Int, title: String = "", subtype: String = "", contentType: String = "",
        genre: String = "", picturePath: String? = nil, durationSeconds: Int? = nil,
        year: Int? = nil, meeting: String = "", start: Date? = nil, pageId: Int? = nil
    ) {
        self.contentId = contentId
        self.title = title
        self.subtype = subtype
        self.contentType = contentType
        self.genre = genre
        self.picturePath = picturePath
        self.durationSeconds = durationSeconds
        self.year = year
        self.meeting = meeting
        self.start = start
        self.pageId = pageId
    }

    /// Series pages have a content ID of their own, but may have none: fall back to the page.
    public var id: Int { contentId > 0 ? contentId : -(pageId ?? 0) }

    public var isLive: Bool { subtype == "LIVE" }

    /// A scheduled event that hasn't begun: shown, but not playable yet.
    public func isUpcoming(now: Date) -> Bool {
        guard subtype == "LIVE_EVENT", let start else { return false }
        return start > now
    }

    public func pictureURL(width: Int, height: Int) -> URL? {
        picturePath.map { Endpoints.image(path: $0, width: width, height: height) }
    }

    /// The line under a tile's title. Live: "Live". A scheduled event: its start, such as
    /// "Sun, Nov 8 · 2:00 PM", in `calendar`'s time zone. A race replay's card needs no "Race"
    /// under it. Otherwise the genre, or the subtype in words ("Race highlights"), or "".
    public func subtitle(now: Date, calendar: Calendar) -> String {
        if isLive { return "Live" }
        if subtype == "LIVE_EVENT", let start { return Self.sessionTime(start, calendar: calendar) }
        if genre == "Race" || genre == "Full Race" { return "" }
        if !genre.isEmpty { return genre }
        let words = subtype.lowercased().replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func sessionTime(_ date: Date, calendar: Calendar) -> String {
        // A value-type format style: no shared formatter to cache or lock (Swift 6 safe).
        let style = Date.VerbatimFormatStyle(
            format: "\(weekday: .abbreviated), \(month: .abbreviated) \(day: .defaultDigits) · \(hour: .defaultDigits(clock: .twelveHour, hourCycle: .oneBased)):\(minute: .twoDigits) \(dayPeriod: .standard(.abbreviated))",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: calendar.timeZone,
            calendar: calendar)
        return date.formatted(style)
    }
}

public enum RowTag: Sendable, Equatable {
    /// The current weekend's own row, a mix of replays, highlights and shows.
    case weekend
    /// Popular full race replays from every season.
    case archive
}

/// A titled row of F1 TV's: shows and documentaries come as `posters`.
public struct CatalogRow: Sendable, Equatable {
    public var title: String
    public var items: [CatalogItem]
    public var posters: Bool
    public var tag: RowTag?

    public init(title: String, items: [CatalogItem], posters: Bool = false, tag: RowTag? = nil) {
        self.title = title
        self.items = items
        self.posters = posters
        self.tag = tag
    }
}

/// A race weekend (or test) in the season calendar.
public struct Meeting: Sendable, Hashable, Identifiable {
    public var key: String
    /// Championship round; nil for testing.
    public var round: Int?
    public var name: String
    public var place: String
    public var start: Date
    public var end: Date
    /// F1 TV's page for the weekend, which carries its full schedule.
    public var pageId: Int?
    public var picturePath: String?

    public var id: String { key }

    public init(
        key: String, round: Int? = nil, name: String, place: String, start: Date, end: Date,
        pageId: Int? = nil, picturePath: String? = nil
    ) {
        self.key = key
        self.round = round
        self.name = name
        self.place = place
        self.start = start
        self.end = end
        self.pageId = pageId
        self.picturePath = picturePath
    }
}

public struct WeekendContent: Sendable, Equatable {
    /// Practice, qualifying, sprint and race, in running order.
    public var sessions: [CatalogItem]
    /// Highlights, shows and press conferences.
    public var videos: [CatalogItem]
    /// F1 TV's schedule for the weekend: sessions and live shows, in running order.
    public var schedule: [CatalogItem]
    /// F1 TV's rows under the schedule, in its order.
    public var rows: [CatalogRow]

    public init(
        sessions: [CatalogItem] = [], videos: [CatalogItem] = [],
        schedule: [CatalogItem] = [], rows: [CatalogRow] = []
    ) {
        self.sessions = sessions
        self.videos = videos
        self.schedule = schedule
        self.rows = rows
    }

    /// Nothing live, and the last event of the schedule has had time to finish.
    public func scheduleOver(now: Date) -> Bool {
        guard !schedule.isEmpty else { return true }
        let last = schedule.map { $0.start ?? Date(timeIntervalSince1970: 0) }.max()!
        return !schedule.contains { $0.isLive } && now > last.addingTimeInterval(Self.scheduleTail)
    }

    private static let scheduleTail: TimeInterval = 3 * 60 * 60
}

/// F1 TV's home page: what it features at the top now, and its rows.
public struct HomePage: Sendable, Equatable {
    public var featured: [CatalogItem]
    public var rows: [CatalogRow]

    public init(featured: [CatalogItem] = [], rows: [CatalogRow] = []) {
        self.featured = featured
        self.rows = rows
    }
}

/// A show's or documentary's page: its episodes in rows, usually one per season.
public struct CollectionPage: Sendable, Equatable {
    public var title: String
    public var description: String
    public var picturePath: String?
    public var rows: [CatalogRow]

    public init(title: String = "", description: String = "", picturePath: String? = nil, rows: [CatalogRow] = []) {
        self.title = title
        self.description = description
        self.picturePath = picturePath
        self.rows = rows
    }
}

/// One feed of a session: the main feed, a data channel or a driver's onboard.
public struct Channel: Sendable, Equatable {
    public var id: Int?
    public var isDefault: Bool
    public var isOnboard: Bool
    public var title: String
    public var racingNumber: Int?
    public var driverLastName: String
    public var teamName: String
    public var teamColorHex: String

    public init(
        id: Int?, isDefault: Bool = false, isOnboard: Bool = false, title: String = "",
        racingNumber: Int? = nil, driverLastName: String = "", teamName: String = "", teamColorHex: String = ""
    ) {
        self.id = id
        self.isDefault = isDefault
        self.isOnboard = isOnboard
        self.title = title
        self.racingNumber = racingNumber
        self.driverLastName = driverLastName
        self.teamName = teamName
        self.teamColorHex = teamColorHex
    }

    public var displayTitle: String {
        if isOnboard && !driverLastName.isEmpty {
            if let racingNumber { return "\(racingNumber) \(driverLastName)" }
            return driverLastName
        }
        if !title.isEmpty { return title }
        return id.map { "Channel \($0)" } ?? "Channel"
    }
}

public struct VideoDetail: Sendable, Equatable {
    public var contentId: Int
    public var title: String
    public var channels: [Channel]

    public init(contentId: Int, title: String, channels: [Channel]) {
        self.contentId = contentId
        self.title = title
        self.channels = channels
    }
}

/// What PLAY returns: the stream, and the license URL when the stream is protected.
public struct PlayInfo: Sendable, Equatable {
    public var url: URL
    public var licenseURL: URL?
    public var streamType: String

    public init(url: URL, licenseURL: URL? = nil, streamType: String) {
        self.url = url
        self.licenseURL = licenseURL
        self.streamType = streamType
    }
}
