import QtQuick
import QtQuick.Window
import "../.."

// Idle and texture lifecycle of the globe (tests/offscreen/globe-idle.sh):
//   empty    3 s with `active` false: no textures yet (the VRAM reference)
//   loaded   active, textures in; then 5 s without touching anything: the
//            item must not ask for a single frame by itself
//   reopen   active off and on three times with keepTextures (the default):
//            the same textures stay, nothing reloads
//   release  keepTextures false, active false: the textures are dropped
// Each phase prints one "globe-idle" line; the script samples the DRM
// memory of the process at the "empty" and "loaded" lines.
Window {
  id: win
  width: 1100
  height: 900
  visible: true
  color: "#1a1b26"

  property int frames: 0
  onFrameSwapped: frames++

  Globe {
    id: globe
    anchors.fill: parent
    active: false
    centerLat: 30
    centerLon: -30
    radius: 380
    sunVector: sunFor(new Date(Date.UTC(2026, 9, 3, 18, 0)))
    homeLat: 51.5
    homeLon: -0.12
    homeRingNm: 100
  }

  property var firstMaps: null
  property int step: 0                          // half seconds
  Timer {
    interval: 500
    repeat: true
    running: true
    property int idleStart: 0
    onTriggered: {
      win.step++
      if (win.step === 6) {
        console.info("globe-idle empty", "ready", globe.ready)
        globe.active = true
      } else if (win.step > 6 && win.step < 100 && globe.ready && win.firstMaps === null) {
        win.firstMaps = globe.maps
        console.info("globe-idle loaded", "terrain", globe.hasTerrain, globe.terrainInfo)
        win.step = 100
      } else if (win.step === 104) {
        idleStart = win.frames                  // 2 s to settle, then count 5 s
      } else if (win.step === 114) {
        console.info("globe-idle idle-frames", win.frames - idleStart, "in 5 s")
      } else if (win.step >= 115 && win.step < 121) {
        globe.active = !globe.active            // three closes and opens
        if (globe.active)
          console.info("globe-idle reopen", "same textures", globe.maps === win.firstMaps, "ready", globe.ready)
      } else if (win.step === 121) {
        globe.keepTextures = false
        globe.active = false
      } else if (win.step === 122) {
        console.info("globe-idle release", "maps", globe.maps, "ready", globe.ready)
        Qt.quit()
      }
    }
  }
}
