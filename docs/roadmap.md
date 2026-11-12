# iOS app for iPhone Duo: approved decisions

The iPhone Duo is the design target. The app's reason to exist is what the fold makes possible
that the official F1 TV app doesn't do. Personal and unofficial; uses each person's own F1 TV
subscription. No paid services or servers beyond Apple's developer fee.

## Launch version

**1.0.** Before launch, every release is a numbered beta of 1.0, then one release candidate, then
the launch. Adding a beta needs the owner's written yes.

| Release | Title | Exit test (checked by the owner) |
|---|---|---|
| v1.0-beta.1 | Foundation | On the 15 Pro Max: sign in, play the São Paulo race replay, close the app, reopen it and it resumes at the same moment |
| v1.0-beta.2 | Multiview and fold | Four São Paulo feeds play together for 10 minutes without stalling; in the Duo simulator, folding and unfolding keeps the same feeds and position |
| v1.0-beta.3 | Live data | On a replay, the track map and timing match the picture; tapping a car brings up its onboard; laptop pose shows Race Engineer and Scrub Deck |
| v1.0-beta.4 | Radio and the closed phone | Team radio plays by lap with transcripts; the closed-phone modes work in the simulator; haptics fire on flags |
| v1.0-beta.5 | Showpieces | In Mirror Lap, two onboards reach the same corner together on a replay; Strategy Lab, Then and Now and Prediction Pad work |
| v1.0-beta.6 | Between races | Calendar shows local times and a reminder fires; Kitchen Board, Countdown Lamp, Archive Atlas, recap and Dynamic Island work |
| v1.0-beta.7 | Real device | Every mode checked on the Duo across one live race weekend; experiments 24 to 28 tried, then kept or dropped |
| v1.0-rc.1 | Release candidate | Fixes only; launch check is a full live race weekend with no blocking bug |
| v1.0 | Public launch | |

## Duo ideas and where they land

All of 1 to 23 are in. 24 to 28 are experiments for beta.7, tried on the real device.

| # | Idea | Pose | Beta |
|---|---|---|---|
| 1 | Folding is the interface: unfold zooms in, fold zooms out, never lose your place | All | 2 |
| 2 | Close equals bookmark: shutting pauses and marks; opening resumes or offers "while you were away" live | All | 1 |
| 3 | Three rooms: Race Weekend, Paddock, Archive | All | 1 |
| 4 | Haptic vocabulary: yellow flag, safety car, your driver pits, purple sector | All | 4 |
| 5 | Fold-shut recap: 60-second summary on the outer screen after a session | All | 6 |
| 6 | Hinge as an audio mixer: angle crossfades commentary and driver radio | All | 4 |
| 7 | Radio Scanner: one driver's radio with scrolling transcript, swipe to change | Closed | 4 |
| 8 | Unfold to See: event card; opening jumps to that moment, rewound a few seconds | Closed | 4 |
| 9 | Gap Thermometer: two cars, colour shifts as the gap closes | Closed | 4 |
| 10 | Island Flag Ring: flag, lap and position in the Dynamic Island (needs device test) | Closed | 6 |
| 11 | Director's Desk: big picture, thumbnail feeds, tower and map (needs device test) | Open | 3 |
| 12 | Race Table: flat between two people, each half faces its viewer | Open | 2 |
| 13 | Strategy Lab: tyre stints and a "pit now?" rejoin estimate | Open | 5 |
| 14 | Archive Atlas: pick a circuit, every race there since 1981 | Open | 6 |
| 15 | Mirror Lap: two onboards synced by track position, gap on the hinge (replays first) | Book | 5 |
| 16 | Onboard and Logbook: onboard plus that driver's radio, sectors and stops | Book | 4 |
| 17 | Ear-Matched Rivals: each rival's radio in one AirPod | Book | 4 |
| 18 | Then and Now: today's race beside a classic at the same circuit (needs test) | Book | 5 |
| 19 | Race Engineer: onboard upright, engineer's console below | Laptop | 3 |
| 20 | Scrub Deck: video upright, touch timeline of race events below | Laptop | 3 |
| 21 | Prediction Pad: tap your calls, scored privately | Laptop | 5 |
| 22 | Kitchen Board: large-type timing board, screen turns yellow or red on a flag | Standing | 6 |
| 23 | Countdown Lamp: next circuit and countdown between races | Standing | 6 |
| 24 | Hinge as a picture/data dial | Experiment | 7 |
| 25 | Multiview beyond about four feeds | Experiment | 7 |
| 26 | Watch This Corner: cut to each car's onboard as it reaches a corner | Experiment | 7 |
| 27 | Voice questions | Experiment | 7 |
| 28 | Two-audience tent: both screens active at once | Experiment | 7 |

