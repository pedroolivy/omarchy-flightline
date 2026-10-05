import QtQuick

// The selected flight's route as a GPU ribbon: origin -> aircraft drawn solid with a
// glow that grows towards the aircraft, aircraft -> destination dotted, the airports
// marked. Two great-circle legs that meet at the aircraft, so the sprite sits on the
// line at every zoom (shaders/route.vert explains why one arc is not enough).
//
// Geometry is one constant GridMesh; moving the camera or the aircraft only changes
// uniforms, so the layer costs no CPU per frame. The airport codes are labels, placed
// by GlobeView with the others.
//
// Imports QtQuick only, like the other layers (tests render it offscreen).
ShaderEffect {
  id: root

  // -------------------------------------------------------------- view
  property real centerLat: 0                    // degrees
  property real centerLon: 0
  property real radius: Math.min(width, height) * 0.45   // px, same as the Globe

  // ------------------------------------------------------------- route
  property real fromLat: 0                      // origin airport
  property real fromLon: 0
  property real atLat: 0                        // the aircraft, dead-reckoned like its sprite
  property real atLon: 0
  property real toLat: 0                        // destination airport
  property real toLon: 0
  property bool shown: false
  property real gapPx: 14                       // the line stops this far from the aircraft
  property real dotPx: 7                        // spacing of the dots still to fly

  // ------------------------------------------------------------ colours
  property color flownColor: "#7aa2f7"
  property color restColor: "#6b7199"
  property color haloColor: Qt.rgba(0.1, 0.1, 0.15, 0.8)

  // ------------------------------------------- uniforms (see route.vert)
  // 160 segments a leg with cosine spacing: the first one is ~1e-4 of the leg, so
  // even a 10,000 km leg is within a fraction of a pixel of its curve at full zoom
  // near the aircraft and the airports.
  readonly property real steps: 160

  visible: shown
  blending: true
  mesh: GridMesh { resolution: Qt.size(2 * root.steps + 6, 1) }
  vertexShader: Qt.resolvedUrl("shaders/route.vert.qsb")
  fragmentShader: Qt.resolvedUrl("shaders/route.frag.qsb")
}
