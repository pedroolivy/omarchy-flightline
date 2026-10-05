import QtQuick
import QtQuick.Window
import "../.."

// (a) Whole globe over South America at 23:30 UTC: the continent on the night
// side with city lights, the terminator over the Pacific, graticule, borders,
// the home ring at Manaus and a 250 NM live-data ring. Then the seams: day
// side, the antimeridian at regional zoom (Fiji, night: coast, lights and
// graticule must run across lon 180 unbroken) and the north pole. The last shot
// turns `active` off with keepTextures off: the textures are released and the
// globe must fall back to plain ocean.
Window {
  width: 900
  height: 900
  visible: true
  color: "black"

  Globe {
    id: globe
    anchors.fill: parent
    centerLat: -10
    centerLon: -58
    radius: 400
    sunVector: sunFor(new Date(Date.UTC(2026, 9, 3, 23, 30)))
    homeLat: -3.12
    homeLon: -60.02
    homeRingNm: 100
    liveLat: -3.12
    liveLon: -60.02
    liveRadiusNm: 250
  }

  Shots {
    target: globe
    ready: globe.ready
    names: ["a-globe-night.png", "a-globe-day.png", "a-antimeridian.png", "a-pole.png", "a-globe-inactive.png"]
    onPrepare: function (i) {
      if (i === 1) {
        globe.sunVector = globe.sunFor(new Date(Date.UTC(2026, 9, 3, 15, 0)))
        globe.centerLat = 20
        globe.centerLon = 10
      } else if (i === 2) {
        globe.sunVector = globe.sunFor(new Date(Date.UTC(2026, 9, 3, 12, 0)))
        globe.centerLat = -17.5
        globe.centerLon = 179.9
        globe.radius = 450 / Math.sin(300 / 3440.065)
      } else if (i === 3) {
        globe.centerLat = 82
        globe.centerLon = 30
        globe.radius = 1400
      } else if (i === 4) {
        globe.radius = 400
        globe.keepTextures = false
        globe.active = false
        console.info("inactive: earth/lights status", globe.ready, globe.earthInfo, globe.lightsInfo)
      }
    }
  }
}
