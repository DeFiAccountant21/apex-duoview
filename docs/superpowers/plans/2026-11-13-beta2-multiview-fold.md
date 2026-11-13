# v1.0-beta.2 — Multiview and fold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Up to four feeds of one F1 TV session play together in step, laid out to fit each fold of the iPhone Duo, with feed picking, presets, speed, picture in picture and resume.

**Architecture:** One `player_tm` PLAY returns every feed's URL; the app runs one `AVPlayer` per shown feed inside a model-owned `MultiviewController`, kept in step by program-date-time. Everything testable without a device (multiview parsing, feed identity, the picks and presets store, layout geometry, sync and struggle rules) lives in DuoCore: the existing `F1TV` target and a new `Multiview` target, tested on Linux. SwiftUI tile views only show players; posture changes animate their frames.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, SwiftUI, AVFoundation/AVKit, XcodeGen, GitHub Actions. iOS 27.1, iPhoneOS 27.2 SDK. Linux toolchain here: Swift 6.4.1 at `/opt/swift`.

**Spec:** [docs/superpowers/specs/2026-11-13-beta2-multiview-fold-design.md](../specs/2026-11-13-beta2-multiview-fold-design.md). Read it before any task. Beta.1's spec and code are the base this builds on.

## Global Constraints

- iOS 27.1 deployment target; Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`. App types that touch UI or AVFoundation objects are `@MainActor`; callbacks from AVFoundation queues are `@Sendable` and hop to the main actor with plain values (every beta.1 compile error was main-actor isolation).
- DuoCore imports Foundation only (no SwiftUI, UIKit, AVFoundation, CoreGraphics import beyond what Foundation re-exports: `CGRect`, `CGSize`, `CGFloat` come from Foundation on Linux). No third-party dependencies anywhere.
- One multiview PLAY per opened multiview: `CONTENT/PLAY` with `player=player_tm`, platform `WEB_DASH`, `channelId` = the session's default channel, the Android web player's device header (`os=android;browser=chrome`, `p=true`) and its Android Chrome User-Agent: with Safari's header F1 TV sends one `SWITCHER` feed, with Android's all of them (`MULTI`; owner probe 2026-11-13). Swaps, presets, layout changes and fold changes never send another PLAY. The only second `player_tm` PLAY is the expired-link refresh (spec "Expired links").
- Multiview is for tiers `OPS`, `VIP`, `PREMIUM` (`Account.hasMultiview`) and sessions with at least two feeds.
- Layout rules: tiles are 16:9, aspect-fit, never cropped; 6 pt from screen edges and between tiles; no tile narrower than 200 pt; tiles never enter the fold region (fold frame grown by 6 pt) except "across the fold". Default and ⟳ order per posture and feed count exactly as the spec's table; laptop's "row of three" is not built.
- Sync: tolerance 0.1 s, seek threshold 1.0 s, against the main feed's program date; position-based when a stream has no program-date-time.
- Speeds: 0.5, 0.75, 1, 1.25, 1.5, 2; not offered at the live edge.
- Presets: at most 8. Default four: world feed (`INTERNATIONAL`), the owner's driver's onboard (`MultiviewStore.favouriteDriver`; empty spot until picked), `TRACKER`, `DATA` (owner, 2026-11-13; was `F1 LIVE`).
- Fixed copy: "Watch multiview"; "Multiview needs F1 TV Premium"; "Not available for this race"; "Pick a feed"; "Keep four spots"; "Fit \(n) to the screen"; "You can change this any time in Settings › Multiview."; "Paused to keep the main feed smooth"; "Saved for beta.3: timing tower + track map"; "From the start"; "Watch live"; "Save as preset"; "Clear all"; "Reset to default"; "Switch layout" (with ⟳). Beta.1 copy stays as it is.
- Style from beta.1's `Theme` (background `#0A0A0B`, surfaces, silver text, racing red only for primary actions, the SOUND badge, progress and LIVE).
- Tokens, entitlement tokens and signed stream URLs are never logged, printed, put in errors or committed. Fixtures are sanitised.
- Space kept for a later beta is drawn and labelled where it shows.
- `Config/Version.xcconfig`: `BETA_LABEL = beta.2`; raise `CURRENT_PROJECT_VERSION` for each build handed to the owner.
- Commits end with the attribution lines in the session's instructions. Push to `ios` only. Never merge `og-android`.
- The app can't be compiled in the cloud session: app tasks are written to compile first time and are checked by the owner's builds at the checkpoints below.

## Review Focus

