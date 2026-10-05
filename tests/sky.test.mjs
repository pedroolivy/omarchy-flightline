// Run: node tests/sky.test.mjs
// Loads SkyModel.js (a QML ".pragma library" script) into a plain JS context.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"
import vm from "node:vm"
import assert from "node:assert/strict"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "SkyModel.js"), "utf8").replace(/^\.pragma library\s*/, "")
const S = {}
vm.createContext(S)
vm.runInContext(source, S)

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
const KM_PER_DEG = 111.19508          // 2π·6371.0088 / 360

// A point `km` due north of (lat, lon) on the sphere.
const north = (lat, lon, km) => ({ lat: lat + km / KM_PER_DEG, lon })

test("elevation of an aircraft at 11 km altitude matches the spec table", () => {
  const cases = [[10, 47.7], [25, 23.6], [50, 12.2], [100, 5.8]]
  for (const [km, el] of cases) {
    const p = north(-23.7, 133.88, km)
    const a = S.lookAngles(-23.7, 133.88, 0, p.lat, p.lon, 11000)
    near(a.el, el, 0.05)
    near(a.az, 0, 1e-6)
    near(a.groundKm, km, 1e-6)
  }
})

test("directly overhead is 90° and a range equal to the altitude", () => {
  const a = S.lookAngles(51.47, -0.45, 0, 51.47, -0.45, 10668)
  near(a.el, 90, 1e-9)
  near(a.rangeKm, 10.668, 1e-9)
})

test("azimuth follows the compass", () => {
  const f = (lat, lon) => S.lookAngles(0, 0, 0, lat, lon, 10000).az
  near(f(1, 0), 0)
  near(f(0, 1), 90)
  near(f(-1, 0), 180)
  near(f(0, -1), 270)
  near(f(1, 1), 45, 0.01)
})

test("azimuth and distance work across the antimeridian and the poles' neighbourhood", () => {
  const a = S.lookAngles(0, 179.5, 0, 0, -179.5, 10000)
  near(a.az, 90)
  near(a.groundKm, KM_PER_DEG, 1e-6)
  const b = S.lookAngles(89, 10, 0, 89, 190, 10000)
  near(b.groundKm, 2 * KM_PER_DEG, 1e-3)
})

test("an aircraft at 11 km goes below the horizon at about 374 km", () => {
  const h = S.horizonDistanceKm(11000, 0)
  near(h, 374.1, 0.2)
  const p = north(0, 0, h)
  near(S.lookAngles(0, 0, 0, p.lat, p.lon, 11000).el, 0, 1e-6)
  const q = north(0, 0, 400)
  assert.ok(S.lookAngles(0, 0, 0, q.lat, q.lon, 11000).el < 0)
  const r = north(0, 0, 350)
  assert.ok(S.lookAngles(0, 0, 0, r.lat, r.lon, 11000).el > 0)
})

test("horizon distance grows with the observer's height too", () => {
  assert.ok(S.horizonDistanceKm(11000, 1000) > S.horizonDistanceKm(11000, 0) + 100)
  near(S.horizonDistanceKm(0, 0), 0, 1e-9)
})

test("a ground-level target on the ground is below the horizon at any distance", () => {
  const p = north(0, 0, 5)
  assert.ok(S.lookAngles(0, 0, 0, p.lat, p.lon, 0).el < 0)
})

test("horizon dip at 11 km is about 3.4°", () => {
  near(S.dipDeg(11000), 3.37, 0.02)
  near(S.dipDeg(0), 0, 1e-9)
})

// ---------------------------------------------------------------- sun

const at = (iso) => new Date(iso)

test("June solstice: subsolar latitude is the tropic", () => {
  near(S.sunSubpoint(at("2026-06-21T08:24:00Z")).lat, 23.44, 0.05)
})

test("March equinox: the sun is over the equator", () => {
  near(S.sunSubpoint(at("2026-03-20T14:46:00Z")).lat, 0, 0.08)
})

