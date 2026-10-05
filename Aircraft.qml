import QtQuick

// GPU aircraft layer: up to 10,240 aircraft from one ShaderEffect and one
// small data texture (traffic.ppm, written by flightline-feed; format in
// docs/ARCHITECTURE.md). Nothing here touches individual aircraft in JS: the
// vertex shader decodes each one from the texture, dead-reckons it along its
// great circle from `time`, and fades it out as its data gets old.
//
// The texture is double-buffered: a new `revision` loads into the hidden
// Image, and only once it is ready do the texture, `count` and `epochMs` switch
// together, so a frame never mixes a new count with old positions.
//
// The selected and hovered aircraft are drawn by a second, two-slot layer on
// top, larger and ringed in `selectedColor`. Under the sprites, as children
// with a negative z, sit the trails (Trails.qml) and, at region zoom, the
// altitude shadows (these shaders again, in shadow mode), so the view stacks
// one item and every layer shares the texture swap above.
//
// Zoom moods follow `spritePx`, which the view already scales with zoom: at
// world zoom (~2.6 px) dots with a glow and short tails that read as flow; once
// glyphs appear (4-5 px) shadows fade in; tails stay ~10-35 px on screen.
ShaderEffect {
  id: root

  // -------------------------------------------------------------- view
  property real centerLat: 0                    // degrees
  property real centerLon: 0
  property real radius: Math.min(width, height) * 0.45   // px, same as the Globe
  property real spritePx: 6                     // sprite half-size, px (the view scales it with zoom)

  // -------------------------------------------------------------- data
  property url source                           // file URL of traffic.ppm
  property int revision: 0                      // bump to reload
  property int count: 0                         // aircraft in the file at `revision`
  property real epochMs: 0                      // texture epoch of `revision`
  property real time: 0                         // s since epochMs (set by the view)
  property real maxAge: 90                      // s; stop extrapolating, fade out from 70 %
  property int selectedIndex: -1
  property int hoveredIndex: -1
  readonly property int capacity: 10240

  // ------------------------------------------------------------ colours
  property color groundColor: "#565f89"
  property color lowColor: "#565f89"            // altitude ramp: muted -> accent -> foreground
  property color midColor: "#7aa2f7"
  property color highColor: "#c0caf5"
  property color selectedColor: "#ff9e64"
  property color emergencyColor: "#f7768e"
  property color haloColor: Qt.rgba(0.09, 0.09, 0.12, 0.8)
  // The halo is the theme background: it tells a light theme from a dark one.
  readonly property bool lightBackdrop: 0.2126 * haloColor.r + 0.7152 * haloColor.g + 0.0722 * haloColor.b > 0.5
  property color shadowColor: Qt.rgba(haloColor.r * 0.3, haloColor.g * 0.3, haloColor.b * 0.3, lightBackdrop ? 0.26 : 0.5)

  // ------------------------------------------------------------- layers
  property bool showTrails: true
  property bool showShadows: true
  // Tail length on screen of a 450 kt jet, px, from behind its sprite; slower
  // aircraft draw shorter ones.
  property real trailPx: 4 * spritePx
  // Flight time that takes at this zoom (s); ~8 min at world zoom, seconds when deep.
  property real trailSeconds: Math.max(1, Math.min(900, trailPx / Math.max(1, radius) / (450 * 1.852 / 3600 / 6371)))
  property real trailWidth: Math.max(0.6, Math.min(1.5, 0.18 * spritePx))   // half-width at the head, px
  // Share of the aircraft colour; dark ink weighs more. At world zoom thousands
  // of tails overlap in the corridors, so there they are fainter: flow, not a
  // white-out that hides the dots and the city names.
  property real trailStrength: (lightBackdrop ? 0.55 : 0.7) * (0.4 + 0.6 * smoothstep(3.0, 5.0, spritePx))
  // Shadows appear with the glyphs (dots cast none) and fall up to shadowPx
  // away at FL400.
  property real shadowStrength: smoothstep(4.0, 5.5, spritePx)
  property real shadowPx: 1.3 * spritePx
  property real glow: lightBackdrop ? 0.6 : 1   // 0..1, the tint around dots at world zoom
  // 1 adds the glow as light instead of tinting. Off by default: added light
  // has no ceiling, and the dense cores (the US, Europe) turn into a white
  // plateau that hides the dots and the city names over them.
  property real glowAdditive: 0

  function smoothstep(e0, e1, x) {
    var t = Math.max(0, Math.min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
  }

  // ------------------------------------------ uniforms (see aircraft.vert)
  property real texEpochMs: 0                   // epoch / count of the texture on screen
  property real texCount: 0
  readonly property real texTime: time + (epochMs - texEpochMs) / 1000
  readonly property real selectedSlot: selectedIndex
  readonly property real hoveredSlot: hoveredIndex
  readonly property real columns: 3 * capacity - 1
  readonly property real drawLayer: 0
  readonly property color shadowFaded: Qt.rgba(shadowColor.r, shadowColor.g, shadowColor.b, shadowColor.a * shadowStrength)
  property variant dataTex: bufferA

  mesh: GridMesh { resolution: Qt.size(3 * root.capacity - 1, 1) }
  vertexShader: Qt.resolvedUrl("shaders/aircraft.vert.qsb")
  fragmentShader: Qt.resolvedUrl("shaders/aircraft.frag.qsb")

  // ------------------------------------------------------ double buffer
  property int front: 0                         // 0 = bufferA on screen, 1 = bufferB

  onSourceChanged: load()
  onRevisionChanged: load()
  Component.onCompleted: load()

  function load() {
    var back = front === 0 ? bufferB : bufferA
    // "#rev" makes every revision a new URL; with cache: false it is re-read from disk.
    // Revision 0 means the helper has not written the file yet.
    back.source = source.toString() === "" || revision <= 0 ? "" : source + "#" + revision
  }
  function swap(image) {
    if (image.status !== Image.Ready || image === dataTex) return
    texEpochMs = epochMs
    texCount = Math.min(count, capacity)
    dataTex = image
    front = image === bufferA ? 0 : 1
  }

  Image {
    id: bufferA
    visible: false
    asynchronous: true
    cache: false
    smooth: false
    onStatusChanged: root.swap(bufferA)
  }
  Image {
    id: bufferB
    visible: false
    asynchronous: true
    cache: false
    smooth: false
    onStatusChanged: root.swap(bufferB)
  }

  // ----------------------------------------------- shadows and trails under
  ShaderEffect {
    z: -2
    anchors.fill: parent
    visible: root.showShadows && root.shadowStrength > 0.01 && root.texCount > 0

    readonly property real centerLat: root.centerLat
    readonly property real centerLon: root.centerLon
    readonly property real radius: root.radius
    readonly property real spritePx: root.spritePx
    readonly property real texTime: root.texTime
    readonly property real texCount: root.texCount
    readonly property real maxAge: root.maxAge
    readonly property real selectedSlot: -1
    readonly property real hoveredSlot: -1
    readonly property real columns: root.columns
    readonly property real drawLayer: 2
    readonly property real shadowPx: root.shadowPx
    readonly property real glow: 0
    readonly property real glowAdditive: 0
    readonly property color groundColor: root.groundColor   // unused by shadows, but every uniform needs a property
    readonly property color lowColor: root.lowColor
    readonly property color midColor: root.midColor
    readonly property color highColor: root.highColor
    readonly property color selectedColor: root.selectedColor
    readonly property color emergencyColor: root.emergencyColor
    readonly property color haloColor: root.haloColor
    readonly property color shadowColor: root.shadowFaded
    readonly property variant dataTex: root.dataTex

    mesh: GridMesh { resolution: Qt.size(3 * root.capacity - 1, 1) }
    vertexShader: root.vertexShader
    fragmentShader: root.fragmentShader
  }
  Trails {
    z: -1
    anchors.fill: parent
    visible: root.showTrails && root.texCount > 0
    centerLat: root.centerLat
    centerLon: root.centerLon
    radius: root.radius
    dataTex: root.dataTex
    texTime: root.texTime
    texCount: root.texCount
    maxAge: root.maxAge
    selectedSlot: root.selectedIndex
    trailSeconds: root.trailSeconds
    trailWidth: root.trailWidth
    headPx: 0.9 * root.spritePx               // a jet's tail is 0.88 half-sizes behind its centre
    strength: root.trailStrength
    lowColor: root.lowColor
    midColor: root.midColor
    highColor: root.highColor
    selectedColor: root.selectedColor
    emergencyColor: root.emergencyColor
  }

  // --------------------------------------------- selected / hovered on top
  ShaderEffect {
    anchors.fill: parent
    visible: root.selectedIndex >= 0 || root.hoveredIndex >= 0

    readonly property real centerLat: root.centerLat
    readonly property real centerLon: root.centerLon
    readonly property real radius: root.radius
    readonly property real spritePx: root.spritePx
    readonly property real texTime: root.texTime
    readonly property real texCount: root.texCount
    readonly property real maxAge: root.maxAge
    readonly property real selectedSlot: root.selectedSlot
    readonly property real hoveredSlot: root.hoveredSlot
    readonly property real columns: 5
    readonly property real drawLayer: 1
    readonly property real shadowPx: 0
    readonly property real glow: 0
    readonly property real glowAdditive: 0
    readonly property color groundColor: root.groundColor
    readonly property color lowColor: root.lowColor
    readonly property color midColor: root.midColor
    readonly property color highColor: root.highColor
    readonly property color selectedColor: root.selectedColor
    readonly property color emergencyColor: root.emergencyColor
    readonly property color haloColor: root.haloColor
    readonly property color shadowColor: root.shadowFaded
    readonly property variant dataTex: root.dataTex

    mesh: GridMesh { resolution: Qt.size(5, 1) }
    vertexShader: root.vertexShader
    fragmentShader: root.fragmentShader
  }
}
