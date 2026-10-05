import QtQuick
import QtQuick.Window
import "../.."
import "../../Model.js" as Model

// GlobeView with a stand-in service fed by real flightline-feed output
// (globeview.sh builds the fixtures). Args after the out dir:
//   <scene> <fixture dir> [seconds]
// Scenes:
//   world     the whole globe at the fixture's time, city names, no aircraft labels
//   europe    400 NM over London: glyphs, aircraft labels, the in-view count
//   sparse    400 NM between Alice Springs and SIA248 (ADL-SIN): home ring in a
//             sparse sky, the selected aircraft with its route, the hover card;
//             then 60 NM on the aircraft
//   drag      no PNGs: drags the globe by hand for <seconds> and prints frames,
//             so globeview.sh can measure CPU per frame
//   dragroute the same with JFK-LHR selected and its route drawn
//   idle      no PNGs: counts frames while nobody touches it, 10 s on the whole
//             world, then 6 s at 400 NM over London (frame pacing budgets)
//   interact  no PNGs: wheel zoom keeps the point under the cursor, a click
//             picks the sprite under it, fly-to lands, follow keeps the
//             selected aircraft centred; prints PASS / FAIL lines
//   hover     no PNGs: the GUI-thread cost of the first hover after a new
//             revision, once the view sat idle for a second (world and 400 NM)
//   labels    label-dense views (labels-fixture.py traffic): London 60 NM,
//             400 NM over London, New York 40 NM, the whole globe (cities at
//             the limb) and London 60 NM with a hovered aircraft
//   route     JFK-LHR, SYD-LAX and GRU-LIS with the aircraft 40 % along, each
//             at globe, region (600 NM) and deep (15 NM) zoom
Window {
  id: win
  width: 620
  height: 540
  visible: true
  color: tints.background

  readonly property string scene: shots.args[1] || "world"
  readonly property int seconds: Number(shots.args[3]) || 10
  property int frames: 0
  onFrameSwapped: frames++

  // Tokyo Night, as the panel derives it; THEME=latte or THEME=gruvbox
  // (globeview.sh) for a light and a warm theme.
  readonly property string theme: (shots.args.filter(function(a) { return a.indexOf("theme=") === 0 })[0] || "theme=").slice(6)
  GlobePalette {
    id: tints
    foreground: win.theme === "latte" ? "#4c4f69" : win.theme === "gruvbox" ? "#ebdbb2" : "#c0caf5"
    background: win.theme === "latte" ? "#eff1f5" : win.theme === "gruvbox" ? "#282828" : "#1a1b26"
    accent: win.theme === "latte" ? "#1e66f5" : win.theme === "gruvbox" ? "#d79921" : "#7aa2f7"
    muted: win.theme === "latte" ? "#8c8fa1" : win.theme === "gruvbox" ? "#928374" : "#565f89"
    urgent: win.theme === "latte" ? "#d20f39" : win.theme === "gruvbox" ? "#fb4934" : "#f7768e"
  }

  FakeService {
    id: service
    dir: shots.args[2] || ""
    mode: win.scene === "world" ? "world" : "region"
  }

  // A minimal places list (the panel reads assets/places.json).
  property var places: []
  Component.onCompleted: {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState === XMLHttpRequest.DONE) win.places = JSON.parse(xhr.responseText).places
    }
    xhr.open("GET", Qt.resolvedUrl("../../assets/places.json"))
    xhr.send()
  }

  GlobeView {
    id: view
    anchors.fill: parent
    service: service
    tints: tints
    places: win.places
    units: "aviation"
    // The label and route scenes put home at a public landmark in their own views.
    readonly property bool greenwich: win.scene === "labels" || win.scene === "route" || win.scene === "dragroute"
    homeLat: greenwich ? 51.4769 : -23.80
    homeLon: greenwich ? -0.0005 : 133.90
    homeRingNm: greenwich ? 25 : 100
    homeName: greenwich ? "Greenwich" : "Alice Springs"
    property int settles: 0
    onViewSettled: function(lat, lon, nm) {
      settles++
      console.info("settled", lat.toFixed(2), lon.toFixed(2), Math.round(nm) + " NM", "in view", inViewCount)
    }
  }

  Shots {
    id: shots
    target: view
    ready: view.ready && view.shownCount > 0 && win.places.length > 0 && names.length > 0
    names: win.scene === "world" ? ["gv-world.png", "gv-world-night.png"]
         : win.scene === "europe" ? ["gv-europe.png"]
         : win.scene === "sparse" ? ["gv-sparse.png", "gv-sparse-60nm.png"]
         : win.scene === "labels" ? ["gv-labels-london60.png", "gv-labels-europe400.png", "gv-labels-newyork40.png",
                                     "gv-labels-globe.png", "gv-labels-london60-hover.png"]
         : win.scene === "route" ? win.routeShots() : []
    onPrepare: function(i) {
      if (win.scene === "world") {
        view.setView(i === 0 ? 20 : 5, i === 0 ? -30 : 100, 6000)
      } else if (win.scene === "europe") {
        view.setView(51.47, -0.45, 400)
      } else if (win.scene === "labels") {
        view.hoverAt(-1, -1)
        var views = [[51.5, -0.12, 60], [51.47, -0.45, 400], [40.71, -74.0, 40], [30, -20, 6000], [51.5, -0.12, 60]]
        view.setView(views[i][0], views[i][1], views[i][2])
        if (i === 4) hover.restart()
      } else if (win.scene === "route") {
        var r = win.routes[Math.floor(i / 3)], z = i % 3
        view.selectedHex = r.hex
        view.route = { origin: r.origin, destination: r.destination }
        view.routeVisible = true
        var at = view.selectedPos
        if (z === 0) {
          var mid = Model.slerpLonLat(r.origin.lat, r.origin.lon, r.destination.lat, r.destination.lon, 0.5)
          view.setView(mid.lat, mid.lon, 6000)
        } else {
          view.setView(at.lat, at.lon, z === 1 ? 600 : 15)
        }
      } else if (win.scene === "sparse") {
        view.selectedHex = "76cd08"           // SIA248, north-west out of Adelaide
        view.route = { origin: { code: "ADL", lat: -34.9450, lon: 138.5306 },
                       destination: { code: "SIN", lat: 1.3644, lon: 103.9915 } }
        view.routeVisible = true
        if (i === 0) view.setView(-26.8, 134.8, 400)
        else view.setView(view.selectedPos.lat, view.selectedPos.lon, 60)
        hover.restart()
      }
    }
  }

  // labels-fixture.py's route aircraft.
  readonly property var routes: [
    { name: "jfklhr", hex: "~0f1001", origin: { code: "JFK", lat: 40.6413, lon: -73.7781 }, destination: { code: "LHR", lat: 51.4700, lon: -0.4543 } },
    { name: "sydlax", hex: "~0f1002", origin: { code: "SYD", lat: -33.9399, lon: 151.1753 }, destination: { code: "LAX", lat: 33.9416, lon: -118.4085 } },
    { name: "grulis", hex: "~0f1003", origin: { code: "GRU", lat: -23.4356, lon: -46.4731 }, destination: { code: "LIS", lat: 38.7742, lon: -9.1342 } }
  ]
  function routeShots() {
    var out = []
    for (var i = 0; i < routes.length; i++)
      out.push("gv-route-" + routes[i].name + "-globe.png", "gv-route-" + routes[i].name + "-region.png", "gv-route-" + routes[i].name + "-deep.png")
    return out
  }

  // Hover the visible aircraft nearest the middle that is not the selected one.
  Timer {
    id: hover
    interval: 150
    onTriggered: {
      var pos = view.positions()
      var best = -1, bestD = 1e9
      for (var k = 0; pos && k < pos.ok.length; k++) {
        if (!pos.ok[k] || k === view.selectedIndex) continue
        if (pos.x[k] < 40 || pos.y[k] < 60 || pos.x[k] > view.width - 200 || pos.y[k] > view.height - 40) continue
        var d = Math.hypot(pos.x[k] - view.width / 2, pos.y[k] - view.height / 2)
        if (d < bestD) { best = k; bestD = d }
      }
      if (best >= 0) {
        view.hoverX = pos.x[best]
        view.hoverY = pos.y[best]
        view.hoverNow()
        console.info("hovered", best, view.hoveredIndex, JSON.stringify(view.rowAt(best).cs))
      }
      console.info("selected", view.selectedIndex, view.selectedRow ? view.selectedRow.cs : "-",
                   "pos", view.selectedPos ? view.selectedPos.lat.toFixed(3) + "," + view.selectedPos.lon.toFixed(3) : "-")
    }
  }

  // ------------------------------------------------------ interact scene
  property bool interactReady: view.ready && view.shownCount > 0 && win.places.length > 0 && win.scene === "interact"
  property var picks: []
  Connections {
    target: view
    function onPicked(index) { win.picks.push(index) }
  }
  function check(name, ok, detail) { console.info((ok ? "PASS " : "FAIL ") + name + (detail ? "  " + detail : "")) }
  onInteractReadyChanged: if (interactReady) {
    view.setView(51.47, -0.45, 400)
    interact.step = 0
    interact.restart()
  }
  Timer {
    id: interact
    property int step: 0
    property var before: null
    interval: 300
    onTriggered: {
      if (step === 0) {
        // Wheel zoom towards a point off-centre.
        before = view.unproject(150, 120)
        view.zoomAt(150, 120, 2.5)
        step = 1
        interval = 1200
      } else if (step === 1) {
        var after = view.unproject(150, 120)
        var km = Model.distanceKm(before.lat, before.lon, after.lat, after.lon)
        win.check("wheel zoom keeps the point under the cursor", !view.animating && km < 0.5, km.toFixed(3) + " km")
        // Click on a sprite.
        var pos = view.positions()
        var k = -1
        for (var i = pos.ok.length - 1; i >= 0; i--)
          if (pos.ok[i] && pos.x[i] > 100 && pos.y[i] > 100 && pos.x[i] < view.width - 100 && pos.y[i] < view.height - 100) { k = i; break }
        view.beginDrag(pos.x[k] + 2, pos.y[k] - 1)
        view.endDrag(pos.x[k] + 2, pos.y[k] - 1)
        win.check("a click picks the sprite under it", win.picks[win.picks.length - 1] === k, "k=" + k + " picked=" + win.picks[win.picks.length - 1])
        view.beginDrag(5, 5)
        view.endDrag(5, 5)
        win.check("a click on empty sky picks nothing", win.picks[win.picks.length - 1] === -1)
        // Idle ticks later the positions are not projected again; picking
        // re-checks its candidates at the new clock.
        view.nowMs += 20000
        var later = view.screenNow(view.store.prep, k, Model.viewMatrix(view.centerLon, view.centerLat))
        var moved = Math.hypot(later.x - pos.x[k], later.y - pos.y[k])
        view.beginDrag(later.x, later.y)
        view.endDrag(later.x, later.y)
        win.check("20 s later a click still picks it where it is drawn", win.picks[win.picks.length - 1] === k && view.positions() === pos,
                  "moved " + moved.toFixed(1) + " px, picked " + win.picks[win.picks.length - 1])
        // Fly across the Atlantic.
        win.settlesBefore = view.settles
        view.flyTo(40.64, -73.78, 300, 900)
        step = 2
        interval = 1500
      } else if (step === 2) {
        win.check("fly-to lands on target", !view.animating && Math.abs(view.centerLat - 40.64) < 1e-6 && Math.abs(view.centerLon + 73.78) < 1e-6
                  && Math.abs(view.visibleRadiusNm - 300) < 0.5, view.centerLat.toFixed(4) + "," + view.centerLon.toFixed(4) + " " + view.visibleRadiusNm.toFixed(1) + " NM")
        win.check("one settle per fly-to", view.settles - win.settlesBefore === 1, String(view.settles - win.settlesBefore))
        // Follow the fastest mover in view.
        var m = service.meta()
        var best = -1
        for (var j = 0; j < m.n; j++)
          if (m.gs[j] > 400 && m.trk[j] !== null && Model.distanceKm(m.lat[j], m.lon[j], 40.64, -73.78) < 300 && (300 - m.t[j]) < 30) { best = j; break }
        view.selectedHex = m.hex[best]
        view.following = true
        win.check("selection resolves by hex", view.selectedIndex === best, m.cs[best])
        view.flyTo(view.selectedPos.lat, view.selectedPos.lon, 60, 300)
        step = 3
        interval = 4000
      } else if (step === 3) {
        var p = view.selectedPos
        win.check("follow keeps the aircraft centred", view.following && Math.abs(view.centerLat - p.lat) < 1e-9 && Math.abs(view.centerLon - p.lon) < 1e-9,
                  "clock " + view.clockInterval + " ms")
        view.beginDrag(300, 300)
        view.dragTo(340, 300)
        view.endDrag(340, 300)
        win.check("dragging stops following", !view.following)
        // A drag whose release never comes: the grab is cancelled (what
        // MouseArea.onCanceled does), or the panel closes mid-drag.
        view.beginDrag(300, 300)
        view.dragTo(340, 310)
        view.cancelDrag()
        view.beginDrag(200, 200)
        view.active = false
        view.active = true
        win.framesBefore = win.frames
        step = 4
        interval = 1500
      } else if (step === 4) {
        win.check("a cancelled drag lets the camera settle", !view.animating && !view.dragging,
                  (win.frames - win.framesBefore) + " frames in 1.5 s")
        win.check("and the frame loop stops", win.frames - win.framesBefore < 10, String(win.frames - win.framesBefore))
        Qt.quit()
        return
      }
      restart()
    }
  }
  property int settlesBefore: 0
  property int framesBefore: 0

  // --------------------------------------------------------- hover scene
  // A new revision arrives, nobody touches the view for a second, then the
  // mouse lands on a sprite: how long does that first hoverNow() block?
  property bool hoverReady: view.ready && view.shownCount > 0 && win.places.length > 0 && win.scene === "hover"
  onHoverReadyChanged: if (hoverReady) {
    firstHover.round = 0
    firstHover.phase = 0
    firstHover.restart()
  }
  Timer {
    id: firstHover
    property int round: 0                     // 0-3 world view, 4-7 at 400 NM over London
    property int phase: 0
    property real px: -1
    property real py: -1
    property var times: []
    interval: 500
    onTriggered: {
      if (phase === 0) {
        // Aim at a sprite near the middle with the current revision.
        if (round === 0) view.setView(48, 5, 6000)
        if (round === 4) view.setView(51.47, -0.45, 400)
        var pos = view.positions()
        var best = -1, bestD = 1e9
        for (var k = 0; pos && k < pos.ok.length; k++) {
          if (!pos.ok[k]) continue
          var d = Math.hypot(pos.x[k] - view.width / 2, pos.y[k] - view.height / 2)
          if (d < bestD) { best = k; bestD = d }
        }
        px = best >= 0 ? pos.x[best] : view.width / 2
        py = best >= 0 ? pos.y[best] : view.height / 2
        view.hoverAt(-1, -1)
        service.bump()
        phase = 1
        interval = 1500                     // the texture swaps, then idle time
      } else {
        var t0 = Date.now()
        view.hoverX = px
        view.hoverY = py
        view.hoverNow()
        var ms = Date.now() - t0
        times.push(ms)
        console.info("first hover after a new revision (" + (round < 4 ? "world" : "400 NM") + "):", ms, "ms, hovered", view.hoveredIndex)
        if (round === 3 || round === 7) {
          var part = times.slice(round - 3, round + 1)
          console.info("  mean", (part.reduce(function(a, b) { return a + b }, 0) / part.length).toFixed(1), "ms over", part.length)
        }
        if (++round >= 8) {
          Qt.quit()
          return
        }
        phase = 0
        interval = 300
      }
      restart()
    }
  }

  // ---------------------------------------------------------- idle scene
  property bool idleReady: view.ready && view.shownCount > 0 && win.places.length > 0 && win.scene === "idle"
  onIdleReadyChanged: if (idleReady) {
    view.setView(20, -30, 6000)
    idle.phase = 0
    idle.restart()
  }
  Timer {
    id: idle
    property int phase: 0
    property int start: 0
    interval: 1000                            // let the settle frames pass first
    onTriggered: {
      if (phase === 0) {
        start = win.frames
        phase = 1
        interval = 10000
        console.info("idle world: clock interval", view.clockInterval, "ms")
      } else if (phase === 1) {
        console.info("idle world: frames in 10 s", win.frames - start)
        view.setView(51.47, -0.45, 400)
        phase = 2
        interval = 1000
      } else if (phase === 2) {
        start = win.frames
        phase = 3
        interval = 6000
        console.info("idle europe: clock interval", view.clockInterval, "ms")
      } else {
        console.info("idle europe: frames in 6 s", win.frames - start)
        Qt.quit()
        return
      }
      restart()
    }
  }

  // ---------------------------------------------------------- drag scene
  // Synthetic mouse: press, then move in a circle every frame, like a user
  // spinning the globe, for `seconds`.
  property bool dragReady: view.ready && view.shownCount > 0 && win.places.length > 0
                           && (win.scene === "drag" || win.scene === "dragroute")
  onDragReadyChanged: if (dragReady) {
    if (win.scene === "dragroute") {
      view.selectedHex = win.routes[0].hex
      view.route = { origin: win.routes[0].origin, destination: win.routes[0].destination }
      view.routeVisible = true
    }
    view.setView(30, -20, 2500)
    view.beginDrag(310, 270)
    dragClock.start()
    report.start()
  }
  FrameAnimation {
    id: dragClock
    running: false
    onTriggered: view.dragTo(310 + 120 * Math.sin(elapsedTime * 0.9), 270 + 60 * Math.sin(elapsedTime * 1.3))
  }
  Timer {
    id: report
    interval: 1000
    repeat: true
    property int n: 0
    property int last: 0
    onTriggered: {
      console.info("bench fps", win.frames - last, "aircraft", view.shownCount, "animating", view.animating)
      last = win.frames
      if (++n >= win.seconds) {
        view.endDrag(310, 270)
        Qt.quit()
      }
    }
  }
}
