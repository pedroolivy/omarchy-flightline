.pragma library

// Pure functions shared by Service.qml and the panel.
// Nothing here touches QML objects, the network or the filesystem, so the
// whole file is exercised by tests/model.test.mjs under plain Node.

var NM_KM = 1.852
var FT_M = 0.3048
var KT_KMH = 1.852
var KT_MPH = 1.150779
var KM_MI = 0.621371
var EARTH_RADIUS_KM = 6371.0088
var MAX_RADIUS_NM = 250              // adsb.fi refuses (and counts) anything larger
var MAX_AIRCRAFT = 2500
var MAX_EXTRAPOLATION_S = 45
var DEG = Math.PI / 180

// ---------------------------------------------------------------- numbers

function clamp(value, min, max) {
  return value < min ? min : (value > max ? max : value)
}

function finite(value) {
  return typeof value === "number" && isFinite(value)
}

function numberOr(value, fallback) {
  var n = typeof value === "string" && value.trim() !== "" ? Number(value) : value
  return finite(n) ? n : fallback
}

function wrapLon(lon) {
  if (lon >= -180 && lon <= 180) return lon
  var wrapped = ((lon + 180) % 360 + 360) % 360 - 180
  return wrapped === -180 && lon > 0 ? 180 : wrapped
}

function normalizeAngle(deg) {
  return ((deg % 360) + 360) % 360
}

// Shortest signed difference b - a in degrees, in (-180, 180].
function angleDelta(a, b) {
  var d = normalizeAngle(b - a)
  return d > 180 ? d - 360 : d
}

function isValidLatLon(lat, lon) {
  return finite(lat) && finite(lon) && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
}

// ---------------------------------------------------------- sphere maths

function vecFromLonLat(lon, lat) {
  var lam = lon * DEG
  var phi = lat * DEG
  var c = Math.cos(phi)
  return [c * Math.cos(lam), c * Math.sin(lam), Math.sin(phi)]
}

// Rows of the rotation that brings (centerLon, centerLat) to the viewer:
// x points east, y north, z towards the eye. A point is on the visible
// hemisphere when its rotated z is positive.
function viewMatrix(centerLon, centerLat) {
  var l = centerLon * DEG
  var p = centerLat * DEG
  var sl = Math.sin(l), cl = Math.cos(l), sp = Math.sin(p), cp = Math.cos(p)
  return [
    -sl, cl, 0,
    -sp * cl, -sp * sl, cp,
    cp * cl, cp * sl, sp
  ]
}

// Orthographic projection of lon/lat into unit-sphere view space.
function projectLonLat(m, lon, lat) {
  var lam = lon * DEG
  var phi = lat * DEG
  var c = Math.cos(phi)
  var x = c * Math.cos(lam), y = c * Math.sin(lam), z = Math.sin(phi)
  return {
    x: m[0] * x + m[1] * y,
    y: m[3] * x + m[4] * y + m[5] * z,
    z: m[6] * x + m[7] * y + m[8] * z
  }
}

// Inverse of projectLonLat for a point inside the unit disc. Returns null
// outside the globe.
function unprojectUnit(m, ux, uy) {
  var r2 = ux * ux + uy * uy
  if (r2 > 1) return null
  var uz = Math.sqrt(1 - r2)
  // Transpose of the rotation brings view space back to the earth frame.
  var x = m[0] * ux + m[3] * uy + m[6] * uz
  var y = m[1] * ux + m[4] * uy + m[7] * uz
  var z = m[5] * uy + m[8] * uz
  return {
    lon: Math.atan2(y, x) / DEG,
    lat: Math.asin(clamp(z, -1, 1)) / DEG
  }
}

// Angular radius (radians) of the part of the globe visible in a viewport
// whose half-diagonal is `halfDiagonalPx` when the globe radius is `radiusPx`.
function visibleAngularRadius(radiusPx, halfDiagonalPx) {
  if (radiusPx <= 0) return Math.PI / 2
  var ratio = halfDiagonalPx / radiusPx
  return ratio >= 1 ? Math.PI / 2 : Math.asin(ratio)
}

// ----------------------------------------------------------- geodesy

function distanceKm(lat1, lon1, lat2, lon2) {
  var p1 = lat1 * DEG, p2 = lat2 * DEG
  var dp = (lat2 - lat1) * DEG
  var dl = (lon2 - lon1) * DEG
  var a = Math.sin(dp / 2) * Math.sin(dp / 2)
    + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2)
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(a)))
}

function bearingDeg(lat1, lon1, lat2, lon2) {
  var p1 = lat1 * DEG, p2 = lat2 * DEG
  var dl = (lon2 - lon1) * DEG
  var y = Math.sin(dl) * Math.cos(p2)
  var x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl)
  return normalizeAngle(Math.atan2(y, x) / DEG)
}

function destination(lat, lon, bearing, distanceKmValue) {
  var d = distanceKmValue / EARTH_RADIUS_KM
  var b = bearing * DEG
  var p1 = lat * DEG
  var l1 = lon * DEG
  var sinP2 = Math.sin(p1) * Math.cos(d) + Math.cos(p1) * Math.sin(d) * Math.cos(b)
  var p2 = Math.asin(clamp(sinP2, -1, 1))
  var l2 = l1 + Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(p1), Math.cos(d) - Math.sin(p1) * sinP2)
  return { lat: p2 / DEG, lon: wrapLon(l2 / DEG) }
}

// Great-circle interpolation, t in [0, 1]. Used for fly-to animations so a
// long pan follows the globe instead of cutting through lon/lat space.
function slerpLonLat(lat1, lon1, lat2, lon2, t) {
  var a = vecFromLonLat(lon1, lat1)
  var b = vecFromLonLat(lon2, lat2)
  var dot = clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1, 1)
  var omega = Math.acos(dot)
  if (omega < 1e-6) return { lat: lat2, lon: lon2 }
  var s = Math.sin(omega)
  var wa = Math.sin((1 - t) * omega) / s
  var wb = Math.sin(t * omega) / s
  var x = wa * a[0] + wb * b[0]
  var y = wa * a[1] + wb * b[1]
  var z = wa * a[2] + wb * b[2]
  return { lat: Math.asin(clamp(z, -1, 1)) / DEG, lon: Math.atan2(y, x) / DEG }
}

// ------------------------------------------------------------ data feeds

// adsb.lol answers any radius, so it serves every mode; adsb.fi is the
// fallback and only ever sees a circle of at most MAX_RADIUS_NM.
var SOURCES = ["adsb.lol", "adsb.fi"]
var SOURCE_HOSTS = { "adsb.lol": "api.adsb.lol", "adsb.fi": "opendata.adsb.fi" }
var WORLD_RADIUS_NM = 10800          // half the Earth's circumference
var WORLD_VIEW_NM = 1500             // views wider than this fetch the whole world
var REGION_MIN_NM = 50
var REGION_MAX_NM = 3000

function feedUrl(source, lat, lon, radiusNm) {
  var la = clamp(lat, -90, 90).toFixed(4)
  var lo = wrapLon(lon).toFixed(4)
  if (source === "adsb.lol")
    return "https://api.adsb.lol/v2/point/" + la + "/" + lo + "/" + Math.round(clamp(radiusNm, 1, WORLD_RADIUS_NM))
  return "https://opendata.adsb.fi/api/v3/lat/" + la + "/lon/" + lo + "/dist/" + Math.round(clamp(radiusNm, 1, MAX_RADIUS_NM))
}

