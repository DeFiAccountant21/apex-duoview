import Foundation
import Testing
@testable import F1TV

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name).json"))
}

private let empty = #"{"resultObj":{"containers":[]}}"#

@Suite struct CatalogueTests {
    /// Signed-out session on tier ANONYMOUS / group 1 (so paths use `A`).
    static func signedOut() async throws -> (FakeHTTPClient, F1TVSession, Catalogue) {
        let f = await SessionTests.fake()
        let s = F1TVSession(http: f)
        try await s.prepare()
        return (f, s, Catalogue(session: s))
    }

    static func signedIn() async throws -> (FakeHTTPClient, F1TVSession, Catalogue) {
        let f = await SessionTests.fake(tier: "PREMIUM", group: 5)
        let s = F1TVSession(http: f)
        try await s.prepare()
        _ = try await s.signIn(token: "TOK")
        return (f, s, Catalogue(session: s))
    }

    static func last(_ f: FakeHTTPClient) async -> HTTPRequest { await f.requests.last! }

    @Test func liveNowPathAndHeaders() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/EVENTS/LIVENOW/ANONYMOUS/1", body: try fixtureData("livenow"))
        _ = try await c.liveNow()
        let r = await Self.last(f)
        #expect(r.url.path == "/1.0/A/ENG/WEB_HLS/ALL/EVENTS/LIVENOW/ANONYMOUS/1")
        #expect(r.url.query == nil)
        #expect(r.headers["ascendontoken"] == nil)
    }

    @Test func signedInReadsAreAuthorizedAndUseRPath() async throws {
        let (f, _, c) = try await Self.signedIn()
        await f.respond(pathSuffix: "/EVENTS/LIVENOW/PREMIUM/5", body: try fixtureData("livenow"))
        _ = try await c.liveNow()
        let r = await Self.last(f)
        #expect(r.url.path == "/1.0/R/ENG/WEB_HLS/ALL/EVENTS/LIVENOW/PREMIUM/5")
        #expect(r.headers["ascendontoken"] == "TOK")
        #expect(r.headers["entitlementtoken"] == "ENT")
    }

    @Test func calendarQuery() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/PAGE/SEARCH/VOD/ANONYMOUS/1", body: try fixtureData("calendar-2026"))
        let meetings = try await c.calendar(season: 2026)
        #expect(!meetings.isEmpty)
        let r = await Self.last(f)
        #expect(r.url.path == "/2.0/A/ENG/WEB_HLS/ALL/PAGE/SEARCH/VOD/ANONYMOUS/1")
        #expect(r.url.query == "orderBy=meeting_End_Date&sortOrder=asc&filter_objectSubtype=Meeting&filter_season=2026&filter_orderByFom=Y&maxResults=100")
    }

    @Test func archiveAndReplayQueries() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/PAGE/SEARCH/VOD/ANONYMOUS/1", body: try fixtureData("archive-races"))
        let items = try await c.archiveRaces()
        #expect(!items.isEmpty)
        #expect(await Self.last(f).url.query == "filter_Series=Formula%201&filter_genres=Full%20Race,Race&filter_objectSubtype=Replay&filter_objectType=Video&orderBy=shortPeriod&sortOrder=desc&maxResults=100")
        _ = try await c.raceReplays(season: 2025)
        #expect(await Self.last(f).url.query == "filter_Series=Formula%201&filter_genres=Full%20Race,Race&filter_objectSubtype=Replay&filter_objectType=Video&filter_season=2025&maxResults=100")
    }

    @Test func seasonVideosQuery() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/PAGE/SEARCH/VOD/ANONYMOUS/1", body: try fixtureData("season-1998"))
        let items = try await c.seasonVideos(season: 1998)
        #expect(!items.isEmpty)
        #expect(await Self.last(f).url.query == "filter_season=1998&maxResults=100")
    }

    @Test func homeAndCollectionPaths() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/PAGE/395/ANONYMOUS/1", body: try fixtureData("home"))
        _ = try await c.home()
        #expect(await Self.last(f).url.path == "/2.0/A/ENG/WEB_HLS/ALL/PAGE/395/ANONYMOUS/1")
        await f.respond(pathSuffix: "/PAGE/1234/ANONYMOUS/1", json: empty)
        _ = try await c.collection(pageId: 1234)
        #expect(await Self.last(f).url.path == "/2.0/A/ENG/WEB_HLS/ALL/PAGE/1234/ANONYMOUS/1")
    }

    static let meeting = Meeting(
        key: "1297", round: 21, name: "São Paulo Grand Prix", place: "Interlagos",
        start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1), pageId: 4087, picturePath: nil)

    @Test func weekendUsesPage() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/PAGE/4087/ANONYMOUS/1", body: try fixtureData("weekend-saopaulo"))
        let w = try await c.weekend(Self.meeting)
        #expect(!w.sessions.isEmpty)
        #expect(w.sessions.allSatisfy { $0.meeting == "São Paulo Grand Prix" })
        let paths = await f.requests.map(\.url.path).filter { $0.contains("/PAGE/") }
        #expect(paths == ["/2.0/A/ENG/WEB_HLS/ALL/PAGE/4087/ANONYMOUS/1"])
    }

    @Test func weekendFallsBackOnServerError() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/PAGE/4087/ANONYMOUS/1", status: 500, json: "{}")
        await f.respond(pathSuffix: "/PAGE/SEARCH/VOD/ANONYMOUS/1", body: try fixtureData("weekend-saopaulo"))
        _ = try await c.weekend(Self.meeting)
        let r = await Self.last(f)
        #expect(r.url.path == "/2.0/A/ENG/WEB_HLS/ALL/PAGE/SEARCH/VOD/ANONYMOUS/1")
        #expect(r.url.query == "orderBy=meeting_End_Date&sortOrder=asc&filter_MeetingKey=1297&filter_orderByFom=Y&maxResults=100")
    }

    @Test func weekendFallsBackOnEmptySchedule() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/PAGE/4087/ANONYMOUS/1", json: empty)
        await f.respond(pathSuffix: "/PAGE/SEARCH/VOD/ANONYMOUS/1", json: empty)
        _ = try await c.weekend(Self.meeting)
        #expect(await Self.last(f).url.query?.contains("filter_MeetingKey=1297") == true)
    }

    @Test func weekendWithoutPageSearchesDirectly() async throws {
        let (f, _, c) = try await Self.signedOut()
        await f.respond(pathSuffix: "/PAGE/SEARCH/VOD/ANONYMOUS/1", json: empty)
        var m = Self.meeting
        m.pageId = nil
        _ = try await c.weekend(m)
        let pages = await f.requests.map(\.url.path).filter { $0.contains("/PAGE/") }
        #expect(pages == ["/2.0/A/ENG/WEB_HLS/ALL/PAGE/SEARCH/VOD/ANONYMOUS/1"])
    }

    @Test func videoUsesVideoVersionAndEntitlement() async throws {
        let (f, _, c) = try await Self.signedIn()
        await f.respond(pathSuffix: "/CONTENT/VIDEO/1000010431/PREMIUM/5", body: try fixtureData("video-1000010431-WEB_HLS"))
        let v = try await c.video(contentId: 1000010431)
        #expect(v.contentId == 1000010431)
        let r = await Self.last(f)
        #expect(r.url.path == "/4.5/R/ENG/WEB_HLS/ALL/CONTENT/VIDEO/1000010431/PREMIUM/5")
        #expect(r.headers["entitlementtoken"] == "ENT")
    }

    @Test func videoWithNoContainerSurfacesBadResponse() async throws {
        let (f, _, c) = try await Self.signedIn()
        await f.respond(pathSuffix: "/CONTENT/VIDEO/9/PREMIUM/5", json: empty)
        await #expect(throws: F1TVError.self) { try await c.video(contentId: 9) }
    }
}
