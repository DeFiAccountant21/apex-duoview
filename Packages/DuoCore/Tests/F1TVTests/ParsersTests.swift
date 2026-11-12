import Foundation
import Testing
@testable import F1TV

private func fixture(_ name: String) throws -> JSONValue {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name).json")
    return try JSONValue.parse(Data(contentsOf: url))
}

private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private let now = Date(timeIntervalSince1970: 1_794_526_278)  // 2026-11-12, the fixtures' recording time

@Suite struct ParsersTests {
    // MARK: Video

    @Test func videoHasDefaultAndOnboardChannels() throws {
        let v = Parsers.video(try fixture("video-1000010431-WEB_DASH"))
        #expect(v.contentId == 1000010431)
        #expect(v.title == "2026 São Paulo Grand Prix")
        #expect(v.channels.count == 6)
        let main = v.channels.first { $0.isDefault }
        #expect(main?.id == 1033)
        #expect(main?.displayTitle == "F1 LIVE")
        #expect(main?.isOnboard == false)
        let nor = try #require(v.channels.first { $0.id == 1016 })
        #expect(nor.isOnboard)
        #expect(nor.racingNumber == 1)
        #expect(nor.driverLastName == "Norris")
        #expect(nor.teamName == "McLaren")
        #expect(nor.teamColorHex == "#FF8000")
        #expect(nor.displayTitle == "1 Norris")
    }