function urlHost(url) {
  var m = /^https?:\/\/([^\/:?#]+)/.exec(String(url || ""))
  return m ? m[1].toLowerCase() : ""
}

// Control, bidi and other invisible format characters (same class as
// flightline-feed's CONTROL_RE): none of them may reorder or hide panel text.
var CONTROL_RE = /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]/g

function cleanString(value, maxLength, pattern) {
  if (typeof value !== "string") return ""
  var s = value.replace(CONTROL_RE, "").trim()
  if (s.length > maxLength) s = s.slice(0, maxLength)
  if (pattern && !pattern.test(s)) return ""
  return s
}

var HEX_RE = /^~?[0-9a-f]{6}$/
var CALLSIGN_RE = /^[A-Z0-9-]{1,8}$/
var REG_RE = /^[A-Z0-9-]{1,10}$/
var TYPE_RE = /^[A-Z0-9]{1,4}$/
var SQUAWK_RE = /^[0-7]{4}$/
var CATEGORY_RE = /^[A-D][0-7]$/

// Normalise one feed record. Every field the UI reads is validated here so
// remote data can never reach the scene graph as rich text, NaN or an
// unbounded string. Returns null for records that cannot be placed.
function sanitizeAircraft(raw, receivedAtMs) {
  if (!raw || typeof raw !== "object") return null
  var hex = cleanString(raw.hex, 7).toLowerCase()
  if (!HEX_RE.test(hex)) return null
  var lat = numberOr(raw.lat, NaN)
  var lon = numberOr(raw.lon, NaN)
  if (!isValidLatLon(lat, lon)) return null

  var onGround = raw.alt_baro === "ground"
  var alt = onGround ? 0 : numberOr(raw.alt_baro, numberOr(raw.alt_geom, NaN))
  var seenPos = clamp(numberOr(raw.seen_pos, numberOr(raw.seen, 0)), 0, 600)
  var track = numberOr(raw.track, numberOr(raw.true_heading, numberOr(raw.mag_heading, NaN)))
  var squawk = cleanString(raw.squawk, 4, SQUAWK_RE)
  var emergency = cleanString(raw.emergency, 16)
  var dbFlags = numberOr(raw.dbFlags, 0)

  return {
    hex: hex,
    callsign: cleanString(String(raw.flight || "").toUpperCase(), 8, CALLSIGN_RE),
    registration: cleanString(String(raw.r || "").toUpperCase(), 10, REG_RE),
    type: cleanString(String(raw.t || "").toUpperCase(), 4, TYPE_RE),
    description: cleanString(raw.desc, 48),
    operator: cleanString(raw.ownOp, 48),
    category: cleanString(raw.category, 2, CATEGORY_RE),
    lat: lat,
    lon: lon,
    onGround: onGround,
    altitudeFt: finite(alt) ? clamp(Math.round(alt), -2000, 80000) : null,
    groundSpeedKt: finite(numberOr(raw.gs, NaN)) ? clamp(numberOr(raw.gs, 0), 0, 2500) : null,
    track: finite(track) ? normalizeAngle(track) : null,
    verticalRateFpm: finite(numberOr(raw.baro_rate, numberOr(raw.geom_rate, NaN)))
      ? clamp(Math.round(numberOr(raw.baro_rate, numberOr(raw.geom_rate, 0))), -20000, 20000) : null,
    squawk: squawk,
    emergency: emergency !== "none" ? emergency : "",
    military: (dbFlags & 1) === 1,
    positionTimeMs: receivedAtMs - seenPos * 1000
  }
}

// Parse a whole feed response. All three supported feeds share the
// ADS-B Exchange v2 shape: { ac: [...], now: ms }.
function parseFeed(text, receivedAtMs) {
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "invalid response" }
  }
  if (!data || typeof data !== "object") return { ok: false, error: "invalid response" }
  var list = Array.isArray(data.ac) ? data.ac : (Array.isArray(data.aircraft) ? data.aircraft : null)
  if (!list) return { ok: false, error: "no aircraft list" }
  var out = []
  var seen = {}
  for (var i = 0; i < list.length && out.length < MAX_AIRCRAFT; i++) {
    var ac = sanitizeAircraft(list[i], receivedAtMs)
    if (!ac || seen[ac.hex]) continue
    seen[ac.hex] = true
    out.push(ac)
  }
  return { ok: true, aircraft: out }
}

// Dead reckoning: where the aircraft is now, given its last report.
function extrapolate(ac, nowMs) {
  if (!ac || ac.onGround || ac.track === null || ac.groundSpeedKt === null || ac.groundSpeedKt < 30)
    return { lat: ac.lat, lon: ac.lon }
  var dt = clamp((nowMs - ac.positionTimeMs) / 1000, 0, MAX_EXTRAPOLATION_S)
  if (dt <= 0) return { lat: ac.lat, lon: ac.lon }
  return destination(ac.lat, ac.lon, ac.track, ac.groundSpeedKt * KT_KMH * dt / 3600)
}

// ------------------------------------------------------- classification

function isEmergency(ac) {
  return !!ac && (ac.squawk === "7500" || ac.squawk === "7600" || ac.squawk === "7700" || ac.emergency !== "")
}

function emergencyLabel(ac) {
  if (!ac) return ""
  if (ac.squawk === "7500") return "Hijack (7500)"
  if (ac.squawk === "7600") return "Radio failure (7600)"
  if (ac.squawk === "7700") return "Emergency (7700)"
  if (ac.emergency) return "Emergency: " + ac.emergency
  return ""
}

// "glyph" picks the silhouette Globe.qml draws.
function glyphFor(ac) {
  if (!ac) return "jet"
  if (ac.category === "A7") return "rotor"
  if (ac.category === "B1" || ac.category === "B4") return "glider"
  if (ac.category === "B2") return "balloon"
  if (ac.category === "A1" || ac.category === "B6") return "light"
  if (ac.category === "A5" || ac.category === "A4") return "heavy"
  if (ac.category && ac.category.charAt(0) === "C") return "ground"
  return "jet"
}

function phaseOf(ac) {
  if (!ac) return ""
  if (ac.onGround) return "On ground"
  var vr = ac.verticalRateFpm
  if (vr !== null && vr > 400) return "Climbing"
  if (vr !== null && vr < -400) return "Descending"
  if (ac.altitudeFt !== null && ac.altitudeFt >= 18000) return "Cruising"
  return "Level"
}

// ---------------------------------------------------------- formatting

// units: "aviation" (ft, kt, nm), "metric" (m, km/h, km), "imperial" (ft, mph, mi).
//
// "auto" prefers the system time zone over the locale: plenty of people run
// Linux in en_US far from the US, but their clock knows where they are. Only
// the United States, Liberia and Myanmar default to imperial.
var IMPERIAL_ZONE_RE = /^(US\/|Pacific\/Honolulu$|Africa\/Monrovia$|Asia\/(Yangon|Rangoon)$|America\/(New_York|Chicago|Denver|Los_Angeles|Phoenix|Anchorage|Juneau|Sitka|Yakutat|Nome|Metlakatla|Adak|Boise|Detroit|Menominee|Indiana\/|Kentucky\/|North_Dakota\/))/

