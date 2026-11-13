# v1.0-beta.2 — Multiview and fold: design

Owner-approved in conversation on 2026-11-13. The interactive sketch the owner reviewed is the
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
   the main feed.
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
"Main" is the feed with the sound.

| Posture | Layout (⟳ cycles) | Screen used | Shape |
|---|---|---|---|
| Closed (outer screen) | One | most | The main feed fills the outer screen. Swipe left/right to make another of the four the main feed. The other three keep playing silently, out of sight, so opening is instant and in step. |
| Book (half-open, fold down the middle) | **Two per screen** (default) | 70% | Two feeds stacked on each half, each as wide as its half allows; nothing over the fold region. Main is top-left. |
| | Across the fold | 77% | One feed as wide as the whole screen (the Android way), the others out of sight. The picture bends at the hinge; the owner wants it available, not default. |
| Flat (fully open) | **Main + row** (default) | 91% | Main feed the full width of the screen; the other three in a row underneath, centred. |
| | 2 × 2 grid | 77% | Four equal feeds. Main is top-left. |
| Laptop (half-open, hinge across) | One | 66% | Main feed the full width of the top half; the other three in a 2 × 2 below the hinge; the fourth spot is an empty placeholder ("Timing + map, beta.3"). |
| Unknown posture | Flat's layouts | — | Treat as flat. |

- **⟳ Switch layout** in the controls cycles the layouts for the current posture (book and flat
  have two; the others one, so the button is hidden or disabled there). The choice is remembered
  per posture across sessions.
- **Tap a feed** to swap it into the main spot; the sound moves with it. Swapping changes where a
  feed sits, not which four you have.
- **Every change of posture or layout animates**: the same tile views move to their new frames
  (one view per feed, keyed by the feed, frames animated), never removed and recreated.
- Narrow screens (a phone in portrait, the outer screen) use the closed layout.
- **Geometry rules (builder's call, recorded here):** 6 pt from the screen edges and 6 pt between
  tiles; tiles never enter the fold region in book "two per screen" or laptop. Laptop is the inner
  screen turned (669 × 951 in the simulator) with the fold across at y 456–496. The screen-use
  figures in the table are floors under those rules (tests assert at least that figure), not exact
  values. Tiles stay inside the safe area where it touches them, except a full-width main feed may
  run edge to edge horizontally.

### Fewer than four feeds (builder's call)

- Layouts always have four slots. An empty slot (a remembered feed missing from this session, or
  after Clear all) shows a "Pick a feed" placeholder in that tile's place, the same size.
- One feed can't fill two slots.
- If the main slot is empty, the sound and the main spot go to the first filled slot.
- A session with only two or three feeds offers that many; the remaining slots stay placeholders
  and are left out of the closed-screen swipe.

### Choosing feeds

- **Entry:** a session's detail screen shows **Watch multiview** when the account has multiview
  (tier OPS, VIP or PREMIUM) and the session has at least two feeds. Pro accounts see "Multiview
  needs F1 TV Premium" instead. The single-feed list from beta.1 stays.
- **Default four:** world feed (`INTERNATIONAL`), `F1 LIVE`, `TRACKER`, `DATA`, because every race
  has them. The user can change which four are the default.
- **Last used:** whatever four were showing when the player closed. Next time any session opens in
  multiview it starts with those, no picking.
- **Reset to default** puts the default four back.
- **Edit feeds:** shows the four slots; tap one to change it to any of the session's feeds; **Clear
  all** empties the slots to pick four new ones. Whatever results becomes "last used".
- **Presets:** up to 8. "Save as preset" stores the four feeds *and* the layout chosen for each
  posture, under a name the user types. Presets can be renamed, updated (overwritten with the
  current setup) and deleted. Choosing one loads it in place: feeds swap without a new PLAY.
- **Feeds are remembered by what they are, not by channel id** (ids differ per session): world
  feed, F1 Live, tracker, data, or a driver's onboard by the driver's last name (racing numbers
  change between seasons: Norris is 1 in 2026). When a remembered feed doesn't exist in a session
  (a driver not racing, an older race without F1 Live), that slot shows "Pick a feed" instead of
  guessing.

### Player controls (multiview)

Apple's `AVPlayerViewController` can't show four players, so multiview gets its own controls, in
the beta.1 style (dark, condensed headings, red only for primary actions, progress and LIVE). Tap to
show, auto-hide after a few seconds:

- Close; session title; ⟳ switch layout; Feeds (edit, presets, reset to default); audio language
  for the main feed (commentary languages and Track FX, from the stream's audio options); speed.
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
- **O2 — older races.** For older (pipeline-1) content `WEB_DASH` returned DASH, which iOS can't
  play. If multiview can't get HLS for an older race, Watch multiview is not offered for it ("Not
  available for this race"), unless task 1 shows approach B works there without ending sessions.
- **O3 — how many feeds the hardware handles.** Four in the Mac simulator says little about the Duo;
  the quality caps and struggle handling cover it, and beta.7 measures the real device.
- **O4 — live behaviour** waits for a live session.
