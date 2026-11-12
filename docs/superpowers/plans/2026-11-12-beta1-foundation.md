# v1.0-beta.1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The first iPhone build: sign in with your own F1 TV account, browse three rooms, play one feed, and resume where you left off.

**Architecture:** A Foundation-only Swift package (`Packages/DuoCore`) holds the F1 TV client and the resume/history rules, tested on Linux here and in CI. The SwiftUI app (`DuoApp/`) adds sign-in, rooms, the AVKit player, the fold adapter and a debug multiview probe; it is built on the owner's Mac by a local Claude session. XcodeGen generates the Xcode project from `project.yml`.

**Tech Stack:** Swift 6 (language mode 6, strict concurrency), Swift Testing, SwiftUI, AVKit, WebKit, Security (Keychain), XcodeGen, GitHub Actions. iOS 27.1. Linux toolchain here: Swift 6.4.1 at `/opt/swift`.

**Spec:** [docs/superpowers/specs/2026-11-12-beta1-foundation-design.md](../specs/2026-11-12-beta1-foundation-design.md). Read it before any task.

## Global Constraints

- Deployment target iOS 27.1; Swift 6 language mode; `swift-tools-version: 6.0` in `Package.swift`, which both the Linux 6.4.1 toolchain and Xcode 27.1 accept.
- `DuoCore` imports Foundation only: never SwiftUI, UIKit, AVFoundation, Combine or FoundationNetworking. Networking only through `HTTPClient`.
- The Android source is read from the `og-android` branch (`git fetch origin og-android`, `git show origin/og-android:app/src/main/java/app/apexview/F1TvApi.kt`). Never merge it.
- Base URL `https://f1tv.formula1.com`; path pattern `{BASE}/{version}/{A|R}/ENG/{platform}/ALL/{path}`; 15 s timeout; every request sends the Safari user agent.
- Single-feed requests use `WEB_HLS`; the platform is a per-request parameter; the entitlement token is cached per platform.
- Device header default (spec O1): `device=web;screen=browser;os=mac os;browser=safari;browserVersion=26.1;osVersion=10.15.7;appVersion=54.2.1;playerVersion=8.212.0;p=<true|false>;tms=1`, sent on `WEB_*` PLAY requests only.
- Never issue a second PLAY for content already playing.
- Tokens, entitlement tokens and signed stream URLs are never logged, printed or committed. The repo is public.
- The iPhone app's folder is `DuoApp/` (not `App/`).
- Version: `Config/Version.xcconfig` is the only source: `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION` = build number, `BETA_LABEL = beta.1`.
- User-facing copy is fixed by the spec: "Couldn't load F1 TV: …" with "Try again"; "F1 TV won't play this on your account. Its plan may not include this session."; "This feed stopped: <reason>."; "This session is protected and can't play in this app yet"; "Your F1 TV sign-in has expired. Sign in again."; "Sign in to watch."
- Commits end with the attribution lines in the session's instructions. Push to `ios` only.

## Review Focus

1. **A sign-in that expires while the app is open.** ENTITLEMENT returns 401/403 on the foreground re-check → signed out with the expiry message, bookmark kept, no crash or blank screen. Test in Task 3.
2. **F1 TV JSON with nulls, missing keys or unexpected types** (the Kotlin reads null as ""). A tile with a null title or picture still parses; an item with `contentId <= 0` and no page ID is dropped; a whole row never fails because of one bad item. Tests in Task 4.
3. **Non-ASCII names in URLs and queries** ("São Paulo", "日本語" audio names). Query values are percent-encoded once, never twice. Test in Task 2.
4. **The pasted sign-in in every shape the owner has produced:** raw JSON, URL-encoded, double URL-encoded, a `login-session=` prefix, surrounding quotes or a trailing newline, a 3,000-character value, a bare token. Test in Task 3.
5. **Resuming something that can't resume as saved:** the saved feed is no longer in the feed list, the saved position is past the new duration, or the content is now live. Fall back to the default feed, clamp to the start, or go to the live edge, with no error. Tests in Tasks 7 and 11.

---

## Owner steps (not agent tasks)

These are done by the owner, guided by Claude. Tasks that need them say so.

- **O-A (before Task 4):** run the fixture recording from Task 1 on the Mac and send the resulting `fixtures.zip` (no tokens in it) as a chat upload.
- **O-B (before Task 8):** install Xcode 27.1 or later and XcodeGen (`brew install xcodegen`); clone the repo and check out `ios`; choose a bundle ID (spec O2).
- **O-C (before Task 12):** run the SDK declarations command given in Task 12 and paste its output.
- **O-D (Task 14):** the exit test on the 15 Pro Max.

---

### Task 1: Fixture recording option in the stream check
**Model:** Sonnet 5.5

**Files:**
- Modify: `spike/stream_check.py`
- Modify: `spike/.gitignore` (add `fixtures/`, `fixtures.zip`)

