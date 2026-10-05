import QtQuick

// GPU trails: a short comet tail behind every airborne aircraft, from one
// ShaderEffect over the same data texture as Aircraft.qml (shaders/trails.vert
// has the details). Aircraft.qml stacks it under its sprites and drives every
// property; on its own it draws nothing until `dataTex` and `texCount` are set.
//
// The tail covers the last `trailSeconds` of flight along the great circle the
// sprite is dead-reckoned on, so a faster aircraft draws a longer tail. Nothing
// here runs per aircraft or per frame in JS.
ShaderEffect {
  id: root

  // -------------------------------------------------------------- view
  property real centerLat: 0                    // degrees
  property real centerLon: 0
  property real radius: Math.min(width, height) * 0.45   // px, same as the Globe

  // -------------------------------------------------------------- data
  property variant dataTex                      // traffic.ppm as Aircraft.qml shows it
  property real texTime: 0                      // s since the epoch of dataTex
  property real texCount: 0
  property real maxAge: 90                      // s; as Aircraft.maxAge
  property real selectedSlot: -1                // its trail takes selectedColor

  // -------------------------------------------------------------- look
  property real trailSeconds: 60                // flight time the tail covers, s
  property real trailWidth: 1                   // half-width at the head, px
  property real headPx: 0                       // px behind the head the sprite covers; the tail starts there
  property real strength: 0.5                   // 0..1: share of the aircraft colour
  property color lowColor: "#565f89"            // the sprites' altitude ramp
  property color midColor: "#7aa2f7"
  property color highColor: "#c0caf5"
  property color selectedColor: "#ff9e64"
  property color emergencyColor: "#f7768e"

  readonly property int capacity: 10240
  readonly property real columns: 3 * capacity - 1

  mesh: GridMesh { resolution: Qt.size(3 * root.capacity - 1, 1) }
  vertexShader: Qt.resolvedUrl("shaders/trails.vert.qsb")
  fragmentShader: Qt.resolvedUrl("shaders/trails.frag.qsb")
}