test("solar noon at the equator on the solstice: due north, 66.5° up", () => {
  // equation of time is about -1.9 min on 21 June, so noon at 0° is 12:02 UTC
  const sub = S.sunSubpoint(at("2026-06-21T12:02:00Z"))
  const sun = S.sunAltAz(sub, 0, 0)
  near(sun.el, 66.56, 0.3)
  assert.ok(Math.abs(((sun.az + 180) % 360) - 180) < 1.5, `az ${sun.az}`)
})

test("solar noon at Greenwich on 1 January: due south, 15.5° up", () => {
  const sun = S.sunAltAz(S.sunSubpoint(at("2026-01-01T12:03:00Z")), 51.4769, 0)
  near(sun.el, 15.5, 0.4)
  near(sun.az, 180, 1.5)
})

test("morning sun is in the east, evening sun in the west", () => {
  const sub = (h) => S.sunSubpoint(at(`2026-10-03T${h}:00Z`))
  const am = S.sunAltAz(sub("09:00"), 51.47, -0.45)     // 10:00 BST
  const pm = S.sunAltAz(sub("15:00"), 51.47, -0.45)
  assert.ok(am.az > 90 && am.az < 180, `am az ${am.az}`)
  assert.ok(pm.az > 180 && pm.az < 270, `pm az ${pm.az}`)
})

test("midnight sun is far below the horizon", () => {
  const sun = S.sunAltAz(S.sunSubpoint(at("2026-10-03T00:00:00Z")), 0, 0)
  assert.ok(sun.el < -60, `el ${sun.el}`)
})

test("J2000 noon: the sun is at declination -23.0° near longitude 0.8°", () => {
  const sub = S.sunSubpoint(at("2000-01-01T12:00:00Z"))
  near(sub.lat, -23.0, 0.1)
  near(sub.lon, 0.8, 0.4)
})

test("sunset in Cape Town: the sun crosses the horizon in the evening, in the west", () => {
  // Cape Town (-33.92, 18.42), early October: geometric sunset about 18:47 local
  // = 16:47 UTC, azimuth ~265 degrees (the almanac's 18:51 includes refraction)
  let prev = null, crossed = null
  for (let m = 15 * 60; m < 18 * 60; m += 2) {
    const d = new Date(Date.UTC(2026, 9, 3, 0, m))
    const s = S.sunAltAz(S.sunSubpoint(d), -33.92, 18.42)
    if (prev !== null && prev > 0 && s.el <= 0) crossed = { m, az: s.az }
    prev = s.el
  }
  assert.ok(crossed, "no sunset found")
  assert.ok(crossed.m >= 16 * 60 + 32 && crossed.m <= 17 * 60 + 2, `sunset at ${crossed.m / 60}`)
  assert.ok(crossed.az > 260 && crossed.az < 280, `az ${crossed.az}`)
})

test("an aircraft at 11 km stays sunlit until the sun is 3.4° below the horizon", () => {
  assert.equal(S.isSunlit(-1, -1, 11000), true)
  assert.equal(S.isSunlit(-5, -3, 11000), true)
  assert.equal(S.isSunlit(-8, -3.5, 11000), false)
  assert.equal(S.isSunlit(10, 10, 11000), false)      // daytime: nothing to remark on
  assert.equal(S.isSunlit(-1, -1, 0), false)
})

// --------------------------------------------- sun, moon and planets (Meeus)

// Meeus, "Astronomical Algorithms" (2nd ed.): worked examples in Terrestrial
// Time, so these pass Julian Ephemeris Days straight in.
const hours = (h, m, s) => (h + m / 60 + s / 3600) * 15
const degs = (d, m, s) => d + m / 60 + s / 3600
const ARCSEC = 1 / 3600
const sepDeg = (a, b) => {
  const D = Math.PI / 180
  return Math.acos(Math.min(1, Math.sin(a.el * D) * Math.sin(b.el * D)
    + Math.cos(a.el * D) * Math.cos(b.el * D) * Math.cos((a.az - b.az) * D))) / D
}

