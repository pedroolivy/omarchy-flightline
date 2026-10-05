import QtQuick
import QtQuick.Window
import "../.."

// The v2.1 globe looks, scene by scene, in a dark, a light and a warm theme
// (docs/VISUAL.md "Art direction"): day over the Atlantic, night over Europe
// and Asia, dusk over Africa, 250 NM over the Alps, the Andes, the Himalayas
// and Iceland, 60 NM over London, Japan with the Mariana Trench, the Azores
// ridge and both poles. The globe sits on the theme's background with the
// palette's transparent space, as in the panel.
//
// Args after the out dir: [theme,...|all (default dark)] [scene,...|all] [WxH] [urgent], and
// optionally a "world:count:epochMs" fixture (feed2ppm.py, as run.sh packs
// it) to draw the whole world's traffic over the globe. "urgent" tints the
// twilight with mix(accent, urgent) as GlobePalette would. The same file runs
// on a v2.0 tree for side-by-side composites: v2.1 properties are only set
// where the Globe has them.
//   /usr/lib/qt6/bin/qml tests/offscreen/globe-looks.qml -- OUT dark alps,iceland
Window {
  id: win
  // the options, without the "name:count:epochMs" fixtures run.sh appends
  readonly property var opts: shots.args.slice(1).filter(function (a) { return a.indexOf(":") < 0 })
  readonly property var size: (opts[2] || "1100x900").split("x")
  width: Number(size[0])
  height: Number(size[1])
  visible: true
  color: palette.background

  readonly property var themes: ({
    dark: ["#c0caf5", "#1a1b26", "#7aa2f7", "#565f89", "#f7768e"],    // Tokyo Night-like
    light: ["#4c4f69", "#eff1f5", "#1e66f5", "#8c8fa1", "#d20f39"],   // Catppuccin Latte-like
    warm: ["#ebdbb2", "#282828", "#d79921", "#928374", "#fb4934"]     // Gruvbox-like
  })
  // name: [lat, lon, visible NM (0: GlobeView's fit radius), UTC "MM-DDTHH:MM"]
  readonly property var scenes: ({
    atlantic: [25, -35, 0, "10-03T14:00"],
    night: [45, 45, 0, "10-03T22:00"],
    dusk: [2, 20, 0, "10-03T16:45"],
    alps: [46.3, 9.0, 250, "10-03T10:30"],
    andes: [-21, -67.5, 250, "10-03T15:00"],
    himalaya: [29.5, 86, 250, "10-03T05:30"],
    iceland: [64.9, -18.6, 250, "10-03T13:00"],
    london: [51.5, -0.12, 60, "10-03T12:00"],
    japan: [27, 141, 1300, "10-03T02:30"],
    azores: [38.5, -29, 600, "10-03T13:30"],
    arctic: [78, -40, 1500, "06-21T15:00"],
    antarctica: [-78, 20, 0, "12-21T10:00"]
  })
  readonly property var themeNames: !opts[0] ? ["dark"] : opts[0] === "all" ? ["dark", "light", "warm"] : opts[0].split(",")
  readonly property var sceneNames: !opts[1] || opts[1] === "all" ? Object.keys(scenes) : opts[1].split(",")
  readonly property var shotList: {
    var out = []
    for (var t = 0; t < themeNames.length; t++)
      for (var s = 0; s < sceneNames.length; s++)
        out.push([themeNames[t], sceneNames[s]])
    return out
  }

  GlobePalette {
    id: palette
  }

  Item {
    id: scene
    anchors.fill: parent
    Rectangle {
      anchors.fill: parent
      color: palette.background
    }
    Globe {
      id: globe
      anchors.fill: parent
      nightStrength: palette.night
      spaceColor: palette.space
      oceanColor: palette.ocean
      landColor: palette.land
      coastColor: palette.coast
      borderColor: palette.border
      gridColor: palette.grid
      glowColor: palette.glow
      lightsColor: palette.lights
      homeColor: palette.home
      liveColor: palette.live
    }
    Aircraft {
      id: air
      anchors.fill: parent
      visible: win.traffic !== null
      centerLat: globe.centerLat
      centerLon: globe.centerLon
      radius: globe.radius
      source: win.traffic ? win.traffic.url : ""
      count: win.traffic ? win.traffic.count : 0
      epochMs: win.traffic ? win.traffic.epochMs : 0
      revision: 1
      time: 300
      maxAge: 120
      spritePx: Math.min(8, 2.2 + globe.radius / 600)
      groundColor: palette.ground
      lowColor: palette.low
      midColor: palette.mid
      highColor: palette.high
      haloColor: palette.halo
    }
  }
  readonly property var traffic: shots.fixture("world")

  function apply(theme, name) {
    var c = themes[theme]
    palette.foreground = c[0]
    palette.background = c[1]
    palette.accent = c[2]
    palette.muted = c[3]
    palette.urgent = c[4]
    var s = scenes[name]
    globe.centerLat = s[0]
    globe.centerLon = s[1]
    var fit = Math.min(width, height) * 0.42
    globe.radius = s[2] > 0 ? Math.max(fit, height / 2 / Math.sin(s[2] / 3440.065)) : fit
    globe.sunVector = globe.sunFor(new Date("2026-" + s[3] + ":00Z"))
    if (opts[3] === "urgent" && "twilightColor" in globe)
      globe.twilightColor = palette.alpha(palette.mix(palette.accent, palette.urgent, 0.5), palette.light ? 0.2 : 0.45)
  }

  Shots {
    id: shots
    target: scene
    ready: globe.ready && (win.traffic === null || air.texCount > 0)
    names: win.shotList.map(function (x) { return x[0] + "-" + x[1] + ".png" })
    onPrepare: function (i) { win.apply(win.shotList[i][0], win.shotList[i][1]) }
  }
}
