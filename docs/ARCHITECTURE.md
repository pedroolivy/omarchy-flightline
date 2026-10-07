# Flightline v2.1 — architecture and contracts

This file is the contract between Flightline's parts. Anything not written
here is up to the owner of the file. Change a contract only by editing this
document first. `docs/VISUAL.md` is the art direction (how it should look and
why); the formats, properties and budgets it set for v2.1 are folded in here.

## Goals (in priority order)

1. **Near-zero cost.** Panel closed: 0 frames, one small request a minute.
   Panel open and still: no frame unless something visibly moved (≥ 0.5 px).
   Dragging/zooming: full refresh rate with < 1 ms CPU per frame. The shell's
   GUI thread (shared with the bar) never parses large JSON and never runs
   per-aircraft JavaScript per frame.
2. **Many aircraft.** Up to 10,240 aircraft drawn at once (the whole world is
   ~9.5k), smoothly dead-reckoned on the GPU between feed updates.
3. **Beautiful and Omarchy-native.** Cartographer-grade and quiet: depth
   comes from light (relief, sea-floor depth, sunlight, atmosphere), never
   from decoration, and nothing moves unless the user acts or data arrives.
   Every colour comes from the active theme (`qs.Commons` `Color`):
   `foreground`, `background`, `accent`, `muted`, `urgent`. Monospace shell font, Omarchy panel conventions (KeyboardPanel
   popout under the bar pill, `PanelSectionHeader`, `Button`, Esc/Tab).

## Layout

```
manifest.json          service + bar-widget (v2.1.0)
Service.qml            data engine, location, search, routes        (owner: service)
flightline-feed        python3 helper: feed JSON → PPM + meta + summary (owner: feed)
flightline-locate      Wi-Fi → BeaconDB helper (unchanged from v0.1)
Model.js               pure JS helpers (geodesy, formatting, parsers)  (stage 1: service, stage 2: ui)
Globe.qml              GPU globe ShaderEffect                          (owner: shaders)
Aircraft.qml           GPU aircraft ShaderEffect, with its shadow and focus layers (owner: shaders)
Trails.qml             GPU comet tails under the aircraft (Aircraft.qml stacks it) (owner: shaders)
RouteArc.qml           GPU ribbon of the selected flight's route          (owner: ui)
GlobeView.qml          camera, interaction, labels, picking, layers    (owner: ui)
GlobePalette.qml       every globe colour derived from the 5 theme colours (owner: ui)
LookUp.qml, SkyModel.js  "Look up" sky-dome lens                       (owner: lookup)
Panel.qml, BarWidget.qml                                               (owner: ui)
shaders/*.vert|frag    GLSL 440 sources; shaders/*.qsb baked outputs   (owner: shaders)
assets/earth.png, assets/lights.png, assets/terrain.png, assets/places.json (owner: assets)
tools/                 build-textures.sh, sdfbake.c, geo2bin.py, build-shaders.sh, build-geo.py,
                       build-terrain.sh, terrainbake.c
tests/                 model.test.mjs, sky.test.mjs, feed/ (python), offscreen/ (qml render
                       tests: run.sh, globeview.sh, lookup.sh, bench.sh, FakeService.qml, Shots.qml)
docs/ARCHITECTURE.md   this file
docs/VISUAL.md         art direction: palettes, moods by zoom, the look of each layer
```

Rendering components (`Globe.qml`, `Aircraft.qml`, `Trails.qml`,
`RouteArc.qml`, `GlobeView.qml`, `GlobePalette.qml`, `LookUp.qml`) import
**only QtQuick / QtQuick.Shapes / Quickshell.Io** — never `qs.Commons` or
`qs.Ui`. Colours, fonts and sizes come in as properties, so
they can be rendered offscreen with `/usr/lib/qt6/bin/qml` for tests:

```sh
QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen \
  /usr/lib/qt6/bin/qml tests/offscreen/<test>.qml      # GPU, no window
```

Only `Panel.qml`, `BarWidget.qml` and `Service.qml` may import `qs.*`.