test("Julian Day: J2000.0 and the Unix epoch", () => {
  near(S.julianDay(Date.UTC(2000, 0, 1, 12)), 2451545.0, 1e-9)
  near(S.julianDay(0), 2440587.5, 1e-9)
})

test("Sun, Meeus ex. 25.a (1992 Oct 13.0 TD): apparent α 13h13m31.4s, δ −7°47′06″ within 2″", () => {
  const sun = S.sunPosition(2448908.5)
  near(sun.ra, hours(13, 13, 31.4), 2 * ARCSEC)
  near(sun.dec, -degs(7, 47, 6), 2 * ARCSEC)
  near(sun.lambda, 199.90895, 0.0001)
  near(sun.R, 0.99766, 0.00001)
})

test("Moon, Meeus ex. 47.a (1992 Apr 12.0 TD): λ, β to 1e-5°, distance to 0.1 km, α δ to 0.2″", () => {
  const moon = S.moonPosition(2448724.5)
  near(moon.lambda, 133.162655, 1e-5)
  near(moon.beta, -3.229126, 1e-5)
  near(moon.distKm, 368409.7, 0.1)
  near(moon.ra, 134.688470, 0.2 * ARCSEC)
  near(moon.dec, 13.768368, 0.2 * ARCSEC)
})

test("Moon's phase, Meeus ex. 48.a (same instant): i 69.08°, k 0.6786, bright limb χ 285.0°", () => {
  const ph = S.moonPhase(S.sunPosition(2448724.5), S.moonPosition(2448724.5))
  near(ph.phaseAngle, 69.0756, 0.01)
  near(ph.illuminated, 0.6786, 0.0005)
  near(ph.brightLimb, 285.0, 0.2)
})

test("Venus, Meeus ex. 33.a (1992 Dec 20.0 TD): α 21h04m41.454s, δ −18°53′16.84″ within 0.01°", () => {
  // The elements are the JPL approximate ones, not VSOP87: 20″ off here,
  // up to ~0.2° for Saturn, far below a pixel of the dome.
  const v = S.planetPosition("venus", 2448976.5)
  near(v.ra, hours(21, 4, 41.454), 0.01)
  near(v.dec, -degs(18, 53, 16.84), 0.01)
  near(v.delta, 0.910845, 0.0005)
  near(v.mag, -4.2, 0.2)
})

test("total solar eclipse of 2026 Aug 12 from Reykjavik: Sun and Moon meet (parallax is applied)", () => {
  // 17:48 UT: geocentrically they are ~0.9° apart; the observer's parallax brings them together
  const b = S.skyBodies(Date.UTC(2026, 7, 12, 17, 48), 64.15, -21.94, 0)
  assert.ok(sepDeg(b.sun, b.moon) < 0.1, `separation ${sepDeg(b.sun, b.moon)}`)
  assert.ok(b.sun.up && b.moon.up)
  assert.ok(b.moon.illuminated < 0.001)
})

test("total lunar eclipse of 2026 Mar 3: the Moon is full, opposite the Sun", () => {
  const jde = S.julianDay(Date.UTC(2026, 2, 3, 11, 33)) + 69 / 86400
  const ph = S.moonPhase(S.sunPosition(jde), S.moonPosition(jde))
  assert.ok(ph.illuminated > 0.9999, `k ${ph.illuminated}`)
  assert.ok(ph.elongation > 179, `elongation ${ph.elongation}`)
})

test("Venus at greatest eastern elongation, 2026 Aug 15: 45.9° from the Sun", () => {
  near(S.planetPosition("venus", S.julianDay(Date.UTC(2026, 7, 15)) + 69 / 86400).elongation, 45.9, 0.3)
})

test("refraction lifts the horizon by about 0.5° and nothing near the zenith", () => {
  near(S.refractionDeg(0), 0.48, 0.02)
  near(S.refractionDeg(90), 0, 1e-4)
  near(S.refractionDeg(45), 1 / 60, 0.002)
  assert.equal(S.refractionDeg(-5), 0)
})

