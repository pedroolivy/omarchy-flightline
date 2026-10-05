#version 440
// Flightline route of the selected flight, vertex stage: one GridMesh, no CPU geometry.
//
// The route is two great-circle legs that meet at the aircraft: origin -> aircraft (flown)
// and aircraft -> destination (to go). Routes are per callsign and real tracks wander off
// the textbook great circle by up to 150 km, so a single origin -> destination arc would
// leave the sprite beside the line at regional zoom; two legs keep it on the line at any
// zoom.
//
// Mesh: GridMesh resolution (2 * steps + 6) x 1.
//   columns 0 .. 2 * steps    a ribbon along both legs (steps segments each, column `steps`
//                             is the aircraft). Columns are spaced closer near the three
//                             ends (cosine spacing), where deep zoom looks; a chord there
//                             stays well under a pixel off the true curve.
//   columns 2 * steps + 1..3  origin marker: left tip, top/bottom, right tip (a diamond)
//   columns 2 * steps + 4..6  destination marker, the same
// The two ends of the ribbon collapse to points, and so do the marker tips, so the cells
// that join the pieces have no area (the trick aircraft.vert uses between slots).
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 vPix;     // px, item space
layout(location = 1) out vec4 vRibbon;  // across (px), angle from the aircraft (rad, < 0 flown), flown fraction, z
layout(location = 2) out vec4 vInfo;    // kind (0 ribbon, 1 origin, 2 destination), marker-local px, angle aircraft -> destination
layout(location = 3) out vec2 vAt;      // the aircraft on screen, px

// Keep this block identical in route.vert and route.frag (build-shaders.sh checks).
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float width;            // item size, px
    float height;
    float centerLat;        // view centre, degrees
    float centerLon;
    float radius;           // globe radius, px
    float fromLat;          // origin, aircraft, destination (degrees)
    float fromLon;
    float atLat;
    float atLon;
    float toLat;
    float toLon;
    float steps;            // ribbon segments per leg
    float gapPx;            // the line stops this far from the aircraft (its sprite shows)
    float dotPx;            // spacing of the dots on the leg still to fly
    vec4 flownColor;        // colours arrive premultiplied
    vec4 restColor;
    vec4 haloColor;
};
out gl_PerVertex { vec4 gl_Position; };

const float RIBBON_HALF = 12.0;          // px each side of the line: room for the glow
const float MARK_HALF = 7.0;             // px, half the marker's inner square

vec3 toVec(float latDeg, float lonDeg) {
    float la = radians(latDeg), lo = radians(lonDeg);
    return vec3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la));
}

// Great-circle angle between unit vectors, stable for short legs.
float arc(vec3 a, vec3 b) { return 2.0 * asin(clamp(0.5 * length(a - b), 0.0, 1.0)); }

// Point at fraction f of the great circle a -> b (angle w).
vec3 slerp(vec3 a, vec3 b, float w, float f) {
    if (w < 1e-6) return normalize(mix(a, b, f));
    return (sin((1.0 - f) * w) * a + sin(f * w) * b) / sin(w);
}

void main() {
    float cells = 2.0 * steps + 6.0;
    float c = floor(qt_MultiTexCoord0.x * cells + 0.5);
    float side = qt_MultiTexCoord0.y < 0.5 ? 1.0 : -1.0;

    float la = radians(centerLat), lo = radians(centerLon);
    vec3 F = toVec(centerLat, centerLon);
    vec3 E = vec3(-sin(lo), cos(lo), 0.0);
    vec3 N = vec3(-sin(la) * cos(lo), -sin(la) * sin(lo), cos(la));
    vec2 centre = 0.5 * vec2(width, height);

    vec3 A = toVec(fromLat, fromLon), C = toVec(atLat, atLon), B = toVec(toLat, toLon);
    float wAC = arc(A, C), wCB = arc(C, B);

    vec3 P;
    vec2 offset = vec2(0.0);
    vRibbon = vec4(0.0);
    vInfo = vec4(0.0, 0.0, 0.0, wCB);
    vAt = centre + radius * vec2(dot(C, E), -dot(C, N));
    if (c <= 2.0 * steps) {
        // ---- the ribbon
        bool flown = c < steps;
        float u = flown ? c / steps : (c - steps) / steps;
        float f = 0.5 - 0.5 * cos(3.14159265358979 * u);
        vec3 a = flown ? A : C, b = flown ? C : B;
        float w = flown ? wAC : wCB;
        P = slerp(a, b, w, f);
        // Direction of travel on the sphere, projected: the orthographic projection is
        // linear, so this is exactly the screen tangent.
        vec3 n = cross(a, b);
        vec3 T = dot(n, n) > 1e-14 ? cross(normalize(n), P) : vec3(0.0);
        vec2 t = vec2(dot(T, E), -dot(T, N));
        t = dot(t, t) > 1e-12 ? normalize(t) : vec2(1.0, 0.0);
        bool end = c < 0.5 || c > 2.0 * steps - 0.5;
        float across = end ? 0.0 : side * RIBBON_HALF;
        offset = across * vec2(-t.y, t.x);
        // The angle from the aircraft is 0 at the shared column from both sides, so the
        // flown / to-go split falls exactly on the aircraft.
        vRibbon = vec4(across, flown ? -(1.0 - f) * wAC : f * wCB, flown ? f : 1.0, dot(P, F));
    } else {
        // ---- airport markers: diamonds around the origin and the destination
        float m = c - 2.0 * steps - 1.0;          // 0..2 origin, 3..5 destination
        bool origin = m < 2.5;
        float part = origin ? m : m - 3.0;
        P = origin ? A : B;
        vec2 corner = part < 0.5 ? vec2(-2.0, 0.0) : (part > 1.5 ? vec2(2.0, 0.0) : vec2(0.0, 2.0 * side));
        offset = MARK_HALF * corner;
        vInfo.xyz = vec3(origin ? 1.0 : 2.0, offset);
        vRibbon.w = dot(P, F);
    }
    vec2 s = centre + radius * vec2(dot(P, E), -dot(P, N)) + offset;
    vPix = s;
    gl_Position = qt_Matrix * vec4(s, 0.0, 1.0);
}
