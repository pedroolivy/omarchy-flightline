import QtQuick
import QtQuick.Window
import "../.."

// (b) 250 NM view over Alice Springs (public coordinates): home ring, live-data
// ring, the route arc from the south-east into ASP of the selected aircraft (flown part solid,
// the rest dashed) and a few synthetic aircraft of every glyph class, one on
// the ground, one squawking 7700, one hovered. Day, then night, then 60 NM.
Window {
  id: win
  width: 900
  height: 900
  visible: true
  color: "black"

  readonly property var traffic: shots.fixture("outback")
  // 250 NM from the centre to the nearest edge
  function radiusFor(nm) { return 450 / Math.sin(nm / 3440.065) }

  Item {
    id: scene
    anchors.fill: parent

    Globe {
      id: globe
      anchors.fill: parent
      centerLat: -23.80
      centerLon: 133.90
      radius: win.radiusFor(250)
      sunVector: sunFor(new Date(Date.UTC(2026, 9, 3, 3, 0)))      // 12:30 local
      homeLat: -23.80
      homeLon: 133.90
      homeRingNm: 100
      liveLat: -23.53
      liveLon: 134.34
      liveRadiusNm: 240
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
      revision: 1                     // 0 means "no file yet": nothing loads
      time: 300                       // = the fetch time of the fixture
      spritePx: 7
      selectedIndex: 11               // QFA1492 (ground first, then by altitude)
      hoveredIndex: 12                // UAE261
    }
    RouteArc {
      anchors.fill: parent
      centerLat: globe.centerLat
      centerLon: globe.centerLon
      radius: globe.radius
      fromLat: -27.5345               // an origin 600 km south-east
      fromLon: 138.0942
      atLat: -25.30872                // QFA1492, 60 % of the way
      atLon: 135.54724
      toLat: -23.8011                 // ASP
      toLon: 133.9015
      shown: true
      gapPx: 2.5 * air.spritePx + 3
    }
  }

  Shots {
    id: shots
    target: scene
    ready: globe.ready && air.texCount > 0
    names: ["b-regional-day.png", "b-regional-night.png", "b-regional-60nm.png"]
    onPrepare: function (i) {
      if (i === 1)
        globe.sunVector = globe.sunFor(new Date(Date.UTC(2026, 9, 3, 13, 30)))   // 23:00 local
      if (i === 2) {
        globe.radius = win.radiusFor(60)
        globe.centerLat = -24.33
        globe.centerLon = 134.45
        air.spritePx = 9
      }
    }
  }
}