function resolveUnits(setting, localeName, timeZone) {
  if (setting === "metric" || setting === "imperial" || setting === "aviation") return setting
  var zone = String(timeZone || "").trim()
  if (/^[A-Za-z]+\/[A-Za-z_\/+-]+$/.test(zone)) return IMPERIAL_ZONE_RE.test(zone) ? "imperial" : "metric"
  return /_(US|LR|MM)(\.|@|$)/.test(String(localeName || "")) ? "imperial" : "metric"
}

// Natural Earth's min_zoom is a web-map zoom level; translate the globe's
// pixel radius into the same scale (256 px tiles around the equator).
function webZoomForRadius(radiusPx) {
  return Math.log(Math.max(1, 2 * Math.PI * radiusPx) / 256) / Math.LN2
}

function groupThousands(n) {
  return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function formatAltitude(ac, units) {
  if (!ac) return "—"
  if (ac.onGround) return "Ground"
  if (ac.altitudeFt === null) return "—"
  if (units === "metric") return groupThousands(ac.altitudeFt * FT_M) + " m"
  return groupThousands(ac.altitudeFt) + " ft"
}

function formatSpeed(kt, units) {
  if (kt === null || kt === undefined) return "—"
  if (units === "metric") return Math.round(kt * KT_KMH) + " km/h"
  if (units === "imperial") return Math.round(kt * KT_MPH) + " mph"
  return Math.round(kt) + " kt"
}

function formatDistance(km, units) {
  if (!finite(km)) return "—"
  var value, unit
  if (units === "aviation") { value = km / NM_KM; unit = "nm" }
  else if (units === "imperial") { value = km * KM_MI; unit = "mi" }
  else { value = km; unit = "km" }
  return (value < 10 ? value.toFixed(1) : String(Math.round(value))) + " " + unit
}

function formatRadius(nm, units) {
  return formatDistance(nm * NM_KM, units)
}

function formatVerticalRate(fpm, units) {
  if (fpm === null || fpm === undefined || Math.abs(fpm) < 200) return "Level"
  var arrow = fpm > 0 ? "↑ " : "↓ "
  if (units === "metric") return arrow + Math.round(Math.abs(fpm) * FT_M / 60 * 10) / 10 + " m/s"
  return arrow + groupThousands(Math.abs(fpm)) + " ft/min"
}

var COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

function compassPoint(deg) {
  if (!finite(deg)) return ""
  return COMPASS[Math.round(normalizeAngle(deg) / 45) % 8]
}

function formatHeading(deg) {
  if (!finite(deg)) return "—"
  return Math.round(normalizeAngle(deg)) + "° " + compassPoint(deg)
}

function formatAge(seconds) {
  if (!finite(seconds) || seconds < 0) return ""
  if (seconds < 5) return "just now"
  if (seconds < 60) return Math.round(seconds) + "s ago"
  if (seconds < 3600) return Math.round(seconds / 60) + "m ago"
  return Math.round(seconds / 3600) + "h ago"
}

function displayName(ac) {
  if (!ac) return ""
  return ac.callsign || ac.registration || ac.hex.toUpperCase()
}

// -------------------------------------------------------- nearby list

function nearest(aircraft, lat, lon, limit, includeGround) {
  var rows = []
  for (var i = 0; i < aircraft.length; i++) {
    var ac = aircraft[i]
    if (!includeGround && ac.onGround) continue
    rows.push({ ac: ac, km: distanceKm(lat, lon, ac.lat, ac.lon) })
  }
  rows.sort(function(a, b) { return a.km - b.km })
  return rows.slice(0, limit)
}

// Does a query (center, radius) fully cover the circle (lat, lon, r)?
function queryCovers(queryLat, queryLon, queryRadiusNm, lat, lon, radiusNm) {
  if (!isValidLatLon(queryLat, queryLon) || !isValidLatLon(lat, lon)) return false
  // A world query reaches the antipode of its centre too.
  if (queryRadiusNm >= WORLD_RADIUS_NM) return true
  return distanceKm(queryLat, queryLon, lat, lon) + radiusNm * NM_KM <= queryRadiusNm * NM_KM + 0.5
}

// ------------------------------------------------------- feed planning

// The feed has three modes. With the panel closed only the overhead circle
// around home is polled; with it open the query follows the view, and wide
// views fetch the whole world in one request.
var FEED_GAP_MS = 10000              // between feed requests, whatever triggers them (adsb.lol 429s bursts)
var HOST_GAP_MS = 3000               // between any two requests to one host
var BACKOFF_MIN_MS = 5000
var BACKOFF_MAX_MS = 120000
var FALLBACK_AFTER = 3               // consecutive adsb.lol failures before adsb.fi steps in

function feedMode(panelOpen, visibleRadiusNm) {
  if (!panelOpen) return "home"
  return finite(visibleRadiusNm) && visibleRadiusNm > WORLD_VIEW_NM ? "world" : "region"
}

// The circle a mode wants, before any source limit. `view` is
// { lat, lon, radiusNm } with the radius the panel can see. Returns null
// when there is nothing to ask about yet.
function feedQuery(mode, view, home, nearbyRadiusNm) {
  if (mode === "world") return { lat: 0, lon: 0, radiusNm: WORLD_RADIUS_NM }
  var hasHome = !!home && isValidLatLon(home.lat, home.lon)
  if (mode === "region") {
    var lon = view && finite(view.lon) ? wrapLon(view.lon) : NaN
    if (view && isValidLatLon(view.lat, lon) && finite(view.radiusNm))
      return { lat: view.lat, lon: lon,
               radiusNm: Math.round(clamp(view.radiusNm * 1.15, REGION_MIN_NM, REGION_MAX_NM)) }
    // Opened but not settled yet: start with the air around home.
    return hasHome ? { lat: home.lat, lon: home.lon, radiusNm: MAX_RADIUS_NM } : null
  }
  if (!hasHome) return null
  return { lat: home.lat, lon: home.lon, radiusNm: clamp(numberOr(nearbyRadiusNm, 100), 5, MAX_RADIUS_NM) }
}

// What a source can actually be asked. adsb.fi only takes a small circle, so
// a world query falls back to `centre` (the view or home) at its maximum.
// `wide` === false (the wideQueries setting) holds adsb.lol to the same
// documented limit.
function sourceQuery(source, query, centre, wide) {
  var small = source === "adsb.fi" || wide === false
  if (!query || !small || query.radiusNm <= MAX_RADIUS_NM) return query
  var c = query.radiusNm >= WORLD_RADIUS_NM && centre && isValidLatLon(centre.lat, centre.lon) ? centre : query
  return { lat: c.lat, lon: wrapLon(c.lon), radiusNm: MAX_RADIUS_NM }
}

// Poll interval for a mode; `rand` in [0, 1) spreads requests by ±10 % so
// many desktops never line up on the same second.
function cadenceMs(mode, rand) {
  var base = mode === "region" ? 15000 : 60000
  return Math.round(base * (0.9 + 0.2 * clamp(numberOr(rand, 0.5), 0, 1)))
}

// Exponential backoff after `failures` consecutive failures: 5 s, 10 s,
// 20 s ... capped at 120 s, then jittered by ±15 % inside those bounds.
function backoffMs(failures, rand) {
  if (!(failures > 0)) return 0
  var base = Math.min(BACKOFF_MAX_MS, BACKOFF_MIN_MS * Math.pow(2, Math.min(failures, 16) - 1))
  var jittered = base * (0.85 + 0.3 * clamp(numberOr(rand, 0.5), 0, 1))
  return Math.round(clamp(jittered, BACKOFF_MIN_MS, BACKOFF_MAX_MS))
}

// Which source to use next and the earliest time it may be asked. `health`
// maps source → { failures, retryAtMs }. The preferred source (adsb.lol
// unless the feedSource setting says adsb.fi) is used until it failed
// FALLBACK_AFTER times in a row; after that the other one carries the feed
// and the preferred one is retried whenever its own backoff runs out.
function chooseSource(health, nowMs, preferred) {
  var first = preferred === "adsb.fi" ? "adsb.fi" : "adsb.lol"
  var second = first === "adsb.lol" ? "adsb.fi" : "adsb.lol"
  var a = health && health[first] || { failures: 0, retryAtMs: 0 }
  var b = health && health[second] || { failures: 0, retryAtMs: 0 }
  if (a.failures < FALLBACK_AFTER || nowMs >= a.retryAtMs)
    return { source: first, atMs: Math.max(nowMs, a.retryAtMs) }
  if (b.retryAtMs <= a.retryAtMs) return { source: second, atMs: Math.max(nowMs, b.retryAtMs) }
  return { source: first, atMs: a.retryAtMs }
}

// Decide the next feed request. `s` holds:
//   nowMs, mode, query (from feedQuery), viewRadiusNm (region only), centre,
//   lastQuery, lastSuccessMs, lastAttemptMs, cadenceMs, force,
//   health (see chooseSource), hostLastMs (host → last request time),
//   preferred (optional, "adsb.lol" | "adsb.fi": the feedSource setting),
//   wide (optional, false holds adsb.lol to 250 NM: the wideQueries setting)
// Returns { source, query, url, host, atMs, covered } or null when idle.
//
// Fresh data that still covers what is wanted waits for the cadence; a view
// that moved outside the last answer is fetched right away. Either way no
// request comes sooner than FEED_GAP_MS after the previous one, HOST_GAP_MS
// after anything else sent to that host, or before the source's backoff.
function planFetch(s) {
  if (!s || !s.query) return null
  var pick = chooseSource(s.health, s.nowMs, s.preferred)
  var q = sourceQuery(pick.source, s.query, s.centre, s.wide)
  var need = s.mode === "region" && finite(s.viewRadiusNm) ? Math.min(q.radiusNm, s.viewRadiusNm) : q.radiusNm
  var last = s.lastQuery
  var covered = !!last && queryCovers(last.lat, last.lon, last.radiusNm, q.lat, q.lon, need)
  var due = s.force || !covered ? (s.lastAttemptMs || 0) + FEED_GAP_MS : (s.lastSuccessMs || 0) + s.cadenceMs
  var host = SOURCE_HOSTS[pick.source]
  var hostLast = s.hostLastMs && s.hostLastMs[host] ? s.hostLastMs[host] : 0
  return {
    source: pick.source,
    query: q,
    url: feedUrl(pick.source, q.lat, q.lon, q.radiusNm),
    host: host,
    covered: covered,
    atMs: Math.max(s.nowMs, due, pick.atMs, hostLast + HOST_GAP_MS)
  }
}

// How one curl run went. curl writes the HTTP status with --write-out;
// "000" or a non-zero exit means the request never got an answer.
function classifyFetch(exitCode, httpCodeText) {
  var code = parseInt(String(httpCodeText || "").trim().slice(-3), 10) || 0
  if (exitCode === 0 && code === 200) return { ok: true, code: 200, rateLimited: false, error: "" }
  if (code === 429) return { ok: false, code: code, rateLimited: true, error: "rate limited" }
  if (exitCode === 0 && code > 0) return { ok: false, code: code, rateLimited: false, error: "HTTP " + code }
  return { ok: false, code: code, rateLimited: false, error: "no connection" }
}

// --------------------------------------------------- summary and meta

var FLAG_GROUND = 1
var FLAG_EMERGENCY = 2
var FLAG_MILITARY = 4

function intOr(value, fallback) {
  var n = numberOr(value, NaN)
  return finite(n) ? Math.round(n) : fallback
}

function numberOrNull(value) {
  var n = numberOr(value, NaN)
  return finite(n) ? n : null
}

// One aircraft row of the helper's output (summary list or meta column).
// The helper already sanitised it; this keeps the GUI side honest anyway.
function cleanRow(r) {
  if (!r || typeof r !== "object") return null
  var lat = numberOr(r.lat, NaN)
  var lon = numberOr(r.lon, NaN)
  if (!isValidLatLon(lat, lon)) return null
  return {
    i: intOr(r.i, -1),
    hex: cleanString(r.hex, 7, HEX_RE),
    cs: cleanString(r.cs, 8, CALLSIGN_RE),
    ty: cleanString(r.ty, 4, TYPE_RE),
    rg: cleanString(r.rg, 10, REG_RE),
    op: cleanString(r.op, 48),
    sq: cleanString(r.sq, 4, SQUAWK_RE),
    lat: lat,
    lon: lon,
    alt: numberOrNull(r.alt),
    gs: numberOrNull(r.gs),
    trk: numberOrNull(r.trk),
    vr: numberOrNull(r.vr),
    km: numberOrNull(r.km),
    brg: numberOrNull(r.brg)
  }
}

function cleanRows(list, max) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length && out.length < max; i++) {
    var row = cleanRow(list[i])
    if (row) out.push(row)
  }
  return out
}

