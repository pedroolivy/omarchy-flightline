import QtQuick

// Every colour of the globe lens, derived from the five theme colours
// Omarchy exposes (qs.Commons Color: foreground, background, accent, muted,
// urgent). Semantic hue names cannot be trusted across themes, so only
// these are used: the sea and the land are mixes of background and
// foreground, highlights come from accent, alerts from urgent. Light themes
// work the same way, the mixes simply darken instead of lighten.
//
// QtQuick only, so tests derive the same colours offscreen.
QtObject {
  id: root

  property color foreground: "#c0caf5"
  property color background: "#1a1b26"
  property color accent: "#7aa2f7"
  property color muted: "#565f89"
  property color urgent: "#f7768e"

  readonly property bool light: luminance(background) > 0.5

  function luminance(c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
  function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function scale(c, k) { return Qt.rgba(c.r * k, c.g * k, c.b * k, 1) }

  // ------------------------------------------------------------- earth
  readonly property color space: "transparent"       // the panel shows through
  readonly property color ocean: mix(background, accent, light ? 0.10 : 0.07)
  readonly property color land: mix(background, foreground, light ? 0.16 : 0.12)
  readonly property color coast: alpha(mix(accent, foreground, 0.35), 0.8)
  readonly property color border: alpha(foreground, 0.4)
  readonly property color grid: alpha(foreground, 0.13)
  readonly property color glow: alpha(accent, 0.55)
  readonly property color lights: mix(accent, foreground, 0.6)
  readonly property color home: accent
  readonly property color route: accent
  readonly property color routeRest: mix(muted, foreground, 0.25)
  readonly property color live: alpha(accent, 0.45)
  // Night shading strength: a light theme darkened as far as a dark one
  // turns muddy grey, so it only dims.
  readonly property real night: light ? 0.55 : 1

  // Relief, sea floor, sun and sky (v2.1). Each colour's alpha is its strength
  // in the shader. Light themes mix towards the background (their paper) where
  // dark ones mix towards the foreground, so the same rules read as a lit relief
  // map on dark themes and as Swiss-style shading on light ones.
  readonly property color shelf: light ? mix(ocean, background, 0.55) : mix(ocean, coast, 0.10)
  readonly property color deep: light ? mix(ocean, accent, 0.08) : scale(ocean, 0.72)
  // On paper the high ground turns lighter, as on a Swiss relief map (aerial
  // perspective: the peaks bright, the valleys in a blue-grey haze); a grey
  // highland under grey shading read as smoke.
  readonly property color highland: light ? mix(land, background, 0.55) : mix(land, foreground, 0.18)
  readonly property color snow: light ? alpha(mix(ocean, background, 0.85), 0.9) : alpha(foreground, 0.65)
  readonly property color shade: light ? alpha(mix(foreground, accent, 0.25), 0.4) : alpha(scale(ocean, 0.25), 0.5)
  readonly property color sheen: light ? alpha(mix(ocean, background, 0.9), 0.5) : alpha(foreground, 0.32)
  // Dusk turns towards between the accent and the alert colour: violet on
  // Tokyo Night, amber-red on Gruvbox. The alpha is how far the hue turns; it
  // never adds light. On paper the band is wide and pale, so a light theme
  // keeps it nearer the accent and fainter, or it reads as a pink wash.
  readonly property color twilight: light ? alpha(mix(accent, urgent, 0.3), 0.1) : alpha(mix(accent, urgent, 0.5), 0.38)
  readonly property color isobath: alpha(mix(accent, foreground, 0.35), light ? 0.14 : 0.12)
  readonly property color glint: light ? alpha(background, 0.25) : alpha(lights, 0.10)
  readonly property color star: alpha(foreground, 0.6)

  // ---------------------------------------------------------- aircraft
  // Altitude ramp: muted on the ground, accent at FL200, foreground at FL400.
  readonly property color ground: muted
  readonly property color low: mix(muted, accent, 0.25)
  readonly property color mid: accent
  readonly property color high: foreground
  readonly property color selected: accent
  readonly property color emergency: urgent
  readonly property color halo: alpha(background, 0.8)
  // Altitude shadows: the background, darkened; ink-light on a light theme.
  readonly property color shadow: Qt.rgba(background.r * 0.3, background.g * 0.3, background.b * 0.3, light ? 0.26 : 0.5)

  // ------------------------------------------------------------ labels
  readonly property color label: foreground
  // Light themes keep the dim text darker: over the dimmed night side a pale
  // grey sinks into the map.
  readonly property color labelDim: mix(foreground, background, light ? 0.04 : 0.4)
  // The outline that keeps label text off the map. Light themes get a softer
  // one: a near-white ring round dark text over the night side reads as embossed.
  readonly property color labelHalo: light ? alpha(background, 0.5) : halo
  // Light themes keep place names nearly solid: at 62 % they sank into the grey
  // of the night side (about 1.6:1).
  readonly property color city: alpha(foreground, light ? 0.84 : 0.62)
  readonly property color tooltip: background
  readonly property color tooltipText: foreground
  readonly property color tooltipBorder: alpha(foreground, 0.3)

  // ------------------------------------------------------- Look up sky
  // The dome's light follows the Sun: night, the horizon haze, day, and the
  // glow over the set Sun (LookUp.qml blends them by solar altitude).
  readonly property color skyNight: light ? mix(background, foreground, 0.15) : mix(background, accent, 0.025)
  readonly property color skyNightHorizon: light ? mix(background, mix(foreground, accent, 0.4), 0.08) : mix(background, accent, 0.10)
  readonly property color skyDay: mix(background, accent, light ? 0.10 : 0.13)
  readonly property color skyDayHorizon: light ? mix(background, accent, 0.03) : mix(background, mix(accent, foreground, 0.3), 0.17)
  readonly property color skyTwilight: mix(accent, urgent, 0.35)
  readonly property color body: foreground
}
