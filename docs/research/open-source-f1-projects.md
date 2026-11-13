# Open-source F1 projects: what Apex DuoView can borrow

Roadmap read first; all three repos cloned and read (README plus key source). #N = roadmap idea number.

## 1. IAmTomShaw/f1-race-replay (MIT per README; no LICENSE file in the repo root, so ask the author to add one before copying code)
- **What:** Python 3.11 desktop replay (Arcade, PySide6). Data only via FastF1. No server.
- **Technique:** `f1_data.py` resamples each driver's x, y, race distance, speed, gear, DRS and tyre onto one 25 fps timeline with `np.interp`, sorts cars by (lap, distance) for positions, and marks pit windows from PitIn/PitOut times.
- **Track map:** a dense reference polyline from one lap, edges from normals (winding fixed with the shoelace formula), cars projected onto it with a KD-tree for along-track distance, rotated by the circuit's rotation value.
- **Safety car:** F1 has no GPS for it, so it is simulated from track status (4 = SC, 5 = red, 6 = VSC, 7 = VSC ending). It deploys, leads the pack, then returns.
- **Other:** purple/green sector classification plus a theoretical best lap (`lib/sectors.py`). A scipy Bayesian tyre-degradation model (fuel 0.032 s/kg, 110 kg start, 1.6 kg/lap burn). Official lap times aligned to replay time by a median offset. The author lists the leaderboard as inaccurate in the first corners, in pit stops and at the finish.
- **iPhone adaptation:** don't prebuild whole-race frame dictionaries. Keep per-driver sorted samples and interpolate on demand at display rate (binary search plus linear blend). Replace scipy with a small fuel-corrected linear fit. Replace the KD-tree with a windowed nearest-point search from the last index.

## 2. slowlydev/f1-dash (AGPL-3.0: no code can be copied; ideas and formats only)
- **What:** Rust (Axum) relay plus Next.js. The server connects to F1 live timing and pushes websockets to the web UI, so it needs a backend. We would connect directly from the phone.
- **Live feed:** OPTIONS pre-negotiate to get the `AWSALBCORS` cookie, then negotiate and open the websocket, with User-Agent `BestHTTP` and gzip. Topics: Heartbeat, ExtrapolatedClock, TimingStats, TimingAppData, WeatherData, TrackStatus, SessionStatus, DriverList, RaceControlMessages, SessionInfo, SessionData, LapCount, TimingData, TeamRadio, CarData.z, Position.z. Updates are partial patches folded into state by `merge.ts`.
- **Possibly stale:** it uses the older `/signalr` URL, while FastF1 uses `/signalrcore`. Check which is current.
- **Delay sync:** `useBuffer` keeps timestamped frames and binary-searches the one at (now minus delay). That is the technique for matching data to a delayed or replayed picture.
- **Mini-sectors:** segment status 2048 yellow, 2049 green, 2051 purple, 2064 blue, 0 none. Sector values carry `OverallFastest` and `PersonalFastest`.
- **`calculatePosition`:** takes N seconds lost and walks the gaps of the cars behind to give a rejoin position. That is the core of "pit now?".
- **Map:** outline, corners and marshal sectors from `api.multiviewer.app/api/v1/circuits/{key}/{year}`.
- **Extras:** wake lock, OLED mode, radio playback with a track-time offset.
- I did not read the UI components in depth.

## 3. theOehrly/Fast-F1 (MIT)
Python and pandas library over the static archive, Jolpica (Ergast-compatible) and a live client. Beyond the layout we already credit:
- **Live auth.** The live client signs in to the F1 account (OAuth2 PKCE) and sends the F1TV subscription token as a Bearer token. Its docs say that without it data may be "incomplete or missing". This matches our own-sign-in model. I did not verify that the video-API token is the same token.
- **Position format.** Use the `Date` field, because `Time` is inaccurate and has duplicates. Coordinates are in 1/10 m since 2020, with OnTrack/OffTrack status. `.z` payloads are base64 plus raw deflate, which the Swift Compression framework can decode.
- **`IsAccurate` lap rule.** No pit in or out. Track status in {1, 2, 12, 21}. All three sectors present. Sector sum within 3 ms of lap time. Previous lap not under SC. This is the clean-lap filter for pace.
- **Stints.** `Stint`, `FreshTyre` and `TyreLife` come from TimingAppData, with glitch repair.
- **`calculate_driver_ahead`.** Distance to the car ahead from telemetry. Its docs warn that error grows beyond one or two laps.
- **Circuit info.** The same MultiViewer data: corner number, letter, angle and distance.

## Top picks (ranked)
1. **Resample and interpolate Position.z/CarData.z on demand** (beta.3; #11, #19, #15). It makes the map match the picture, aligned to `#EXT-X-PROGRAM-DATE-TIME`.
2. **f1-dash-style timestamp buffer and delta merge** (beta.3, building on beta.2 resume). One clock drives video, map and tower, and "while you were away" (#2, #8) becomes a state lookup.
3. **Mini-sector and sector colour codes** (beta.3 timing, beta.4 purple haptic #4; #16, #22). Cheap, and readable at arm's length on the Kitchen Board.
4. **Outline, corners and marshal sectors** (beta.3). Use MultiViewer where terms allow. Fall back to building the outline from one lap of position data. Corner markers also feed Watch This Corner (#26, beta.7).
5. **Polyline projection for along-track distance** (beta.4 Gap Thermometer #9, beta.5 Mirror Lap #15). On the hinge, sync two onboards by track position, not clock time.
6. **Strategy Lab engine** (beta.5, #13): stints from TimingAppData, `IsAccurate` filter, fuel-corrected degradation, and the `calculatePosition` walk with a pit-loss input.
7. **Track-status timeline** (beta.3 Scrub Deck #20; beta.4 flag haptics #4 and Unfold to See #8), with a synthetic SC marker.
8. **Live auth plus raw recording** (beta.3, the Android 0.99.4 item): subscriber token on the live feed, and record raw `.z` messages to disk while the app is open.

## Legal and terms
- No f1-dash code (AGPL). Topic names, status codes and endpoint knowledge are fine.
- MultiViewer's API and the FastF1 mirror (`livetiming-mirror.fastf1.dev`) are third-party services with no stated terms. Don't depend on the mirror, and don't redistribute F1 data. Fetch per user and cache locally.
- Live timing needs the user's own F1TV token. Never bundle a token or proxy data through our own server.
- All three projects carry the "unofficial, Formula One Licensing trademark" notice. We should too.
