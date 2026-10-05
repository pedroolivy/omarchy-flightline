pragma ComponentBehavior: Bound

import QtQuick

// GPU globe: one ShaderEffect, three textures, no geometry on the CPU.
//
// shaders/globe.frag draws the whole orthographic Earth per pixel: land and
// coast from a distance field, sea-floor depth, land relief and snow, country/
// state borders, an adaptive graticule, sunlight with the night side and city
// lights, the atmosphere, stars, and the overlays (home ring, live-data
// boundary). QML only feeds uniforms, so moving the camera costs a
// handful of property writes and one draw call.
//
// The textures (earth 4096 x 2048 + lights 2048 x 1024 + terrain 3072 x 1536:
// 58 MiB of VRAM) load the first time `active` is true. With `keepTextures` (the default) they then
// stay: Mesa keeps freed textures cached but does not reuse them for the next
// upload, so releasing on every close left two sets resident after the second
// open (docs/ARCHITECTURE.md "Budgets"). Until they arrive the globe draws as
// plain ocean.
//
// Imports QtQuick only: colours come in as properties, so the globe renders
// offscreen in tests (tests/offscreen/).
ShaderEffect {
  id: root

  // -------------------------------------------------------------- view
  property real centerLat: 0                    // degrees
  property real centerLon: 0
  property real radius: Math.min(width, height) * 0.45   // px
  property real time: 0                         // s; for subtle effects only
  property vector3d sunVector: Qt.vector3d(1, 0, 0)       // ECEF unit vector, see sunFor()
  property real nightStrength: 1                // 0..1
  property bool active: true
  property bool keepTextures: true              // false: release whenever `active` turns false

  // ------------------------------------------------------------ colours
  property color spaceColor: "#16161e"
  property color oceanColor: "#1a1b26"
  property color landColor: "#292e42"
  property color coastColor: Qt.rgba(0.48, 0.64, 0.97, 0.85)
  property color borderColor: Qt.rgba(0.66, 0.69, 0.84, 0.45)
  property color gridColor: Qt.rgba(0.66, 0.69, 0.84, 0.16)
  property color glowColor: Qt.rgba(0.48, 0.64, 0.97, 0.6)
  property color lightsColor: Qt.rgba(1.0, 0.78, 0.45, 1)
  property color homeColor: "#7aa2f7"
  property color liveColor: Qt.rgba(0.48, 0.64, 0.97, 0.5)

  // v2.1 colours. The defaults follow the v2.0 colours above, so a view that
  // only sets those still gets a matching globe: glowColor carries the theme's
  // accent and borderColor its foreground (GlobePalette), and the ocean tells
  // a light theme from a dark one. The alpha of each is its strength.
  readonly property bool lightOcean: luma(oceanColor) > 0.5
  readonly property color white: Qt.rgba(1, 1, 1, 1)
  readonly property color accentGuess: Qt.rgba(glowColor.r, glowColor.g, glowColor.b, 1)
  readonly property color foregroundGuess: Qt.rgba(borderColor.r, borderColor.g, borderColor.b, 1)
  property color shelfColor: lightOcean ? mixc(oceanColor, white, 0.18) : mixc(oceanColor, coastColor, 0.1)
  property color deepColor: lightOcean ? mixc(oceanColor, accentGuess, 0.08) : scalec(oceanColor, 0.72)
  property color highlandColor: mixc(landColor, foregroundGuess, lightOcean ? 0.14 : 0.18)
  property color snowColor: lightOcean ? withAlpha(mixc(oceanColor, white, 0.85), 0.9) : withAlpha(foregroundGuess, 0.65)
  property color shadeColor: lightOcean ? withAlpha(foregroundGuess, 0.45) : withAlpha(scalec(oceanColor, 0.25), 0.5)
  property color sheenColor: lightOcean ? withAlpha(mixc(oceanColor, white, 0.9), 0.5) : withAlpha(foregroundGuess, 0.32)
  property color twilightColor: withAlpha(accentGuess, lightOcean ? 0.2 : 0.45)
  property color isobathColor: withAlpha(coastColor, lightOcean ? 0.14 : 0.12)
  property color glintColor: lightOcean ? Qt.rgba(1, 1, 1, 0.25) : withAlpha(lightsColor, 0.1)
  property color starColor: withAlpha(foregroundGuess, 0.6)

  // ------------------------------------------------------------ toggles
  property bool showGraticule: true
  property bool showBorders: true
  property bool showNight: true
  property bool showLights: true
  property bool showRelief: true                // terrain: relief, snow, sea-floor depth, isobaths
  property bool showIsobaths: true              // the 200 / 1,000 / 4,000 m contours at region zoom
  property bool showStars: true                 // around the disc; only ever drawn on a dark ocean
  property real reliefStrength: 1               // hillshade gain, 0..~1.5

  // ----------------------------------------------------------- overlays
  property real homeLat: 0
  property real homeLon: 0
  property real homeRingNm: 0                   // <= 0: no home
  property real liveLat: 0
  property real liveLon: 0
  property real liveRadiusNm: 0                 // <= 0: hidden

  // ------------------------------------------------------------ textures
  // Distance-field spreads baked by tools/build-textures.sh (SL, SB, LW / 64).
  property url earthSource: Qt.resolvedUrl("assets/earth.png")
  property url lightsSource: Qt.resolvedUrl("assets/lights.png")
  property url terrainSource: Qt.resolvedUrl("assets/terrain.png")
  readonly property real landSpread: 8
  readonly property real borderSpread: 4
  readonly property Maps maps: textures.item as Maps
  readonly property bool ready: maps !== null && maps.ready

  // ------------------------------------------- uniforms (see globe.vert)
  // bool properties do not reach float uniforms, so the toggles are mirrored.
  readonly property real gridOn: showGraticule ? 1 : 0
  readonly property real bordersOn: showBorders ? 1 : 0
  readonly property real nightOn: showNight ? 1 : 0
  readonly property real lightsOn: showLights ? 1 : 0
  readonly property real starsOn: showStars && !lightOcean ? 1 : 0
  readonly property real isobathsOn: showIsobaths ? 1 : 0
  readonly property size earthSize: maps && maps.ready ? maps.earth.sourceSize : Qt.size(4096, 2048)
  readonly property size lightsSize: maps && maps.ready ? maps.lights.sourceSize : Qt.size(2048, 1024)
  readonly property vector4d earthInfo: Qt.vector4d(earthSize.width, earthSize.height, landSpread, borderSpread)
  readonly property vector4d lightsInfo: Qt.vector4d(lightsSize.width, lightsSize.height, lightsSize.width / 64, 0)
  // A missing or broken terrain.png only turns the relief off (v2.0's flat globe).
  readonly property bool hasTerrain: ready && maps.terrain.status === Image.Ready
  readonly property size terrainSize: hasTerrain ? maps.terrain.sourceSize : Qt.size(3072, 1536)
  readonly property vector4d terrainInfo: Qt.vector4d(terrainSize.width, terrainSize.height,
                                                      hasTerrain && showRelief ? 1 : 0, reliefStrength)
  readonly property variant earth: maps && maps.ready ? maps.earth : blank
  readonly property variant lights: maps && maps.ready ? maps.lights : blank
  readonly property variant terrain: hasTerrain ? maps.terrain : blank

  vertexShader: Qt.resolvedUrl("shaders/globe.vert.qsb")
  fragmentShader: Qt.resolvedUrl("shaders/globe.frag.qsb")

  // The textures live in a Loader, so turning it off destroys the Images and
  // Qt frees both the pixels and the GPU textures.
  property bool texturesWanted: false
  onActiveChanged: texturesWanted = active || (keepTextures && texturesWanted)
  Component.onCompleted: texturesWanted = active
  Loader {
    id: textures
    active: root.texturesWanted
    asynchronous: true
    sourceComponent: Maps {
      earthSource: root.earthSource
      lightsSource: root.lightsSource
      terrainSource: root.terrainSource
    }
  }
  component Maps: Item {
    property url earthSource
    property url lightsSource
    property url terrainSource
    readonly property alias earth: earthImage
    readonly property alias lights: lightsImage
    readonly property alias terrain: terrainImage
    readonly property bool ready: earthImage.status === Image.Ready && lightsImage.status === Image.Ready
                                  && terrainImage.status !== Image.Loading

    // Exact taps: the shader filters earth.png itself (side-signed borders).
    Image {
      id: earthImage
      visible: false
      source: parent.earthSource
      asynchronous: true
      cache: false
      smooth: false
      mipmap: false
    }
    Image {
      id: lightsImage
      visible: false
      source: parent.lightsSource
      asynchronous: true
      cache: false
      smooth: true
      mipmap: false
    }
    // Data channels, not a picture: RGB without alpha (Qt would premultiply it).
    // Linear filtering for the shader's B-spline; no mipmaps (the width is not a
    // power of two, which GLES 2 only allows without them).
    Image {
      id: terrainImage
      visible: false
      source: parent.terrainSource
      asynchronous: true
      cache: false
      smooth: true
      mipmap: false
    }
  }
  // Stand-in texture provider while inactive or loading (no texture: plain ocean).
  Image {
    id: blank
    visible: false
  }

  function luma(c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
  function mixc(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }
  function scalec(c, k) { return Qt.rgba(c.r * k, c.g * k, c.b * k, 1) }
  function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Unit vector (ECEF) towards the subsolar point at `date`. Low-precision
  // solar position (Astronomical Almanac), good to ~0.5 degree.
  function sunFor(date) {
    var d = date.getTime() / 86400000 - 10957.5           // days since J2000
    var g = (357.529 + 0.98560028 * d) * Math.PI / 180
    var q = 280.459 + 0.98564736 * d
    var L = (q + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * Math.PI / 180
    var e = (23.439 - 0.00000036 * d) * Math.PI / 180
    var dec = Math.asin(Math.sin(e) * Math.sin(L))
    var ra = Math.atan2(Math.cos(e) * Math.sin(L), Math.cos(L))
    var gmst = (18.697374558 + 24.06570982441908 * d) % 24
    var lon = ((ra * 180 / Math.PI - gmst * 15) % 360 + 540) % 360 - 180
    var lo = lon * Math.PI / 180
    return Qt.vector3d(Math.cos(dec) * Math.cos(lo), Math.cos(dec) * Math.sin(lo), Math.sin(dec))
  }
}
