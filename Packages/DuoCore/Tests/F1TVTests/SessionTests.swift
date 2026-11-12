import Foundation
import Testing
@testable import F1TV

@Suite struct SessionTests {
    static let config = #"{"apiConfig":{"playAPIVersion":"3.5","videoAPIVersion":"4.5"}}"#

    static func ent(_ token: String) -> String { #"{"resultObj":{"entitlementToken":"\#(token)"}}"# }
    static func loc(_ tier: String, _ group: Int) -> String {
        #"{"resultObj":{"userLocation":[{"entitlement":"\#(tier)","groupId":\#(group)}]}}"#
    }

    static func fake(tier: String = "PREMIUM", group: Int = 5) async -> FakeHTTPClient {
        let f = FakeHTTPClient()
        await f.respond(pathSuffix: "/config", json: config)
        await f.respond(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/USER/LOCATION", json: loc("ANONYMOUS", 1))
        await f.respond(pathSuffix: "/2.0/R/ENG/WEB_HLS/ALL/USER/ENTITLEMENT", json: ent("ENT"))
        await f.respond(pathSuffix: "/2.0/R/ENG/WEB_DASH/ALL/USER/ENTITLEMENT", json: ent("ENTDASH"))
        await f.respond(pathSuffix: "/1.0/R/ENG/WEB_HLS/ALL/USER/LOCATION", json: loc(tier, group))
        return f
    }

    @Test func configSetsVersions() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/USER/LOCATION", json: Self.loc("ANONYMOUS", 1))
        await f.respond(pathSuffix: "/3.5/R/ENG/WEB_HLS/ALL/X", json: #"{"ok":1}"#)
        await f.respond(pathSuffix: "/4.5/R/ENG/WEB_HLS/ALL/Y", json: #"{"ok":1}"#)
        let s = F1TVSession(http: f)
        try await s.prepare()
        _ = try await s.signIn(token: "TOK")
        _ = try await s.getJSON(path: "X", version: .play, platform: .webHLS)
        _ = try await s.getJSON(path: "Y", version: .video, platform: .webHLS)
        let paths = await f.requests.map(\.url.path)
        #expect(paths.contains("/3.5/R/ENG/WEB_HLS/ALL/X"))
        #expect(paths.contains("/4.5/R/ENG/WEB_HLS/ALL/Y"))
    }

    @Test func malformedConfigFallsBack() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/config", json: "x")
        await f.respond(pathSuffix: "/3.0/A/ENG/WEB_HLS/ALL/X", json: "{}")
        await f.respond(pathSuffix: "/4.0/A/ENG/WEB_HLS/ALL/Y", json: "{}")
        await f.respond(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/USER/LOCATION", json: Self.loc("ANONYMOUS", 1))
        let s = F1TVSession(http: f)
        try await s.prepare()
        _ = try await s.getJSON(path: "X", version: .play, platform: .webHLS)
        _ = try await s.getJSON(path: "Y", version: .video, platform: .webHLS)
        let paths = await f.requests.map(\.url.path)
        #expect(paths.contains("/3.0/A/ENG/WEB_HLS/ALL/X"))
        #expect(paths.contains("/4.0/A/ENG/WEB_HLS/ALL/Y"))
    }

    @Test func prepareSetsAnonymousLocation() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/USER/LOCATION", json: Self.loc("ANONYMOUS", 1))
        let s = F1TVSession(http: f)
        #expect(await s.location == nil)
        try await s.prepare()
        #expect(await s.location == F1TVSession.Location(tier: "ANONYMOUS", groupId: 1))
        #expect(await s.isSignedIn == false)
        let req = await f.requests.last!
        #expect(req.headers["entitlementtoken"] == nil)
        #expect(req.headers["User-Agent"] == Endpoints.userAgent)
    }

    @Test func signInSendsTokensAndReturnsAccount() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/USER/LOCATION", json: Self.loc("ANONYMOUS", 1))
        let s = F1TVSession(http: f)
        try await s.prepare()
        let account = try await s.signIn(token: "TOK")
        #expect(account == Account(tier: "PREMIUM", groupId: 5, hasVideoPlan: true, hasMultiview: true))
        #expect(await s.account == account)
        #expect(await s.isSignedIn)
        #expect(await s.location == F1TVSession.Location(tier: "PREMIUM", groupId: 5))
        let reqs = await f.requests
        let entReq = reqs.first { $0.url.path == "/2.0/R/ENG/WEB_HLS/ALL/USER/ENTITLEMENT" }
        #expect(entReq?.headers["ascendontoken"] == "TOK")
        let locReq = reqs.last { $0.url.path == "/1.0/R/ENG/WEB_HLS/ALL/USER/LOCATION" }
        #expect(locReq?.headers["entitlementtoken"] == "ENT")
        #expect(reqs.allSatisfy { $0.headers["User-Agent"] == Endpoints.userAgent })
    }

    @Test func tierCapabilities() async throws {
        let reg = F1TVSession(http: await Self.fake(tier: "REG"))
        let r = try await reg.signIn(token: "T")
        #expect(r.hasVideoPlan == false)
        #expect(r.hasMultiview == false)
        let pro = F1TVSession(http: await Self.fake(tier: "PRO"))
        let p = try await pro.signIn(token: "T")
        #expect(p.hasVideoPlan == true)
        #expect(p.hasMultiview == false)
    }

    @Test func entitlementRefusedLeavesSignedOut() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/2.0/R/ENG/WEB_HLS/ALL/USER/ENTITLEMENT", status: 401, json: "{}")
        let s = F1TVSession(http: f)
        await #expect(throws: F1TVError.refused(status: 401)) { _ = try await s.signIn(token: "TOK") }
        #expect(await s.isSignedIn == false)
        #expect(await s.account == nil)
    }

