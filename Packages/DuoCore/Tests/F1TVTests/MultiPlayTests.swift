import Foundation
import Testing
@testable import F1TV

private let multiSuffix = "/3.0/R/ENG/WEB_DASH/ALL/CONTENT/PLAY"

private func fixtureText(_ name: String) throws -> String {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

private func fixture(_ name: String) throws -> JSONValue {
    try JSONValue.parse(Data(try fixtureText(name).utf8))
}

private func multiBody() throws -> Data {
    Data(try fixtureText("play-1000010431-multiview-WEB_DASH.json").utf8)
}

/// Inline PLAY JSON with the given feed URLs (channel ids 1001, 1002, ...).
private func inline(
    urls: [String], streamType: String = "SDR_HD_CMAF", extra: String = ""
) throws -> JSONValue {
    let feeds = urls.enumerated().map { i, u in
        #"{"metadata":{"channel_id":\#(1001 + i)},"url":"\#(u)"}"#
    }.joined(separator: ",")
    let text = #"{"resultObj":{"tme":{"feeds":[\#(feeds)]},"streamType":"\#(streamType)"\#(extra)}}"#
    return try JSONValue.parse(Data(text.utf8))
}

@Suite struct MultiPlayTests {
    @Test func parsesRecordedSaoPauloMultiview() throws {
        let info = try Parsers.multiPlay(try fixture("play-1000010431-multiview-WEB_DASH.json"))
        #expect(info.feeds.count == 26)
        #expect(info.streamType == "SDR_HD_CMAF")
        #expect(info.licenseURL == nil)
        #expect(info.feeds[1025]?.absoluteString == "https://example.com/1025.m3u8")
        // Every feed the catalogue lists for the race is among the multiview's feeds.
        let video = try fixtureText("video-1000010431-WEB_DASH.json")
        let listed = Set(video.matches(of: /"channelId": (\d+)/).compactMap { Int($0.output.1) })
        #expect(!listed.isEmpty)
        for id in listed { #expect(info.feeds[id] != nil) }
    }

    @Test func cmafStreamTypeWithM3U8IsAccepted() throws {
        let info = try Parsers.multiPlay(
            try inline(urls: ["https://example.com/a.m3u8", "https://example.com/b.m3u8"]))
        #expect(info.streamType == "SDR_HD_CMAF")
        #expect(info.feeds.count == 2)
    }

    @Test func missingFeedsIsBadResponse() throws {
        let json = try JSONValue.parse(Data(#"{"resultObj":{"tme":{},"streamType":"SDR_HD_CMAF"}}"#.utf8))
        #expect(throws: F1TVError.self) { try Parsers.multiPlay(json) }
        do { _ = try Parsers.multiPlay(json) } catch let e as F1TVError {
            guard case .badResponse = e else { Issue.record("expected badResponse, got \(e)"); return }
        }
    }

    @Test func feedWithoutChannelIdOrURLIsNotUsable() throws {
        let text = #"""
        {"resultObj":{"tme":{"feeds":[
          {"metadata":{},"url":"https://example.com/a.m3u8"},
          {"metadata":{"channel_id":1001},"url":"<removed>"},
          {"metadata":{"channel_id":1002},"url":"ftp://example.com/b.m3u8"}]},"streamType":"X"}}
        """#
        let json = try JSONValue.parse(Data(text.utf8))
        do { _ = try Parsers.multiPlay(json); Issue.record("expected a throw") } catch let e as F1TVError {
            guard case .badResponse = e else { Issue.record("expected badResponse, got \(e)"); return }
        }
    }

    @Test func switcherSingleFeedIsMultiviewUnavailable() throws {
        let text = try fixtureText("play-1000010431-multiview-SWITCHER.json")
            .replacingOccurrences(of: #""url": "<removed>""#, with: #""url": "https://example.com/1033.m3u8""#)
        let json = try JSONValue.parse(Data(text.utf8))
        #expect(throws: F1TVError.multiviewUnavailable) { try Parsers.multiPlay(json) }
    }

    @Test func mpdURLIsMultiviewUnavailable() throws {
        let json = try inline(urls: ["https://example.com/a.m3u8", "https://example.com/b.mpd"])
        #expect(throws: F1TVError.multiviewUnavailable) { try Parsers.multiPlay(json) }
    }

    @Test func licenseURLIsProtected() throws {
        let json = try inline(
            urls: ["https://example.com/a.m3u8", "https://example.com/b.m3u8"],
            extra: #","laURL":"https://example.com/license""#)
        #expect(throws: F1TVError.protectedContent) { try Parsers.multiPlay(json) }
    }

    @Test func requestUsesPlayerTmOnWebDASHWithMultiviewHeader() async throws {
        let f = await PlayCoordinatorTests.fake()
        await f.respond(pathSuffix: multiSuffix, body: try multiBody())
        let p = PlayCoordinator(session: try await PlayCoordinatorTests.signedIn(f))
        let info = try await p.playMultiview(contentId: 1000010431, defaultChannelId: 1033)
        #expect(info.feeds.count == 26)
        let r = try #require(await PlayCoordinatorTests.plays(f).first)
        #expect(r.url.path.contains("/WEB_DASH/"))
        #expect(r.url.path.hasSuffix("CONTENT/PLAY"))
        #expect(r.url.query == "contentId=1000010431&player=player_tm&channelId=1033")
        #expect(r.headers["entitlementtoken"] == "ENTDASH")
        #expect(r.headers["x-f1-device-info"] == Endpoints.androidDeviceInfo(multiview: true))
        let device = try #require(r.headers["x-f1-device-info"])
        #expect(device.contains("p=true"))
        #expect(device.contains("os=android"))
        #expect(device.contains("browser=chrome"))
        #expect(r.headers["User-Agent"] == Endpoints.androidUserAgent)
        #expect(try #require(r.headers["User-Agent"]).contains("Android"))
    }

    @Test func singlePlayKeepsSafariHeader() async throws {
        let f = await PlayCoordinatorTests.fake()
        let single = try fixtureText("play-1000010431-WEB_HLS.json")
            .replacingOccurrences(of: #""url": "<removed>""#, with: #""url": "https://example.invalid/x/index.m3u8""#)
        await f.respond(pathSuffix: "/3.0/R/ENG/WEB_HLS/ALL/CONTENT/PLAY", json: single)
        let p = PlayCoordinator(session: try await PlayCoordinatorTests.signedIn(f))
        _ = try await p.play(contentId: 1000010431, channelId: 1016)
        let r = try #require(await PlayCoordinatorTests.plays(f).first)
        let device = try #require(r.headers["x-f1-device-info"])
        #expect(device == Endpoints.deviceInfo(multiview: false))
        #expect(device.contains("p=false"))
        #expect(device.contains("browser=safari"))
        #expect(r.headers["User-Agent"] == Endpoints.userAgent)
    }

    @Test func askingAgainSendsNoSecondPlay() async throws {
        let f = await PlayCoordinatorTests.fake()
        await f.respond(pathSuffix: multiSuffix, body: try multiBody())
        let p = PlayCoordinator(session: try await PlayCoordinatorTests.signedIn(f))
        let a = try await p.playMultiview(contentId: 1000010431, defaultChannelId: 1033)
        let b = try await p.playMultiview(contentId: 1000010431, defaultChannelId: 1033)
        #expect(a == b)
        #expect(await PlayCoordinatorTests.plays(f).count == 1)
    }

    @Test func refreshSendsANewPlay() async throws {
        let f = await PlayCoordinatorTests.fake()
        await f.respond(pathSuffix: multiSuffix, body: try multiBody())
        let p = PlayCoordinator(session: try await PlayCoordinatorTests.signedIn(f))
        _ = try await p.playMultiview(contentId: 1000010431, defaultChannelId: 1033)
        let again = try await p.playMultiview(contentId: 1000010431, defaultChannelId: 1033, refresh: true)
        #expect(again.feeds.count == 26)
        #expect(await PlayCoordinatorTests.plays(f).count == 2)
        let active = await p.active
        #expect(active?.contentId == 1000010431)
    }

    @Test func singlePlayReplacesMultiview() async throws {
        let f = await PlayCoordinatorTests.fake()
        await f.respond(pathSuffix: multiSuffix, body: try multiBody())
        let single = try fixtureText("play-1000010431-WEB_HLS.json")
            .replacingOccurrences(of: #""url": "<removed>""#, with: #""url": "https://example.invalid/x/index.m3u8""#)
        await f.respond(pathSuffix: "/3.0/R/ENG/WEB_HLS/ALL/CONTENT/PLAY", json: single)
        let p = PlayCoordinator(session: try await PlayCoordinatorTests.signedIn(f))
        _ = try await p.playMultiview(contentId: 1000010431, defaultChannelId: 1033)
        _ = try await p.play(contentId: 1000010431, channelId: 1033)
        #expect(await PlayCoordinatorTests.plays(f).count == 2)
        // Back to multiview: the single play replaced it, so this needs a fresh request.
        _ = try await p.playMultiview(contentId: 1000010431, defaultChannelId: 1033)
        #expect(await PlayCoordinatorTests.plays(f).count == 3)
    }

    @Test func protectedMultiviewIsNotActive() async throws {
        let f = await PlayCoordinatorTests.fake()
        let text = try fixtureText("play-1000010431-multiview-WEB_DASH.json")
            .replacingOccurrences(of: #""streamType""#, with: #""laURL": "https://example.com/license", "streamType""#)
        await f.respond(pathSuffix: multiSuffix, json: text)
        let p = PlayCoordinator(session: try await PlayCoordinatorTests.signedIn(f))
        await #expect(throws: F1TVError.protectedContent) {
            _ = try await p.playMultiview(contentId: 1000010431, defaultChannelId: 1033)
        }
        #expect(await p.active == nil)
    }
}