// flightline-feed's one-line stdout. Returns { ok: true, ... } with every
// number checked, { ok: false, error } for a reported failure, or null when
// the line is not JSON at all.
function parseSummary(text) {
  var data
  try { data = JSON.parse(String(text || "").trim()) } catch (e) { return null }
  if (!data || typeof data !== "object") return null
  if (data.ok !== true) return { ok: false, error: cleanString(String(data.error || "feed helper failed"), 120) }
  var rev = intOr(data.rev, -1)
  var epochMs = numberOr(data.epochMs, NaN)
  if (rev < 0 || !finite(epochMs)) return { ok: false, error: "malformed summary" }
  var q = data.query && typeof data.query === "object" ? data.query : null
  var h = data.home && typeof data.home === "object" ? data.home : null
  return {
    ok: true,
    rev: rev,
    source: cleanString(data.source, 16),
    epochMs: epochMs,
    fetchedMs: numberOr(data.fetchedMs, epochMs + 300000),
    n: clamp(intOr(data.n, 0), 0, 10240),
    airborne: Math.max(0, intOr(data.airborne, 0)),
    dropped: Math.max(0, intOr(data.dropped, 0)),
    maxGs: clamp(numberOr(data.maxGs, 0), 0, 2500),
    query: q && isValidLatLon(numberOr(q.lat, NaN), numberOr(q.lon, NaN))
      ? { lat: numberOr(q.lat, 0), lon: numberOr(q.lon, 0), radiusNm: numberOr(q.radiusNm, 0) } : null,
    home: h ? {
      lat: numberOr(h.lat, NaN),
      lon: numberOr(h.lon, NaN),
      radiusNm: numberOr(h.radiusNm, 0),
      count: Math.max(0, intOr(h.count, 0)),
      nearest: cleanRows(h.nearest, 8),
      nearestAny: cleanRows(h.nearestAny, 8)
    } : null,
    emergencies: cleanRows(data.emergencies, 32)
  }
}

