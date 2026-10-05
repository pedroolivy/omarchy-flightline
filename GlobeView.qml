pragma ComponentBehavior: Bound

import QtQuick
import "Model.js" as Model

// The globe lens: camera, input, labels and picking around the GPU layers.
// Globe.qml draws the Earth, Aircraft.qml every aircraft and RouteArc.qml the
// selected flight's route; this item only moves their uniforms, so a drag is
// a few property writes a frame.
//
// Frame pacing (docs/ARCHITECTURE.md "Frame pacing"): a FrameAnimation runs
// only while the camera moves (drag, inertia, zoom easing, fly-to). Otherwise
// one Timer advances the aircraft clock, as rarely as the fastest aircraft
// needs to move half a pixel. Nothing else here may cause a frame.
//
// Per-aircraft JavaScript (picking, labels, the in-view count) runs on settle,
// on a new data revision and on hover, never per frame. Positions are
// dead-reckoned exactly like aircraft.vert (Model.reckon), so a click lands
// on the sprite under the cursor.
//
// Imports QtQuick only: colours, fonts and the service come in as
// properties, so the view renders offscreen in tests (tests/offscreen/).
Item {
  id: root

  // ------------------------------------------------------------- inputs
  property var service: null              // Service.qml, or a stand-in with the same API
  property bool active: true              // textures and clocks only while true (panel open)
  property var places: []                 // assets/places.json rows: [name, lat, lon, minZoom, capital]
  property string units: "metric"
  property string selectedHex: ""         // the selection survives revisions by hex
  property bool following: false          // keep the selected aircraft in the middle
  property var route: null                // { origin, destination } with lat/lon
  property bool routeVisible: false       // the panel decides whether the route is plausible

  property real homeLat: NaN
  property real homeLon: NaN
  property real homeRingNm: 0             // <= 0: no home
  property string homeName: ""

  property bool showLabels: true
  property bool showGraticule: true
  property bool showBorders: true
  property bool showNight: true
  property bool showLights: true
  property bool showRelief: true          // terrain: hillshade, snow, sea-floor depth, isobaths
  property bool showStars: true           // around the disc, dark themes only
  property bool showTrails: true          // comet tails behind airborne aircraft
  property bool showShadows: true         // altitude shadows under the glyphs at region zoom

  // ------------------------------------------------------------ colours
  // Derived from the theme by GlobePalette; any single one can be overridden.
  property GlobePalette tints: GlobePalette {}
  property color spaceColor: tints.space
  property color oceanColor: tints.ocean
  property color landColor: tints.land
  property color coastColor: tints.coast
  property color borderColor: tints.border
  property color gridColor: tints.grid
  property color glowColor: tints.glow
  property color lightsColor: tints.lights
  property color homeColor: tints.home
  property color routeColor: tints.route
  property color routeRestColor: tints.routeRest
  property color liveColor: tints.live
  property color shelfColor: tints.shelf
  property color deepColor: tints.deep
  property color highlandColor: tints.highland
  property color snowColor: tints.snow
  property color shadeColor: tints.shade
  property color sheenColor: tints.sheen
  property color twilightColor: tints.twilight
  property color isobathColor: tints.isobath
  property color glintColor: tints.glint
  property color starColor: tints.star
  property color groundColor: tints.ground
  property color lowColor: tints.low
  property color midColor: tints.mid
  property color highColor: tints.high
  property color selectedColor: tints.selected
  property color emergencyColor: tints.emergency
  property color haloColor: tints.halo
  property color shadowColor: tints.shadow
  property color labelColor: tints.label
  property color labelDimColor: tints.labelDim
  property color cityColor: tints.city
  property color labelHaloColor: tints.labelHalo
  property color tooltipColor: tints.tooltip
  property color tooltipTextColor: tints.tooltipText
  property color tooltipBorderColor: tints.tooltipBorder
  property string fontFamily: "monospace"
  property int fontSize: 11
  property int smallFontSize: 10

  // ------------------------------------------------------------- camera
  property real centerLat: 0
  property real centerLon: 0
  property real radius: fitRadius                      // globe radius, px
  readonly property real halfDiagonal: Math.sqrt(width * width + height * height) / 2
  readonly property real fitRadius: Math.max(40, Math.min(width, height) * 0.42)
  readonly property real maxRadius: Model.radiusForVisibleNm(12, halfDiagonal, fitRadius)
  readonly property real visibleRadiusNm: Model.visibleRadiusNm(radius, halfDiagonal)
  readonly property real spritePx: Model.spritePxFor(visibleRadiusNm)
  // True from the first camera frame to the settle; labels hide meanwhile.
  property bool animating: false

  // ---------------------------------------------------- outputs (read only)
  property int selectedIndex: -1          // index of selectedHex in the texture on screen
  property var selectedRow: null          // its meta row (Model.metaRow shape), null when gone
  property var selectedPos: null          // { lat, lon } dead-reckoned to `nowMs`
  property int hoveredIndex: -1
  property int inViewCount: -1            // airborne aircraft on screen; -1 when not counted
  property double nowMs: Date.now()       // the aircraft clock; changes only on frames and ticks
  property int shownRev: 0                // service revision whose texture is on screen
  readonly property int clockInterval: clock.interval
  readonly property int shownCount: air.texCount
  readonly property bool ready: globe.ready

  signal viewSettled(real lat, real lon, real visibleRadiusNm)
  signal picked(int index)                // -1: empty space
  signal userMoved()

  // ---------------------------------------------------------- the layers
  // Back to front (docs/ARCHITECTURE.md "Layers"): Globe (stars, sea floor,
  // relief, coast and borders, night and lights, atmosphere, home and live
  // rings), Aircraft (its shadows and trails under the sprites, the selected
  // and hovered ones on top), RouteArc, then the labels and the hover card.
  Globe {
    id: globe
    anchors.fill: parent
    active: root.active
    centerLat: root.centerLat
    centerLon: root.centerLon
    radius: root.radius
    sunVector: sunFor(new Date(root.sunMs))
    nightStrength: root.tints.night
    spaceColor: root.spaceColor
    oceanColor: root.oceanColor
    landColor: root.landColor
    coastColor: root.coastColor
    borderColor: root.borderColor
    gridColor: root.gridColor
    glowColor: root.glowColor
    lightsColor: root.lightsColor
    homeColor: root.homeColor
    liveColor: root.liveColor
    shelfColor: root.shelfColor
    deepColor: root.deepColor
    highlandColor: root.highlandColor
    snowColor: root.snowColor
    shadeColor: root.shadeColor
    sheenColor: root.sheenColor
    twilightColor: root.twilightColor
    isobathColor: root.isobathColor
    glintColor: root.glintColor
    starColor: root.starColor
    showGraticule: root.showGraticule
    showBorders: root.showBorders
    showNight: root.showNight
    showLights: root.showLights
    showRelief: root.showRelief
    showStars: root.showStars && !root.tints.light
    homeLat: Model.finite(root.homeLat) ? root.homeLat : 0
    homeLon: Model.finite(root.homeLon) ? root.homeLon : 0
    homeRingNm: Model.isValidLatLon(root.homeLat, root.homeLon) ? Math.max(root.homeRingNm, 0.01) : 0
    // The live-data boundary: what the last answer covered (none in world mode).
    readonly property var live: root.service && root.service.mode !== "home" ? root.service.lastQuery : null
    liveLat: live ? live.lat : 0
    liveLon: live ? live.lon : 0
    liveRadiusNm: live ? live.radiusNm : 0
  }

  Aircraft {
    id: air
    anchors.fill: parent
    centerLat: root.centerLat
    centerLon: root.centerLon
    radius: root.radius
    spritePx: root.spritePx
    source: root.service ? root.service.trafficPath : ""
    time: (root.nowMs - epochMs) / 1000
    // World answers come every 60 s and take a while to download, so their
    // aircraft keep moving a little longer before they fade.
    maxAge: root.service && root.service.lastQuery && root.service.lastQuery.radiusNm >= Model.WORLD_RADIUS_NM
      ? Model.WORLD_MAX_AGE_S : Model.LIVE_MAX_AGE_S
    selectedIndex: root.selectedIndex
    hoveredIndex: root.hoveredIndex
    groundColor: root.groundColor
    lowColor: root.lowColor
    midColor: root.midColor
    highColor: root.highColor
    selectedColor: root.selectedColor
    emergencyColor: root.emergencyColor
    haloColor: root.haloColor
    shadowColor: root.shadowColor
    showTrails: root.showTrails
    showShadows: root.showShadows
    onTexEpochMsChanged: root.textureShown()
  }
  // New revisions load only while the panel is open; the last one stays put.
  Binding { target: air; property: "epochMs"; value: root.service ? root.service.epochMs : 0; when: root.active; restoreMode: Binding.RestoreNone }
  Binding { target: air; property: "count"; value: root.service ? root.service.trafficCount : 0; when: root.active; restoreMode: Binding.RestoreNone }
  Binding { target: air; property: "revision"; value: root.service ? root.service.trafficRev : 0; when: root.active; restoreMode: Binding.RestoreNone }

  // ------------------------------------------------------------- route
  // The selected flight's route, above the aircraft and below the labels. It
  // replaces Globe's built-in arc, which stays off.
  readonly property bool routeShown: routeVisible && selectedPos !== null && Model.routeHasCoordinates(route)
  RouteArc {
    id: routeArc
    anchors.fill: parent
    shown: root.routeShown && root.active
    centerLat: root.centerLat
    centerLon: root.centerLon
    radius: root.radius
    fromLat: root.routeShown ? root.route.origin.lat : 0
    fromLon: root.routeShown ? root.route.origin.lon : 0
    atLat: root.routeShown ? root.selectedPos.lat : 0
    atLon: root.routeShown ? root.selectedPos.lon : 0
    toLat: root.routeShown ? root.route.destination.lat : 0
    toLon: root.routeShown ? root.route.destination.lon : 0
    gapPx: root.ringGap()                 // clear of the selected sprite's ring
    flownColor: root.routeColor
    restColor: root.routeRestColor
    haloColor: root.haloColor
  }

  // ------------------------------------------------------------ labels
  FontMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }
  FontMetrics {
    id: boldMetrics
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.bold: true
  }
  FontMetrics {
    id: smallMetrics
    font.family: root.fontFamily
    font.pixelSize: root.smallFontSize
  }
  FontMetrics {
    id: smallBoldMetrics
    font.family: root.fontFamily
    font.pixelSize: root.smallFontSize
    font.bold: true
  }

  readonly property bool labelsShown: showLabels && active && !animating

  // Pooled: text and positions are written from JS on settle and with the
  // clock. Places are cities, home and the route's airports, anchored on the
  // spot itself (a dot for cities; Globe and RouteArc draw the other marks)
  // with the text on whichever side the layout chose.
  Item {
    id: placeLayer
    anchors.fill: parent
    visible: root.labelsShown
    Repeater {
      id: placeLabels
      model: 27                           // 24 cities, home, 2 airports
      delegate: Item {
        id: place
        required property int index
        property string text: ""
        property string kind: "city"      // city | home | airport
        property real tx: 0               // text box, relative to the anchor
        property real ty: 0
        visible: false
        Rectangle {
          visible: place.kind === "city"
          x: -1.5
          y: -1.5
          width: 3
          height: 3
          radius: 1.5
          color: root.cityColor
        }
        Text {
          x: place.tx
          y: place.ty
          text: place.text
          textFormat: Text.PlainText
          color: place.kind === "home" ? root.homeColor : (place.kind === "airport" ? root.routeColor : root.cityColor)
          font.family: root.fontFamily
          font.pixelSize: root.smallFontSize
          font.bold: place.kind !== "city"
          style: Text.Outline
          styleColor: root.labelHaloColor
        }
      }
    }
  }

  Item {
    id: flightLayer
    anchors.fill: parent
    visible: root.labelsShown
    Repeater {
      id: flightLabels
      model: 12
      delegate: Row {
        id: tag
        required property int index
        property int k: -1                // aircraft index in the texture on screen
        property string name: ""
        property string level: ""
        property bool chosen: false
        property bool alert: false
        property real fade: 1             // near the limb
        visible: false
        // The hover card says the same and more, next to the cursor.
        opacity: k === root.hoveredIndex && tip.visible ? 0 : fade
        spacing: 4
        Text {
          text: tag.name
          textFormat: Text.PlainText
          color: tag.alert ? root.emergencyColor : (tag.chosen ? root.selectedColor : root.labelColor)
          font.family: root.fontFamily
          font.pixelSize: root.fontSize
          font.bold: tag.chosen || tag.alert
          style: Text.Outline
          styleColor: root.labelHaloColor
        }
        Text {
          anchors.baseline: parent.children[0].baseline
          visible: tag.level !== ""
          text: tag.level
          textFormat: Text.PlainText
          color: root.labelDimColor
          font.family: root.fontFamily
          font.pixelSize: root.smallFontSize
          style: Text.Outline
          styleColor: root.labelHaloColor
        }
      }
    }
  }

  // Hover card: callsign · type · altitude, next to the cursor on the first
  // side that leaves the labels readable (placeTip).
  Rectangle {
    id: tip
    property string text: ""
    visible: text !== "" && root.hoveredIndex >= 0 && !root.animating
    width: tipText.implicitWidth + 12
    height: tipText.implicitHeight + 6
    color: root.tooltipColor
    border.color: root.tooltipBorderColor
    border.width: 1
    Text {
      id: tipText
      anchors.centerIn: parent
      text: tip.text
      textFormat: Text.PlainText
      color: root.tooltipTextColor
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
    }
  }

  // ------------------------------------------------------------- input
  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: root.active
    acceptedButtons: Qt.LeftButton
    cursorShape: root.dragging ? Qt.ClosedHandCursor : (root.hoveredIndex >= 0 ? Qt.PointingHandCursor : Qt.OpenHandCursor)
    onPressed: function(m) { root.beginDrag(m.x, m.y) }
    onPositionChanged: function(m) {
      if (pressed) root.dragTo(m.x, m.y)
      else root.hoverAt(m.x, m.y)
    }
    onReleased: function(m) { root.endDrag(m.x, m.y) }
    // The grab went elsewhere (the panel closed with the button held, a popup).
    onCanceled: root.cancelDrag()
    onDoubleClicked: function(m) { root.zoomAt(m.x, m.y, 2) }
    onWheel: function(w) { root.zoomAt(w.x, w.y, Math.pow(2, w.angleDelta.y / 480)) }
    onExited: root.hoverAt(-1, -1)
  }

  // ------------------------------------------------------------- clocks
  // Moving: one camera step per frame. Still: the idle clock below.
  FrameAnimation {
    running: root.animating && root.active
    onTriggered: root.step(frameTime)
  }

  Timer {
    id: clock
    // At least 1 s: at deep zoom a 1 s step is ~1.3 px for the fastest jet,
    // which nobody sees, and the "≤ 2 frames / s" budget keeps its margin.
    interval: Model.idleTickMs(root.service ? root.service.maxGs : 0, root.radius, 1000, 30000)
    repeat: true
    running: root.active && root.visible && !root.animating && air.texCount > 0
    onTriggered: root.tick()
  }

  // Hover picking at most every 33 ms; runs only while the mouse moves.
  Timer {
    id: hoverTimer
    interval: 33
    onTriggered: root.hoverNow()
  }

  // Idle warm-up: once nothing moved and nobody touched the view for 300 ms,
  // parse the revision's meta and project its aircraft, so the first hover or
  // click after new data finds them ready instead of blocking for ~30 ms.
  // Draws nothing, so it costs no frame.
  property double lastInputMs: 0
  Timer {
    id: warmTimer
    interval: 300
    onTriggered: root.warm()
  }

  // The sun moves a quarter degree a minute; refreshing it with every tick
  // would only add frames.
  property double sunMs: Date.now()

  onActiveChanged: {
    if (!active) {
      // Closing mid-gesture must not leave the FrameAnimation armed.
      stopMotion()
      cancelDrag()
      animating = false
      hoveredIndex = -1
      return
    }
    nowMs = Date.now()
    sunMs = nowMs
    Qt.callLater(settle)
  }
  onVisibleChanged: if (visible && active) Qt.callLater(settle)
  onFitRadiusChanged: if (radius < fitRadius) radius = fitRadius
  onWidthChanged: Qt.callLater(layoutLabels)
  onHeightChanged: Qt.callLater(layoutLabels)
  onShowLabelsChanged: Qt.callLater(layoutLabels)
  onPlacesChanged: cityVecs = null
  // Label boxes are measured once per text; a new font invalidates them all.
  onFontFamilyChanged: relayoutFont()
  onFontSizeChanged: relayoutFont()
  function relayoutFont() {
    store.widths = {}
    store.widthCount = 0
    Qt.callLater(layoutLabels)
  }
  onSelectedHexChanged: {
    resolveSelection()
    Qt.callLater(layoutLabels)
  }
  onUnitsChanged: Qt.callLater(layoutLabels)

  // ======================================================== camera API

  // Jump without animation; `visibleNm` <= 0 keeps the zoom. `quiet` skips
  // viewSettled, for a view that is only passed through (the intro).
  function setView(lat, lon, visibleNm, quiet) {
    stopMotion()
    if (visibleNm > 0) radius = radiusFor(visibleNm)
    setCentre(lat, lon)
    if (quiet) layoutLabels()
    else settle()
  }

  // Glide along the great circle to (lat, lon), easing the zoom to show
  // `visibleNm` around it (<= 0 keeps the zoom).
  function flyTo(lat, lon, visibleNm, ms) {
    if (!Model.isValidLatLon(lat, Model.wrapLon(lon))) return
    if (!(ms > 16) || width <= 0) {
      setView(lat, lon, visibleNm)
      return
    }
    stopMotion()
    var r1 = visibleNm > 0 ? radiusFor(visibleNm) : radius
    flight = {
      lat0: centerLat, lon0: centerLon, r0: radius,
      lat1: lat, lon1: Model.wrapLon(lon), r1: r1,
      angle: Model.distanceKm(centerLat, centerLon, lat, lon) / Model.EARTH_RADIUS_KM,
      startMs: Date.now(), ms: ms
    }
    animating = true
  }

  // Zoom around the middle (or the followed aircraft), eased.
  function zoomBy(factor) {
    zoomAt(width / 2, height / 2, factor)
  }

  // Move the picture by (dx, dy) px, as if dragged; keys use this.
  function panBy(dx, dy) {
    var lat = Model.clamp(centerLat + dy / radius / Model.DEG, -85, 85)
    var lon = centerLon - dx / (radius * Math.max(0.05, Math.cos(centerLat * Model.DEG))) / Model.DEG
    following = false
    flyTo(lat, lon, 0, 160)
  }

  function radiusFor(visibleNm) {
    return Model.clamp(Model.radiusForVisibleNm(visibleNm, halfDiagonal, fitRadius), fitRadius, maxRadius)
  }

  // Camera state (bookkeeping, nothing binds to it).
  property var flight: null               // fly-to in progress
  property var inertia: null              // { vx, vy, startMs } after a flick
  property real zoomTarget: 0             // eased zoom target radius, 0 = none
  property var zoomAnchor: null           // { lat, lon, x, y }: stays under the cursor
  property bool dragging: false
  property var drag: null                 // { grab, pressX, pressY, lastX, lastY, moved, samples }
  property double lastSettleMs: 0

  function setCentre(lat, lon) {
    centerLat = Model.clamp(lat, -85, 85)
    centerLon = Model.wrapLon(lon)
  }

  function stopMotion() {
    flight = null
    inertia = null
    zoomTarget = 0
    zoomAnchor = null
  }

  function unproject(x, y) {
    return Model.unprojectUnit(Model.viewMatrix(centerLon, centerLat), (x - width / 2) / radius, -(y - height / 2) / radius)
  }

  function startAnimating() {
    if (!animating) {
      nowMs = Date.now()
      animating = true
    }
  }

  function step(dt) {
    nowMs = Date.now()
    dt = Math.min(Math.max(dt, 0), 0.05)
    var busy = dragging
    if (flight) busy = stepFlight() || busy
    if (inertia) busy = stepInertia(dt) || busy
    if (zoomTarget > 0) busy = stepZoom(dt) || busy
    updateSelectedPos()
    if (following && selectedPos && !dragging && !flight) setCentre(selectedPos.lat, selectedPos.lon)
    if (!busy) {
      animating = false
      settle()
    }
  }

  function stepFlight() {
    var f = flight
    var t = (Date.now() - f.startMs) / f.ms
    var e = Model.easeInOut(t)
    var c = Model.slerpLonLat(f.lat0, f.lon0, f.lat1, f.lon1, e)
    setCentre(c.lat, c.lon)
    radius = Model.clamp(Model.flightRadius(f.r0, f.r1, 2 * halfDiagonal, f.angle, e), fitRadius, maxRadius)
    if (t < 1) return true
    setCentre(f.lat1, f.lon1)
    radius = Model.clamp(f.r1, fitRadius, maxRadius)
    flight = null
    return false
  }

  // A flick keeps spinning for at most 600 ms, slowing down exponentially.
  function stepInertia(dt) {
    var k = Math.exp(-dt / 0.14)
    inertia.vx *= k
    inertia.vy *= k
    movePicture(inertia.vx * dt, inertia.vy * dt)
    if (Math.hypot(inertia.vx, inertia.vy) > 15 && Date.now() - inertia.startMs < 600) return true
    inertia = null
    return false
  }

  function stepZoom(dt) {
    var k = 1 - Math.exp(-dt / 0.09)
    var gap = Math.log(zoomTarget / radius)
    if (Math.abs(gap) < 0.003) radius = zoomTarget
    else radius = radius * Math.exp(gap * k)
    var a = zoomAnchor
    if (a && !following) {
      var c = Model.anchorView(a.lat, a.lon, (a.x - width / 2) / radius, -(a.y - height / 2) / radius)
      if (c) setCentre(c.lat, c.lon)
    }
    if (radius !== zoomTarget) return true
    zoomTarget = 0
    zoomAnchor = null
    return false
  }

  // Immediate move of the picture by (dx, dy) px.
  function movePicture(dx, dy) {
    var lat = Model.clamp(centerLat + dy / radius / Model.DEG, -85, 85)
    setCentre(lat, centerLon - dx / (radius * Math.max(0.05, Math.cos(centerLat * Model.DEG))) / Model.DEG)
  }

  function zoomAt(x, y, factor) {
    if (!(factor > 0) || width <= 0) return
    flight = null
    inertia = null
    var target = Model.clamp((zoomTarget > 0 ? zoomTarget : radius) * factor, fitRadius, maxRadius)
    if (Math.abs(target - radius) < 0.5 && zoomTarget === 0) return
    var p = following ? null : unproject(x, y)
    lastInputMs = Date.now()
    zoomTarget = target
    zoomAnchor = p ? { lat: p.lat, lon: p.lon, x: x, y: y } : null
    hoveredIndex = -1
    startAnimating()
  }

  // ---------------------------------------------------------------- drag
  function beginDrag(x, y) {
    stopMotion()
    hoverTimer.stop()
    lastInputMs = Date.now()
    dragging = true
    drag = { grab: unproject(x, y), pressX: x, pressY: y, lastX: x, lastY: y, moved: false,
             samples: [{ t: Date.now(), x: x, y: y }] }
    startAnimating()
  }

  function dragTo(x, y) {
    var d = drag
    if (!d) return
    if (!d.moved && Math.hypot(x - d.pressX, y - d.pressY) < 4) return
    if (!d.moved) {
      d.moved = true
      hoveredIndex = -1
      following = false
      userMoved()
    }
    // The grabbed point stays under the cursor; off the globe, plain panning.
    var c = d.grab ? Model.anchorView(d.grab.lat, d.grab.lon, (x - width / 2) / radius, -(y - height / 2) / radius) : null
    if (c && Math.abs(c.lat) <= 85) setCentre(c.lat, c.lon)
    else {
      movePicture(x - d.lastX, y - d.lastY)
      d.grab = unproject(x, y)
    }
    d.lastX = x
    d.lastY = y
    var now = Date.now()
    d.samples.push({ t: now, x: x, y: y })
    while (d.samples.length > 2 && now - d.samples[0].t > 80) d.samples.shift()
  }

  function cancelDrag() {
    drag = null
    dragging = false
    hoverTimer.stop()
  }

  function endDrag(x, y) {
    var d = drag
    drag = null
    dragging = false
    if (!d) return
    if (!d.moved) {
      picked(pickAt(x, y))
      return
    }
    var first = d.samples[0]
    var dt = (Date.now() - first.t) / 1000
    if (dt > 0.005 && Date.now() - d.samples[d.samples.length - 1].t < 60) {
      var vx = (x - first.x) / dt, vy = (y - first.y) / dt
      if (Math.hypot(vx, vy) > 60) inertia = { vx: vx, vy: vy, startMs: Date.now() }
    }
  }

  // ================================================== data and picking

  // The texture on screen changed: from here on, meta of that revision
  // describes what is drawn.
  property var pending: ({ rev: 0, epochMs: 0 })
  Connections {
    target: root.service
    function onTrafficRevChanged() {
      root.pending = { rev: root.service.trafficRev, epochMs: root.service.epochMs }
    }
  }
  onServiceChanged: pending = service ? { rev: service.trafficRev, epochMs: service.epochMs } : { rev: 0, epochMs: 0 }

  function textureShown() {
    var rev = air.texEpochMs === pending.epochMs ? pending.rev
      : (service && air.texEpochMs === service.epochMs ? service.trafficRev : -1)
    if (rev < 0) return
    shownRev = rev
    store.prep = null
    store.pos = null
    Qt.callLater(dataChanged)
  }

  function dataChanged() {
    resolveSelection()
    layoutLabels()
    if (hoveredIndex >= 0) hoveredIndex = -1
    warmTimer.restart()
  }

  function warm() {
    // Moving or hidden: settle() and becoming visible ask again.
    if (!active || !visible || animating || dragging) return
    var quiet = Date.now() - lastInputMs
    if (quiet < 300) {
      warmTimer.interval = 300 - quiet
      warmTimer.restart()
      return
    }
    warmTimer.interval = 300
    if (prepared()) positions()
  }

  // Per-revision columns as typed arrays, built once from meta, the screen
  // positions of the last pick and the label text widths. Plain members of
  // one object, so filling them from inside a binding (the panel's lists)
  // notifies nothing.
  readonly property var store: ({ prep: null, pos: null, widths: {}, widthCount: 0 })

  function prepared() {
    if (store.prep && store.prep.rev === shownRev) return store.prep
    var m = service && shownRev > 0 && service.trafficRev === shownRev ? service.meta() : null
    if (!m || Model.numberOr(m.rev, -1) !== shownRev) return null
    var n = Math.min(Model.intOr(m.n, 0), air.capacity)
    var p = {
      rev: shownRev, epochMs: Model.numberOr(m.epochMs, 0), n: n, meta: m,
      lat: new Float64Array(n), lon: new Float64Array(n), trk: new Float64Array(n),
      gs: new Float64Array(n), t: new Float64Array(n), flags: new Uint8Array(n),
      frame: new Float64Array(6 * n), speed: new Float64Array(n),  // Model.motionFrame, rad/s
      maxSpeed: 0
    }
    for (var k = 0; k < n; k++) {
      // meta.json holds numbers or null; anything else counts as missing.
      var la = m.lat[k], lo = m.lon[k], tr = m.trk[k], gs = m.gs[k], t = m.t[k]
      p.lat[k] = typeof la === "number" ? la : NaN
      p.lon[k] = typeof lo === "number" ? lo : NaN
      p.trk[k] = typeof tr === "number" ? tr : NaN
      p.gs[k] = typeof gs === "number" ? gs : 0
      p.t[k] = typeof t === "number" ? t : 0
      p.flags[k] = m.flags[k] & 255
      if (!(p.lat[k] === p.lat[k]) || !(p.lon[k] === p.lon[k])) continue
      // Model.motionFrame, inlined: this loop runs for every aircraft.
      var phi = p.lat[k] * Model.DEG, lam = p.lon[k] * Model.DEG, b = p.trk[k] === p.trk[k] ? p.trk[k] * Model.DEG : 0
      var sp = Math.sin(phi), cp = Math.cos(phi), sl = Math.sin(lam), cl = Math.cos(lam), sb = Math.sin(b), cb = Math.cos(b)
      var i = 6 * k
      p.frame[i] = cp * cl
      p.frame[i + 1] = cp * sl
      p.frame[i + 2] = sp
      p.frame[i + 3] = -sp * cl * cb - sl * sb
      p.frame[i + 4] = -sp * sl * cb + cl * sb
      p.frame[i + 5] = cp * cb
      // As in the texture: no track or no speed, no movement.
      p.speed[k] = p.trk[k] === p.trk[k] && p.gs[k] > 0 ? p.gs[k] * Model.KT_RAD_PER_S : 0
      if (p.speed[k] > p.maxSpeed) p.maxSpeed = p.speed[k]
    }
    store.prep = p
    return p
  }

  // Screen positions of every aircraft for the current camera, cached until
  // it moves; `ok` is 0 for hidden ones (behind the globe, faded out). `ms`
  // is the clock they were projected for. Labels ask for `exact` ones;
  // picking takes a set a few ticks old (aircraft creep at most `drift` px
  // since, and pickAt re-checks its candidates at the current clock), so a
  // hover after an idle tick does not re-project every aircraft.
  function positions(exact) {
    var p = prepared()
    if (!p) return null
    var key = p.rev + "|" + centerLat + "|" + centerLon + "|" + radius + "|" + width + "|" + height
    var pos = store.pos
    if (pos && pos.key === key && (pos.ms === nowMs || (!exact && drift(p, pos) <= 24))) return pos
    var m = Model.viewMatrix(centerLon, centerLat)
    var cx = width / 2, cy = height / 2, r = radius
    var tNow = (nowMs - p.epochMs) / 1000
    var maxAge = air.maxAge
    var f = p.frame
    var out = { key: key, ms: nowMs, x: new Float32Array(p.n), y: new Float32Array(p.n), ok: new Uint8Array(p.n) }
    for (var k = 0; k < p.n; k++) {
      var age = tNow - p.t[k]
      if (age >= maxAge || !(p.lat[k] === p.lat[k])) continue
      var i = 6 * k
      var vx = f[i], vy = f[i + 1], vz = f[i + 2]
      var d = p.speed[k] * (age < 0 ? 0 : age)
      if (d > 0) {
        var c = Math.cos(d), s = Math.sin(d)
        vx = vx * c + f[i + 3] * s
        vy = vy * c + f[i + 4] * s
        vz = vz * c + f[i + 5] * s
      }
      var z = m[6] * vx + m[7] * vy + m[8] * vz
      if (z <= 0) continue
      out.x[k] = cx + r * (m[0] * vx + m[1] * vy)
      out.y[k] = cy - r * (m[3] * vx + m[4] * vy + m[5] * vz)
      out.ok[k] = 1
    }
    store.pos = out
    return out
  }

  // How far (px) the fastest aircraft may have moved since `pos` was projected.
  function drift(p, pos) {
    return p.maxSpeed * Math.abs(nowMs - pos.ms) / 1000 * radius
  }

  // Aircraft k on screen at the current clock, { x, y }, or null when hidden;
  // positions() does the same for all of them at once.
  function screenNow(p, k, m) {
    var age = (nowMs - p.epochMs) / 1000 - p.t[k]
    if (age >= air.maxAge || !(p.lat[k] === p.lat[k])) return null
    var f = p.frame, i = 6 * k
    var d = p.speed[k] * (age < 0 ? 0 : age)
    var c = Math.cos(d), s = Math.sin(d)
    var vx = f[i] * c + f[i + 3] * s, vy = f[i + 1] * c + f[i + 4] * s, vz = f[i + 2] * c + f[i + 5] * s
    if (m[6] * vx + m[7] * vy + m[8] * vz <= 0) return null
    return { x: width / 2 + radius * (m[0] * vx + m[1] * vy), y: height / 2 - radius * (m[3] * vx + m[4] * vy + m[5] * vz) }
  }

  // The aircraft drawn under (x, y), or -1. The selected one is drawn 1.8x
  // larger and on top, so it wins within its own size.
  function pickAt(x, y) {
    var pos = positions(false)
    if (!pos) return -1
    var p = store.prep
    var slack = pos.ms === nowMs ? 0 : drift(p, pos)
    var m = slack > 0 ? Model.viewMatrix(centerLon, centerLat) : null
    // Where k is now: the cached position, or re-projected when it is older.
    function at(k) { return m ? screenNow(p, k, m) : { x: pos.x[k], y: pos.y[k] } }
    var s = selectedIndex
    if (s >= 0 && s < pos.ok.length && pos.ok[s]) {
      var rs = spritePx * 1.8 + 3
      var q = at(s)
      if (q && (q.x - x) * (q.x - x) + (q.y - y) * (q.y - y) <= rs * rs) return s
    }
    var r = Math.max(7, spritePx * 1.4)
    var reach = (r + slack) * (r + slack)
    var best = -1, bestD = r * r
    for (var k = 0; k < pos.ok.length; k++) {
      if (!pos.ok[k]) continue
      var dx = pos.x[k] - x, dy = pos.y[k] - y
      var d = dx * dx + dy * dy
      if (d > reach) continue
      if (m) {
        var e = at(k)
        if (!e) continue
        d = (e.x - x) * (e.x - x) + (e.y - y) * (e.y - y)
      }
      if (d <= bestD) {                  // later = higher = drawn on top
        best = k
        bestD = d
      }
    }
    return best
  }

  property real hoverX: -1
  property real hoverY: -1
  function hoverAt(x, y) {
    hoverX = x
    hoverY = y
    lastInputMs = Date.now()
    if (x < 0) {
      hoverTimer.stop()
      hoveredIndex = -1
      return
    }
    if (!hoverTimer.running) hoverTimer.start()
  }

  function hoverNow() {
    if (dragging || animating || hoverX < 0 || !active) return
    var k = pickAt(hoverX, hoverY)
    if (k !== hoveredIndex) hoveredIndex = k
    var row = k >= 0 ? rowAt(k) : null
    tip.text = row ? describe(row) : ""
    if (tip.text) placeTip(hoverX, hoverY)
  }

  // The hover card goes above right of the cursor, or on the first other
  // corner that covers no label or mark (the hovered aircraft's own label hides
  // while the card shows); failing that, above right over them.
  function placeTip(x, y) {
    var w = tip.width, h = tip.height
    var spots = [[x + 14, y - h - 8], [x + 14, y + 16], [x - 14 - w, y - h - 8], [x - 14 - w, y + 16]]
    var pick = null
    for (var i = 0; i < spots.length; i++) {
      var spot = { x: Model.clamp(spots[i][0], 4, width - w - 4), y: Model.clamp(spots[i][1], 4, height - h - 4) }
      if (!pick) pick = spot
      if (!coversLabel(spot.x, spot.y, w, h)) {
        pick = spot
        break
      }
    }
    tip.x = pick.x
    tip.y = pick.y
  }

  function coversLabel(x, y, w, h) {
    var lists = [labelBoxes, markBoxes]
    for (var i = 0; i < 2; i++)
      for (var j = 0; j < lists[i].length; j++) {
        var b = lists[i][j]
        if (b.k !== hoveredIndex && x < b.bx + b.w && x + w > b.bx && y < b.by + b.h && y + h > b.by) return true
      }
    return false
  }

  // Meta row `k` of the texture on screen (Service API shape), or null.
  function rowAt(k) {
    var p = prepared()
    return p ? Model.metaRow(p.meta, k) : null
  }

  // The `limit` airborne aircraft of the texture on screen closest to
  // (lat, lon): [{ i, row, km, brg }]. For the panel's list when nothing is
  // inside the overhead circle; runs on demand, once per revision at most.
  function nearestTo(lat, lon, limit) {
    var p = prepared()
    if (!p || !Model.isValidLatLon(lat, lon)) return []
    // Closest = largest dot product with home; distances only for the winners.
    var h = Model.vecFromLonLat(lon, lat)
    var f = p.frame
    var best = []
    for (var k = 0; k < p.n; k++) {
      if ((p.flags[k] & Model.FLAG_GROUND) !== 0 || !(p.lat[k] === p.lat[k])) continue
      var dot = h[0] * f[6 * k] + h[1] * f[6 * k + 1] + h[2] * f[6 * k + 2]
      if (best.length >= limit && dot <= best[best.length - 1].dot) continue
      best.push({ i: k, dot: dot })
      best.sort(function(a, b) { return b.dot - a.dot })
      if (best.length > limit) best.pop()
    }
    return best.map(function(b) {
      return { i: b.i, row: Model.metaRow(p.meta, b.i), km: Model.distanceKm(lat, lon, p.lat[b.i], p.lon[b.i]),
               brg: Model.bearingDeg(lat, lon, p.lat[b.i], p.lon[b.i]) }
    })
  }

  function describe(row) {
    var ac = Model.toAircraft(row, NaN)
    return [Model.displayName(ac), row.ty, Model.formatAltitude(ac, units)]
      .filter(function(s) { return s && s !== "—" }).join(" · ")
  }

  function resolveSelection() {
    if (!selectedHex) {
      selectedIndex = -1
      selectedRow = null
      selectedPos = null
      return
    }
    var p = prepared()
    if (!p) return                         // keep the last answer until meta lines up
    var k = p.meta.hex.indexOf(selectedHex)
    selectedIndex = k
    selectedRow = k >= 0 ? Model.metaRow(p.meta, k) : null
    updateSelectedPos()
  }

  function updateSelectedPos() {
    var row = selectedRow
    var prep = store.prep
    if (!row || !prep) {
      if (!selectedHex) selectedPos = null
      return
    }
    var age = (nowMs - prep.epochMs) / 1000 - row.t
    var gs = Model.finite(row.trk) ? row.gs : null
    var q = Model.reckon(row.lat, row.lon, row.trk, gs, age, air.maxAge)
    if (!selectedPos || selectedPos.lat !== q.lat || selectedPos.lon !== q.lon) selectedPos = q
  }

  // ============================================================ settling

  function settle() {
    lastSettleMs = Date.now()
    layoutLabels()
    if (active && width > 0) viewSettled(centerLat, centerLon, visibleRadiusNm)
    if (hoverX >= 0) hoverTimer.restart()
    warmTimer.restart()
  }

  // The idle clock: aircraft move, labels and the followed camera with them.
  function tick() {
    nowMs = Date.now()
    if (nowMs - sunMs > 60000) sunMs = nowMs
    updateSelectedPos()
    if (following && selectedPos) {
      setCentre(selectedPos.lat, selectedPos.lon)
      // The feed follows the camera, but only every few seconds.
      if (nowMs - lastSettleMs > 5000) {
        lastSettleMs = nowMs
        viewSettled(centerLat, centerLon, visibleRadiusNm)
      }
    }
    moveLabels()
  }

  // ---------------------------------------------------- label layout
  //
  // One placement for every label (aircraft, cities, home, the route's
  // airports), greedy by the priority in docs/VISUAL.md: the selected flight,
  // emergencies, the hovered aircraft, aircraft near the cursor (or the
  // middle), home, cities by rank, then the rest of the aircraft. Each label
  // tries right, left, above and below its anchor, keeps clear of the others,
  // of the sprites and of the drawn marks, and stays inside the disc, fading
  // near the limb (Model.placeGlobeLabels). It runs on settle, on new data and
  // when a tick moved two labels into each other; ticks otherwise just carry
  // the labels along with their aircraft (moveLabels).

  property var cityVecs: null              // places as unit vectors, built once
  property var placedFlights: []           // [{ k, ox, oy, w, h, fixed, lat, lon }] per pooled label
  property var labelBoxes: []              // [{ bx, by, w, h, k }] on screen: the flights', then the places'
  property var markBoxes: []               // home, airports, the selected ring: the hover card avoids them

  property var labelSides: ({})            // label key -> side, so labels keep their side

  readonly property int nearLabels: 4      // aircraft labelled first around the cursor or middle

  function cityVectors() {
    if (cityVecs) return cityVecs
    var out = []
    var rows = Array.isArray(places) ? places : []
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      var lat = Model.numberOr(r[1], NaN), lon = Model.numberOr(r[2], NaN)
      if (!Model.isValidLatLon(lat, lon)) continue
      var name = String(r[0] || "").replace(Model.CONTROL_RE, "").replace(/\s+/g, " ").trim().slice(0, 40)
      out.push({ name: name, v: Model.vecFromLonLat(lon, lat), minZoom: Model.numberOr(r[3], 9), capital: r[4] === 1 })
    }
    out.sort(function(a, b) { return a.minZoom - b.minZoom })
    cityVecs = out
    return out
  }

  // Advance width of `text` in one of the label fonts, remembered: callsigns
  // and city names come back on every layout.
  function textWidth(fm, text) {
    if (!text) return 0
    var key = fm.font.pixelSize + (fm.font.bold ? "b|" : "|") + text
    var w = store.widths[key]
    if (w === undefined) {
      w = Math.ceil(fm.advanceWidth(text))
      if (++store.widthCount > 4000) {          // a long session meets many callsigns
        store.widths = {}
        store.widthCount = 1
      }
      store.widths[key] = w
    }
    return w
  }

  function screenOf(m, v) {
    var x = m[0] * v[0] + m[1] * v[1]
    var y = m[3] * v[0] + m[4] * v[1] + m[5] * v[2]
    var z = m[6] * v[0] + m[7] * v[1] + m[8] * v[2]
    return { x: width / 2 + radius * x, y: height / 2 - radius * y, z: z }
  }

  // The globe's disc while its limb is on screen (labels fade near it), else null.
  function labelDisc() {
    return radius < halfDiagonal ? { x: width / 2, y: height / 2, r: radius } : null
  }

  function hideLabels() {
    for (var i = 0; i < flightLabels.count; i++) flightLabels.itemAt(i).visible = false
    for (var j = 0; j < placeLabels.count; j++) placeLabels.itemAt(j).visible = false
    placedFlights = []
    labelBoxes = []
    markBoxes = []
  }

  function layoutLabels() {
    if (!showLabels || !active || animating || width <= 0 || height <= 0) {
      if (!showLabels || width <= 0) hideLabels()
      return
    }
    var m = Model.viewMatrix(centerLon, centerLat)
    var lh = metrics.height, slh = smallMetrics.height
    var dots = spritePx < 4.5
    var focus = hoverX >= 0 ? { x: hoverX, y: hoverY } : { x: width / 2, y: height / 2 }
    var items = []
    var obstacles = []                     // sprites and marks: labels keep off them when they can
    var marks = []                         // drawn marks the hover card avoids too
    var count = -1

    // ---- aircraft: everything on screen once glyphs show; at globe zoom
    // only the selected one and emergencies (the summary lists those).
    var p = dots && selectedIndex < 0 ? null : prepared()
    var pos = p ? positions(true) : null
    if (pos && !dots) {
      count = 0
      var cands = []
      var cells = {}
      var cellW = width / 4, cellH = height / 3
      var r = spritePx * 0.75
      for (var k = 0; k < pos.ok.length; k++) {
        if (!pos.ok[k]) continue
        var x = pos.x[k], y = pos.y[k]
        if (x < 0 || y < 0 || x > width || y > height) continue
        if (k !== selectedIndex) obstacles.push({ bx: x - r, by: y - r, w: 2 * r, h: 2 * r })
        var alert = (p.flags[k] & Model.FLAG_EMERGENCY) !== 0
        if ((p.flags[k] & Model.FLAG_GROUND) !== 0) {
          if (k !== selectedIndex && !alert) continue
        } else {
          count++
        }
        var c = { k: k, x: x, y: y, d: Math.hypot(x - focus.x, y - focus.y), alert: alert }
        // The aircraft nearest the middle of each cell of a 4 x 3 grid go
        // first among the rest, so labels spread over the view.
        var cell = Math.floor(x / cellW) + 4 * Math.floor(y / cellH)
        c.cd = Math.hypot(x - (Math.floor(x / cellW) + 0.5) * cellW, y - (Math.floor(y / cellH) + 0.5) * cellH)
        if (!cells[cell] || c.cd < cells[cell].cd) cells[cell] = c
        cands.push(c)
      }
      for (var key in cells) cells[key].spread = true
      cands.sort(function(a, b) { return a.d - b.d })
      var near = 0, nearPx = Math.min(width, height) * 0.22, farPx = Math.max(1, Math.hypot(width, height))
      for (var j = 0; j < cands.length; j++) {
        var cj = cands[j]
        var tier = cj.k === selectedIndex ? Model.LABEL_TIER.selected
          : cj.alert ? Model.LABEL_TIER.emergency
          : cj.k === hoveredIndex ? Model.LABEL_TIER.hovered
          : near < nearLabels && cj.d < nearPx ? Model.LABEL_TIER.near : Model.LABEL_TIER.aircraft
        if (tier === Model.LABEL_TIER.near) near++
        cj.priority = Model.labelPriority(tier, tier === Model.LABEL_TIER.aircraft
          ? (cj.spread ? 0.5 : 0) + 0.49 * (1 - cj.d / farPx) : 1 - cj.d / farPx)
      }
      cands.sort(function(a, b) { return b.priority - a.priority })
      for (var i = 0; i < cands.length && i < 60; i++) items.push(flightItem(cands[i], p, lh))
    } else if (pos && selectedIndex >= 0 && pos.ok[selectedIndex]) {
      items.push(flightItem({ k: selectedIndex, x: pos.x[selectedIndex], y: pos.y[selectedIndex], alert: false,
                              priority: Model.labelPriority(Model.LABEL_TIER.selected, 1) }, p, lh))
    }
    if (dots) {
      var em = service && Array.isArray(service.emergencies) ? service.emergencies : []
      for (var e = 0; e < em.length; e++) {
        if (em[e].i === selectedIndex) continue
        var se = screenOf(m, Model.vecFromLonLat(em[e].lon, em[e].lat))
        if (se.z <= 0.05) continue
        var nameE = em[e].cs || String(em[e].hex || "").toUpperCase()
        var levelE = em[e].sq || ""
        items.push({ key: "a" + em[e].hex, pool: "flight", x: se.x, y: se.y, h: lh, gap: ringGap(),
                     w: textWidth(boldMetrics, nameE) + (levelE ? 4 + textWidth(smallMetrics, levelE) : 0),
                     priority: Model.labelPriority(Model.LABEL_TIER.emergency, 0.5), soft: true,
                     k: em[e].i, name: nameE, level: levelE, alert: true, lat: em[e].lat, lon: em[e].lon, fixed: true })
      }
    }
    inViewCount = count
    // The selected sprite is drawn larger, ringed.
    if (pos && selectedIndex >= 0 && pos.ok[selectedIndex]) {
      var rs = ringGap() - 2
      marks.push({ bx: pos.x[selectedIndex] - rs, by: pos.y[selectedIndex] - rs, w: 2 * rs, h: 2 * rs })
    }

    // ---- home, the route's airports and cities
    var hs = null
    if (Model.isValidLatLon(homeLat, homeLon)) {
      hs = screenOf(m, Model.vecFromLonLat(homeLon, homeLat))
      if (hs.z > 0.05) {
        marks.push({ bx: hs.x - 9, by: hs.y - 9, w: 18, h: 18 })      // Globe's home mark
        if (homeName)
          items.push({ key: "home", pool: "place", kind: "home", x: hs.x, y: hs.y, w: textWidth(smallBoldMetrics, homeName),
                       h: slh, gap: 11, priority: Model.labelPriority(Model.LABEL_TIER.home, 0), soft: true,
                       name: homeName })
      } else {
        hs = null
      }
    }
    if (routeShown) {
      var ends = [route.origin, route.destination]
      for (var a = 0; a < 2; a++) {
        var ae = screenOf(m, Model.vecFromLonLat(ends[a].lon, ends[a].lat))
        if (ae.z <= 0.05) continue
        marks.push({ bx: ae.x - 7, by: ae.y - 7, w: 14, h: 14 })       // RouteArc's airport mark
        var code = String(ends[a].code || "")
        if (code)
          items.push({ key: "r" + a, pool: "airport", kind: "airport", x: ae.x, y: ae.y, w: textWidth(smallBoldMetrics, code),
                       h: slh, gap: 9, priority: Model.labelPriority(Model.LABEL_TIER.selected, 0.5 - 0.1 * a), soft: true,
                       name: code })
      }
    }
    var limit = Model.webZoomForRadius(radius) + 0.4
    var list = cityVectors()
    // Zoomed in, thousands of places pass the zoom test: a dot product with
    // the view direction drops those beyond the corners before projecting.
    var zMin = Math.max(0.2, Math.cos(Model.visibleAngularRadius(radius, halfDiagonal)))
    for (var ci = 0, n = 0; ci < list.length && n < 400; ci++) {
      var city = list[ci]
      if (city.minZoom > limit) break
      var cv = city.v
      if (m[6] * cv[0] + m[7] * cv[1] + m[8] * cv[2] < zMin) continue
      var sc = screenOf(m, cv)
      if (sc.x < 0 || sc.y < 0 || sc.x > width || sc.y > height) continue
      if (hs && city.name === homeName && Math.hypot(sc.x - hs.x, sc.y - hs.y) < 40) continue   // home says it already
      // The biggest cities' dots: aircraft labels sit beside them rather than
      // on them, so the city can still be named.
      if (n++ < 60) obstacles.push({ bx: sc.x - 2.5, by: sc.y - 2.5, w: 5, h: 5 })
      items.push({ key: "c" + city.name, pool: "place", kind: "city", x: sc.x, y: sc.y, w: textWidth(smallMetrics, city.name),
                   h: slh, gap: 5, soft: city.capital, mark: { bx: sc.x - 2.5, by: sc.y - 2.5, w: 5, h: 5 },
                   priority: Model.labelPriority(Model.LABEL_TIER.city,
                                                 (city.capital ? 0.5 : 0) + 0.49 * Model.clamp(1 - city.minZoom / 12, 0, 1)),
                   name: city.name })
    }

    var placed = Model.placeGlobeLabels(items, {
      bounds: { x: 4, y: 4, w: width - 8, h: height - 8 },
      disc: labelDisc(),
      limits: { flight: flightLabels.count, place: placeLabels.count - 2, airport: 2 },
      obstacles: obstacles.concat(marks),
      previous: labelSides
    })
    markBoxes = marks
    showPlaced(placed)
  }

  // px from a ringed sprite's centre (selected, emergency) to just past its
  // ring: aircraft.frag rings at 1.25x a sprite drawn 1.8x (1.725x for an
  // emergency), more for a heavy.
  function ringGap() {
    return spritePx * 2.5 + 3
  }

  // Text, box and placement options of one aircraft label; ringed sprites
  // are drawn larger, so their labels stand further off.
  function flightItem(c, p, lh) {
    var row = Model.metaRow(p.meta, c.k)
    var ac = Model.toAircraft(row, NaN)
    var name = row ? Model.displayName(ac) : ""
    var level = row ? Model.formatAltitudeShort(ac.altitudeFt, ac.onGround, units) : ""
    if (c.alert && row && row.sq) level = row.sq
    var chosen = c.k === selectedIndex
    var w = textWidth(chosen || c.alert ? boldMetrics : metrics, name) + (level ? 4 + textWidth(smallMetrics, level) : 0)
    return { key: "a" + (row ? row.hex : c.k), pool: "flight", x: c.x, y: c.y, w: w, h: lh,
             gap: chosen || c.alert ? ringGap() : spritePx + 3, priority: c.priority, soft: chosen || c.alert,
             k: c.k, name: name, level: level, alert: c.alert }
  }

  // Hand the placement to the pooled labels and remember what moveLabels and
  // the hover card need.
  function showPlaced(placed) {
    var flights = [], flightBoxes = [], placeBoxes = [], sides = {}
    var fi = 0, pi = 0
    for (var i = 0; i < placed.length; i++) {
      var pl = placed[i], it = pl.item
      sides[it.key] = pl.side
      if (it.pool === "flight") {
        var tag = flightLabels.itemAt(fi++)
        tag.k = it.k
        tag.name = it.name
        tag.level = it.level
        tag.chosen = it.k === selectedIndex
        tag.alert = it.alert
        tag.fade = pl.alpha
        tag.x = pl.bx
        tag.y = pl.by
        tag.visible = true
        flightBoxes.push({ bx: pl.bx, by: pl.by, w: pl.w, h: pl.h, k: it.k })
        flights.push({ k: it.k, ox: pl.bx - it.x, oy: pl.by - it.y, w: pl.w, h: pl.h,
                       fixed: it.fixed === true, lat: it.lat, lon: it.lon })
      } else {
        var place = placeLabels.itemAt(pi++)
        place.text = it.name
        place.kind = it.kind
        place.tx = pl.bx - it.x
        place.ty = pl.by - it.y
        place.x = it.x
        place.y = it.y
        place.opacity = pl.alpha
        place.visible = true
        placeBoxes.push({ bx: pl.bx, by: pl.by, w: pl.w, h: pl.h, k: -1 })
      }
    }
    for (; fi < flightLabels.count; fi++) flightLabels.itemAt(fi).visible = false
    for (; pi < placeLabels.count; pi++) placeLabels.itemAt(pi).visible = false
    placedFlights = flights
    labelBoxes = flightBoxes.concat(placeBoxes)    // flights first: moveLabels relies on it
    labelSides = sides
  }

  // With the clock: carry the aircraft labels along with their aircraft
  // without choosing again, unless that pushes two labels together or one
  // off the disc; then (and when following, the camera moved) lay out anew.
  function moveLabels() {
    if (!labelsShown) return
    if (following) {
      layoutLabels()
      return
    }
    var m = Model.viewMatrix(centerLon, centerLat)
    var p = placedFlights.length ? prepared() : null
    var tNow = p ? (nowMs - p.epochMs) / 1000 : 0
    var disc = labelDisc()
    var nf = placedFlights.length
    var boxes = labelBoxes.slice(nf)                       // the places stay put
    for (var i = 0; i < nf; i++) {
      var f = placedFlights[i]
      var q = null
      if (f.fixed) q = { lat: f.lat, lon: f.lon }
      else if (p && f.k < p.n) q = Model.reckon(p.lat[f.k], p.lon[f.k], p.trk[f.k], p.gs[f.k], tNow - p.t[f.k], air.maxAge)
      var b = labelBoxes[i]
      if (q) {
        var s = screenOf(m, Model.vecFromLonLat(q.lon, q.lat))
        b = { bx: s.x + f.ox, by: s.y + f.oy, w: f.w, h: f.h, k: f.k }
        var alpha = Model.discAlpha(b.bx, b.by, b.w, b.h, disc, Model.LABEL_FADE)
        if (s.z <= 0 || alpha < 0.35 || overlapsAny(b, boxes)) {
          layoutLabels()
          return
        }
        var tag = flightLabels.itemAt(i)
        tag.x = b.bx
        tag.y = b.by
        tag.fade = alpha
      }
      boxes.push(b)
    }
    labelBoxes = boxes.slice(boxes.length - nf).concat(boxes.slice(0, boxes.length - nf))
  }

  function overlapsAny(b, list) {
    for (var j = 0; j < list.length; j++) {
      var o = list[j]
      if (b.bx < o.bx + o.w && b.bx + b.w > o.bx && b.by < o.by + o.h && b.by + b.h > o.by) return true
    }
    return false
  }
}