1. **A swap or preset after the links have expired, late in a long race.** Opening a new feed fails → one fresh `player_tm` PLAY, all four reattached at the current position, in step; never a second PLAY otherwise. Tests in Task 2 (coordinator refresh) and Task 7 (controller path, by owner check).
2. **Remembered feeds that don't exist in this session** (a driver not racing, an older race without F1 Live, a session with only two or three feeds): those slots resolve to nothing, never to a wrong feed and never the same feed twice; the fewer-feeds preference then decides placeholders or fit. Tests in Task 3 and Task 5.
3. **A feed that stalls or a fold change mid-buffering:** no restart; when it recovers it is seeked back to the main feed's date, not left behind. Tests in Task 6 (policy) and the owner's exit test.
4. **Older content:** `WEB_DASH` multiview answers with DASH or no program-date-time. DASH → "Not available for this race"; no program-date-time → position-based sync, no crash. Tests in Task 2 and Task 6.
5. **Preset names and limits:** empty or whitespace names, names over 30 characters, duplicates, a ninth preset, renaming a deleted one. Refused with a clear error, the store unchanged. Tests in Task 5.

---

## Owner steps (not agent tasks)

- **O-A (after Task 1):** run `python3 spike/stream_check.py --dump-multiview <São Paulo race URL>` on the Mac with the sign-in on the clipboard as in beta.1, and send `spike/multiview-fixtures.zip` and the printed summary. **Gate:** if the São Paulo `player_tm` request on `WEB_DASH` doesn't return HLS feeds, stop here and go back to the owner (spec "Safety step").
- **O-B (any time before Task 8):** with the beta.1 build in the iPhone Duo simulator, play a feed, then (1) close the simulator to the outer screen, (2) reopen, (3) turn it into laptop posture if the simulator allows it. Report for each: did playback continue, pause or restart; did the app's screen keep its state; is laptop reachable with the real hinge or only with Settings › Debug › Simulate fold.
- **O-C (after Task 7, Task 8, Task 10 and Task 13):** pull, `xcodegen generate`, build with the zero-warnings command from beta.1, run in the iPhone Duo simulator, report what the task's check list asks.
- **O-D (after Task 13):** the exit test: four São Paulo 2026 race feeds for 10 minutes without stalling; closed, book, flat and laptop keep the same four feeds in step at the same moment.

---

### Task 1: Multiview request check and fixtures in the stream check
**Model:** Sonnet 5.5

**Files:**
- Modify: `spike/stream_check.py`
- Modify: `spike/.gitignore` (add `multiview-fixtures/`, `multiview-fixtures.zip`)

**Interfaces:**
- Produces: a `--dump-multiview <content URL or id>` flag. Files (fixed names; Task 2 reads the first): `multiview-fixtures/play-1000010431-multiview-WEB_DASH.json`, `play-1000010431-multiview-WEB_HLS.json`, `play-<oldId>-multiview-WEB_DASH.json`, zipped to `multiview-fixtures.zip`.

- [ ] **Step 1:** Add `dump_multiview(content_id, token)`: sign in as `--dump-catalogue` does, then send `CONTENT/PLAY?contentId=<id>&player=player_tm&channelId=<default channel>` on `WEB_DASH` and on `WEB_HLS`, with the Safari device info and `p=true`. The default channel is the stream with `default: true` in `CONTENT/VIDEO`.
- [ ] **Step 2:** For each response, before sanitising, record into the JSON: `"_feed_count"` (length of `resultObj.tme.feeds`), `"_url_kinds"` (per feed: `m3u8`, `mpd` or `other`), `"_has_laURL"`, and `"_url_expiry_seconds"`: seconds from now to the expiry found in the first feed URL's query (`exp`, `expires`, `Expires`, or a JWT `exp` in a token parameter), or `null`. Then sanitise with the existing `sanitize()` and write. Print a summary line per request: platform, HTTP status, feed count, URL kinds, expiry. No URL is ever printed.
- [ ] **Step 3:** Also run the `WEB_DASH` request for the oldest race in `ARCHIVE races` (the first item of the archive rail whose year is before 2023); name the file with its content id; print its summary.
- [ ] **Step 4:** Run `python3 -I -m py_compile spike/stream_check.py`. Expected: no output.
- [ ] **Step 5:** Commit: `git add spike/stream_check.py spike/.gitignore && git commit -m "Stream check: --dump-multiview records the player_tm request"`.

---

### Task 2: Multiview PLAY in the F1TV library
**Model:** Sonnet 5.5
**Needs:** O-A's `play-1000010431-multiview-WEB_DASH.json` copied into `Packages/DuoCore/Tests/F1TVTests/Fixtures/`.

**Files:**
- Modify: `Packages/DuoCore/Sources/F1TV/Models.swift`, `Parsers.swift`, `F1TVError.swift`, `Session.swift`, `PlayCoordinator.swift`
- Test: `Packages/DuoCore/Tests/F1TVTests/MultiPlayTests.swift`