// meta.json → the parsed object, or null when it is unusable. Columns are
// checked for shape only; single rows are cleaned on access (metaRow).
var META_COLUMNS = ["hex", "cs", "ty", "rg", "op", "lat", "lon", "alt", "gs", "trk", "t", "vr", "sq", "cat", "flags"]

function parseMeta(text) {
  var data
  try { data = JSON.parse(text) } catch (e) { return null }
  if (!data || typeof data !== "object") return null
  var n = intOr(data.n, -1)
  if (n < 0 || n > 10240) return null
  for (var i = 0; i < META_COLUMNS.length; i++) {
    var col = data[META_COLUMNS[i]]
    if (!Array.isArray(col) || col.length < n) return null
  }
  return data
}

// Row `i` of a parsed meta in the Service API shape, or null.
function metaRow(meta, i) {
  if (!meta || !(i >= 0) || i >= meta.n || Math.floor(i) !== i) return null
  var lat = numberOr(meta.lat[i], NaN)
  var lon = numberOr(meta.lon[i], NaN)
  if (!isValidLatLon(lat, lon)) return null
  return {
    i: i,
    hex: cleanString(meta.hex[i], 7, HEX_RE),
    cs: cleanString(meta.cs[i], 8, CALLSIGN_RE),
    ty: cleanString(meta.ty[i], 4, TYPE_RE),
    rg: cleanString(meta.rg[i], 10, REG_RE),
    op: cleanString(meta.op[i], 48),
    lat: lat,
    lon: lon,
    alt: numberOrNull(meta.alt[i]),
    gs: numberOrNull(meta.gs[i]),
    trk: numberOrNull(meta.trk[i]),
    t: numberOr(meta.t[i], 0),
    vr: numberOrNull(meta.vr[i]),
    sq: cleanString(meta.sq[i], 4, SQUAWK_RE),
    cat: cleanString(meta.cat[i], 2, CATEGORY_RE),
    flags: intOr(meta.flags[i], 0) & 255
  }
}

// A summary or meta row in the shape the formatters above take
// (displayName, formatAltitude, phaseOf, isEmergency, glyphFor ...).
// `epochMs` turns the row's `t` into positionTimeMs when it has one.
function toAircraft(row, epochMs) {
  if (!row) return null
  var flags = intOr(row.flags, 0)
  var onGround = row.alt === -1 || (flags & FLAG_GROUND) !== 0
  var squawkAlert = row.sq === "7500" || row.sq === "7600" || row.sq === "7700"
  return {
    hex: row.hex,
    callsign: row.cs || "",
    registration: row.rg || "",
    type: row.ty || "",
    description: "",
    operator: row.op || "",
    category: row.cat || "",
    lat: row.lat,
    lon: row.lon,
    onGround: onGround,
    altitudeFt: onGround ? 0 : (finite(row.alt) ? row.alt : null),
    groundSpeedKt: finite(row.gs) ? row.gs : null,
    track: finite(row.trk) ? normalizeAngle(row.trk) : null,
    verticalRateFpm: finite(row.vr) ? row.vr : null,
    squawk: row.sq || "",
    emergency: (flags & FLAG_EMERGENCY) !== 0 && !squawkAlert ? "declared" : "",
    military: (flags & FLAG_MILITARY) !== 0,
    positionTimeMs: finite(epochMs) && finite(row.t) ? epochMs + row.t * 1000 : NaN
  }
}

// --------------------------------------------------------------- routes

// Distance (km) from a point to the great-circle segment origin → destination.
function routeDeviationKm(oLat, oLon, dLat, dLon, lat, lon) {
  var d13 = distanceKm(oLat, oLon, lat, lon) / EARTH_RADIUS_KM
  var d12 = distanceKm(oLat, oLon, dLat, dLon) / EARTH_RADIUS_KM
  if (d12 < 1e-9) return d13 * EARTH_RADIUS_KM
  var delta = (bearingDeg(oLat, oLon, lat, lon) - bearingDeg(oLat, oLon, dLat, dLon)) * DEG
  var xt = Math.asin(clamp(Math.sin(d13) * Math.sin(delta), -1, 1))
  // Behind the origin or past the destination: the nearest end counts.
  if (Math.cos(delta) < 0) return d13 * EARTH_RADIUS_KM
  var at = Math.acos(clamp(Math.cos(d13) / Math.cos(xt), -1, 1))
  if (at > d12) return distanceKm(dLat, dLon, lat, lon)
  return Math.abs(xt) * EARTH_RADIUS_KM
}

function routeHasCoordinates(route) {
  return !!route && !!route.origin && !!route.destination
    && isValidLatLon(route.origin.lat, route.origin.lon) && isValidLatLon(route.destination.lat, route.destination.lon)
}

// adsbdb routes are per callsign and go stale when airlines reuse numbers.
// A route is believable when the aircraft is within max(150 km, 15 % of the
// route length) of its great circle.
function routePlausible(route, lat, lon) {
  if (!routeHasCoordinates(route) || !isValidLatLon(lat, lon)) return false
  var o = route.origin, d = route.destination
  var tolerance = Math.max(150, 0.15 * distanceKm(o.lat, o.lon, d.lat, d.lon))
  return routeDeviationKm(o.lat, o.lon, d.lat, d.lon, lat, lon) <= tolerance
}

// Progress along a route and a naive ETA: the remaining great-circle
// distance at the current ground speed. `seconds` is null below 50 kt, where
// the aircraft is taxiing or the speed is meaningless.
function routeProgress(route, lat, lon, gsKt) {
  if (!routeHasCoordinates(route) || !isValidLatLon(lat, lon)) return null
  var o = route.origin, d = route.destination
  var total = distanceKm(o.lat, o.lon, d.lat, d.lon)
  var remaining = distanceKm(lat, lon, d.lat, d.lon)
  var flown = distanceKm(o.lat, o.lon, lat, lon)
  var progress = total > 0 ? clamp(flown / (flown + remaining), 0, 1) : 1
  var speed = numberOr(gsKt, 0)
  return {
    totalKm: total,
    remainingKm: remaining,
    progress: progress,
    seconds: speed >= 50 ? Math.round(remaining / (speed * KT_KMH) * 3600) : null
  }
}

// ------------------------------------------------------ location sources

// Omarchy's weather location state: {"name", "latitude", "longitude"}.
function parseOmarchyLocation(text) {
  var unset = { name: "", lat: NaN, lon: NaN }
  if (!text) return unset
  var data
  try { data = JSON.parse(text) } catch (e) { return unset }
  if (!data || typeof data !== "object") return unset
  var lat = numberOr(data.latitude, NaN)
  var lon = numberOr(data.longitude, NaN)
  return {
    name: cleanString(data.name, 80),
    lat: isValidLatLon(lat, lon) ? lat : NaN,
    lon: isValidLatLon(lat, lon) ? lon : NaN
  }
}