test("twilight names follow the Sun's altitude", () => {
  assert.deepEqual([10, -0.5, -3, -9, -15, -30].map(S.twilightOf), ["day", "day", "civil", "nautical", "astronomical", "night"])
})

test("the sky's Sun agrees with the globe's subsolar point", () => {
  for (const iso of ["2026-01-01T12:03:00Z", "2026-06-21T05:00:00Z", "2026-10-03T21:42:50Z"]) {
    const ms = Date.parse(iso)
    const a = S.skyBodies(ms, 51.4769, 0, 0).sun
    const b = S.sunAltAz(S.sunSubpoint(new Date(ms)), 51.4769, 0)
    near(a.trueEl, b.el, 0.05)
    near(a.az, b.az, 0.1)
  }
})

test("London at civil dusk, 2026 Apr 19: Venus low in the west, a young waxing Moon beside it, Jupiter up", () => {
  const b = S.skyBodies(Date.parse("2026-04-19T19:40:00Z"), 51.5074, -0.1278, 0)
  assert.equal(b.twilight, "civil")
  assert.equal(b.dusk, true)
  const venus = b.planets.find(p => p.name === "venus")
  assert.ok(venus.visible && venus.el > 10 && venus.az > 270 && venus.az < 300, JSON.stringify(venus))
  assert.ok(b.moon.up && b.moon.waxing && b.moon.illuminated < 0.15)
  assert.ok(b.planets.find(p => p.name === "jupiter").visible)
  assert.ok(!b.planets.find(p => p.name === "saturn").visible)       // below the horizon
  assert.equal(b.planets[0].name, "venus")                            // brightest first
  // the lit limb faces the Sun: the step towards it lowers the elevation and heads west
  assert.ok(b.moon.limb.el < b.moon.el)
})

test("planets hide by day and in bright twilight, the Moon does not", () => {
  const noon = S.skyBodies(Date.parse("2026-10-03T02:40:00Z"), 35.6762, 139.6503, 0)   // Tokyo
  assert.equal(noon.twilight, "day")
  assert.ok(noon.sun.up && noon.sun.el > 45)
  assert.equal(noon.planets.filter(p => p.visible).length, 0)
  assert.ok(noon.planets.some(p => p.up))
  assert.ok(noon.moon.up)
  // Venus shows from a Sun just below the horizon, a first-magnitude planet near −8°
  near(S.sunLimitFor(-4.4), -1.4, 1e-9)
  assert.ok(S.sunLimitFor(1) < -8.5)
})

test("Mercury is kept back until it is clear of the Sun and of the horizon", () => {
  for (let h = 0; h < 48; h++) {
    const b = S.skyBodies(Date.UTC(2026, 3, 1) + h * 1800000 * 7, 51.5, -0.13, 0)
    const m = b.planets.find(p => p.name === "mercury")
    if (m.visible) assert.ok(m.elongation >= 12 && m.el >= 3 && b.sun.trueEl <= S.sunLimitFor(m.mag))
  }
})

test("skyBodies is cheap enough for every 10 s tick", () => {
  S.skyBodies(Date.now(), 40.71, -74.0, 0)
  const t0 = performance.now()
  for (let k = 0; k < 200; k++) S.skyBodies(Date.now() + k * 1e7, 40.71, -74.0, 0)
  const ms = (performance.now() - t0) / 200
  console.log(`     ${ms.toFixed(3)} ms per call`)
  assert.ok(ms < 2, `${ms} ms`)
})

// ------------------------------------------------------------ projection

test("dome: zenith in the centre, horizon on the circle, east on the left", () => {
  const z = S.domePoint(123, 90, 100, 100, 80, false)
  near(z.x, 100); near(z.y, 100)
  const n = S.domePoint(0, 0, 100, 100, 80, false)
  near(n.x, 100); near(n.y, 20)
  const e = S.domePoint(90, 0, 100, 100, 80, false)
  near(e.x, 20); near(e.y, 100)
  const e2 = S.domePoint(90, 0, 100, 100, 80, true)
  near(e2.x, 180)
  const half = S.domePoint(180, 45, 100, 100, 80, false)
  near(half.y, 140)
})

