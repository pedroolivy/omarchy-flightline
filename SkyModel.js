.pragma library

// Sky geometry for the "Look up" lens: where an aircraft is on the dome above
// the observer (azimuth, elevation), the horizon, the sun, the Moon and the
// bright planets, and a scan that turns one parsed meta.json into everything
// the lens draws.
// Nothing here touches QML objects, so the whole file is exercised by
// tests/sky.test.mjs under plain Node.

var EARTH_RADIUS_KM = 6371.0088       // same sphere as Model.js and the shaders
var KT_KMH = 1.852
var FT_M = 0.3048
var DEG = Math.PI / 180

var MAX_AGE_S = 90                    // aircraft.vert: extrapolation stops, fades from 70 %
var LOOKAHEAD_S = 600
var PATH_STEP_S = 60
var RIM_MAX_KM = 1000
var RIM_MIN_ALT_FT = 1000             // lower than this is arriving or departing, hidden by buildings
var RIM_BINS = 72                     // 5° each

// ---------------------------------------------------------------- numbers

function finite(value) {
  return typeof value === "number" && isFinite(value)
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

function normalizeAngle(deg) {
  return ((deg % 360) + 360) % 360
}

// -------------------------------------------------------------- geometry

// Point `distanceKm` along the great circle that leaves (lat, lon) on `bearing`.
function destination(lat, lon, bearing, distanceKm) {
  var d = distanceKm / EARTH_RADIUS_KM
  var b = bearing * DEG
  var p1 = lat * DEG
  var sinP2 = Math.sin(p1) * Math.cos(d) + Math.cos(p1) * Math.sin(d) * Math.cos(b)
  var p2 = Math.asin(clamp(sinP2, -1, 1))
  var l2 = lon * DEG + Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(p1), Math.cos(d) - Math.sin(p1) * sinP2)
  var lon2 = ((l2 / DEG + 540) % 360 + 360) % 360 - 180
  return { lat: p2 / DEG, lon: lon2 }
}

// Where `target` stands in the sky of the observer, on a spherical Earth:
// azimuth (° clockwise from north), elevation (° above the horizon, negative
// below it), ground distance along the surface and straight-line range.
// Altitudes are metres above the sphere. The aircraft sinks below the
// horizon by its own height as well as by the curvature, so 11 km up it is
// 47.7° high at 10 km and gone beyond about 374 km.
function lookAngles(obsLat, obsLon, obsAltM, lat, lon, altM) {
  var p1 = obsLat * DEG, p2 = lat * DEG
  var dl = (lon - obsLon) * DEG
  var sdp = Math.sin((p2 - p1) / 2), sdl = Math.sin(dl / 2)
  var a = sdp * sdp + Math.cos(p1) * Math.cos(p2) * sdl * sdl
  var theta = 2 * Math.asin(Math.min(1, Math.sqrt(a)))
  var az = normalizeAngle(Math.atan2(Math.sin(dl) * Math.cos(p2),
    Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl)) / DEG)
  var r1 = EARTH_RADIUS_KM + obsAltM / 1000
  var r2 = EARTH_RADIUS_KM + altM / 1000
  var x = r2 * Math.sin(theta)                       // along the ground, in the observer's frame
  var z = r2 * Math.cos(theta) - r1                  // up
  return {
    az: az,
    el: Math.atan2(z, x) / DEG,
    groundKm: EARTH_RADIUS_KM * theta,
    rangeKm: Math.sqrt(x * x + z * z)
  }
}

// How far the horizon is from an observer at `obsAltM`, for something at
// `altM`: the ground distance where the elevation is exactly zero.
function horizonDistanceKm(altM, obsAltM) {
  var r = EARTH_RADIUS_KM
  return r * (Math.acos(r / (r + altM / 1000)) + Math.acos(r / (r + (obsAltM || 0) / 1000)))
}

// Horizon dip at altitude `altM`, in degrees: the sun must sink this far
// below the ground horizon before it stops lighting something that high.
function dipDeg(altM) {
  return Math.acos(EARTH_RADIUS_KM / (EARTH_RADIUS_KM + altM / 1000)) / DEG
}

// -------------------------------------------------------------------- sun

