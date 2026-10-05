#version 440
// Flightline aircraft, fragment stage: one signed-distance silhouette per sprite.
// Glyph classes (flags bits 3-5): 0 twin jet, 1 four-engine heavy, 2 turboprop/GA,
// 3 rotorcraft, 4 glider (also balloons and the rest of category B),
// 5 ground vehicle (small square). The shapes are drawn for a 7-14 px half-size:
// every class differs in its wing (swept, swept with four pods, straight,
// rotor, long and slender), which still reads where engines and tails blur.
// Below a ~4 px half-size every glyph melts into a dot with a soft glow, so the
// world view reads as a field of light along the corridors.
layout(location = 0) in vec2 vLocal;
layout(location = 1) in vec4 vColor;
layout(location = 2) in vec4 vInfo;
layout(location = 0) out vec4 fragColor;

// Keep this block identical in aircraft.vert and aircraft.frag (build-shaders.sh checks).
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float width;            // item size, px
    float height;
    float centerLat;        // view centre, degrees
    float centerLon;
    float radius;           // globe radius, px
    float texTime;          // seconds since the epoch of the texture in use
    float texCount;         // aircraft in the texture in use
    float columns;          // GridMesh x resolution (3 * slots - 1)
    float drawLayer;        // 0 sprites, 1 selected/hovered, 2 shadows
    float spritePx;         // sprite half-size, px
    float maxAge;           // s; extrapolation stops here, fading from 70 %
    float selectedSlot;     // selectedIndex / hoveredIndex (-1 none)
    float hoveredSlot;
    float shadowPx;         // shadow offset at FL400, px (a ground-level shadow sits under the sprite)
    float glow;             // 0..1: halo of light around the dots at world zoom
    float glowAdditive;     // 0: the glow tints (default), 1: it adds light
    vec4 groundColor;       // colours arrive premultiplied
    vec4 lowColor;
    vec4 midColor;
    vec4 highColor;
    vec4 selectedColor;
    vec4 emergencyColor;
    vec4 haloColor;
    vec4 shadowColor;       // already scaled by the zoom fade
};