    @Test func authorizedGetCachesEntitlementPerPlatform() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/3.5/R/ENG/WEB_DASH/ALL/CONTENT/PLAY", json: #"{"resultObj":{"url":"u"}}"#)
        let s = F1TVSession(http: f)
        _ = try await s.signIn(token: "TOK")
        let json = try await s.getJSON(path: "CONTENT/PLAY", version: .play, platform: .webDASH,
                                       query: [("contentId", "7")], authorized: true)
        _ = try await s.getJSON(path: "CONTENT/PLAY", version: .play, platform: .webDASH, authorized: true)
        #expect(json["resultObj"]["url"].string == "u")
        let reqs = await f.requests
        #expect(reqs.filter { $0.url.path.hasSuffix("/WEB_DASH/ALL/USER/ENTITLEMENT") }.count == 1)
        #expect(reqs.filter { $0.url.path.hasSuffix("/WEB_HLS/ALL/USER/ENTITLEMENT") }.count == 1)
        let play = reqs.first { $0.url.path.hasSuffix("/WEB_DASH/ALL/CONTENT/PLAY") }!
        #expect(play.headers["entitlementtoken"] == "ENTDASH")
        #expect(play.headers["ascendontoken"] == "TOK")
        #expect(play.url.query == "contentId=7")
    }

    @Test func signedOutAuthorizedThrows() async throws {
        let s = F1TVSession(http: FakeHTTPClient())
        await #expect(throws: F1TVError.notSignedIn) {
            _ = try await s.getJSON(path: "X", version: .fixed("1.0"), platform: .webHLS, authorized: true)
        }
    }

    @Test func expiredEntitlementOnRecheckSignsOut() async throws {
        let f = await Self.fake()
        let s = F1TVSession(http: f)
        _ = try await s.signIn(token: "TOK")
        await f.respond(pathSuffix: "/2.0/R/ENG/WEB_DASH/ALL/USER/ENTITLEMENT", status: 403, json: "{}")
        await #expect(throws: F1TVError.refused(status: 403)) {
            _ = try await s.getJSON(path: "X", version: .play, platform: .webDASH, authorized: true)
        }
        #expect(await s.isSignedIn == false)
    }

    @Test func signOutClearsAccountKeepsAnonymousLocation() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/USER/LOCATION", json: Self.loc("ANONYMOUS", 1))
        let s = F1TVSession(http: f)
        try await s.prepare()
        _ = try await s.signIn(token: "TOK")
        await s.signOut()
        #expect(await s.account == nil)
        #expect(await s.isSignedIn == false)
        #expect(await s.location == F1TVSession.Location(tier: "ANONYMOUS", groupId: 1))
        await #expect(throws: F1TVError.notSignedIn) {
            _ = try await s.getJSON(path: "X", version: .fixed("1.0"), platform: .webHLS, authorized: true)
        }
    }

    @Test func statusMapping() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/E500", status: 500, body: Data(String(repeating: "z", count: 300).utf8))
        await f.respond(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/BAD", json: "not json")
        struct Boom: Error {}
        await f.fail(pathSuffix: "/1.0/A/ENG/WEB_HLS/ALL/NET", with: Boom())
        let s = F1TVSession(http: f)
        do { _ = try await s.getJSON(path: "E500", version: .fixed("1.0"), platform: .webHLS); Issue.record("no throw") }
        catch let e as F1TVError { #expect(e == .server(status: 500, message: String(repeating: "z", count: 200))) }
        do { _ = try await s.getJSON(path: "BAD", version: .fixed("1.0"), platform: .webHLS); Issue.record("no throw") }
        catch let e as F1TVError { if case .badResponse = e {} else { Issue.record("expected badResponse") } }
        do { _ = try await s.getJSON(path: "NET", version: .fixed("1.0"), platform: .webHLS); Issue.record("no throw") }
        catch let e as F1TVError { if case .network = e {} else { Issue.record("expected network") } }
        do { _ = try await s.getJSON(path: "NOPE", version: .fixed("1.0"), platform: .webHLS); Issue.record("no throw") }
        catch let e as F1TVError { #expect(e == .server(status: 404, message: "")) }
    }

    @Test func authorizedGet401And403MapToRefused() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/1.0/R/ENG/WEB_HLS/ALL/P401", status: 401, json: "{}")
        await f.respond(pathSuffix: "/1.0/R/ENG/WEB_HLS/ALL/P403", status: 403, json: "{}")
        let s = F1TVSession(http: f)
        _ = try await s.signIn(token: "TOK")
        await #expect(throws: F1TVError.refused(status: 401)) {
            _ = try await s.getJSON(path: "P401", version: .fixed("1.0"), platform: .webHLS, authorized: true)
        }
        await #expect(throws: F1TVError.refused(status: 403)) {
            _ = try await s.getJSON(path: "P403", version: .fixed("1.0"), platform: .webHLS, authorized: true)
        }
    }

    @Test func concurrentGetsShareOneEntitlementRequest() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/3.5/R/ENG/WEB_DASH/ALL/P", json: "{}")
        let gate = GatedHTTPClient(f, gatedSuffix: "/WEB_DASH/ALL/USER/ENTITLEMENT")
        let s = F1TVSession(http: gate)
        _ = try await s.signIn(token: "TOK")
        async let a = s.getJSON(path: "P", version: .play, platform: .webDASH, authorized: true)
        async let b = s.getJSON(path: "P", version: .play, platform: .webDASH, authorized: true)
        await gate.waitUntilHeld()
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        _ = try await (a, b)
        let n = await f.requests.filter { $0.url.path.hasSuffix("/WEB_DASH/ALL/USER/ENTITLEMENT") }.count
        #expect(n == 1)
    }

    @Test func signOutDuringSignInIsNotUndone() async throws {
        let f = await Self.fake()
        let gate = GatedHTTPClient(f, gatedSuffix: "/WEB_HLS/ALL/USER/ENTITLEMENT")
        let s = F1TVSession(http: gate)
        let signIn = Task { try await s.signIn(token: "TOK") }
        await gate.waitUntilHeld()
        await s.signOut()
        await gate.release()
        _ = await signIn.result
        #expect(await s.isSignedIn == false)
        #expect(await s.account == nil)
        await #expect(throws: F1TVError.notSignedIn) {
            _ = try await s.getJSON(path: "X", version: .fixed("1.0"), platform: .webHLS, authorized: true)
        }
    }

    @Test func signOutDuringAuthorizedGetSendsNothing() async throws {
        let f = await Self.fake()
        await f.respond(pathSuffix: "/3.5/R/ENG/WEB_DASH/ALL/P", json: "{}")
        let gate = GatedHTTPClient(f, gatedSuffix: "/WEB_DASH/ALL/USER/ENTITLEMENT")
        let s = F1TVSession(http: gate)
        _ = try await s.signIn(token: "TOK")
        let get = Task { try await s.getJSON(path: "P", version: .play, platform: .webDASH, authorized: true) }
        await gate.waitUntilHeld()
        await s.signOut()
        await gate.release()
        let result = await get.result
        #expect({ if case .failure(let e) = result, e as? F1TVError == .notSignedIn { return true } else { return false } }())
        let sent = await f.requests.contains { $0.url.path.hasSuffix("/WEB_DASH/ALL/P") }
        #expect(!sent)
    }
}

/// Holds responses for one path suffix until released, so tests can interleave calls.
actor GatedHTTPClient: HTTPClient {
    private let inner: FakeHTTPClient
    private let gatedSuffix: String
    private var held = false
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ inner: FakeHTTPClient, gatedSuffix: String) {
        self.inner = inner
        self.gatedSuffix = gatedSuffix
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix(gatedSuffix), !open {
            held = true
            heldWaiters.forEach { $0.resume() }
            heldWaiters = []
            await withCheckedContinuation { waiters.append($0) }
        }
        return try await inner.send(request)
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
