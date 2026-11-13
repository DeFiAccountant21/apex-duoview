# Changelog

Versions follow the standard in [docs/roadmap.md](docs/roadmap.md).

## Unreleased

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
  without commentary (Track FX), audio that keeps going when the screen is off, and picture in
  picture. Picture in picture is switched off for now while it is finished.
- Bookmarks and resume: the app remembers where you stopped in each session, and picks up there
  when you reopen it, even after the app was closed.
- A fold adapter that reads the phone's hinge, with a readout in Settings and a simulated fold
  for testing without the hardware. Nothing changes shape with it yet.
- A dark style with near-black backgrounds, silver text and racing red, and a new app icon.
- A hidden test screen that checks how well two feeds stay in step, for the multiview work
  planned for later betas.
- DuoCore logic library: F1 TV request building, sign-in exchange and cookie decoding, resume
  bookmarks, watch history and the resume decision, with tests that run on every push.
- Throwaway stream check confirming F1 TV serves iPhone-playable streams for replays, with a
  live-session mode, a live timing recorder and fixture recording.

Known limits: no multiview yet, the dark style only, and live sessions are not yet verified.