// wttr.in ?format=j1 → { name, lat, lon } of the IP-detected area.
function parseWttrArea(text) {
  var data
  try { data = JSON.parse(text) } catch (e) { return null }
  var area = data && data.nearest_area && data.nearest_area[0]
  if (!area) return null
  var lat = numberOr(area.latitude, NaN)
  var lon = numberOr(area.longitude, NaN)
  if (!isValidLatLon(lat, lon)) return null
  var name = area.areaName && area.areaName[0] ? cleanString(area.areaName[0].value, 80) : ""
  return { name: name, lat: lat, lon: lon }
}

// Open-Meteo geocoding → suggestion rows.
function parseGeocoding(text) {
  var data
  try { data = JSON.parse(text) } catch (e) { return [] }
  var results = data && Array.isArray(data.results) ? data.results : []
  var rows = []
  for (var i = 0; i < results.length && rows.length < 6; i++) {
    var r = results[i]
    var lat = numberOr(r && r.latitude, NaN)
    var lon = numberOr(r && r.longitude, NaN)
    if (!r || !isValidLatLon(lat, lon)) continue
    var name = cleanString(r.name, 80)
    if (!name) continue
    var detail = [cleanString(r.admin1, 60), cleanString(r.country, 60)].filter(function(s) { return s !== "" }).join(", ")
    rows.push({ name: name, detail: detail, lat: lat, lon: lon })
  }
  return rows
}

// flightline-locate output → { lat, lon, accuracyM } or null.
function parseLocate(text) {
  var data
  try { data = JSON.parse(text) } catch (e) { return null }
  var lat = numberOr(data && data.location && data.location.lat, NaN)
  var lon = numberOr(data && data.location && data.location.lng, NaN)
  if (!isValidLatLon(lat, lon)) return null
  return { lat: lat, lon: lon, accuracyM: clamp(numberOr(data.accuracy, 0), 0, 1e7) }
}

// adsbdb callsign route → { origin, destination, airline }. Airports carry
// short labels and lat/lon (NaN when adsbdb has none).
function parseRoute(text) {
  var data
  try { data = JSON.parse(text) } catch (e) { return null }
  var route = data && data.response && data.response.flightroute
  if (!route || typeof route !== "object") return null
  function airport(a) {
    if (!a || typeof a !== "object") return null
    var code = cleanString(a.iata_code, 3, /^[A-Z0-9]{3}$/) || cleanString(a.icao_code, 4, /^[A-Z0-9]{4}$/)
    if (!code) return null
    var lat = numberOr(a.latitude, NaN)
    var lon = numberOr(a.longitude, NaN)
    var placed = isValidLatLon(lat, lon)
    return {
      code: code,
      city: cleanString(a.municipality, 48),
      name: cleanString(a.name, 64),
      country: cleanString(a.country_name, 48),
      lat: placed ? lat : NaN,
      lon: placed ? lon : NaN
    }
  }
  var origin = airport(route.origin)
  var destination = airport(route.destination)
  // Same airport at both ends is how stale or placeholder routes show up.
  if (!origin || !destination || origin.code === destination.code) return null
  var airline = route.airline && typeof route.airline === "object" ? cleanString(route.airline.name, 48) : ""
  return { origin: origin, destination: destination, airline: airline }
}

// ------------------------------------------------------- flight search

// Airline groups whose flights fly under several ICAO callsign prefixes that
// a single IATA lookup does not reveal (LATAM sells "LA" for TAM, LAN, ...).
var EXTRA_ICAO_FOR_IATA = {
  "LA": ["TAM", "LAN", "LPE", "LNE", "LXP"],
  "JJ": ["TAM"],
  "4M": ["DSM", "LAN"]
}

// Work out how a search text could identify an aircraft. Returns the lookups
// to try, most specific first:
//   { kind: "callsign" | "registration" | "hex", value }
//   { kind: "iata", airline, number }   (needs an airline → ICAO lookup)
function flightLookups(text) {
  var raw = String(text || "").toUpperCase().replace(/\s+/g, "")
  if (raw.length < 3 || raw.length > 10) return []
  var out = []
  var m
  if (/^[A-Z]{3}[0-9][0-9A-Z]{0,4}$/.test(raw)) out.push({ kind: "callsign", value: raw })
  // US registrations (N12345) look like flight numbers; prefer the aircraft.
  if (/^[A-Z0-9]{1,2}-[A-Z0-9]{2,5}$/.test(raw) || /^N[0-9][0-9A-Z]{1,4}$/.test(raw))
    out.push({ kind: "registration", value: raw })
  if ((m = /^([A-Z][0-9]|[0-9][A-Z]|[A-Z]{2})([0-9]{1,4}[A-Z]?)$/.exec(raw)))
    out.push({ kind: "iata", airline: m[1], number: m[2].replace(/^0+(?=\d)/, "") })
  if (/^[0-9A-F]{6}$/.test(raw)) out.push({ kind: "hex", value: raw.toLowerCase() })
  return out
}

function looksLikeFlight(text) {
  return flightLookups(text).length > 0
}

function flightLookupUrl(lookup) {
  var base = "https://opendata.adsb.fi/api/v2/"
  if (lookup.kind === "callsign") return base + "callsign/" + encodeURIComponent(lookup.value)
  if (lookup.kind === "registration") return base + "registration/" + encodeURIComponent(lookup.value)
  if (lookup.kind === "hex") return base + "hex/" + encodeURIComponent(lookup.value)
  return ""
}

// adsbdb /v0/airline/<IATA> → ICAO prefixes, plus known group extras.
function parseAirlinePrefixes(text, iata) {
  var prefixes = []
  try {
    var data = JSON.parse(text)
    var rows = data && Array.isArray(data.response) ? data.response : []
    for (var i = 0; i < rows.length; i++) {
      var icao = cleanString(rows[i] && rows[i].icao, 3, /^[A-Z]{3}$/)
      if (icao && prefixes.indexOf(icao) === -1) prefixes.push(icao)
    }
  } catch (e) {}
  var extra = EXTRA_ICAO_FOR_IATA[iata] || []
  for (var j = 0; j < extra.length; j++) if (prefixes.indexOf(extra[j]) === -1) prefixes.push(extra[j])
  return prefixes.slice(0, 6)
}

// ------------------------------------------------- globe label placement

// Who wins a spot on the globe, most important first (docs/VISUAL.md "Labels,
// route, picking"). The route's airport codes go with the selected flight.
var LABEL_TIER = { selected: 1, emergency: 2, hovered: 3, near: 4, home: 5, city: 6, aircraft: 7 }
var LABEL_SIDES = ["right", "left", "above", "below"]
var LABEL_FADE = 0.06                // labels fade over the outer 6 % of the globe's radius

// Sort key of a label: its tier, then `rank` in [0, 1) inside the tier
// (higher wins).
function labelPriority(tier, rank) {
  return 10 - tier + clamp(numberOr(rank, 0), 0, 0.999)
}

