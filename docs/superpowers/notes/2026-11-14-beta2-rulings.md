# Beta.2 — decisions made while building, and what was left for later

Kept from the build ledger (2026-11-13/14) so nothing decided on the owner's behalf is lost. Each line says what it costs if wrong.

## Rulings

- Ruling: T4's 1020x700 screen uses a fold frame centred, 40 pt wide, full height (laptop: turned, across) — matches the simulator's 40 pt fold region — cost if wrong: one test's input.
- Ruling: while waiting for the owner's O-A run, do the DuoCore tasks that don't need it (3, 4, 5, 6) after Task 1; Task 2 runs when the fixture arrives; Task 7 waits for Task 2 — cost if wrong: none, no file overlap.
- Ruling: where the plan leaves behaviour open, follow the Android app (og-android branch) as the owner asked, adapted to the Duo — cost if wrong: rework of that behaviour.
- Ruling: when an option doesn't fit (tile < 200 pt or region empty), fall back only to fold-respecting options of the same posture in ⟳ order, then to a single main tile (book: across the fold; laptop/flat: aspect-fit within the screen inset), others hidden; min width 200 is relaxed only for that last single tile. Add `static func usableOptionIDs(screen:foldFrame:posture:feedCount:) -> [String]` (optionIDs filtered to those that fit, never empty) so ⟳ in T8 never shows the same layout twice — cost if wrong: one unused helper.
- Ruling: fold frame is intersected with the screen first; a fold that doesn't intersect the screen, or is thinner along the posture's split axis than across it (wrong orientation), is treated as nil (flat) — cost if wrong: an odd device report lays out flat.
- Ruling: feedCount <= 0 returns []; zero/negative screen returns feedCount hidden zero-rect frames (nothing to draw) — cost if wrong: trivial.
- Ruling: the multiview PLAY sends Android's web device header (os=android;browser=chrome;browserVersion=140;osVersion=14;p=true;tms=1) and Android Chrome UA (as og-android does) — cost if wrong: one header string.
- Ruling: HLS is judged by feed URLs (.m3u8 ok, .mpd → multiviewUnavailable), not streamType (real value "SDR_HD_CMAF") — plan's "streamType is not HLS" test replaced — cost if wrong: none, the probe shows m3u8 with that streamType.
- Ruling: Task 2 fixture is built from the real single-feed response's shape (O-A, sanitised) with the probe's 26 real channel ids and tme.channel MULTI, URLs as https://example.com/<id>.m3u8; the real one-feed SWITCHER response is committed too as the "fewer than two feeds → multiviewUnavailable" case. Saves an owner round trip — cost if wrong: parser misses a field in MULTI mode; caught at checkpoint O-C on a real build.
- Ruling: fewer than 2 usable feeds → multiviewUnavailable (Android's singleFeedPlan message case); fallback to per-feed player_bm sessions (Android's own fallback when F1 refuses multiview; probe B shows they coexist) is T7's job — follows the owner's "like Android" instruction — cost if wrong: T7 rework.
- Ruling (revises the earlier T7 fallback ruling): the per-feed player_bm fallback is NOT built in T7. The probe shows player_tm with the Android header works, the approved spec says one PLAY per multiview, and the fallback would add a second session model to the hardest task. Refused/unavailable → the spec's error text. Ledgered as a candidate for a later beta (owner to decide) — cost if wrong: a race/account where player_tm is refused shows "Not available for this race" instead of falling back.
- Ruling: O-B (fold behaviour of beta.1 in the simulator) not received; T8 proceeds — players live in the controller, not the views, so a fold change can't restart them by design; the owner's T8 check covers it — cost if wrong: a T8 fix round.
- Ruling: lay out inside the safe rect; drop the optional edge-to-edge main — the spec says "may" — cost if wrong: a few points of width on a full-width main.
- Ruling: Task 8 fix round 2 (owner-found) — move tap and hold-drag to UIKit recognizers on the tile's UIView (UITapGestureRecognizer requiring UILongPressGestureRecognizer(0.35 s) to fail; long-press .changed drives the SwiftUI drag offset), speaker Button stays SwiftUI above it; and LayoutEngine gains book.perScreen for 3 and 4 feeds (slots 0-1 visible, rest hidden) after the default in ⟳ order; spec table updated. Waits for Task 9's implementer (same files) — cost if wrong: another fix round.
- Ruling: driver sheet only for accounts with hasMultiview (it only feeds multiview) — folded into Task 8 fix round 2 dispatch? no: into Task 9 review fix if any, else a T9 follow-up — cost if wrong: trivial. Review dispatched (opus). Task 8 fix round 2 dispatched (resume T8 implementer), FIX_BASE c20fd9b.
- Ruling (for T11): picture in picture shows the feed with the sound (audioChannelId), not slot 0, so the sound continues uninterrupted; on return all feeds resume and re-sync — cost if wrong: PiP shows a different feed than the big one.
- Owner instruction (2026-11-13): release v1.0-beta.2 when the work is done even if not owner-tested; push everything as it lands; mark untested items so they can be tested one by one later. Ruling: CHANGELOG/release notes get an "Untested — check later" list (build checks + simulator checks not yet done, the O-D exit test, live-only behaviour); the exit test O-D moves to that list. Tag/release creation: the owner does it in the GitHub web UI (tag pushes were refused with 403 for beta.1) unless a tool can.
- Ruling: kept speed is not applied to the single-feed player — AVKit's stock player has its own speed menu; beta.1 single feed unchanged — cost if wrong: single-feed speed resets per video.
- Ruling: restore a held-speed notice like Android 4cd41c6 (owner asked for Android behaviour), wording: "This phone can't keep every feed smooth at \(speed). Pick a slower speed to bring them back." — cost if wrong: one sentence.
- Ruling: "Multiview · " prefix on the resume banner accepted (descriptive; listed for the owner in release notes).
- Ruling: final fix wave takes Important 1+2, ledger 149/150/152, Minor 4 (live catch-up keeps the kept speed), Minor 6 Self→type-name hardening; docs (Important 3/4, Minor 1/2/3/8) written by controller — Minor 4 changes Android-copied behaviour, cost if wrong: one line to revert.
- Ruling: Important 5 (owner build before tag) — owner said release whether tested or not, and only the owner can create the tag (web UI); release text will ask for one Mac build first and to tag anyway if it builds — cost if wrong: a beta.2.1 for a compile error.
- Ruling: ledger 151 rejected (state teardown synchronous; worst case F1 TV times out a PLAY session).

## Left for later (from the reviews)

- Per-feed `player_bm` fallback when F1 TV refuses multiview: not built; owner to decide.
- Tracker slightly ahead of the video: owner chose to look again in beta.3 with the timing map.
- Closing a multiview from picture in picture: the F1 TV stop request may outlive the background
  time; the app's own state is already cleared, worst case F1 TV times the session out.
- Reverse race: a future change that closes multiview and starts a single feed in one go must
  wait for the multiview's stop first.
- A multiview bookmark for a race that no longer offers multiview shows "Not available for this
  race" with no single-feed fallback.
- Layout engine: two sweeps per frames() call (trivial cost); laptop last-resort geometry and a
  negative-size test on unusual screens.
- A duplicate channel id in F1 TV's answer isn't handled specially (never seen in real data).
- The pause check uses a 1 s end margin (a brief misread at worst).
- The book layout's top bar spans the crease in its non-interactive middle (cosmetic).
- MultiviewStore has no concurrency test (one store instance by design).