## Runtime files

Everything transient lives in `$XDG_RUNTIME_DIR/flightline/` (tmpfs). Without
`XDG_RUNTIME_DIR` there is no feed (status `error`): a shared fallback such as
`/tmp` would let another user plant symlinks before the helper checks the dir.
The `snapshot` IPC writes `$XDG_RUNTIME_DIR/flightline-snapshot.png`.

| File | Writer | Reader |
|------|--------|--------|
| `raw-<n>.json` | `curl` (Service) | `flightline-feed` (deletes it after, only because it is inside `--out-dir`) |
| `traffic.ppm` | `flightline-feed` (atomic rename) | `Aircraft.qml` (`Image`, async, `cache: false`) |
| `meta.json` | `flightline-feed` (atomic rename) | `Service.meta()` (lazy, on demand) |

## Data texture — `traffic.ppm`

Binary PPM `P6`, **256 × 200**, maxval 255, always this size (capacity
10,240 aircraft = 40 blocks of 256). Aircraft `k` lives in block `b = k >> 8`,
column `c = k & 255`. Each field is a 24-bit big-endian value in one RGB
texel at `(x = c, y = 5·b + row)`:

| row | field | encoding |
|-----|-------|----------|
| 0 | latitude | `round((lat + 90) / 180 · 16777215)` |
| 1 | longitude | `round(((lon + 180) mod 360) / 360 · 16777215)` |
| 2 | track + flags | `(round(track/360 · 65535) << 8) | flags` |
| 3 | speed + altitude | `(min(65535, round(gs_kt · 16)) << 8) | altBand`, `altBand = clamp(round(alt_ft / 250), 0, 255)` (0 when on ground) |
| 4 | observation time | `clamp(round(obs_ms − epochMs), 0, 16777215)` |

`flags` (8 bits): bit0 on ground · bit1 emergency (squawk 7500/7600/7700 or
`emergency` ≠ none) · bit2 military (`dbFlags & 1`) · bits3–5 glyph class
(0 jet, 1 heavy, 2 light/GA, 3 rotorcraft, 4 glider/balloon/other,
5 ground vehicle) · bits6–7 reserved (0).

Aircraft missing a track are written with `gs = 0` (they do not move).
`epochMs` = fetch time − 300,000 ms (so every observation offset is ≥ 0).
Aircraft are ordered by ascending altitude (higher ones draw on top); ground
traffic first. Unused slots are all zero; the shader ignores `k ≥ count`.
Plain ground traffic is drawn without the dark outline (halo), so airport
clusters do not merge into smudges.

Dead reckoning (shader and JS must agree): position at time `t` (seconds since
`epochMs`) = great-circle destination from (lat, lon) along `track` for
`gs · 1.852 / 3600 · max(0, min(t − t_obs, maxAge))` km, Earth radius
6371 km. `maxAge` = 90 s for live data and 120 s for world answers (they come
every 60 s and take a while to download); fade out from 70 % of maxAge.

## Meta — `meta.json`

Index-aligned with the PPM (`k`). Parsed lazily by the GUI thread only when
needed (hover, click, labels, cards), at most once per revision.

```json
{"rev": 12, "epochMs": 1791058514001, "n": 9481,
 "hex": ["4d2453", ...], "cs": ["WZZ239", ...], "ty": ["A21N", ...], "rg": ["9H-WBI", ...],
 "op": ["", ...], "lat": [50.2927, ...], "lon": [8.0567, ...], "alt": [18400, ...],
 "gs": [368.6, ...], "trk": [318.96, ...], "t": [297.9, ...], "vr": [-2048, ...],
 "sq": ["6017", ...], "cat": ["A3", ...], "flags": [0, ...]}
```