// Top-left corner of a w x h label on `side` of its anchor (x, y), `gap` px
// away; above and below are centred on the anchor.
function labelBox(x, y, w, h, gap, side) {
  if (side === "left") return { bx: x - gap - w, by: y - h / 2 }
  if (side === "above") return { bx: x - w / 2, by: y - gap - h }
  if (side === "below") return { bx: x - w / 2, by: y + gap }
  return { bx: x + gap, by: y - h / 2 }
}

// Opacity of a box near the limb of the globe disc { x, y, r }: 1 inside,
// fading to 0 as its farthest corner crosses the outer `fade` (fraction of
// the radius); 0 once a corner is past the limb. No disc: 1.
function discAlpha(bx, by, w, h, disc, fade) {
  if (!disc) return 1
  var dx = Math.max(Math.abs(bx - disc.x), Math.abs(bx + w - disc.x))
  var dy = Math.max(Math.abs(by - disc.y), Math.abs(by + h - disc.y))
  return clamp((disc.r - Math.sqrt(dx * dx + dy * dy)) / (fade * disc.r), 0, 1)
}

// Boxes { bx, by, w, h } bucketed on a coarse grid, so a placement checks
// only its neighbours instead of every sprite on screen.
function BoxGrid(cell) {
  this.cell = cell
  this.cells = {}
}
BoxGrid.prototype.add = function(b) {
  var c = this.cell
  for (var gx = Math.floor(b.bx / c); gx <= Math.floor((b.bx + b.w) / c); gx++)
    for (var gy = Math.floor(b.by / c); gy <= Math.floor((b.by + b.h) / c); gy++) {
      var key = gx + "," + gy
      if (this.cells[key]) this.cells[key].push(b)
      else this.cells[key] = [b]
    }
}
// Does (bx, by, w, h), grown by (px, py) on every side, touch any box?
BoxGrid.prototype.hits = function(bx, by, w, h, px, py) {
  var c = this.cell
  var x0 = bx - px, x1 = bx + w + px, y0 = by - py, y1 = by + h + py
  for (var gx = Math.floor(x0 / c); gx <= Math.floor(x1 / c); gx++)
    for (var gy = Math.floor(y0 / c); gy <= Math.floor(y1 / c); gy++) {
      var list = this.cells[gx + "," + gy]
      if (!list) continue
      for (var i = 0; i < list.length; i++) {
        var b = list[i]
        if (x0 < b.bx + b.w && x1 > b.bx && y0 < b.by + b.h && y1 > b.by) return true
      }
    }
  return false
}

// Collision-aware placement of the globe's labels: greedy by priority, each
// label trying its sides in turn (right, left, above, below unless it says
// otherwise), keeping the side it had last time when that still works.
//
// items: { key, pool, x, y, w, h, gap, priority, sides?, soft?, mark? }
//   pool   the pooled set the label comes from; opts.limits caps each pool
//   gap    px between the anchor and the box (clears the sprite or the dot)
//   soft   may cover obstacles (sprites) when no clear side is left
//   mark   a box reserved once the label is placed (a city's dot)
// opts: { bounds {x, y, w, h}, disc {x, y, r} | null, fade, minAlpha,
//         limits { pool: n }, obstacles [{ bx, by, w, h }], previous { key: side },
//         padX, padY }
//   obstacles  sprites and drawn marks: every label keeps off them when it
//              can, soft ones cover them rather than vanish
// Labels never overlap each other or a placed mark, stay inside `bounds` and
// the disc, and fade near the limb. Returns [{ item, side, bx, by, w, h, alpha }]
// in placement order (most important first).
function placeGlobeLabels(items, opts) {
  opts = opts || {}
  var bounds = opts.bounds || null
  var disc = opts.disc || null
  var fade = numberOr(opts.fade, LABEL_FADE)
  var minAlpha = numberOr(opts.minAlpha, 0.35)
  var limits = opts.limits || {}
  var previous = opts.previous || {}
  var padX = numberOr(opts.padX, 3), padY = numberOr(opts.padY, 1)
  var labels = new BoxGrid(64)
  var obstacles = new BoxGrid(64)
  var ob = opts.obstacles || []
  for (var o = 0; o < ob.length; o++) obstacles.add(ob[o])
  var left = {}
  var open = 0
  for (var pool in limits) {
    left[pool] = limits[pool]
    open += limits[pool]
  }
  var sorted = items.slice().sort(function(a, b) { return b.priority - a.priority })
  var placed = []
  for (var i = 0; i < sorted.length && open > 0; i++) {
    var it = sorted[i]
    if (!(left[it.pool] > 0)) continue
    // A dot already under another label would read as that label's.
    if (it.mark && labels.hits(it.mark.bx, it.mark.by, it.mark.w, it.mark.h, 0, 0)) continue
    var sides = it.sides || LABEL_SIDES
    var last = previous[it.key]
    if (last && sides.indexOf(last) > 0) sides = [last].concat(sides.filter(function(s) { return s !== last }))
    var best = null
    // Pass 0 keeps clear of sprites too; pass 1 (soft labels only) of labels alone.
    for (var pass = 0; pass < (it.soft ? 2 : 1) && !best; pass++) {
      for (var k = 0; k < sides.length; k++) {
        var b = labelBox(it.x, it.y, it.w, it.h, it.gap || 0, sides[k])
        if (bounds && (b.bx < bounds.x || b.by < bounds.y || b.bx + it.w > bounds.x + bounds.w || b.by + it.h > bounds.y + bounds.h))
          continue
        var alpha = discAlpha(b.bx, b.by, it.w, it.h, disc, fade)
        if (alpha < minAlpha || (best && alpha <= best.alpha)) continue
        if (labels.hits(b.bx, b.by, it.w, it.h, padX, padY)) continue
        if (pass === 0 && obstacles.hits(b.bx, b.by, it.w, it.h, 0, 0)) continue
        best = { item: it, side: sides[k], bx: b.bx, by: b.by, w: it.w, h: it.h, alpha: alpha }
        if (alpha >= 1) break                         // a side well inside the disc: take it
      }
    }
    if (!best) continue
    placed.push(best)
    labels.add(best)
    if (it.mark) labels.add(it.mark)
    left[it.pool]--
    open--
  }
  return placed
}

// Short altitude for map labels: flight levels above the transition
// altitude (18,000 ft); metric rounds to 100 m (kilometres next to a
// callsign would read as a distance).
function formatAltitudeShort(altFt, onGround, units) {
  if (onGround) return "GND"
  if (!finite(altFt)) return ""
  if (units === "metric") return groupThousands(Math.round(altFt * FT_M / 100) * 100) + " m"
  if (altFt >= 18000) return "FL" + ("00" + Math.round(altFt / 100)).slice(-3)
  return groupThousands(Math.round(altFt / 100) * 100) + " ft"
}

// "31 min", "1 h 05 min"; "" when unknown.
function formatDuration(seconds) {
  if (!finite(seconds) || seconds < 0) return ""
  var m = Math.round(seconds / 60)
  if (m < 60) return Math.max(1, m) + " min"
  var mm = m % 60
  return Math.floor(m / 60) + " h " + (mm < 10 ? "0" : "") + mm + " min"
}

