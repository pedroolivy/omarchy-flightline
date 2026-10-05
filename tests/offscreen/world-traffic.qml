import QtQuick
import QtQuick.Window
import "../.."

// (c) The whole world's traffic from a real saved response (WORLD_JSON, packed
// by feed2ppm.py): the globe over the North Atlantic at the fetch time, then
// Europe closer in, then South America at dusk.
Window {
  id: win
  width: 900
  height: 900
  visible: true
  color: "black"

  readonly property var traffic: shots.fixture("world")

  Item {
    id: scene
    anchors.fill: parent

    Globe {
      id: globe
      anchors.fill: parent
      centerLat: 35
      centerLon: -30
      radius: 420
      sunVector: sunFor(new Date(win.traffic ? win.traffic.epochMs + 300000 : 0))
    }
    Aircraft {
      id: air
      anchors.fill: parent
      centerLat: globe.centerLat
      centerLon: globe.centerLon
      radius: globe.radius
      source: win.traffic ? win.traffic.url : ""
      count: win.traffic ? win.traffic.count : 0
      epochMs: win.traffic ? win.traffic.epochMs : 0
      revision: 1                       // 0 means "no file yet": nothing loads
      time: 300
      spritePx: 2.2
    }
  }

  Shots {
    id: shots
    target: scene
    ready: globe.ready && air.texCount > 0
    names: ["c-world-atlantic.png", "c-world-europe.png", "c-world-samerica.png"]
    onPrepare: function (i) {
      console.info("aircraft in texture", air.texCount)
      if (i === 1) {
        globe.centerLat = 49
        globe.centerLon = 8
        globe.radius = 2400
        air.spritePx = 4.5
      } else if (i === 2) {
        globe.centerLat = -12
        globe.centerLon = -62
        globe.radius = 1300
        air.spritePx = 3.5
      }
    }
  }
}
