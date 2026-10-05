import QtQuick
import QtQuick.Window
import "../.."
import "../../Model.js" as Model

// GPU cost of the aircraft layers at world zoom: the globe at its fit radius
// (as GlobeView opens it) turning every frame under the whole world's
// traffic, like a slow drag. tests/offscreen/aircraft-bench.sh samples the
// DRM gfx-engine time and the CPU time of the process.
//
// Args after the out dir and the fixture: seconds, width, height, layers and
// an optional visible radius in NM (default: the whole globe; 250 is the
// region mood over Europe, where shadows show). `layers` is "globe" (no
// aircraft), "sprites" (trails and shadows off) or "all" (everything GlobeView
// turns on at that zoom). On a v2.0 tree, which has no trails, "sprites" and
// "all" draw the same thing.
Window {
  id: win
  readonly property var args: shots.args
  width: Number(args[3]) || 1000
  height: Number(args[4]) || 800
  visible: true
  color: "black"

  readonly property var traffic: shots.fixture("world")
  readonly property int seconds: Number(args[2]) || 8
  readonly property string layers: args[5] || "all"
  readonly property real visibleNm: Number(args[6]) || 0
  readonly property real halfDiagonal: Math.sqrt(width * width + height * height) / 2
  readonly property real fitRadius: Math.min(width, height) * 0.42       // GlobeView's
  property int frames: 0
  onFrameSwapped: frames++

  Globe {
    id: globe
    anchors.fill: parent
    centerLat: win.visibleNm > 0 ? 50 : 40
    centerLon: win.visibleNm > 0 ? 2 : -30
    radius: win.visibleNm > 0 ? Model.radiusForVisibleNm(win.visibleNm, win.halfDiagonal, win.fitRadius) : win.fitRadius
    sunVector: sunFor(new Date(win.traffic ? win.traffic.epochMs + 300000 : 0))
  }
  Aircraft {
    id: air
    anchors.fill: parent
    visible: win.layers !== "globe"
    centerLat: globe.centerLat
    centerLon: globe.centerLon
    radius: globe.radius
    source: win.traffic ? win.traffic.url : ""
    count: win.traffic ? win.traffic.count : 0
    epochMs: win.traffic ? win.traffic.epochMs : 0
    revision: 1                                         // 0 means "no file yet"
    spritePx: Model.spritePxFor(Model.visibleRadiusNm(globe.radius, win.halfDiagonal))
    maxAge: 120                                         // world answers
    time: 300
    Component.onCompleted: {
      // v2.1 layers; a v2.0 tree has none of these properties
      if ("showTrails" in air) air.showTrails = win.layers === "all"
      if ("showShadows" in air) air.showShadows = win.layers === "all"
      console.info("layers", win.layers, "trails", air.showTrails, "shadows", air.showShadows)
    }
  }

  FrameAnimation {
    running: globe.ready && air.texCount > 0
    onTriggered: {
      // a slow pan: about 4 px a frame at either zoom
      globe.centerLon = (win.visibleNm > 0 ? 2 : -30) + elapsedTime * 6 * win.fitRadius / globe.radius
      air.time = 300 + elapsedTime
    }
  }

  Shots {
    id: shots
    target: globe
    ready: false
  }

  Timer {
    interval: 1000
    repeat: true
    running: globe.ready && air.texCount > 0
    property int n: 0
    property int last: 0
    onTriggered: {
      console.info("bench fps", win.frames - last, "aircraft", air.texCount)
      last = win.frames
      if (++n >= win.seconds) Qt.quit()
    }
  }
}
