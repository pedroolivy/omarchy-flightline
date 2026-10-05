# Flightline

The whole world's air traffic on a GPU globe, right in the Omarchy bar.

A small plane in the bar counts the aircraft flying near you. Click it and a
globe opens in your theme's colours with every aircraft the community
receivers hear, around 9,000 at once: they glide across the continents,
cities glow on the night side, and the traffic alone traces the busy parts of
the world. Zoom in and the globe turns into a quiet chart: shaded mountains,
the depth of the sea floor, sunlight across the day side, and every aircraft
drawn by type with a short trail and a shadow that grows with its altitude.
Click any plane to see what it is, where it is going and when it lands, or
type a flight number to find it anywhere and follow it. The **Look up** lens
turns the panel into a sky dome of what is above you right now, the Sun, the
Moon and the planets included.

## Features

- **Bar pill** with the number of aircraft in the air within your overhead
  radius. The tooltip names the closest one (with its route when known) and
  how many are airborne worldwide. An emergency squawk inside your radius
  takes over the pill (`󰀝 7700`).
- **The whole world on the globe.** Zoomed out, the panel loads every
  aircraft on Earth in one request and draws them as a field of softly
  glowing lights, so the busy corridors read as light. Zoomed in, they
  become silhouettes by type (twin jet, heavy, turboprop, helicopter, glider,
  ground vehicle) with a fading trail along their heading and a shadow offset
  by their altitude, coloured from your theme's muted colour on the ground
  through its accent to its foreground at cruise.
- **A real globe, on the GPU.** Shaded relief with snow and ice, sea-floor
  depth with faint depth contours, coastlines, country and state borders, an
  adaptive latitude/longitude grid, the live sun with a twilight band and
  NASA city lights on the night side, an atmosphere at the limb and faint
  stars around it, all drawn in one shader pass and all in your theme's
  colours (dark, light or warm). Drag to spin (with inertia), scroll to zoom
  towards the cursor, double-click to zoom in.
- **Smooth traffic.** Positions are dead-reckoned on the GPU between feed
  updates, so aircraft glide instead of jumping, and old reports fade out
  instead of standing still.
- **Aircraft card.** Callsign, airline, type, registration, the route
  (origin → destination with cities), a progress bar along it with an
  estimated landing time, distance and direction from you, altitude, vertical
  rate, speed, heading and squawk. The route arc is drawn on the globe: the
  part flown solid, the rest dashed. Emergency squawks (7500/7600/7700) are
  flagged. Anything estimated says `est.`
- **The route on the globe.** The selected flight's route runs through the
  aircraft at every zoom: the part flown solid with a soft glow, the rest
  dotted, and the airports marked with their codes.
- **Labels that never collide.** Callsigns, cities and your location are
  placed together so they never overlap one another or fall off the edge of
  the globe; the selected flight, emergencies and what is under the cursor
  come first.
- **Look up.** A sky dome over your location: aircraft by azimuth and
  elevation, their paths across your sky for the next ten minutes, the next
  passes and what lies just beyond the horizon. The Sun, the Moon with its
  real phase, and Mercury to Saturn appear where they are, and the dome's
  light follows the Sun from day through twilight to night.
- **Never empty.** In sparse regions the panel opens on a wider view around
  you, the list shows the closest aircraft the feed knows, wherever they are,
  and `W` shows the world's traffic.
- **Find any flight.** Search by callsign (`TAM3054`), ticket flight number
  (`LA 3054`, `BA 117`), registration (`PR-XMA`, `N12345`) or ICAO hex.
  Flightline finds the aircraft anywhere in the world, flies to it and
  follows it.
- **Uses your Omarchy weather location** automatically. No setup if you have
  already picked a city in the weather panel.