// Subsolar point (the same low-precision formulas as Globe.sunFor, so the sky
// and the globe's night side agree; good to about 0.02°).
function sunSubpoint(date) {
  var d = date.getTime() / 86400000 - 10957.5                // days since J2000
  var g = (357.529 + 0.98560028 * d) * DEG
  var q = 280.459 + 0.98564736 * d
  var L = (q + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * DEG
  var e = (23.439 - 0.00000036 * d) * DEG
  var dec = Math.asin(Math.sin(e) * Math.sin(L))
  var ra = Math.atan2(Math.cos(e) * Math.sin(L), Math.cos(L))
  var gmst = (18.697374558 + 24.06570982441908 * d) % 24
  var lon = ((ra / DEG - gmst * 15) % 360 + 540) % 360 - 180
  return { lat: dec / DEG, lon: lon }
}

// Sun elevation and azimuth for an observer, from the subsolar point.
// No refraction: the disc is at 0° geometrically, about 0.8° above the
// visible sunrise.
function sunAltAz(sub, lat, lon) {
  var p = lat * DEG, dec = sub.lat * DEG
  var h = (lon - sub.lon) * DEG                              // hour angle, west positive
  var sinEl = Math.sin(p) * Math.sin(dec) + Math.cos(p) * Math.cos(dec) * Math.cos(h)
  var az = Math.atan2(Math.sin(h), Math.cos(h) * Math.sin(p) - Math.tan(dec) * Math.cos(p)) / DEG + 180
  return { el: Math.asin(clamp(sinEl, -1, 1)) / DEG, az: normalizeAngle(az) }
}

// After sunset something high up still catches the sun. `sunElAtPlane` is the
// sun's elevation over the aircraft's own ground position, `sunElAtObserver`
// the one over the observer (it only reads as "lit against a dark sky" once
// the observer's sun is down).
function isSunlit(sunElAtObserver, sunElAtPlane, altM) {
  return sunElAtObserver < 0 && sunElAtPlane > -dipDeg(altM)
}

// ------------------------------------------------------ sun, moon, planets
//
// Where the Sun, the Moon and the bright planets stand for the observer,
// after Jean Meeus, "Astronomical Algorithms" (2nd ed., 1998), with no data
// files: the Sun from ch. 25 (low accuracy, ~0.01°), the Moon from ch. 47
// (its full periodic tables, ~10″), its phase and bright limb from ch. 48,
// and the planets as Keplerian orbits (ch. 30, 33) on the JPL approximate
// elements (E. M. Standish, valid 1800–2050; worst for Saturn at ~0.2°).
// The sky-dome scale is ~3 px per degree, so all of this is far better than
// a pixel.

var AU_KM = 149597870.7
var J2000 = 2451545.0
var DELTA_T_S = 69                    // TT − UT in the 2020s (Meeus ch. 10); 1 s moves the Moon 0.5″

function sinD(x) { return Math.sin(x * DEG) }
function cosD(x) { return Math.cos(x * DEG) }

// Julian Day of a time in milliseconds since 1970 (UT).
function julianDay(ms) {
  return ms / 86400000 + 2440587.5
}

// Nutation in longitude and obliquity, and the mean obliquity of the ecliptic,
// degrees (ch. 22, the 0.5″ series).
function nutation(T) {
  var om = 125.04452 - 1934.136261 * T
  var L = 280.4665 + 36000.7698 * T, Lm = 218.3165 + 481267.8813 * T
  var dpsi = (-17.20 * sinD(om) - 1.32 * sinD(2 * L) - 0.23 * sinD(2 * Lm) + 0.21 * sinD(2 * om)) / 3600
  var deps = (9.20 * cosD(om) + 0.57 * cosD(2 * L) + 0.10 * cosD(2 * Lm) - 0.09 * cosD(2 * om)) / 3600
  var eps0 = 23.4392911 - (46.8150 * T + 0.00059 * T * T - 0.001813 * T * T * T) / 3600
  return { dpsi: dpsi, deps: deps, eps0: eps0, eps: eps0 + deps }
}

// Ecliptic (λ, β) to equatorial (α, δ), degrees, for obliquity `eps`.
function toEquatorial(lambda, beta, eps) {
  var ra = Math.atan2(sinD(lambda) * cosD(eps) - Math.tan(beta * DEG) * sinD(eps), cosD(lambda))
  var dec = Math.asin(clamp(sinD(beta) * cosD(eps) + cosD(beta) * sinD(eps) * sinD(lambda), -1, 1))
  return { ra: normalizeAngle(ra / DEG), dec: dec / DEG }
}

// The Sun at Julian Ephemeris Day `jde` (ch. 25): the geometric longitude
// (mean equinox of date) and distance that also place the Earth for the
// planets, and the apparent λ, α, δ.
function sunPosition(jde) {
  var T = (jde - J2000) / 36525
  var L0 = 280.46646 + 36000.76983 * T + 0.0003032 * T * T
  var M = 357.52911 + 35999.05029 * T - 0.0001537 * T * T
  var e = 0.016708634 - 0.000042037 * T - 0.0000001267 * T * T
  var C = (1.914602 - 0.004817 * T - 0.000014 * T * T) * sinD(M)
    + (0.019993 - 0.000101 * T) * sinD(2 * M) + 0.000289 * sinD(3 * M)
  var trueLon = L0 + C
  var R = 1.000001018 * (1 - e * e) / (1 + e * cosD(M + C))
  var om = 125.04 - 1934.136 * T
  var lambda = trueLon - 0.00569 - 0.00478 * sinD(om)          // nutation and aberration
  var eps = nutation(T).eps0 + 0.00256 * cosD(om)
  var q = toEquatorial(lambda, 0, eps)
  return { trueLon: normalizeAngle(trueLon), R: R, lambda: normalizeAngle(lambda), beta: 0,
           distKm: R * AU_KM, ra: q.ra, dec: q.dec }
}

// Periodic terms of the Moon, ch. 47: multiples of D, M, M′, F, then the
// coefficients of Σl (sine, 1e-6°) and Σr (cosine, metres) — table 47.A —
// and of Σb (sine, 1e-6°) — table 47.B.
var MOON_LR = [
  0, 0, 1, 0, 6288774, -20905355,  2, 0, -1, 0, 1274027, -3699111,  2, 0, 0, 0, 658314, -2955968,
  0, 0, 2, 0, 213618, -569925,  0, 1, 0, 0, -185116, 48888,  0, 0, 0, 2, -114332, -3149,
  2, 0, -2, 0, 58793, 246158,  2, -1, -1, 0, 57066, -152138,  2, 0, 1, 0, 53322, -170733,
  2, -1, 0, 0, 45758, -204586,  0, 1, -1, 0, -40923, -129620,  1, 0, 0, 0, -34720, 108743,
  0, 1, 1, 0, -30383, 104755,  2, 0, 0, -2, 15327, 10321,  0, 0, 1, 2, -12528, 0,
  0, 0, 1, -2, 10980, 79661,  4, 0, -1, 0, 10675, -34782,  0, 0, 3, 0, 10034, -23210,
  4, 0, -2, 0, 8548, -21636,  2, 1, -1, 0, -7888, 24208,  2, 1, 0, 0, -6766, 30824,
  1, 0, -1, 0, -5163, -8379,  1, 1, 0, 0, 4987, -16675,  2, -1, 1, 0, 4036, -12831,
  2, 0, 2, 0, 3994, -10445,  4, 0, 0, 0, 3861, -11650,  2, 0, -3, 0, 3665, 14403,
  0, 1, -2, 0, -2689, -7003,  2, 0, -1, 2, -2602, 0,  2, -1, -2, 0, 2390, 10056,
  1, 0, 1, 0, -2348, 6322,  2, -2, 0, 0, 2236, -9884,  0, 1, 2, 0, -2120, 5751,
  0, 2, 0, 0, -2069, 0,  2, -2, -1, 0, 2048, -4950,  2, 0, 1, -2, -1773, 4130,
  2, 0, 0, 2, -1595, 0,  4, -1, -1, 0, 1215, -3958,  0, 0, 2, 2, -1110, 0,
  3, 0, -1, 0, -892, 3258,  2, 1, 1, 0, -810, 2616,  4, -1, -2, 0, 759, -1897,
  0, 2, -1, 0, -713, -2117,  2, 2, -1, 0, -700, 2354,  2, 1, -2, 0, 691, 0,
  2, -1, 0, -2, 596, 0,  4, 0, 1, 0, 549, -1423,  0, 0, 4, 0, 537, -1117,
  4, -1, 0, 0, 520, -1571,  1, 0, -2, 0, -487, -1739,  2, 1, 0, -2, -399, 0,
  0, 0, 2, -2, -381, -4421,  1, 1, 1, 0, 351, 0,  3, 0, -2, 0, -340, 0,
  4, 0, -3, 0, 330, 0,  2, -1, 2, 0, 327, 0,  0, 2, 1, 0, -323, 1165,
  1, 1, -1, 0, 299, 0,  2, 0, 3, 0, 294, 0,  2, 0, -1, -2, 0, 8752
]
var MOON_B = [
  0, 0, 0, 1, 5128122,  0, 0, 1, 1, 280602,  0, 0, 1, -1, 277693,  2, 0, 0, -1, 173237,
  2, 0, -1, 1, 55413,  2, 0, -1, -1, 46271,  2, 0, 0, 1, 32573,  0, 0, 2, 1, 17198,
  2, 0, 1, -1, 9266,  0, 0, 2, -1, 8822,  2, -1, 0, -1, 8216,  2, 0, -2, -1, 4324,
  2, 0, 1, 1, 4200,  2, 1, 0, -1, -3359,  2, -1, -1, 1, 2463,  2, -1, 0, 1, 2211,
  2, -1, -1, -1, 2065,  0, 1, -1, -1, -1870,  4, 0, -1, -1, 1828,  0, 1, 0, 1, -1794,
  0, 0, 0, 3, -1749,  0, 1, -1, 1, -1565,  1, 0, 0, 1, -1491,  0, 1, 1, 1, -1475,
  0, 1, 1, -1, -1410,  0, 1, 0, -1, -1344,  1, 0, 0, -1, -1335,  0, 0, 3, 1, 1107,
  4, 0, 0, -1, 1021,  4, 0, -1, 1, 833,  0, 0, 1, -3, 777,  4, 0, -2, 1, 671,
  2, 0, 0, -3, 607,  2, 0, 2, -1, 596,  2, -1, 1, -1, 491,  2, 0, -2, 1, -451,
  0, 0, 3, -1, 439,  2, 0, 2, 1, 422,  2, 0, -3, -1, 421,  2, 1, -1, 1, -366,
  2, 1, 0, 1, -351,  4, 0, 0, 1, 331,  2, -1, 1, 1, 315,  2, -2, 0, -1, 302,
  0, 0, 1, 3, -283,  2, 1, 1, -1, -229,  1, 1, 0, -1, 223,  1, 1, 0, 1, 223,
  0, 1, -2, -1, -220,  2, 1, -1, -1, -220,  1, 0, 1, 1, -185,  2, -1, -2, -1, 181,
  0, 1, 2, 1, -177,  4, 0, -2, -1, 176,  4, -1, -1, -1, 166,  1, 0, 1, -1, -164,
  4, 0, 1, -1, 132,  1, 0, -1, -1, -119,  4, -1, 0, -1, 115,  2, -2, 0, 1, 107
]

// The Moon at `jde` (ch. 47): geocentric λ, β (the apparent λ includes
// nutation), distance in km, apparent α and δ.
function moonPosition(jde) {
  var T = (jde - J2000) / 36525
  var T2 = T * T, T3 = T2 * T, T4 = T3 * T
  var Lp = 218.3164477 + 481267.88123421 * T - 0.0015786 * T2 + T3 / 538841 - T4 / 65194000
  var D = 297.8501921 + 445267.1114034 * T - 0.0018819 * T2 + T3 / 545868 - T4 / 113065000
  var M = 357.5291092 + 35999.0502909 * T - 0.0001536 * T2 + T3 / 24490000
  var Mp = 134.9633964 + 477198.8675055 * T + 0.0087414 * T2 + T3 / 69699 - T4 / 14712000
  var F = 93.2720950 + 483202.0175233 * T - 0.0036539 * T2 - T3 / 3526000 + T4 / 863310000
  var A1 = 119.75 + 131.849 * T, A2 = 53.09 + 479264.290 * T, A3 = 313.45 + 481266.484 * T
  var E = 1 - 0.002516 * T - 0.0000074 * T2
  // Terms in M are scaled by E once per multiple: the Earth's orbit grows rounder.
  var sl = 0, sr = 0, sb = 0, k, arg, f
  for (k = 0; k < MOON_LR.length; k += 6) {
    arg = MOON_LR[k] * D + MOON_LR[k + 1] * M + MOON_LR[k + 2] * Mp + MOON_LR[k + 3] * F
    f = MOON_LR[k + 1] === 0 ? 1 : (Math.abs(MOON_LR[k + 1]) === 1 ? E : E * E)
    sl += f * MOON_LR[k + 4] * sinD(arg)
    sr += f * MOON_LR[k + 5] * cosD(arg)
  }
  for (k = 0; k < MOON_B.length; k += 5) {
    arg = MOON_B[k] * D + MOON_B[k + 1] * M + MOON_B[k + 2] * Mp + MOON_B[k + 3] * F
    f = MOON_B[k + 1] === 0 ? 1 : (Math.abs(MOON_B[k + 1]) === 1 ? E : E * E)
    sb += f * MOON_B[k + 4] * sinD(arg)
  }
  sl += 3958 * sinD(A1) + 1962 * sinD(Lp - F) + 318 * sinD(A2)
  sb += -2235 * sinD(Lp) + 382 * sinD(A3) + 175 * sinD(A1 - F) + 175 * sinD(A1 + F)
    + 127 * sinD(Lp - Mp) - 115 * sinD(Lp + Mp)
  var nu = nutation(T)
  var lambda = normalizeAngle(Lp + sl / 1e6)
  var beta = sb / 1e6
  var q = toEquatorial(lambda + nu.dpsi, beta, nu.eps)
  return { lambda: lambda, apparentLambda: normalizeAngle(lambda + nu.dpsi), beta: beta,
           distKm: 385000.56 + sr / 1000, ra: q.ra, dec: q.dec }
}

// Phase of the Moon (ch. 48) from the apparent Sun and Moon above:
// phaseAngle i (0 full, 180 new), the illuminated fraction k, and the position
// angle χ of the bright limb's midpoint, from celestial north through east.
function moonPhase(sun, moon) {
  var cpsi = cosD(moon.beta) * cosD(moon.apparentLambda - sun.lambda)
  var psi = Math.acos(clamp(cpsi, -1, 1))
  var i = Math.atan2(sun.distKm * Math.sin(psi), moon.distKm - sun.distKm * cpsi) / DEG
  var da = (sun.ra - moon.ra) * DEG
  var chi = Math.atan2(cosD(sun.dec) * Math.sin(da),
    sinD(sun.dec) * cosD(moon.dec) - cosD(sun.dec) * sinD(moon.dec) * Math.cos(da)) / DEG
  return { phaseAngle: i, illuminated: (1 + cosD(i)) / 2, elongation: psi / DEG, brightLimb: normalizeAngle(chi) }
}

// JPL approximate elements (Standish, table 1, J2000 ecliptic and equinox):
// a (AU), e, I, L, long. of perihelion ϖ, node Ω (°), each value then its rate
// per Julian century. The Earth comes from the Sun of ch. 25 instead.
var PLANETS = {
  mercury: [0.38709927, 0.00000037, 0.20563593, 0.00001906, 7.00497902, -0.00594749,
            252.25032350, 149472.67411175, 77.45779628, 0.16047689, 48.33076593, -0.12534081],
  venus:   [0.72333566, 0.00000390, 0.00677672, -0.00004107, 3.39467605, -0.00078890,
            181.97909950, 58517.81538729, 131.60246718, 0.00268329, 76.67984255, -0.27769418],
  mars:    [1.52371034, 0.00001847, 0.09339410, 0.00007882, 1.84969142, -0.00813131,
            -4.55343205, 19140.30268499, -23.94362959, 0.44441088, 49.55953891, -0.29257343],
  jupiter: [5.20288700, -0.00011607, 0.04838624, -0.00013253, 1.30439695, -0.00183714,
            34.39644051, 3034.74612775, 14.72847983, 0.21252668, 100.47390909, 0.20469106],
  saturn:  [9.53667594, -0.00125060, 0.05386179, -0.00050991, 2.48599187, 0.00193609,
            49.95424423, 1222.49362201, 92.59887831, -0.41897216, 113.66242448, -0.28867794]
}
var PLANET_NAMES = ["mercury", "venus", "mars", "jupiter", "saturn"]

// Visual magnitude from the distances (AU) and the phase angle (ch. 41).
// Saturn leaves out its rings (they add up to −0.5 when wide open).
function planetMagnitude(name, r, delta, i) {
  var d = 5 * Math.log(r * delta) / Math.LN10
  if (name === "mercury") return -0.42 + d + 0.0380 * i - 0.000273 * i * i + 0.000002 * i * i * i
  if (name === "venus") return -4.40 + d + 0.0009 * i + 0.000239 * i * i - 0.00000065 * i * i * i
  if (name === "mars") return -1.52 + d + 0.016 * i
  if (name === "jupiter") return -9.40 + d + 0.005 * i
  return -8.88 + d
}

// Heliocentric ecliptic position of a planet at `jde`, rectangular, in AU,
// referred to the ecliptic and mean equinox of date (precession in longitude
// added to the J2000 elements; the ecliptic itself moves < 0.01° in decades).
function heliocentric(el, jde) {
  var T = (jde - J2000) / 36525
  var a = el[0] + el[1] * T, e = el[2] + el[3] * T, I = el[4] + el[5] * T
  var L = el[6] + el[7] * T, peri = el[8] + el[9] * T, node = el[10] + el[11] * T
  var M = normalizeAngle(L - peri) * DEG
  var E = M + e * Math.sin(M)
  for (var k = 0; k < 6; k++) E -= (E - e * Math.sin(E) - M) / (1 - e * Math.cos(E))  // Kepler (ch. 30)
  var xp = a * (Math.cos(E) - e), yp = a * Math.sqrt(1 - e * e) * Math.sin(E)
  var w = (peri - node) * DEG, O = (node + (5029.0966 * T + 1.11113 * T * T) / 3600) * DEG, inc = I * DEG
  var cw = Math.cos(w), sw = Math.sin(w), cO = Math.cos(O), sO = Math.sin(O), ci = Math.cos(inc), si = Math.sin(inc)
  return {
    x: (cw * cO - sw * sO * ci) * xp + (-sw * cO - cw * sO * ci) * yp,
    y: (cw * sO + sw * cO * ci) * xp + (-sw * sO + cw * cO * ci) * yp,
    z: sw * si * xp + cw * si * yp
  }
}

// A planet seen from the Earth at `jde` (ch. 33): apparent α, δ, λ, β, the
// distances r (Sun) and Δ (Earth) in AU, its elongation from the Sun, phase
// angle and magnitude. Light time is taken out once; aberration (≤ 20″) is
// left in.
function planetPosition(name, jde, sun) {
  sun = sun || sunPosition(jde)
  var el = PLANETS[name]
  var ex = -sun.R * cosD(sun.trueLon), ey = -sun.R * sinD(sun.trueLon)   // the Earth, from the Sun
  var p = heliocentric(el, jde)
  var dx = p.x - ex, dy = p.y - ey, dz = p.z
  var delta = Math.sqrt(dx * dx + dy * dy + dz * dz)
  p = heliocentric(el, jde - 0.0057755183 * delta)
  dx = p.x - ex; dy = p.y - ey; dz = p.z
  delta = Math.sqrt(dx * dx + dy * dy + dz * dz)
  var r = Math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
  var nu = nutation((jde - J2000) / 36525)
  var lambda = normalizeAngle(Math.atan2(dy, dx) / DEG + nu.dpsi)
  var beta = Math.atan2(dz, Math.sqrt(dx * dx + dy * dy)) / DEG
  var q = toEquatorial(lambda, beta, nu.eps)
  var i = Math.acos(clamp((r * r + delta * delta - sun.R * sun.R) / (2 * r * delta), -1, 1)) / DEG
  var elong = Math.acos(clamp((sun.R * sun.R + delta * delta - r * r) / (2 * sun.R * delta), -1, 1)) / DEG
  return { name: name, ra: q.ra, dec: q.dec, lambda: lambda, beta: beta, r: r, delta: delta,
           distKm: delta * AU_KM, elongation: elong, phaseAngle: i, mag: planetMagnitude(name, r, delta, i) }
}

// Apparent sidereal time at Greenwich, degrees, for the Julian Day `jd` (UT)
// (ch. 12, plus the equation of the equinoxes).
function siderealDeg(jd) {
  var T = (jd - J2000) / 36525
  var nu = nutation(T)
  return normalizeAngle(280.46061837 + 360.98564736629 * (jd - J2000) + 0.000387933 * T * T
    - T * T * T / 38710000 + nu.dpsi * cosD(nu.eps))
}

// Atmospheric refraction, degrees, for a true altitude `h` (Sæmundsson,
// ch. 16): 0.5° at the horizon, 1′ at 45°. None below −1°, where nothing is
// drawn anyway.
function refractionDeg(h) {
  if (h < -1) return 0
  return (1.02 / Math.tan((h + 10.3 / (h + 5.11)) * DEG) + 0.0019279) / 60
}

// Topocentric azimuth (from north, clockwise) and altitude of a body at α, δ
// and `distKm` from the Earth's centre, for an observer on the sphere: the
// parallax (up to 1° for the Moon) is the observer's offset from the centre.
// `el` is the apparent altitude (refracted), `trueEl` the geometric one.
function horizontal(ra, dec, distKm, lst, lat, altM) {
  var H = (lst - ra) * DEG, p = lat * DEG, d = dec * DEG
  // the body in the observer's east, north, up axes, in km from the centre
  var e = -Math.cos(d) * Math.sin(H)
  var n = Math.cos(p) * Math.sin(d) - Math.sin(p) * Math.cos(d) * Math.cos(H)
  var u = Math.sin(p) * Math.sin(d) + Math.cos(p) * Math.cos(d) * Math.cos(H)
  var dist = finite(distKm) ? distKm : 1e12
  var up = u * dist - (EARTH_RADIUS_KM + (altM || 0) / 1000)
  var el = Math.atan2(up, dist * Math.sqrt(e * e + n * n)) / DEG
  return { az: normalizeAngle(Math.atan2(e, n) / DEG), el: el + refractionDeg(el), trueEl: el }
}

// One step of `stepDeg` along the great circle of the sky from (az1, el1)
// towards (az2, el2): which way on the dome the bright limb of the Moon faces.
function towards(az1, el1, az2, el2, stepDeg) {
  var a = [cosD(el1) * sinD(az1), cosD(el1) * cosD(az1), sinD(el1)]
  var b = [cosD(el2) * sinD(az2), cosD(el2) * cosD(az2), sinD(el2)]
  var dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
  var t = [b[0] - dot * a[0], b[1] - dot * a[1], b[2] - dot * a[2]]
  var len = Math.sqrt(t[0] * t[0] + t[1] * t[1] + t[2] * t[2]) || 1
  var c = cosD(stepDeg), s = sinD(stepDeg) / len
  var v = [a[0] * c + t[0] * s, a[1] * c + t[1] * s, a[2] * c + t[2] * s]
  return { az: normalizeAngle(Math.atan2(v[0], v[1]) / DEG), el: Math.asin(clamp(v[2], -1, 1)) / DEG }
}

// The light of the sky by the Sun's geometric altitude: day, then civil,
// nautical and astronomical twilight down to −18°, then night.
function twilightOf(sunEl) {
  if (sunEl >= -0.833) return "day"
  if (sunEl >= -6) return "civil"
  if (sunEl >= -12) return "nautical"
  if (sunEl >= -18) return "astronomical"
  return "night"
}

// How low the Sun must be before a body of magnitude `mag` shows: Venus
// (−4.4) as the Sun sets, Jupiter (−2.5) a few degrees later, a first-
// magnitude planet near the end of nautical twilight.
function sunLimitFor(mag) {
  return clamp(-2 - 1.5 * (mag + 4), -10, -1)
}

// Everything bright in the sky of an observer at `ms` (UT milliseconds):
//   sun      {az, el, trueEl, ra, dec, up}
//   moon     {az, el, up, phaseAngle, illuminated, elongation, brightLimb,
//             limb: {az, el} a step towards the Sun, waxing}
//   planets  [{name, az, el, mag, elongation, up, visible}], brightest first
//   twilight day | civil | nautical | astronomical | night, and `dusk`
//            (the Sun in the western half of the sky)
// `up` is the upper limb (planets: the centre) above the apparent horizon;
// a planet is `visible` when it is up, the Sun is low enough for its
// magnitude (sunLimitFor) and it stands clear of the Sun's glare (10° for
// Venus, 12° for the others, Mercury has to be 3° up as well).
function skyBodies(ms, lat, lon, altM, opts) {
  opts = opts || {}
  var dT = finite(opts.deltaTS) ? opts.deltaTS : DELTA_T_S
  var jd = julianDay(ms), jde = jd + dT / 86400
  var lst = siderealDeg(jd) + lon
  var sunEq = sunPosition(jde)
  var moonEq = moonPosition(jde)
  var sun = horizontal(sunEq.ra, sunEq.dec, sunEq.distKm, lst, lat, altM)
  sun.ra = sunEq.ra; sun.dec = sunEq.dec
  sun.up = sun.el > -0.27                                  // upper limb, 16′ semidiameter
  var moon = horizontal(moonEq.ra, moonEq.dec, moonEq.distKm, lst, lat, altM)
  var phase = moonPhase(sunEq, moonEq)
  moon.up = moon.el > -0.26
  moon.phaseAngle = phase.phaseAngle
  moon.illuminated = phase.illuminated
  moon.elongation = phase.elongation
  moon.brightLimb = phase.brightLimb
  moon.waxing = normalizeAngle(moonEq.apparentLambda - sunEq.lambda) < 180
  moon.limb = towards(moon.az, moon.el, sun.az, sun.el, 1)
  moon.distKm = moonEq.distKm
  var planets = []
  for (var k = 0; k < PLANET_NAMES.length; k++) {
    var pl = planetPosition(PLANET_NAMES[k], jde, sunEq)
    var h = horizontal(pl.ra, pl.dec, pl.distKm, lst, lat, altM)
    var name = PLANET_NAMES[k]
    var clear = pl.elongation >= (name === "venus" ? 10 : 12) && (name !== "mercury" || h.el >= 3)
    planets.push({
      name: name, az: h.az, el: h.el, mag: pl.mag, elongation: pl.elongation,
      up: h.el > 0, visible: h.el > 0 && clear && sun.trueEl <= sunLimitFor(pl.mag)
    })
  }
  planets.sort(function(a, b) { return a.mag - b.mag })
  return {
    sun: sun, moon: moon, planets: planets,
    twilight: twilightOf(sun.trueEl), dusk: sun.az >= 180
  }
}

// ------------------------------------------------------- dome projection

// Azimuthal equidistant: zenith in the centre, the horizon on the circle of
// `radius`. North is up; east is on the left unless `eastRight`, as on a
// star chart held overhead.
function domePoint(az, el, cx, cy, radius, eastRight) {
  var r = radius * (90 - clamp(el, -90, 90)) / 90
  var a = az * DEG
  return { x: cx + (eastRight ? 1 : -1) * r * Math.sin(a), y: cy - r * Math.cos(a) }
}

// ------------------------------------------------------------------ scan

// The observer's local axes (east, north, up) in Earth-centred coordinates.
// A scan looks at thousands of aircraft, so it works with vectors: after one
// set-up per aircraft, every point of its path costs two trig calls.
function frameOf(lat, lon, altM) {
  var sp = Math.sin(lat * DEG), cp = Math.cos(lat * DEG)
  var sl = Math.sin(lon * DEG), cl = Math.cos(lon * DEG)
  return {
    ex: -sl, ey: cl, ez: 0,
    nx: -sp * cl, ny: -sp * sl, nz: cp,
    ux: cp * cl, uy: cp * sl, uz: sp,
    r1: EARTH_RADIUS_KM + (altM || 0) / 1000
  }
}

// The motion of an aircraft at (lat, lon), `altM` high, flying straight and
// level on `trk` at `gs` knots: its position and tangent vectors (Earth-centred
// unit vectors), the angular speed and its radius.
function motionOf(lat, lon, altM, trk, gs) {
  var sp = Math.sin(lat * DEG), cp = Math.cos(lat * DEG)
  var sl = Math.sin(lon * DEG), cl = Math.cos(lon * DEG)
  var st = Math.sin(trk * DEG), ct = Math.cos(trk * DEG)
  return {
    px: cp * cl, py: cp * sl, pz: sp,
    // unit tangent along the track: north · cos(trk) + east · sin(trk)
    tx: -sp * cl * ct - sl * st, ty: -sp * sl * ct + cl * st, tz: cp * ct,
    rate: gs * KT_KMH / 3600 / EARTH_RADIUS_KM,
    r2: EARTH_RADIUS_KM + altM / 1000
  }
}

// Where that aircraft is `t` seconds from now as the observer's frame sees it:
// { t, az, el } (the same numbers as lookAngles along destination(), without
// the repeated trigonometry), and the ground distance and range of the same
// point when `detail` is passed an object to fill.
function viewAt(frame, m, t, detail) {
  var d = m.rate * t
  var c = Math.cos(d), s = Math.sin(d)
  var x = m.px * c + m.tx * s, y = m.py * c + m.ty * s, z = m.pz * c + m.tz * s
  var e = x * frame.ex + y * frame.ey + z * frame.ez
  var n = x * frame.nx + y * frame.ny + z * frame.nz
  var u = x * frame.ux + y * frame.uy + z * frame.uz
  var h = Math.sqrt(e * e + n * n)
  var up = m.r2 * u - frame.r1
  var out = m.r2 * h
  if (detail) {
    detail.groundKm = EARTH_RADIUS_KM * Math.atan2(h, u)
    detail.rangeKm = Math.sqrt(up * up + out * out)
    detail.ux = x; detail.uy = y; detail.uz = z
  }
  return { t: t, az: normalizeAngle(Math.atan2(e, n) / DEG), el: Math.atan2(up, out) / DEG }
}

// Rough angle between two directions of the sky, in degrees (flat metric with
// the azimuth scaled by the mean elevation; enough to decide where to split).
function skySeparationDeg(az1, el1, az2, el2) {
  var da = Math.abs(az2 - az1)
  if (da > 180) da = 360 - da
  var de = el2 - el1
  var k = Math.cos((el1 + el2) / 2 * DEG)
  return Math.sqrt(de * de + da * da * k * k)
}

// Samples between two times, splitting a step wherever the aircraft crosses
// more than ~6° of sky (a pass near the zenith swings fast in azimuth).
function refine(at, a, b, depth, out) {
  if (depth > 0 && skySeparationDeg(a.az, a.el, b.az, b.el) > 6) {
    var mid = at((a.t + b.t) / 2)
    refine(at, a, mid, depth - 1, out)
    refine(at, mid, b, depth - 1, out)
    return
  }
  out.push(b)
}

// Time between a and b, where one is above `minEl` and the other is not,
// found by bisection; returns the sample on the sky side of the crossing.
function crossing(at, a, b, minEl) {
  var lo = a, hi = b
  for (var k = 0; k < 7; k++) {
    var mid = at((lo.t + hi.t) / 2)
    if ((mid.el > minEl) === (lo.el > minEl)) lo = mid
    else hi = mid
  }
  return (hi.el > minEl) ? hi : lo
}

// The first stretch of the next `lookaheadS` seconds that `at(t)` spends above
// `minEl`: [{t, az, el}] with the crossings of the horizon pinned down, or []
// when it never rises. A start that is already above the horizon begins at
// t = 0.
function skyPath(at, lookaheadS, stepS, minEl) {
  var samples = [at(0)]
  for (var t = stepS; t < lookaheadS + stepS / 2; t += stepS)
    refine(at, samples[samples.length - 1], at(Math.min(t, lookaheadS)), 4, samples)

  var run = []
  for (var i = 0; i < samples.length; i++) {
    var s = samples[i]
    if (s.el > minEl) {
      if (run.length === 0 && i > 0) run.push(crossing(at, samples[i - 1], s, minEl))
      run.push(s)
    } else if (run.length > 0) {
      run.push(crossing(at, samples[i - 1], s, minEl))
      break
    }
  }
  return run
}

function nameOf(meta, i) {
  return meta.cs[i] || meta.rg[i] || String(meta.hex[i] || "").toUpperCase()
}

// Everything the lens shows, from one parsed meta.json (columns index-aligned
// with traffic.ppm, so `i` is the same index the globe selects).
//
//   obs     {lat, lon, altM}   the observer
//   nowS    seconds since meta.epochMs (the shader's `time`)
//   opts    maxAgeS, lookaheadS, stepS, minEl, rimMaxKm, rimMinAltFt,
//           beyondCount, passMinEl, sun (a subsolar point, for the sunlit flag)
//
// Returns { sky, incoming, beyond, rim, passes, counts }:
//   sky       aircraft above the horizon now, highest first, each with
//             {i, name, az, el, groundKm, rangeKm, altM, alt (ft), gs, trk,
//              alpha, emergency, sunlit, path: [{t, az, el}], tMaxS, maxEl,
//              maxAz, fromAz, toAz}
//   incoming  aircraft below the horizon that rise within the look-ahead
//             (same fields; `path` starts on the horizon)
//   beyond    the nearest few aircraft below the horizon: {i, name, km, brg, alt}
//   rim       per 5° of bearing, the nearest aircraft below the horizon
//             ({km, i}) or null
//   passes    sky + incoming whose highest point reaches passMinEl, soonest
//             first (the same rows)
//   counts    {sky, incoming, beyond, stale, unknownAlt, ground}
//
// Positions are dead-reckoned exactly like the GPU does (aircraft.vert): the
// last report moved along its track by gs times the age, capped at maxAgeS,
// and aircraft older than that are left out. Paths are level flight from
// there. Only aircraft inside a box around the observer are looked at, so a
// whole-world meta costs about the same as a regional one.
function scan(meta, obs, nowS, opts) {
  opts = opts || {}
  var maxAge = finite(opts.maxAgeS) ? opts.maxAgeS : MAX_AGE_S
  var lookahead = finite(opts.lookaheadS) ? opts.lookaheadS : LOOKAHEAD_S
  var step = finite(opts.stepS) ? opts.stepS : PATH_STEP_S
  var minEl = finite(opts.minEl) ? opts.minEl : 0
  var rimMax = finite(opts.rimMaxKm) ? opts.rimMaxKm : RIM_MAX_KM
  var rimMinAlt = finite(opts.rimMinAltFt) ? opts.rimMinAltFt : RIM_MIN_ALT_FT
  var beyondLimit = finite(opts.beyondCount) ? opts.beyondCount : 3
  var passMinEl = finite(opts.passMinEl) ? opts.passMinEl : 10
  var sun = opts.sun || null
  var obsAltM = obs && finite(obs.altM) ? obs.altM : 0

  var out = {
    sky: [], incoming: [], beyond: [], passes: [],
    rim: new Array(RIM_BINS),
    counts: { sky: 0, incoming: 0, beyond: 0, stale: 0, unknownAlt: 0, ground: 0 }
  }
  for (var b = 0; b < RIM_BINS; b++) out.rim[b] = null
  if (!meta || !obs || !finite(obs.lat) || !finite(obs.lon)) return out

  var frame = frameOf(obs.lat, obs.lon, obsAltM)
  var obsSunEl = sun ? sunAltAz(sun, obs.lat, obs.lon).el : 90
  var sunVec = sun ? [Math.cos(sun.lat * DEG) * Math.cos(sun.lon * DEG), Math.cos(sun.lat * DEG) * Math.sin(sun.lon * DEG), Math.sin(sun.lat * DEG)] : null
  // The box that can matter: the rim, plus what an aircraft covers flying in
  // for the look-ahead at up to ~1,100 km/h. Longitude shrinks with latitude.
  var gapKm = rimMax + 1100 * lookahead / 3600
  var latGap = gapKm / 111.19
  var lonScale = 111.19 * Math.cos(Math.min(89.9, Math.abs(obs.lat) + latGap) * DEG)
  var n = Math.min(meta.n | 0, meta.lat.length)
  var detail = {}

  for (var i = 0; i < n; i++) {
    var lat0 = meta.lat[i], lon0 = meta.lon[i]
    if (!finite(lat0) || !finite(lon0) || Math.abs(lat0 - obs.lat) > latGap) continue
    var dlon = Math.abs(lon0 - obs.lon)
    if ((dlon > 180 ? 360 - dlon : dlon) * lonScale > gapKm) continue

    var flags = meta.flags[i] | 0
    var alt = meta.alt[i]
    if (alt === -1 || (flags & 1) !== 0) { out.counts.ground++; continue }
    if (!finite(alt)) { out.counts.unknownAlt++; continue }
    var age = nowS - (finite(meta.t[i]) ? meta.t[i] : 0)
    if (age >= maxAge) { out.counts.stale++; continue }

    var trkKnown = finite(meta.trk[i])
    var gs = finite(meta.gs[i]) && trkKnown && meta.gs[i] > 0 ? meta.gs[i] : 0
    var trk = trkKnown ? meta.trk[i] : 0
    var altM = alt * FT_M
    // Where it is now: the report moved on by its age (capped), then onwards.
    var motion = motionOf(lat0, lon0, altM, trk, gs)
    var t0 = clamp(age, 0, maxAge)
    var la = viewAt(frame, motion, t0, detail)
    var up = la.el > minEl
    if (!up) {
      if (detail.groundKm > rimMax) continue
      var listed = alt >= rimMinAlt
      if (listed) out.counts.beyond++
      var bin = Math.floor(la.az / 360 * RIM_BINS) % RIM_BINS
      if (listed && (!out.rim[bin] || detail.groundKm < out.rim[bin].km)) out.rim[bin] = { km: detail.groundKm, i: i }
      if (listed && (out.beyond.length < beyondLimit || detail.groundKm < out.beyond[out.beyond.length - 1].km)) {
        out.beyond.push({ i: i, name: nameOf(meta, i), km: detail.groundKm, brg: la.az, alt: alt })
        out.beyond.sort(function(a, b) { return a.km - b.km })
        if (out.beyond.length > beyondLimit) out.beyond.pop()
      }
      // Can it rise within the look-ahead? Only if it could close the gap.
      if (gs === 0 || detail.groundKm > horizonDistanceKm(altM, obsAltM) + gs * KT_KMH / 3600 * lookahead + 5) continue
    }

    // The path starts from where it is now.
    var at = function(t) { var s = viewAt(frame, motion, t0 + t); s.t = t; return s }
    var path = gs > 0 ? skyPath(at, lookahead, step, minEl) : (up ? [{ t: 0, az: la.az, el: la.el }] : [])
    if (path.length === 0) continue

    var planeSunEl = 90
    if (sun) {
      planeSunEl = Math.asin(clamp(detail.ux * sunVec[0] + detail.uy * sunVec[1] + detail.uz * sunVec[2], -1, 1)) / DEG
    }
    // Highest point of the stretch above the horizon.
    var top = path[0]
    for (var k = 1; k < path.length; k++) if (path[k].el > top.el) top = path[k]
    var row = {
      i: i, name: nameOf(meta, i),
      az: la.az, el: la.el, groundKm: detail.groundKm, rangeKm: detail.rangeKm,
      altM: altM, alt: alt, gs: gs > 0 ? gs : null, trk: trkKnown ? trk : null,
      alpha: 1 - clamp((age - 0.7 * maxAge) / (0.3 * maxAge), 0, 1),
      emergency: (flags & 2) !== 0,
      sunlit: sun ? isSunlit(obsSunEl, planeSunEl, altM) : false,
      path: path,
      tMaxS: top.t, maxEl: top.el, maxAz: top.az,
      fromAz: path[0].az, toAz: path[path.length - 1].az
    }
    if (up) out.sky.push(row)
    else out.incoming.push(row)
  }

  out.sky.sort(function(a, b) { return b.el - a.el })
  out.counts.sky = out.sky.length
  out.counts.incoming = out.incoming.length
  out.passes = out.sky.concat(out.incoming)
    .filter(function(r) { return r.maxEl >= passMinEl })
    .sort(function(a, b) { return a.tMaxS - b.tMaxS || b.maxEl - a.maxEl })
    .slice(0, 12)
  return out
}
