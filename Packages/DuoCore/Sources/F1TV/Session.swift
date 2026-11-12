import Foundation

public struct Account: Sendable, Equatable {
    public let tier: String
    public let groupId: Int
    public var hasVideoPlan: Bool
    public var hasMultiview: Bool

    public init(tier: String, groupId: Int, hasVideoPlan: Bool, hasMultiview: Bool) {
        self.tier = tier
        self.groupId = groupId
        self.hasVideoPlan = hasVideoPlan
        self.hasMultiview = hasMultiview
    }
}

public enum VersionKind: Sendable {
    case fixed(String)
    case play
    case video
}

/// F1 TV's sign-in exchange and authorized GETs. The ascendon (subscription) token is
/// exchanged for an entitlement token per platform; neither is ever logged or put in an error.
public actor F1TVSession {
    public struct Location: Sendable, Equatable {
        public let tier: String
        public let groupId: Int
        public init(tier: String, groupId: Int) {
            self.tier = tier
            self.groupId = groupId
        }
    }

    private let http: any HTTPClient
    private var playVersion = "3.0"
    private var videoVersion = "4.0"
    private var configLoaded = false
    private var prepared = false
    private var ascendon: String?
    private var entitlements: [Platform: String] = [:]
    private var entitlementTasks: [Platform: Task<String, Error>] = [:]

    public private(set) var account: Account?
    public private(set) var location: Location?
    private var anonymousLocation: Location?
    /// Bumped by every sign-in commit and sign-out, so work that suspended across one can tell.
    private var epoch = 0

    public var isSignedIn: Bool { ascendon != nil && account != nil }

    public init(http: any HTTPClient) {
        self.http = http
    }

    /// Loads the config and the anonymous location, so catalogue paths have a tier and group
    /// before anyone signs in.
    public func prepare() async throws {
        if prepared { return }
        try await loadConfig()
        let loc = try await fetchLocation(signedIn: false, entitlement: nil)
        anonymousLocation = loc
        if !isSignedIn { location = loc }
        prepared = true
    }

    public func signIn(token: String) async throws -> Account {
        let startEpoch = epoch
        try await loadConfig()
        let entitlement = try await fetchEntitlement(token: token, platform: .webHLS)
        let loc = try await fetchLocation(signedIn: true, entitlement: entitlement)
        // A sign-out (or another sign-in) landed while we were waiting: don't undo it.
        guard epoch == startEpoch else { throw CancellationError() }
        let account = Account(
            tier: loc.tier,
            groupId: loc.groupId,
            hasVideoPlan: !["", "ANONYMOUS", "REG"].contains(loc.tier),
            hasMultiview: ["OPS", "VIP", "PREMIUM"].contains(loc.tier))
        epoch += 1
        entitlementTasks = [:]
        entitlements = [.webHLS: entitlement]
        ascendon = token
        self.account = account
        location = loc
        return account
    }

    public func signOut() {
        epoch += 1
        ascendon = nil
        account = nil
        location = anonymousLocation
        entitlements = [:]
        entitlementTasks = [:]
    }

    public func getJSON(
        path: String,
        version: VersionKind,
        platform: Platform,
        query: [(String, String)] = [],
        authorized: Bool = false
    ) async throws -> JSONValue {
        var headers: [String: String] = [:]
        let startEpoch = epoch
        if authorized {
            guard let token = ascendon else { throw F1TVError.notSignedIn }
            let ent = try await entitlement(for: platform)
            guard epoch == startEpoch, ascendon == token else { throw F1TVError.notSignedIn }
            headers["ascendontoken"] = token
            headers["entitlementtoken"] = ent
            // The web player's device header goes on authorized PLAY requests, as in the web app.
            if case .play = version { headers["x-f1-device-info"] = Endpoints.deviceInfo(multiview: false) }
        }
        let resolved: String
        switch version {
        case .fixed(let v): resolved = v
        case .play: resolved = playVersion
        case .video: resolved = videoVersion
        }
        let url = Endpoints.url(
            version: resolved, signedIn: isSignedIn, platform: platform, path: path, query: query)
        return try await getJSON(url: url, headers: headers)
    }

    // MARK: - Internals

    private func loadConfig() async throws {
        if configLoaded { return }
        let response = try await send(Endpoints.base.appendingPathComponent("config"), headers: [:])
        try Self.check(response)
        // A config we can't read leaves the default versions in place.
        if let json = try? JSONValue.parse(response.body) {
            let config = json["apiConfig"]
            if let v = Self.version(config["playAPIVersion"]) { playVersion = v }
            if let v = Self.version(config["videoAPIVersion"]) { videoVersion = v }
        }
        configLoaded = true
    }

    private static func version(_ value: JSONValue) -> String? {
        let s = value.string.trimmingCharacters(in: .whitespaces)
        return s.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil ? s : nil
    }

    private func fetchLocation(signedIn: Bool, entitlement: String?) async throws -> Location {
        let url = Endpoints.url(version: "1.0", signedIn: signedIn, platform: .webHLS, path: "USER/LOCATION")
        var headers: [String: String] = [:]
        if let entitlement { headers["entitlementtoken"] = entitlement }
        let json = try await getJSON(url: url, headers: headers)
        let first = json["resultObj"]["userLocation"][0]
        let tier = first["entitlement"].string
        guard !tier.isEmpty, let group = first["groupId"].int else {
            throw F1TVError.badResponse("Location response has no tier or group")
        }
        return Location(tier: tier, groupId: group)
    }

    /// The cached entitlement for a platform, fetched on first use. A refusal means the
    /// sign-in has expired, so the session signs out.
    private func entitlement(for platform: Platform) async throws -> String {
        guard let token = ascendon else { throw F1TVError.notSignedIn }
        if let cached = entitlements[platform] { return cached }
        let startEpoch = epoch
        let task: Task<String, Error>
        if let running = entitlementTasks[platform] {
            task = running
        } else {
            task = Task { try await self.fetchEntitlement(token: token, platform: platform) }
            entitlementTasks[platform] = task
        }
        do {
            let value = try await task.value
            if entitlementTasks[platform] == task { entitlementTasks[platform] = nil }
            // Signed out (or in again) while waiting: this value belongs to the old session.
            guard epoch == startEpoch, ascendon == token else { throw F1TVError.notSignedIn }
            entitlements[platform] = value
            return value
        } catch {
            if entitlementTasks[platform] == task { entitlementTasks[platform] = nil }
            if case F1TVError.refused = error, epoch == startEpoch, ascendon == token { signOut() }
            throw error
        }
    }

    private func fetchEntitlement(token: String, platform: Platform) async throws -> String {
        let url = Endpoints.url(version: "2.0", signedIn: true, platform: platform, path: "USER/ENTITLEMENT")
        let response = try await send(url, headers: ["ascendontoken": token])
        try Self.check(response, includeBody: false)
        guard let json = try? JSONValue.parse(response.body) else {
            throw F1TVError.badResponse("Entitlement response is not JSON")
        }
        let value = json["resultObj"]["entitlementToken"].string
        guard !value.isEmpty else { throw F1TVError.badResponse("Entitlement response has no token") }
        return value
    }

    private func getJSON(url: URL, headers: [String: String]) async throws -> JSONValue {
        let response = try await send(url, headers: headers)
        try Self.check(response)
        do {
            return try JSONValue.parse(response.body)
        } catch {
            let path = url.path.components(separatedBy: "/ALL/").last ?? url.path
            throw F1TVError.badResponse("Unreadable JSON from \(path)")
        }
    }

    private func send(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var all = headers
        all["User-Agent"] = Endpoints.userAgent
        do {
            return try await http.send(HTTPRequest(method: "GET", url: url, headers: all))
        } catch let e as F1TVError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw F1TVError.network(error.localizedDescription)
        }
    }

    private static func check(_ response: HTTPResponse, includeBody: Bool = true) throws {
        switch response.status {
        case 200..<400: return
        case 401, 403: throw F1TVError.refused(status: response.status)
        default:
            let body = includeBody ? String(decoding: response.body, as: UTF8.self) : ""
            throw F1TVError.server(status: response.status, message: String(body.prefix(200)))
        }
    }
}
