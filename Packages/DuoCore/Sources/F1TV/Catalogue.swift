import Foundation

/// F1 TV's catalogue reads: live now, the calendar, weekends, the home page, collections, the
/// archive and a video's feeds. Reads are authorized once signed in and anonymous before.
public struct Catalogue: Sendable {
    private let session: F1TVSession

    public init(session: F1TVSession) {
        self.session = session
    }

    public func liveNow() async throws -> [CatalogItem] {
        let (tier, group) = try await tierAndGroup()
        let json = try await get("EVENTS/LIVENOW/\(tier)/\(group)", version: "1.0")
        return Parsers.liveNow(json)
    }

    public func calendar(season: Int) async throws -> [Meeting] {
        let json = try await search([
            ("orderBy", "meeting_End_Date"), ("sortOrder", "asc"),
            ("filter_objectSubtype", "Meeting"), ("filter_season", "\(season)"),
            ("filter_orderByFom", "Y"), ("maxResults", "100"),
        ])
        return Parsers.calendar(json)
    }

    /// A weekend's sessions and videos from its page, or from a `filter_MeetingKey` search when
    /// the page is missing, fails or has no schedule or rows.
    public func weekend(_ meeting: Meeting) async throws -> WeekendContent {
        if let pageId = meeting.pageId {
            do {
                let (tier, group) = try await tierAndGroup()
                let json = try await get("PAGE/\(pageId)/\(tier)/\(group)", version: "2.0")
                let content = Parsers.weekend(json, meetingName: meeting.name)
                if !(content.sessions.isEmpty && content.videos.isEmpty
                    && content.schedule.isEmpty && content.rows.isEmpty) {
                    return content
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Any other failure of the page: the search below has what can be watched.
            }
        }
        let json = try await search([
            ("orderBy", "meeting_End_Date"), ("sortOrder", "asc"),
            ("filter_MeetingKey", meeting.key), ("filter_orderByFom", "Y"), ("maxResults", "100"),
        ])
        return Parsers.weekend(json, meetingName: meeting.name)
    }

    public func home() async throws -> HomePage {
        let (tier, group) = try await tierAndGroup()
        return Parsers.home(try await get("PAGE/395/\(tier)/\(group)", version: "2.0"))
    }

    public func collection(pageId: Int) async throws -> CollectionPage {
        let (tier, group) = try await tierAndGroup()
        return Parsers.collection(try await get("PAGE/\(pageId)/\(tier)/\(group)", version: "2.0"))
    }

    /// The most watched full race replays from every season.
    public func archiveRaces() async throws -> [CatalogItem] {
        Parsers.search(try await search([
            ("filter_Series", "Formula 1"), ("filter_genres", "Full Race,Race"),
            ("filter_objectSubtype", "Replay"), ("filter_objectType", "Video"),
            ("orderBy", "shortPeriod"), ("sortOrder", "desc"), ("maxResults", "100"),
        ]))
    }

    /// A season's full race replays.
    public func raceReplays(season: Int) async throws -> [CatalogItem] {
        Parsers.search(try await search([
            ("filter_Series", "Formula 1"), ("filter_genres", "Full Race,Race"),
            ("filter_objectSubtype", "Replay"), ("filter_objectType", "Video"),
            ("filter_season", "\(season)"), ("maxResults", "100"),
        ]))
    }

    /// A season from before F1 TV's race weekends: a flat set of videos, replays first.
    public func seasonVideos(season: Int) async throws -> [CatalogItem] {
        Parsers.search(try await search([("filter_season", "\(season)"), ("maxResults", "100")]))
    }

    public func video(contentId: Int) async throws -> VideoDetail {
        let (tier, group) = try await tierAndGroup()
        let json = try await session.getJSON(
            path: "CONTENT/VIDEO/\(contentId)/\(tier)/\(group)", version: .video,
            platform: .webHLS, authorized: await session.isSignedIn)
        return try Parsers.video(json)
    }

    // MARK: Internals

    private func tierAndGroup() async throws -> (String, Int) {
        try await session.prepare()
        guard let location = await session.location else {
            throw F1TVError.badResponse("No tier or group yet")
        }
        return (location.tier, location.groupId)
    }

    private func get(_ path: String, version: String, query: [(String, String)] = []) async throws -> JSONValue {
        try await session.getJSON(
            path: path, version: .fixed(version), platform: .webHLS,
            query: query, authorized: await session.isSignedIn)
    }

    private func search(_ query: [(String, String)]) async throws -> JSONValue {
        let (tier, group) = try await tierAndGroup()
        return try await get("PAGE/SEARCH/VOD/\(tier)/\(group)", version: "2.0", query: query)
    }
}
