# v1.0-beta.1 — Foundation: design

Status: draft for the owner's review. Roadmap, versioning and the full idea list are in
[docs/roadmap.md](../../roadmap.md); this spec covers beta.1 only.

## Goal and exit test

The first build of the iPhone app that does something real: sign in with your own F1 TV account,
find a session, watch it, and come back to it.

**Exit test (owner, on the 15 Pro Max):** sign in, play the 2026 São Paulo race replay, close the
app, reopen it, and it resumes at the same moment.

Also checked, not part of the exit test: the same build runs in the iPhone Duo simulator folded and
unfolded, and the posture readout in Settings changes when the simulator folds.

## In scope

1. Sign in, sign out, browsing before sign-in.
2. Three rooms (idea 3) as the app's top level: Race Weekend, Paddock, Archive.
3. Playing one feed of a session (replay or live), with commentary language and Track FX choice.
4. Resume (idea 2, first half): the app bookmarks what you were watching and where, and picks it
   up when reopened. "While you were away" for live sessions is beta.4.
5. The project skeleton every later beta builds on: logic library, app, fold adapter, version
   source of truth, tests and CI.

## Out of scope (later betas)

Multiview, layouts, picture in picture, fold-driven layouts and transitions (beta.2). Track map,
timing, chequered marks on the scrubber (beta.3). Radio, haptics, closed-phone modes (beta.4).
Calendar reminders, Driver of the Day, the "what to watch next" carousel (beta.6).

## Decisions already settled by testing

From the stream checks (see roadmap "Verified so far"):

- **Request style.** Single feed: `WEB_HLS` with the Safari-on-Mac `x-f1-device-info` values that
  worked. It returned HLS for both new (pipeline 6) and older (pipeline 1) content, whereas
  `WEB_DASH` returned DASH for older content, which iOS can't play. Multiview (`player_tm`) is
  beta.2's question: `WEB_DASH` returned all 26 feeds as HLS for the race; `WEB_HLS` returned one.
  So the platform is a per-request parameter, with the entitlement token cached per platform, not
  one app-wide setting.
- **Not yet run:** `CONTENT/VIDEO` (the feed list) on either platform, and `player_bm` with an
  onboard `channelId`. The fixture recording run (see Testing) covers both before the parsers are
  written.
- **No DRM** on any replay checked, so AVPlayer plays the stream URL directly. The code still
  checks `laURL`: if a response ever carries one, show "This session is protected and can't play in
  this app yet" instead of failing silently. FairPlay is not built in beta.1.
- **Native platform strings** (`MOBILE_HLS`, `TABLET_HLS`, `BIG_SCREEN_HLS`) are refused; not used.

## Structure

```
project.yml                  XcodeGen project definition (the .xcodeproj is generated, not committed)
Config/Version.xcconfig      MARKETING_VERSION = 1.0, CURRENT_PROJECT_VERSION = build number
Config/Signing.xcconfig      bundle ID and team (owner-specific, see open item O2)
Packages/DuoCore/            Swift package: the logic library (Foundation only)
  Sources/F1TV/              API client, sign-in exchange, catalogue, play
  Sources/Library/           resume store, watch history (pure Swift, storage behind a protocol)
  Tests/                     Swift Testing suites with JSON fixtures
DuoApp/                      the iPhone app (SwiftUI, AVKit)
  Rooms/                     Race Weekend, Paddock, Archive
  Player/                    single-feed player screen
  SignIn/                    web sign-in, token paste
  Fold/                      the fold adapter (only code touching Duo APIs)
  Support/                   Keychain, app state, settings
.github/workflows/ci.yml     CI
```

The iPhone app's folder is `DuoApp/`, not `App/`: the Mac's file system ignores letter case, so
`App/` would collide with Android's `app/`.

The Android source stays where it is (`app/`, Gradle files) until beta.3 has ported it, then it is
deleted from `ios`. It is not moved: moving it would make merging `og-android` updates unreliable.

**Why XcodeGen.** An Xcode project file can't be written reliably by hand or by agents. XcodeGen
builds it from `project.yml`, which agents can edit and review. The owner installs it once
(`brew install xcodegen`) and runs `xcodegen` after pulling.

