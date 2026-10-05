import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Flightline's single background service. Every bar widget (one per monitor)
// and the panel read from this one instance, so traffic is fetched once no
// matter how many screens show the pill.
//
// Responsibilities:
//   - resolve the home location (own setting → Omarchy weather location → IP)
//   - schedule ADS-B requests for the overhead circle, the panel's view or
//     the whole world (docs/ARCHITECTURE.md "Feed scheduling")
//   - hand each answer to flightline-feed, which turns it into the GPU data
//     texture and a small summary, so no large JSON is parsed here
//   - a callsign → route cache, city search, flight search, Wi-Fi lookup
Item {
  id: root

  // Host injection (see shell/README.md "Plugin manifest").
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.pedroolivy.flightline"
  readonly property string version: manifest && manifest.version ? manifest.version : "dev"
  readonly property string userAgent: "Flightline/" + version + " (+https://github.com/pedroolivy/omarchy-flightline)"
  readonly property string locatePath: localPath(Qt.resolvedUrl("flightline-locate"))
  readonly property string feedPath: localPath(Qt.resolvedUrl("flightline-feed"))

  // Everything transient lives on tmpfs (docs/ARCHITECTURE.md "Runtime files").
  // Without XDG_RUNTIME_DIR there is no private place for it, and a shared
  // one like /tmp would let another user plant symlinks: no feed then.
  readonly property string runtimeDir: {
    var base = String(Quickshell.env("XDG_RUNTIME_DIR") || "")
    return base ? base + "/flightline" : ""
  }

  function localPath(url) {
    return decodeURIComponent(url.toString().replace(/^file:\/\//, ""))
  }

  // Inline shell.json entry of the bar widget, pushed in by BarWidget.qml.
  property var settings: ({})
  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null || v === "" ? fallback : v
  }

  readonly property real nearbyRadiusNm: Model.clamp(Model.numberOr(setting("nearbyRadiusNm", 100), 100), 5, Model.MAX_RADIUS_NM)
  // "feedSource", not v0.1's "dataSource": that one was saved as "adsb.fi"
  // on every v0.1 entry and would hold every v2 request to 250 NM.
  readonly property string feedSource: String(setting("feedSource", "adsb.lol")) === "adsb.fi" ? "adsb.fi" : "adsb.lol"
  readonly property bool wideQueries: setting("wideQueries", true) !== false
  readonly property string units: Model.resolveUnits(String(setting("units", "auto")), Qt.locale().name, timeZone)

  // "auto" units follow the system clock's zone (see Model.resolveUnits).
  property string timeZone: ""
  Process {
    running: true
    command: ["timedatectl", "show", "--property=Timezone", "--value"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.timeZone = String(text || "").trim().slice(0, 64)
    }
  }

  // Request spacing per host, shared by the feed, flight search and route
  // lookups. Plain bookkeeping: nothing binds to it.
  property var hostLastMs: ({})
  readonly property int lookupGapMs: 1100        // adsbdb
  readonly property int feedHostGapMs: 3000      // the feed hosts, also for flight search

  function hostWaitMs(url, gapMs) {
    var last = hostLastMs[Model.urlHost(url)] || 0
    return Math.max(0, last + gapMs - Date.now())
  }

  // curl argv for a request whose body arrives on stdout. With `withStatus`
  // the HTTP status goes to stderr instead of failing the run, so callers can
  // tell "not found" from "rate limited". Also records the host for spacing,
  // since every caller starts the process right after building it.
  function curlArgs(url, maxTime, withStatus) {
    hostLastMs[Model.urlHost(url)] = Date.now()
    var args = ["curl", "--silent", "--show-error", "--compressed",
                "--proto", "=https", "--max-time", String(maxTime || 12),
                "--max-filesize", "16777216", "--user-agent", userAgent]
    args = args.concat(withStatus ? ["--write-out", "%{stderr}%{http_code}"] : ["--fail"])
    return args.concat([url])
  }

  // ------------------------------------------------------------- location

  // { name, lat, lon, source: "manual" | "wifi" | "omarchy" | "ip" | "", accuracyM }
  readonly property var home: resolveHome()
  readonly property bool hasHome: Model.isValidLatLon(home.lat, home.lon)
  // Changes only when home really moves, not on every settings write.
  readonly property string homeKey: hasHome ? home.lat.toFixed(4) + "," + home.lon.toFixed(4) : ""
  property var omarchyLocation: ({ name: "", lat: NaN, lon: NaN })
  property var omarchyGeocoded: null   // coordinates for a name-only weather location
  property var ipLocation: null
  property bool ipLookupFailed: false

  function resolveHome() {
    var lat = Model.numberOr(setting("homeLat", NaN), NaN)
    var lon = Model.numberOr(setting("homeLon", NaN), NaN)
    if (Model.isValidLatLon(lat, lon))
      return { name: String(setting("homeName", "")), lat: lat, lon: lon,
               source: String(setting("homeSource", "manual")),
               accuracyM: Model.numberOr(setting("homeAccuracyM", 0), 0) }
    var o = omarchyLocation
    if (Model.isValidLatLon(o.lat, o.lon))
      return { name: o.name, lat: o.lat, lon: o.lon, source: "omarchy", accuracyM: 0 }
    if (o.name && omarchyGeocoded && omarchyGeocoded.query === o.name)
      return { name: o.name, lat: omarchyGeocoded.lat, lon: omarchyGeocoded.lon, source: "omarchy", accuracyM: 0 }
    if (ipLocation)
      return { name: ipLocation.name, lat: ipLocation.lat, lon: ipLocation.lon, source: "ip", accuracyM: 0 }
    return { name: "", lat: NaN, lon: NaN, source: "", accuracyM: 0 }
  }

  // The weather panel owns this file; Flightline only reads it.
  FileView {
    id: omarchyLocationFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.omarchyLocation = Model.parseOmarchyLocation(text())
    onLoadFailed: root.omarchyLocation = Model.parseOmarchyLocation("")
  }

  onOmarchyLocationChanged: {
    var o = omarchyLocation
    if (o.name && !Model.isValidLatLon(o.lat, o.lon)
        && !(omarchyGeocoded && omarchyGeocoded.query === o.name) && !nameGeocodeProc.running) {
      nameGeocodeProc.query = o.name
      nameGeocodeProc.command = curlArgs(geocodeUrl(o.name, 1), 8)
      nameGeocodeProc.running = true
    }
    Qt.callLater(ensureFallbackLocation)
  }

  function ensureFallbackLocation() {
    if (hasHome || ipLookupFailed || ipProc.running) return
    // Same service Omarchy's weather panel uses for its auto-detect.
    ipProc.command = curlArgs("https://wttr.in/?format=j1", 15)
    ipProc.running = true
  }

  Process {
    id: nameGeocodeProc
    property string query: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = Model.parseGeocoding(text)
        if (rows.length > 0)
          root.omarchyGeocoded = { query: nameGeocodeProc.query, lat: rows[0].lat, lon: rows[0].lon }
        else
          Qt.callLater(root.ensureFallbackLocation)
      }
    }
  }

  Process {
    id: ipProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var area = Model.parseWttrArea(text)
        if (area) root.ipLocation = area
        else root.ipLookupFailed = true
      }
    }
  }

  // Persist a home location on the widget's own shell.json entry. Settings
  // are inline on the entry (shell/README.md "Storage rules"), so this writes
  // the whole entry back with the location keys replaced.
  function saveHome(name, lat, lon, source, accuracyM) {
    var next = {}
    for (var k in settings) if (k !== "id") next[k] = settings[k]
    if (Model.isValidLatLon(lat, lon)) {
      next.homeName = String(name || "")
      next.homeLat = Math.round(lat * 10000) / 10000
      next.homeLon = Math.round(lon * 10000) / 10000
      next.homeSource = source
      if (accuracyM > 0) next.homeAccuracyM = Math.round(accuracyM)
      else delete next.homeAccuracyM
    } else {
      delete next.homeName
      delete next.homeLat
      delete next.homeLon
      delete next.homeSource
      delete next.homeAccuracyM
    }
    // Optimistic local copy so the UI moves before the config round-trip.
    root.settings = next
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(root.pluginId, next)
  }

  function clearHome() {
    saveHome("", NaN, NaN, "", 0)
    if (!Model.isValidLatLon(omarchyLocation.lat, omarchyLocation.lon)) Qt.callLater(ensureFallbackLocation)
  }

  // ------------------------------------------------------------ place search

  property var placeSuggestions: []
  property string placeQuery: ""
  property string placeActiveQuery: ""
  readonly property bool searchingPlaces: placeProc.running

  function geocodeUrl(name, count) {
    return "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(name)
      + "&count=" + count + "&language=en&format=json"
  }

  function searchPlaces(text) {
    var q = String(text || "").trim()
    placeQuery = q
    if (q.length < 2) {
      placeSuggestions = []
      return
    }
    if (!placeProc.running) startPlaceSearch()
  }

  function startPlaceSearch() {
    placeActiveQuery = placeQuery
    placeProc.command = curlArgs(geocodeUrl(placeActiveQuery, 6), 8)
    placeProc.running = true
  }

  Process {
    id: placeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.placeSuggestions = root.placeQuery.length >= 2 ? Model.parseGeocoding(text) : []
        if (root.placeQuery !== root.placeActiveQuery && root.placeQuery.length >= 2)
          Qt.callLater(root.startPlaceSearch)
      }
    }
  }

  // --------------------------------------------------------- flight search

  // Find an aircraft anywhere in the world by callsign (TAM3054), ticket
  // flight number (LA 3054), registration (PR-XMA) or ICAO hex. Lookups run
  // one at a time, spaced per host, and stop at the first aircraft found.
  property var flightResults: []
  property string flightStatus: ""     // "" | searching | found | notfound
  property string flightQuery: ""
  property var flightSteps: []
  property int flightSerial: 0

  function findFlight(text) {
    var lookups = Model.flightLookups(text)
    flightSerial++
    flightQuery = String(text || "").trim()
    flightResults = []
    flightSteps = lookups
    flightStatus = lookups.length ? "searching" : ""
    flightStepTimer.stop()
    if (lookups.length && !flightProc.running) nextFlightStep()
  }

  function flightStepUrl(step) {
    return step.kind === "iata" ? "https://api.adsbdb.com/v0/airline/" + encodeURIComponent(step.airline)
                                : Model.flightLookupUrl(step)
  }

  function nextFlightStep() {
    if (flightProc.running) return
    if (flightResults.length > 0 || flightSteps.length === 0) {
      if (flightStatus === "searching") flightStatus = flightResults.length ? "found" : "notfound"
      return
    }
    var step = flightSteps[0]
    var url = flightStepUrl(step)
    var wait = hostWaitMs(url, lookupGapMs)
    // Searches go to adsb.fi: same spacing as the feed, and not while it backs off.
    if (Model.urlHost(url) === Model.SOURCE_HOSTS["adsb.fi"])
      wait = Math.max(hostWaitMs(url, feedHostGapMs), sourceHealth["adsb.fi"].retryAtMs - Date.now())
    if (wait > 0) {
      flightStepTimer.interval = wait
      flightStepTimer.restart()
      return
    }
    flightSteps = flightSteps.slice(1)
    flightProc.serial = flightSerial
    flightProc.step = step
    flightProc.command = curlArgs(url, step.kind === "iata" ? 8 : 10)
    flightProc.running = true
  }

  Timer {
    id: flightStepTimer
    onTriggered: root.nextFlightStep()
  }

  Process {
    id: flightProc
    property int serial: 0
    property var step: null
    stdout: StdioCollector { id: flightOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (flightProc.serial !== root.flightSerial) {
        // A newer search started while this one ran.
        if (root.flightStatus === "searching") Qt.callLater(root.nextFlightStep)
        return
      }
      var step = flightProc.step
      if (step && step.kind === "iata") {
        var prefixes = exitCode === 0 ? Model.parseAirlinePrefixes(flightOut.text, step.airline)
                                      : Model.parseAirlinePrefixes("", step.airline)
        var expanded = prefixes.map(function(p) { return { kind: "callsign", value: p + step.number } })
        root.flightSteps = expanded.concat(root.flightSteps)
      } else if (exitCode === 0) {
        var parsed = Model.parseFeed(flightOut.text, Date.now())
        if (parsed.ok && parsed.aircraft.length) root.flightResults = parsed.aircraft.slice(0, 5)
      }
      Qt.callLater(root.nextFlightStep)
    }
  }

  // -------------------------------------------------------------- Wi-Fi

  property string locateError: ""
  readonly property bool locating: locateProc.running

  function locateWithWifi() {
    if (locateProc.running) return
    locateError = ""
    locateProc.command = [locatePath]
    locateProc.running = true
  }

  Process {
    id: locateProc
    stdout: StdioCollector { id: locateOut; waitForEnd: true }
    stderr: StdioCollector { id: locateErr; waitForEnd: true }
    onExited: function(exitCode) {
      var fix = exitCode === 0 ? Model.parseLocate(locateOut.text) : null
      if (!fix) {
        var reason = String(locateErr.text || "").trim().split("\n").pop()
        root.locateError = reason ? reason.slice(0, 120) : "Wi-Fi location failed"
        return
      }
      root.saveHome("Wi-Fi location", fix.lat, fix.lon, "wifi", fix.accuracyM)
    }
  }

  // ------------------------------------------------------------- traffic

  // What the panel is looking at, pushed by the panel when the camera
  // settles. Closed, only the overhead circle around home is polled.
  // Every panel (one per monitor) reports itself through setPanelOpen, so
  // one closing or being destroyed never hides another one that is open.
  property bool panelOpen: false
  property var openPanels: []

  function setPanelOpen(panel, open) {
    var list = openPanels.filter(function(p) { return p !== panel })
    if (open) list.push(panel)
    openPanels = list
    panelOpen = list.length > 0
  }
  property var view: null               // { lat, lon, radiusNm } visible circle
  readonly property string mode: Model.feedMode(panelOpen, view ? view.radiusNm : NaN)
  readonly property var wantedQuery: Model.feedQuery(mode, panelOpen ? view : null, home, nearbyRadiusNm)

  property string status: "idle"        // idle | loading | ok | error
  property string errorText: ""
  property string activeSource: ""
  property var lastQuery: null           // { lat, lon, radiusNm } of the last answer
  property double lastUpdateMs: 0

  // The last flightline-feed run. trafficRev changes last, once everything
  // else describes the new traffic.ppm / meta.json.
  readonly property string trafficPath: "file://" + encodeURI(runtimeDir + "/traffic.ppm")
  property int trafficRev: 0
  property int trafficCount: 0
  property double epochMs: 0
  property real maxGs: 0
  property var summary: null
  property int airborneCount: -1
  property int worldCount: -1            // airborne total of the last world answer
  property var emergencies: []
  property int nearbyCount: -1           // -1 = unknown
  property double nearbyMs: 0            // when nearbyCount was last true
  property var nearest: []               // summary.home.nearest, closest first
  property var nearestAny: []            // summary.home.nearestAny: closest anywhere when nearest is empty

  // Scheduler state (see Model.planFetch).
  property double lastAttemptMs: 0
  property double lastSuccessMs: 0
  property real cadenceJitter: Math.random()
  property bool forceNext: false
  property int requestSerial: 0
  property int failuresInRow: 0
  property var sourceHealth: ({
    "adsb.lol": { failures: 0, retryAtMs: 0 },
    "adsb.fi": { failures: 0, retryAtMs: 0 }
  })
  // True from curl's start to the helper's end. Not Process.running: that is
  // still true inside onExited, where the next request gets scheduled.
  property bool fetching: false

  function setView(lat, lon, visibleRadiusNm) {
    var wrapped = Model.wrapLon(Model.numberOr(lon, NaN))
    var radius = Model.numberOr(visibleRadiusNm, NaN)
    if (!Model.isValidLatLon(lat, wrapped) || !(radius > 0)) return
    var prev = view
    if (prev && prev.lat === lat && prev.lon === wrapped && prev.radiusNm === radius) return
    view = { lat: lat, lon: wrapped, radiusNm: radius }
  }

  // Right click on the pill. A request already in flight is as fresh as it gets.
  function refresh() {
    if (fetching) return
    forceNext = true
    schedule()
  }

  onWantedQueryChanged: Qt.callLater(schedule)
  onHomeKeyChanged: {
    nearbyCount = -1
    nearbyMs = 0
    nearest = []
    nearestAny = []
  }
  // A smaller circle is still "covered" by the last answer, but its count is not.
  onNearbyRadiusNmChanged: refresh()
  onPanelOpenChanged: {
    // The parsed world meta is the biggest thing Flightline holds; drop it.
    if (!panelOpen) releaseMeta()
    Qt.callLater(schedule)
  }
  // Switching source or wide queries applies to the next request.
  onFeedSourceChanged: Qt.callLater(schedule)
  onWideQueriesChanged: Qt.callLater(schedule)

  function planNow() {
    return Model.planFetch({
      nowMs: Date.now(),
      mode: mode,
      query: wantedQuery,
      viewRadiusNm: panelOpen && view ? view.radiusNm : NaN,
      centre: panelOpen && view ? view : (hasHome ? home : null),
      lastQuery: lastQuery,
      lastSuccessMs: lastSuccessMs,
      lastAttemptMs: lastAttemptMs,
      cadenceMs: Model.cadenceMs(mode, cadenceJitter),
      force: forceNext,
      health: sourceHealth,
      hostLastMs: hostLastMs,
      preferred: feedSource,
      wide: wideQueries
    })
  }

  // Arm the one feed timer for the next request. Safe to call any time; a
  // request in flight schedules the next one when it finishes.
  function schedule() {
    if (fetching) return
    if (!runtimeDir) {
      status = "error"
      errorText = "XDG_RUNTIME_DIR is not set; the feed needs a private runtime dir"
      return
    }
    var plan = planNow()
    if (!plan) {
      feedTimer.stop()
      if (status === "loading") status = "idle"
      return
    }
    feedTimer.interval = Math.max(0, Math.max(plan.atMs, helperRetryAtMs) - Date.now())
    feedTimer.restart()
  }

  Timer {
    id: feedTimer
    onTriggered: root.startFetch()
  }

  function startFetch() {
    if (fetching) return
    var plan = planNow()
    if (!plan) return
    if (Math.max(plan.atMs, helperRetryAtMs) > Date.now() + 50) {
      schedule()
      return
    }
    requestSerial++
    var raw = runtimeDir + "/raw-" + requestSerial + ".json"
    var world = plan.query.radiusNm >= Model.WORLD_RADIUS_NM
    fetchProc.plan = plan
    fetchProc.raw = raw
    fetchProc.serial = requestSerial
    fetchProc.startMs = Date.now()
    // The body goes straight to tmpfs; only the status code comes back here.
    fetchProc.command = ["curl", "--silent", "--show-error", "--compressed",
                         "--proto", "=https", "--max-time", world ? "30" : "15",
                         "--max-filesize", "16777216", "--create-dirs", "--output", raw,
                         "--write-out", "%{http_code}", "--user-agent", userAgent, plan.url]
    lastAttemptMs = Date.now()
    hostLastMs[plan.host] = lastAttemptMs
    forceNext = false
    // "error" stays until a request succeeds, so retries do not flicker.
    if (status === "idle") status = "loading"
    fetching = true
    fetchProc.awaiting = true
    fetchProc.running = true
  }

  Process {
    id: fetchProc
    property var plan: null
    property string raw: ""
    property int serial: 0
    property double startMs: 0
    property bool awaiting: false

    stdout: StdioCollector { id: fetchOut; waitForEnd: true }
    stderr: StdioCollector { id: fetchErr; waitForEnd: true }

    onExited: function(exitCode) {
      fetchProc.awaiting = false
      var result = Model.classifyFetch(exitCode, fetchOut.text)
      if (!result.ok) {
        root.fetching = false
        root.removeFile(fetchProc.raw)
        root.logFeed(fetchProc.plan, false, result.code, -1, result.rateLimited ? "rate limited" : result.error)
        root.feedFailed(fetchProc.plan.source, result, fetchErr.text)
        return
      }
      root.runFeedHelper(fetchProc.plan, fetchProc.raw, fetchProc.serial, fetchProc.startMs)
    }
    // curl missing: no exited signal, only running going false.
    onRunningChanged: if (!running && awaiting) {
      awaiting = false
      root.fetching = false
      root.feedFailed(plan.source, { rateLimited: false, error: "curl is not installed" }, "")
    }
  }

  function runFeedHelper(plan, raw, serial, startMs) {
    var q = plan.query
    // A world answer covers the Earth from any centre; centred on the view,
    // the helper drops far-away aircraft first if the world ever overflows
    // the texture.
    var c = q.radiusNm >= Model.WORLD_RADIUS_NM && view ? view : q
    // Through python3, so a lost executable bit (zip download) does not matter.
    var args = ["python3", feedPath, "--in=" + raw, "--out-dir=" + runtimeDir, "--rev=" + serial,
                "--source=" + plan.source, "--fetched-ms=" + Math.round(startMs),
                "--query=" + c.lat.toFixed(4) + "," + c.lon.toFixed(4) + "," + Math.round(q.radiusNm)]
    // "=" keeps argparse from reading a negative latitude as an option.
    if (hasHome)
      args.push("--home=" + home.lat.toFixed(4) + "," + home.lon.toFixed(4), "--radius=" + nearbyRadiusNm)
    feedProc.plan = plan
    feedProc.raw = raw
    feedProc.sentHome = hasHome ? { lat: home.lat, lon: home.lon, radiusNm: nearbyRadiusNm } : null
    feedProc.command = args
    feedProc.awaiting = true
    feedProc.running = true
  }

  Process {
    id: feedProc
    property var plan: null
    property string raw: ""
    property var sentHome: null
    property bool awaiting: false

    stdout: StdioCollector { id: feedOut; waitForEnd: true }
    stderr: StdioCollector { id: feedErr; waitForEnd: true }

    onExited: function(exitCode) {
      feedProc.awaiting = false
      root.fetching = false
      var s = Model.parseSummary(feedOut.text)
      if (exitCode !== 0 || !s || !s.ok) {
        // The helper deletes its input when it succeeds; a crash may not.
        root.removeFile(feedProc.raw)
        var reason = s && s.error ? s.error : String(feedErr.text || "").trim().split("\n").pop()
        root.logFeed(feedProc.plan, false, 200, -1, "helper: " + (reason || "unreadable output"))
        // Exit 2 with a reason means the source sent garbage; anything else
        // is the helper's own fault and says nothing about the source.
        if (exitCode === 2 && s && !s.ok) root.feedFailed(feedProc.plan.source, { rateLimited: false, error: reason }, "")
        else root.helperFailed(reason || "unreadable output")
        return
      }
      root.acceptSummary(feedProc.plan, feedProc.sentHome, s)
    }
    onRunningChanged: if (!running && awaiting) {
      awaiting = false
      root.fetching = false
      root.removeFile(raw)
      root.helperFailed("could not start (is python3 installed?)")
    }
  }

  // The helper broke, not the source: report it and back off without
  // blaming the source (no fallback to adsb.fi for a local problem).
  property int helperFailures: 0
  property double helperRetryAtMs: 0
  function helperFailed(reason) {
    helperFailures++
    helperRetryAtMs = Date.now() + Model.backoffMs(helperFailures, Math.random())
    failuresInRow++
    if (trafficRev === 0 || failuresInRow >= 2) status = "error"
    errorText = ("flightline-feed: " + reason).slice(0, 120)
    schedule()
  }

  function feedFailed(source, result, stderrText) {
    var health = sourceHealth[source]
    health.failures++
    health.retryAtMs = Date.now() + Model.backoffMs(health.failures, Math.random())
    failuresInRow++
    // One hiccup with data on screen is not worth an error state.
    if (trafficRev === 0 || failuresInRow >= 2) status = "error"
    var reason = String(stderrText || "").trim().split("\n").pop().replace(/^curl: \(\d+\)\s*/, "")
    errorText = (source + ": " + (result.rateLimited ? "busy, slowing down" : (reason || result.error))).slice(0, 120)
    schedule()
  }

  // The last few feed requests, for `omarchy-shell flightline status`.
  // Radius and timing only: never a centre, so the status stays location-free.
  property var feedLog: []
  function logFeed(plan, ok, code, n, error) {
    var log = feedLog.slice(-11)
    log.push({ atMs: Date.now(), source: plan ? plan.source : "", mode: mode,
               nm: plan ? Math.round(plan.query.radiusNm) : 0, ok: ok, code: code || 0,
               ms: Math.round(Date.now() - fetchProc.startMs), n: n, error: String(error || "").slice(0, 60) })
    feedLog = log
  }

  function acceptSummary(plan, sentHome, s) {
    logFeed(plan, true, 200, s.n, "")
    var health = sourceHealth[plan.source]
    health.failures = 0
    health.retryAtMs = 0
    failuresInRow = 0
    helperFailures = 0
    helperRetryAtMs = 0
    lastQuery = plan.query
    lastSuccessMs = Date.now()
    lastUpdateMs = lastSuccessMs
    cadenceJitter = Math.random()
    activeSource = plan.source
    summary = s
    epochMs = s.epochMs
    maxGs = s.maxGs
    trafficCount = s.n
    airborneCount = s.airborne
    emergencies = s.emergencies
    nearestAny = s.home && s.home.count === 0 ? s.home.nearestAny : []
    if (plan.query.radiusNm >= Model.WORLD_RADIUS_NM) worldCount = s.airborne
    updateNearby(plan.query, sentHome, s.home)
    errorText = ""
    status = "ok"
    trafficRev = s.rev
    schedule()
  }

  // The overhead count is only true when the answer covered the whole circle
  // and home has not moved since the request went out.
  function updateNearby(query, sentHome, h) {
    if (!h || !sentHome || !hasHome) return
    if (sentHome.lat !== home.lat || sentHome.lon !== home.lon || sentHome.radiusNm !== nearbyRadiusNm) return
    if (!Model.queryCovers(query.lat, query.lon, query.radiusNm, home.lat, home.lon, nearbyRadiusNm)) return
    nearbyCount = h.count
    nearbyMs = Date.now()
    nearest = h.nearest
  }

  property var removeQueue: []
  function removeFile(path) {
    if (!path) return
    removeQueue = removeQueue.concat([path])
    if (!removeProc.running) nextRemove()
  }
  function nextRemove() {
    if (removeQueue.length === 0) return
    removeProc.command = ["rm", "-f", "--", removeQueue[0]]
    removeQueue = removeQueue.slice(1)
    removeProc.running = true
  }
  Process {
    id: removeProc
    onExited: Qt.callLater(root.nextRemove)
  }

  // ----------------------------------------------------------------- meta

  // meta.json is read and parsed only when something asks (hover, click,
  // labels, cards) and at most once per revision. The read blocks, but it
  // is a tmpfs file written moments ago.
  FileView {
    id: metaFile
    preload: false
    blockAllReads: true
    printErrors: false
  }
  property var metaState: ({ rev: -1, data: null })

  function meta() {
    if (trafficRev <= 0) return null
    if (metaState.rev === trafficRev) return metaState.data
    // Remember the attempt even if it fails, so a bad file is read once.
    metaState.rev = trafficRev
    metaState.data = null
    var path = runtimeDir + "/meta.json"
    if (metaFile.path !== path) metaFile.path = path
    else metaFile.reload()
    var parsed = Model.parseMeta(metaFile.text())
    // A meta.json from another revision would not line up with traffic.ppm.
    if (parsed && Model.numberOr(parsed.rev, -1) === trafficRev) metaState.data = parsed
    return metaState.data
  }

  function releaseMeta() {
    metaState = { rev: -1, data: null }
    metaFile.path = ""
  }

  function aircraftAt(i) {
    return Model.metaRow(meta(), i)
  }

  // --------------------------------------------------------------- routes

  // adsbdb routes, in memory only (never bundled or written to disk).
  property var routes: ({})            // callsign → route | null (unknown)
  property var routeQueue: []
  property var routeRetryAtMs: ({})    // callsign → when a failed lookup may run again

  function routeFor(callsign) {
    var cs = String(callsign || "").toUpperCase()
    if (!Model.CALLSIGN_RE.test(cs)) return null
    var known = routes.hasOwnProperty(cs)
    var retryAt = routeRetryAtMs[cs] || 0
    if (known && (retryAt === 0 || Date.now() < retryAt)) return routes[cs]
    if (routeQueue.indexOf(cs) === -1) {
      routeQueue = routeQueue.concat([cs])
      Qt.callLater(nextRoute)
    }
    return known ? routes[cs] : null
  }

  function routePlausible(route, lat, lon) {
    return Model.routePlausible(route, lat, lon)
  }

  function nextRoute() {
    if (routeProc.running || routeQueue.length === 0) return
    var callsign = routeQueue[0]
    var url = "https://api.adsbdb.com/v0/callsign/" + encodeURIComponent(callsign)
    var wait = hostWaitMs(url, lookupGapMs)
    if (wait > 0) {
      routeTimer.interval = wait
      routeTimer.restart()
      return
    }
    routeQueue = routeQueue.slice(1)
    routeProc.callsign = callsign
    routeProc.command = curlArgs(url, 8, true)
    routeProc.running = true
  }

  Timer {
    id: routeTimer
    onTriggered: root.nextRoute()
  }

  Process {
    id: routeProc
    property string callsign: ""
    stdout: StdioCollector { id: routeOut; waitForEnd: true }
    stderr: StdioCollector { id: routeErr; waitForEnd: true }
    onExited: function(exitCode) {
      var result = Model.classifyFetch(exitCode, routeErr.text)
      var cs = routeProc.callsign
      // Start over past 2,000 callsigns, which takes days of panning.
      var next = {}
      if (Object.keys(root.routes).length < 2000)
        for (var k in root.routes) next[k] = root.routes[k]
      // A 404 means adsbdb does not know the callsign; cache that for good.
      // Anything else (rate limit, outage) is retried after five minutes.
      next[cs] = result.ok ? Model.parseRoute(routeOut.text) : null
      if (result.ok || result.code === 404) delete root.routeRetryAtMs[cs]
      else root.routeRetryAtMs[cs] = Date.now() + 300000
      root.routes = next
      Qt.callLater(root.nextRoute)
    }
  }

  Component.onCompleted: {
    omarchyLocationFile.reload()
    // The first read can race shell startup; one delayed retry self-corrects.
    startupTimer.start()
    Qt.callLater(schedule)
  }

  Timer {
    id: startupTimer
    interval: 1500
    onTriggered: {
      omarchyLocationFile.reload()
      root.ensureFallbackLocation()
    }
  }
}
