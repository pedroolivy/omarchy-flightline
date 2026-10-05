import QtQuick
import QtQuick.Window
import "../.."

// Trail geometry against the sprites (fixtures "deadreckon" and "edge", the
// latter tests/offscreen/aircraft-edge.json):
//   check-head-trail.png / check-head-sprite.png: the deadreckon aircraft at
//     t = 60 s (8.73 px east of the centre at radius 5000), once as a bare
//     Trails layer ending at its head (headPx 0, round end), once as the sprite
//     alone; a script compares where each says the aircraft is.
//   check-antimeridian.png: two jets crossing 180 degrees in opposite
//     directions, one without a track (gs 0: no trail), one taxiing (none),
//     one stale (age 80 s of 90: faded with its trail) beside a fresh twin.
//   check-limb.png: the same at globe zoom, with heavies at the limb: the one
//     whose head is just behind it must draw nothing, not a streak.
Window {
  id: win
  width: 400
  height: 300
  visible: true
  color: "black"

  readonly property var one: shots.fixture("deadreckon")
  readonly property var edge: shots.fixture("edge")

  Item {
    id: scene
    anchors.fill: parent

    Rectangle {
      anchors.fill: parent
      color: "#1a1b26"
    }
    Image {
      id: tex
      visible: false
      smooth: false
      cache: false
      source: win.one ? win.one.url + "#1" : ""
    }
    Trails {
      id: bare
      anchors.fill: parent
      visible: false
      radius: 5000
      dataTex: tex
      texCount: tex.status === Image.Ready ? 1 : 0
      texTime: 60
      trailSeconds: 120
      trailWidth: 1
      headPx: 0
      strength: 1
      lowColor: "white"
      midColor: "white"
      highColor: "white"
    }
    Aircraft {
      id: air
      anchors.fill: parent
      radius: 5000
      source: win.one ? win.one.url : ""
      count: win.one ? win.one.count : 0
      epochMs: win.one ? win.one.epochMs : 0
      revision: 1
      time: 60
      spritePx: 8
      showTrails: false
      showShadows: false
      lowColor: "white"
      midColor: "white"
      highColor: "white"
      haloColor: "transparent"
    }
  }

  Shots {
    id: shots
    target: scene
    ready: air.texCount > 0 && tex.status === Image.Ready
    names: ["check-head-trail.png", "check-head-sprite.png", "check-antimeridian.png", "check-limb.png"]
    onPrepare: function (i) {
      bare.visible = i === 0
      air.visible = i > 0
      if (i === 2) {
        air.showTrails = true
        air.showShadows = true
        air.lowColor = "#565f89"
        air.midColor = "#7aa2f7"
        air.highColor = "#c0caf5"
        air.haloColor = Qt.rgba(0.1, 0.11, 0.15, 0.8)
        air.count = win.edge.count
        air.epochMs = win.edge.epochMs
        air.source = win.edge.url
        air.centerLat = 10.04
        air.centerLon = 180
        air.radius = 50000
        air.time = 305
        air.maxAge = 90
      } else if (i === 3) {
        air.radius = 140
        air.spritePx = 2.6
      }
    }
  }
}