**Interfaces:**
- Produces:
  - `public struct MultiPlayInfo: Sendable, Equatable { public var feeds: [Int: URL]; public var licenseURL: URL?; public var streamType: String }` (key = channel id).
  - `Parsers.multiPlay(_ json: JSONValue) throws -> MultiPlayInfo`: reads `resultObj.tme.feeds[].metadata.channel_id` and `.url`; throws `.badResponse` when there are no usable feeds; throws `.multiviewUnavailable` when `streamType` is not `HLS` or any feed URL path ends in `.mpd`; throws `.protectedContent` when `laURL` is present.
  - `F1TVError.multiviewUnavailable` (new case).
  - `F1TVSession.getJSON(path:version:platform:query:authorized:multiview:)`, new `multiview: Bool = false` parameter used for the play device header (`Endpoints.deviceInfo(multiview:)`).
  - `PlayCoordinator.playMultiview(contentId: Int, defaultChannelId: Int?, refresh: Bool = false) async throws -> MultiPlayInfo`: same one-session rules as `play` (asking again for the active multiview returns it without a request; a different item replaces it; `stop()` ends it), except `refresh: true` always sends a new request for the same content. A single-feed `play` replaces an active multiview and vice versa.

- [ ] **Step 1: Write the failing tests** in `MultiPlayTests.swift`:
  - `parsesRecordedSaoPauloMultiview`: parse the fixture; `feeds.count == fixture["_feed_count"]` (capped at 6 by the sanitiser), every key is a `channelId` listed in `video-1000010431-WEB_DASH.json`, `streamType == "HLS"`. (The fixture's URLs are `<removed>`, so build the test's JSON by replacing each feed's `url` with `https://example.com/<channel>.m3u8` before parsing.)
  - `missingFeedsIsBadResponse`, `dashIsMultiviewUnavailable` (`streamType: "DASH"`), `mpdURLIsMultiviewUnavailable`, `licenseURLIsProtected`: inline JSON.
  - `requestUsesPlayerTmOnWebDASHWithMultiviewHeader`: `FakeHTTPClient` sees one request whose path contains `/WEB_DASH/` and `CONTENT/PLAY`, query `player=player_tm` and `channelId=1033`, header `x-f1-device-info` containing `p=true`.
  - `askingAgainSendsNoSecondPlay`, `refreshSendsANewPlay`, `singlePlayReplacesMultiview`.
- [ ] **Step 2:** Run `cd Packages/DuoCore && /opt/swift/usr/bin/swift test --filter MultiPlayTests`. Expected: FAIL (types missing).
- [ ] **Step 3:** Implement the interfaces above. `PlayCoordinator`'s `Key` gains `multiview: Bool`; the existing generation logic is reused, not duplicated.
- [ ] **Step 4:** Run `swift test` (whole package). Expected: all pass, including the beta.1 suites.
- [ ] **Step 5:** Commit.

---

### Task 3: Multiview target, feed identity and slot resolution
**Model:** Sonnet 5.5

**Files:**
- Modify: `Packages/DuoCore/Package.swift` (new target `Multiview` depending on `F1TV` and `Library`; product `Multiview`; test target `MultiviewTests` with `resources: [.copy("Fixtures")]`)
- Modify: `project.yml` (DuoApp depends on product `Multiview`)
- Create: `Packages/DuoCore/Sources/Multiview/FeedPick.swift`
- Test: `Packages/DuoCore/Tests/MultiviewTests/FeedPickTests.swift`

**Interfaces:**
- Produces:
  - `public enum FeedPick: Codable, Hashable, Sendable { case worldFeed, f1Live, tracker, data, onboard(lastName: String), other(title: String) }`
  - `FeedPick.init(_ channel: Channel)`: title (trimmed, uppercased) `INTERNATIONAL` → `.worldFeed`, `F1 LIVE` → `.f1Live`, `TRACKER` → `.tracker`, `DATA` → `.data`; `isOnboard` with a last name → `.onboard(lastName:)`; else `.other(title:)`.
  - `FeedPick.matches(_ channel: Channel) -> Bool` (onboard last names compare case- and diacritic-insensitively).
  - `public static let defaultFour: [FeedPick] = [.worldFeed, .f1Live, .tracker, .data]`
  - `public static func resolve(_ picks: [FeedPick?], in channels: [Channel]) -> [Channel?]`: one entry per pick, the first unused matching channel or nil; a channel is never used twice; channels with a nil id are never used.

- [ ] **Step 1: Write the failing tests** using the São Paulo channels from `video-1000010431-WEB_HLS.json` built inline (1033 `F1 LIVE` default, 1025 `INTERNATIONAL`, 1003 `TRACKER`, 1004 `DATA`, obc 1016 Norris #1, obc 1009 Verstappen #3):
  - `classifiesSaoPauloFeeds`: 1025 → `.worldFeed`, 1033 → `.f1Live`, 1003 → `.tracker`, 1004 → `.data`, 1016 → `.onboard(lastName: "Norris")`.
  - `defaultFourResolvesInOrder`: `[1025, 1033, 1003, 1004]`.
  - `onboardMatchesByNameNotNumber`: a pick `.onboard(lastName: "norris")` resolves to a Norris channel numbered 4.
  - `missingPickIsNil`: `.onboard(lastName: "Senna")` → nil; `.f1Live` in a session without it → nil.
  - `sameFeedNeverTwice`: picks `[.worldFeed, .worldFeed]` → `[1025, nil]`.
- [ ] **Step 2:** Run `swift test --filter FeedPickTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `FeedPick` and the package/project changes.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit.

---

### Task 4: Layout engine
**Model:** Sonnet 5.5

**Files:**
- Create: `Packages/DuoCore/Sources/Multiview/LayoutEngine.swift`
- Test: `Packages/DuoCore/Tests/MultiviewTests/LayoutEngineTests.swift`
- Fixture (already committed): `Packages/DuoCore/Tests/MultiviewTests/Fixtures/layouts-reference.json`; generator `spike/layout_search.py`.

**Interfaces:**
- Produces:
  - `public enum Posture: String, Codable, Sendable, CaseIterable { case closed, flat, book, laptop, unknown }` (the app maps its own `Posture` to this one).
  - `public struct TileFrame: Equatable, Sendable { public var rect: CGRect; public var visible: Bool }`
  - `public enum LayoutEngine` with:
    - `static func optionIDs(posture: Posture, feedCount: Int) -> [String]`: the spec table's order (default first). `unknown` uses flat's; `closed` → `["closed.main"]`. IDs: flat `flat.full` (1); `flat.mainBelow`, `flat.twoStacked` (2); `flat.mainBelow`, `flat.pyramid` (3); `flat.mainBelow`, `flat.mainBesideBelow`, `flat.grid` (4); book `book.across`, `book.oneSide` (1); `book.perScreen`, `book.across` (2); `book.oneLeftTwoRight`, `book.across` (3); `book.twoPerScreen`, `book.across` (4); laptop `laptop.mainUp` (1); `laptop.oneUpOneDown` (2); `laptop.twoStacked`, `laptop.twoSideBySide` (3); `laptop.pyramid` (4).
    - `static func frames(screen: CGSize, foldFrame: CGRect?, posture: Posture, feedCount: Int, optionID: String?) -> [TileFrame]`: exactly `feedCount` frames, index 0 = main; an unknown or nil `optionID` means the default. Hidden tiles (`visible: false`: the others in `book.across` and `closed.main`) take the main tile's rect. Book or laptop with `foldFrame == nil` falls back to flat. Closed: the main tile aspect-fits the whole screen with no margin.
    - `static func reservedArea(screen: CGSize, foldFrame: CGRect?, posture: Posture, feedCount: Int) -> CGRect?`: the laptop lower region (below the fold region, 6 pt margins) when posture is laptop and `feedCount == 1`, else nil (it carries the "Saved for beta.3" label).
    - `static func screenUse(_ frames: [TileFrame], screen: CGSize) -> Double` (visible area ÷ screen area).
  - Geometry: margin 6, gap 6, min width 200, 16:9; regions are the screen inset by 6, split around the fold frame grown by 6. Within a region, shapes are "one", "main + others below/beside" with the main as large as fits and the others sharing what's left, "column", "two over one" (pyramid), "2 × 2"; groups are centred in their region. The reference JSON pins the results.

- [ ] **Step 1: Write the failing tests:**
  - `matchesReferenceFrames`: for every entry in `layouts-reference.json`, `frames(screen:` 951 × 669 (laptop: 669 × 951) `, foldFrame:` x 456–496 full height (laptop: y 456–496 full width) `, posture, feedCount, optionID: id)`; the visible frames equal the entry's `frames` within 0.5 pt, and the count of visible frames equals `visible`.
  - `defaultsAreFirstOption`: `optionIDs(posture: .book, feedCount: 1).first == "book.across"`, `(.flat, 4).first == "flat.mainBelow"`, `(.laptop, 4) == ["laptop.pyramid"]`.
  - `screenUseFloors`: defaults for 4 feeds: flat ≥ 0.906, book ≥ 0.696, laptop ≥ 0.663 (spec table).
  - `everyTileIs16x9OnScreenAndWideEnough`: for all postures, counts 1–4, all options, screens 951 × 669 and 669 × 951 and 1020 × 700: each visible rect within the screen, width ≥ 200, `abs(width * 9 / 16 - height) < 0.5`.
  - `nothingCrossesTheFoldUnlessAcross`: for book and laptop options other than `book.across`, no visible rect intersects the fold frame.
  - `bookWithoutFoldFallsBackToFlat`, `closedFillsScreen` (390 × 844 outer screen in landscape 844 × 390: main width 693.3, centred), `reservedAreaOnlyForLaptopOneFeed`.
- [ ] **Step 2:** Run `swift test --filter LayoutEngineTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. `spike/layout_search.py` shows the search the reference came from; port the chosen shapes, not the search.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit.

---

### Task 5: Picks, presets and preferences store
**Model:** Sonnet 5.5

**Files:**
- Create: `Packages/DuoCore/Sources/Multiview/MultiviewStore.swift`
- Test: `Packages/DuoCore/Tests/MultiviewTests/MultiviewStoreTests.swift`

**Interfaces:**
- Consumes: `FeedPick` (Task 3), `Posture` (Task 4), `KeyValueStore`/`MemoryStore` (Library).
- Produces:
  - `public struct Preset: Codable, Equatable, Sendable, Identifiable { public let id: UUID; public var name: String; public var picks: [FeedPick?]; public var layouts: [String: String] }` (`layouts` key = `LayoutKey.string`, value = layout option id).
  - `public struct LayoutKey: Hashable, Sendable { public var posture: Posture; public var feedCount: Int; public var string: String }` (`"book.4"`), with `Posture` from Task 4.
  - `public enum FewerFeeds: String, Codable, Sendable { case ask, keepSpots, fit }`
  - `public enum PresetError: Error, Equatable { case emptyName, nameTooLong, duplicateName, full, notFound }`
  - `public final class MultiviewStore: @unchecked Sendable` (lock-protected like `RecentsStore`), init `(store: any KeyValueStore)`, with: `defaultPicks: [FeedPick?]` (get/set; starts as `FeedPick.defaultFour`), `lastUsed: [FeedPick?]` (get/set; starts as `defaultPicks`), `resetToDefault()` (lastUsed = defaultPicks), `presets: [Preset]`, `savePreset(name: String, picks: [FeedPick?], layouts: [String: String]) throws -> Preset`, `renamePreset(id: UUID, to: String) throws`, `updatePreset(id: UUID, picks: [FeedPick?], layouts: [String: String]) throws`, `deletePreset(id: UUID)`, `layoutChoice(for: LayoutKey) -> String?`, `setLayoutChoice(_: String, for: LayoutKey)`, `fewerFeeds: FewerFeeds` (get/set; starts `.ask`).
  - Constants: `MultiviewStore.maxPresets = 8`, `maxNameLength = 30`. Names are trimmed; duplicates compare case-insensitively.

- [ ] **Step 1: Write the failing tests:** `startsWithDefaultFour`, `lastUsedPersistsAcrossInstances` (two stores on one `MemoryStore`), `resetToDefaultRestoresDefaults`, `changingDefaultsChangesReset`, `savesAndRenamesPreset`, `ninthPresetIsRefused` (`.full`, count stays 8), `emptyAndWhitespaceNamesRefused`, `thirtyOneCharacterNameRefused`, `duplicateNameRefusedCaseInsensitive`, `renamingMissingPresetIsNotFound`, `layoutChoiceIsPerPostureAndCount`, `fewerFeedsDefaultsToAsk`.
- [ ] **Step 2:** Run `swift test --filter MultiviewStoreTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Persist as JSON under keys `multiview.defaults`, `multiview.lastUsed`, `multiview.presets`, `multiview.layouts`, `multiview.fewerFeeds`.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit.

---

### Task 6: Sync and struggle rules
**Model:** Haiku 5.5

**Files:**
- Create: `Packages/DuoCore/Sources/Multiview/SyncPolicy.swift`
- Test: `Packages/DuoCore/Tests/MultiviewTests/SyncPolicyTests.swift`

**Interfaces:**
- Produces:
  - `public enum SyncAction: Equatable, Sendable { case none, nudge(rate: Double), seek(by: Double) }`
  - `public enum SyncPolicy` with `tolerance = 0.1`, `seekThreshold = 1.0`, `nudgeFraction = 0.03`, `speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]`, and `static func action(offset: Double?, baseRate: Double) -> SyncAction`. `offset` = this feed's time minus the main feed's (seconds; positive = ahead); nil (no comparable time) → `.none`; `|offset| <= 0.1` → `.none`; `0.1 < |offset| <= 1.0` → `.nudge(rate: baseRate * (1 ∓ 0.03))` (slower when ahead); `> 1.0` → `.seek(by: -offset)`.
  - `public struct StruggleMonitor: Sendable` with `mutating func record(stall at: Date)`, `mutating func record(droppedFrames: Int, over seconds: Double, at: Date)`, `func shouldFreezeOthers(at: Date) -> Bool`: true when 2 or more stalls in the last 30 s, or more than 10 dropped frames per second averaged over the last 10 s; `mutating func reset()`.

- [ ] **Step 1: Write the failing tests:** `inToleranceDoesNothing` (0.1 → none), `aheadIsSlowed` (0.5 at 1× → nudge 0.97), `behindIsSpedUp` (−0.5 at 2× → nudge 2.06), `farOffIsSeeked` (2.5 → seek −2.5), `noTimeDoesNothing` (nil), `twoStallsFreeze`, `oldStallsExpire` (stalls 31 s apart → false), `droppedFrameRateFreezes`, `resetClears`, `speedsAreFixed`.
- [ ] **Step 2:** Run `swift test --filter SyncPolicyTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit.

---

### Task 7: Multiview player (fixed flat layout)
**Model:** Opus 5.5

**Files:**
- Create: `DuoApp/Multiview/MultiviewController.swift`, `DuoApp/Multiview/MultiviewView.swift`, `DuoApp/Multiview/FeedTile.swift`
- Modify: `DuoApp/Support/AppModel.swift` (own a `MultiviewController`; sign-out and `expire` also close it), `DuoApp/Rooms/RootView.swift` (a full-screen cover for multiview beside the single-feed one), `DuoApp/Rooms/DetailView.swift` (the entry), `Config/Version.xcconfig` (`BETA_LABEL = beta.2`, build number +1)

**Interfaces:**
- Consumes: `PlayCoordinator.playMultiview` (Task 2), `FeedPick`, `MultiviewStore` (Tasks 3 and 5), `SyncPolicy`, `StruggleMonitor` (Task 6).
- Produces (`@MainActor @Observable final class MultiviewController`):
  - `init(coordinator: PlayCoordinator, store: MultiviewStore, recents: RecentsStore, history: WatchHistory)`
  - `func open(item: CatalogItem, detail: VideoDetail, startAt: Start) async`, `func close()`
  - `private(set) var isPresented: Bool`, `isLoading: Bool`, `errorText: String?`
  - `private(set) var slots: [Channel?]` (four entries, index 0 = main, sound on 0), `private(set) var channels: [Channel]` (the session's)
  - `func player(for channelId: Int) -> AVPlayer?`
  - `func makeMain(slot: Int)`, `func setFeed(_ channel: Channel?, at slot: Int)`
  - `func play()`, `func pause()`, `func seek(toSeconds: Double)`, `func setRate(_: Double)`, `private(set) var isPaused: Bool`, `rate: Double`, `othersFrozen: Bool`
- Behaviour:
  - `open` resolves `store.lastUsed` against `detail.channels` (`FeedPick.resolve`), sends one `playMultiview`, creates one `AVPlayer` per filled slot, all muted except slot 0, starts them together at the start position, and saves `lastUsed` on every slot change.
  - A sync tick every 0.5 s reads each item's `currentDate()` (fallback: `currentTime()`) and applies `SyncPolicy.action` against slot 0.
  - Non-main items get `preferredMaximumResolution` = their tile size × screen scale and `preferredPeakBitRate` 2_500_000; slot 0 unlimited.
  - `StruggleMonitor` fed from `AVPlayerItemPlaybackStalled` and the access log (`fetchAccessLog`, completion-handler form, `@Sendable`, as beta.1's probe fix); when it says freeze, pause non-main players and set `othersFrozen`; tapping or 30 s without a stall resumes them and seeks them to slot 0's date.
  - A player whose item fails with HTTP 403/410 (expired link) triggers `playMultiview(..., refresh: true)` once and reattaches all slots at slot 0's current position.
  - Errors use beta.1's messages; `F1TVError.multiviewUnavailable` → "Not available for this race".
  - The bookmark and watch history are saved as the single-feed player does (every 5 s, background, close), for slot 0's position.
- `MultiviewView`: black background; one `FeedTile` per filled slot, in a fixed flat "main + below" arrangement for now (Task 8 replaces it); a close button. `FeedTile` shows an `AVPlayerLayer` for its player (a `UIViewRepresentable` whose layer class is `AVPlayerLayer`, `videoGravity` `.resizeAspect`), the feed's name, and the red "SOUND" badge on slot 0. Tile views are keyed by channel id.
- `DetailView`: when signed in and `detail.channels.count >= 2`, a "Watch multiview" primary button above the feed list if `account.hasMultiview`, otherwise the text "Multiview needs F1 TV Premium".

- [ ] **Step 1:** Implement the controller, views and wiring above.
- [ ] **Step 2:** Self-check for Swift 6 isolation: every AVFoundation callback closure is `@Sendable`, extracts plain values, and hops with `Task { @MainActor in … }`; no `AVPlayer` crosses an actor boundary.
- [ ] **Step 3:** Commit.
- [ ] **Step 4 (owner, O-C):** build (zero warnings), open São Paulo 2026 race, Watch multiview: four feeds play, the world feed has the sound, they look in step; tap Close and reopen.

---

### Task 8: Fold-driven layouts, switching and gestures
**Model:** Opus 5.5

**Files:**
- Modify: `DuoApp/Multiview/MultiviewView.swift`, `DuoApp/Multiview/MultiviewController.swift`
- Create: `DuoApp/Multiview/ReservedArea.swift`

**Interfaces:**
- Consumes: `LayoutEngine` (Task 4), `MultiviewStore.layoutChoice` (Task 5), beta.1's `FoldState` from the environment.
- Produces: `MultiviewController.layoutOption(for: Multiview.Posture, feedCount: Int) -> String` and `cycleLayout(posture:feedCount:)` (stores the choice).

- [ ] **Step 1:** Map `FoldState.posture` to `Multiview.Posture` (a root narrower than 600 pt, such as the outer screen or a phone in portrait, counts as `closed`); the screen size and fold frame come from `FoldState.rootSize` and `foldFrame` (full-screen coordinates, as `SettingsPanel` uses).
- [ ] **Step 2:** Lay tiles out with `LayoutEngine.frames` in a full-screen `GeometryReader` that ignores the safe area; each tile is positioned with `.frame` and `.position` from its `TileFrame`, hidden tiles at opacity 0, and the whole arrangement animates with `.animation(.snappy, value:)` on the frames (the beta.1 `SettingsPanel` technique: same views, frames animate; never `if`/`else` between layouts).
- [ ] **Step 3:** Draw `ReservedArea` (dashed outline, "Saved for beta.3: timing tower + track map") when `LayoutEngine.reservedArea` is non-nil.
- [ ] **Step 4:** Tap a non-main tile → `makeMain(slot:)` (trades places with the main; tapping the old main trades back). Press-and-hold then drag a tile onto another → `moveFeed(from:to:)` (trades the two slots; the dragged tile follows the finger, the others keep their frames, the drop animates with the layout glide). Closed posture: horizontal swipe changes the main feed through the filled slots. "Switch layout" (⟳) button in the controls when `optionIDs` has more than one entry.
- [ ] **Step 4b (owner change, 2026-11-13): sound apart from the main spot.** The controller gains `private(set) var audioChannelId: Int?` and `func setAudio(channelId: Int)`: exactly one feed is unmuted; opening starts with the main feed; `makeMain`, `moveFeed` and fold/layout changes never move it; if the feed with the sound is removed or ends, the sound goes to the main feed. Each `FeedTile` gets a speaker button (SF Symbol `speaker.wave.2.fill` on the feed with the sound, `speaker.slash` on the others, 44 pt hit area, top-right) that calls `setAudio`; the red "SOUND" badge shows on the feed with the sound, not on slot 0. The struggle freeze never freezes the feed with the sound (it is treated like the main feed for freezing).
- [ ] **Step 5:** Commit.
- [ ] **Step 6 (owner, O-C):** in the Duo simulator: each posture's default layout; ⟳ in flat and book; tap to make main and tap back; drag a feed onto another; put the sound on a small feed and swap feeds (the sound stays); close to the outer screen and swipe; unfold again. Nothing restarts, feeds stay in step, the glide is smooth.

---

### Task 9: Feeds editor, presets and the fewer-feeds prompt
**Model:** Sonnet 5.5

**Files:**
- Create: `DuoApp/Multiview/FeedsEditor.swift`, `DuoApp/Multiview/PresetsView.swift`, `DuoApp/Multiview/FewerFeedsPrompt.swift`
- Modify: `DuoApp/Multiview/MultiviewController.swift`, `DuoApp/Multiview/MultiviewView.swift`, `DuoApp/Support/SettingsView.swift` (a "Multiview" section)

**Interfaces:**
- Consumes: `MultiviewStore`, `FeedPick`, controller slot methods.
- Produces: `MultiviewController.clearAll()`, `resetToDefault()`, `apply(_ preset: Preset)`, `saveAsPreset(name: String) throws`; `MultiviewController.effectiveFeedCount: Int` (4 when `keepSpots`, else filled slots).

- [ ] **Step 1:** Feeds editor sheet: four slots ("Pick a feed" when empty), tap a slot to choose from the session's channels (names as beta.1's `Channel.displayTitle`, team colour bar for onboards), "Clear all", "Reset to default", "Save as preset", and "Make these my default" (sets `defaultPicks`).
- [ ] **Step 2:** Presets list: apply, rename, update with the current setup, delete; `PresetError` cases shown as plain messages ("Give the preset a name.", "Names can be up to 30 characters.", "You already have a preset with that name.", "You can save up to 8 presets.").
- [ ] **Step 3:** Fewer feeds: when the filled count drops below four and `store.fewerFeeds == .ask`, show the prompt with "Keep four spots" and "Fit \(n) to the screen" and the line "You can change this any time in Settings › Multiview."; store the answer. `keepSpots` lays out four with "Pick a feed" placeholders in the empty slots (placeholder tiles use the same `TileFrame`s); `fit` lays out the filled count. Adding a feed back returns to four.
- [ ] **Step 4:** Settings › Multiview: "When a feed is missing" picker (Ask / Keep four spots / Fit to the screen), and "My driver" (the driver list below; "None").
- [ ] **Step 4b (owner change, 2026-11-13): your driver.** DuoCore first, with Linux tests: `MultiviewStore.favouriteDriver: String?` (get/set, persisted under `multiview.favouriteDriver`) and `MultiviewStore.driverPromptShown: Bool` (`multiview.driverPromptShown`); the starting `defaultPicks` becomes `[.worldFeed, favouriteDriver.map { .onboard(lastName: $0) }, .tracker, .data]` (computed while `defaultPicks` was never set by hand), and `FeedPick.defaultFour` is removed or replaced so nothing else still defaults to `.f1Live`. Tests: `defaultsUseFavouriteDriver`, `noDriverLeavesSecondSpotEmpty`, `changingDriverChangesDefaults`, `driverPromptShownPersists`; update the Task 3/5 tests that expected `.f1Live`. App: after the first successful sign-in (and on launch while `driverPromptShown` is false and signed in), a "Pick your driver" sheet lists the onboard channels of the most recent race replay (from the catalogue the app already loads; `driverLastName`, racing number, team colour bar as in the feed list), with "Skip"; choosing sets `favouriteDriver`, resets `lastUsed` to the new default, and sets `driverPromptShown`; "Skip" only sets `driverPromptShown`. If the race list can't load, the sheet isn't shown and is offered next launch.
- [ ] **Step 5:** Commit.

---

### Task 10: Controls, speed and audio
**Model:** Sonnet 5.5

**Files:**
- Create: `DuoApp/Multiview/MultiviewControls.swift`
- Modify: `DuoApp/Multiview/MultiviewView.swift`, `MultiviewController.swift`

- [ ] **Step 1:** Tap the video to show controls, auto-hide after 4 s: Close, session title, "Switch layout", Feeds (editor and presets), audio language for the feed with the sound (`audioChannelId`; the item's audible `AVMediaSelectionGroup` options, which include Track FX), speed (`SyncPolicy.speeds`, hidden at the live edge), play/pause, one scrubber for all feeds, and "LIVE" for live sessions (returns to the live edge).
- [ ] **Step 2:** Speed and seek apply to every player together, followed by a sync pass; `othersFrozen` shows "Paused to keep the main feed smooth" on the frozen tiles.
- [ ] **Step 3:** Commit.
- [ ] **Step 4 (owner, O-C):** controls, speed 2× and 0.5×, audio language change, scrubbing keeps all four in step.

---

### Task 11: Picture in picture
**Model:** Opus 5.5

**Files:**
- Modify: `DuoApp/Multiview/MultiviewController.swift`, `DuoApp/Multiview/FeedTile.swift`, `DuoApp/Player/PlayerView.swift`, `DuoApp/Player/PlayerController.swift`

- [ ] **Step 1:** Multiview: an `AVPictureInPictureController` on slot 0's `AVPlayerLayer`, `canStartPictureInPictureAutomaticallyFromInline = true`; on start, pause the other players; on stop or restore (`restoreUserInterfaceForPictureInPictureStop`), re-present the multiview cover, resume the others and seek them to slot 0's date, then call the completion handler with `true`. Making another feed main moves the PiP controller to its layer.
- [ ] **Step 2:** Single feed: `allowsPictureInPicturePlayback = true` with an `AVPlayerViewControllerDelegate` that restores the full-screen cover on return (beta.1 left a black cover behind because it had no restore).
- [ ] **Step 3:** Commit.

---

### Task 12: Resume and the live start choice
**Model:** Sonnet 5.5

**Files:**
- Modify: `Packages/DuoCore/Sources/Library/WatchBookmark.swift` (add `public var multiview: Bool`, decoded as `false` when absent)
- Test: `Packages/DuoCore/Tests/LibraryTests/RecentsStoreTests.swift`
- Modify: `DuoApp/Multiview/MultiviewController.swift`, `DuoApp/Player/ResumeBanner.swift`, `DuoApp/Rooms/DetailView.swift`

- [ ] **Step 1: Write the failing test** `oldBookmarksDecodeAsSingleFeed` (JSON without `multiview` decodes with `multiview == false`) and `multiviewFlagRoundTrips`.
- [ ] **Step 2:** Run `swift test --filter RecentsStoreTests`. Expected: FAIL. Implement; run `swift test`. Expected: all pass.
- [ ] **Step 3:** Multiview saves bookmarks with `multiview: true`; Resume on such a bookmark opens multiview (one fresh `player_tm`) with `lastUsed` at the saved position (live: live edge).
- [ ] **Step 4:** Starting a live session that has been running more than 60 s (single or multiview) asks "From the start" or "Watch live"; "From the start" seeks to the session's start (the first segment's program date, or position 0).
- [ ] **Step 5:** Commit.

---

### Task 13: Clean-up and release notes
**Model:** Haiku 5.5

**Files:**
- Delete: `DuoApp/Debug/MultiviewProbeView.swift` and its Settings › Debug link
- Modify: `CHANGELOG.md` (Unreleased: beta.2 bullets), `README.md` (status), `docs/roadmap.md` (Android 0.95–0.99.9 rows that landed)

- [ ] **Step 1:** Remove the probe and its link.
- [ ] **Step 2:** CHANGELOG Unreleased: multiview of four feeds in step; fit-to-screen layouts for every fold and feed count with Switch layout; tap a feed to make it main; feeds remembered, default four, reset, presets; fewer-feeds choice; speed 0.5×–2×; main feed kept smooth when the phone struggles; picture in picture; multiview resume; "From the start" / "Watch live".
- [ ] **Step 3:** Commit.
- [ ] **Step 4 (owner, O-C then O-D):** zero-warnings build, then the exit test.