The Android app's own features (multiview, track map, flags, timing cards, team radio, resume,
picture in picture, Driver of the Day, what to watch next, catalogue, calendar and reminders) are
carried over in betas 1 to 6. The Android TV remote and the self-updating installer are not.

## Version numbers and releases (owner's standard)

1. Format: vX.Y, or vX.Y.Z only when a patch exists. Always keep the leading "v". Never add a
   trailing .0 (v2.1, not v2.1.0).
   - X = major generation or redesign (resets the lower numbers).
   - Y = a new feature or phase within that generation.
   - Z = a small fix within that feature release (v2.1.1).
2. Before public launch, every release is a numbered beta of the launch version: v1.0-beta.1,
   v1.0-beta.2, … then one release candidate v1.0-rc.1 (fixes only), then the launch v1.0.
   - Each beta is one milestone from the fixed roadmap above with a plain exit test.
   - A fix to a beta already in use is v1.0-beta.N.1, .2, …
   - If the launch check fails, the next is v1.0-rc.2. Otherwise rc.1 becomes v1.0.
   - Where a tool needs plain numbers, it gets them there and the tag and title keep the short
     form. In Xcode, MARKETING_VERSION stays 1.0 through every beta and the build number goes up
     each build (TestFlight and the App Store reject "-beta").
3. After launch: v1.1 for the next feature release, a patch like v1.1.1, and so on. A new major
   generation starts at v2.0.
4. Every version gets a Git tag, a GitHub Release (betas and RCs marked as pre-release, never
   "Latest") and a dated CHANGELOG.md section. Keep an "Unreleased" section for work in progress.
5. Never renumber, move or rewrite a released version, tag or release. Keep one source of truth
   for the current version, and don't leave old version labels lying around.

Release titles: "v1.0-beta.1 — Foundation", "v1.0-rc.1 — Release candidate", "v1.0 — Public launch".

## Verified so far (São Paulo 2026 race replay, owner's Premium account, US)

- Sign-in and play requests work from a plain client; the `WEB_DASH` request style returns HLS.
- Single feed and all 26 multiview feeds came back as HLS with no DRM key tags (first feed's
  playlists checked only). Not yet verified: live sessions.
- 2026-11-12: the São Paulo race stream (world feed, signed link from the play API) played in
  Safari on the owner's Mac, which uses the same Apple video engine as the app.
  Seeking to a later point also worked.
- The race's streams (pipeline 6, 6-second segments) carry #EXT-X-PROGRAM-DATE-TIME on every
  feed checked (world feed, F1 Live, an onboard, the last onboard), all starting at the same
  instant, so feeds can be kept in step with each other and with live timing.
- Multiview feeds are labelled: onboards carry `metadata.racing_number` and a team-radio audio
  track named with the driver's three-letter code (`audio_track_names.tea`). The world feed has
  seven commentary languages plus "Track FX" (race sound without commentary); F1 Live has English
  and Spanish. Onboards are marked `optionality=optional-on-stream-failure`.
- An older pipeline-1 video carried six commentary languages plus an "FX" track (race sound
  without commentary) and no #EXT-X-PROGRAM-DATE-TIME.
- F1 TV's config publishes a FairPlay certificate, so protected content may exist elsewhere.

## Screenshots

README screenshots (and later App Store screenshots) are made with the
[app-store-screenshots](https://github.com/ParthJadhav/app-store-screenshots) skill, which has
iPhone Duo outer and inner display frames. It is installed and used once the UI is ready to show,
starting with the first beta whose screens are worth presenting, from simulator captures taken on
the owner's Mac. The skill's project file (`app-store-screenshots.json`) is kept in the repo so
the deck can be updated each beta.

## Keeping up with the Android app

`og-android` is a copy of the original Android app, kept current with GitHub's Sync fork. It is
never edited here, and its code is not on `ios`; the two branches are never merged.

When `og-android` gets an update, its changes are read there (agents fetch the branch and read
the files directly) and anything worth having is rebuilt in Swift as part of a beta, or listed for
a later one. The last Android version already reviewed is recorded here, so it's always clear what
is new.

Last Android version reviewed: **0.94**.
