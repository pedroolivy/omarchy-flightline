pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Flightline popout: a hero header with the lens switch, the globe (or
// the Look up sky dome) on the left, location / aircraft details on the
// right. Mounted by BarWidget.qml exactly like Omarchy's own weather panel,
// so it opens under the pill, joins the bar's popout switching and closes
// with Esc.
//
// Nothing here runs on a timer: text that depends on time (ETA, "last seen")
// follows the globe's clock, which only ticks when an aircraft has moved
// half a pixel.
Panel {
  id: root
  moduleName: "io.github.pedroolivy.flightline"
  ipcTarget: "io.github.pedroolivy.flightline"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------ open/close
  function open() { openFromHotkey() }

  function openFromHotkey() {
    // Before show(): the globe settles as it becomes active, and on the first
    // open that must already be the intro's view.
    if (!positioned) firstView()
    root.controller.show()
    if (service) service.setPanelOpen(root, true)
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (editingLocation) cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  // Open straight into a lens: the bar's middle click opens Look up.
  function openLens(name) {
    setLens(name)
    if (!root.opened) root.openFromHotkey()
  }

  onOpenedChanged: {
    if (service) service.setPanelOpen(root, opened)
    if (opened) placesWanted = true
  }
  // Hot reload or removing the widget must not leave the feed in panel mode.
  Component.onDestruction: if (service) service.setPanelOpen(root, false)

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  // ---------------------------------------------------------------- state
  readonly property var home: service ? service.home : null
  // From `home` itself, so bindings never see the flag before the record.
  readonly property bool hasHome: !!home && Model.isValidLatLon(home.lat, home.lon)
  readonly property string units: service ? service.units : "metric"
  readonly property real overheadNm: service ? service.nearbyRadiusNm : 100
  property bool positioned: false
  property string lens: "globe"             // globe | lookup
  readonly property bool showLabels: setting("showLabels", true) !== false
  readonly property bool showGraticule: setting("showGraticule", true) !== false
  readonly property bool showNight: setting("showNight", true) !== false
  readonly property bool showLights: setting("showLights", true) !== false
  readonly property bool showRelief: setting("showRelief", true) !== false
  readonly property bool showTrails: setting("showTrails", true) !== false
  readonly property bool showStars: setting("showStars", true) !== false

  // The globe's clock: moves only when something on screen moved.
  readonly property double nowMs: globe.nowMs

  function setLens(name) {
    var next = name === "lookup" ? "lookup" : "globe"
    if (next === lens) return
    lens = next
    // Look up wants the air around home; the globe asks for its own view
    // again when it shows (GlobeView settles on becoming visible).
    if (lens === "lookup" && service && hasHome) service.setView(home.lat, home.lon, 220)
  }

  // First open of the session: the whole Earth, then a glide home once the
  // textures are in. Later opens keep the last view, like other panels.
  // The Earth is only passed through, so it asks the feed for nothing.
  property bool introPending: false
  function firstView() {
    if (positioned || !hasHome) return
    positioned = true
    globe.setView(home.lat, home.lon, 6000, true)
    introPending = true
    if (globe.ready) playIntro()
    else introTimeout.start()
  }
  // Textures take ~0.1 s; should they never arrive, glide home anyway.
  Timer {
    id: introTimeout
    interval: 1500
    onTriggered: root.playIntro()
  }
  function playIntro() {
    if (!introPending) return
    introPending = false
    flyHome(900)
  }
  Connections {
    target: globe
    function onReadyChanged() { if (globe.ready) root.playIntro() }
  }

  // A region around home: the overhead ring with room to spare, wider where
  // the bar already counts only a few aircraft.
  function homeSpanNm() {
    var span = Math.max(250, overheadNm * 2.5)
    var n = service ? service.nearbyCount : -1
    return n >= 0 && n < 6 ? Math.max(span, 500) : span
  }

  function goHome() {
    if (!hasHome) return
    positioned = true
    globe.following = false
    flyHome(900)
  }

  // In sparse regions even that can be nearly empty. Once the answer for the
  // home view is on screen, widen it (up to 900 NM) until about a dozen
  // aircraft are in sight; once, and only if the user has not moved since.
  property real autoSpanNm: 0
  function flyHome(ms) {
    autoSpanNm = homeSpanNm()
    globe.flyTo(home.lat, home.lon, autoSpanNm, ms)
  }
  function fitHomeSpan() {
    if (autoSpanNm <= 0 || !hasHome || !service || globe.animating) return
    if (lens !== "globe" || Math.abs(globe.visibleRadiusNm - autoSpanNm) > autoSpanNm * 0.05
        || Model.distanceKm(globe.centerLat, globe.centerLon, home.lat, home.lon) > 5) {
      autoSpanNm = 0                        // the view went elsewhere
      return
    }
    var q = service.lastQuery
    if (!q || globe.shownRev !== service.trafficRev
        || !Model.queryCovers(q.lat, q.lon, q.radiusNm, home.lat, home.lon, autoSpanNm)) return   // not this view's answer yet
    autoSpanNm = 0
    // The viewport's short side reaches ~0.65 of the half-diagonal.
    var rows = globe.nearestTo(home.lat, home.lon, 12)
    var needNm = rows.length >= 12 ? rows[11].km / Model.NM_KM / 0.65 : Infinity
    var nm = Math.min(900, needNm)
    if (nm > globe.visibleRadiusNm * 1.1) globe.flyTo(home.lat, home.lon, nm, 700)
  }
  Connections {
    target: globe
    function onShownRevChanged() { Qt.callLater(root.fitHomeSpan) }
  }

  function goWorld() {
    globe.following = false
    globe.flyTo(globe.centerLat, globe.centerLon, 6000, 900)
  }

  onHasHomeChanged: if (hasHome && !positioned && opened) Qt.callLater(firstView)

  // ------------------------------------------------------------ selection
  // The selection is a hex code: indexes change with every revision. The
  // globe finds it again in each new texture (globe.selectedRow); when the
  // aircraft drops out of the feed, the last known record stays on the card.
  property string selectedHex: ""
  property var lastSelected: null           // v0.1-shape aircraft, kept when the signal drops
  property double lastSeenSelectedMs: 0
  readonly property var liveSelected: globe.selectedRow ? Model.toAircraft(globe.selectedRow, service ? service.epochMs : NaN) : null
  readonly property var selected: liveSelected || (selectedHex ? lastSelected : null)
  readonly property bool selectedLost: selectedHex !== "" && liveSelected === null
  readonly property var selectedPos: globe.selectedRow && globe.selectedPos ? globe.selectedPos
    : (selected ? { lat: selected.lat, lon: selected.lon } : null)
  readonly property var route: selected && selected.callsign && service && service.routes.hasOwnProperty(selected.callsign)
    ? service.routes[selected.callsign] : null
  readonly property bool routeOk: route !== null && selectedPos !== null && service !== null
    && service.routePlausible(route, selectedPos.lat, selectedPos.lon)
  readonly property var progress: routeOk ? Model.routeProgress(route, selectedPos.lat, selectedPos.lon, selected.groundSpeedKt) : null

  onLiveSelectedChanged: {
    if (!liveSelected) return
    var callsignChanged = !lastSelected || lastSelected.callsign !== liveSelected.callsign
    lastSelected = liveSelected
    lastSeenSelectedMs = Date.now()
    if (callsignChanged && liveSelected.callsign && service) service.routeFor(liveSelected.callsign)
  }

  function select(hex) {
    if (hex === selectedHex) return
    selectedHex = hex
    if (!hex) {
      globe.following = false
      lastSelected = null
    }
  }

  // An index of the texture on screen (globe click, Look up click, lists).
  // `hex` is the fallback when that texture's meta is not readable yet.
  function selectIndex(i, hex) {
    var row = i >= 0 ? globe.rowAt(i) : null
    if (!row || !row.hex) {
      select(hex || "")
      return
    }
    select(row.hex)
    var ac = Model.toAircraft(row, service ? service.epochMs : NaN)
    if (!liveSelected) {
      lastSelected = ac
      lastSeenSelectedMs = Date.now()
    }
    if (ac.callsign && service) service.routeFor(ac.callsign)
  }

  // Select and glide to an aircraft of a list (meta or summary rows).
  function selectAndShow(i, lat, lon, hex) {
    selectIndex(i, hex)
    positioned = true
    if (lens === "globe" && Model.isValidLatLon(lat, lon))
      globe.flyTo(lat, lon, Math.min(Math.max(globe.visibleRadiusNm, 120), 600), 800)
  }

  function toggleFollow() {
    if (!selectedHex) return
    globe.following = !globe.following
    if (globe.following && selectedPos) {
      setLens("globe")
      globe.flyTo(selectedPos.lat, selectedPos.lon, Math.min(globe.visibleRadiusNm, 250), 700)
    }
  }

  // n / N: walk the list on the right, closest first.
  property int cursorIndex: -1
  function nextAircraft(step) {
    var rows = aroundRows
    if (!rows.length) return
    cursorIndex = ((cursorIndex + step) % rows.length + rows.length) % rows.length
    var r = rows[cursorIndex]
    selectAndShow(r.i, r.lat, r.lon, r.hex)
  }

  // e: walk the emergencies of the last answer.
  property int emergencyCursor: -1
  function nextEmergency() {
    var list = service ? service.emergencies : []
    if (!list.length) return
    emergencyCursor = (emergencyCursor + 1) % list.length
    var e = list[emergencyCursor]
    selectAndShow(e.i, e.lat, e.lon, e.hex)
  }

  // ---------------------------------------------------------------- search
  // One search box, two intents: "go" looks somewhere (a city, or a flight
  // anywhere in the world); "home" picks the location the bar counts around.
  property bool editingLocation: false
  property string searchMode: "go"
  property int suggestionIndex: 0
  property bool pendingTrack: false
  readonly property var flightRows: service && searchMode === "go" ? service.flightResults : []
  readonly property var placeRows: service ? service.placeSuggestions : []
  readonly property int resultCount: flightRows.length + placeRows.length

  function startSearch(mode) {
    searchMode = mode === "home" ? "home" : "go"
    editingLocation = true
    suggestionIndex = 0
    if (service) {
      service.placeSuggestions = []
      service.findFlight("")
    }
    Qt.callLater(function() {
      locationField.text = ""
      locationField.forceActiveFocus()
    })
  }
  function startEditingLocation() { startSearch("home") }

  function cancelEditingLocation() {
    editingLocation = false
    if (service) {
      service.placeSuggestions = []
      service.findFlight("")
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function onSearchEdited(text) {
    suggestionIndex = 0
    searchDebounce.restart()
    if (searchMode === "go" && Model.looksLikeFlight(text)) flightDebounce.restart()
    else if (service) { flightDebounce.stop(); service.findFlight("") }
  }

  function acceptSearch() {
    var i = Math.min(suggestionIndex, Math.max(0, resultCount - 1))
    if (i < flightRows.length) pickFlight(flightRows[i])
    else if (placeRows.length > 0) pickPlace(placeRows[i - flightRows.length])
  }

  function pickPlace(row) {
    if (!row || !service) return
    cancelEditingLocation()
    if (searchMode === "home") {
      service.saveHome(row.name, row.lat, row.lon, "manual", 0)
      positioned = true
      Qt.callLater(goHome)
      return
    }
    globe.following = false
    positioned = true
    setLens("globe")
    globe.flyTo(row.lat, row.lon, 150, 1100)
  }

  // A flight found by the search may be outside the traffic on screen; the
  // glide there brings it in, and the globe picks it up by hex.
  function pickFlight(ac) {
    if (!ac) return
    cancelEditingLocation()
    pendingTrack = false
    positioned = true
    select(ac.hex)
    lastSelected = ac
    lastSeenSelectedMs = Date.now()
    if (ac.callsign && service) service.routeFor(ac.callsign)
    setLens("globe")
    globe.following = true
    var p = Model.extrapolate(ac, Date.now())
    globe.flyTo(p.lat, p.lon, 120, 1300)
  }

  // `omarchy-shell flightline track TAM3054` finds and follows a flight.
  function track(query) {
    if (!service) return
    if (!opened) openFromHotkey()
    pendingTrack = true
    service.findFlight(query)
  }

  Connections {
    target: root.service
    function onFlightResultsChanged() {
      if (root.pendingTrack && root.service.flightResults.length) root.pickFlight(root.service.flightResults[0])
    }
    function onFlightStatusChanged() {
      if (root.pendingTrack && root.service.flightStatus === "notfound") root.pendingTrack = false
    }
    function onHomeChanged() {
      if (root.service && root.service.home.source === "wifi" && root.opened) Qt.callLater(root.goHome)
    }
  }

  function pinView() {
    if (!service) return
    service.saveHome("Pinned spot", globe.centerLat, globe.centerLon, "manual", 0)
    cancelEditingLocation()
  }

  function useWeatherLocation() {
    if (!service) return
    service.clearHome()
    cancelEditingLocation()
    Qt.callLater(goHome)
  }

  function sourceLabel() {
    if (!home || !home.source) return "Looking for your location…"
    if (home.source === "omarchy") return "From your Omarchy weather location"
    if (home.source === "ip") return "Estimated from your IP address"
    if (home.source === "wifi") {
      var acc = home.accuracyM > 0 ? " · ±" + (home.accuracyM >= 1000 ? Math.round(home.accuracyM / 1000) + " km" : Math.round(home.accuracyM) + " m") : ""
      return "Located with Wi-Fi" + acc
    }
    return "Set in Flightline"
  }

  // ---------------------------------------------------------------- places
  // City names for the globe, read once the panel is first opened.
  property bool placesWanted: false
  FileView {
    path: root.placesWanted ? decodeURIComponent(Qt.resolvedUrl("assets/places.json").toString().replace(/^file:\/\//, "")) : ""
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        globe.places = data && Array.isArray(data.places) ? data.places : []
      } catch (e) {
        console.warn("Flightline: could not read places: " + e)
      }
    }
  }

  // -------------------------------------------------------------- helpers
  readonly property color fg: Color.foreground
  readonly property color dim: Qt.darker(Color.foreground, 1.45)

  readonly property string heroMeta: {
    if (!service) return ""
    var sky = lens === "lookup" && lookUp.item && lookUp.item.hasHome ? lookUp.item.skyCount : -1
    return Model.heroMeta(hasHome && home.name ? home.name : "", hasHome ? service.nearbyCount : -1,
                          lens === "globe" ? globe.inViewCount : -1, service.worldCount, sky)
  }

  readonly property string statusLine: {
    if (!service) return ""
    if (service.status === "error") return service.errorText || "Feed unreachable"
    if (!service.lastUpdateMs) return service.status === "loading" ? "Loading traffic…" : "Waiting for traffic…"
    var parts = [service.activeSource, "updated " + Qt.formatTime(new Date(service.lastUpdateMs), "hh:mm:ss"),
                 Model.groupThousands(service.trafficCount) + " aircraft"]
    if (service.mode === "world") parts.push("whole world")
    return parts.join("  ·  ")
  }

  // The list on the right: the overhead circle from the summary, or, when it
  // is empty, the closest aircraft of the last answer (the helper picks
  // them, so this never reads meta.json).
  readonly property bool aroundFallback: service !== null && hasHome && service.nearest.length === 0 && service.nearbyCount >= 0
  readonly property var aroundRows: {
    if (!service) return []
    var u = units
    var list = (aroundFallback ? service.nearestAny : service.nearest) || []
    return list.slice(0, 7).map(function(r) { return rowView(r.i, r, r.km, r.brg) })
  }

  function rowView(i, row, km, brg) {
    var ac = Model.toAircraft(row, NaN)
    var r = row && row.cs && service && service.routes.hasOwnProperty(row.cs) ? service.routes[row.cs] : null
    // The route says more than the type when it is known.
    var what = r ? r.origin.code + "→" + r.destination.code : (row.ty || "")
    return { i: i, hex: row.hex, cs: row.cs, lat: row.lat, lon: row.lon,
             text: [Model.displayName(ac), what].filter(function(s) { return s }).join("  ")
               + "  ·  " + Model.formatAltitude(ac, units),
             where: Model.formatDistance(km, units) + " " + Model.compassPoint(brg) }
  }

  // Routes for the closest few, so the list can say where they are going.
  onAroundRowsChanged: {
    if (!opened || !service) return
    for (var k = 0; k < aroundRows.length && k < 3; k++)
      if (aroundRows[k].cs) service.routeFor(aroundRows[k].cs)
  }

  // `omarchy-shell flightline <method>`; bind a key with
  // `omarchy-shell shell toggle io.github.pedroolivy.flightline`.
  // status() never includes coordinates, so it is safe for bug reports.
  IpcHandler {
    target: "flightline"

    function status(): string {
      var s = root.service
      return JSON.stringify({
        version: s ? s.version : null,
        feed: s ? s.status : "no service",
        error: s ? s.errorText : "",
        source: s ? s.activeSource : "",
        mode: s ? s.mode : "",
        aircraft: s ? s.trafficCount : 0,
        airborne: s ? s.airborneCount : -1,
        world: s ? s.worldCount : -1,
        overhead: s ? s.nearbyCount : -1,
        overheadRadiusNm: s ? s.nearbyRadiusNm : null,
        locationSource: root.home ? root.home.source : "",
        open: root.opened,
        lens: root.lens,
        visibleRadiusNm: Math.round(globe.visibleRadiusNm),
        following: globe.following,
        texturesReady: globe.ready,
        lastUpdateAgoS: s && s.lastUpdateMs ? Math.round((Date.now() - s.lastUpdateMs) / 1000) : null,
        failures: s ? { "adsb.lol": s.sourceHealth["adsb.lol"].failures, "adsb.fi": s.sourceHealth["adsb.fi"].failures } : null,
        recent: s ? s.feedLog.map(function(e) {
          return { agoS: Math.round((Date.now() - e.atMs) / 1000), source: e.source, mode: e.mode, nm: e.nm,
                   ok: e.ok, code: e.code, ms: e.ms, n: e.n, error: e.error }
        }) : []
      })
    }
    function refresh(): void { if (root.service) root.service.refresh() }
    function toggle(): void { root.toggle() }
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function home(): void { root.goHome() }
    function zoomIn(): void { globe.zoomBy(1.6) }
    function zoomOut(): void { globe.zoomBy(1 / 1.6) }
    function world(): void {
      root.positioned = true
      if (!root.opened) root.openFromHotkey()
      root.setLens("globe")
      root.goWorld()
    }
    // "globe" or "lookup".
    function lens(name: string): void { root.openLens(name) }
    // "lat,lon" or "lat,lon,radiusNm": look somewhere else, e.g.
    // `omarchy-shell flightline view 51.47,-0.45,60` for Heathrow.
    function view(spec: string): string {
      var parts = String(spec || "").split(",")
      var lat = Number(parts[0]), lon = Number(parts[1])
      if (!Model.isValidLatLon(lat, lon)) return "usage: view lat,lon[,radiusNm]"
      var nm = parts.length > 2 ? Model.clamp(Number(parts[2]) || 120, 5, 6000) : 120
      globe.following = false
      root.positioned = true
      if (!root.opened) root.openFromHotkey()
      root.setLens("globe")
      globe.flyTo(lat, lon, nm, 900)
      return "ok"
    }
    function track(query: string): string { root.track(query); return "searching" }
    function search(): void { if (!root.opened) root.openFromHotkey(); root.startSearch("go") }
    // Open the search already filled in, e.g. `omarchy-shell flightline find "LA 3054"`.
    function find(query: string): void {
      if (!root.opened) root.openFromHotkey()
      root.startSearch("go")
      Qt.callLater(function() {
        locationField.text = String(query || "").slice(0, 64)
        root.onSearchEdited(locationField.text)
      })
    }
    // Writes a PNG of the open panel (not the rest of the screen) and
    // returns its path; the file lands a moment after the call returns.
    function snapshot(): string {
      var dir = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
      if (!dir) return "error: XDG_RUNTIME_DIR is not set"
      var path = dir + "/flightline-snapshot.png"
      keyCatcher.grabToImage(function(result) { result.saveToFile(path) })
      return path
    }
  }

  // ---------------------------------------------------------------- view
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(940))
    contentHeight: panel.fittedContentHeight(Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onCloseRequested: {
        if (globe.following) globe.following = false
        else if (root.selectedHex) root.select("")
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (root.lens === "globe") globe.panBy(-dx * 80, -dy * 80) }
      onActivateRequested: root.toggleFollow()
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "f") root.toggleFollow()
        else if (k === "c") root.goHome()
        else if (k === "w") { root.setLens("globe"); root.goWorld() }
        else if (t === "n") root.nextAircraft(1)
        else if (t === "N") root.nextAircraft(-1)
        else if (k === "e") root.nextEmergency()
        else if (t === "1") root.setLens("globe")
        else if (t === "2") root.setLens("lookup")
        else if (k === "r" && root.service) root.service.refresh()
        else if (k === "/" || k === "s") root.startSearch("go")
        else if (t === "+" || t === "=") globe.zoomBy(1.6)
        else if (t === "-" || t === "_") globe.zoomBy(1 / 1.6)
      }

      Item {
        anchors.fill: parent

        Rectangle {
          anchors.fill: parent
          color: Color.popups.background
        }

        // ------------------------------------------------------ header
        Item {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Math.max(hero.implicitHeight, lensSwitch.height)

          PanelHero {
            id: hero
            anchors.left: parent.left
            anchors.right: headerTools.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            title: "Flightline"
            meta: root.heroMeta
            iconComponent: Component {
              Text {
                text: "󰀝"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.display
              }
            }
          }

          Row {
            id: headerTools
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰍉"
              tooltipText: "Find a city or flight (/)"
              onClicked: root.startSearch("go")
            }
            ButtonGroup {
              id: lensSwitch
              anchors.verticalCenter: parent.verticalCenter
              focusable: false
              fontSize: Style.font.bodySmall
              value: root.lens
              options: [
                { value: "globe", label: "Globe", tooltip: "The world's traffic (1)" },
                { value: "lookup", label: "Look up", tooltip: "The sky above you (2)" }
              ]
              onChanged: function(v) { root.setLens(v) }
            }
          }
        }

        // ---------------------------------------------------- viewport
        Item {
          id: viewport
          anchors.left: parent.left
          anchors.top: header.bottom
          anchors.topMargin: Style.space(10)
          anchors.bottom: parent.bottom
          width: parent.width - sidebar.width - Style.spacing.panelGap
          clip: true

          GlobePalette {
            id: tints
            foreground: Color.foreground
            background: Color.background
            accent: Color.accent
            muted: Color.muted
            urgent: Color.urgent
          }

          GlobeView {
            id: globe
            anchors.fill: parent
            visible: root.lens === "globe"
            active: root.opened
            service: root.service
            tints: tints
            units: root.units
            fontFamily: Style.font.family
            fontSize: Style.font.bodySmall
            smallFontSize: Style.font.caption
            selectedHex: root.selectedHex
            route: root.route
            routeVisible: root.routeOk
            homeLat: root.hasHome ? root.home.lat : NaN
            homeLon: root.hasHome ? root.home.lon : NaN
            homeRingNm: root.hasHome ? root.overheadNm : 0
            homeName: root.hasHome && root.home.name ? root.home.name : ""
            showLabels: root.showLabels
            showGraticule: root.showGraticule
            showNight: root.showNight
            showLights: root.showLights
            showRelief: root.showRelief
            showTrails: root.showTrails
            showStars: root.showStars

            onPicked: function(index) { root.selectIndex(index) }
            onUserMoved: {
              root.positioned = true
              root.autoSpanNm = 0
            }
            onViewSettled: function(lat, lon, radiusNm) {
              // The whole Earth before the intro glide is not worth a world request.
              if (root.introPending) return
              if (root.service && root.lens === "globe" && root.opened) root.service.setView(lat, lon, radiusNm)
              Qt.callLater(root.fitHomeSpan)
            }
          }

          // Look up: written to the same service API, loaded only while shown.
          Loader {
            id: lookUp
            anchors.fill: parent
            active: root.lens === "lookup" && root.opened
            source: Qt.resolvedUrl("LookUp.qml")
            onLoaded: {
              var v = item
              v.service = Qt.binding(function() { return root.service })
              v.home = Qt.binding(function() { return root.hasHome ? root.home : null })
              v.units = Qt.binding(function() { return root.units })
              v.selectedIndex = Qt.binding(function() { return globe.selectedIndex })
              v.foreground = Qt.binding(function() { return Color.foreground })
              v.background = Qt.binding(function() { return Color.background })
              v.accent = Qt.binding(function() { return Color.accent })
              v.muted = Qt.binding(function() { return Color.muted })
              v.urgent = Qt.binding(function() { return Color.urgent })
              // The sky's light comes from the globe's palette, like every other colour.
              v.skyNight = Qt.binding(function() { return tints.skyNight })
              v.skyNightHorizon = Qt.binding(function() { return tints.skyNightHorizon })
              v.skyDay = Qt.binding(function() { return tints.skyDay })
              v.skyDayHorizon = Qt.binding(function() { return tints.skyDayHorizon })
              v.skyTwilight = Qt.binding(function() { return tints.skyTwilight })
              v.bodyColor = Qt.binding(function() { return tints.body })
              v.fontFamily = Qt.binding(function() { return Style.font.family })
              v.fontPx = Qt.binding(function() { return Style.font.bodySmall })
              v.picked.connect(function(index) { root.selectIndex(index) })
            }
          }
          Text {
            anchors.centerIn: parent
            visible: root.lens === "lookup" && lookUp.status === Loader.Error
            text: "Look up could not be loaded."
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // Zoom controls, bottom-left of the globe.
          Column {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(6)
            spacing: Style.space(4)
            visible: root.lens === "globe"
            PanelActionButton { iconText: "+"; tooltipText: "Zoom in (+)"; onClicked: globe.zoomBy(1.6) }
            PanelActionButton { iconText: "−"; tooltipText: "Zoom out (−)"; onClicked: globe.zoomBy(1 / 1.6) }
            PanelActionButton { iconText: "󰇧"; tooltipText: "Whole world (W)"; onClicked: root.goWorld() }
            PanelActionButton {
              iconText: "󰋜"
              visible: root.hasHome
              tooltipText: "Back to " + (root.home && root.home.name ? root.home.name : "home") + " (C)"
              onClicked: root.goHome()
            }
          }
        }

        // ------------------------------------------------------ sidebar
        Item {
          id: sidebar
          anchors.right: parent.right
          anchors.top: header.bottom
          anchors.topMargin: Style.space(10)
          anchors.bottom: parent.bottom
          width: Math.min(Style.space(300), parent.width * 0.4)

          Flickable {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: footer.top
            anchors.bottomMargin: Style.space(6)
            clip: true
            contentHeight: sideColumn.height
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: sideColumn
              width: parent.width
              spacing: Style.spacing.lg

              // Location
              Column {
                width: parent.width
                spacing: Style.space(3)
                visible: !root.editingLocation

                PanelSectionHeader { text: "Location" }
                // Click-to-edit label, like the location in Omarchy's weather panel.
                Item {
                  width: parent.width
                  height: locationRow.implicitHeight + Style.space(4)
                  Row {
                    id: locationRow
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(7)
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "󰋜"
                      color: Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Math.min(implicitWidth, sidebar.width - Style.space(60))
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: root.home && root.home.name ? root.home.name : (root.hasHome ? "Your area" : "Set your location")
                      color: locationMouse.containsMouse ? Color.accent : root.fg
                      font.family: Style.font.family
                      font.pixelSize: Style.font.title
                      font.bold: true
                      font.underline: locationMouse.containsMouse
                    }
                  }
                  MouseArea {
                    id: locationMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.startEditingLocation()
                  }
                }
                Text {
                  width: parent.width
                  leftPadding: Style.space(6)
                  text: root.sourceLabel()
                  color: root.dim
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.editingLocation

                PanelSectionHeader { text: root.searchMode === "home" ? "Set your location" : "Find a city or flight" }
                TextField {
                  id: locationField
                  width: parent.width
                  placeholderText: root.searchMode === "home" ? "Search a city…" : "Lisbon, TAM3054, LA 3054, PR-XMA…"
                  onTextEdited: root.onSearchEdited(text)
                  Keys.onEscapePressed: root.cancelEditingLocation()
                  Keys.onDownPressed: root.suggestionIndex = Math.min(root.suggestionIndex + 1, Math.max(0, root.resultCount - 1))
                  Keys.onUpPressed: root.suggestionIndex = Math.max(0, root.suggestionIndex - 1)
                  onAccepted: root.acceptSearch()
                }
                Timer {
                  id: searchDebounce
                  interval: 300
                  onTriggered: if (root.service) root.service.searchPlaces(locationField.text)
                }
                Timer {
                  id: flightDebounce
                  interval: 550
                  onTriggered: if (root.service) root.service.findFlight(locationField.text)
                }
                Repeater {
                  model: root.flightRows
                  delegate: Button {
                    required property var modelData
                    required property int index
                    width: parent.width
                    leftAlign: true      // list rows: start at the left, clip a long tail
                    clip: true
                    horizontalPadding: Style.space(6)
                    selected: index === root.suggestionIndex
                    iconText: "󰀝"
                    text: Model.displayName(modelData) + (modelData.type ? "  ·  " + modelData.type : "")
                      + "  ·  " + Model.formatAltitude(modelData, root.units)
                    tooltipText: "Track and follow this flight"
                    onClicked: root.pickFlight(modelData)
                  }
                }
                Text {
                  width: parent.width
                  visible: root.searchMode === "go" && root.service && root.service.flightStatus !== "" && root.service.flightStatus !== "found"
                  wrapMode: Text.WordWrap
                  leftPadding: Style.space(6)
                  textFormat: Text.PlainText
                  text: !root.service ? "" : root.service.flightStatus === "searching"
                    ? "Looking for " + root.service.flightQuery.toUpperCase() + " in the air…"
                    : root.service.flightQuery.toUpperCase() + " is not in the air right now, or no receiver hears it."
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Repeater {
                  model: root.placeRows
                  delegate: Button {
                    required property var modelData
                    required property int index
                    width: parent.width
                    leftAlign: true
                    clip: true
                    horizontalPadding: Style.space(6)
                    selected: index + root.flightRows.length === root.suggestionIndex
                    iconText: root.searchMode === "home" ? "󰋜" : "󰍎"
                    text: modelData.name + (modelData.detail ? "  ·  " + modelData.detail : "")
                    onClicked: root.pickPlace(modelData)
                  }
                }
                Text {
                  visible: root.service && root.service.searchingPlaces
                  text: "Searching…"
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Flow {
                  width: parent.width
                  spacing: Style.space(4)
                  Button { visible: root.searchMode === "home"; text: "Pin this view"; bordered: true; tooltipText: "Use the centre of the globe"; onClicked: root.pinView() }
                  Button {
                    visible: root.searchMode === "home"
                    text: root.service && root.service.locating ? "Locating…" : "Wi-Fi"
                    bordered: true
                    tooltipText: "Experimental: ask BeaconDB where the nearby Wi-Fi networks are"
                    onClicked: if (root.service) root.service.locateWithWifi()
                  }
                  Button { visible: root.searchMode === "home"; text: "Weather location"; bordered: true; tooltipText: "Follow Omarchy's weather location"; onClicked: root.useWeatherLocation() }
                  Button { text: "Cancel"; onClicked: root.cancelEditingLocation() }
                }
                Text {
                  width: parent.width
                  visible: text !== ""
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: root.service ? root.service.locateError : ""
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              PanelSeparator { width: parent.width }

              // Selected aircraft
              Column {
                id: card
                width: parent.width
                spacing: Style.space(6)
                visible: root.selected !== null
                readonly property var ac: root.selected

                Item {
                  width: parent.width
                  height: Math.max(callsignText.implicitHeight, cardButtons.height)
                  Text {
                    id: callsignText
                    anchors.left: parent.left
                    anchors.right: cardButtons.left
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: card.ac ? Model.displayName(card.ac) : ""
                    color: card.ac && Model.isEmergency(card.ac) ? Color.urgent : Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.display
                    font.bold: true
                  }
                  Row {
                    id: cardButtons
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)
                    PanelActionButton {
                      iconText: globe.following ? "󰓾" : "󰆤"
                      tooltipText: globe.following ? "Stop following (F)" : "Follow (F)"
                      foreground: globe.following ? Color.accent : Color.foreground
                      onClicked: root.toggleFollow()
                    }
                    PanelActionButton { iconText: "󰅖"; tooltipText: "Close (Esc)"; onClicked: root.select("") }
                  }
                }

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: {
                    var ac = card.ac
                    if (!ac) return ""
                    var who = root.route && root.route.airline ? root.route.airline : (ac.operator || "")
                    return [who, ac.description || ac.type, ac.registration].filter(function(s) { return s }).join("  ·  ")
                  }
                  color: root.fg
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                // Route: origin → destination, how far along, when it lands.
                Column {
                  width: parent.width
                  spacing: Style.space(3)
                  visible: root.route !== null

                  Text {
                    textFormat: Text.PlainText
                    text: root.route ? root.route.origin.code + "  →  " + root.route.destination.code : ""
                    color: root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.route ? (root.route.origin.city || root.route.origin.name) + "  →  " + (root.route.destination.city || root.route.destination.name) : ""
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  Item {
                    width: parent.width
                    height: Style.space(14)
                    visible: root.progress !== null
                    Rectangle {
                      id: progressTrack
                      anchors.left: parent.left
                      anchors.right: progressText.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(4)
                      radius: height / 2
                      color: Util.alpha(Color.foreground, 0.12)
                      Rectangle {
                        width: parent.width * (root.progress ? root.progress.progress : 0)
                        height: parent.height
                        radius: parent.radius
                        color: Color.accent
                      }
                    }
                    Text {
                      id: progressText
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.progress ? Math.round(root.progress.progress * 100) + "%  est." : ""
                      color: root.dim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    visible: text !== ""
                    text: {
                      var p = root.progress
                      if (!p || p.seconds === null || !root.route) return ""
                      var at = Qt.formatTime(new Date(root.nowMs + p.seconds * 1000), "hh:mm")
                      return "lands " + root.route.destination.code + " ~" + at + "  ·  " + Model.formatDuration(p.seconds) + "  est."
                    }
                    color: root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: root.route !== null && !root.routeOk && Model.routeHasCoordinates(root.route)
                    text: "Route unconfirmed: this aircraft is off its usual path."
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                Rectangle {
                  width: parent.width
                  height: emergencyText.implicitHeight + Style.space(8)
                  visible: card.ac !== null && Model.isEmergency(card.ac)
                  color: Util.alpha(Color.urgent, 0.15)
                  border.color: Util.alpha(Color.urgent, 0.6)
                  border.width: 1
                  Text {
                    id: emergencyText
                    anchors.centerIn: parent
                    text: card.ac ? Model.emergencyLabel(card.ac) : ""
                    color: Color.urgent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                }

                Text {
                  visible: root.selectedLost
                  text: "Signal lost · last seen " + Model.formatAge((root.nowMs - root.lastSeenSelectedMs) / 1000)
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  visible: text !== ""
                  text: {
                    var p = root.selectedPos
                    if (!p || !root.hasHome) return ""
                    var km = Model.distanceKm(root.home.lat, root.home.lon, p.lat, p.lon)
                    return Model.formatDistance(km, root.units) + " " + Model.compassPoint(Model.bearingDeg(root.home.lat, root.home.lon, p.lat, p.lon)) + " of you"
                  }
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(10)
                  rowSpacing: Style.space(4)
                  Repeater {
                    model: {
                      var ac = card.ac
                      if (!ac) return []
                      var u = root.units
                      var rows = [
                        ["Altitude", Model.formatAltitude(ac, u)],
                        ["Vertical", Model.formatVerticalRate(ac.verticalRateFpm, u)],
                        ["Speed", Model.formatSpeed(ac.groundSpeedKt, u)],
                        ["Heading", Model.formatHeading(ac.track)],
                        ["Phase", Model.phaseOf(ac)]
                      ]
                      if (ac.squawk) rows.push(["Squawk", ac.squawk])
                      if (ac.registration) rows.push(["Registration", ac.registration])
                      if (ac.type) rows.push(["Type", ac.type])
                      rows.push(["ICAO", ac.hex.toUpperCase()])
                      var flat = []
                      for (var i = 0; i < rows.length; i++) flat.push({ label: rows[i][0], value: rows[i][1], isLabel: true }, { label: rows[i][0], value: rows[i][1], isLabel: false })
                      return flat
                    }
                    delegate: Text {
                      required property var modelData
                      width: modelData.isLabel ? Style.space(84) : card.width - Style.space(94)
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: modelData.isLabel ? modelData.label : modelData.value
                      color: modelData.isLabel ? root.dim : root.fg
                      font.family: Style.font.family
                      font.pixelSize: modelData.isLabel ? Style.font.caption : Style.font.body
                    }
                  }
                }
              }

              // Look up: the passes over you and what lies beyond the horizon.
              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: root.selected === null && root.lens === "lookup" && lookUp.item !== null

                PanelSectionHeader { text: "Next passes" }
                Repeater {
                  model: lookUp.item ? lookUp.item.passes.slice(0, 6) : []
                  delegate: Button {
                    required property var modelData
                    width: parent.width
                    leftAlign: true
                    clip: true
                    horizontalPadding: Style.space(6)
                    text: modelData.name + "  ·  " + Math.round(modelData.maxEl) + "° " + Model.compassPoint(modelData.maxAz)
                      + "  ·  " + Model.formatSoon(modelData.tMaxS) + (modelData.sunlit ? "  ·  sunlit" : "")
                    onClicked: root.selectIndex(modelData.i)
                  }
                }
                Text {
                  width: parent.width
                  visible: lookUp.item !== null && lookUp.item.passes.length === 0
                  wrapMode: Text.WordWrap
                  leftPadding: Style.space(6)
                  text: "Nothing passes high over you in the next ten minutes."
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                PanelSectionHeader { text: "Beyond the horizon" }
                Repeater {
                  model: lookUp.item ? lookUp.item.beyond : []
                  delegate: Button {
                    required property var modelData
                    width: parent.width
                    leftAlign: true
                    clip: true
                    horizontalPadding: Style.space(6)
                    text: modelData.name + "  ·  " + Model.formatDistance(modelData.km, root.units) + " " + Model.compassPoint(modelData.brg)
                    onClicked: root.selectIndex(modelData.i)
                  }
                }
              }

              // Around you: the overhead circle, or the nearest beyond it.
              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: root.selected === null && root.lens === "globe"

                PanelSectionHeader {
                  text: !root.hasHome ? "Around you"
                    : root.aroundFallback ? "Nearest · nothing within " + Model.formatRadius(root.overheadNm, root.units)
                    : "Around you · " + Model.formatRadius(root.overheadNm, root.units)
                }
                Repeater {
                  model: root.aroundRows
                  delegate: Button {
                    required property var modelData
                    required property int index
                    width: parent.width
                    leftAlign: true
                    clip: true
                    horizontalPadding: Style.space(6)
                    selected: index === root.cursorIndex
                    text: modelData.text + "  ·  " + modelData.where
                    onClicked: {
                      root.cursorIndex = index
                      root.selectAndShow(modelData.i, modelData.lat, modelData.lon, modelData.hex)
                    }
                  }
                }
                Text {
                  width: parent.width
                  visible: root.aroundRows.length === 0
                  wrapMode: Text.WordWrap
                  leftPadding: Style.space(6)
                  text: !root.service || !root.service.lastUpdateMs
                    ? (root.service && root.service.status === "error" ? "Traffic feed is unreachable right now." : "Listening for aircraft…")
                    : !root.hasHome ? "Set your location to see what flies over you."
                    : "Quiet skies. Press W for the whole world's traffic."
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Footer
          Column {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Style.space(3)
            PanelSeparator { width: parent.width }
            Row {
              width: parent.width
              spacing: Style.space(6)
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(6); height: width; radius: width / 2
                color: !root.service ? root.dim
                  : root.service.status === "error" ? Color.urgent
                  : root.service.status === "ok" ? Color.accent : root.dim
              }
              Text {
                width: parent.width - Style.space(12)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.statusLine
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "drag · scroll · click a plane · / search · F follow · C home · W world · N next · 1 2 lens"
              color: Qt.darker(root.dim, 1.25)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