float segment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}
float cross2(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

// Exact distance to the convex quad a-b-c-d (either winding), negative inside.
// Wings and tailplanes are quads: a capsule cannot show sweep and taper.
float quad(vec2 p, vec2 a, vec2 b, vec2 c, vec2 d) {
    float dist = min(min(segment(p, a, b), segment(p, b, c)), min(segment(p, c, d), segment(p, d, a)));
    vec4 e = vec4(cross2(b - a, p - a), cross2(c - b, p - b), cross2(d - c, p - c), cross2(a - d, p - d));
    bool inside = min(min(e.x, e.y), min(e.z, e.w)) >= 0.0 || max(max(e.x, e.y), max(e.z, e.w)) <= 0.0;
    return inside ? -dist : dist;
}

// Silhouettes, nose at +y, mirror-symmetric in x, inside [-1, 1]. Each takes
// the mirrored point (x >= 0), so one wing, pod or tailplane draws both sides.

// Twin jet (A320, 737): swept tapered wing, one pod ahead of each wing.
float jet(vec2 p) {
    float d = segment(p, vec2(0.0, -0.50), vec2(0.0, 0.78)) - 0.115;       // fuselage
    d = min(d, segment(p, vec2(0.0, -0.88), vec2(0.0, -0.45)) - 0.065);     // tail cone
    d = min(d, quad(p, vec2(0.0, 0.27), vec2(0.97, -0.22), vec2(0.93, -0.34), vec2(0.0, -0.13)));
    d = min(d, segment(p, vec2(0.36, 0.22), vec2(0.36, 0.02)) - 0.08);      // engine pod
    return min(d, quad(p, vec2(0.0, -0.58), vec2(0.40, -0.84), vec2(0.38, -0.93), vec2(0.0, -0.80)));
}
// Four-engine heavy (747, A380): wider, deeper wing, two pods each side.
float heavy(vec2 p) {
    float d = segment(p, vec2(0.0, -0.50), vec2(0.0, 0.80)) - 0.14;
    d = min(d, segment(p, vec2(0.0, -0.90), vec2(0.0, -0.45)) - 0.08);
    d = min(d, quad(p, vec2(0.0, 0.32), vec2(1.0, -0.28), vec2(0.95, -0.42), vec2(0.0, -0.16)));
    d = min(d, segment(p, vec2(0.34, 0.25), vec2(0.34, 0.05)) - 0.075);
    d = min(d, segment(p, vec2(0.66, 0.06), vec2(0.66, -0.12)) - 0.07);
    return min(d, quad(p, vec2(0.0, -0.58), vec2(0.46, -0.86), vec2(0.43, -0.96), vec2(0.0, -0.82)));
}
// Turboprop / light aircraft: straight high-aspect wing well forward, short nose.
float light(vec2 p) {
    float d = segment(p, vec2(0.0, -0.45), vec2(0.0, 0.72)) - 0.12;
    d = min(d, segment(p, vec2(0.0, -0.84), vec2(0.0, -0.40)) - 0.065);
    d = min(d, quad(p, vec2(0.0, 0.42), vec2(1.0, 0.36), vec2(1.0, 0.18), vec2(0.0, 0.12)));
    return min(d, quad(p, vec2(0.0, -0.60), vec2(0.40, -0.62), vec2(0.40, -0.78), vec2(0.0, -0.80)));
}
// Rotorcraft: the rotor disc's rim around a cabin, a thin tail boom and its
// rotor. The rim is what reads at 7 px; the disc itself is filled faintly
// (main()).
float rotor(vec2 p) {
    float d = abs(length(p - vec2(0.0, 0.12)) - 0.82) - 0.06;              // rotor rim
    d = min(d, segment(p, vec2(0.0, -0.02), vec2(0.0, 0.30)) - 0.24);       // cabin
    d = min(d, segment(p, vec2(0.0, -0.10), vec2(0.0, -0.92)) - 0.065);     // tail boom
    return min(d, segment(p, vec2(0.0, -0.88), vec2(0.22, -0.88)) - 0.06);  // tail rotor
}
// Glider: long slender straight wing, thin fuselage, small tailplane.
float glider(vec2 p) {
    float d = segment(p, vec2(0.0, -0.84), vec2(0.0, 0.55)) - 0.06;
    d = min(d, segment(p, vec2(0.0, 0.08), vec2(0.0, 0.62)) - 0.10);        // cockpit
    d = min(d, quad(p, vec2(0.0, 0.30), vec2(1.0, 0.22), vec2(1.0, 0.12), vec2(0.0, 0.10)));
    return min(d, segment(p, vec2(0.0, -0.80), vec2(0.28, -0.80)) - 0.05);
}
float vehicle(vec2 p) {
    vec2 q = abs(p) - vec2(0.32);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.08;
}
float silhouette(float glyph, vec2 p) {
    vec2 m = vec2(abs(p.x), p.y);
    return glyph < 0.5 ? jet(m) : glyph < 1.5 ? heavy(m) : glyph < 2.5 ? light(m)
         : glyph < 3.5 ? rotor(m) : glyph < 4.5 ? glider(m) : vehicle(p);
}

void main() {
    if (vColor.a <= 0.0) discard;
    float glyph = floor(vInfo.x + 0.5);
    float ring = floor(vInfo.y + 0.5);
    float halfPx = vInfo.z;

    // ---- shadow layer: the silhouette, blurred by vInfo.w px
    if (drawLayer > 1.5) {
        float px = 1.0 / halfPx;
        float tiny = 1.0 - smoothstep(3.5, 5.0, halfPx);
        float d = tiny > 0.99 ? length(vLocal) - 0.55 : mix(silhouette(glyph, vLocal), length(vLocal) - 0.55, tiny);
        float blur = vInfo.w * px;
        fragColor = vColor * (1.0 - smoothstep(-blur, blur, d)) * qt_Opacity;
        return;
    }

    // ringed sprites draw the glyph in the inner part and the ring around it
    float inner = ring > 2.5 ? 0.72 : (ring > 0.5 ? 0.70 : 1.0);
    vec2 p = vLocal / inner;
    float glyphPx = halfPx * inner;                       // glyph half-size, px
    float px = 1.0 / glyphPx;                             // one px in glyph units

    // tiny: a dot (and no silhouette to evaluate, which is most sprites at world zoom)
    float tiny = 1.0 - smoothstep(3.5, 5.0, glyphPx);
    float d = length(p) - 0.55;
    if (tiny < 0.99) d = mix(silhouette(glyph, p), d, tiny);

    float fade = vColor.a;
    float body = 1.0 - smoothstep(-0.5 * px, 0.5 * px, d);
    // The dark outline separates a glyph from the map, and dots from each
    // other: without it the US and European cores merge into one bright plate.
    float halo = (1.0 - smoothstep(0.0, 2.5 * px, d)) * 0.7 * fade * vInfo.w * (1.0 - 0.1 * tiny);
    vec4 col = vColor * body;
    if (glyph > 2.5 && glyph < 3.5 && tiny < 0.99) {       // the rotor disc, faint
        float disc = (1.0 - smoothstep(-0.5 * px, 0.5 * px, length(p - vec2(0.0, 0.12)) - 0.82)) * (1.0 - tiny);
        col += vColor * 0.16 * disc * (1.0 - col.a);
    }
    col += haloColor * halo * (1.0 - col.a);

    // World zoom: a soft halo around each dot, so a sparse corridor (the North
    // Atlantic tracks) reads as a faint line. A tint by default: it converges
    // to the dot colour however many overlap. Additive light (alpha 0 in
    // premultiplied blending adds the colour) has no ceiling, and thousands of
    // dots over the US turn it into a white plateau that hides the dots.
    if (tiny > 0.01 && ring < 0.5) {
        float r = length(vLocal) * halfPx;                // px from the centre
        float g = exp(-0.5 * r * r / 2.2) * glow * tiny * (1.0 - body) * 0.2;
        col += vColor * g * vec4(1.0, 1.0, 1.0, 1.0 - glowAdditive);
    }

    if (ring > 0.5) {
        float pxS = 1.0 / halfPx;                         // one px in sprite units
        float r = abs(length(vLocal) - 1.25) - 0.75 * pxS;
        float cov = (1.0 - smoothstep(-0.5 * pxS, 0.5 * pxS, r)) * fade;
        vec4 rc = ring > 2.5 ? emergencyColor : selectedColor * (ring > 1.5 ? 0.6 : 1.0);
        col = rc * cov + col * (1.0 - rc.a * cov);
    }
    fragColor = col * qt_Opacity;
}