// ------------------------------------------------------------------ scan

function metaOf(rows, extra) {
  const col = (k, d) => rows.map(r => (k in r ? r[k] : d))
  return Object.assign({
    rev: 1, epochMs: 0, n: rows.length,
    hex: rows.map((r, i) => r.hex || ("a0000" + i)), cs: col("cs", ""), ty: col("ty", ""), rg: col("rg", ""),
    op: col("op", ""), lat: col("lat"), lon: col("lon"), alt: col("alt", 36000), gs: col("gs", 450),
    trk: col("trk", 0), t: col("t", 0), vr: col("vr", 0), sq: col("sq", ""), cat: col("cat", "A3"),
    flags: col("flags", 0)
  }, extra)
}

const OBS = { lat: 0, lon: 0, altM: 0 }

test("scan separates what is in sight from what is beyond the horizon", () => {
  const ft = 11000 / 0.3048
  const near1 = north(0, 0, 25), far1 = north(0, 0, 450)
  const m = metaOf([
    { cs: "NEAR", lat: near1.lat, lon: near1.lon, alt: ft, gs: 0 },
    { cs: "FAR", lat: far1.lat, lon: far1.lon, alt: ft, gs: 0 },
  ])
  const r = S.scan(m, OBS, 0)
  assert.equal(r.sky.length, 1)
  assert.equal(r.sky[0].name, "NEAR")
  near(r.sky[0].el, 23.6, 0.05)
  near(r.sky[0].az, 0, 1e-6)
  assert.equal(r.beyond.length, 1)
  assert.equal(r.beyond[0].name, "FAR")
  near(r.beyond[0].km, 450, 0.01)
  near(r.beyond[0].brg, 0, 1e-6)
  assert.equal(r.rim[0].i, 1)
  assert.equal(r.counts.sky, 1)
  assert.equal(r.counts.beyond, 1)
})

test("scan skips ground traffic, unknown altitude and stale reports", () => {
  const p = north(0, 0, 20)
  const m = metaOf([
    { lat: p.lat, lon: p.lon, alt: -1, flags: 1 },
    { lat: p.lat, lon: p.lon, alt: null },
    { lat: p.lat, lon: p.lon, t: -100 },       // age 100 s at now = 0 → older than 90 s
    { lat: p.lat, lon: p.lon, t: -10, gs: 0 }, // fine
  ])
  const r = S.scan(m, OBS, 0)
  assert.equal(r.sky.length, 1)
  assert.equal(r.sky[0].i, 3)
  assert.deepEqual([r.counts.ground, r.counts.unknownAlt, r.counts.stale], [1, 1, 1])
})

test("scan dead-reckons from the observation time, capped at maxAge, like the shader", () => {
  // 600 kt = 1111 m/s; 30 km south of the observer, flying north, observed 30 s ago
  const p = north(0, 0, -30)
  const m = metaOf([{ lat: p.lat, lon: p.lon, gs: 600, trk: 0, t: 0 }])
  const r = S.scan(m, OBS, 30)
  const moved = 600 * 1.852 / 3600 * 30                 // 9.26 km
  near(r.sky[0].groundKm, 30 - moved, 0.01)
  near(r.sky[0].az, 180, 1e-6)
  // age 80 s: moved 24.7 km, still inside maxAge; then the aircraft is faded
  const late = S.scan(m, OBS, 80)
  near(late.sky[0].groundKm, 30 - 600 * 1.852 / 3600 * 80, 0.01)
  assert.ok(late.sky[0].alpha < 0.5 && late.sky[0].alpha > 0.3, `alpha ${late.sky[0].alpha}`)
  // age 91 s: gone
  assert.equal(S.scan(m, OBS, 91).sky.length, 0)
})

