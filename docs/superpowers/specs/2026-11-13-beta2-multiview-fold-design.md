# v1.0-beta.2 — Multiview and fold: design

Owner-approved on 2026-11-13 ("all is good, proceed"). The interactive sketch the owner reviewed is the
"Duo Multiview Layouts" artifact (private to the owner); this document is the source of truth.

## Goal and exit test

The beta where the fold starts doing real work. Up to four feeds of one session play together, in
step, and folding the phone changes how much you see without ever changing what's playing.

**Exit test (owner, in the iPhone Duo simulator):** four São Paulo 2026 race feeds play together for
10 minutes without stalling; folding and unfolding (closed, book, flat, laptop) keeps the same four
feeds, in step, at the same moment.

## Why

The app exists for what the Duo's fold makes possible and the official F1 TV app doesn't do. The
Android app this started from treats a half-open book as one flat canvas, so a feed can sit right
across the bend. Here every posture has its own layout, the crease is respected, and moving between
postures is one smooth glide of the same feeds (the owner liked exactly this in the beta.1 Settings
panel).

## Goals

1. **Multiview of four feeds** for F1 TV Premium (tiers OPS, VIP, PREMIUM), from one multiview play
   session, kept in step.
2. **The rule:** folding changes how much you see, never what's playing. The same players keep
   running through every fold change; nothing reloads, nothing loses its place, the sound stays on
   the feed you chose.
3. **Layouts that use as much of the screen as a 16:9 picture allows**, nothing cropped (the world
   feed's timing tower and graphics sit at its edges), one set per posture, with a ⟳ button that
   cycles the layouts available for the current posture.
4. **Choosing feeds:** a default four, "last used" remembered across sessions, reset to default,
   edit/clear, and up to 8 named presets.
5. From the Android app: playback speed 0.5× to 2× for all feeds together; when the phone can't
   keep up, only the main feed keeps its picture; for live sessions, "From the start" or "Watch
   live".
6. **Picture in picture**, back on (it was turned off for beta.1).

## Non-goals (this beta)

- More than four feeds at once, and the "ring" layout (centre feed with up to 12 around it). The
  owner dropped the ring; more than about four live feeds stays the beta.7 experiment on the Duo.
- Race Table (two people across a flat Duo): moved to beta.7, it needs the real hardware.
- The offer of the next live programme when one starts: moved to beta.3 (the live-data beta).
- Track map, timing tower, flags on the map: beta.3. Laptop posture keeps one empty spot for them.
- Free drag-and-resize of tiles with magnetic snapping (an Android feature): not planned; the
  posture layouts replace it.
- Cropping or zooming video to fill space.

## Anti-goals (would make this a failure even if it technically works)

- A fold change that reloads, rebuffers or restarts any feed, or jumps the position.
- Feeds visibly out of step with each other (a car at a corner on one feed and past it on another).
- In book posture, a picture across the crease unless the user chose that layout.
- Two Settings-style surfaces swapping instead of one moving (the beta.1 Settings lesson): tiles
  are the same views, and their frames animate.

## Constraints

- iOS 27.1 deployment target, iPhoneOS 27.2 SDK, Swift 6 strict concurrency (every compile error
  so far has been main-actor isolation), SwiftUI, AVFoundation. No third-party dependencies.
- Logic that can be tested without a device lives in the DuoCore package and runs on Linux CI.
- The owner tests in the iPhone Duo simulator until the Duo arrives; real-device checks are beta.7.
- F1 TV: one multiview PLAY per opened multiview. A second PLAY request can end the first session
  (the Android code says so), so tiles must all come from one `player_tm` call and swapping feeds
  must never issue another PLAY.
- Privacy rules from beta.1 hold: never log or commit tokens, entitlement tokens or signed stream
  URLs; fixtures are sanitised.
- Release standard in `docs/roadmap.md`. `Config/Version.xcconfig`: `BETA_LABEL = beta.2`, build
  number raised for each build handed to the owner.

## Approaches considered (owner picked A)

- **A. One multiview session for all four (picked).** One `CONTENT/PLAY` with `player=player_tm`
  returns every feed's URL (`resultObj.tme.feeds[].url`, keyed by `metadata.channel_id`), as F1's
  website and the Android app (`multiPlay`) do. Each tile is its own `AVPlayer` on its feed's URL,
  all kept to one clock. Pros: matches F1 TV, one request, swaps and presets are near-instant
  because every URL is already in hand. Cons: the app has never sent this request (the spike got
  all 26 São Paulo feeds back from it, outside the app); older content may not support it (below).
- **B. Four separate single-feed requests (`player_bm` × 4).** Reuses beta.1's proven path. Cons:
  F1 TV may treat it as four viewers or end earlier sessions; every swap needs a new request;
  starting four independent players makes sync harder. Kept only as the fallback if A fails.
- Combining the feeds into one video: impossible for live HLS; dropped.

**Safety step:** the plan's first task checks the multiview request inside the app (see Open
items O1). If F1 TV refuses it, the plan stops there and comes back to the owner: under B, instant
swaps and presets that load without a new request can't hold, so the promises need the owner's
say before anything is built on top.