- **Light on resources.** See [Performance](#performance).

## Install

```bash
omarchy plugin add https://github.com/pedroolivy/omarchy-flightline.git --enable
```

The pill appears on the right side of the bar. Move it with
`omarchy bar move io.github.pedroolivy.flightline --section left|center|right`.

To open the globe from a key, add a binding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + F", "Flightline", "omarchy-shell shell toggle io.github.pedroolivy.flightline")
```

## Remove

```bash
omarchy plugin remove io.github.pedroolivy.flightline
```

This deletes the plugin directory and its bar entry (including any location
you saved in Flightline). The only other files are the live traffic files in
`$XDG_RUNTIME_DIR/flightline/` and, if you ever took one, the snapshot
`$XDG_RUNTIME_DIR/flightline-snapshot.png`. Both live in memory and are gone
at logout.

## Using it

| Input | Action |
|-------|--------|
| Drag / arrows / `h` `j` `k` `l` | Spin the globe |
| Scroll / `+` `-` | Zoom towards the cursor |
| Double-click | Zoom in |
| Click a plane or a row | Show its details and route |
| `1` / `2` | Globe / Look up |
| `/` or `S` | Find a city or a flight |
| `F`, `Space` or `Enter` | Follow the selected aircraft |
| `N` / `Shift+N` | Next / previous aircraft in the list |
| `E` | Next emergency |
| `C` | Back to your location |
| `W` | The whole world |
| `R` | Refresh now |
| `Esc` | Stop following → deselect → close |
| Left / middle / right click on the pill | Globe / Look up / refresh |

### Location

Flightline needs a centre for the bar count. It uses the first of these that
is available:

1. **A location you set in Flightline**: click the location name in the panel
   and search a city, pin the current view, or try Wi-Fi.
2. **Your Omarchy weather location** (`~/.local/state/omarchy/settings/weather.json`),
   read-only. Change it in the weather panel and Flightline follows.
3. **An estimate from your IP address**, using the same service as Omarchy's
   weather panel (`wttr.in`).

**Wi-Fi location (experimental)** works like a browser's: it reads the access
points NetworkManager already sees (no scan, no root), skips networks that
opted out (`_nomap` / `_optout`), and asks [BeaconDB](https://beacondb.net)
where they are. BeaconDB is young and crowd-sourced, so in many regions it
only knows a rough area. The panel shows the accuracy it reports. It only
runs when you press the button.

### Settings

Settings live on the widget's entry in `~/.config/omarchy/shell.json`:

```bash
omarchy bar set io.github.pedroolivy.flightline nearbyRadiusNm 60
omarchy bar set io.github.pedroolivy.flightline units aviation
```

| Key | Default | Meaning |
|-----|---------|---------|
| `nearbyRadiusNm` | `100` | Overhead radius for the bar count, in nautical miles (5–250) |
| `units` | `auto` | `metric`, `imperial`, `aviation` (ft, kt, nm) or `auto`. Auto follows your system time zone, so an `en_US` system in Germany still gets kilometres |
| `feedSource` | `adsb.lol` | Preferred feed: `adsb.lol` or `adsb.fi`. The other one takes over automatically when it fails. adsb.fi only answers circles up to 250 nm, so the world view needs adsb.lol. (v0.1's `dataSource` key is no longer read) |
| `wideQueries` | `true` | Let the open panel ask adsb.lol for circles wider than 250 nm (see [Coverage](#coverage)). `false` keeps every request within 250 nm |
| `showLabels` | `true` | Callsign and city labels |
| `showGraticule` | `true` | Latitude/longitude grid |
| `showNight` | `true` | Night side shading |
| `showLights` | `true` | City lights on the night side |
| `showRelief` | `true` | Shaded relief, snow and ice, sea-floor depth. `false` draws the flat v2.0 globe |
| `showTrails` | `true` | A short fading trail behind every aircraft in the air |
| `showStars` | `true` | Faint, still stars around the globe (dark themes only) |

### Scripting

```bash
omarchy-shell flightline status            # JSON, never includes coordinates
omarchy-shell flightline track TAM3054     # find, show and follow a flight
omarchy-shell flightline find "LA 3054"    # open the search, filled in
omarchy-shell flightline view 51.47,-0.45,60   # look somewhere (lat,lon,radius nm)
omarchy-shell flightline lens lookup       # open in a lens: globe | lookup
omarchy-shell flightline snapshot          # PNG of the open panel; prints its path
omarchy-shell flightline home | world | zoomIn | zoomOut | refresh | search
omarchy-shell flightline toggle | open | close
```

## Coverage

Aircraft positions come from **community ADS-B networks**: volunteers with
receivers at home. Coverage is dense across Europe and North America, but can
be thin elsewhere: some regions see only a handful of aircraft even when the
sky is busy. Commercial trackers fill those gaps with their own receivers and
satellites. If you live in a quiet area, consider feeding
[adsb.lol](https://adsb.lol) or [adsb.fi](https://adsb.fi) with a cheap
receiver: everyone's map gets better.

What the panel asks for depends on what you look at:

| Panel | Request | How often |
|-------|---------|-----------|
| closed | your overhead circle | once a minute |
| open, region (up to 1,500 nm across) | the visible circle, up to 3,000 nm | every 15 s, and when you move outside it (at most every 10 s) |
| open, whole globe | the whole world, one request | once a minute |

**Wide queries.** adsb.lol documents a 250 nm limit for its point query, but
answers larger circles in practice, up to the whole world. Flightline uses
that for the region and world views, with at least 10 s between requests and
backoff when the server says it is busy. If you prefer to stay within the
documented limit, set `wideQueries` to `false`: every request then stays
within 250 nm of the view (or of you) and the world view shows that circle
only. In region views a faint ring on the globe marks the area the last answer
covered.

## Privacy

Flightline sends:

- the centre and radius of what you look at to the ADS-B feed (`adsb.lol`,
  or `adsb.fi` as fallback); with the panel closed, only your overhead circle
  (your location, rounded to about 10 m, and `nearbyRadiusNm`); in the world
  view, no location at all (`0,0` and the whole Earth), unless adsb.fi is
  standing in, which only takes a 250 nm circle around the view or you;
- a callsign to [adsbdb](https://www.adsbdb.com) for routes: the aircraft
  you select, and the closest three in the panel's list while it is open;
- what you type in search to the [Open-Meteo](https://open-meteo.com) geocoder
  (cities) and to `adsb.fi` / `adsbdb` (flights; adsb.fi at most every 3 s);
- a request to `wttr.in` for an IP-based estimate, only when no location is set;
- nearby Wi-Fi access point addresses to BeaconDB, only when you press **Wi-Fi**.

Every request identifies itself as `Flightline/<version>`. Feed answers are
turned into two files on tmpfs (`$XDG_RUNTIME_DIR/flightline/`, mode 0700) and
nothing else is written outside your `shell.json` entry. Routes are kept in
memory only. The `status` command never prints coordinates.

## Performance

v2.1 adds relief, sea depth, sunlight, trails and shadows at the same cost
where it matters: nothing is drawn unless something moved. Numbers measured
offscreen on a Ryzen 7 8700G with its integrated Radeon 780M (Mesa), with
the whole world's 9,316 aircraft, against v2.0 in alternating runs:

- **Panel closed:** no frames, one small request a minute. The feed answer
  is converted by `flightline-feed` in its own process, so the shell never
  parses it.
- **Panel open and still:** the globe draws a frame only when the fastest
  aircraft has moved half a pixel, and never more than once a second: no
  frame in 10 s on the whole globe, one every ~3 s at 400 nm, once a second
  at 60 nm. Trails, shadows and the route move with that same clock.
- **Dragging:** every frame at the display's refresh rate, 0.09 ms of GUI
  thread and 0.19 ms of the whole process per frame (v2.0: 0.09 / 0.18).
  GPU at 3440 × 1440: 2.4 ms a frame with the globe at its usual size, the
  same as v2.0; about 1.35–1.4 × v2.0 when the globe covers a whole
  ultrawide window, the price of the relief and the sunlight.
- **Data updates:** reading the summary costs well under a millisecond. The
  per-aircraft file (`meta.json`) is parsed once per update, while the panel
  is open and idle (about 20 ms for the whole world, a few ms for a region),
  so the first hover or click afterwards takes about 1 ms instead of ~30.
- **Memory:** the globe textures (map, city lights and terrain) load the
  first time the panel opens and then stay for the session: 62 MiB of video
  memory (v2.0: 46 MiB) and about 67 MiB of RAM (v2.0: 55 MiB). Releasing them on close freed the RAM, but Mesa
  kept the video memory and allocated a second set on the next open, so
  keeping one set is the smaller footprint.
- **Size:** 6.9 MiB installed, most of it the three textures.

## Dependencies

All ship with Omarchy: `curl`, `jq` (Wi-Fi lookup), `python3` (standard library only),
`timedatectl` (systemd) and, for the optional Wi-Fi lookup, `nmcli`
(NetworkManager). The GPU shaders come prebuilt (`shaders/*.qsb`), so nothing
is compiled on your machine. No installer, no `sudo`.

## Development

```text
manifest.json        plugin manifest (service + bar widget)
Service.qml          one shared service: location, feed scheduling, search, routes
flightline-feed      python3 helper: feed answer → traffic.ppm + meta.json + summary
flightline-locate    Wi-Fi → BeaconDB helper
BarWidget.qml        the pill; mounts Panel.qml like Omarchy's own weather pill
Panel.qml            the popout: header, lenses, sidebar, keys, IPC
GlobeView.qml        camera, input, labels and picking around the GPU layers
GlobePalette.qml     every globe colour, derived from the theme
Globe.qml            the Earth: one ShaderEffect (shaders/globe.*)
Aircraft.qml         every aircraft, its shadows and the selected one: shaders/aircraft.*
Trails.qml           the aircraft's comet tails (shaders/trails.*)
RouteArc.qml         the selected flight's route (shaders/route.*)
LookUp.qml, SkyModel.js   the Look up sky dome, the Sun, the Moon and the planets
Model.js             pure logic: geodesy, camera, label placement, feed planning, parsing, formatting
assets/              earth.png, lights.png, terrain.png, places.json (see NOTICE.md)
shaders/             GLSL sources and the baked .qsb files
tools/               build-shaders.sh, build-textures.sh (+ geo2bin.py, sdfbake.c, build-terrain.sh,
                     terrainbake.c), build-geo.py
docs/ARCHITECTURE.md how the parts fit, formats, layers and budgets
docs/VISUAL.md       the art direction
tests/               model.test.mjs, sky.test.mjs, feed/, offscreen/
```

Tests:

```bash
node tests/model.test.mjs && node tests/sky.test.mjs
FLIGHTLINE_FIXTURES=dir python3 tests/feed/test_feed.py   # dir: saved adsb.lol answers (lol_*.json, world.json); without it the 4 tests on real data are skipped
WORLD_JSON=world.json tests/offscreen/run.sh   # shader renders, offscreen on the GPU
WORLD_JSON=world.json tests/offscreen/globeview.sh
WORLD_JSON=world.json tests/offscreen/globeview.sh labels | route | interact | idle | hover | drag
WORLD_JSON=world.json tests/offscreen/aircraft.sh
WORLD_JSON=world.json tests/offscreen/lookup.sh
WORLD_JSON=world.json W=3440 H=1440 RADIUS=fit tests/offscreen/bench.sh
```

The offscreen tests never open a window and never touch the network; the
world and region tests need a saved feed answer (`curl` one from adsb.lol
yourself; none is committed). `flightline-feed` only ever deletes an input
file that sits inside its `--out-dir`, so a saved answer is safe to pass.

Rebuilding the generated files (both are committed, users never run these):

```bash
tools/build-shaders.sh     # shaders/*.qsb, needs qsb from qt6-shadertools
tools/build-textures.sh    # assets/, downloads Natural Earth, NASA and NOAA sources once (~350 MB)
```

Saving a QML file under `~/.config/omarchy/plugins/` hot-reloads the widget
and panel. Changes to `Service.qml` or to IPC handlers need
`omarchy restart shell`.

## Credits

- Aircraft data: [adsb.lol](https://adsb.lol), under the
  [ODbL](https://opendatacommons.org/licenses/odbl/1-0/), and
  [adsb.fi](https://adsb.fi) open data (personal, non-commercial use).
- Routes and airlines: [adsbdb](https://www.adsbdb.com). The flight route
  data is the work of David Taylor, Edinburgh and Jim Mason, Glasgow.
- City search: [Open-Meteo](https://open-meteo.com) geocoding
  ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)), location data
  based on GeoNames.
- Map: [Natural Earth](https://www.naturalearthdata.com) (public domain).
- Relief and sea depth: NOAA [ETOPO1](https://www.ncei.noaa.gov/products/etopo-global-relief-model)
  1 Arc-Minute Global Relief Model (public domain; Amante and Eakins, 2009).
- Sun, Moon and planets: formulas from Jean Meeus, *Astronomical Algorithms*,
  and NASA JPL's approximate planetary elements (E. M. Standish).
- Night lights: [NASA Black Marble](https://earthobservatory.nasa.gov/features/NightLights)
  (NASA Earth Observatory, Suomi NPP VIIRS).
- Wi-Fi location: [BeaconDB](https://beacondb.net).
- IP location: [wttr.in](https://wttr.in), as used by Omarchy's weather panel.
- Inspired by community plugins such as
  [Radio Atlas](https://github.com/AksharP5/omarchy-radio-atlas) and
  [Skywatch](https://github.com/amir-the-h/skywatch-omarchy). No code is shared.

See [NOTICE.md](NOTICE.md) for the full terms.

## License

[MIT](LICENSE)