test("path of a fly-by: starts at the aircraft, ends on the far horizon or after 10 min", () => {
  // flying east, 20 km north of the observer, 300 km out to the west
  const west = { lat: 20 / KM_PER_DEG, lon: -300 / KM_PER_DEG }
  const m = metaOf([{ lat: west.lat, lon: west.lon, gs: 480, trk: 90, alt: 36000 }])
  const r = S.scan(m, OBS, 0)
  // 480 kt over 10 min is 148 km: it rises (horizon at 11 km is 374 km out? no: 300 km is inside)
  assert.equal(r.sky.length, 1)
  const path = r.sky[0].path
  near(path[0].t, 0)
  near(path[path.length - 1].t, 600, 1e-6)
  assert.ok(path.length >= 11)
  // all samples are above the horizon, the azimuth swings from west (270°) toward north
  for (const s of path) assert.ok(s.el > 0)
  assert.ok(path[0].az > 265 && path[0].az < 275)
  assert.ok(path[path.length - 1].az > 270 || path[path.length - 1].az < 20)
})

test("path of an overhead pass is dense enough near the zenith", () => {
  const start = { lat: 0.0005, lon: -80 / KM_PER_DEG }   // 80 km west, passing 55 m north of the observer
  const m = metaOf([{ lat: start.lat, lon: start.lon, gs: 480, trk: 90, alt: 36000 }])
  const r = S.scan(m, OBS, 0)
  const path = r.sky[0].path
  let maxJump = 0
  for (let i = 1; i < path.length; i++) {
    const a = path[i - 1], b = path[i]
    const c = Math.sin(a.el * Math.PI / 180) * Math.sin(b.el * Math.PI / 180) +
      Math.cos(a.el * Math.PI / 180) * Math.cos(b.el * Math.PI / 180) * Math.cos((b.az - a.az) * Math.PI / 180)
    maxJump = Math.max(maxJump, Math.acos(Math.min(1, c)) * 180 / Math.PI)
  }
  assert.ok(maxJump <= 6.5, `max step ${maxJump}°`)
  const top = path.reduce((x, y) => (y.el > x.el ? y : x))
  assert.ok(top.el > 85, `top ${top.el}`)
  // 80 km at 889 km/h is 324 s
  near(r.passes[0].tMaxS, 324, 8)
})

test("an aircraft beyond the horizon that is flying in appears as incoming, from the horizon", () => {
  // 450 km out to the east, flying west at 480 kt: it rises after (450-374)/0.247 = 308 s
  const east = { lat: 0, lon: 450 / KM_PER_DEG }
  const m = metaOf([{ cs: "RISE", lat: east.lat, lon: east.lon, gs: 480, trk: 270, alt: 36089 }])
  const r = S.scan(m, OBS, 0, { passMinEl: 0 })
  assert.equal(r.sky.length, 0)
  assert.equal(r.incoming.length, 1)
  const p = r.incoming[0].path
  near(p[0].el, 0, 0.05)
  near(p[0].t, 308, 4)
  assert.ok(p[0].az > 85 && p[0].az < 95)
  assert.equal(r.beyond.length, 1)
  assert.equal(r.passes.length, 1)
  assert.equal(r.passes[0].name, "RISE")
  assert.ok(r.passes[0].maxEl > 0.5 && r.passes[0].maxEl < 1)
  assert.equal(S.scan(m, OBS, 0).passes.length, 0)     // never above the default 10° threshold
})

test("an aircraft beyond the horizon and flying away never shows up in the sky", () => {
  const east = { lat: 0, lon: 450 / KM_PER_DEG }
  const m = metaOf([{ lat: east.lat, lon: east.lon, gs: 480, trk: 90 }])
  const r = S.scan(m, OBS, 0)
  assert.equal(r.sky.length + r.incoming.length, 0)
  assert.equal(r.beyond.length, 1)
})

