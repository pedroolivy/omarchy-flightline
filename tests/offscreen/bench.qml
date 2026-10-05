import QtQuick
import QtQuick.Window
import "../.."
import "../../Model.js" as Model

// Cost of continuous interaction: the globe turns every frame with the whole
// world's traffic on it (WORLD_JSON), like a drag. Prints the frame count once
// a second; bench.sh samples the process CPU and GPU time.
// Args after the out dir and the fixture: seconds, width, height, radius mode
// and layers (bench.sh fills them from its env):
//   breathe  the globe spins and breathes in zoom (380..836 px; the v2.0 bench)
//   fit      GlobeView's fit radius (0.42 of the short side), a slow pan
//   cover    the globe covers the whole window (every pixel runs the globe
//            shader at region-like magnification), a slow pan
//   layers   all (globe + aircraft, trails and shadows on where the tree has
//            them) or globe (no aircraft layer)
//   sprite   bench (2.2 + radius / 600 px, the v2.0 bench) or app (what GlobeView
//            draws at that zoom, Model.spritePxFor: dots at globe zoom, no shadows)
Window {
  id: win
  readonly property var args: shots.args
  width: Number(args[3]) || 1000
  height: Number(args[4]) || 800
  visible: true
  color: "black"

  readonly property var traffic: shots.fixture("world")
  readonly property int seconds: Number(args[2]) || 8
  readonly property string mode: args[5] || "breathe"
  readonly property string layers: args[6] || "all"
  readonly property string sprite: args[7] || "bench"
  readonly property real fitRadius: Math.min(width, height) * 0.42
  readonly property real coverRadius: Math.sqrt(width * width + height * height) / 2 + 2
  property int frames: 0
  onFrameSwapped: frames++

  Globe {
    id: globe
    anchors.fill: parent
    centerLat: 30
    centerLon: -40
    radius: win.mode === "cover" ? win.coverRadius : win.mode === "fit" ? win.fitRadius : 380
    sunVector: sunFor(new Date(win.traffic ? win.traffic.epochMs + 300000 : 0))
    homeLat: 51.47
    homeLon: -0.45
    homeRingNm: 100
    liveRadiusNm: 0
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
    spritePx: win.sprite === "app"
      ? Model.spritePxFor(Model.visibleRadiusNm(globe.radius, Math.sqrt(win.width * win.width + win.height * win.height) / 2))
      : 2.2 + globe.radius / 600
    Component.onCompleted: {
      // v2.1 layers; a v2.0 tree has none of these properties
      if ("revision" in air) air.revision = 1
      if ("showTrails" in air) air.showTrails = true
      if ("showShadows" in air) air.showShadows = true
    }
  }

  FrameAnimation {
    running: globe.ready && air.texCount > 0
    onTriggered: {
      if (win.mode === "breathe") {
        globe.centerLon = -40 + elapsedTime * 15
        globe.radius = 380 * (1.6 + 0.6 * Math.sin(elapsedTime * 0.8))
      } else {
        globe.centerLon = -40 + elapsedTime * 6 * win.fitRadius / globe.radius   // ~4 px a frame
      }
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