`alt` = feet, `-1` on ground, `null` unknown. `t` = observation time in
seconds since `epochMs` (one decimal). `gs`, `trk`, `vr` may be `null`.
Strings are sanitised exactly like v0.1 `Model.sanitizeAircraft` (hex
`^~?[0-9a-f]{6}$`, callsign `^[A-Z0-9-]{1,8}$`, registration
`^[A-Z0-9-]{1,10}$`, type `^[A-Z0-9]{1,4}$`, squawk `^[0-7]{4}$`, category
`^[A-D][0-7]$`, free text ≤ 48 chars, no control or invisible format
characters: C0, DEL, C1, U+061C, U+200B–200F, U+2028–202E, U+2060–206F,
U+FEFF, the same class in `flightline-feed` and `Model.cleanString`).

## Summary — `flightline-feed` stdout

One line of JSON, small (< 8 KB), parsed by `Service.qml` on every update:

```json
{"ok": true, "rev": 12, "source": "adsb.lol", "epochMs": 1791058514001, "fetchedMs": 1791058814001,
 "n": 9481, "airborne": 8700, "dropped": 0,
 "query": {"lat": 0, "lon": 0, "radiusNm": 10800},
 "home": {"lat": 51.47, "lon": -0.45, "radiusNm": 100, "count": 4,
          "nearest": [{"i": 812, "hex": "406b90", "cs": "BAW117", "ty": "B77W", "rg": "G-STBA", "op": "",
                       "lat": 51.6, "lon": -0.1, "alt": 40000, "gs": 455, "trk": 41, "vr": 0,
                       "km": 28.4, "brg": 59.0}]},
 "emergencies": [{"i": 77, "hex": "...", "cs": "...", "sq": "7700", "lat": 0, "lon": 0, "alt": 12000}],
 "maxGs": 612}
```

`home` is `null` when no `--home` was given; `nearest` holds up to 8 airborne
aircraft within the radius, closest first. When none is inside (`count` 0),
`home.nearestAny` holds the 5 closest airborne aircraft at any distance (same
row shape), so the panel's fallback list never needs meta.json; otherwise it
is `[]`. `i` indexes the PPM/meta. `maxGs` is a robust maximum: the 99.5th
percentile of the moving airborne aircraft (the true maximum below ~100 of
them), capped at 1,000 kt, so one bad report cannot speed up the idle clock.
On failure: `{"ok": false, "error": "short reason"}` and exit code ≠ 0
(2 bad input or arguments, 3 output not writable).

CLI (Service passes every option as `--opt=value`, so a negative latitude is
never read as an option, and runs the helper as `python3 flightline-feed`):

```
flightline-feed --in RAW.json --out-dir DIR --rev N --source NAME
                [--home LAT,LON --radius NM] [--query LAT,LON,NM] [--capacity 10240]
                [--fetched-ms MS] [--keep-input]
```

`--fetched-ms` is when the request went out (Service passes curl's start;
default: now; clamped to the last two minutes), the fetch time used for
`epochMs` and the observation offsets. The input is deleted afterwards only
when it sits directly inside `--out-dir` (where Service puts it), never with
`--keep-input`, so a saved fixture is never lost. Inputs over 16 MiB are
refused and records past the first 50,000 are dropped unread.

If the feed holds more than `capacity` aircraft, ground traffic goes first
(farthest from the query centre first), then airborne aircraft by the same
rule. In world mode Service sends the view centre in `--query` with the
10,800 NM radius (it covers the Earth from any centre), so what overflows is
far from what the user looks at. Python 3 standard library only (no numpy).
Must handle the adsb.lol / adsb.fi v2/v3 shape (`{"ac": [...], "now": ms}`),
5 MB inputs in well under 0.5 s, and never crash on garbage (exit 2 with
`ok: false`).

## Feed scheduling — `Service.qml`

Sources: **adsb.lol** primary (`https://api.adsb.lol/v2/point/{lat}/{lon}/{radiusNm}`,
accepts large radii in practice), **adsb.fi** fallback
(`https://opendata.adsb.fi/api/v3/lat/{lat}/lon/{lon}/dist/{nm}`, **never > 250**,
4xx count against its limit). `User-Agent: Flightline/<version> (+https://github.com/pedroolivy/omarchy-flightline)`.