**Rules for the logic library.** Imports Foundation only (no SwiftUI, AVFoundation, Combine, UIKit),
so it compiles and tests on Linux in the cloud session and in CI. Networking goes through a small
`HTTPClient` protocol so tests use canned responses; the `URLSession` implementation lives in the
app (on Linux `URLSession` is in `FoundationNetworking`, which the library doesn't import). Swift 6
language mode, strict concurrency, and a `swift-tools-version` accepted by both the Linux toolchain
here (6.4.1) and Xcode 27.1.

**Deployment target:** iOS 27.1. Swift 6.

## Components

### F1TV (logic library)

Mirrors the Android `F1TvApi.kt` (ported from eXhumer/f1tv-api, MIT; the notice is carried into the
app's About screen and LICENSE).

- `F1TVConfig`: `GET /config`, reads `apiConfig.playAPIVersion` / `videoAPIVersion` (must match
  `\d+\.\d+`, defaults 3.0 / 4.0).
- `F1TVSession` (actor): holds the subscription token, entitlement token, tier and groupId.
  - `signIn(token)`: ENTITLEMENT (`ascendontoken` header) → `entitlementToken`; LOCATION
    (`entitlementtoken` header) → `userLocation[0].entitlement` (tier) and `groupId`.
  - `prepare()`: config and anonymous location so browsing works signed out (`A` paths).
  - `hasVideoPlan = tier ∉ {ANONYMOUS, REG}`; `hasMultiview = tier ∈ {OPS, VIP, PREMIUM}`.
- URL pattern `{BASE}/{version}/{A|R}/ENG/{platform}/ALL/{path}`, platform per request (see
  above); every request sends the Safari user agent; 15 s timeout.
- Catalogue calls, with the exact filters from the Kotlin:
  - `liveNow()`: `1.0/…/EVENTS/LIVENOW/{tier}/{groupId}`.
  - `calendar(season)`: search, `filter_objectSubtype=Meeting`, skips
    `emfAttributes.Diplay_In_Schedule == "false"` (F1's spelling), testing has no round.
  - `weekend(pageId, meetingKey)`: `PAGE/{pageId}`, `interactive_schedule` group "FORMULA 1"
    (else "ALL"), falling back to a `filter_MeetingKey` search.
  - `home()`: `PAGE/395`, rows from `horizontal_thumbnail`, `vertical_thumbnail`,
    `horizontal_simple_poster`; skip blank, "Survey" and `MYLIST` rows.
  - `collection(pageId)` for BUNDLE tiles (shows and series).
  - `archiveRaces()` and `raceReplays(season)`: the Replay / Full Race searches; drop "Kids".
  - `seasonVideos(season)` for seasons before 2018.
  - `video(contentId)`: `CONTENT/VIDEO`, reads `additionalStreams[]` (`channelId`, `default`,
    `type`, `title`, `racingNumber`, `driverLastName`, `teamName`, `hex`).
  - `play(contentId, channelId)`: `CONTENT/PLAY?contentId=…&player=player_bm[&channelId=…]`.
    Returns `url`, `laURL`, `streamType`.
- Models: `CatalogItem` (contentId, title, subtype, contentType, genre, pictureUrl, duration, year,
  meeting, start, pageId; derived `live`, `upcoming`, subtitle rules), `Weekend`, `Session`,
  `Channel`, `PlayInfo`. Image URL: `{BASE}/image-resizer/image/{path}?w=&h=&q=HI&o=L`.
- **One play session at a time.** "A second PLAY request can end the first session", so the client
  never issues a second PLAY for content that is playing; switching feed first stops the current
  one.
- Errors: a typed `F1TVError` (`notSignedIn`, `refused(status)`, `noVideoPlan`, `network`,
  `server(status, message)`, `badResponse`) so the app can phrase them.

### Library (logic library)

- `WatchBookmark`: contentId, title, image, channelId, positionMs, durationMs, live, savedAt.
- `RecentsStore`: newest first, at most 4, one per contentId, removes a replay saved within 60 s
  of its end. Storage behind a protocol (`UserDefaults` in the app, in-memory in tests).
- `WatchHistory`: contentId → watched time and finished (at 90% of duration until timing data
  exists in beta.3), capped at 300.

### Sign-in (app)

- **Web sign-in:** a `WKWebView` on `https://account.formula1.com/#/en/login` with a plain Safari
  user agent. Polls `WKHTTPCookieStore` once a second for `login-session` and reads
  `data.subscriptionToken` from it (raw or URL-encoded JSON). The screen says to use email and
  password, because Google sign-in refuses embedded browsers.
- **Token paste fallback:** "Use a token instead", as on Android. It accepts the whole
  `login-session` cookie value (about 3,000 characters) as well as a bare token, decoded the same
  way as the stream check.
- Web sign-in has never been run in an iPhone web view, so it is the first thing tried on the
  phone; the paste fallback is the way through if it fails.
- Token stored in the Keychain, this device only, never synced to iCloud or backups.
- Sign-in exchange re-runs on launch and whenever the app comes back to the foreground; a 401/403
  from ENTITLEMENT signs the user out with "Your F1 TV sign-in has expired. Sign in again."
- Sign-out stops playback (saving the bookmark first), deletes the token and the web view's cookies.
- No video plan: after sign-in, a sheet explains that a free F1 TV account can't play video, with
  the Apple TV linking note for US Premium, and a sign-out button.

### Rooms (app)

The top level is three rooms, as a tab bar on the outer screen and a sidebar on the inner screen
(standard SwiftUI `TabView` with the sidebar-adaptable style, which follows size class).

- **Race Weekend:** Continue watching (when present); Live now; the latest weekend's sessions as a
  schedule (live sessions first, upcoming ones shown dimmed and not tappable); F1 TV's own weekend
  rows ("More from the weekend").
- **Paddock:** F1 TV's home page rows (shows, analysis, features) and "Featured on F1 TV".
- **Archive:** "Popular races from the archive", then seasons back to 1981; a season opens its
  weekends (2018 on) or its videos (before 2018).
- Every room refreshes "Live now" about once a minute while open.
- A tile opens a detail screen: title, image, and the session's feeds. A session with one feed plays
  straight away; otherwise the default feed is preselected and the onboards are listed by number,
  driver and team colour.
- Errors on any load: "Couldn't load F1 TV: …" with "Try again".

### Player (app)

- `AVPlayerViewController` (wrapped for SwiftUI). This gives scrubbing, live edge, AirPlay and the
  audio menu for commentary languages and Track FX with no custom controls. Custom controls arrive
  with multiview in beta.2.
- Plays the HLS URL from `play()`. If `laURL` is present: the protected-session message above.
- Error copy, as on Android: 401/403 → "F1 TV won't play this on your account. Its plan may not
  include this session."; otherwise "This feed stopped: <reason>."
- Live sessions start at the live edge.

### Resume ("close equals bookmark", app)

- The bookmark is saved every 5 seconds while playing, when the app leaves the foreground, and when
  the player closes.
- When the app is reopened from the background with the player still in memory, playback simply
  continues from where it paused.
- When the app was closed fully, it opens on the room you were in with the bookmarked session on
  top: tapping "Resume" makes a fresh PLAY request (old links expire) and seeks to the saved
  position. Live sessions resume at the live edge.
- Continue watching shows the last four, with a progress bar and "Xh Ym left" or "Live".

Opening straight into the player on launch was considered and not chosen: a cold start needs a
fresh PLAY request and the network, and dropping the user into a loading video with no context is
worse than one tap. Revisit on the Duo in beta.2, where unfolding is the natural "resume" gesture.

### Fold adapter (app)

The only code that touches the iPhone Duo APIs. In beta.1 it exists, compiles and reports; nothing
uses it for layout yet.

- `enum Posture { closed, flat, book, laptop, unknown }` (`standing` is added only if the SDK
  shows it can be told apart), `foldFrame: CGRect?`,
  `hingeAngle: Double?`, published as an `@Observable` `FoldState`.
- `SystemFoldProvider`: `onHingeChange` and `GeometryProxy.reservedRegions(kind: .division)`.
  Exact declarations are taken from the iOS 27.1 SDK on the owner's Mac (open item O3), because
  Apple's reference pages for the hinge API weren't readable and these APIs post-date the models
  writing the code.
- `FakeFoldProvider`: driven from a debug menu, so later betas can be built and tested on any
  simulator.
- Settings shows a live posture / fold / hinge readout, which checks the API names against the real
  simulator early.

### Multiview probe (app, debug only)

A hidden screen that starts four players on four feeds of one session at once, with each feed's
own PLAY request (single-session multiview is beta.2). It reports start time, stalls and dropped
frames per player. It exists so the "can a phone play four F1 feeds at once" risk shows up in
beta.1 testing rather than late in beta.2. Not part of the exit test.

## Version and build numbers

`Config/Version.xcconfig` is the single source of truth: `MARKETING_VERSION = 1.0` through every
beta, `CURRENT_PROJECT_VERSION` raised for each build handed to the owner. The tag, release title
and changelog carry `v1.0-beta.1`. Settings → About shows "v1.0-beta.1 (build N)": the beta name
comes from a `BETA_LABEL` build setting in the same file.

## Testing

- **Logic library (cloud and CI, every push):** Swift Testing suites for URL building, the
  sign-in exchange, every catalogue parser, play response parsing, error mapping, `RecentsStore`
  and `WatchHistory` rules. Parsers are tested against JSON fixtures.
- **Fixtures first:** before the parsers are written, the owner records real responses by running
  the stream check with a new `--dump-catalogue` option. It saves the config, home, a weekend page,
  the archive search, `CONTENT/VIDEO` on both `WEB_HLS` and `WEB_DASH`, a `player_bm` play with an
  onboard `channelId` on `WEB_HLS`, and one play with `os=ios` in the device header. Tokens, signed
  URL queries and account fields are stripped, and samples are trimmed small (the repo is public).
  Hand-written fixtures would only test the agents' reading of the Kotlin.
- **Ported Android tests:** `ScheduleTest` (weekend and session ordering) is the only one that
  applies to beta.1; the rest arrive with their features.
- **App:** nothing in the cloud session can build SwiftUI, AVKit or WebKit code. The app is built
  by a Claude session running on the owner's Mac (`xcodegen` then `xcodebuild` for the simulator),
  which reports errors back, and by CI once GitHub's macOS runners carry Xcode 27.1. Then a short
  checklist per build on the phone: sign in, browse each room, play, change commentary, resume
  after closing.
- **CI** (`.github/workflows/ci.yml`): a Linux job runs `swift test` on the logic library on every
  push to `ios`. A macOS job builds the app only once GitHub's runners carry Xcode 27.1; until then
  it's left out rather than failing.

## Work split

| Task | Model |
|---|---|
| Plan for this beta, fold adapter, review before release | Opus 5.5 |
| F1TV and Library port with tests, XcodeGen project, sign-in, rooms, player | Sonnet 5.5 |
| Fixture recording option in the stream check, ScheduleTest port, CI file, changelog | Haiku 5.5 |

## Open items

- **O1 — device header for iPhone.** Default to the Safari-on-Mac values that worked. The fixture
  run also tries `os=ios;browser=safari`; switch only if that is accepted.
- **O2 — bundle ID (owner).** A reverse-domain ID such as `com.<yourname>.apexviewduo`. It can't be
  changed after an App Store or TestFlight upload, so it should not depend on the final app name.
  The owner's Apple ID is enough for builds on their own phone; the paid developer account is
  needed only for TestFlight.
- **O3 — Duo API declarations (owner, once Xcode 27.1 is installed).** One Terminal command,
  supplied in the plan, prints the SDK's declarations of `onHingeChange`, `reservedRegions` and
  `ArrangementView` for the agents to code against.
- **O4 — the app's name** is still the working name "Apexview Duo". "F1" and "Formula 1" are
  trademarks, so the final name should be F1-flavoured without using either.
