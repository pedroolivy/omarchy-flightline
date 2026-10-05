import QtQuick
import QtQuick.Window
import "../.."

// Shimmer check: each scene is grabbed at its centre and with the centre moved
// east by exactly 1 and 3 px of ground at the view centre, like a slow drag.
// Shifted back by those pixels, a frame that does not alias matches the first
// one near the centre; what is left over (tests/offscreen/globe-shimmer.sh)
// is texture or line aliasing that would crawl while dragging. Runs on a v2.0
// tree too, for the same numbers there.
Window {
  id: win
  width: 800
  height: 600
  visible: true
  color: "#1a1b26"

  // name: [lat, lon, radius px]
  readonly property var scenes: ({
    globe: [35, -20, 252],
    globe3440: [35, -20, 605],          // the user's monitor: fit radius at 1440 px high
    alps: [46.3, 9.0, 300 / Math.sin(250 / 3440.065)],
    london: [51.5, -0.12, 300 / Math.sin(60 / 3440.065)],
    arctic: [75, -40, 1500],
    antarctic: [-82, 20, 605]
  })
  readonly property var names: Object.keys(scenes)
  readonly property var shifts: [0, 1, 3]

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
      sunVector: sunFor(new Date(Date.UTC(2026, 9, 3, 12, 0)))
      spaceColor: palette.space
      oceanColor: palette.ocean
      landColor: palette.land
      coastColor: palette.coast
      borderColor: palette.border
      gridColor: palette.grid
      glowColor: palette.glow
      lightsColor: palette.lights
    }
  }

  Shots {
    target: scene
    ready: globe.ready
    names: {
      var out = []
      for (var i = 0; i < win.names.length; i++)
        for (var j = 0; j < win.shifts.length; j++)
          out.push("shimmer-" + win.names[i] + "-" + win.shifts[j] + ".png")
      return out
    }
    onPrepare: function (i) {
      var s = win.scenes[win.names[Math.floor(i / win.shifts.length)]]
      var px = win.shifts[i % win.shifts.length]
      globe.centerLat = s[0]
      globe.radius = s[2]
      // px of ground at the centre: radius * cos(lat) * dLon
      globe.centerLon = s[1] + px / (s[2] * Math.cos(s[0] * Math.PI / 180)) * 180 / Math.PI
    }
  }
}