**Interfaces:**
- Produces: a `--dump-catalogue` flag writing sanitised JSON files into `spike/fixtures/` and zipping them to `spike/fixtures.zip`. File names are fixed, because Task 4 reads them: `config.json`, `location.json`, `home.json`, `livenow.json`, `calendar-2026.json`, `weekend-saopaulo.json` (the meeting's PAGE response for the 2026 São Paulo meeting, found through the calendar), `archive-races.json`, `season-1998.json`, `video-1000010431-WEB_HLS.json`, `video-1000010431-WEB_DASH.json`, `play-1000010431-WEB_HLS.json`, `play-1000010431-onboard-WEB_HLS.json` (channelId 1016), `play-1000010431-iosheader-WEB_HLS.json` (device header with `os=ios;browser=safari;browserVersion=27;osVersion=27.2`), `play-1000009999-WEB_HLS.json`.

- [ ] **Step 1:** Add `sanitize(obj)`. It is recursive and returns a copy. It replaces values whose key matches `/token|ascendon|entitlement|subscriber|email|session/i` with `"<removed>"`, and replaces query strings and token path segments in URL strings using the existing `mask_url`. It truncates every list longer than 6 to its first 6 items, recursively, so each file stays small. Sanitise the location response by keeping only `entitlement`, `groupId` and the country codes.
- [ ] **Step 2:** Add `--dump-catalogue`. It runs the existing sign-in and then each request named above, with the same headers the app will use (Global Constraints). Each response passes through `sanitize`, is written with `json.dump(..., indent=1, ensure_ascii=False)` and then zipped. A failed request writes `{"error": <status>, "body": <first 600 chars, scrubbed>}` instead of stopping the run. The play files also record whether `url` ended in `.m3u8` and whether `laURL` was present, as `"_url_kind"` and `"_has_laURL"`, because the URL itself is removed.
- [ ] **Step 3:** Verify offline with faked HTTP, as earlier spike work did: run it in the scratchpad, then grep the output for the faked token, entitlement and URL query values. Expected: 0 matches, 14 files, and a zip under 200 KB.
- [ ] **Step 4:** Commit `spike/stream_check.py` and `spike/.gitignore`, then push.

### Task 2: DuoCore package, HTTP layer and URL building
**Model:** Sonnet 5.5

**Files:**
- Create: `Packages/DuoCore/Package.swift` with library products `F1TV` and `Library` and test targets `F1TVTests` and `LibraryTests`.
- Create: `Packages/DuoCore/Sources/F1TV/HTTP.swift`, `Endpoints.swift`, `F1TVError.swift`
- Test: `Packages/DuoCore/Tests/F1TVTests/EndpointsTests.swift`, `Packages/DuoCore/Tests/F1TVTests/Support/FakeHTTPClient.swift`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces:
  - `HTTP.swift`:
    - `public struct HTTPRequest: Sendable, Equatable { public var method: String; public var url: URL; public var headers: [String: String] }`
    - `public struct HTTPResponse: Sendable { public var status: Int; public var body: Data }`
    - `public protocol HTTPClient: Sendable { func send(_ request: HTTPRequest) async throws -> HTTPResponse }`
  - `Endpoints.swift`:
    - `public enum Platform: String, Sendable, CaseIterable { case webHLS = "WEB_HLS", webDASH = "WEB_DASH" }`
    - `public enum Endpoints`, with:
      - `static let base: URL`
      - `static let userAgent: String` (the Safari UA `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15`)
      - `static func url(version: String, signedIn: Bool, platform: Platform, path: String, query: [(String, String)] = []) -> URL`
      - `static func image(path: String, width: Int, height: Int) -> URL`
      - `static func deviceInfo(multiview: Bool) -> String`
  - `F1TVError.swift`: `public enum F1TVError: Error, Equatable, Sendable { case notSignedIn, refused(status: Int), noVideoPlan, network(String), server(status: Int, message: String), badResponse(String), protectedContent }`
  - Test support: `FakeHTTPClient` (an actor), which answers by matching URL path suffix and records requests. Later tasks reuse it.

- [ ] **Step 1: Write failing tests** in `EndpointsTests.swift`:
  - `url(version: "2.0", signedIn: true, platform: .webHLS, path: "PAGE/395/PREMIUM/5")` → `"https://f1tv.formula1.com/2.0/R/ENG/WEB_HLS/ALL/PAGE/395/PREMIUM/5"`.
  - `signedIn: false` puts `/A/` in place of `/R/`.
  - A query `[("filter_MeetingKey","1234"),("filter_genres","Full Race,Race"),("q","São Paulo")]` keeps the order and encodes each value exactly once: the result contains `S%C3%A3o%20Paulo` and not `%25`.
  - `image(path: "1000010431/abc.jpg", width: 640, height: 360)` → `"https://f1tv.formula1.com/image-resizer/image/1000010431/abc.jpg?w=640&h=360&q=HI&o=L"`.
  - `deviceInfo(multiview: true)` equals the Global Constraints string with `p=true`.
- [ ] **Step 2:** Run `cd Packages/DuoCore && swift test`. Expected: compile failure (types not defined).
- [ ] **Step 3:** Implement the three files. Build URLs with `URLComponents` and `percentEncodedQueryItems`, encoding values with `.urlQueryAllowed` minus `&=+`. Commas stay literal, as the Kotlin sends `Full Race,Race`; add that to the Step 1 assertions.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Write `ci.yml`. On a push to `ios`, a job on `ubuntu-24.04` with container `swift:6.4` runs `cd Packages/DuoCore && swift test`. There is no macOS job.
- [ ] **Step 6:** Commit and push. Then confirm the CI run is green with the GitHub MCP tool `actions_list` (`list_workflow_runs`, branch `ios`). If Actions is disabled on the fork, report it to the orchestrator; don't work around it.

### Task 3: Sign-in exchange, account and cookie decoding
**Model:** Sonnet 5.5

**Files:**
- Create: `Packages/DuoCore/Sources/F1TV/LoginCookie.swift`, `Session.swift`, `JSON.swift`
- Test: `Packages/DuoCore/Tests/F1TVTests/LoginCookieTests.swift`, `SessionTests.swift`

**Interfaces:**
- Consumes: Task 2's `HTTPClient`, `Endpoints`, `F1TVError` and `FakeHTTPClient`.
- Produces:
  - `public enum LoginCookie { public static let loginURL: URL; public static func token(from raw: String) -> String? }`. It applies the same rules as `decode_signin` in `spike/stream_check.py`.
  - `public struct Account: Sendable, Equatable { public let tier: String; public let groupId: Int; public var hasVideoPlan: Bool; public var hasMultiview: Bool }`
  - `public actor F1TVSession`, with:
    - `init(http: any HTTPClient)`
    - `func prepare() async throws`
    - `func signIn(token: String) async throws -> Account`
    - `func signOut()`
    - `var account: Account? { get }`
    - `var isSignedIn: Bool { get }`
    - `func getJSON(path: String, version: VersionKind, platform: Platform, query: [(String, String)] = [], authorized: Bool = false) async throws -> JSONValue`
  - `public enum VersionKind: Sendable { case fixed(String), play, video }`. The play and video versions come from `/config`.
  - `JSON.swift`: `public enum JSONValue: Sendable, Equatable` (null, bool, number, string, array, object), with lenient accessors:
    - `subscript(key: String) -> JSONValue`, which returns `.null` when missing
    - `subscript(index: Int) -> JSONValue`
    - `var string: String`, where null and non-strings give `""` and numbers give their text
    - `var int: Int?`, which accepts numeric strings
    - `var array: [JSONValue]`, where anything else gives `[]`
    - `var bool: Bool?`, which accepts `"true"` and `"false"`

- [ ] **Step 1: Write failing tests.**
  - `LoginCookieTests`: every shape in Review Focus 4 returns `"TOK123"` from a cookie whose JSON is `{"data":{"subscriptionToken":"TOK123"}}`. For the 3,000-character value, pad `data` with an extra key. A JSON cookie without the token returns `nil`, and so does `"two words"`.
  - `SessionTests`:
    - Config `{"apiConfig":{"playAPIVersion":"3.0","videoAPIVersion":"4.0"}}` sets the versions. A malformed `"x"` falls back to 3.0 / 4.0.
    - `signIn` sends `ascendontoken: TOK` to `…/2.0/R/ENG/WEB_HLS/ALL/USER/ENTITLEMENT`, then `entitlementtoken: ENT` to `…/1.0/R/ENG/WEB_HLS/ALL/USER/LOCATION`, and returns `Account(tier: "PREMIUM", groupId: 5)`. The account has `hasMultiview == true` and `hasVideoPlan == true`.
    - Tier `REG` gives `hasVideoPlan == false`. Tier `PRO` gives `hasMultiview == false`.
    - ENTITLEMENT returning 401 throws `.refused(status: 401)` and leaves `isSignedIn == false`. This covers Review Focus 1.
    - An authorized `getJSON` for `.webDASH` after sign-in fetches and caches a second entitlement for that platform. Two calls make one ENTITLEMENT request per platform.
    - A request while signed out with `authorized: true` throws `.notSignedIn`.
- [ ] **Step 2:** Run `swift test --filter F1TVTests`. Expected: compile failure.
- [ ] **Step 3:** Implement. `prepare()` loads the config, then fetches the anonymous LOCATION with `signedIn: false`, so the catalogue paths have a tier and groupId when signed out. HTTP status mapping: 401/403 → `.refused`, other 4xx/5xx → `.server(status, first 200 chars)`, transport errors → `.network`, and unparsable JSON → `.badResponse`.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit and push.

### Task 4: Catalogue models and parsers (needs O-A fixtures)
**Model:** Sonnet 5.5

**Files:**
- Create: `Packages/DuoCore/Sources/F1TV/Models.swift`, `Parsers.swift`, `Schedule.swift`
- Create: `Packages/DuoCore/Tests/F1TVTests/Fixtures/*.json`, unzipped from the owner's `fixtures.zip`. Declare them as resources in `Package.swift`.
- Test: `Packages/DuoCore/Tests/F1TVTests/ParsersTests.swift`, `ScheduleTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (Task 3), `Endpoints.image` (Task 2).
- Produces:
  - `CatalogItem`, `Sendable, Equatable, Identifiable`. Fields: `contentId: Int`, `title: String`, `subtype: String`, `contentType: String`, `genre: String`, `picturePath: String?`, `durationSeconds: Int?`, `year: Int?`, `meeting: String`, `start: Date?`, `pageId: Int?`.
    - `var isLive: Bool` is `subtype == "LIVE"`.
    - `func isUpcoming(now: Date) -> Bool` is `subtype == "LIVE_EVENT" && start > now`.
    - `func subtitle(now: Date, calendar: Calendar) -> String`, with the spec's subtitle rules. Upcoming uses the format `EEE, MMM d · h:mm a`.
  - `CatalogRow`. Fields: `title: String`, `items: [CatalogItem]`, `posters: Bool`, `tag: RowTag?`, where `enum RowTag { case weekend, archive }`.
  - `Meeting`. Fields: `key: String`, `round: Int?`, `name: String`, `place: String`, `start: Date`, `end: Date`, `pageId: Int?`, `picturePath: String?`.
  - `WeekendContent`. Fields: `sessions`, `videos`, `schedule: [CatalogItem]` and `rows: [CatalogRow]`.
    - `func scheduleOver(now: Date) -> Bool`.
  - `HomePage`. Fields: `featured: [CatalogItem]`, `rows: [CatalogRow]`.
  - `CollectionPage`. Fields: `title`, `description`, `picturePath: String?`, `rows`.
  - `Channel`. Fields: `id: Int?`, `isDefault: Bool`, `isOnboard: Bool`, `title: String`, `racingNumber: Int?`, `driverLastName: String`, `teamName: String`, `teamColorHex: String`.
    - `var displayTitle` is `"<number> <lastName>"` for onboards, otherwise `title`, otherwise `"Channel <id>"`.
  - `VideoDetail`. Fields: `contentId`, `title`, `channels: [Channel]`. When F1 lists none, it is a single `Channel(id: nil, isDefault: true, title: "Main feed")`.
  - `PlayInfo`. Fields: `url: URL`, `licenseURL: URL?`, `streamType: String`.
  - `enum Parsers`, with:
    - `static func catalogItem(_ metadataContainer: JSONValue) -> CatalogItem?`
    - `static func liveNow(_:) -> [CatalogItem]`
    - `static func calendar(_:) -> [Meeting]`
    - `static func weekend(_:) -> WeekendContent`
    - `static func home(_:) -> HomePage`
    - `static func collection(_:) -> CollectionPage`
    - `static func search(_:) -> [CatalogItem]`
    - `static func video(_:) -> VideoDetail`
    - `static func play(_:) throws -> PlayInfo`
  - `Schedule.swift`: `public func scheduleDayToOpen(days: [[CatalogItem]], today: Int, now: Date, sessions: Set<Int>, finished: (Int) -> Bool) -> Int`, ported line for line from `F1TvApi.kt` on `og-android`.

- [ ] **Step 1: Write failing tests** against the real fixtures. The values are read from the fixtures once they arrive.
  - `video-1000010431-WEB_DASH.json` (falling back to `WEB_HLS` if that one failed) has a default channel, and onboard channels with `racingNumber` and `driverLastName`.
  - `calendar-2026.json` contains a meeting named "São Paulo Grand Prix" with a round number. Entries where `Diplay_In_Schedule == "false"` are skipped.
  - `weekend-saopaulo.json` gives a non-empty `schedule` in start order.
  - `home.json` gives rows with no blank, "Survey" or MYLIST rows, and featured items from `super_hero`.
  - `play-*.json` give an `.m3u8` URL (assert on the recorded `_url_kind`) and `licenseURL == nil`.
  - Review Focus 2: a hand-written container with `title: null`, `pictureUrl` missing and `duration: "5400"` still parses (title `""`, duration 5400). An item with `contentId: 0` and no page ID is dropped. A row with one malformed item keeps its other items.
  - `ScheduleTests`: port all ten tests in `ScheduleTest.kt` (`origin/og-android:app/src/test/java/app/apexview/ScheduleTest.kt`) with the same values, converting the hour arithmetic to `Date(timeIntervalSince1970:)`.
- [ ] **Step 2:** Run `swift test --filter "ParsersTests|ScheduleTests"`. Expected: compile failure.
- [ ] **Step 3:** Implement by mirroring `F1TvApi.kt`: the field names, skip rules and fallbacks are in the spec's "Catalogue calls". `play` throws `F1TVError.badResponse` when `url` is missing.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit and push.

### Task 5: Catalogue calls and the play coordinator
**Model:** Sonnet 5.5

**Files:**
- Create: `Packages/DuoCore/Sources/F1TV/Catalogue.swift`, `PlayCoordinator.swift`
- Test: `Packages/DuoCore/Tests/F1TVTests/CatalogueTests.swift`, `PlayCoordinatorTests.swift`

**Interfaces:**
- Consumes: `F1TVSession.getJSON` (Task 3), `Parsers` (Task 4).
- Produces:
  - `public struct Catalogue: Sendable`, with `init(session: F1TVSession)` and these `async throws` calls:
    - `liveNow() -> [CatalogItem]`
    - `calendar(season: Int) -> [Meeting]`
    - `weekend(_ meeting: Meeting) -> WeekendContent`
    - `home() -> HomePage`
    - `collection(pageId: Int) -> CollectionPage`
    - `archiveRaces() -> [CatalogItem]`
    - `raceReplays(season: Int) -> [CatalogItem]`
    - `seasonVideos(season: Int) -> [CatalogItem]`
    - `video(contentId: Int) -> VideoDetail`
  - `public actor PlayCoordinator`, with:
    - `init(session: F1TVSession)`
    - `func play(contentId: Int, channelId: Int?) async throws -> PlayInfo`
    - `func stop()`
    - `var active: (contentId: Int, channelId: Int?)? { get }`

- [ ] **Step 1: Write failing tests.**
  - Each call requests the exact path and query from the spec, with the search filters copied from the Kotlin and listed in the order the Kotlin lists them. `weekend` falls back to the `filter_MeetingKey` search when `PAGE/{pageId}` returns 500 or an empty schedule.
  - `PlayCoordinator`:
    - Calling `play(1000010431, nil)` twice in a row sends one PLAY request.
    - `play(1000010431, 1016)` after that stops the first and sends a second request.
    - The request is `…/3.0/R/ENG/WEB_HLS/ALL/CONTENT/PLAY?contentId=1000010431&player=player_bm&channelId=1016`, with headers `ascendontoken`, `entitlementtoken` and `x-f1-device-info`.
    - A response with `laURL` throws `.protectedContent`. A 403 throws `.refused(status: 403)`. Signed out, it throws `.notSignedIn`.
- [ ] **Step 2:** Run `swift test --filter "CatalogueTests|PlayCoordinatorTests"`. Expected: compile failure.
- [ ] **Step 3:** Implement. Catalogue reads use `authorized: false` before sign-in and `true` after. `video` uses `VersionKind.video` with the entitlement header, and `play` uses `VersionKind.play`.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit and push.

### Task 6: Library: bookmarks, recents and watch history
**Model:** Haiku 5.5

**Files:**
- Create: `Packages/DuoCore/Sources/Library/WatchBookmark.swift`, `RecentsStore.swift`, `WatchHistory.swift`, `KeyValueStore.swift`
- Test: `Packages/DuoCore/Tests/LibraryTests/RecentsStoreTests.swift`, `WatchHistoryTests.swift`

**Interfaces:**
- Produces:
  - `public struct WatchBookmark: Codable, Sendable, Equatable`. Fields: `contentId: Int`, `title: String`, `picturePath: String?`, `channelId: Int?`, `positionMs: Int64`, `durationMs: Int64`, `live: Bool`, `savedAt: Date`.
  - `public protocol KeyValueStore: Sendable { func data(forKey: String) -> Data?; func set(_ data: Data?, forKey: String) }`, plus a `public final class MemoryStore: KeyValueStore` for tests.
  - `public final class RecentsStore: @unchecked Sendable`, with:
    - `init(store: any KeyValueStore, now: @escaping @Sendable () -> Date = Date.init)`
    - `func save(_: WatchBookmark)`
    - `func all() -> [WatchBookmark]`
    - `func remove(contentId: Int)`
    - It stores under the key `"recents"` and guards with a lock.
  - `public final class WatchHistory: @unchecked Sendable`, with:
    - `init(store:now:)`
    - `func record(contentId: Int, positionMs: Int64, durationMs: Int64)`
    - `func isFinished(_ contentId: Int) -> Bool`
    - `func watchedMs(_ contentId: Int) -> Int64`
    - It stores under the key `"history"`.

- [ ] **Step 1: Write failing tests.**
  - Saving 5 different items keeps the newest 4, newest first.
  - Saving the same `contentId` again moves it to the front without duplicating it.
  - Saving a replay with `positionMs >= durationMs - 60_000` removes it instead of storing it, but a live item at any position is kept.
  - `WatchHistory`:
    - Gaps between records over 15 s don't count as watched time.
    - An item is finished at 90% of its duration.
    - The history is capped at 300 entries, dropping the least recently recorded.
  - Data persists through a new store instance that uses the same `MemoryStore`.
- [ ] **Step 2:** Run `swift test --filter LibraryTests`. Expected: compile failure.
- [ ] **Step 3:** Implement with JSON in the store.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit and push.

### Task 7: Resume decision
**Model:** Sonnet 5.5

**Files:**
- Create: `Packages/DuoCore/Sources/Library/ResumePlan.swift`
- Test: `Packages/DuoCore/Tests/LibraryTests/ResumePlanTests.swift`

**Interfaces:**
- Consumes: `WatchBookmark` (Task 6). It takes the feed list as plain values so that `Library` doesn't depend on `F1TV`.
- Produces:
  - `public struct ResumePlan: Equatable, Sendable { public let channelId: Int?; public let start: Start }`
  - `public enum Start: Equatable, Sendable { case liveEdge, position(Int64) }`
  - `public static func make(bookmark: WatchBookmark, availableChannelIds: [Int?], defaultChannelId: Int?, isLiveNow: Bool, durationMs: Int64?) -> ResumePlan`

- [ ] **Step 1: Write failing tests** (Review Focus 5):
  - The saved channel is still available → use it, at the saved position.
  - The saved channel is gone → use the default channel, at the saved position.
  - The saved position is past the new duration → `.position(0)`.
  - The content is live now, or the bookmark says live → `.liveEdge`.
  - The bookmark had `channelId == nil` and nil is available → nil.
- [ ] **Step 2:** Run `swift test --filter ResumePlanTests`. Expected: compile failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit and push.

### Task 8: App project, configuration and networking (needs O-B)
**Model:** Sonnet 5.5. Verification is by the owner's local Mac session.

**Files:**
- Create: `project.yml`
- Create: `Config/Version.xcconfig`, `Config/Signing.xcconfig`, `Config/Signing.local.xcconfig.example`
- Create: `DuoApp/DuoApp.swift`, `DuoApp/Support/URLSessionHTTPClient.swift`, `DuoApp/Support/Keychain.swift`, `DuoApp/Support/AppModel.swift`, `DuoApp/Support/UserDefaultsStore.swift`
- Create: `DuoApp/Resources/Assets.xcassets` (empty app icon set), `DuoApp/Info.plist` keys via `project.yml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes:
  - `HTTPClient` (Task 2)
  - `F1TVSession`, `Catalogue`, `PlayCoordinator` (Tasks 3 and 5)
  - `RecentsStore`, `WatchHistory`, `KeyValueStore` (Task 6)
- Produces:
  - `@MainActor @Observable final class AppModel`, with:
    - `var auth: AuthState` (`.signedOut`, `.signingIn`, `.signedIn(Account)`)
    - `var message: String?`
    - `let session`, `catalogue`, `player: PlayCoordinator`, `recents`, `history`
    - `func restore() async`
    - `func signIn(token: String) async`
    - `func signOut()`
    - `func revalidate() async` (called on foreground)
  - `enum Keychain`, with `static func saveToken(_:)`, `static func loadToken() -> String?` and `static func deleteToken()`. It uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecAttrSynchronizable = false`.
  - `URLSessionHTTPClient: HTTPClient`, with a 15 s timeout and an ephemeral configuration so it never shares Safari's cookies.

- [ ] **Step 1:** Write `project.yml`:
  - One iOS app target, `DuoApp`, with iOS 27.1 as the deployment target. The local package `Packages/DuoCore` provides the products `F1TV` and `Library`.
  - Config files: `Config/Version.xcconfig` and `Config/Signing.xcconfig`. The latter `#include?`s the git-ignored `Config/Signing.local.xcconfig`, which holds `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM`.
  - Display name "Apex DuoView".
  - `INFOPLIST_KEY_UIBackgroundModes = audio`, so audio keeps playing when the app is backgrounded.
- [ ] **Step 2:** Write `Config/Version.xcconfig` with `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1` and `BETA_LABEL = beta.1`. Expose `BETA_LABEL` to the app through an Info.plist key `DuoBetaLabel = $(BETA_LABEL)`.
- [ ] **Step 3:** Implement `AppModel`, `Keychain`, `URLSessionHTTPClient` and `UserDefaultsStore: KeyValueStore`. `DuoApp.swift` shows a placeholder root view bound to `AppModel.auth`.
  - `restore()` loads the token from the Keychain and signs in. Any failure leaves the app signed out with the message, and the catalogue still loads anonymously through `prepare()`.
  - `revalidate()` re-runs sign-in when the app comes to the foreground (from `scenePhase`). If that returns `.refused`, it signs out and sets the message to "Your F1 TV sign-in has expired. Sign in again."
- [ ] **Step 4: Owner's Mac session verifies:**
  - Run `xcodegen generate`, then `xcodebuild -scheme DuoApp -destination 'generic/platform=iOS Simulator' build`.
  - Expected: `BUILD SUCCEEDED` with zero warnings from `DuoApp/` sources.
  - The build output goes back to the orchestrator.
- [ ] **Step 5:** Commit and push. Do not commit `Signing.local.xcconfig`.

### Task 9: Sign-in screens
**Model:** Sonnet 5.5

**Files:**
- Create: `DuoApp/SignIn/SignInView.swift`, `WebSignInView.swift`, `TokenPasteView.swift`, `PlanSheet.swift`

**Interfaces:**
- Consumes: `AppModel.signIn(token:)` and `signOut()` (Task 8); `LoginCookie.token(from:)` and `loginURL` (Task 3).

- [ ] **Step 1:** Build `WebSignInView`: a `WKWebView` on `LoginCookie.loginURL` with `customUserAgent = Endpoints.userAgent`.
  - Once a second, it reads `WKHTTPCookieStore.allCookies()`, looking for the `login-session` cookie on a `formula1.com` domain.
  - It passes the cookie's value through `LoginCookie.token(from:)`. On the first non-nil token it calls `signIn` and closes.
  - The screen's subtitle reads: "Sign in with your F1 TV email and password. Google sign-in doesn't work inside apps."
- [ ] **Step 2:** Build `TokenPasteView`: a multi-line `TextEditor` (no length limit) with a "Use this" button that runs `LoginCookie.token(from:)`. When that returns nil, it shows "That doesn't look like a login-session cookie or a subscription token."
- [ ] **Step 3:** Build `PlanSheet`, shown after sign-in when `!account.hasVideoPlan`. Its copy explains that a free F1 TV account can't play video, and that US F1 TV Premium through Apple TV needs the Apple account linked on F1 TV's website first. Its buttons are "OK" and "Sign out".
- [ ] **Step 4:** Make sign-out clear the cookies too: `WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)`.
- [ ] **Step 5:** Owner's Mac session builds it as in Task 8. Then the owner signs in once in the simulator and once on the phone. Expected: the app shows signed in with tier PREMIUM. If web sign-in fails on the phone, the paste route signs in.
- [ ] **Step 6:** Commit and push.

### Task 10: Rooms
**Model:** Sonnet 5.5

**Files:**
- Create:
  - `DuoApp/Rooms/RootView.swift`
  - `RaceWeekendRoom.swift`, `PaddockRoom.swift`, `ArchiveRoom.swift`
  - `SeasonView.swift`, `CollectionView.swift`, `DetailView.swift`
  - `Components/TileView.swift`, `Components/RowView.swift`, `Components/LoadState.swift`

**Interfaces:**
- Consumes: `Catalogue`, `CatalogItem`, `CatalogRow`, `WeekendContent.scheduleOver` and `scheduleDayToOpen` (Tasks 4 and 5); `AppModel` (Task 8).
- Produces: `DetailView(item: CatalogItem)`, which calls `onPlay(contentId: Int, channel: Channel)`. Task 11 handles that call.

- [ ] **Step 1:** Build `RootView`: `TabView` with `.tabViewStyle(.sidebarAdaptable)` and three tabs, Race Weekend, Paddock and Archive, plus a Settings button. It follows size class: tabs on the outer screen, sidebar on the inner screen.
- [ ] **Step 2:** Build `RaceWeekendRoom`. The rows, top to bottom:
  - Continue watching, from `recents.all()`. Each card shows a progress bar and "Xh Ym left", or "Live".
  - Live now.
  - The latest weekend's schedule, opened on the `scheduleDayToOpen` day. It is shown until `scheduleOver`. Upcoming items are dimmed and can't be tapped.
  - That weekend's F1 TV rows.
  - "Live now" refreshes every 60 s while the room is visible.
- [ ] **Step 3:** Build `PaddockRoom`: "Featured on F1 TV", then the `home()` rows. Poster rows use a 2:3 tile.
- [ ] **Step 4:** Build `ArchiveRoom`: "Popular races from the archive", then seasons from the current year back to 1981. `SeasonView` shows the weekends from 2018 on, and `seasonVideos` before that. BUNDLE tiles open `CollectionView`.
- [ ] **Step 5:** Build `DetailView`: image, title and the feed list from `video(contentId:)`.
  - With one channel it plays straight away. Otherwise the default channel comes first, then the onboards with number, driver and a bar in the team colour.
  - Signed out, the play button shows "Sign in to watch."
- [ ] **Step 6:** Every load error shows "Couldn't load F1 TV: <message>" with a "Try again" button that retries only that load.
- [ ] **Step 7:** Owner's Mac session builds it. Then, in the iPhone Duo simulator, folded and unfolded, each room loads and the São Paulo race shows its feeds.
- [ ] **Step 8:** Commit and push.

### Task 11: Player and resume
**Model:** Sonnet 5.5

**Files:**
- Create: `DuoApp/Player/PlayerView.swift`, `PlayerController.swift`, `ResumeBanner.swift`

**Interfaces:**
- Consumes:
  - `PlayCoordinator.play` and `stop` (Task 5)
  - `RecentsStore`, `WatchHistory` (Task 6)
  - `ResumePlan.make` (Task 7)
  - `DetailView.onPlay` (Task 10)
- Produces: `@MainActor @Observable final class PlayerController`, with:
  - `func start(item: CatalogItem, channel: Channel, startAt: Start) async`
  - `func close()`
  - `func resume(_ bookmark: WatchBookmark) async`
  - `var errorText: String?`

- [ ] **Step 1:** Build `PlayerView`: a `UIViewControllerRepresentable` around `AVPlayerViewController`, shown full screen. Its audio menu comes from AVKit with no custom code.
- [ ] **Step 2:** Build `PlayerController.start`:
  - It calls `PlayCoordinator.play` and makes an `AVPlayer` from `PlayInfo.url`.
  - For `.position(ms)` it seeks once the item is ready to play. For `.liveEdge` it lets AVKit start at the live edge.
  - `.protectedContent` shows "This session is protected and can't play in this app yet".
  - `.refused` shows "F1 TV won't play this on your account. Its plan may not include this session."
  - An `AVPlayerItem.failedToPlayToEndTime` or `.failed` status shows "This feed stopped: <localizedDescription>."
- [ ] **Step 3:** Save bookmarks:
  - every 5 s while playing (a periodic time observer)
  - when `scenePhase` becomes `.background`
  - on `close()`
  - `WatchHistory.record` runs at the same points.
  - `close()` also calls `PlayCoordinator.stop()`.
- [ ] **Step 4:** Build resume on cold start. If `recents.all().first` was saved less than 3 days ago, the room shows a `ResumeBanner` with the title, the position and a "Resume" button. `resume(_:)` does the following:
  1. Fetches `video(contentId:)`.
  2. Builds `ResumePlan.make(...)`.
  3. Calls `start`.
- [ ] **Step 5:** Owner's Mac session builds it. Then the owner, on the phone:
  1. Plays the São Paulo race.
  2. Switches commentary to Track FX.
  3. Seeks.
  4. Swipes the app away.
  5. Reopens it and taps Resume.
  Expected: it resumes within a few seconds of where it was.
- [ ] **Step 6:** Commit and push.

### Task 12: Fold adapter and Settings (needs O-C)
**Model:** Opus 5.5

**Files:**
- Create: `DuoApp/Fold/FoldState.swift`, `SystemFoldProvider.swift`, `FakeFoldProvider.swift`, `DuoApp/Support/SettingsView.swift`

**Interfaces:**
- Produces:
  - `enum Posture: String, Sendable { case closed, flat, book, laptop, unknown }`
  - `@MainActor @Observable final class FoldState`, with:
    - `var posture: Posture`
    - `var foldFrame: CGRect?` (in the root view's coordinates)
    - `var hingeAngle: Double?`
    - `var source: Source` (`.system` or `.fake`)
  - `.foldTracking(_ state: FoldState)`, a view modifier that `RootView` attaches.

- [ ] **Step 1:** The owner runs the following on the Mac and pastes the output:

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path); for m in SwiftUI UIKit; do f=$(find "$SDK/System/Library/Frameworks/$m.framework" -name "*.swiftinterface" | grep -m1 arm64e-apple-ios); grep -n -E "onHingeChange|reservedRegions|ReservedRegion|ArrangementView|struct Hinge|enum HingeStatus|UIHingeInteraction" "$f" | head -80; done
```

- [ ] **Step 2:** Implement `SystemFoldProvider` strictly from the pasted declarations:
  - `onHingeChange` gives the status and angle.
  - `GeometryProxy.reservedRegions(kind: .division)` gives the fold frame.
  - Posture is derived from the status and the fold's orientation: closed → `.closed`; fully open → `.flat`; partially open with a vertical fold → `.book`; partially open with a horizontal fold → `.laptop`.
  - Anything else is `.unknown`. Don't add `standing` unless the declarations expose a way to detect it.
- [ ] **Step 3:** Build `FakeFoldProvider`, set from a debug section in Settings with a posture picker and an angle slider.
- [ ] **Step 4:** Build `SettingsView`. It contains:
  - Account: tier, and "Sign out".
  - A live readout of `FoldState`.
  - About: "Apex DuoView v1.0-beta.1 (build N)", from the bundle version and `DuoBetaLabel`.
  - Credits and licences for Apexview, eXhumer/f1tv-api, eXhumer/eXViewer, FastF1 and MultiViewer.
  - The debug section.
- [ ] **Step 5:** Owner's Mac session builds it. In the Duo simulator, folding, half-opening and rotating change the readout.
- [ ] **Step 6:** Commit and push.

### Task 13: Multiview probe (debug)
**Model:** Sonnet 5.5

**Files:**
- Create: `DuoApp/Debug/MultiviewProbeView.swift`

**Interfaces:**
- Consumes:
  - `Catalogue.video`
  - `F1TVSession` (it makes its own PLAY requests; the probe bypasses `PlayCoordinator` and calls `Parsers.play` on `getJSON` results)
  - Settings' debug section (Task 12)

- [ ] **Step 1:** Build a screen, reached from Settings → Debug, that does the following for a content ID field (default `1000010431`):
  - Fetches the feed list and picks the default feed plus 3 onboards.
  - Makes one `player_bm` PLAY request per feed, 1 second apart, and starts four muted `AVPlayer`s in a 2×2 grid.
  - Per player, shows the time to first frame, the stall count (from `AVPlayerItem.playbackStallTime` notifications), dropped frames from `AVPlayerItemAccessLog` (`numberOfDroppedVideoFrames`), and the indicated bitrate.
  - Has a "Copy report" button that copies these numbers as text, with no URLs.
- [ ] **Step 2:** Owner's Mac session builds it. The owner runs it on the 15 Pro Max for 2 minutes and pastes the report. Not part of the exit test.
- [ ] **Step 3:** Commit and push.

### Task 14: Review and release v1.0-beta.1
**Model:** Opus 5.5 reviews. Haiku 5.5 writes the changelog.

- [ ] **Step 1:** Opus reviews the whole branch against the spec and this plan's Review Focus, and fixes what it finds.
- [ ] **Step 2:** The owner runs the exit test on the 15 Pro Max: sign in, play the São Paulo race replay, close the app, reopen it, tap Resume, and it resumes at the same moment. Pass or fail is the owner's call.
- [ ] **Step 3:** Haiku moves the CHANGELOG "Unreleased" entries into `## v1.0-beta.1 — Foundation (2026-MM-DD)` and starts a new empty "Unreleased" section.
- [ ] **Step 4:** Tag and release:

```bash
git tag -a v1.0-beta.1 -m "v1.0-beta.1 — Foundation"
git push origin v1.0-beta.1
```

  Create a GitHub Release from that tag with the title "v1.0-beta.1 — Foundation", marked as a pre-release and not "Latest". Its notes are the changelog section. If this session can't create a release, the owner creates it on GitHub with those exact settings.
- [ ] **Step 5:** Raise `CURRENT_PROJECT_VERSION` for the next build, then commit and push.
