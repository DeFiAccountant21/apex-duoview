import Foundation
import Testing
@testable import F1TV

@Suite struct EndpointsTests {
    @Test func buildsSignedInURL() {
        let url = Endpoints.url(version: "2.0", signedIn: true, platform: .webHLS, path: "PAGE/395/PREMIUM/5")
        #expect(url.absoluteString == "https://f1tv.formula1.com/2.0/R/ENG/WEB_HLS/ALL/PAGE/395/PREMIUM/5")
    }

    @Test func signedOutUsesA() {
        let url = Endpoints.url(version: "2.0", signedIn: false, platform: .webDASH, path: "PAGE/1")
        #expect(url.absoluteString == "https://f1tv.formula1.com/2.0/A/ENG/WEB_DASH/ALL/PAGE/1")
    }

    @Test func queryKeepsOrderAndEncodesOnce() {
        let url = Endpoints.url(
            version: "2.0", signedIn: true, platform: .webHLS, path: "PAGE/1",
            query: [("filter_MeetingKey", "1234"), ("filter_genres", "Full Race,Race"), ("q", "São Paulo")])
        let s = url.absoluteString
        #expect(s.contains("S%C3%A3o%20Paulo"))
        #expect(!s.contains("%25"))
        #expect(s.contains("Full%20Race,Race"))
        let k1 = s.range(of: "filter_MeetingKey")!.lowerBound
        let k2 = s.range(of: "filter_genres")!.lowerBound
        let k3 = s.range(of: "q=")!.lowerBound
        #expect(k1 < k2 && k2 < k3)
    }

    @Test func encodesReservedCharactersInValues() {
        let url = Endpoints.url(version: "2.0", signedIn: true, platform: .webHLS, path: "X",
                                query: [("a", "b&c=d+e")])
        #expect(url.absoluteString.hasSuffix("?a=b%26c%3Dd%2Be"))
    }

    @Test func encodesNonASCIIAudioNames() {
        let url = Endpoints.url(version: "2.0", signedIn: true, platform: .webHLS, path: "X",
                                query: [("lang", "日本語")])
        #expect(url.absoluteString.hasSuffix("?lang=%E6%97%A5%E6%9C%AC%E8%AA%9E"))
    }

    @Test func noQueryMeansNoQuestionMark() {
        let url = Endpoints.url(version: "2.0", signedIn: true, platform: .webHLS, path: "X")
        #expect(!url.absoluteString.contains("?"))
    }

    @Test func imageURL() {
        let url = Endpoints.image(path: "1000010431/abc.jpg", width: 640, height: 360)
        #expect(url.absoluteString == "https://f1tv.formula1.com/image-resizer/image/1000010431/abc.jpg?w=640&h=360&q=HI&o=L")
    }

    @Test func deviceInfoString() {
        #expect(Endpoints.deviceInfo(multiview: true) ==
            "device=web;screen=browser;os=mac os;browser=safari;browserVersion=26.1;osVersion=10.15.7;appVersion=54.2.1;playerVersion=8.212.0;p=true;tms=1")
        #expect(Endpoints.deviceInfo(multiview: false).contains(";p=false;"))
    }

    @Test func userAgentAndBase() {
        #expect(Endpoints.base.absoluteString == "https://f1tv.formula1.com")
        #expect(Endpoints.userAgent == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15")
    }

    @Test func fakeClientMatchesSuffixAndRecords() async throws {
        let fake = FakeHTTPClient()
        await fake.respond(pathSuffix: "/PAGE/1", json: "{}")
        let req = HTTPRequest(method: "GET", url: Endpoints.url(version: "2.0", signedIn: true, platform: .webHLS, path: "PAGE/1"), headers: [:])
        let ok = try await fake.send(req)
        #expect(ok.status == 200)
        let miss = try await fake.send(HTTPRequest(method: "GET", url: Endpoints.base, headers: [:]))
        #expect(miss.status == 404)
        #expect(await fake.requests.count == 2)
    }
}
