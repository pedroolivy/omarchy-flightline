# Flightline — visual direction

How Flightline should look, and why. `docs/ARCHITECTURE.md` is the binding
contract (formats, properties, layers, budgets); this file is the art
direction behind it. v2.1 was a visual leap with v2.0's feel: the same
near-zero cost when nothing moves (see Budgets in ARCHITECTURE.md), a richer
picture when something does.

## Art direction: Omarchy-native, cartographer-grade

- **Theme first.** Every colour comes from the five theme colours (`foreground`, `background`,
  `accent`, `muted`, `urgent`) through `GlobePalette.qml`. There are no hard-coded hues. It must look
  deliberate on dark themes (Tokyo Night-like: bg #1a1b26, fg #c0caf5, accent #7aa2f7, muted #565f89,
  urgent #f7768e), light themes (Catppuccin Latte-like: bg #eff1f5, fg #4c4f69, accent #1e66f5,
  muted #8c8fa1, urgent #d20f39) and warm themes (Gruvbox-like: bg #282828, fg #ebdbb2,
  accent #d79921, muted #928374, urgent #fb4934). On a dark theme the relief reads as a lit
  model, on a light one as Swiss-style shading on paper, on a warm one as an old topographic map.
- **Quiet, precise, flat.** Depth comes from light, not decoration: relief, sea-floor depth, sunlight
  and atmosphere. No gloss, lens flares, gradients for their own sake or neon.
- **Nothing moves by itself.** Motion happens only when the user acts or new data arrives. There are
  no pulses, twinkles or idle spinning, and no idle frames beyond what v2.0 already spent.
- **Layers of meaning, back to front:**
  1. space and faint stars
  2. sea-floor depth
  3. land relief
  4. coast and borders
  5. night side and city lights
  6. atmosphere
  7. home and live-data overlays
  8. trails
  9. aircraft
  10. route
  11. labels
- **Three moods by zoom.**
  - *Globe:* a living night map of air traffic. Glowing corridors over the North Atlantic, Europe and
    the US, a lit sphere and a crisp limb.
  - *Region (~50–1500 NM):* a precise chart. Relief, depth tones, crisp glyphs with altitude shadows
    and short trails.
  - *Deep zoom:* an approach chart. Clean, readable and calm; glyphs grow to ~11 px so the type of
    each aircraft reads at a glance.
- **Typography** stays the shell's monospace font. Labels never overlap one another, cities or the
  limb.

## Where each part lives

| Part | Files |
|------|-------|
| Terrain data | `assets/terrain.png`, `tools/build-terrain.sh`, `tools/terrainbake.c` |
| The Earth | `Globe.qml`, `shaders/globe.*` |
| Aircraft, shadows, trails | `Aircraft.qml`, `Trails.qml`, `shaders/aircraft.*`, `shaders/trails.*` |
| Labels, route, picking | `GlobeView.qml`, `Model.js`, `RouteArc.qml`, `shaders/route.*` |
| Look up | `LookUp.qml`, `SkyModel.js` |
| Colours | `GlobePalette.qml` (every rule below that names a colour) |

## Terrain

- A data texture from NOAA ETOPO1: hillshade in R, sea depth in G, land elevation in B (format in
  ARCHITECTURE.md). The hillshade is cartographic, lit mainly from the north-west at 45° with softer
  west and north lights and a sky term, computed at the DEM's resolution and averaged down so it never
  aliases.
- Natural Earth's coast (earth.png) decides land and sea. Terrain only shades, so it never draws a
  second, shifted coastline.

## Globe

- **Land:** the hillshade, softly saturated on both sides; a hypsometric tint in which lowlands keep
  the theme's land colour and highlands lean towards the foreground; snow on the highest ground (the
  Himalaya and the high Andes, a trace on the Alps) and quieter ice on Greenland and Antarctica.
  Relief follows zoom: calm at globe zoom, alive at region zoom, calmer again on an approach chart.
- **Ocean:** shelves lighter with a hint of the coast colour, the abyss darker; hairline isobaths at
  200 / 1,000 / 4,000 m at region zoom, very faint. Next to the coast the depth itself draws a soft
  shelf halo, never a second line.
- **Sun:** the day side rises gently towards the subsolar point; dusk is a narrow band where the hue
  turns towards `mix(accent, urgent)` at the pixel's own brightness, so the terminator never gets a
  bright seam; a faint glint where the sun reflects off the sea; the night side and its city lights
  as readable as v2.0 (`night` 0.55 on light themes).
- **Atmosphere:** limb scattering brighter on the sunlit side, a crisp 1-px rim and a two-scale halo.
- **Stars:** dark themes only, outside the disc; sparse, static, screen-anchored and faint, gone
  once the globe fills the view.
- Lines stay 1 px sharp, and nothing shimmers while dragging.

## Aircraft

- **World zoom:** a field of dots, each with a small soft glow (added light on dark themes, a tint on
  light ones), so the corridors read as light; tails are short and faint here, flow rather than a
  white-out.
- **Trails:** comet tails on airborne aircraft, run backwards along the great circle the sprite flies
  on, tapered to nothing, in the aircraft's colour but dimmer; about 10–40 px on screen, longer for
  faster aircraft. None for ground traffic or stale aircraft.
- **Altitude shadows:** at region zoom a soft copy of each airborne silhouette falls towards the
  south-east (the hillshade's light), further and softer the higher the aircraft.
- **Glyphs:** twin jets, four-engine heavies, turboprops/GA, rotorcraft and gliders read clearly at a
  7–14 px half-size; ground vehicles stay small dots.

## Labels and route

- Aircraft, city, home and airport labels are placed together and never overlap; they stay inside the
  disc and fade near the limb. Priority: selected, emergencies, hovered, aircraft near the cursor or
  centre, home, capitals and cities by rank, other aircraft.
- The first hover or click after new data costs ≤ 2 ms: meta and positions are warmed while idle.
- The selected flight's route is two great-circle legs that meet at the aircraft, so the sprite sits
  on the line at every zoom: the flown part solid with a glow growing towards the aircraft, the rest
  dotted, a dot at the origin and a ring at the destination, the IATA codes as labels.

## Look up

- The Sun, the Moon with its real phase and the lit limb facing the Sun, and Mercury to Saturn when
  they are above the horizon and clear of twilight; positions from Meeus' low-precision formulas.
- The dome's light follows the Sun: day, civil, nautical and astronomical twilight, night, with a
  glow over the set Sun. Theme colours only; the aircraft stay the protagonists.
