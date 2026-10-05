import QtQuick
import QtQuick.Window
import "../.."

// (e) The sky of the "Look up" lens: London at civil dusk with Venus, a young
// Moon and Jupiter; New York at night under a gibbous Moon; Tokyo at noon
// with the day Moon; each in a dark, a light and a warm theme. The traffic
// is lookup.sh's world answer moved to each moment (only the clock moves:
// the aircraft are where that answer had them).
Window {
  id: win
  width: 640
  height: 600
  visible: true
  color: look.background

  readonly property string dataDir: shots.outDir + "/lookup-data"
  readonly property var metaData: {
    var xhr = new XMLHttpRequest()
    xhr.open("GET", "file://" + dataDir + "/meta.json", false)
    xhr.send()
    return JSON.parse(xhr.responseText)
  }
  property var shifted: metaData

  QtObject {
    id: mock
    property int trafficRev: 1
    property double epochMs: win.shifted.epochMs
    property var lastQuery: null
    property string status: "ok"
    function meta() { return win.shifted }
  }

  readonly property var palettes: ({
    dark: ["#c0caf5", "#1a1b26", "#7aa2f7", "#565f89", "#f7768e"],     // Tokyo Night-like
    light: ["#4c4f69", "#eff1f5", "#1e66f5", "#8c8fa1", "#d20f39"],    // Catppuccin Latte-like
    warm: ["#ebdbb2", "#282828", "#d79921", "#928374", "#fb4934"]      // Gruvbox-like
  })
  readonly property var scenes: [
    ["london-dusk", 51.5074, -0.1278, "2026-04-19T19:40:00Z"],
    ["newyork-night", 40.7128, -74.006, "2026-01-29T03:30:00Z"],
    ["tokyo-noon", 35.6762, 139.6503, "2026-10-03T02:40:00Z"]
  ]
  readonly property var shots: {
    var out = []
    for (var s = 0; s < scenes.length; s++)
      for (var p in palettes) out.push([s, p])
    return out
  }

  Item {
    id: scene
    anchors.fill: parent
    Rectangle { anchors.fill: parent; color: win.color }
    LookUp {
      id: look
      anchors.fill: parent
      service: mock
      fontFamily: "monospace"
      fontPx: 12
      units: "metric"
    }
  }

  Shots {
    id: shots
    target: scene
    names: win.shots.map(function (s) { return "e-" + win.scenes[s[0]][0] + "-" + s[1] + ".png" })
    onPrepare: function (i) {
      var sc = win.scenes[win.shots[i][0]], pal = win.palettes[win.shots[i][1]]
      look.foreground = pal[0]; look.background = pal[1]; look.accent = pal[2]; look.muted = pal[3]; look.urgent = pal[4]
      var nowMs = Date.parse(sc[3])
      win.shifted = Object.assign({}, win.metaData, { epochMs: nowMs - 305000 })
      look.fixedNowMs = nowMs
      look.home = { lat: sc[1], lon: sc[2], name: sc[0] }
      mock.trafficRev++
      look.selectedIndex = -1
      look.rebuild()
      var b = look.bodies
      if (b) console.info(sc[0], win.shots[i][1], b.twilight, "sun", b.sun.el.toFixed(1), "moon",
        b.moon.up ? b.moon.el.toFixed(1) + "/" + b.moon.az.toFixed(0) + " " + Math.round(b.moon.illuminated * 100) + "%" : "down",
        b.planets.filter(function (p) { return p.visible }).map(function (p) { return p.name }).join(","),
        "sky", look.skyCount)
    }
  }
}