## What the owner decided

### Postures and layouts

Geometry is computed from the screen size and the fold's frame (`FoldState.foldFrame`), never from
hard-coded numbers; the figures below are for the simulator's inner screen (951 × 669 points, fold
region x 456–496) and are what the sketch showed. All tiles are 16:9, aspect-fit, nothing cropped.
"Main" is the feed in the biggest spot. The sound is chosen separately (see "Owner changes after the first multiview check").

**Fit to screen, for every feed count (owner-approved 2026-11-13).** Found by computing every
arrangement of 1–4 whole 16:9 tiles on each screen shape and keeping those that cover the most
screen, with no tile narrower than 200 pt. The first listed is the default; ⟳ cycles the rest.
Percentages are the share of the whole screen showing video.

| Feeds | Open flat | Half-open book | Half-open laptop (screen turned, hinge across) |
|---|---|---|---|
| 1 | Full screen · 78% | **Across the fold** · 78% (owner's pick); ⟳ one screen · 17% | Main above the hinge · 38% (beta.3 timing and map below) |
| 2 | Main full width + one below · 82%; ⟳ two equal, stacked · 59% | One per screen · 35%; ⟳ across the fold · 78% | Main above, one below, both full width · 76% |
| 3 | Main full width + two below · 86%; ⟳ three equal (two over one) · 58% | Main alone on the left, two stacked on the right · 52%; ⟳ one per screen (the other feed out of sight) · 35%; ⟳ across the fold · 78% | Main above, two stacked below · 65%; ⟳ two side by side below · 57% |
| 4 | Main full width + three below · 91%; ⟳ main + one beside + two below · 86%; ⟳ 2 × 2 grid · 77% | Two per screen · 70%; ⟳ one per screen (the other two out of sight) · 35%; ⟳ across the fold · 78% | Main above, three below (two over one) · 66% |

- **Closed (outer screen):** the main feed fills the screen whatever the count; swipe left/right
  to make another feed the main one. The others keep playing silently, out of sight.
- **Across the fold** means one picture spanning both halves, over the bend; the other feeds keep
  playing out of sight. It is the default only for one feed; with two or more, nothing crosses the
  fold unless the user picks it with ⟳.
- **Space kept for a later beta** is always drawn and labelled, in sketches and in the app where
  it shows (owner's rule): today only laptop posture's lower half with one feed, "Timing + map,
  beta.3". Laptop's "row of three" layout was dropped: it only made room for beta.3.
- **Unknown posture:** flat's layouts. Narrow screens (a phone in portrait): the closed layout.
- Research (Apple TV app, F1 TV, YouTube TV, ESPN, DAZN, Peacock, from web-search summaries): four
  feeds is the common limit, one large plus smaller ones the usual shape, layouts re-fit when the
  count changes, and the sound follows the feed you pick. No multiview product found lays feeds out
  around a hinge. The Apple TV app carries F1 multiview in the US from 2026 and reportedly reached
  iPhone with iOS 27.2, so the fold is what sets this app apart.

- **⟳ Switch layout** in the controls cycles the layouts for the current posture and feed count
  (hidden when there is only one). The choice is remembered per posture and feed count, across
  sessions.
  In book with three or four feeds, ⟳ also offers "one per screen": the main feed and the second
  one, one on each screen, the others playing out of sight (owner, 2026-11-13).
- **Tap a feed** to swap it into the main spot: the two trade places, so tapping the old main
  feed puts them back. The sound stays with the feed that has it. Swapping changes where a feed
  sits, not which four you have. **Press and hold a feed, then drag it onto another**, to trade
  their places in any layout (owner, 2026-11-13).
- **Every change of posture or layout animates**: the same tile views move to their new frames
  (one view per feed, keyed by the feed, frames animated), never removed and recreated.
- Narrow screens (a phone in portrait, the outer screen) use the closed layout.
- **Geometry rules (builder's call, recorded here):** 6 pt from the screen edges and 6 pt between
  tiles; tiles never enter the fold region in book "two per screen" or laptop. Laptop is the inner
  screen turned (669 × 951 in the simulator) with the fold across at y 456–496. The screen-use
  figures in the table are floors under those rules (tests assert at least that figure), not exact
  values. The table's figures were computed with these rules for the simulator's screen. Tiles stay inside the safe area where it touches them, except a full-width main feed may
  run edge to edge horizontally.

### Fewer than four feeds (owner's decision, 2026-11-13)

- **When it asks:** the first time the feeds drop below four (a feed removed, a remembered feed
  missing in this session, or a session with only two or three feeds), a short prompt offers
  **Keep four spots** (the empty one shows "Pick a feed", same size as a tile) or **Fit three to
  the screen** (or two, and so on). It says "You can change this any time in Settings ›
  Multiview." and never asks again: the answer is remembered, and Settings has the switch.
- **Fit to the screen** uses the same rule as everything else: as much of the screen as a 16:9
  picture allows, the main feed as large as it can be, the rest sharing what's left.
  - Flat, three feeds: main the full width, the other two side by side underneath, centred.
  - Book, three feeds: main on the left screen, the other two stacked on the right.
  - Laptop, three feeds: main the full width of the top half, the other two below the hinge, as
    large as they fit (the beta.3 timing and map share that half later).
  - Two feeds: one per screen in book; main plus one in flat and laptop by the same rule.
  - Closed: unchanged (one feed); the swipe goes through the feeds there are.
- Adding a feed back returns to four. One feed can't fill two slots. If the main slot is the one
  emptied, the sound and the main spot go to the next feed.

### Player controls (multiview)

Apple's `AVPlayerViewController` can't show four players, so multiview gets its own controls, in
the beta.1 style (dark, condensed headings, red only for primary actions, progress and LIVE). Tap to
show, auto-hide after a few seconds:

- Close; session title; ⟳ switch layout; Feeds (edit, presets, reset to default); audio language
  for the feed with the sound (commentary languages and Track FX, from the stream's audio options); speed.
- One scrubber for all feeds, play/pause, and for live sessions a "Live" button that returns to the
  live edge.
- The single-feed player (non-Premium accounts, sessions with one feed, or the existing feed list)
  stays Apple's player as in beta.1.

### Where the players live (builder's call)

The four `AVPlayer`s belong to a multiview coordinator owned by the app model, not by any view, as
beta.1's `PlayerController` is. Tile views only show a player's picture. So a posture change, a
switch between the inner and outer screen, or a scene rebuild never stops or recreates a player;
if the system pauses playback during such a change, the coordinator resumes it, in step. Task 1
also records, in the simulator, what actually happens to the app when it closes to the outer screen
and when it turns into laptop (whether laptop is reachable with the real hinge or only with the
fake fold).

### Expired links (builder's call)

The signed feed URLs from `player_tm` expire after a while. Players already running keep playing.
If opening a feed (a swap, a preset, resuming after a long pause) fails because its link has
expired, the coordinator makes one fresh `player_tm` PLAY and reattaches all four feeds at the
current position, in step. That is the only case where feeds reload; fold changes never do. Task 1
notes how long the links last if it can tell.

### Keeping feeds in step

- All four start at the same instant and stay within a small tolerance of the main feed (target:
  0.1 s). Streams carry `#EXT-X-PROGRAM-DATE-TIME` (verified on the São Paulo race), so the main
  feed's program date is the reference; small drift is corrected by nudging a feed's rate, large
  drift (over about 1 s, or after a stall) by seeking it to the main feed's date.
- Content without program-date-time (older pipeline-1 videos) is aligned by playback position
  instead.
- Seeking, pausing, speed changes and swaps apply to all four together.

### Speed, struggling, quality

- Speed: 0.5×, 0.75×, 1×, 1.25×, 1.5×, 2× for every feed together. Not offered at the live edge.
- Non-main tiles are limited to the quality their tile size needs (resolution and bit-rate caps),
  so four feeds fit the connection and the decoder.
- When the phone can't keep up (stalls or many dropped frames on non-main feeds, including at higher
  speeds), the non-main feeds freeze on their last frame with a small "Paused to keep the main feed
  smooth" note, and the main feed keeps playing. They resume, back in step, when conditions recover
  or when tapped.

### Live sessions

- Starting a live session that is already under way asks **From the start** or **Watch live**.
  Joining at the start begins at the session's start, not the stream's first segment if it has more.
- This can only be tested during a live session (Las Vegas Nov 19–22 or the season's last weekend in
  early December); it is not part of the exit test.

### Picture in picture

- Leaving the app while watching multiview puts the main feed in picture in picture; the other
  feeds pause. Coming back restores the multiview and brings the paused feeds back in step.
- Single-feed playback gets picture in picture too.
- Beta.1 turned it off because returning left a black cover behind (no restore handling). The
  restore must bring the player back properly.

### Resume ("close equals bookmark")

- The bookmark (every 5 seconds, on leaving the foreground, on close) records that it was multiview,
  the position, and the session. Resume reopens multiview with the last-used four at that position
  (one fresh `player_tm` PLAY; old links expire). Live sessions resume at the live edge, as in
  beta.1.
- Continue watching is unchanged.

## Logic library (DuoCore, tested on Linux)

What can be pure goes here, with Swift Testing suites:

- **Multiview play parsing:** `resultObj.tme.feeds[]` → channel id to URL, plus `laURL` and
  `streamType`; a sanitised fixture recorded by the owner (O1).
- **Feed identity:** classify a `Channel` as world feed / F1 Live / tracker / data / onboard (by
  driver last name) / other; resolve remembered picks against a session's channels, with the
  "Pick a feed" gap rule.
- **Feed picks and presets store:** default four, last used, reset, edit/clear, presets (max 8,
  rename, update, delete), layout choice per posture; persisted through the existing
  `KeyValueStore`.
- **Layout geometry:** a pure function from screen size, fold frame, posture and layout choice to
  tile frames and the main slot. Tests: every tile is 16:9 and on screen, no tile overlaps the fold
  region in book "two per screen" and laptop, the screen-use figures above hold for 951 × 669.
- **Sync decisions:** given each feed's offset from the main feed, the action (none, rate nudge,
  seek), so the thresholds are tested without players.

## App (built and checked by the owner in the simulator)

- Multiview player: one `AVPlayer` per feed, a coordinator that starts, keeps in step, swaps and
  tears down the four; the tile views; the controls; picture in picture; the speed and struggle
  handling.
- Fold-driven layout through `FoldState` (beta.1's adapter), animated as the beta.1 Settings panel
  is (one view per tile, frames animated).
- Feeds editor and presets UI; the Watch multiview entry on the detail screen.
- Resume and bookmarks extended for multiview.
- The beta.1 debug multiview probe (four separate PLAYs) is removed once the real multiview works;
  it used the pattern this beta avoids.

## Testing

- **DuoCore:** the suites above run on every push (Linux CI), as in beta.1.
- **Owner, in the iPhone Duo simulator:** zero-warnings build log, then the exit test, then a
  checklist per feature (each posture and ⟳ layout, swaps, edit/clear/reset, presets, speed,
  picture in picture, resume after quitting).
- **Live:** "From the start / Watch live" during a live session when one happens; not blocking.

## Work order (for the plan)

1. **Check the multiview request in the app** (O1, O2) and record the sanitised fixture. Stop and
   fall back to approach B if it fails.
2. DuoCore: multiview parsing, feed identity, picks and presets store, layout geometry, sync
   decisions, each with tests.
3. App: the multiview player and sync coordinator with a fixed flat layout, playing four São Paulo
   feeds (the first half of the exit test).
4. Fold-driven layouts, ⟳, animated glides, the closed-screen swipe (the second half).
5. Feeds editor, presets, reset to default, Watch multiview entry.
6. Speed, quality caps, struggle handling.
7. Picture in picture; resume for multiview; live start choice.
8. Remove the debug probe; CHANGELOG, README status, roadmap.

## Open items

- **O1 — the multiview request inside the app.** Platform: `WEB_DASH` returned all 26 São Paulo
  feeds as HLS in the spike; `WEB_HLS` returned one. Device info: Android sends `p=true` for
  multiview accounts (beta.1's single-feed PLAY sends `p=false`). Task 1 confirms what works and
  the owner records a sanitised `player_tm` fixture with the stream check.
  **Resolved 2026-11-13 (owner's probe run):** the device header decides it, not the platform. With
  the Android web player's header and User-Agent, `player_tm` returns all 26 feeds (`tme.channel`
  `MULTI`, HLS, no licence) on both `WEB_DASH` and `WEB_HLS`; with Safari's it returns only the
  requested feed (`SWITCHER`). The app sends the Android header for the multiview PLAY, as the
  Android app does. `streamType` reads `SDR_HD_CMAF` for HLS here, so HLS is judged by the feed URLs.
  Separate `player_bm` sessions also play side by side (Android's own fallback).
- **O2 — older races.** For older (pipeline-1) content `WEB_DASH` returned DASH, which iOS can't
  play. If multiview can't get HLS for an older race, Watch multiview is not offered for it ("Not
  available for this race"), unless task 1 shows approach B works there without ending sessions.
- **O3 — how many feeds the hardware handles.** Four in the Mac simulator says little about the Duo;
  the quality caps and struggle handling cover it, and beta.7 measures the real device.
- **O4 — live behaviour** waits for a live session.

## Owner changes after the first multiview check (2026-11-13)

From the owner's simulator check of the Task 7 build:

- **The default four are the world feed, your driver's onboard, the tracker and the data feed.**
  F1 LIVE shows the same race picture as the world feed during a race, so it leaves the defaults
  (it stays in the feed list). The first time the app is used after signing in, a "Pick your
  driver" sheet lists the drivers (the onboard feeds of the latest race F1 TV lists); the choice
  fills the second default spot and can be changed any time in Settings › Multiview › "My driver".
  "Skip" leaves that spot as "Pick a feed". Picking a driver in that first sheet also resets the
  last-used feeds to the new default.
- **Sound from any feed, without moving it.** Each tile has a speaker button; tapping it moves the
  sound to that feed (one feed at a time) and the red SOUND badge goes with it. Swapping or dragging
  feeds never moves the sound. Opening multiview starts with the sound on the main feed. The audio
  language choice applies to the feed with the sound. (Android does the same: its audio is chosen
  per tile, apart from the big one.)
- **Arrange by hand:** press, hold and drag a feed onto another to trade places (above), and a tap
  swaps a feed with the main one and back. The arrangement is saved as the last-used feeds.
- **The tracker runs slightly ahead of the race video.** Left as it is for beta.2 (owner's choice);
  looked at again in beta.3, when the timing map arrives (Android delays its map about 7 s and lets
  the viewer fine-tune it).
