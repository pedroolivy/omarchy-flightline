import QtQuick
import QtQuick.Window
import "../.."

// Dead reckoning against the contract: one aircraft at (0, 0), track 90,
// 360 kt, observed exactly at epochMs. At t = 60 s it has flown 6 NM = 0.1
// degree east: 5000 * sin(0.1 deg) = 8.73 px to the right at radius 5000. At
// t = 80 s it is 2/3 faded (70 % .. 100 % of maxAge = 90 s). Then the source
// switches to another file and the new count must latch with the texture.
Window {
  id: win
  width: 200
  height: 100
  visible: true
  color: "black"

  readonly property var one: shots.fixture("deadreckon")
  readonly property var other: shots.fixture("outback")

  Item {
    id: scene
    anchors.fill: parent

    Rectangle {
      anchors.fill: parent
      color: "black"
    }
    Aircraft {
      id: air
      anchors.fill: parent
      centerLat: 0
      centerLon: 0
      radius: 5000
      source: win.one ? win.one.url : ""
      count: win.one ? win.one.count : 0
      epochMs: win.one ? win.one.epochMs : 0
      revision: 1                       // 0 means "no file yet": nothing loads
      spritePx: 8
      lowColor: "white"
      midColor: "white"
      highColor: "white"
      haloColor: "transparent"
    }
  }

  Shots {
    id: shots
    target: scene
    ready: air.texCount > 0
    names: ["dr-t0.png", "dr-t60.png", "dr-t80.png", "dr-swap.png"]
    onPrepare: function (i) {
      air.time = [0, 60, 80, 0][i]
      if (i === 3) {
        air.count = win.other.count
        air.epochMs = win.other.epochMs
        air.source = win.other.url
        console.info("after source change, before load: texCount", air.texCount)
      }
    }
  }
  Connections {
    target: air
    function onTexCountChanged() { console.info("texCount ->", air.texCount, "texEpochMs", air.texEpochMs) }
  }
}
