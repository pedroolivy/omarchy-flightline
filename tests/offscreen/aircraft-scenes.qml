import QtQuick
import QtQuick.Window
import "../.."
import "../../Model.js" as Model

// The aircraft layers in GlobeView's stack and with GlobeView's numbers
// (fitRadius, radius for a visible radius, Model.spritePxFor, maxAge by
// mode), over the whole world's traffic from a saved answer (WORLD_JSON).
// Renders work on a v2.0 tree too, which simply has no trails or shadows.
//
// Args after the out dir and the fixture: palette (dark | light | warm),
// width, height, then the scene names to render (default: all of them). A
// name may end in "@<px>" to override GlobeView's sprite size, e.g. jfk-15@12.
// Writes <out>/air-<palette>-<scene>[@<px>].png.
Window {
  id: win
  readonly property var args: shots.args
  readonly property string paletteName: args[2] || "dark"
  width: Number(args[3]) || 3440
  height: Number(args[4]) || 1440
  visible: true
  color: "black"

  readonly property var traffic: shots.fixture("world")

  // [name, lat, lon, visible radius NM]; the world answer was fetched at
  // 21:42 UTC, so Europe and the North Atlantic are at night.
  readonly property var scenes: [
    ["world-atlantic", 42, -32, 0],
    ["world-europe", 47, 2, 1400],
    ["london-250", 51.5, -0.5, 250],
    ["newyork-250", 40.7, -74.0, 250],
    ["jfk-60", 40.64, -73.78, 60],
    ["jfk-15", 40.64, -73.78, 15],
    ["lhr-15", 51.47, -0.45, 15]
  ]
  readonly property var wanted: args.length > 5 ? args.slice(5) : scenes.map(function (s) { return s[0] })
  readonly property var queue: wanted.map(function (w) {
    var name = w.split("@")[0]
    var s = scenes.filter(function (s) { return s[0] === name })[0]
    return s ? [w].concat(s.slice(1), [Number(w.split("@")[1]) || 0]) : null
  }).filter(function (s) { return s !== null })
  property real spriteOverride: 0

  readonly property var themes: ({
    dark: ["#c0caf5", "#1a1b26", "#7aa2f7", "#565f89", "#f7768e"],
    light: ["#4c4f69", "#eff1f5", "#1e66f5", "#8c8fa1", "#d20f39"],
    warm: ["#ebdbb2", "#282828", "#d79921", "#928374", "#fb4934"]
  })
  GlobePalette {
    id: tints
    foreground: win.themes[win.paletteName][0]
    background: win.themes[win.paletteName][1]
    accent: win.themes[win.paletteName][2]
    muted: win.themes[win.paletteName][3]
    urgent: win.themes[win.paletteName][4]
  }

  // GlobeView's camera maths
  readonly property real halfDiagonal: Math.sqrt(width * width + height * height) / 2
  readonly property real fitRadius: Math.max(40, Math.min(width, height) * 0.42)
  property real visibleNm: 0
  readonly property real radius: visibleNm > 0
    ? Math.max(fitRadius, Model.radiusForVisibleNm(visibleNm, halfDiagonal, fitRadius)) : fitRadius

  Rectangle {
    id: scene
    anchors.fill: parent
    color: tints.background             // the panel behind the globe

    Globe {
      id: globe
      anchors.fill: parent
      centerLat: 42
      centerLon: -32
      radius: win.radius
      sunVector: sunFor(new Date(win.traffic ? win.traffic.epochMs + 300000 : 0))
      nightStrength: tints.night
      spaceColor: tints.space
      oceanColor: tints.ocean
      landColor: tints.land
      coastColor: tints.coast
      borderColor: tints.border
      gridColor: tints.grid
      glowColor: tints.glow
      lightsColor: tints.lights
    }
    Aircraft {
      id: air
      anchors.fill: parent
      centerLat: globe.centerLat
      centerLon: globe.centerLon
      radius: globe.radius
      spritePx: win.spriteOverride > 0 ? win.spriteOverride : Model.spritePxFor(Model.visibleRadiusNm(win.radius, win.halfDiagonal))
      source: win.traffic ? win.traffic.url : ""
      count: win.traffic ? win.traffic.count : 0
      epochMs: win.traffic ? win.traffic.epochMs : 0
      revision: 1
      time: 305                         // 5 s after the fetch
      maxAge: Model.WORLD_MAX_AGE_S || 120
      groundColor: tints.ground
      lowColor: tints.low
      midColor: tints.mid
      highColor: tints.high
      selectedColor: tints.selected
      emergencyColor: tints.emergency
      haloColor: tints.halo
    }
  }

  Shots {
    id: shots
    target: scene
    ready: globe.ready && air.texCount > 0
    names: win.queue.map(function (s) { return "air-" + win.paletteName + "-" + s[0] + ".png" })
    onPrepare: function (i) {
      var s = win.queue[i]
      globe.centerLat = s[1]
      globe.centerLon = s[2]
      win.visibleNm = s[3]
      win.spriteOverride = s[4]
      console.info(s[0], "radius", win.radius.toFixed(0), "spritePx", air.spritePx.toFixed(2))
    }
  }
}
