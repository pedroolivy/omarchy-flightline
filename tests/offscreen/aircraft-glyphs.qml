import QtQuick
import QtQuick.Window
import "../.."

// A sheet of every glyph class at the sizes they must read at (7, 10 and 14 px
// half-size), with trails and shadows: columns twin jet, heavy, light/GA,
// rotorcraft, glider, ground vehicle; rows 2,000 ft, FL200, FL380, on the
// ground; one emergency at the bottom. Fixture "glyphs":
// tests/offscreen/aircraft-glyphs.json, every aircraft observed at the fetch
// time (tests/offscreen/aircraft.sh packs it).
// Args after the out dir and the fixture: palette (dark | light | warm).
Window {
  id: win
  width: 440
  height: 360
  visible: true
  color: "black"

  readonly property var traffic: shots.fixture("glyphs")
  readonly property string paletteName: shots.args[2] || "dark"
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

  Rectangle {
    id: scene
    anchors.fill: parent
    color: tints.land                   // glyphs over land, where shadows show least

    Aircraft {
      id: air
      anchors.fill: parent
      centerLat: -0.005
      centerLon: 0
      radius: 60 / (0.01 * Math.PI / 180)                // 60 px between columns
      source: win.traffic ? win.traffic.url : ""
      count: win.traffic ? win.traffic.count : 0
      epochMs: win.traffic ? win.traffic.epochMs : 0
      revision: 1
      time: 300
      spritePx: 7
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
    ready: air.texCount > 0
    names: ["glyphs-" + win.paletteName + "-7.png", "glyphs-" + win.paletteName + "-10.png", "glyphs-" + win.paletteName + "-14.png"]
    onPrepare: function (i) { air.spritePx = [7, 10, 14][i] }
  }
}