| Mode | When | Query | Cadence |
|------|------|-------|---------|
| home | panel closed | home, `nearbyRadiusNm` | 60 s ± 10 % jitter |
| region | panel open, visible radius ≤ 1500 NM | view centre, `clamp(visible · 1.15, 50, 3000)` NM | 15 s ± 10 %, and on view settle if not covered |
| world | panel open, visible radius > 1500 NM | (0, 0, 10800) | 60 s ± 10 %; reuse while < 60 s old |

One request in flight at a time; ≥ 10 s between feed requests whatever
triggers them (adsb.lol 429s bursts; 10–15 s spacing was clean in testing);
≥ 3 s between requests to the same feed host, flight search included (it
also waits out adsb.fi's backoff); adsbdb lookups ≥ 1.1 s apart. On HTTP 429
or network error back off exponentially (5 s → 120 s, jitter) and after 3
consecutive lol failures use adsb.fi (centre only, radius ≤ 250) until lol
recovers. A failure of `flightline-feed` itself (crash, missing python3) is
reported as the helper's, backs off the same way, and is never counted
against the source. Settings: `feedSource` (`adsb.lol` | `adsb.fi`, the
preferred source; v0.1's `dataSource` key is ignored because v0.1 saved
`adsb.fi` on every entry) and `wideQueries` (`false` holds adsb.lol to
250 NM too). Polling does not pause while the screen is locked (no cheap
signal for third-party plugins); never poll world mode while the panel is
closed.

## Service API (what Panel/BarWidget/GlobeView may use)

Properties: `home {name, lat, lon, source, accuracyM}`, `hasHome`, `units`,
`nearbyRadiusNm`, `feedSource`, `wideQueries`, `panelOpen` (true while any
panel reported itself open through `setPanelOpen`), `status` (idle|loading|ok|error),
`errorText`, `activeSource`, `mode` (home|region|world), `trafficPath` (file
URL of traffic.ppm), `trafficRev` (int, bumps when a new PPM is in place),
`trafficCount`, `epochMs`, `maxGs`, `summary` (last summary object),
`nearbyCount` (-1 unknown), `nearbyMs` (when nearbyCount was last true; the
bar tooltip dates a count older than 5 min), `nearest` (array from summary.home.nearest),
`nearestAny` (summary.home.nearestAny of the last answer, `[]` unless its
home circle was empty),
`airborneCount`, `worldCount` (airborne total of the last world fetch, -1 if
none), `emergencies`, `lastUpdateMs`, `lastQuery {lat, lon, radiusNm}`,
`routes` (callsign → route|null), `placeSuggestions`, `searchingPlaces`,
`flightResults`, `flightStatus`, `flightQuery`, `locating`, `locateError`,
`timeZone`, `version`.

Functions: `setPanelOpen(panel, open)` (every Panel instance, also on
destruction, so one monitor's panel closing never hides another's),
`setView(lat, lon, visibleRadiusNm)` (panel calls on settle),
`refresh()`, `meta()` → parsed meta object for the current `trafficRev`
(cached; `null` if none), `aircraftAt(i)` → `{hex, cs, ty, rg, op, lat, lon,
alt, gs, trk, t, vr, sq, cat, flags}` from meta, `routeFor(callsign)`
(async, fills `routes`), `routePlausible(route, lat, lon)` (aircraft within
max(150 km, 15 % of route length) of the great circle), `searchPlaces(text)`,
`findFlight(text)`, `saveHome(name, lat, lon, source, accuracyM)`,
`clearHome()`, `locateWithWifi()`.

Routes come from adsbdb `GET /v0/callsign/{CS}` (origin/destination with
lat/lon). Cache in memory; negative-cache 404s; ≤ 1 lookup per 1.1 s; never
bundle or persist route data (licence).

## Terrain texture — `assets/terrain.png`

A data texture, not a picture: RGB PNG, 8 bit, **no alpha** (Qt premultiplies
alpha on upload, which would corrupt data channels). Equirectangular with
exactly earth.png's mapping, `u = (lon + 180) / 360`, `v = (90 − lat) / 180`,
texel centres at `(i + 0.5) / W`. Shipped at **3072 × 1536** (3.85 MB): 4096
does not fit the 4 MB file budget and 2048 turns the Alps to mush at 250 NM.
The width is not a power of two, so shaders read the size from
`terrainInfo` (never hard-code it), sample it without mipmaps and wrap `u`
by hand with `fract()`.

| Channel | Meaning | Decode (`t` = texture value 0..1) |
|---------|---------|-----------------------------------|
| R | hillshade, land only; 128 is flat and the whole sea is 128 | `relief = (t.r · 255 − 128) / 127`, −1 full shade … +1 facing the light |
| G | sea depth; 0 on land and at the shore | `depth_m = 8000 · t.g²` |
| B | land elevation; 0 at sea, at lakes and below sea level; ice sheets use their surface | `elev_m = 6000 · t.b²` |

The hillshade is cartographic: light from the north-west at 45° (weight 0.5),
west and north lights (0.15 each) and a sky term (0.2), computed at the DEM's
1-arc-minute resolution and box-averaged down, so it does not alias. B is a
texel mean over ~13 km, so peaks read lower than their summits (the Alps top
out near 3,000 m): snow rules use latitude as well as height. Land and sea
always come from earth.png's Natural Earth coast; terrain only shades, so it
can never draw a second coastline. Source: NOAA ETOPO1 (public domain), built
reproducibly by `tools/build-terrain.sh` (see NOTICE.md).

Past about 4 screen pixels a texel (region zoom, ~600 NM and closer) the data
has no more detail, only blur. There the shader steps the hillshade, the snow
and the sea-floor tones back, drops the land contours, and draws the
highland tint as antialiased layers at 500, 1,000, 2,000, 3,000 and 4,000 m,
like an atlas's hypsometric steps: clean shapes instead of smoke.

## Layers (GlobeView, back to front)

| # | Layer | Drawn by |
|---|-------|----------|
| 1 | space and faint stars (dark themes, outside the disc) | `Globe` |
| 2–6 | sea-floor depth, land relief and snow, coast and borders, night side and city lights, atmosphere | `Globe` |
| 7 | home ring and the live-data boundary | `Globe` |
| 8a | altitude shadows (region zoom) | `Aircraft` child, z −2 (aircraft shaders, `drawLayer` 2) |
| 8b | trails | `Trails`, an `Aircraft` child at z −1 |
| 9 | aircraft, then the selected and hovered ones on top | `Aircraft` (`drawLayer` 0, then a 2-slot child with `drawLayer` 1) |
| 10 | route of the selected flight | `RouteArc` |
| 11 | labels (places, flights) and the hover card | pooled `Text` in `GlobeView` |

Every layer is one ShaderEffect with a constant mesh: moving the camera writes
uniforms only. The shadow and trail layers share Aircraft's double-buffered
texture swap, so they never show another revision than the sprites. Globe's
built-in route arc (`routeVisible`, the `routeFrom*`/`routeTo*`/`routeAt*`
uniforms) still works but GlobeView keeps it off: RouteArc replaces it.

## GlobePalette.qml — colours

Every colour of the globe and the sky is a mix of the five theme colours
(`foreground`, `background`, `accent`, `muted`, `urgent`); there are no
hard-coded hues. `light` (background luminance > 0.5) switches the few rules
that differ: light themes mix towards the background (their paper) where
dark ones mix towards the foreground, and night only dims them (`night`
0.55). Alpha is a colour's strength in the shader where noted.

- Earth: `space`, `ocean`, `land`, `coast`, `border`, `grid`, `glow`,
  `lights`, `home`, `route`, `routeRest`, `live`, `night`.
- Relief and sea (v2.1): `shelf` (shallow sea), `deep` (the abyss),
  `highland` (hypsometric tint), `snow` (alpha = strength), `shade` and
  `sheen` (the hillshade's dark and lit sides), `twilight` (dusk hue
  `mix(accent, urgent, 0.5)`; alpha = how far the hue turns, it never adds
  light), `isobath`, `glint`, `star`.
- Aircraft: `ground`, `low`, `mid`, `high` (muted → accent → foreground),
  `selected`, `emergency`, `halo`, `shadow` (background × 0.3).
- Labels: `label`, `labelDim`, `labelHalo`, `city`, `tooltip`,
  `tooltipText`, `tooltipBorder`.
- Look up sky: `skyNight`, `skyNightHorizon`, `skyDay`, `skyDayHorizon`,
  `skyTwilight`, `body`.

GlobeView exposes each as an overridable `…Color` property bound to the
palette (`shelfColor: tints.shelf`, …); Panel binds the sky colours into
LookUp.

## Globe.qml (ShaderEffect) — properties

`centerLat`, `centerLon` (deg), `radius` (px), `time` (s, for subtle effects
only; nothing animates by itself), `sunVector` (vector3d, ECEF unit, from
`sunFor(date)`), `nightStrength` (0..1), colours (`color`): `spaceColor`,
`oceanColor`, `landColor`, `coastColor`, `borderColor`, `gridColor`,
`glowColor`, `lightsColor`, `homeColor`, `routeColor`, `routeRestColor`,
`liveColor`, and since v2.1 `shelfColor`, `deepColor`, `highlandColor`,
`snowColor`, `shadeColor`, `sheenColor`, `twilightColor`, `isobathColor`,
`glintColor`, `starColor` (defaults derive from the v2.0 colours, so a view
that only sets those still gets a matching globe); toggles: `showGraticule`,
`showBorders`, `showNight`, `showLights`, `showRelief` (all terrain use:
relief, snow, sea-floor depth, isobaths), `showIsobaths`, `showStars` (the
shader also requires a dark ocean); `reliefStrength` (hillshade gain, 1);
overlays (all drawn analytically in the fragment shader, zero CPU):
`homeLat`, `homeLon`, `homeRingNm` (≤ 0 = no home), `liveLat`, `liveLon`,
`liveRadiusNm` (≤ 0 = hidden; the live-data boundary), `routeFromLat/Lon`,
`routeToLat/Lon`, `routeAtLat/Lon` and `routeVisible` (the legacy route).
Read-only: `ready`, `hasTerrain`, `terrainSize`, `terrainInfo`
(width, height, on, strength).

Samplers: earth (binding 1), lights (2), terrain (3). The textures load the
first time `active` is true, in one Loader; `ready` waits for earth and
lights and for terrain to stop loading. A missing or broken terrain.png only
turns the relief off (`hasTerrain` false: v2.0's flat globe and coarse coast
proxy). With `keepTextures` (default true) they then stay for the item's
life; `keepTextures: false` releases them whenever `active` turns false.
Measured on Mesa/radeonsi: releasing frees the RAM copy, but the driver keeps
the freed video memory and allocates a second set on the next load, so after
two opens release-on-close held more than keeping one set. GlobeView passes
`nightStrength` from GlobePalette (`night`: 1 dark themes, 0.55 light ones).

Shader rules: pixels more than 3 px outside the limb skip all sphere work
(only the halo and stars are drawn there); every line is a distance in
pixels, one pixel sharp at any zoom and faded where it would alias; relief
fades where a terrain texel is smaller than a pixel and towards the poles,
so nothing shimmers while the globe turns.

## Aircraft.qml (ShaderEffect) — properties

`centerLat`, `centerLon` (deg), `radius` (px), `source` (url of traffic.ppm),
`revision` (int; bump to reload, 0 = no file yet), `count`, `epochMs`,
`time` (s since `epochMs`, set by the view), `maxAge` (90), `spritePx`
(half-size in px), `selectedIndex`, `hoveredIndex` (-1 none), colours:
`groundColor`, `lowColor`, `midColor`, `highColor` (altitude ramp: muted →
accent → foreground), `selectedColor`, `emergencyColor`, `haloColor`,
`shadowColor`. v2.1 layers: `showTrails`, `showShadows`, `trailPx`
(4 × spritePx: tail of a 450 kt jet), `trailSeconds` (flight time that
covers, from the zoom, 1..900 s), `trailWidth`, `trailStrength` (fainter at
world zoom, where thousands overlap), `shadowStrength` (fades in with the
glyphs, 4 → 5.5 px), `shadowPx` (offset at FL400; 15 % of it on the ground),
`glow` and `glowAdditive` (light around the world-zoom dots: added on dark
themes, a tint on light ones; `lightBackdrop` from the halo's luminance).
Constant capacity 10,240 (GridMesh `(3·cap − 1) × 1`).

Uniform `drawLayer`: 0 sprites, 1 selected/hovered (two slots, larger,
ringed), 2 shadows (a blurred silhouette offset towards the south-east, the
hillshade's light). Glyph classes: 0 twin jet, 1 four-engine heavy (means
"large", not an engine count), 2 turboprop/GA, 3 rotorcraft, 4 glider (all
of ADS-B category B), 5 ground vehicle. Dead reckoning in every shader is
`p0·cos d + t0·sin d` on the unit sphere, the same great circle as
`Model.reckon`, and the heading is that circle's tangent.

`Trails.qml` (child of Aircraft, which drives it): `centerLat`, `centerLon`,
`radius`, `dataTex`, `texTime`, `texCount`, `maxAge`, `selectedSlot`,
`trailSeconds`, `trailWidth`, `headPx` (where the sprite ends), `strength`,
`lowColor`, `midColor`, `highColor`, `selectedColor`, `emergencyColor`. Each
airborne aircraft gets a tapered tail run backwards along its great circle,
alpha 0 at the end; none on the ground, below 1 kt or without a track; a
stale aircraft's tail fades with its sprite.

## RouteArc.qml (ShaderEffect) — properties

`centerLat`, `centerLon`, `radius`, `fromLat/Lon` (origin airport),
`atLat/Lon` (the aircraft, GlobeView's `selectedPos`), `toLat/Lon`, `shown`,
`gapPx` (the line stops short of the selected ring), `dotPx`, `flownColor`,
`restColor`, `haloColor`; `steps` 160 per leg. Two great-circle legs that
meet at the aircraft (real tracks drift from the textbook arc, so one arc
misses the sprite at deep zoom): the flown leg solid over a dark halo with a
glow growing towards the aircraft, the rest as ground-fixed dots, a dot at
the origin and a ring at the destination. One constant GridMesh
`(2·steps + 6) × 1`; the airport codes are labels placed by GlobeView.

## LookUp.qml — sky bodies

`SkyModel.skyBodies(ms, lat, lon, altM)` (Meeus' low-precision formulas, no
data files) gives the Sun, the Moon (phase, bright limb) and Mercury to
Saturn in topocentric azimuth and apparent altitude, with visibility rules
(above the horizon; planets only once the Sun is low enough for their
magnitude and clear of it). LookUp computes them only in `rebuild()` (the
existing 10 s tick, a new revision, home, visibility) and paints a sky whose
light follows the Sun's altitude (day, civil, nautical and astronomical
twilight, night). Properties: `showBodies`, `bodies` (read-only result),
`skyNight`, `skyNightHorizon`, `skyDay`, `skyDayHorizon`, `skyTwilight`,
`bodyColor` (Panel binds GlobePalette's).

## Frame pacing (GlobeView)

- `FrameAnimation` runs **only** while dragging, during inertia, zoom easing
  or a fly-to. It updates camera and `time`.
- Otherwise `time` advances from a `Timer` whose interval is the time the
  fastest aircraft (`maxGs`) needs to move 0.5 px at the current radius,
  clamped to [1 s, 30 s] (at 60 NM a 1 s step is ~1.3 px for the fastest jet).
  No other timer may cause a frame; trails, shadows and the route move only
  with that clock or the camera.
- A drag whose release never arrives (grab cancelled, panel closed mid-drag)
  ends the gesture, so the FrameAnimation always stops.
- Labels (12 aircraft, 24 cities + home + 2 airports, pooled `Text`) are
  placed by `Model.placeGlobeLabels` on settle and on new data, in the
  priority selected, emergencies, hovered, near the cursor or centre, home,
  cities by rank, other aircraft; they never overlap one another and fade at
  the limb. The clock tick only carries them along with their aircraft and
  re-places them on a collision; while following an aircraft, each tick lays
  them out again (the view itself moves). Hidden while the camera moves.
- Idle warm-up: 300 ms after a new revision or a settle, with no input,
  GlobeView parses meta and projects the aircraft (no frame), so the first
  hover or click costs ≤ 2 ms. Picking may reuse a projection a few ticks
  old within a drift tolerance and re-checks only nearby candidates; hover
  is throttled to ≤ 30 Hz.
- Sprite size follows the zoom (`Model.spritePxFor`): 2.6 px dots for the
  whole globe, 8 px at 60 NM, 11.5 px from 12 NM in.

## Budgets to verify

Measured offscreen on the real GPU (Ryzen 7 8700G, Radeon 780M shared with the
desktop, Mesa radeonsi, OpenGL RHI) against v2.0.1 in interleaved runs, with
the world answer of 9,316 aircraft (GPU times: see the note under the table).

| Situation | Budget | v2.1 measured (v2.0) |
|-----------|--------|----------------------|
| Panel closed | 0 frames; ≤ 1 request/min | no new timer; the closed panel draws nothing (same frame count as v2.0 in the stub-shell harness) |
| Open, world view, mouse still | ≤ 1 frame / 10 s | 0 frames in 10 s, clock 30 s (0) |
| Open, region view, mouse still | ≤ 1 frame / s plus feed updates | 2 frames in 6 s at 400 NM, clock 3.1 s (2) |
| GPU per frame, 3440 × 1440, globe at GlobeView's fit radius | ≤ 1.35 × v2.0 | 2.26 ms vs 4.68 ms (0.48 ×) |
| GPU per frame, 3440 × 1440, region view at 250 NM, every aircraft with shadows and trails | ≤ 1.35 × v2.0 | 5.34 ms vs 4.36 ms (1.22 ×) |
| The same at 60 NM | ≤ 1.35 × v2.0 | 5.37 ms vs 4.28 ms (1.25 ×) |
| GPU per frame, 3440 × 1440, the globe covering the window | ≤ 1.35 × v2.0 | 6.03 ms vs 4.78 ms (1.26 ×) |
| CPU per frame while dragging | GUI thread ≤ 0.5 ms, process ≤ 1 ms | 0.09 ms / 0.19 ms (0.09 / 0.18) |
| First hover after a revision | ≤ 2 ms on the GUI thread | 1.3 ms world, 1.0 ms at 400 NM (22.5 / 2.0 offscreen; ~31 ms live) |
| Feed update, summary path | < 2 ms on the GUI thread | unchanged |
| Feed update, meta | ≤ 1 meta.json parse per revision: on demand, or warmed at idle while the panel is open (~20 ms world, a few ms region) | once per revision |
| Texture VRAM | ≤ 80 MiB | 62 MiB (≈ 46) |
| Shipped size (no tests, docs, tools) | ≤ 8 MB | 7.19 MB = 6.86 MiB (3.05 MiB) |

GPU times come from GL timer queries per layer, with Qt's own GLSL 150 shaders,
v2.0 and v2.1 drawn alternately in every frame and both orders averaged, so
both see the same GPU clock. The process counters (drm-engine-gfx, `gpu_busy_percent`) were
too noisy to certify a ratio. Where the time goes at 250 NM: the globe +0.78 ms
(relief, sea floor, sunlight, atmosphere), trails 0.14 ms, shadows 0.10 ms;
the sprites cost less than v2.0's. Benches:
`tests/offscreen/bench.sh` (`W`, `H`, `RADIUS`, `LAYERS`, `SPRITE`) and
`globeview.sh drag | idle | hover`; texture VRAM: `globe-idle.sh`.