// The panel header's uppercase meta line, e.g.
// "ZÜRICH · 4 NEAR · 189 IN VIEW · 9,412 WORLDWIDE". Unknown counts (< 0,
// or left out) are skipped, so the line only ever says what is known. `sky`
// is the Look up lens's count of aircraft above the horizon.
function heroMeta(place, near, inView, world, sky) {
  var parts = []
  if (place) parts.push(String(place))
  if (near >= 0) parts.push(groupThousands(near) + " NEAR")
  if (sky >= 0) parts.push(groupThousands(sky) + " IN YOUR SKY")
  if (inView >= 0) parts.push(groupThousands(inView) + " IN VIEW")
  if (world >= 0) parts.push(groupThousands(world) + " WORLDWIDE")
  return parts.join(" · ").toUpperCase()
}

// "in 3 min" / "now" for a moment `seconds` ahead.
function formatSoon(seconds) {
  if (!finite(seconds)) return ""
  if (seconds < 45) return "now"
  return "in " + formatDuration(seconds)
}

// ------------------------------------------------------------- the camera

// GlobeView's orthographic camera: a centre (lat, lon), a globe radius in
// px, north always up. These helpers keep it in step with the shaders.

var NM_PER_RAD = 3440.065
var HEMISPHERE_NM = Math.PI / 2 * NM_PER_RAD     // ~5,400 NM: the whole visible half
var SHADER_EARTH_KM = 6371                        // aircraft.vert's Earth radius
var LIVE_MAX_AGE_S = 90                           // stop extrapolating, fade from 70 %
var WORLD_MAX_AGE_S = 120                         // world answers come every 60 s and take a while

// aircraft.vert's dead reckoning in JS, so picking and labels land on the
// sprites: the great-circle destination along `trk` for gs * min(age, maxAge),
// on a sphere of SHADER_EARTH_KM. Aircraft without a track or speed stay put.
function reckon(lat, lon, trk, gs, age, maxAge) {
  if (!finite(trk) || !finite(gs) || gs <= 0) return { lat: lat, lon: lon }
  var d = gs * 1.852 / 3600 / SHADER_EARTH_KM * clamp(age, 0, maxAge)
  if (!(d > 0)) return { lat: lat, lon: lon }
  var p = lat * DEG, t = trk * DEG
  var sp = Math.sin(p), cp = Math.cos(p)
  var p2 = Math.asin(clamp(sp * Math.cos(d) + cp * Math.sin(d) * Math.cos(t), -1, 1))
  var l2 = lon * DEG + Math.atan2(Math.sin(t) * Math.sin(d) * cp, Math.cos(d) - sp * Math.sin(p2))
  return { lat: p2 / DEG, lon: wrapLon(l2 / DEG) }
}

// The same dead reckoning as vectors, for many aircraft at once: the unit
// position p and the unit tangent t along the track (ECEF), so the aircraft
// after an angle d is p cos d + t sin d (exactly the great circle reckon()
// follows). Returns [px, py, pz, tx, ty, tz].
var KT_RAD_PER_S = 1.852 / 3600 / SHADER_EARTH_KM

function motionFrame(lat, lon, trk) {
  var p = lat * DEG, l = lon * DEG, b = finite(trk) ? trk * DEG : 0
  var sp = Math.sin(p), cp = Math.cos(p), sl = Math.sin(l), cl = Math.cos(l)
  var sb = Math.sin(b), cb = Math.cos(b)
  // north (-sp cl, -sp sl, cp), east (-sl, cl, 0)
  return [cp * cl, cp * sl, sp,
          -sp * cl * cb - sl * sb, -sp * sl * cb + cl * sb, cp * cb]
}

// How far out (NM) the viewport reaches from its centre: the half-diagonal
// as a great-circle radius. The whole hemisphere once the globe fits.
function visibleRadiusNm(radiusPx, halfDiagonalPx) {
  return visibleAngularRadius(radiusPx, halfDiagonalPx) * NM_PER_RAD
}

// Inverse of visibleRadiusNm: the globe radius at which the half-diagonal
// spans `nm`. Wider than the hemisphere returns `fitPx` (the whole globe).
function radiusForVisibleNm(nm, halfDiagonalPx, fitPx) {
  if (!(nm > 0) || nm >= HEMISPHERE_NM * 0.999) return fitPx
  return Math.max(fitPx, halfDiagonalPx / Math.sin(nm / NM_PER_RAD))
}

// The view centre that puts (pLat, pLon) at the unit-disc offset (ux, uy)
// from the middle of the globe (x east, y up), north up. Exact, so a point
// grabbed with the mouse stays under the cursor while dragging and zooming.
// Returns null when no north-up view can do it (the cursor is off the
// globe, or the point is too close to a pole).
function anchorView(pLat, pLon, ux, uy) {
  var r2 = ux * ux + uy * uy
  if (!(r2 < 1)) return null
  var uz = Math.sqrt(1 - r2)
  var phi = pLat * DEG
  var cphi = Math.cos(phi)
  if (Math.abs(ux) >= cphi) return null
  var dl = Math.asin(ux / cphi)                   // longitude of p relative to the centre
  var a = cphi * Math.cos(dl)
  var la = Math.atan2(Math.sin(phi), a) - Math.atan2(uy, uz)
  if (Math.abs(la) > Math.PI / 2) return null
  return { lat: la / DEG, lon: wrapLon(pLon - dl / DEG) }
}

// Interval of the idle clock: the time the fastest aircraft (`maxGs`, kt)
// needs to move half a pixel on a globe of `radiusPx`, clamped.
function idleTickMs(maxGs, radiusPx, minMs, maxMs) {
  var pxPerS = numberOr(maxGs, 0) * 1.852 / 3600 / SHADER_EARTH_KM * radiusPx
  if (!(pxPerS > 0)) return maxMs
  return Math.round(clamp(500 / pxPerS, minMs, maxMs))
}

// Sprite half-size (px) for a view reaching `visibleNm`: ~2.6 px dots for the
// whole globe, ~4 px at 1,500 NM where glyphs appear, 8 px at 60 NM, then
// growing to 11.5 px at 12 NM, so an approach chart shows the silhouettes
// (twin, heavy, turboprop, rotorcraft) instead of specks.
function spritePxFor(visibleNm) {
  var nm = Math.max(1, visibleNm)
  var t = clamp((Math.log(HEMISPHERE_NM) - Math.log(nm)) / (Math.log(HEMISPHERE_NM) - Math.log(60)), 0, 1)
  var deep = clamp(Math.log(60 / nm) / Math.log(5), 0, 1)
  return 2.6 + 5.4 * t + 3.5 * deep
}

function easeInOut(t) {
  t = clamp(t, 0, 1)
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2
}

// Globe radius during a fly-to at eased progress `e`: log-linear from r0 to
// r1, pulled back in the middle of long hops so both ends stay in sight, like
// a camera that rises before it travels. A hop of `angleRad` fits on screen
// at about spanPx / sin(angleRad) (spanPx ~ twice the viewport half-diagonal).
function flightRadius(r0, r1, spanPx, angleRad, e) {
  var a = Math.log(r0), b = Math.log(r1)
  var fit = spanPx / Math.max(0.05, Math.sin(Math.min(angleRad, Math.PI / 2)))
  var lift = Math.max(0, (a + b) / 2 - Math.log(fit))
  return Math.exp(a + (b - a) * e - lift * Math.sin(Math.PI * e))
}