test("a pass that rises and sets inside the window is cut at both horizons", () => {
  // 380 km north, crossing east to west at 900 kt (463 m/s): it dips in and out of the 374 km circle
  const p = north(0, 0, 360)
  const m = metaOf([{ lat: p.lat, lon: -150 / KM_PER_DEG, gs: 900, trk: 90, alt: 36089 }])
  const r = S.scan(m, OBS, 0)
  const row = r.sky[0] || r.incoming[0]
  assert.ok(row, "no pass")
  const path = row.path
  near(path[path.length - 1].el, 0, 0.05)
  assert.ok(path[path.length - 1].t < 600)
})

test("rim keeps the nearest aircraft per 5° of bearing and the beyond list the nearest overall", () => {
  const rows = []
  for (const km of [500, 420, 900, 700]) {
    const p = { lat: 0, lon: km / KM_PER_DEG }       // all due east: bearing 90, bin 18
    rows.push({ lat: p.lat, lon: p.lon, gs: 0 })
  }
  const south = north(0, 0, -600)
  rows.push({ lat: south.lat, lon: south.lon, gs: 0 })
  rows.push({ lat: south.lat, lon: south.lon + 1, gs: 0 })
  const r = S.scan(metaOf(rows), OBS, 0, { beyondCount: 3 })
  near(r.rim[18].km, 420, 0.01)
  assert.equal(r.rim[18].i, 1)
  assert.deepEqual(Array.from(r.beyond, b => b.i), [1, 0, 4])
  assert.equal(r.counts.beyond, 6)
  assert.equal(r.rim.filter(x => x).length, 3)
})

test("rim ignores aircraft beyond rimMaxKm", () => {
  const p = { lat: 0, lon: 3000 / KM_PER_DEG }
  const r = S.scan(metaOf([{ lat: p.lat, lon: p.lon, gs: 0 }]), OBS, 0)
  assert.equal(r.counts.beyond, 0)
  assert.equal(r.beyond.length, 0)
})

test("emergency flag, sunlit flag and naming", () => {
  const p = north(0, 0, 40)
  const m = metaOf([
    { cs: "", rg: "PR-XYZ", lat: p.lat, lon: p.lon, gs: 0, flags: 2 },
    { cs: "", rg: "", hex: "e49abc", lat: p.lat, lon: p.lon + 0.01, gs: 0 },
  ])
  const night = S.sunSubpoint(at("2026-10-03T00:00:00Z"))   // sun is over the Pacific at 0°E midnight: well below
  const r = S.scan(m, OBS, 0, { sun: S.sunSubpoint(at("2026-10-03T21:00:00Z")) })
  assert.equal(r.sky.find(x => x.i === 0).emergency, true)
  assert.equal(r.sky.find(x => x.i === 0).name, "PR-XYZ")
  assert.equal(r.sky.find(x => x.i === 1).name, "E49ABC")
  // at 0°, 0° on 3 Oct 00:00 UTC the sun is far below the horizon over the Pacific side: not sunlit at 11 km
  assert.equal(S.scan(m, OBS, 0, { sun: night }).sky[0].sunlit, false)
})

test("sunlit: an aircraft at 11 km just after sunset is flagged", () => {
  // find the moment, at the equator, when the sun is about 2° below the horizon
  let when = null
  for (let m = 17 * 60; m < 19 * 60 && !when; m++) {
    const d = new Date(Date.UTC(2026, 2, 20, 0, m))
    if (S.sunAltAz(S.sunSubpoint(d), 0, 0).el < -2) when = d
  }
  const sun = S.sunSubpoint(when)
  const p = north(0, 0, 40)
  const r = S.scan(metaOf([{ lat: p.lat, lon: p.lon, gs: 0 }]), OBS, 0, { sun })
  assert.equal(r.sky[0].sunlit, true)
  const low = S.scan(metaOf([{ lat: p.lat, lon: p.lon, gs: 0, alt: 1000 }]), OBS, 0, { sun })
  assert.equal(low.sky[0].sunlit, false)
})

