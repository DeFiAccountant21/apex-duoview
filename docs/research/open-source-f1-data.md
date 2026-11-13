# Six more F1 data projects: what Apex DuoView can borrow

All six cloned and read on 2026-11-13. #N = roadmap idea. Caveat: openf1.org and the live APIs were unreachable from this session, so OpenF1 and Jolpica terms come from their repos (docs, code, TERMS.md), not the live sites. Re-check before relying on them.

## 1. f1db/f1db (CC BY 4.0)
- **What:** all-time data, 1950 to now: drivers, constructors, circuits with layouts, race, qualifying and sprint results, grids, fastest laps, pit stops, Driver of the Day, standings. Static download, no API. Release v2026.20.0 (9 Nov 2026), tagged after every round. Formats: JSON, CSV, SQLite, SQL, Smile. Source YAML is 96 MB; I couldn't read release asset sizes.
- **Circuit SVGs:** 160 layouts (Monaco has 6 eras, Interlagos 2), each in black, white and outline styles. About 660 KB per style. They are single-stroke paths, so they tint easily. They are in the repo only, not in the release zips.
- **Terms:** CC BY 4.0 is commercial-safe and MIT-compatible. We owe credit: "Data: F1DB, CC BY 4.0" in About, plus a link. Bundling is fine.
- **Gaps:** no team colours, no headshots, no lap-by-lap data.
- **Fit:** best of the six. Build a compact JSON or SQLite subset (results, pit stops, fastest laps, drivers, circuits) and read it with GRDB or SQLite3. Measure the size, but a post-1981 subset should be single-digit MB. Update it with each app release, or fetch the release asset at runtime.
- **Feeds:** Archive Atlas #14 (beta.6), Then and Now #18 (beta.5), Countdown Lamp #23.

## 2. bacinger/f1-circuits (MIT)
- **What:** GeoJSON, 40 circuits, one LineString each (about 4,800 points in all, 116 KB). Real lat/lon with length, opened year and altitude. Per-season calendar lists for 2020 to 2026 (2026 has 23 rounds, including Madring). Updated 16 Oct 2026.
- **Terms:** MIT. Keep the copyright notice. Bundle freely.
- **Catch:** it's geographic, not F1's own x/y position frame. Using it for the live map would need a fitted transform. Keep MultiViewer as the live map source.
- **Fit:** this is the fallback and static layer: calendar and Countdown Lamp #23, Archive Atlas pins #14, an outline when MultiViewer is down, and a tiny glyph for the Dynamic Island #10. Use MapKit or project the points yourself. Cheap to bundle.

## 3. br-g/openf1
- **What:** REST API (plus MQTT and WebSocket for live) over a MongoDB, ingesting F1's own livetiming feed. It processes that feed into: car_data and location (about 3.7 Hz), laps, intervals, position, stints, pit, overtakes, race_control, weather, team_radio (mp3 URLs on livetiming.formula1.com), drivers (headshot_url, team_colour), results and starting grid. Historical data is free, from 2023, no auth.
- **Live:** needs a paid sponsorship and an OAuth2 token per user. Team radio coverage fell sharply in 2026.
- **Limits:** the server code sets 30 requests per 10 s per IP. Authenticated users get higher limits. Phones on carrier NAT share IPs.
- **Terms:** the repo LICENSE is CC BY-NC-SA 4.0, but pyproject.toml says MIT. That's a conflict, so treat the data and code as NC-SA until the author clarifies. NC blocks a paid app, and SA conflicts with our MIT. Don't bundle. Don't copy code.
- **Fit:** it duplicates what our own sign-in already reads straight from F1 (live feed plus the DriverList colours and headshots). It adds latency and a dependency, so it is not a live alternative.
- **Two real uses:**
  1. **Dev-only fixtures.** Record free 2023+ location, car_data and laps to drive the beta.3 map and timing in the simulator without an F1 TV session. Never commit or ship them.
  2. **A reference for derived rules** (overtakes, intervals, the lap-1 time fix) that we reimplement ourselves.

## 4. jolpica/jolpica-f1 (Ergast successor)
- **What:** Ergast-compatible REST API. Results, standings, laps and pit stops; laps from 1996. Volunteer-run, no uptime promise. CSV database dumps are available.
- **Terms:** CC BY-NC-SA 4.0 (TERMS.md). The code is Apache-2.0, but the data is NC-SA. Commercial use needs a deal: admin@jolpi.ca, or the supporter tier.
- **Limits:** 4 requests per second burst and 500 per hour sustained, per IP, and the docs say limits "will decrease". Unauthenticated phones sharing a NAT would hit that quickly.
- **Fit:** not for the shipping app. The only unique value is lap-by-lap positions for pre-2018 races. I'd skip it. If wanted later, make it opt-in, user-initiated, cached, with a tiny footprint. Remove it, or get a licence, before any paid tier.

## 5. davidor/formula1-lap-charts (CC BY-SA 3.0)
- **What:** an AngularJS lap chart (position against lap, one line per driver), fed by Ergast. Last commit June 2021, and Ergast is gone.
- **Terms:** SA means we can't copy its code into an MIT app.
- **Fit:** idea only, and a good one: the lap chart design (after Chris Pudney's d3 chart). Draw it in SwiftUI Canvas from our own TimingData per-lap positions, with pit marks and SC bands.

## 6. toUpperCase78/formula1-datasets (GPL-3.0)
- **What:** CSVs of 2019 to 2026 race, qualifying and sprint results, calendars, drivers, teams and Driver of the Day votes (2022 to 2024), plus game ratings. Scraped from formula1.com. About 150 MB, mostly PNG photos. Last commit 11 Nov 2026 (2026 results, 20 of 23 rounds).
- **Terms:** GPL-3.0 on data is copyleft. It conflicts with MIT, and its provenance is scraped F1 content. The photos are F1's copyright.

## Ranked additions
1. **F1DB subset for Archive Atlas and Then and Now** (beta.5 and beta.6). It gives race history by circuit with the right credit, and a classic race (layout, winner, fastest lap, pit stops) beside today's. It works on the closed phone as a single-handed browse, and spread out on the inner screen in Book pose for the side-by-side.
2. **F1DB circuit SVGs, with the bacinger locations** (beta.5 to beta.6). Era-correct layouts for Then and Now, and for Archive Atlas thumbnails. Convert the SVG paths to Swift Paths at build time. A small tinted glyph also suits Countdown Lamp and the outer screen.
3. **Lap chart in Scrub Deck** (beta.3, #20). In Laptop pose the touch strip below the upright video becomes position against lap. Tap a line to scrub there. Design idea only, built from our own data.
4. **bacinger outline as map fallback** (beta.3). When MultiViewer is unavailable, show a static outline in the Director's Desk #11 map slot.
5. **OpenF1 recordings as dev fixtures** (beta.3 development). Test the map, timing and Mirror Lap sync without a live session. Local only.

## Don't use
- **formula1-datasets:** GPL-3.0, scraped, F1's photos, and F1DB covers the same ground.
- **Jolpica in the shipped app:** NC-SA, 500 per hour per IP, no uptime promise.
- **OpenF1 as a live source or bundled data:** conflicting NC-SA licence, paid per user, a lagging mirror of data we already read directly.
- **lap-charts code:** share-alike, AngularJS, stale since 2021.
- **bacinger GeoJSON as the live map:** wrong coordinate frame, current layouts only. Keep MultiViewer.
- **Our credit notices:** add the F1DB CC BY 4.0 credit and the bacinger MIT notice, plus the usual unofficial/F1 trademark line.
