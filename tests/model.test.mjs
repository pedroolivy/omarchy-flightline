// Run: node tests/model.test.mjs
// Loads Model.js (a QML ".pragma library" script) into a plain JS context.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import vm from "node:vm"
import assert from "node:assert/strict"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const M = {}
vm.createContext(M)
vm.runInContext(source, M)

let failures = 0
function test(name, fn) {
  try {
    fn()
    console.log("ok   " + name)
  } catch (e) {
    failures++
    console.log("FAIL " + name + "\n     " + e.message)
  }
}
const near = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} !~ ${b}`)

test("wrapLon keeps longitudes in [-180, 180]", () => {
  near(M.wrapLon(190), -170)
  near(M.wrapLon(-190), 170)
  near(M.wrapLon(180), 180)
  near(M.wrapLon(540), 180)
})

test("angleDelta takes the short way round", () => {
  near(M.angleDelta(350, 10), 20)
  near(M.angleDelta(10, 350), -20)
})

test("view matrix puts the centre in front of the viewer", () => {
  const m = M.viewMatrix(-46.6, -23.5)
  const p = M.projectLonLat(m, -46.6, -23.5)
  near(p.x, 0); near(p.y, 0); near(p.z, 1)
  const east = M.projectLonLat(m, -45.6, -23.5)
  assert.ok(east.x > 0 && Math.abs(east.y) < 0.01, "east is +x")
  const north = M.projectLonLat(m, -46.6, -22.5)
  assert.ok(north.y > 0, "north is +y")
  const antipode = M.projectLonLat(m, 133.4, 23.5)
  assert.ok(antipode.z < 0, "antipode is hidden")
})

test("unprojectUnit inverts projectLonLat", () => {
  const m = M.viewMatrix(8.57, 50.03)
  for (const [lon, lat] of [[8.57, 50.03], [10, 52], [-5, 40], [30, 70]]) {
    const p = M.projectLonLat(m, lon, lat)
    const back = M.unprojectUnit(m, p.x, p.y)
    near(back.lon, lon, 1e-6); near(back.lat, lat, 1e-6)
  }
  assert.equal(M.unprojectUnit(m, 0.9, 0.9), null)
})

test("distance and destination agree", () => {
  const d = M.distanceKm(-23.5505, -46.6333, -22.9068, -43.1729)
  assert.ok(d > 355 && d < 365, "SP-RJ about 360 km, got " + d)
  const b = M.bearingDeg(-23.5505, -46.6333, -22.9068, -43.1729)
  const p = M.destination(-23.5505, -46.6333, b, d)
  near(p.lat, -22.9068, 1e-3); near(p.lon, -43.1729, 1e-3)
})

test("slerp ends on both endpoints and crosses the antimeridian", () => {
  const a = M.slerpLonLat(0, 170, 0, -170, 0)
  const b = M.slerpLonLat(0, 170, 0, -170, 1)
  const mid = M.slerpLonLat(0, 170, 0, -170, 0.5)
  near(a.lon, 170, 1e-6); near(b.lon, -170, 1e-6)
  near(Math.abs(mid.lon), 180, 1e-6)
})

test("feed urls are clamped and well formed", () => {
  assert.equal(M.feedUrl("adsb.fi", -23.55051, -46.63331, 300),
    "https://opendata.adsb.fi/api/v3/lat/-23.5505/lon/-46.6333/dist/250")
  assert.equal(M.feedUrl("adsb.lol", 1, 2, 0), "https://api.adsb.lol/v2/point/1.0000/2.0000/1")
  assert.equal(M.feedUrl("adsb.lol", 0, 0, 10800), "https://api.adsb.lol/v2/point/0.0000/0.0000/10800")
  assert.equal(M.feedUrl("adsb.lol", -23.7, -226.12, 99999), "https://api.adsb.lol/v2/point/-23.7000/133.8800/10800")
  assert.equal(M.urlHost("https://api.adsb.lol/v2/point/0/0/1"), "api.adsb.lol")
  assert.equal(M.urlHost("https://API.adsbdb.com:443/v0/x"), "api.adsbdb.com")
  assert.equal(M.urlHost("nonsense"), "")
})

const sample = {
  hex: "4D2453", flight: "WZZ239  ", r: "9H-WBI", t: "A21N", desc: "AIRBUS A-321neo",
  alt_baro: 18400, gs: 368.6, track: 318.96, baro_rate: -2048, squawk: "6017",
  emergency: "none", category: "A3", lat: 50.292709, lon: 8.056665, seen_pos: 2
}

test("sanitizeAircraft keeps valid fields", () => {
  const ac = M.sanitizeAircraft(sample, 10000)
  assert.equal(ac.hex, "4d2453")
  assert.equal(ac.callsign, "WZZ239")
  assert.equal(ac.registration, "9H-WBI")
  assert.equal(ac.type, "A21N")
  assert.equal(ac.altitudeFt, 18400)
  assert.equal(ac.emergency, "")
  assert.equal(ac.positionTimeMs, 8000)
  assert.equal(M.phaseOf(ac), "Descending")
})

test("sanitizeAircraft rejects junk and strips control/markup", () => {
  assert.equal(M.sanitizeAircraft({ ...sample, hex: "<b>x</b>" }, 0), null)
  assert.equal(M.sanitizeAircraft({ ...sample, lat: 95 }, 0), null)
  assert.equal(M.sanitizeAircraft({ ...sample, lat: "nope" }, 0), null)
  const ac = M.sanitizeAircraft({ ...sample, flight: "<img src=x>", r: "A\u0007B", squawk: "9999", category: "Z9",
                                  desc: "x".repeat(500) }, 0)
  assert.equal(ac.callsign, "")
  assert.equal(ac.registration, "AB")
  assert.equal(ac.squawk, "")
  assert.equal(ac.category, "")
  assert.equal(ac.description.length, 48)
  // C1 controls and bidi/format characters cannot reorder or hide panel text.
  assert.equal(M.cleanString("A\u202eB\u0085C\u200bD\u2066E\ufeffF\u061cG", 48), "ABCDEFG")
})

test("ground aircraft and missing numbers", () => {
  const ac = M.sanitizeAircraft({ hex: "abcdef", lat: 1, lon: 2, alt_baro: "ground" }, 0)
  assert.equal(ac.onGround, true)
  assert.equal(ac.altitudeFt, 0)
  assert.equal(ac.groundSpeedKt, null)
  assert.equal(ac.track, null)
  assert.equal(M.formatAltitude(ac, "aviation"), "Ground")
  const p = M.extrapolate(ac, 999999)
  assert.equal(p.lat, 1); assert.equal(p.lon, 2)
})

test("parseFeed dedupes, caps and survives garbage", () => {
  const text = JSON.stringify({ ac: [sample, sample, { hex: "nothex" }, null] })
  const r = M.parseFeed(text, 0)
  assert.equal(r.ok, true)
  assert.equal(r.aircraft.length, 1)
  assert.equal(M.parseFeed("not json", 0).ok, false)
  assert.equal(M.parseFeed("{}", 0).ok, false)
})

test("extrapolate moves along the track and caps the horizon", () => {
  const ac = M.sanitizeAircraft({ ...sample, track: 90, lat: 0, lon: 0, gs: 360, seen_pos: 0 }, 0)
  const p = M.extrapolate(ac, 10000) // 10 s at 360 kt = 1 nm east
  near(p.lat, 0, 1e-6)
  near(M.distanceKm(0, 0, p.lat, p.lon), 1.852, 1e-3)
  const far = M.extrapolate(ac, 10 * 60 * 1000)
  near(M.distanceKm(0, 0, far.lat, far.lon), 360 * 1.852 * 45 / 3600, 1e-3)
})

test("emergencies and glyphs", () => {
  const ac = M.sanitizeAircraft({ ...sample, squawk: "7700" }, 0)
  assert.equal(M.isEmergency(ac), true)
  assert.equal(M.emergencyLabel(ac), "Emergency (7700)")
  assert.equal(M.glyphFor({ category: "A7" }), "rotor")
  assert.equal(M.glyphFor({ category: "A5" }), "heavy")
  assert.equal(M.glyphFor({ category: "" }), "jet")
})

test("unit formatting", () => {
  const ac = M.sanitizeAircraft(sample, 0)
  assert.equal(M.resolveUnits("auto", "en_US"), "imperial")
  assert.equal(M.resolveUnits("auto", "en_US.UTF-8"), "imperial")
  assert.equal(M.resolveUnits("auto", "pt_BR"), "metric")
  assert.equal(M.resolveUnits("auto", "en_US.UTF-8", "America/Sao_Paulo"), "metric")
  assert.equal(M.resolveUnits("auto", "pt_BR.UTF-8", "America/Chicago"), "imperial")
  assert.equal(M.resolveUnits("auto", "en_GB", "America/Indiana/Indianapolis"), "imperial")
  assert.equal(M.resolveUnits("auto", "en_US", "Europe/Lisbon"), "metric")
  assert.equal(M.resolveUnits("auto", "en_US", "garbage zone"), "imperial")
  assert.equal(M.resolveUnits("aviation", "pt_BR"), "aviation")
  assert.equal(M.formatAltitude(ac, "aviation"), "18,400 ft")
  assert.equal(M.formatAltitude(ac, "metric"), "5,608 m")
  assert.equal(M.formatSpeed(368.6, "aviation"), "369 kt")
  assert.equal(M.formatSpeed(368.6, "metric"), "683 km/h")
  assert.equal(M.formatDistance(5.04, "metric"), "5.0 km")
  assert.equal(M.formatDistance(18.52, "aviation"), "10 nm")
  assert.equal(M.formatVerticalRate(-2048, "aviation"), "↓ 2,048 ft/min")
  assert.equal(M.formatVerticalRate(10, "aviation"), "Level")
  assert.equal(M.formatVerticalRate(-64, "metric"), "Level")
  assert.equal(M.formatHeading(318.96), "319° NW")
})

test("web zoom scale", () => {
  near(M.webZoomForRadius(256 / (2 * Math.PI)), 0, 1e-9)
  near(M.webZoomForRadius(512 / (2 * Math.PI)), 1, 1e-9)
})

test("nearest and queryCovers", () => {
  const a = M.sanitizeAircraft({ ...sample, hex: "000001", lat: 0, lon: 0.1 }, 0)
  const b = M.sanitizeAircraft({ ...sample, hex: "000002", lat: 0, lon: 1 }, 0)
  const g = M.sanitizeAircraft({ ...sample, hex: "000003", lat: 0, lon: 0.05, alt_baro: "ground" }, 0)
  const rows = M.nearest([b, a, g], 0, 0, 5, false)
  assert.deepEqual(Array.from(rows, r => r.ac.hex), ["000001", "000002"])
  assert.equal(M.queryCovers(0, 0, 100, 0, 0, 50), true)
  assert.equal(M.queryCovers(0, 0, 100, 0, 1, 50), false)
  assert.equal(M.queryCovers(0, 0, 10800, 0, 180, 250), true, "a world query covers the antipode")
})

test("location parsers", () => {
  const omarchy = M.parseOmarchyLocation('{"name":"Recife","latitude":-8.05,"longitude":-34.9}')
  assert.equal(omarchy.name, "Recife"); near(omarchy.lat, -8.05)
  assert.ok(isNaN(M.parseOmarchyLocation('{"name":"Malibu"}').lat))
  assert.ok(isNaN(M.parseOmarchyLocation("garbage").lat))
  const area = M.parseWttrArea(JSON.stringify({ nearest_area: [{ latitude: "1.5", longitude: "2.5", areaName: [{ value: "Town" }] }] }))
  assert.deepEqual({ ...area }, { name: "Town", lat: 1.5, lon: 2.5 })
  const geo = M.parseGeocoding(JSON.stringify({ results: [{ name: "Lisbon", admin1: "Lisbon", country: "Portugal", latitude: 38.7, longitude: -9.1 }, { name: "Bad", latitude: 999, longitude: 0 }] }))
  assert.equal(geo.length, 1); assert.equal(geo[0].detail, "Lisbon, Portugal")
  const loc = M.parseLocate('{"location":{"lat":10,"lng":20},"accuracy":35}')
  assert.deepEqual({ ...loc }, { lat: 10, lon: 20, accuracyM: 35 })
  assert.equal(M.parseLocate('{"error":1}'), null)
})

test("route parser", () => {
  const text = JSON.stringify({ response: { flightroute: {
    airline: { name: "British Airways" },
    origin: { iata_code: "LHR", icao_code: "EGLL", municipality: "London", name: "Heathrow", country_name: "United Kingdom" },
    destination: { iata_code: "", icao_code: "VABB", municipality: "Mumbai", name: "CSMI", country_name: "India" } } } })
  const r = M.parseRoute(text)
  assert.equal(r.origin.code, "LHR")
  assert.equal(r.destination.code, "VABB")
  assert.ok(Number.isNaN(r.origin.lat), "no coordinates in this sample")
  assert.equal(r.airline, "British Airways")
  assert.equal(M.parseRoute('{"response":"unknown callsign"}'), null)
  const loop = JSON.parse(text)
  loop.response.flightroute.destination = loop.response.flightroute.origin
  assert.equal(M.parseRoute(JSON.stringify(loop)), null)
})

test("flight search understands callsigns, IATA numbers, registrations and hex", () => {
  const kinds = t => Array.from(M.flightLookups(t), l => l.kind + ":" + (l.value || l.airline + "/" + l.number))
  assert.deepEqual(kinds("tam3054"), ["callsign:TAM3054"])
  assert.deepEqual(kinds("LA 3054"), ["iata:LA/3054"])
  assert.deepEqual(kinds("G3 1234"), ["iata:G3/1234"])
  assert.deepEqual(kinds("ba0117"), ["iata:BA/117", "hex:ba0117"])
  assert.deepEqual(kinds("PR-XMA"), ["registration:PR-XMA"])
  assert.deepEqual(kinds("N12345"), ["registration:N12345", "iata:N1/2345"])
  assert.deepEqual(kinds("4d2453"), ["iata:4D/2453", "hex:4d2453"])
  assert.deepEqual(kinds("Lisbon"), [])
  assert.deepEqual(kinds("São Paulo"), [])
  assert.equal(M.looksLikeFlight("Recife"), false)
  assert.equal(M.flightLookupUrl({ kind: "callsign", value: "TAM3054" }), "https://opendata.adsb.fi/api/v2/callsign/TAM3054")
  const prefixes = M.parseAirlinePrefixes(JSON.stringify({ response: [{ icao: "LAN" }, { icao: "bad!" }] }), "LA")
  assert.deepEqual(Array.from(prefixes), ["LAN", "TAM", "LPE", "LNE", "LXP"])
  assert.deepEqual(Array.from(M.parseAirlinePrefixes("garbage", "ZZ")), [])
})

// Boxes of a placement overlap (touching edges do not count).
const overlap = (a, b) => a.bx < b.bx + b.w && a.bx + a.w > b.bx && a.by < b.by + b.h && a.by + a.h > b.by
const label = (key, x, y, tier, extra = {}) =>
  ({ key, pool: "flight", x, y, w: 40, h: 10, gap: 6, priority: M.labelPriority(tier, extra.rank || 0), ...extra })

test("globe labels: no overlaps, inside the bounds, most important first", () => {
  const T = M.LABEL_TIER
  const items = [
    label("other", 52, 51, T.aircraft),
    label("sel", 50, 50, T.selected),
    label("far", 200, 200, T.aircraft),
    label("city", 51, 50, T.city, { pool: "place" })
  ]
  const placed = M.placeGlobeLabels(items, { bounds: { x: 0, y: 0, w: 220, h: 220 }, limits: { flight: 10, place: 10 } })
  for (let i = 0; i < placed.length; i++)
    for (let j = i + 1; j < placed.length; j++) assert.ok(!overlap(placed[i], placed[j]), "labels overlap")
  assert.equal(placed[0].item.key, "sel")
  assert.equal(placed[0].side, "right")
  assert.equal(placed[0].bx, 56, "right of the anchor, gap px away")
  assert.equal(placed[0].by, 45, "centred on it")
  assert.ok(placed.every(p => p.bx >= 0 && p.bx + p.w <= 220 && p.by >= 0 && p.by + p.h <= 220))
  // The crowded one moved to another side instead of vanishing.
  assert.ok(placed.find(p => p.item.key === "other").side !== "right")
})

test("globe labels: candidate sides, pools and priority tiers", () => {
  const T = M.LABEL_TIER
  assert.deepEqual({ ...M.labelBox(100, 100, 40, 10, 6, "right") }, { bx: 106, by: 95 })
  assert.deepEqual({ ...M.labelBox(100, 100, 40, 10, 6, "left") }, { bx: 54, by: 95 })
  assert.deepEqual({ ...M.labelBox(100, 100, 40, 10, 6, "above") }, { bx: 80, by: 84 })
  assert.deepEqual({ ...M.labelBox(100, 100, 40, 10, 6, "below") }, { bx: 80, by: 106 })
  // Tiers win over ranks: the lowest selected beats the best city.
  assert.ok(M.labelPriority(T.selected, 0) > M.labelPriority(T.emergency, 0.999))
  assert.ok(M.labelPriority(T.hovered, 0) > M.labelPriority(T.near, 0.9))
  assert.ok(M.labelPriority(T.home, 0) > M.labelPriority(T.city, 0.99))
  assert.ok(M.labelPriority(T.city, 0) > M.labelPriority(T.aircraft, 0.99))
  // A pool's limit only caps that pool.
  const many = []
  for (let i = 0; i < 6; i++) many.push(label("a" + i, 20 + 60 * i, 20, T.aircraft))
  many.push(label("c", 20, 200, T.city, { pool: "place" }))
  const placed = M.placeGlobeLabels(many, { limits: { flight: 2, place: 1 } })
  assert.equal(placed.filter(p => p.item.pool === "flight").length, 2)
  assert.equal(placed.filter(p => p.item.pool === "place").length, 1)
  assert.equal(M.placeGlobeLabels(many, { limits: { flight: 3 } }).length, 3, "no limit, no labels from that pool")
})

test("globe labels: sprites, marks and the last layout's sides", () => {
  const T = M.LABEL_TIER
  const sprite = { bx: 106, by: 92, w: 10, h: 10 }     // right where the label would go
  const one = (extra) => M.placeGlobeLabels([label("a", 100, 100, T.aircraft, extra)], { limits: { flight: 5 }, obstacles: [sprite] })
  assert.equal(one().length, 1)
  assert.equal(one()[0].side, "left", "keeps off a sprite")
  // Boxed in by sprites on every side: a plain label gives up, a soft one covers one.
  const all = ["right", "left", "above", "below"].map(s => {
    const b = M.labelBox(100, 100, 40, 10, 6, s)
    return { bx: b.bx + 5, by: b.by + 2, w: 4, h: 4 }
  })
  const boxed = (soft) => M.placeGlobeLabels([label("a", 100, 100, T.aircraft, { soft })], { limits: { flight: 5 }, obstacles: all })
  assert.equal(boxed(false).length, 0)
  assert.equal(boxed(true).length, 1)
  // A city's dot is never covered by a later label, and a city whose dot is
  // already under a label is left out.
  const city = label("c", 100, 100, T.city, { pool: "place", gap: 5, mark: { bx: 97.5, by: 97.5, w: 5, h: 5 } })
  const plane = label("p", 60, 100, T.aircraft)          // its right side would cover the dot
  const placed = M.placeGlobeLabels([city, plane], { limits: { flight: 5, place: 5 } })
  assert.equal(placed.length, 2)
  assert.notEqual(placed[1].side, "right")
  const late = M.placeGlobeLabels([label("p", 60, 100, T.selected), city], { limits: { flight: 5, place: 5 } })
  assert.equal(late.length, 1, "the dot sits under the selected label")
  // The side from last time is tried first.
  const again = M.placeGlobeLabels([label("a", 100, 100, T.aircraft)], { limits: { flight: 5 }, previous: { a: "below" } })
  assert.equal(again[0].side, "below")
})

test("globe labels stay inside the disc and fade near the limb", () => {
  const T = M.LABEL_TIER
  const disc = { x: 0, y: 0, r: 100 }
  assert.equal(M.discAlpha(-10, -5, 20, 10, disc, 0.06), 1)
  assert.equal(M.discAlpha(95, -5, 20, 10, disc, 0.06), 0, "past the limb")
  near(M.discAlpha(80, -5, 17, 10, disc, 0.06), (100 - Math.hypot(97, 5)) / 6, 1e-9)
  assert.equal(M.discAlpha(500, 500, 10, 10, null, 0.06), 1, "no limb on screen")
  // Near the right limb the label goes left, fully opaque.
  const placed = M.placeGlobeLabels([label("a", 80, 0, T.aircraft)], { disc, limits: { flight: 5 } })
  assert.equal(placed[0].side, "left")
  assert.equal(placed[0].alpha, 1)
  // With no side well inside, the most visible one is taken, faded.
  const edge = M.placeGlobeLabels([label("a", 93, 0, T.aircraft, { w: 4, h: 4, gap: 1, sides: ["right", "above"] })], { disc, limits: { flight: 5 } })
  assert.equal(edge.length, 1)
  assert.equal(edge[0].side, "above")
  assert.ok(edge[0].alpha > 0.35 && edge[0].alpha < 1, String(edge[0].alpha))
})

// ------------------------------------------------------- feed planning

const ASP = { lat: -23.7, lon: 133.88 }       // Alice Springs
const LHR = { lat: 51.47, lon: -0.45 }
const healthy = () => ({ "adsb.lol": { failures: 0, retryAtMs: 0 }, "adsb.fi": { failures: 0, retryAtMs: 0 } })

test("feed mode follows the panel and the visible radius", () => {
  assert.equal(M.feedMode(false, 5000), "home")
  assert.equal(M.feedMode(true, 300), "region")
  assert.equal(M.feedMode(true, 1500), "region")
  assert.equal(M.feedMode(true, 1501), "world")
  assert.equal(M.feedMode(true, NaN), "region", "not settled yet")
})

test("feed queries per mode", () => {
  assert.deepEqual({ ...M.feedQuery("home", null, ASP, 100) }, { lat: -23.7, lon: 133.88, radiusNm: 100 })
  assert.equal(M.feedQuery("home", null, ASP, 900).radiusNm, 250)
  assert.equal(M.feedQuery("home", null, { lat: NaN, lon: NaN }, 100), null)
  assert.deepEqual({ ...M.feedQuery("region", { ...LHR, radiusNm: 400 }, ASP, 100) }, { lat: 51.47, lon: -0.45, radiusNm: 460 })
  assert.equal(M.feedQuery("region", { ...LHR, radiusNm: 10 }, ASP, 100).radiusNm, 50)
  assert.equal(M.feedQuery("region", { ...LHR, radiusNm: 2900 }, ASP, 100).radiusNm, 3000)
  assert.equal(M.feedQuery("region", { lat: 0, lon: 190, radiusNm: 100 }, null, 100).lon, -170)
  assert.deepEqual({ ...M.feedQuery("region", null, ASP, 100) }, { lat: -23.7, lon: 133.88, radiusNm: 250 })
  assert.equal(M.feedQuery("region", null, null, 100), null)
  assert.deepEqual({ ...M.feedQuery("world", null, null, 100) }, { lat: 0, lon: 0, radiusNm: 10800 })
})

test("adsb.fi only ever sees a small circle", () => {
  const world = M.feedQuery("world", null, null, 100)
  assert.equal(M.sourceQuery("adsb.lol", world, ASP), world)
  assert.deepEqual({ ...M.sourceQuery("adsb.fi", world, ASP) }, { lat: -23.7, lon: 133.88, radiusNm: 250 })
  assert.deepEqual({ ...M.sourceQuery("adsb.fi", world, null) }, { lat: 0, lon: 0, radiusNm: 250 })
  const region = { ...LHR, radiusNm: 900 }
  assert.deepEqual({ ...M.sourceQuery("adsb.fi", region, ASP) }, { ...LHR, radiusNm: 250 }, "region keeps its centre")
  const small = { ...LHR, radiusNm: 120 }
  assert.equal(M.sourceQuery("adsb.fi", small, ASP), small)
})

test("cadence and jitter", () => {
  assert.equal(M.cadenceMs("home", 0), 54000)
  assert.equal(M.cadenceMs("home", 1), 66000)
  assert.equal(M.cadenceMs("home", 0.5), 60000)
  assert.equal(M.cadenceMs("region", 0.5), 15000)
  assert.equal(M.cadenceMs("world", 0.5), 60000)
  for (let i = 0; i < 200; i++) {
    const r = Math.random()
    const c = M.cadenceMs("region", r)
    assert.ok(c >= 13500 && c <= 16500, "region " + c)
  }
})

test("backoff doubles from 5 s and stops at 120 s", () => {
  assert.equal(M.backoffMs(0, 0.5), 0)
  assert.deepEqual([1, 2, 3, 4, 5, 6, 7, 50].map(n => M.backoffMs(n, 0.5)), [5000, 10000, 20000, 40000, 80000, 120000, 120000, 120000])
  for (let n = 1; n < 12; n++)
    for (const r of [0, 0.25, 0.99]) {
      const ms = M.backoffMs(n, r)
      assert.ok(ms >= 5000 && ms <= 120000, `n=${n} r=${r} → ${ms}`)
    }
  assert.ok(M.backoffMs(3, 0) < M.backoffMs(3, 1), "jitter spreads retries")
})

test("source choice falls back after three adsb.lol failures and probes it again", () => {
  const h = healthy()
  assert.deepEqual({ ...M.chooseSource(h, 1000) }, { source: "adsb.lol", atMs: 1000 })
  h["adsb.lol"] = { failures: 2, retryAtMs: 9000 }
  assert.deepEqual({ ...M.chooseSource(h, 1000) }, { source: "adsb.lol", atMs: 9000 }, "waits for its backoff")
  h["adsb.lol"] = { failures: 3, retryAtMs: 21000 }
  assert.deepEqual({ ...M.chooseSource(h, 1000) }, { source: "adsb.fi", atMs: 1000 })
  assert.deepEqual({ ...M.chooseSource(h, 21000) }, { source: "adsb.lol", atMs: 21000 }, "probe when the backoff ran out")
  h["adsb.fi"] = { failures: 4, retryAtMs: 50000 }
  assert.deepEqual({ ...M.chooseSource(h, 1000) }, { source: "adsb.lol", atMs: 21000 }, "both failing: earliest wins")
  h["adsb.fi"] = { failures: 1, retryAtMs: 6000 }
  assert.deepEqual({ ...M.chooseSource(h, 1000) }, { source: "adsb.fi", atMs: 6000 })
  assert.deepEqual({ ...M.chooseSource(null, 5) }, { source: "adsb.lol", atMs: 5 })
})

test("planFetch: fresh covering data waits for the cadence", () => {
  const query = M.feedQuery("home", null, ASP, 100)
  const base = { nowMs: 100000, mode: "home", query, centre: ASP, cadenceMs: 60000, health: healthy(), hostLastMs: {} }
  const first = M.planFetch({ ...base, lastQuery: null, lastSuccessMs: 0, lastAttemptMs: 0 })
  assert.equal(first.source, "adsb.lol")
  assert.equal(first.atMs, 100000, "nothing yet: now")
  assert.equal(first.covered, false)
  assert.equal(first.url, "https://api.adsb.lol/v2/point/-23.7000/133.8800/100")
  assert.equal(first.host, "api.adsb.lol")
  const later = M.planFetch({ ...base, lastQuery: query, lastSuccessMs: 90000, lastAttemptMs: 89000 })
  assert.equal(later.covered, true)
  assert.equal(later.atMs, 150000)
  const forced = M.planFetch({ ...base, lastQuery: query, lastSuccessMs: 99000, lastAttemptMs: 98000, force: true })
  assert.equal(forced.atMs, 108000, "refresh still keeps the 10 s feed gap")
  assert.equal(M.planFetch({ ...base, query: null }), null)
})

test("planFetch: a view outside the last answer is fetched at once", () => {
  const view = { ...LHR, radiusNm: 300 }
  const query = M.feedQuery("region", view, ASP, 100)
  const s = { nowMs: 100000, mode: "region", query, viewRadiusNm: 300, centre: LHR, cadenceMs: 15000,
              health: healthy(), hostLastMs: {}, lastSuccessMs: 95000, lastAttemptMs: 95000 }
  // Last answer was the home circle in Australia: as soon as the feed gap allows
  // (10 s after the last request, which went out 5 s ago).
  assert.equal(M.planFetch({ ...s, lastQuery: { ...ASP, radiusNm: 100 } }).atMs, 105000)
  assert.equal(M.planFetch({ ...s, lastQuery: { ...ASP, radiusNm: 100 }, lastAttemptMs: 80000 }).atMs, 100000)
  // Just panned a little inside the last region answer: wait for the cadence.
  const moved = M.planFetch({ ...s, query: M.feedQuery("region", { lat: 51.6, lon: -0.3, radiusNm: 300 }, ASP, 100),
                              lastQuery: query })
  assert.equal(moved.covered, true)
  assert.equal(moved.atMs, 110000)
  // A world answer covers any region and only goes stale with the region cadence.
  const world = { lat: 0, lon: 0, radiusNm: 10800 }
  assert.equal(M.planFetch({ ...s, lastQuery: world, lastSuccessMs: 40000 }).atMs, 100000)
  assert.equal(M.planFetch({ ...s, lastQuery: world, lastSuccessMs: 90000 }).atMs, 105000)
  // Uncovered but the last request was 2 s ago: the feed gap holds it back.
  assert.equal(M.planFetch({ ...s, lastQuery: null, lastAttemptMs: 98000 }).atMs, 108000)
})

test("planFetch: world data is reused while under a minute old", () => {
  const query = M.feedQuery("world", null, null, 100)
  const s = { nowMs: 100000, mode: "world", query, centre: ASP, cadenceMs: 60000, health: healthy(), hostLastMs: {} }
  assert.equal(M.planFetch({ ...s, lastQuery: query, lastSuccessMs: 70000, lastAttemptMs: 70000 }).atMs, 130000)
  assert.equal(M.planFetch({ ...s, lastQuery: { ...ASP, radiusNm: 2000 }, lastSuccessMs: 99000, lastAttemptMs: 99000 }).atMs,
               109000, "region data never stands in for the world")
})

test("planFetch: host spacing, backoff and the adsb.fi fallback", () => {
  const query = M.feedQuery("world", null, null, 100)
  const s = { nowMs: 100000, mode: "world", query, centre: ASP, cadenceMs: 60000, health: healthy(),
              lastQuery: null, lastSuccessMs: 0, lastAttemptMs: 0 }
  assert.equal(M.planFetch({ ...s, hostLastMs: { "api.adsb.lol": 99000 } }).atMs, 102000, "3 s per host")
  const h = healthy()
  h["adsb.lol"] = { failures: 1, retryAtMs: 140000 }
  assert.equal(M.planFetch({ ...s, health: h, hostLastMs: {} }).atMs, 140000)
  h["adsb.lol"] = { failures: 3, retryAtMs: 140000 }
  const fb = M.planFetch({ ...s, health: h, hostLastMs: { "opendata.adsb.fi": 99500 } })
  assert.equal(fb.source, "adsb.fi")
  assert.equal(fb.atMs, 102500)
  assert.equal(fb.url, "https://opendata.adsb.fi/api/v3/lat/-23.7000/lon/133.8800/dist/250")
  // Once adsb.fi answered that circle, it is covered and waits for the cadence
  // instead of hammering the fallback every few seconds.
  const after = M.planFetch({ ...s, nowMs: 103000, health: h, hostLastMs: { "opendata.adsb.fi": 102500 },
                              lastQuery: fb.query, lastSuccessMs: 103000, lastAttemptMs: 102500 })
  assert.equal(after.source, "adsb.fi")
  assert.equal(after.covered, true)
  assert.equal(after.atMs, 163000)
  // At that point adsb.lol's backoff has run out, so it gets the request back
  // (its world query is not covered by the small fi circle: no extra wait).
  const probe = M.planFetch({ ...s, nowMs: 163000, health: h, hostLastMs: { "opendata.adsb.fi": 102500 },
                              lastQuery: fb.query, lastSuccessMs: 103000, lastAttemptMs: 102500 })
  assert.equal(probe.source, "adsb.lol")
  assert.equal(probe.atMs, 163000)
})

test("planFetch: a region wider than adsb.fi allows is still covered by its answer", () => {
  const view = { ...LHR, radiusNm: 1000 }
  const query = M.feedQuery("region", view, ASP, 100)
  const h = healthy()
  h["adsb.lol"] = { failures: 5, retryAtMs: 500000 }
  const s = { nowMs: 100000, mode: "region", query, viewRadiusNm: 1000, centre: LHR, cadenceMs: 15000, health: h,
              hostLastMs: {}, lastQuery: { ...LHR, radiusNm: 250 }, lastSuccessMs: 95000, lastAttemptMs: 95000 }
  const plan = M.planFetch(s)
  assert.equal(plan.source, "adsb.fi")
  assert.equal(plan.covered, true)
  assert.equal(plan.atMs, 110000)
})

test("classifyFetch reads curl's exit code and status", () => {
  assert.equal(M.classifyFetch(0, "200").ok, true)
  assert.equal(M.classifyFetch(0, "429").rateLimited, true)
  assert.equal(M.classifyFetch(0, "503").error, "HTTP 503")
  assert.equal(M.classifyFetch(0, "000").error, "no connection")
  assert.equal(M.classifyFetch(28, "").error, "no connection")
  assert.equal(M.classifyFetch(7, "200").ok, false, "a dropped transfer is not a success")
  assert.equal(M.classifyFetch(0, "<html>404").code, 404, "status is the last three characters")
})

// ------------------------------------------------------ summary and meta

const summaryLine = JSON.stringify({
  ok: true, rev: 12, source: "adsb.lol", epochMs: 1791058514001, fetchedMs: 1791058814001,
  n: 3, airborne: 2, dropped: 0, query: { lat: 0, lon: 0, radiusNm: 10800 },
  home: { lat: -23.7, lon: 133.88, radiusNm: 100, count: 1, nearest: [
    { i: 2, hex: "7c8db1", cs: "QFA1492", ty: "B738", rg: "VH-XZB", op: "", lat: -23.9, lon: 133.8, alt: 40000,
      gs: 455, trk: 41, vr: 0, km: 41.2, brg: 44.0 },
    { i: 1, hex: "<script>", lat: 1, lon: 2 },
    { i: 0, hex: "abcdef", lat: 999, lon: 2 }] },
  emergencies: [{ i: 1, hex: "4d2453", cs: "WZZ239", sq: "7700", lat: 50.29, lon: 8.05, alt: 12000 }],
  maxGs: 612
})

test("parseSummary keeps the shape and cleans rows", () => {
  const s = M.parseSummary(summaryLine + "\n")
  assert.equal(s.ok, true)
  assert.equal(s.rev, 12)
  assert.equal(s.n, 3)
  assert.equal(s.maxGs, 612)
  assert.equal(s.home.count, 1)
  assert.equal(s.home.nearest.length, 2, "row without a position dropped")
  assert.equal(s.home.nearest[0].cs, "QFA1492")
  assert.equal(s.home.nearest[1].hex, "", "markup never survives")
  assert.equal(s.emergencies[0].sq, "7700")
  assert.equal(s.query.radiusNm, 10800)
  const any = M.parseSummary(JSON.stringify({ ok: true, rev: 1, epochMs: 5, n: 1, home: { lat: 1, lon: 2, radiusNm: 100,
    count: 0, nearest: [], nearestAny: [{ i: 0, hex: "abcdef", cs: "GLO1", lat: 5, lon: 6, km: 640.2, brg: 45 }, { lat: 99 }] } }))
  assert.equal(any.home.nearestAny.length, 1, "bad rows dropped")
  assert.equal(any.home.nearestAny[0].km, 640.2)
  const none = M.parseSummary(JSON.stringify({ ok: true, rev: 1, epochMs: 5, n: 0, home: null }))
  assert.equal(none.home, null)
  assert.deepEqual(Array.from(none.emergencies), [])
  assert.deepEqual({ ...M.parseSummary('{"ok": false, "error": "bad input"}') }, { ok: false, error: "bad input" })
  assert.equal(M.parseSummary("Traceback (most recent call last):"), null)
  assert.equal(M.parseSummary('{"ok": true, "rev": "x"}').ok, false)
})

const metaText = JSON.stringify({
  rev: 12, epochMs: 1791058514001, n: 2,
  hex: ["4d2453", "7c8db1"], cs: ["WZZ239", ""], ty: ["A21N", "B738"], rg: ["9H-WBI", "VH-XZB"], op: ["", "QFA"],
  lat: [50.2927, -23.9], lon: [8.0567, 133.8], alt: [18400, -1], gs: [368.6, null], trk: [318.96, null],
  t: [297.9, 280.0], vr: [-2048, null], sq: ["7700", ""], cat: ["A3", "A3"], flags: [2 | 8, 1]
})

test("parseMeta and metaRow", () => {
  const meta = M.parseMeta(metaText)
  assert.equal(meta.n, 2)
  const a = M.metaRow(meta, 0)
  assert.equal(a.cs, "WZZ239")
  assert.equal(a.flags, 10)
  assert.equal(a.t, 297.9)
  const b = M.metaRow(meta, 1)
  assert.equal(b.gs, null)
  assert.equal(b.alt, -1)
  assert.equal(M.metaRow(meta, 2), null)
  assert.equal(M.metaRow(meta, -1), null)
  assert.equal(M.metaRow(meta, 0.5), null)
  assert.equal(M.metaRow(null, 0), null)
  assert.equal(M.parseMeta("nope"), null)
  assert.equal(M.parseMeta(JSON.stringify({ n: 3, hex: [] })), null, "short columns are refused")
})

test("toAircraft feeds the existing formatters", () => {
  const meta = M.parseMeta(metaText)
  const a = M.toAircraft(M.metaRow(meta, 0), meta.epochMs)
  assert.equal(M.displayName(a), "WZZ239")
  assert.equal(M.formatAltitude(a, "aviation"), "18,400 ft")
  assert.equal(M.isEmergency(a), true)
  assert.equal(M.emergencyLabel(a), "Emergency (7700)")
  assert.equal(M.phaseOf(a), "Descending")
  assert.equal(a.positionTimeMs, meta.epochMs + 297900)
  const g = M.toAircraft(M.metaRow(meta, 1), meta.epochMs)
  assert.equal(g.onGround, true)
  assert.equal(M.formatAltitude(g, "metric"), "Ground")
  assert.equal(M.displayName(g), "VH-XZB")
  const s = M.parseSummary(summaryLine)
  const n = M.toAircraft(s.home.nearest[0], s.epochMs)
  assert.equal(M.formatAltitude(n, "aviation"), "40,000 ft")
  assert.ok(Number.isNaN(n.positionTimeMs), "summary rows have no observation time")
  assert.equal(M.toAircraft(null), null)
})

// --------------------------------------------------------------- routes

const routeMelSyd = {
  origin: { code: "MEL", lat: -37.6690, lon: 144.8410 },
  destination: { code: "SYD", lat: -33.9461, lon: 151.1772 },
  airline: "Qantas"
}

test("route parser keeps airport coordinates", () => {
  // Trimmed adsbdb answer for RYR8EG.
  const text = JSON.stringify({"response": {"flightroute": {"callsign": "RYR8EG", "airline": {"name": "Ryanair"}, "origin": {"iata_code": "VRN", "icao_code": "LIPX", "latitude": 45.395699, "longitude": 10.8885, "municipality": "Verona", "name": "Verona Villafranca Airport", "country_name": "Italy"}, "destination": {"iata_code": "DUB", "icao_code": "EIDW", "latitude": 53.421299, "longitude": -6.27007, "municipality": "Dublin", "name": "Dublin Airport", "country_name": "Ireland"}}}})
  const r = M.parseRoute(text)
  assert.equal(r.origin.code, "VRN")
  near(r.origin.lat, 45.395699); near(r.destination.lon, -6.27007)
  assert.equal(M.routePlausible(r, 49.5, 2.0), true, "over France, on the way to Dublin")
  assert.equal(M.routePlausible(r, 40.0, 20.0), false, "over Greece")
})

test("route deviation geometry", () => {
  const o = routeMelSyd.origin, d = routeMelSyd.destination
  near(M.routeDeviationKm(o.lat, o.lon, d.lat, d.lon, o.lat, o.lon), 0, 1e-6)
  near(M.routeDeviationKm(o.lat, o.lon, d.lat, d.lon, d.lat, d.lon), 0, 1e-3)
  // A point on the great circle halfway along.
  const mid = M.slerpLonLat(o.lat, o.lon, d.lat, d.lon, 0.5)
  near(M.routeDeviationKm(o.lat, o.lon, d.lat, d.lon, mid.lat, mid.lon), 0, 1e-3)
  // 100 km abeam the midpoint.
  const brg = M.bearingDeg(mid.lat, mid.lon, d.lat, d.lon)
  const abeam = M.destination(mid.lat, mid.lon, brg + 90, 100)
  near(M.routeDeviationKm(o.lat, o.lon, d.lat, d.lon, abeam.lat, abeam.lon), 100, 0.5)
  // Beyond the destination the distance is to the destination itself.
  const past = M.destination(d.lat, d.lon, M.bearingDeg(o.lat, o.lon, d.lat, d.lon) + 180 + 180, 300)
  near(M.routeDeviationKm(o.lat, o.lon, d.lat, d.lon, past.lat, past.lon), 300, 1)
  // Behind the origin likewise.
  const behind = M.destination(o.lat, o.lon, M.bearingDeg(o.lat, o.lon, d.lat, d.lon) + 180, 200)
  near(M.routeDeviationKm(o.lat, o.lon, d.lat, d.lon, behind.lat, behind.lon), 200, 0.5)
  near(M.routeDeviationKm(0, 0, 0, 0, 0, 1), M.distanceKm(0, 0, 0, 1), 1e-6)
})

test("routePlausible uses max(150 km, 15 % of the length)", () => {
  const o = routeMelSyd.origin, d = routeMelSyd.destination
  const len = M.distanceKm(o.lat, o.lon, d.lat, d.lon)
  assert.ok(len > 690 && len < 720, "MEL-SYD ~705 km, got " + len)
  const mid = M.slerpLonLat(o.lat, o.lon, d.lat, d.lon, 0.5)
  const brg = M.bearingDeg(mid.lat, mid.lon, d.lat, d.lon)
  const at = km => M.destination(mid.lat, mid.lon, brg - 90, km)
  assert.equal(M.routePlausible(routeMelSyd, at(140).lat, at(140).lon), true)
  assert.equal(M.routePlausible(routeMelSyd, at(160).lat, at(160).lon), false)
  // A long route allows 15 %: LHR-BOM is ~7,200 km → ~1,080 km.
  const lhrBom = { origin: { lat: 51.47, lon: -0.45 }, destination: { lat: 19.09, lon: 72.87 } }
  const m2 = M.slerpLonLat(51.47, -0.45, 19.09, 72.87, 0.5)
  const b2 = M.bearingDeg(m2.lat, m2.lon, 19.09, 72.87)
  const off = d => M.destination(m2.lat, m2.lon, b2 + 90, d)
  assert.equal(M.routePlausible(lhrBom, off(1000).lat, off(1000).lon), true)
  assert.equal(M.routePlausible(lhrBom, off(1200).lat, off(1200).lon), false)
  assert.equal(M.routePlausible({ origin: { lat: NaN, lon: NaN }, destination: d }, mid.lat, mid.lon), false)
  assert.equal(M.routePlausible(null, 0, 0), false)
})

test("routeProgress and ETA", () => {
  const o = routeMelSyd.origin, d = routeMelSyd.destination
  const mid = M.slerpLonLat(o.lat, o.lon, d.lat, d.lon, 0.5)
  const p = M.routeProgress(routeMelSyd, mid.lat, mid.lon, 450)
  near(p.progress, 0.5, 1e-3)
  near(p.remainingKm, p.totalKm / 2, 0.5)
  // 353 km at 450 kt (833.4 km/h) is ~25 min.
  near(p.seconds, Math.round(p.remainingKm / (450 * 1.852) * 3600), 0)
  assert.ok(p.seconds > 24 * 60 && p.seconds < 27 * 60)
  assert.equal(M.routeProgress(routeMelSyd, o.lat, o.lon, 10).seconds, null, "taxiing")
  near(M.routeProgress(routeMelSyd, o.lat, o.lon, 300).progress, 0, 1e-9)
  assert.equal(M.routeProgress(null, 0, 0, 400), null)
})

// ------------------------------------------------------ source settings

test("feedSource: adsb.fi first when preferred, adsb.lol as its fallback", () => {
  const h = healthy()
  assert.deepEqual({ ...M.chooseSource(h, 1000, "adsb.fi") }, { source: "adsb.fi", atMs: 1000 })
  assert.deepEqual({ ...M.chooseSource(h, 1000, "nonsense") }, { source: "adsb.lol", atMs: 1000 })
  h["adsb.fi"] = { failures: 3, retryAtMs: 40000 }
  assert.deepEqual({ ...M.chooseSource(h, 1000, "adsb.fi") }, { source: "adsb.lol", atMs: 1000 })
  assert.deepEqual({ ...M.chooseSource(h, 40000, "adsb.fi") }, { source: "adsb.fi", atMs: 40000 })
  const query = M.feedQuery("home", null, ASP, 100)
  const plan = M.planFetch({ nowMs: 1000, mode: "home", query, centre: ASP, cadenceMs: 60000,
                             health: healthy(), hostLastMs: {}, preferred: "adsb.fi" })
  assert.equal(plan.url, "https://opendata.adsb.fi/api/v3/lat/-23.7000/lon/133.8800/dist/100")
})

test("wideQueries off holds adsb.lol to 250 NM", () => {
  const world = M.feedQuery("world", null, null, 100)
  assert.deepEqual({ ...M.sourceQuery("adsb.lol", world, ASP, false) }, { lat: -23.7, lon: 133.88, radiusNm: 250 })
  assert.equal(M.sourceQuery("adsb.lol", world, ASP, true), world)
  assert.equal(M.sourceQuery("adsb.lol", world, ASP), world, "default stays wide")
  const base = { nowMs: 1000, mode: "world", query: world, centre: LHR, cadenceMs: 60000, health: healthy(), hostLastMs: {} }
  assert.equal(M.planFetch({ ...base, wide: false }).url, "https://api.adsb.lol/v2/point/51.4700/-0.4500/250")
  assert.equal(M.planFetch(base).url, "https://api.adsb.lol/v2/point/0.0000/0.0000/10800")
})

// ------------------------------------------------------------ the camera

test("reckon matches destination() and stops at maxAge", () => {
  const a = M.reckon(-23.7, 133.88, 45, 450, 60, 90)
  const km = 450 * 1.852 / 3600 * 60
  const b = M.destination(-23.7, 133.88, 45, km * M.EARTH_RADIUS_KM / 6371)
  near(a.lat, b.lat, 1e-6); near(a.lon, b.lon, 1e-6)
  const capped = M.reckon(-23.7, 133.88, 45, 450, 500, 90)
  const at90 = M.reckon(-23.7, 133.88, 45, 450, 90, 90)
  near(capped.lat, at90.lat, 1e-12); near(capped.lon, at90.lon, 1e-12)
  assert.deepEqual({ ...M.reckon(1, 2, null, 450, 60, 90) }, { lat: 1, lon: 2 }, "no track")
  assert.deepEqual({ ...M.reckon(1, 2, 90, null, 60, 90) }, { lat: 1, lon: 2 }, "no speed")
  assert.deepEqual({ ...M.reckon(1, 2, 90, 450, -5, 90) }, { lat: 1, lon: 2 }, "future observation")
  const e = M.reckon(0, 179.99, 90, 600, 60, 90)
  assert.ok(e.lon < -179, "wraps the antimeridian: " + e.lon)
})

test("motionFrame vectors follow the same great circle as reckon", () => {
  for (const [lat, lon, trk, gs, age] of [[-23.7, 133.88, 45, 450, 60], [51.47, -0.45, 270, 300, 90], [70, 179.9, 10, 600, 30], [0, 0, 180, 120, 5]]) {
    const f = M.motionFrame(lat, lon, trk)
    const d = gs * M.KT_RAD_PER_S * age
    const v = [0, 1, 2].map(i => f[i] * Math.cos(d) + f[i + 3] * Math.sin(d))
    const q = M.reckon(lat, lon, trk, gs, age, 90)
    const w = M.vecFromLonLat(q.lon, q.lat)
    for (let i = 0; i < 3; i++) near(v[i], w[i], 1e-12)
  }
})

test("visible radius and its inverse", () => {
  near(M.visibleRadiusNm(300, 400), M.HEMISPHERE_NM, 1e-9)
  const r = M.radiusForVisibleNm(250, 450, 300)
  near(M.visibleRadiusNm(r, 450), 250, 1e-6)
  assert.equal(M.radiusForVisibleNm(6000, 450, 300), 300)
  assert.equal(M.radiusForVisibleNm(0, 450, 300), 300)
  assert.ok(M.radiusForVisibleNm(3000, 450, 600) >= 600, "never smaller than the fitted globe")
})

test("anchorView keeps a point under the cursor", () => {
  for (const [lat, lon, ux, uy] of [[-23.7, 133.88, 0.3, -0.2], [51.47, -0.45, -0.5, 0.4], [10, 179.5, 0.2, 0.1], [-60, 20, 0, 0]]) {
    const c = M.anchorView(lat, lon, ux, uy)
    assert.ok(c, `solvable ${lat},${lon}`)
    const p = M.projectLonLat(M.viewMatrix(c.lon, c.lat), lon, lat)
    near(p.x, ux, 1e-9); near(p.y, uy, 1e-9)
    assert.ok(p.z > 0, "in front")
  }
  assert.equal(M.anchorView(0, 0, 0.9, 0.9), null, "off the globe")
  assert.equal(M.anchorView(89.9, 0, 0.5, 0), null, "east-west offset impossible next to the pole")
})

test("idle tick: half a pixel of the fastest aircraft, clamped", () => {
  // 612 kt on a 300 px globe: ~0.015 px/s, so the 30 s ceiling.
  assert.equal(M.idleTickMs(612, 300, 500, 30000), 30000)
  // 250 NM view in a 900 px viewport: radius ~6,200 px → ~1.6 s.
  const r = M.radiusForVisibleNm(250, 450 * Math.SQRT2, 400)
  const ms = M.idleTickMs(612, r, 500, 30000)
  assert.ok(ms > 1000 && ms < 3000, "region tick " + ms)
  assert.equal(M.idleTickMs(612, 1e7, 500, 30000), 500, "floor")
  assert.equal(M.idleTickMs(0, 5000, 500, 30000), 30000, "nothing moves")
})

test("sprite size grows from dots to glyphs", () => {
  near(M.spritePxFor(M.HEMISPHERE_NM), 2.6, 1e-9)
  near(M.spritePxFor(60), 8, 1e-9)
  near(M.spritePxFor(12), 11.5, 1e-9)
  near(M.spritePxFor(5), 11.5, 1e-9)
  near(M.spritePxFor(30), 8 + 3.5 * Math.log(2) / Math.log(5), 1e-9)
  const at1500 = M.spritePxFor(1500)
  assert.ok(at1500 > 3.5 && at1500 < 4.5, "continental " + at1500)
})

test("fly-to radius rises over long hops and ends exactly", () => {
  near(M.flightRadius(5000, 8000, 300, 1.2, 0), 5000, 1e-6)
  near(M.flightRadius(5000, 8000, 300, 1.2, 1), 8000, 1e-6)
  assert.ok(M.flightRadius(5000, 8000, 300, 1.2, 0.5) < 400, "pulls back to see both ends")
  const short = M.flightRadius(5000, 5000, 300, 0.001, 0.5)
  near(short, 5000, 1e-6)
  near(M.easeInOut(0), 0); near(M.easeInOut(1), 1); near(M.easeInOut(0.5), 0.5)
})

test("short altitudes, durations and the hero meta line", () => {
  assert.equal(M.formatAltitudeShort(37000, false, "aviation"), "FL370")
  assert.equal(M.formatAltitudeShort(9000, false, "imperial"), "9,000 ft")
  assert.equal(M.formatAltitudeShort(8550, false, "aviation"), "8,600 ft")
  assert.equal(M.formatAltitudeShort(37000, false, "metric"), "11,300 m")
  assert.equal(M.formatAltitudeShort(0, true, "metric"), "GND")
  assert.equal(M.formatAltitudeShort(null, false, "metric"), "")
  assert.equal(M.formatDuration(31 * 60 + 10), "31 min")
  assert.equal(M.formatDuration(20), "1 min")
  assert.equal(M.formatDuration(65 * 60), "1 h 05 min")
  assert.equal(M.formatDuration(null), "")
  assert.equal(M.heroMeta("Zürich", 4, 189, 9412), "ZÜRICH · 4 NEAR · 189 IN VIEW · 9,412 WORLDWIDE")
  assert.equal(M.heroMeta("", -1, -1, 9412), "9,412 WORLDWIDE")
  assert.equal(M.heroMeta("", 0, -1, -1), "0 NEAR")
  assert.equal(M.heroMeta("Lisboa", 2, -1, 8000, 3), "LISBOA · 2 NEAR · 3 IN YOUR SKY · 8,000 WORLDWIDE")
  assert.equal(M.formatSoon(20), "now")
  assert.equal(M.formatSoon(185), "in 3 min")
  assert.equal(M.formatSoon(NaN), "")
})

if (failures) {
  console.log(`\n${failures} failing`)
  process.exit(1)
}
console.log("\nall passing")
