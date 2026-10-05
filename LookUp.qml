import QtQuick
import "Model.js" as Model
import "SkyModel.js" as Sky

// The "Look up" lens: a sky dome of what is above home right now.
//
// The zenith is the centre and the horizon the big circle; rings mark 30° and
// 60° elevation. Every aircraft in line of sight (elevation > 0, using its
// altitude and the curve of the Earth) sits at its azimuth and elevation with
// its path across the sky for the next ten minutes, and aircraft that will
// rise inside that time show their path from the horizon. Traffic below the
// horizon is listed on the rim band: one tick per 5° of bearing, longer when
// closer, with the nearest few named by bearing and distance.
//
// Behind the traffic is the sky itself: its light follows the Sun's altitude
// (day, civil, nautical and astronomical twilight, night), with the glow of
// twilight over the set Sun; the Sun, the Moon in its true phase with the lit
// limb towards the Sun, and the bright planets once the sky is dark enough to
// show them (SkyModel.skyBodies). They stay quieter than the aircraft.
//
// Cost: nothing runs per frame. The dome is one Canvas that repaints only when
// the data (service.trafficRev), home, size, selection or hover change, plus
// every `tickMs` (10 s) while it is visible; the sky moves 0.04° in that time.
// The geometry and the astronomy are SkyModel.js.
//
// Imports no qs.*: colours and the font come in as properties.
Item {
  id: root

  property var service: null              // Service.qml (or a stand-in with meta(), trafficRev, epochMs)
  property var home: null                 // {lat, lon, ...}
  property string units: "metric"
  property color foreground: "#c0caf5"
  property color background: "#1a1b26"
  property color accent: "#7aa2f7"
  property color muted: "#565f89"
  property color urgent: "#f7768e"
  property string fontFamily: "monospace"
  property int fontPx: 12
  property int selectedIndex: -1          // meta index, like Aircraft.selectedIndex

  signal picked(int index)                // click on an aircraft; -1 when the click hits none

  // ---------------------------------------------------------------- tuning

  property int tickMs: 10000              // the only timer; ≥ 1 s
  property int labelCount: 6              // highest aircraft that get a name
  property int maxPaths: 60               // highest aircraft that draw their path
  property int maxRisingPaths: 6          // soonest to rise that draw theirs
  property real passMinEl: 10             // lowest peak elevation listed in `passes`
  property real observerAltM: 0
  property bool eastRight: false          // false: east on the left, as on a star chart held overhead
  property double fixedNowMs: 0           // 0 = wall clock; tests freeze it
  property bool active: visible
  property bool showBodies: true          // the Sun, the Moon and the planets, and the sky's light

  // ---------------------------------------------------------- sky colours
  // Derived from the five theme colours like GlobePalette (they can move
  // there as they are). A dark theme's night sky stays as dark as v2.0's
  // dome; daylight lifts it towards the accent, never so far that the
  // accent aircraft lose their contrast. A light theme works the other way,
  // like a printed sky chart: the day is the paper, the night a dimmer grey,
  // planets are ink dots, the Moon's lit side is paper on an inked disc and
  // the Sun is ☉.
  readonly property bool lightTheme: luminance(background) > 0.5
  property color skyNight: lightTheme ? mix(background, foreground, 0.15) : mix(background, accent, 0.025)
  property color skyNightHorizon: lightTheme ? mix(background, mix(foreground, accent, 0.4), 0.08) : mix(background, accent, 0.10)
  property color skyDay: lightTheme ? mix(background, accent, 0.10) : mix(background, accent, 0.13)
  property color skyDayHorizon: lightTheme ? mix(background, accent, 0.03) : mix(background, mix(accent, foreground, 0.3), 0.17)
  property color skyTwilight: mix(accent, urgent, 0.35)         // the glow over the set Sun
  property color bodyColor: foreground                          // planets; the Sun and the Moon's light on dark themes

  function luminance(c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
  function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }

  // ------------------------------------------------------------ read-outs

  // Last scan (see SkyModel.scan). The sidebar of the panel reads these.
  property var scan: null
  readonly property var passes: scan ? scan.passes : []          // next passes, soonest first
  readonly property var beyond: scan ? scan.beyond : []          // nearest below the horizon
  readonly property int skyCount: scan ? scan.counts.sky : 0
  readonly property int incomingCount: scan ? scan.counts.incoming : 0
  readonly property int beyondCount: scan ? scan.counts.beyond : 0
  property var sun: null                                         // {el, az} at home
  property var bodies: null                                      // SkyModel.skyBodies at home, or null
  readonly property var selectedRow: rowFor(selectedIndex)       // the scan row of selectedIndex, or null
  readonly property bool hasHome: !!home && Model.isValidLatLon(Number(home.lat), Number(home.lon))
  // Radius around home that the last answer really covers, km (NaN unknown).
  readonly property real coverageKm: {
    var q = service ? service.lastQuery : null
    if (!q || !hasHome) return NaN
    return q.radiusNm * Model.NM_KM - Model.distanceKm(q.lat, q.lon, Number(home.lat), Number(home.lon))
  }

  property int hoveredIndex: -1
  property int paintCount: 0              // paints and scans so far (tests check that an idle lens stays idle)
  property int scanCount: 0
  property real paintMs: 0                // how long the last paint took on the GUI thread

  function rowFor(index) {
    if (!scan || index < 0) return null
    for (var k = 0; k < 2; k++) {
      var rows = k === 0 ? scan.sky : scan.incoming
      for (var i = 0; i < rows.length; i++)
        if (rows[i].i === index) return rows[i]
    }
    return null
  }

  // Scan again now (the next event-loop turn; calls collapse into one).
  function refresh() {
    Qt.callLater(rebuild)
  }

  function now() {
    return fixedNowMs > 0 ? fixedNowMs : Date.now()
  }

  function rebuild() {
    if (!active) return
    scanCount++
    var nowMs = now()
    var meta = hasHome && service ? service.meta() : null
    var obs = hasHome ? { lat: Number(home.lat), lon: Number(home.lon), altM: observerAltM } : null
    var sub = Sky.sunSubpoint(new Date(nowMs))
    sun = obs ? Sky.sunAltAz(sub, obs.lat, obs.lon) : null
    bodies = obs && showBodies ? Sky.skyBodies(nowMs, obs.lat, obs.lon, obs.altM) : null
    if (meta && obs) {
      var epoch = Model.numberOr(meta.epochMs, service.epochMs)
      scan = Sky.scan(meta, obs, (nowMs - epoch) / 1000, { sun: sub, passMinEl: passMinEl })
    } else {
      scan = null
    }
    canvas.requestPaint()
  }

  onServiceChanged: refresh()
  onHomeChanged: refresh()
  onUnitsChanged: canvas.requestPaint()
  onActiveChanged: if (active) refresh()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
  onSelectedIndexChanged: canvas.requestPaint()
  onHoveredIndexChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onBackgroundChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  onMutedChanged: canvas.requestPaint()
  onUrgentChanged: canvas.requestPaint()
  onFontFamilyChanged: canvas.requestPaint()
  onFontPxChanged: canvas.requestPaint()
  onEastRightChanged: canvas.requestPaint()
  onShowBodiesChanged: refresh()
  onSkyNightChanged: canvas.requestPaint()
  onSkyNightHorizonChanged: canvas.requestPaint()
  onSkyDayChanged: canvas.requestPaint()
  onSkyDayHorizonChanged: canvas.requestPaint()
  onSkyTwilightChanged: canvas.requestPaint()
  onBodyColorChanged: canvas.requestPaint()
  Component.onCompleted: refresh()

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onTrafficRevChanged() { root.refresh() }
  }

  Timer {
    interval: Math.max(1000, root.tickMs)
    repeat: true
    running: root.active && root.width > 0
    onTriggered: root.rebuild()
  }

  // ----------------------------------------------------------------- input

  // Where each aircraft was drawn: [{i, x, y}], rebuilt by every paint.
  property var hits: []

  function hitAt(x, y, radius) {
    var best = -1, bestD = radius * radius
    for (var k = 0; k < hits.length; k++) {
      var dx = hits[k].x - x, dy = hits[k].y - y
      var d = dx * dx + dy * dy
      if (d <= bestD) { bestD = d; best = hits[k].i }
    }
    return best
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.hoveredIndex >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
    onPositionChanged: function(mouse) {
      var i = root.hitAt(mouse.x, mouse.y, 12)
      if (i !== root.hoveredIndex) root.hoveredIndex = i
    }
    onExited: root.hoveredIndex = -1
    onClicked: function(mouse) { root.picked(root.hitAt(mouse.x, mouse.y, 14)) }
  }

  // ------------------------------------------------------------------ paint

  function css(color, alpha) {
    return "rgba(" + Math.round(color.r * 255) + "," + Math.round(color.g * 255) + ","
      + Math.round(color.b * 255) + "," + (alpha === undefined ? color.a : alpha * color.a) + ")"
  }

  function fontSpec(bold, scale) {
    var family = /["',]/.test(fontFamily) ? fontFamily : "\"" + fontFamily + "\""
    return (bold ? "bold " : "") + Math.round(fontPx * (scale || 1)) + "px " + family
  }

  function signed(deg, digits) {
    var v = Math.abs(deg).toFixed(digits || 0)
    return (deg < 0 ? "−" : "") + v + "°"
  }

  // "GLO1492 48°" or, for the selected and hovered aircraft, with altitude and
  // distance as well.
  function labelFor(row, detailed) {
    var text = row.name + " " + Math.round(row.el) + "°"
    if (!detailed) return text
    return row.name + " · " + Model.formatAltitude({ altitudeFt: row.alt, onGround: false }, units)
      + " · " + Model.formatDistance(row.groundKm, units) + " " + Model.compassPoint(row.az)
      + " · " + Math.round(row.el) + "° up" + (row.sunlit ? " · sunlit" : "")
  }

  function incomingLabel(row) {
    var minutes = Math.max(1, Math.round(row.path[0].t / 60))
    return row.name + " in " + minutes + " min"
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    renderTarget: Canvas.Image
    renderStrategy: Canvas.Cooperative
    onPaint: {
      root.paintCount++
      var t0 = Date.now()
      root.paintDome(getContext("2d"), width, height)
      root.paintMs = Date.now() - t0
    }
  }

  function paintDome(ctx, w, h) {
    ctx.reset()
    ctx.clearRect(0, 0, w, h)
    var px = fontPx
    var outer = Math.min(w, h) / 2 - px * 1.9                // room for N E S W
    var R = (outer - 5) / 1.1                                // horizon radius
    if (!(R > 40)) return
    var cx = w / 2, cy = h / 2
    var bandW = 0.1 * R
    var sgn = eastRight ? 1 : -1
    var DEG = Math.PI / 180

    function polar(az, r) {
      return { x: cx + sgn * r * Math.sin(az * DEG), y: cy - r * Math.cos(az * DEG) }
    }
    function dome(az, el) {
      return polar(az, R * (90 - Math.max(-90, Math.min(90, el))) / 90)
    }
    function stroke(color, alpha, width) {
      ctx.strokeStyle = css(color, alpha)
      ctx.lineWidth = width
    }
    function circle(r, color, alpha, width, dash) {
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, 2 * Math.PI)
      stroke(color, alpha, width)
      if (dash) ctx.setLineDash(dash)
      ctx.stroke()
      if (dash) ctx.setLineDash([])
    }
    function halo(text, x, y, align, color, alpha) {
      ctx.textAlign = align
      ctx.lineJoin = "round"
      ctx.lineWidth = 3
      ctx.strokeStyle = css(background, 0.85)
      ctx.strokeText(text, x, y)
      ctx.fillStyle = css(color, alpha === undefined ? 1 : alpha)
      ctx.fillText(text, x, y)
    }
    function smooth(e0, e1, v) {
      var t = Math.max(0, Math.min(1, (v - e0) / (e1 - e0)))
      return t * t * (3 - 2 * t)
    }
    function disc(x, y, r) {
      ctx.beginPath()
      ctx.arc(x, y, r, 0, 2 * Math.PI)
    }
    // Text boxes taken (N E S W, the rim, the Sun and the Moon, labels), so
    // labels never land on each other.
    var placed = []
    function inside(left, top, wBox, hBox) {
      var dx = Math.max(Math.abs(left - cx), Math.abs(left + wBox - cx))
      var dy = Math.max(Math.abs(top - cy), Math.abs(top + hBox - cy))
      return dx * dx + dy * dy <= (R - 3) * (R - 3)
    }
    // Writes `text` at the first free spot around (x, y), `gap` px clear of it.
    function place(text, x, y, bold, color, alpha, gap) {
      var g = gap || 9
      var wText = ctx.measureText(text).width
      var hText = px * 1.2
      var spots = [[g, 0, "left"], [-g, 0, "right"], [0, -(px + g - 5), "center"], [0, px + g - 4, "center"], [g, -(px + 1), "left"], [g, px + 1, "left"]]
      for (var o = 0; o < spots.length; o++) {
        var tx = x + spots[o][0], ty = y + spots[o][1], al = spots[o][2]
        var left = al === "left" ? tx : (al === "right" ? tx - wText : tx - wText / 2)
        if (!inside(left, ty - hText / 2, wText, hText)) continue
        var clash = false
        for (var pIdx = 0; pIdx < placed.length; pIdx++) {
          var pr = placed[pIdx]
          if (left < pr.x + pr.w && left + wText > pr.x && ty - hText / 2 < pr.y + pr.h && ty + hText / 2 > pr.y) { clash = true; break }
        }
        if (clash) continue
        placed.push({ x: left, y: ty - hText / 2, w: wText, h: hText })
        halo(text, tx, ty, al, color, alpha)
        return true
      }
      return false
    }

    // ---- the sky. Its light follows the Sun: night below -10°, day above
    // +3°, twilight between; then, inside the horizon, the glow of twilight
    // centred on the set Sun (beyond the horizon circle, so it sinks away as
    // the Sun does) or the brightness around the Sun by day.
    var sky = showBodies ? bodies : null
    var sunEl = sky ? sky.sun.trueEl : 0
    var day = sky ? smooth(-10, 3, sunEl) : 0
    var zenith = mix(skyNight, skyDay, day)
    var horizon = mix(skyNightHorizon, skyDayHorizon, day)
    if (sky) {
      var base = ctx.createRadialGradient(cx, cy, 0, cx, cy, R)
      base.addColorStop(0, css(zenith, 1))
      base.addColorStop(0.6, css(mix(zenith, horizon, 0.35), 1))
      base.addColorStop(1, css(horizon, 1))
      ctx.fillStyle = base
      disc(cx, cy, R)
      ctx.fill()
      ctx.save()
      disc(cx, cy, R)
      ctx.clip()
      var glow = smooth(-18, -4, sunEl) * (1 - smooth(1, 12, sunEl))
      if (glow > 0.01) {
        var gp = dome(sky.sun.az, sky.sun.el)
        var twi = ctx.createRadialGradient(gp.x, gp.y, 0, gp.x, gp.y, R * 0.95)
        twi.addColorStop(0, css(skyTwilight, 0.4 * glow))
        twi.addColorStop(0.45, css(skyTwilight, 0.13 * glow))
        twi.addColorStop(1, css(skyTwilight, 0))
        ctx.fillStyle = twi
        ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R)
      }
      if (sky.sun.up) {
        var sp0 = dome(sky.sun.az, Math.max(0, sky.sun.el))
        var aure = ctx.createRadialGradient(sp0.x, sp0.y, 0, sp0.x, sp0.y, R * 0.45)
        aure.addColorStop(0, css(lightTheme ? background : foreground, 0.10 * day))
        aure.addColorStop(1, css(lightTheme ? background : foreground, 0))
        ctx.fillStyle = aure
        ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R)
      }
      ctx.restore()
    } else {
      // no sky (no home, or bodies off): the v2.0 haze towards the horizon
      var haze = ctx.createRadialGradient(cx, cy, R * 0.15, cx, cy, R)
      haze.addColorStop(0, css(accent, 0))
      haze.addColorStop(1, css(accent, 0.1))
      ctx.fillStyle = haze
      disc(cx, cy, R)
      ctx.fill()
    }

    // ---- rings and axes
    ctx.textBaseline = "middle"
    ctx.font = fontSpec(false, 0.85)
    var elevations = [30, 60]
    for (var e = 0; e < elevations.length; e++) {
      var r = R * (90 - elevations[e]) / 90
      circle(r, muted, 0.55, 1, [2, 5])
      var tag = polar(45, r)
      halo(elevations[e] + "°", tag.x, tag.y, "center", muted)
    }
    stroke(muted, 0.3, 1)
    ctx.beginPath()
    for (var q = 0; q < 4; q++) {
      var a = polar(q * 90, R)
      ctx.moveTo(cx, cy)
      ctx.lineTo(a.x, a.y)
    }
    ctx.stroke()
    // zenith
    ctx.beginPath()
    ctx.moveTo(cx - 4, cy); ctx.lineTo(cx + 4, cy)
    ctx.moveTo(cx, cy - 4); ctx.lineTo(cx, cy + 4)
    stroke(muted, 0.7, 1)
    ctx.stroke()

    // ---- horizon with ticks every 10° (longer every 90°)
    circle(R, foreground, 0.6, 1.5)
    ctx.beginPath()
    for (var d = 0; d < 360; d += 10) {
      var len = d % 90 === 0 ? 9 : (d % 30 === 0 ? 6 : 3.5)
      var p0 = polar(d, R), p1 = polar(d, R - len)
      ctx.moveTo(p0.x, p0.y)
      ctx.lineTo(p1.x, p1.y)
    }
    stroke(foreground, 0.5, 1)
    ctx.stroke()

    // ---- rim band: the nearest aircraft below the horizon, per 5° of bearing
    var r0 = R + 5
    circle(r0, muted, 0.35, 1)
    circle(r0 + bandW, muted, 0.2, 1)
    var rimMax = 1000
    var named = {}
    if (scan) {
      for (var n = 0; n < scan.beyond.length; n++)
        named[Math.floor(scan.beyond[n].brg / 5) % 72] = true
      ctx.lineCap = "round"
      for (var b = 0; b < 72; b++) {
        var cell = scan.rim[b]
        if (!cell) continue
        var closeness = Math.max(0.12, Math.min(1, 1 - (cell.km - 300) / (rimMax - 300)))
        var az = (b + 0.5) * 5
        var t0 = polar(az, r0 + 2), t1 = polar(az, r0 + 2 + (bandW - 4) * closeness)
        ctx.beginPath()
        ctx.moveTo(t0.x, t0.y)
        ctx.lineTo(t1.x, t1.y)
        if (named[b]) stroke(foreground, 0.9, 3.5)
        else stroke(accent, 0.3 + 0.55 * closeness, 3.5)
        ctx.stroke()
      }
      ctx.lineCap = "butt"
    }

    // ---- N E S W
    ctx.font = fontSpec(true, 1)
    var names = ["N", "E", "S", "W"]
    for (var c = 0; c < 4; c++) {
      var cp = polar(c * 90, r0 + bandW + px * 0.95)
      placed.push({ x: cp.x - px, y: cp.y - px, w: 2 * px, h: 2 * px })
      ctx.textAlign = "center"
      ctx.fillStyle = css(c === 0 ? foreground : muted, 1)
      ctx.fillText(names[c], cp.x, cp.y)
    }

    ctx.font = fontSpec(false, 0.85)
    var hitList = []

    // ---- the Sun, the Moon and the planets: drawn under the traffic, a
    // little larger than life (the real discs would be 1.5 px) and quieter
    // than the aircraft. Their discs keep aircraft labels off them.
    var sunR = Math.max(5, px * 0.6), moonR = Math.max(6, px * 0.75)
    var lit = lightTheme ? background : bodyColor            // sunlight on the Sun and the Moon
    var ink = css(foreground, 0.7)                           // their rim on a light theme
    var marks = []                                           // labelled after the aircraft
    if (sky) {
      var sb = sky.sun
      var sp = dome(sb.az, Math.max(0, sb.el))
      if (sb.up) {
        if (!lightTheme) {
          var corona = ctx.createRadialGradient(sp.x, sp.y, sunR * 0.8, sp.x, sp.y, sunR * 3)
          corona.addColorStop(0, css(bodyColor, 0.32))
          corona.addColorStop(1, css(bodyColor, 0))
          ctx.fillStyle = corona
          disc(sp.x, sp.y, sunR * 3)
          ctx.fill()
        }
        disc(sp.x, sp.y, sunR)
        ctx.fillStyle = css(lit, 1)
        ctx.fill()
        if (lightTheme) {
          ctx.strokeStyle = ink; ctx.lineWidth = 1.2
          ctx.stroke()
          disc(sp.x, sp.y, 1.6)
          ctx.fillStyle = ink
          ctx.fill()
        }
        placed.push({ x: sp.x - sunR - 2, y: sp.y - sunR - 2, w: 2 * sunR + 4, h: 2 * sunR + 4 })
      } else if (sunEl > -18) {
        // In twilight a dashed ring on the horizon under the glow, where the
        // Sun has set or will rise.
        disc(sp.x, sp.y, sunR * 0.8)
        stroke(foreground, 0.5, 1.2)
        ctx.setLineDash([2, 2.5]); ctx.stroke(); ctx.setLineDash([])
      }

      var mo = sky.moon
      if (mo.up) {
        var mp = dome(mo.az, Math.max(0, mo.el))
        var lp = dome(mo.limb.az, mo.limb.el)
        // the unlit side, so the whole disc reads, then the lit part: the
        // bright semicircle facing the Sun closed by the terminator, a half
        // ellipse whose width follows the phase angle (a young crescent is
        // kept 2 px wide, or it would vanish)
        disc(mp.x, mp.y, moonR)
        ctx.fillStyle = css(lightTheme ? foreground : bodyColor, lightTheme ? 0.42 : 0.12)
        ctx.fill()
        if (mo.illuminated > 0.004) {
          ctx.save()
          ctx.translate(mp.x, mp.y)
          ctx.rotate(Math.atan2(lp.y - mp.y, lp.x - mp.x))
          ctx.beginPath()
          ctx.arc(0, 0, moonR, -Math.PI / 2, Math.PI / 2, false)
          var tk = Math.min(1 - 2 / moonR, -Math.cos(mo.phaseAngle * DEG))
          for (var tj = 1; tj < 24; tj++) {
            var ty0 = moonR * Math.cos(tj * Math.PI / 24)
            ctx.lineTo(tk * Math.sqrt(Math.max(0, moonR * moonR - ty0 * ty0)), ty0)
          }
          ctx.closePath()
          ctx.fillStyle = css(lit, lightTheme ? 1 : 0.92)
          ctx.fill()
          ctx.restore()
        }
        disc(mp.x, mp.y, moonR)
        if (lightTheme) { ctx.strokeStyle = ink; ctx.lineWidth = 1 }
        else stroke(bodyColor, 0.3, 1)
        ctx.stroke()
        placed.push({ x: mp.x - moonR - 2, y: mp.y - moonR - 2, w: 2 * moonR + 4, h: 2 * moonR + 4 })
        marks.push({ text: "Moon", x: mp.x, y: mp.y, gap: moonR + 4 })
      }

      // brightest last, so it ends on top; size by magnitude (Venus 3.9 px,
      // a first-magnitude planet 1.8 px)
      for (var pl = sky.planets.length - 1; pl >= 0; pl--) {
        var body = sky.planets[pl]
        if (!body.visible) continue
        var pp = dome(body.az, body.el)
        var pr = Math.max(1.5, Math.min(3.9, 2.2 - 0.38 * body.mag))
        disc(pp.x, pp.y, pr + 1.3)
        ctx.fillStyle = css(background, 0.6)              // keeps the dot off paths behind it
        ctx.fill()
        disc(pp.x, pp.y, pr)
        ctx.fillStyle = css(bodyColor, 0.95)
        ctx.fill()
        placed.push({ x: pp.x - pr - 1, y: pp.y - pr - 1, w: 2 * pr + 2, h: 2 * pr + 2 })
        marks.push({ text: body.name.charAt(0).toUpperCase() + body.name.slice(1), x: pp.x, y: pp.y, gap: pr + 5 })
      }
    }

    // ---- paths, then aircraft (highest drawn last, so it ends on top).
    // Paths only for the higher aircraft (a crowd at the horizon would hide the
    // sky), the selected and hovered one, and the next few to rise.
    var dusk = !!sun && sun.el < 0
    if (scan) {
      var all = scan.incoming.slice(0, maxRisingPaths).concat(scan.sky.slice().reverse())
      var risingShown = Math.min(maxRisingPaths, scan.incoming.length)
      var pathFrom = Math.max(0, scan.sky.length - maxPaths)         // sky is reversed: highest last
      ctx.lineCap = "round"
      for (var k = 0; k < all.length; k++) {
        var row = all[k]
        var path = row.path
        var rising = row.el <= 0
        var chosen = row.i === selectedIndex || row.i === hoveredIndex
        var high = k - risingShown >= pathFrom && row.el >= 6
        if (path.length < 2 || !(rising || chosen || high)) continue
        var pts = new Array(path.length)
        for (var m = 0; m < path.length; m++) pts[m] = dome(path[m].az, path[m].el)
        var isSel = row.i === selectedIndex
        // three stretches, fading with time
        var parts = rising ? 1 : 3
        for (var part = 0; part < parts; part++) {
          var from = Math.floor(part * (pts.length - 1) / parts)
          var to = Math.floor((part + 1) * (pts.length - 1) / parts)
          ctx.beginPath()
          ctx.moveTo(pts[from].x, pts[from].y)
          for (var s = from + 1; s <= to; s++) ctx.lineTo(pts[s].x, pts[s].y)
          var base = rising ? 0.4 : [0.5, 0.3, 0.14][part]
          var col = row.emergency ? urgent : accent
          stroke(isSel ? foreground : col, Math.min(1, (isSel ? base + 0.4 : base)) * row.alpha, isSel ? 1.8 : 1.2)
          if (rising) ctx.setLineDash([3, 4])
          ctx.stroke()
          if (rising) ctx.setLineDash([])
        }
      }
      ctx.lineCap = "butt"

      for (var g = 0; g < all.length; g++) {
        var ac = all[g]
        var pt = dome(ac.az, ac.el)
        if (ac.el <= 0) {
          // not up yet: a hollow marker where it will appear over the horizon
          var entry = dome(ac.path[0].az, ac.path[0].el)
          ctx.beginPath(); ctx.arc(entry.x, entry.y, 3.2, 0, 2 * Math.PI)
          stroke(ac.emergency ? urgent : accent, 0.75, 1.2)
          ctx.stroke()
          continue
        }
        var size = 4.5 + 2 * ac.el / 90
        // After sunset the aircraft that still catch the sun are the bright
        // ones against a dark sky.
        var colour = ac.emergency ? urgent : (ac.i === selectedIndex || ac.sunlit ? foreground : accent)
        var fade = ac.alpha * (dusk && !ac.sunlit && !ac.emergency ? 0.65 : 1)
        ctx.fillStyle = css(colour, fade)
        ctx.beginPath()
        var gi = Math.min(2, ac.path.length - 1)
        var ahead = ac.el >= 6 || ac.i === selectedIndex ? dome(ac.path[gi].az, ac.path[gi].el) : null
        if (ahead && (Math.abs(ahead.x - pt.x) + Math.abs(ahead.y - pt.y)) > 0.01) {
          var th = Math.atan2(ahead.y - pt.y, ahead.x - pt.x)
          var ct = Math.cos(th), st = Math.sin(th)
          var shape = [[1, 0], [-0.75, 0.66], [-0.35, 0], [-0.75, -0.66]]
          for (var v = 0; v < 4; v++) {
            var X = pt.x + size * (shape[v][0] * ct - shape[v][1] * st)
            var Y = pt.y + size * (shape[v][0] * st + shape[v][1] * ct)
            if (v === 0) ctx.moveTo(X, Y); else ctx.lineTo(X, Y)
          }
          ctx.closePath()
        } else {
          ctx.arc(pt.x, pt.y, 2.4, 0, 2 * Math.PI)
        }
        ctx.fill()
        if (ac.i === selectedIndex || ac.i === hoveredIndex) {
          ctx.beginPath(); ctx.arc(pt.x, pt.y, size + 5, 0, 2 * Math.PI)
          stroke(ac.i === selectedIndex ? foreground : accent, ac.i === selectedIndex ? 0.95 : 0.7, 1.4)
          ctx.stroke()
        }
        hitList.push({ i: ac.i, x: pt.x, y: pt.y })
      }

      // ---- labels: selected, hovered, then the highest few; never on top of
      // each other, and always inside the horizon, off the bright rim ticks
      // the rim's named aircraft first: bearing and distance, inside the horizon
      var lastAz = -999
      for (var bi = 0; bi < scan.beyond.length; bi++) {
        var bey = scan.beyond[bi]
        if (lastAz > -999 && Math.abs(((bey.brg - lastAz + 540) % 360) - 180) < 24) continue
        var lp = polar(bey.brg, R - px * 2.2)
        var rimText = Model.compassPoint(bey.brg) + " " + Model.formatDistance(bey.km, units)
        var rw = ctx.measureText(rimText).width
        halo(rimText, lp.x, lp.y, "center", foreground, 0.85)
        placed.push({ x: lp.x - rw / 2, y: lp.y - px * 0.6, w: rw, h: px * 1.2 })
        lastAz = bey.brg
      }
      var done = {}
      function label(row, detailed, color) {
        if (done[row.i]) return
        var pt2 = dome(row.az, row.el)
        if (place(labelFor(row, detailed), pt2.x, pt2.y, detailed, color, 1)) done[row.i] = true
      }
      var sel = rowFor(selectedIndex)
      if (sel && sel.el > 0) label(sel, true, foreground)
      var hov = rowFor(hoveredIndex)
      if (hov && hov.el > 0) label(hov, true, foreground)
      for (var lab = 0, shown = 0; lab < scan.sky.length && shown < labelCount; lab++) {
        label(scan.sky[lab], false, foreground)
        shown++
      }
      // the next aircraft to rise, labelled a little above where they appear
      for (var inc = 0; inc < Math.min(2, scan.incoming.length); inc++) {
        var ir = scan.incoming[inc]
        if (ir.path.length === 0) continue
        var ip = dome(ir.path[0].az, Math.max(ir.path[0].el, 0) + 7)
        place(incomingLabel(ir), ip.x, ip.y, false, foreground, 0.75)
      }

    }
    hits = hitList

    // ---- names of the bodies, last: they give way to every aircraft label
    // and avoid the aircraft themselves
    if (marks.length > 0) {
      for (var hk = 0; hk < hitList.length; hk++)
        placed.push({ x: hitList[hk].x - 5, y: hitList[hk].y - 5, w: 10, h: 10 })
      ctx.font = fontSpec(false, 0.8)
      for (var mk = 0; mk < marks.length; mk++)
        place(marks[mk].text, marks[mk].x, marks[mk].y, false, mix(muted, foreground, 0.35), 1, marks[mk].gap)
    }

    // ---- captions
    ctx.font = fontSpec(false, 0.9)
    ctx.textBaseline = "alphabetic"
    ctx.textAlign = "left"
    var line = px * 1.35
    if (!hasHome) {
      ctx.textBaseline = "middle"
      halo("Set a home location to look up", cx, cy, "center", muted)
      return
    }
    var topLeft = []
    if (scan) {
      topLeft.push([skyCount + " in sight", skyCount > 0 ? foreground : muted])
      if (incomingCount > 0) topLeft.push([incomingCount + " rising", muted])
      topLeft.push([beyondCount + " beyond", muted])
    } else {
      topLeft.push([service && service.status === "loading" ? "Waiting for traffic…" : "No traffic data", muted])
    }
    for (var tl = 0; tl < topLeft.length; tl++) {
      ctx.fillStyle = css(topLeft[tl][1], 1)
      ctx.fillText(topLeft[tl][0], 8, 6 + px + tl * line)
    }
    if (scan && skyCount === 0) {
      ctx.textBaseline = "middle"
      halo("Nothing in sight", cx, cy + R * 0.28, "center", muted)
    }
    if (sky) {
      // "nautical dusk · sun 9° below" over "moon 8% waxing"
      ctx.textAlign = "right"
      ctx.fillStyle = css(muted, 1)
      var phaseText = sky.twilight === "day" ? (sky.dusk ? "sunset" : "sunrise")
        : (sky.twilight === "night" ? "night" : sky.twilight + (sky.dusk ? " dusk" : " dawn"))
      ctx.fillText(sunEl > 0 ? "sun " + signed(sunEl) + " up" : phaseText + " · sun " + signed(-sunEl) + " below", w - 8, h - 8)
      ctx.fillText("moon " + Math.round(sky.moon.illuminated * 100) + "% " + (sky.moon.waxing ? "waxing" : "waning")
        + (sky.moon.up ? "" : " · below"), w - 8, h - 8 - line)
    } else if (sun) {
      ctx.textAlign = "right"
      ctx.fillStyle = css(muted, 1)
      ctx.fillText(sun.el > 0 ? "sun " + signed(sun.el) + " up" : "sun " + signed(-sun.el) + " below", w - 8, h - 8)
    }
    if (scan && isFinite(coverageKm) && coverageKm < 380) {
      ctx.textAlign = "left"
      ctx.fillStyle = css(muted, 1)
      ctx.fillText("data reaches " + Model.formatDistance(Math.max(0, coverageKm), units), 8, h - 8)
    }
  }
}