    @Test func videoWithNoStreamsGetsMainFeed() {
        let v = Parsers.video(json(#"{"resultObj":{"containers":[{"metadata":{"contentId":7,"title":"X"}}]}}"#))
        #expect(v.channels == [Channel(id: nil, isDefault: true, title: "Main feed")])
        #expect(v.channels[0].displayTitle == "Main feed")
    }

    @Test func channelDisplayTitleFallbacks() {
        #expect(Channel(id: 5).displayTitle == "Channel 5")
        #expect(Channel(id: 5, title: "DATA").displayTitle == "DATA")
    }

    // MARK: Calendar

    @Test func calendarFixtureParses() throws {
        let meetings = Parsers.calendar(try fixture("calendar-2026"))
        #expect(meetings.count == 6)
        let aus = try #require(meetings.first { $0.name == "Australian Grand Prix" })
        #expect(aus.round == 1)
        #expect(aus.key == "1279")
        #expect(aus.place == "Melbourne")
        #expect(aus.pageId == 12292)
        #expect(aus.picturePath != nil)
        #expect(aus.start == Date(timeIntervalSince1970: 1_772_755_200))  // 2026-03-06T00:00:00Z
        #expect(aus.end > aus.start)
        // Testing has no round.
        let testing = try #require(meetings.first { $0.name == "Pre-Season Testing" })
        #expect(testing.round == nil)
    }

    @Test func calendarSkipsHiddenAndKeepsSaoPaulo() {
        let page = json("""
        {"resultObj":{"containers":[
          {"metadata":{"pictureUrl":null,"emfAttributes":{"MeetingKey":"1299","Meeting_Name":"São Paulo Grand Prix",
            "Circuit_Short_Name":"","Meeting_Country_Name":"Brazil","IsTestEvent":"false","Championship_Meeting_Ordinal":"20",
            "Meeting_Start_Date":"2026-11-06T00:00:00-03:00","Meeting_End_Date":"2026-11-08T23:59:59-03:00","PageID":null,"Diplay_In_Schedule":true}}},
          {"metadata":{"emfAttributes":{"MeetingKey":"1","Meeting_Name":"Hidden","Diplay_In_Schedule":"false"}}},
          {"metadata":{"emfAttributes":{"MeetingKey":"2","Meeting_Name":"Hidden bool","Diplay_In_Schedule":false}}},
          {"metadata":{"emfAttributes":{"MeetingKey":"","Meeting_Name":"No key"}}},
          {"nonsense":true}
        ]}}
        """)
        let meetings = Parsers.calendar(page)
        #expect(meetings.map(\.name) == ["São Paulo Grand Prix"])
        #expect(meetings[0].round == 20)
        #expect(meetings[0].place == "Brazil")
        #expect(meetings[0].pageId == nil)
        #expect(meetings[0].picturePath == nil)
    }

    // MARK: Weekend

    @Test func weekendFixtureHasOrderedSchedule() throws {
        let w = Parsers.weekend(try fixture("weekend-saopaulo"), now: now)
        #expect(!w.schedule.isEmpty)
        let starts = w.schedule.compactMap(\.start)
        #expect(starts == starts.sorted())
        #expect(!w.sessions.isEmpty)
        #expect(!w.videos.isEmpty)
        #expect(!w.rows.isEmpty)
        #expect(w.rows.allSatisfy { !$0.items.isEmpty && !$0.title.isEmpty })
        #expect(w.schedule.allSatisfy { $0.meeting == "São Paulo Grand Prix" })
        let ids = (w.sessions + w.videos).map(\.contentId)
        #expect(Set(ids).count == ids.count)
    }

    @Test func weekendMeetingNameOverride() throws {
        let w = Parsers.weekend(try fixture("weekend-saopaulo"), meetingName: "Custom", now: now)
        #expect(w.schedule.allSatisfy { $0.meeting == "Custom" })
    }

    @Test func weekendFallsBackToSearchContainers() throws {
        let w = Parsers.weekend(try fixture("season-1998"), now: now)
        #expect(w.sessions.isEmpty)
        #expect(!w.videos.isEmpty)
        #expect(w.schedule.isEmpty)
    }

    @Test func weekendVideosOrder() {
        func tile(_ id: Int, _ subtype: String, _ start: Int?) -> String {
            let emf = start.map { #","emfAttributes":{"sessionStartDate":\#($0)}"# } ?? ""
            return #"{"metadata":{"contentId":\#(id),"contentType":"VIDEO","contentSubtype":"\#(subtype)","title":"t\#(id)"\#(emf)}}"#
        }
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let tiles = [
            tile(1, "REPLAY", nowMs - 2000), tile(2, "REPLAY", nowMs - 1000), tile(3, "PRESS CONFERENCE", nil),
            tile(4, "LIVE_EVENT", nowMs + 2000), tile(5, "LIVE_EVENT", nowMs + 1000), tile(6, "LIVE", nowMs - 500),
        ].joined(separator: ",")
        let w = Parsers.weekend(json(#"{"resultObj":{"containers":[\#(tiles)]}}"#), now: now)
        #expect(w.videos.map(\.contentId) == [6, 2, 1, 3, 5, 4])
    }

    // MARK: Home

    @Test func homeRowsFiltered() throws {
        let home = Parsers.home(try fixture("home"))
        #expect(!home.rows.isEmpty)
        for row in home.rows {
            #expect(!row.title.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!row.title.localizedCaseInsensitiveContains("Survey"))
            #expect(row.title != "My List")
            #expect(!row.items.isEmpty)
        }
        let shows = try #require(home.rows.first { $0.title == "Shows" })
        #expect(shows.posters)
        #expect(shows.items.allSatisfy { $0.pageId != nil })
        let weekend = try #require(home.rows.first { $0.tag == .weekend })
        #expect(weekend.title == "2026 São Paulo Grand Prix")
        // The recorded home uses a "hero" layout, treated like "super_hero".
        #expect(home.featured.map(\.contentId).contains(1000079724))
    }

    @Test func homeFeaturedFromSuperHero() {
        let page = json("""
        {"resultObj":{"containers":[{"layout":"super_hero","metadata":{"label":""},
          "retrieveItems":{"uriOriginal":"/x","resultObj":{"containers":[
            {"metadata":{"contentId":11,"contentType":"VIDEO","title":"A"}},
            {"metadata":{"contentId":12,"contentType":"BUNDLE"},"actions":[{"uri":"/2.0/R/ENG/WEB_HLS/ALL/PAGE/9298/PREMIUM/5"}]}
          ]}}}]}}
        """)
        let home = Parsers.home(page)
        #expect(home.featured.map(\.contentId) == [11])
        #expect(home.rows.isEmpty)
    }

    @Test func homeRowTags() {
        func row(_ label: String, _ uri: String, _ layout: String = "horizontal_thumbnail") -> String {
            #"{"layout":"\#(layout)","metadata":{"label":"\#(label)"},"retrieveItems":{"uriOriginal":"\#(uri)","resultObj":{"containers":[{"metadata":{"contentId":5,"contentType":"VIDEO"}}]}}}"#
        }
        let page = json("""
        {"resultObj":{"containers":[\(row("W", "/SANDWICH?x=1")),\(row("A", "/TRAY/SEARCH/VOD?filter_objectSubtype=Replay")),
        \(row("M", "/TRAY/SEARCH/VOD?filter_objectSubtype=Replay&filter_MeetingKey=3")),\(row("  ", "/x")),\(row("Survey time", "/x")),
        \(row("L", "/CONTENT/USERSELECTIONS/MYLIST?a=1"))]}}
        """)
        let rows = Parsers.home(page).rows
        #expect(rows.map(\.title) == ["W", "A", "M"])
        #expect(rows.map(\.tag) == [.weekend, .archive, nil])
    }

    // MARK: Collection, search, live

    @Test func collectionLayouts() {
        func tiles(_ ids: [Int]) -> String {
            ids.map { #"{"metadata":{"contentId":\#($0),"contentType":"VIDEO","title":"e\#($0)","pictureUrl":"p\#($0)"}}"# }.joined(separator: ",")
        }
        let page = json("""
        {"resultObj":{"containers":[
          {"layout":"title","metadata":{"label":"The Cooldown Room"}},
          {"layout":"subtitle","metadata":{"label":"A show"}},
          {"layout":"hero","metadata":{"label":""},"retrieveItems":{"resultObj":{"containers":[\(tiles([1, 2]))]}}},
          {"layout":"vertical_thumbnail","metadata":{"label":" "},"retrieveItems":{"resultObj":{"containers":[\(tiles([2, 3]))]}}}
        ]}}
        """)
        let c = Parsers.collection(page)
        #expect(c.title == "The Cooldown Room")
        #expect(c.description == "A show")
        #expect(c.picturePath == "p1")
        #expect(c.rows.map(\.title) == ["Latest", "Episodes"])
        #expect(c.rows[0].items.map(\.contentId) == [1])
        #expect(c.rows[1].items.map(\.contentId) == [2, 3])
    }

    @Test func searchFixturesParse() throws {
        let archive = Parsers.search(try fixture("archive-races"))
        #expect(!archive.isEmpty)
        #expect(archive.allSatisfy { !$0.title.localizedCaseInsensitiveContains("Kids") })
        let season = Parsers.search(try fixture("season-1998"))
        #expect(season.allSatisfy { $0.subtype != "MEETING" })
    }

    @Test func liveNowEmptyFixture() throws {
        #expect(Parsers.liveNow(try fixture("livenow")).isEmpty)
    }

    @Test func liveNowContainer() {
        let page = json("""
        {"resultObj":{"items":[
          {"metadata":{"contentId":99,"titleBrief":"Race","title":"2026 Race","pictureUrl":"pic","emfAttributes":{"Meeting_Name":"Las Vegas Grand Prix"}}},
          {"metadata":{"contentId":98,"titleBrief":null,"title":null}},
          {"metadata":{"contentId":0,"title":"zero"}},
          {"nope":1}
        ]}}
        """)
        let items = Parsers.liveNow(page)
        #expect(items.map(\.contentId) == [99, 98])
        #expect(items[0].title == "Race")
        #expect(items[0].isLive)
        #expect(items[0].picturePath == "pic")
        #expect(items[0].meeting == "Las Vegas Grand Prix")
        #expect(items[1].title == "Live")
        #expect(items[0].subtitle(now: now, calendar: utc) == "Live")
    }

    // MARK: Review focus 2: nulls and bad items

    @Test func lenientItem() throws {
        let tile = json(#"{"metadata":{"contentId":5,"contentType":"VIDEO","title":null,"duration":"5400","contentSubtype":"REPLAY"}}"#)
        let item = try #require(Parsers.catalogItem(tile))
        #expect(item.title == "")
        #expect(item.picturePath == nil)
        #expect(item.durationSeconds == 5400)
        #expect(item.start == nil)
        #expect(item.year == nil)
    }

    @Test func itemWithoutIdAndPageIsDropped() {
        #expect(Parsers.catalogItem(json(#"{"metadata":{"contentId":0,"title":"x","contentType":"VIDEO"}}"#)) == nil)
        #expect(Parsers.catalogItem(json(#"{"metadata":{"title":"x"}}"#)) == nil)
        #expect(Parsers.catalogItem(json(#"{"metadata":{"contentId":3,"contentType":"LAUNCHER"}}"#)) == nil)
        // A bundle with no page action is dropped too.
        #expect(Parsers.catalogItem(json(#"{"metadata":{"contentId":3,"contentType":"BUNDLE"}}"#)) == nil)
        #expect(Parsers.catalogItem(.null) == nil)
    }

    @Test func bundleKeepsPageId() throws {
        let tile = json(#"{"metadata":{"contentId":0,"contentType":"BUNDLE","title":" Show "},"actions":[{"uri":"/2.0/R/ENG/WEB_HLS/ALL/PAGE/9298/PREMIUM/5"}]}"#)
        let item = try #require(Parsers.catalogItem(tile))
        #expect(item.pageId == 9298)
        #expect(item.title == "Show")
        #expect(item.id == -9298)
    }

    @Test func rowKeepsGoodItemsAroundABadOne() {
        let page = json("""
        {"resultObj":{"containers":[{"layout":"horizontal_thumbnail","metadata":{"label":"Row"},
          "retrieveItems":{"uriOriginal":"/x","resultObj":{"containers":[
            {"metadata":{"contentId":1,"contentType":"VIDEO","title":"a"}},
            {"metadata":"broken"},
            "garbage",
            {"metadata":{"contentId":0}},
            {"metadata":{"contentId":2,"contentType":"VIDEO","title":"b"}}
          ]}}}]}}
        """)
        #expect(Parsers.home(page).rows[0].items.map(\.contentId) == [1, 2])
    }

    @Test func itemFieldsFromRealFixtureTile() throws {
        let tile = try fixture("weekend-saopaulo")["resultObj"]["containers"][2]["retrieveItems"]["resultObj"]["containers"][0]
        let item = try #require(Parsers.catalogItem(tile))
        #expect(item.contentId > 0)
        #expect(item.meeting == "São Paulo Grand Prix")
        #expect(item.start != nil)
        #expect(item.pictureURL(width: 100, height: 50)?.absoluteString.contains("/image-resizer/image/") == true)
    }

    // MARK: Subtitles

    @Test func subtitleRules() {
        let start = Date(timeIntervalSince1970: 1_794_157_200)  // 2026-11-08 17:00 UTC, a Sunday
        func item(_ subtype: String, genre: String = "", start: Date? = nil) -> CatalogItem {
            CatalogItem(contentId: 1, subtype: subtype, genre: genre, start: start)
        }
        #expect(item("LIVE").isLive)
        #expect(item("LIVE").subtitle(now: now, calendar: utc) == "Live")
        let upcoming = item("LIVE_EVENT", start: now.addingTimeInterval(86_400 * 2))
        #expect(upcoming.isUpcoming(now: now))
        #expect(item("LIVE_EVENT", start: start).isUpcoming(now: now) == false)
        #expect(item("LIVE_EVENT", start: start).subtitle(now: now, calendar: utc) == "Sun, Nov 8 · 5:00 PM")
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(item("LIVE_EVENT", start: start).subtitle(now: now, calendar: tokyo) == "Mon, Nov 9 · 2:00 AM")
        #expect(item("REPLAY", genre: "Race").subtitle(now: now, calendar: utc) == "")
        #expect(item("REPLAY", genre: "Full Race").subtitle(now: now, calendar: utc) == "")
        #expect(item("REPLAY", genre: "Tech Talk").subtitle(now: now, calendar: utc) == "Tech Talk")
        #expect(item("RACE HIGHLIGHTS").subtitle(now: now, calendar: utc) == "Race highlights")
        #expect(item("LIVE_EVENT").subtitle(now: now, calendar: utc) == "Live event")
        #expect(item("").subtitle(now: now, calendar: utc) == "")
    }

    // MARK: Play

    @Test func playFixturesAreM3U8() throws {
        for name in ["play-1000010431-WEB_HLS", "play-1000010431-iosheader-WEB_HLS", "play-1000010431-onboard-WEB_HLS", "play-1000009999-WEB_HLS"] {
            let raw = try fixture(name)
            #expect(raw["_url_kind"].string == "m3u8")
            #expect(raw["_has_laURL"].bool == false)
            let url = "https://example.invalid/x/index.m3u8"
            guard case .object(var root) = raw, case .object(var result) = raw["resultObj"] else {
                Issue.record("unexpected shape"); continue
            }
            result["url"] = .string(url)
            root["resultObj"] = .object(result)
            let info = try Parsers.play(.object(root))
            #expect(info.url.absoluteString == url)
            #expect(info.url.pathExtension == "m3u8")
            #expect(info.licenseURL == nil)
            #expect(["SDR_HD_CMAF", "HLS"].contains(info.streamType))
        }
    }

    @Test func playLicenseURLAndMissingURL() throws {
        let info = try Parsers.play(json(#"{"resultObj":{"url":"https://example.invalid/a.mpd","laURL":"https://example.invalid/lic","streamType":"DASH"}}"#))
        #expect(info.licenseURL?.absoluteString == "https://example.invalid/lic")
        #expect(throws: F1TVError.self) { try Parsers.play(json(#"{"resultObj":{"streamType":"HLS"}}"#)) }
        #expect(throws: F1TVError.self) { try Parsers.play(json(#"{"resultObj":{"url":null}}"#)) }
        #expect(throws: F1TVError.self) { try Parsers.play(json(#"{}"#)) }
    }
}
