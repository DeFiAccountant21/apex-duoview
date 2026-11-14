# Changelog

Versions follow the standard in [docs/roadmap.md](docs/roadmap.md).

## Unreleased

Everything below is for **v1.0-beta.2 — Multiview and fold**.

- **Multiview.** On a session with two or more feeds, Premium accounts get a "Watch multiview"
  button: four feeds play at once, in step, from one F1 TV request. Other accounts see
  "Multiview needs F1 TV Premium".
- **Fit to the screen for every fold.** Flat, half-open like a book, half-open like a laptop and
  closed each get their own layouts for one to four feeds, using as much of the screen as the
  16:9 picture allows and never putting a feed in the fold. "Switch layout" (⟳) goes through the
  other layouts for that fold and feed count, including one feed per screen when half-open, and
  remembers your choice. Folding and unfolding glides the feeds to their new places without
  restarting them. Closed, you swipe left or right to change the feed.
- **Arrange by hand.** Tap a small feed to swap it with the big one (tap again to swap back), or
  press, hold and drag a feed onto another to trade places.
- **Sound from any feed.** Each feed has a speaker button; the sound and the red SOUND badge move
  to that feed without moving it.
- **Choosing feeds.** The default four are the world feed, your driver's onboard, the tracker and
  the data feed. A "Pick your driver" sheet asks once after signing in (Premium accounts), and
  Settings › Multiview › My driver changes it. The feeds editor changes any spot, clears all,
  resets to default, and saves up to 8 named presets of feeds and layouts. The last feeds you
  used come back next time.
- **Fewer than four feeds.** Removing a feed asks once whether to keep four spots or fit the rest
  to the screen, and remembers the answer (Settings › Multiview › When a feed is missing).
- **Controls.** Play and pause, one timeline for every feed, speed from 0.5× to 2× (kept between
  videos), commentary language or Track FX for the feed with the sound, and LIVE during live
  sessions. They fade after a few seconds; tap "•••" or the space around the feeds to bring them
  back.
- **When the phone can't keep up,** the other feeds pause with "Paused to keep the main feed
  smooth" and come back in step. A speed that was too much is remembered while the app is open.
- **Picture in picture** for multiview (the feed you're listening to) and for a single feed.
- **Resume** reopens multiview at the same moment.
- **Live sessions** ask "From the start" or "Watch live" before playing, and "From the start"
  starts at the start (Android 0.97–0.98).
- The multiview request identifies as the Android web player, which is how F1 TV returns every
  feed at once.
- The hidden test screen from beta.1 is removed.

### Untested — check later

Built and reviewed, but not yet tried by the owner:

- Builds 5 to 8 (controls, picture in picture, resume and live start, clean-up): the build and
  the simulator check for each.
- Picture in picture: leaving the app, coming back by the window and by the app icon, the
  window's close button, and another app taking over picture in picture.
- Resume of a multiview session after closing the app.
- Speed kept between videos; a speed that struggled being remembered; the note it shows.
- The feeds editor's preset row (the menu and the tap sharing one row).
- VoiceOver on the feeds.
- Live-only: LIVE, the drop back to 1× at the live edge, "From the start" / "Watch live", and the
  multiview layouts on a live race (next live check: Las Vegas, Nov 19–22).
- The beta.2 exit test: four São Paulo feeds for 10 minutes without stalling, and every fold
  keeping the same feeds in step at the same moment.
- On the real iPhone Duo (beta.7): everything above on the hardware.

## v1.0-beta.1 — Foundation (2026-11-13)

- Approved roadmap to v1.0: seven betas, one release candidate, then launch.
- App named Apex DuoView: an iPhone app for watching F1 TV, built around the iPhone Duo's fold.
- Sign in with your F1 TV account on F1's own page, or paste a sign-in token instead. The app
  remembers it on your phone. If it expires you see a message with a Sign in button, and if F1 TV
  can't be reached when the app opens you can try again.
- Three rooms:
  - Race Weekend: live and upcoming sessions, the weekend's schedule and a Continue watching
    banner.
  - Paddock: rows of F1 TV's featured and recent content.
  - Archive: browse by season and race weekend, back to 1981.
- Open any session to see its feeds, including every onboard, and play one.
- The player plays one feed full screen, with a choice of commentary language or race sound
  without commentary (Track FX), and audio that keeps going when the screen is off. Picture in
  picture comes in a later beta.
- Bookmarks and resume: the app remembers where you stopped in each session, and picks up there
  when you reopen it, even after the app was closed.
- If your F1 TV account has no video plan, the app tells you so after sign-in.
- Settings shows the app version, for example "Apex DuoView v1.0-beta.1 (build N)".
- A fold adapter that reads the phone's hinge, with a readout in Settings and a simulated fold
  for testing without the hardware. The first thing that follows the fold: when the phone is
  half-open like a book, Settings sits on the right-hand screen instead of the left, and glides
  to the middle when you open the phone flat and back when you fold it again.
- A dark style with near-black backgrounds, silver text and racing red, and a new app icon,
  also shown on the launch screen, the sign-in screen and in About.
- A hidden test screen that checks how well two feeds stay in step, for the multiview work
  planned for later betas.
- DuoCore logic library: F1 TV request building, sign-in exchange and cookie decoding, resume
  bookmarks, watch history and the resume decision, with tests that run on every push.
- Throwaway stream check confirming F1 TV serves iPhone-playable streams for replays, with a
  live-session mode, a live timing recorder and fixture recording.

Known limits: no multiview yet, the dark style only, and live sessions are not yet verified.