test("the vector path agrees with destination + lookAngles to rounding", () => {
  const obs = { lat: 51.47, lon: -0.45, altM: 30 }
  const frame = S.frameOf(obs.lat, obs.lon, obs.altM)
  for (const [lat, lon, trk, gs, alt] of [[52.1, 0.8, 250, 430, 11000], [50.9, -2.5, 90, 150, 2500], [51.4, -0.5, 10, 480, 9000], [53, 3, 200, 0, 8000]]) {
    const m = S.motionOf(lat, lon, alt, trk, gs)
    for (const t of [0, 45, 300, 600]) {
      const v = S.viewAt(frame, m, t, {})
      const p = gs > 0 ? S.destination(lat, lon, trk, gs * 1.852 / 3600 * t) : { lat, lon }
      const ref = S.lookAngles(obs.lat, obs.lon, obs.altM, p.lat, p.lon, alt)
      near(v.el, ref.el, 1e-6)
      near(((v.az - ref.az + 540) % 360) - 180, 0, 1e-6)
      const d = {}
      S.viewAt(frame, m, t, d)
      near(d.groundKm, ref.groundKm, 1e-6)
      near(d.rangeKm, ref.rangeKm, 1e-6)
    }
  }
})

test("low aircraft (arriving or departing) are not listed as beyond the horizon", () => {
  const p = { lat: 0, lon: 400 / KM_PER_DEG }
  const m = metaOf([{ lat: p.lat, lon: p.lon, gs: 0, alt: 300 }, { lat: p.lat, lon: p.lon + 0.1, gs: 0, alt: 5000 }])
  const r = S.scan(m, OBS, 0)
  assert.equal(r.counts.beyond, 1)
  assert.equal(r.beyond[0].i, 1)
  assert.equal(S.scan(m, OBS, 0, { rimMinAltFt: 0 }).counts.beyond, 2)
})

test("garbage in the columns does not throw", () => {
  const m = metaOf([{ lat: 1, lon: 1 }, { lat: 0.1, lon: 0.1, gs: null, trk: null }, { lat: NaN, lon: 3 }, { lat: 0.2, lon: 0.1, alt: "x" }])
  m.n = 4
  const r = S.scan(m, OBS, 0)
  assert.ok(r.sky.length <= 4)
  assert.doesNotThrow(() => S.scan(null, OBS, 0))
  assert.doesNotThrow(() => S.scan(m, { lat: NaN, lon: 0 }, 0))
  assert.equal(S.scan(m, { lat: NaN, lon: 0 }, 0).sky.length, 0)
})

test("a 9,400-aircraft world scan takes a few milliseconds", () => {
  let seed = 7
  const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296
  const rows = []
  for (let i = 0; i < 9400; i++) rows.push({ lat: rnd() * 160 - 80, lon: rnd() * 360 - 180, gs: 300 + rnd() * 250, trk: rnd() * 360, t: rnd() * 60 })
  // plus a London-like cluster
  for (let i = 0; i < 300; i++) rows.push({ lat: 51.5 + rnd() * 6 - 3, lon: rnd() * 8 - 4, gs: 300 + rnd() * 250, trk: rnd() * 360, t: rnd() * 60 })
  const m = metaOf(rows)
  const run = () => S.scan(m, { lat: 51.47, lon: -0.45, altM: 0 }, 70, { sun: S.sunSubpoint(new Date()) })
  run()                                                  // warm-up: QML's JIT is warm after the first panel update
  const t0 = performance.now()
  const r = run()
  const ms = performance.now() - t0
  console.log(`     ${r.counts.sky} in sight, ${r.counts.incoming} incoming, ${r.counts.beyond} beyond, ${ms.toFixed(1)} ms`)
  assert.ok(ms < 60, `${ms} ms`)
})

if (failures > 0) {
  console.log(`\n${failures} test(s) failed`)
  process.exit(1)
}
console.log("\nall sky tests passed")
