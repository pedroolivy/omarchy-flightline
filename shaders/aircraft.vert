#version 440
// Flightline aircraft, vertex stage: every aircraft from ONE GridMesh.
//
// Mesh: GridMesh resolution (3 * slots - 1) x 1, i.e. 3 vertex columns per slot.
// Slot k owns columns 3k (left tip), 3k+1 (top/bottom) and 3k+2 (right tip);
// the two cells between them form a diamond around the sprite. The cell between
// slot k and k+1 has both edges collapsed to points, so it has no area. Hidden
// slots collapse all their vertices onto one point and cost no fragments.
//
// Data texture traffic.ppm (256 x 200, 24-bit big-endian fields, see
// docs/ARCHITECTURE.md): aircraft k is column k & 255 of block k >> 8, rows
//   0 lat, 1 lon, 2 track (16) | flags (8), 3 gs*16 (16) | altBand (8), 4 t_obs ms.
//
// Three layers share these shaders (`drawLayer`):
//   0 sprites: every aircraft except the selected/hovered ones;
//   1 focus (2 slots): those two on top, larger and ringed;
//   2 shadows: under everything, each airborne aircraft's silhouette pushed
//     away from a north-west light in proportion to its altitude, and blurred.
// shaders/trails.vert dead-reckons with the same maths, so a trail ends exactly
// under its sprite.
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 vLocal;   // sprite space; the glyph fits in [-1, 1], nose at +y
layout(location = 1) out vec4 vColor;   // premultiplied body colour
layout(location = 2) out vec4 vInfo;    // glyph class, ring (0 none, 1 selected, 2 hovered, 3 emergency), sprite half-size px,
                                        // halo 0/1 (shadow layer: blur radius, px)

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
layout(binding = 1) uniform sampler2D dataTex;
out gl_PerVertex { vec4 gl_Position; };

const vec2 TEX_SIZE = vec2(256.0, 200.0);
const float KT_TO_RAD_PER_S = 1.852 / 3600.0 / 6371.0;

vec3 fetch(float k, float row) {
    float col = mod(k, 256.0);
    float block = floor(k / 256.0);
    vec2 uv = (vec2(col, block * 5.0 + row) + 0.5) / TEX_SIZE;   // texel centre
    return floor(textureLod(dataTex, uv, 0.0).rgb * 255.0 + 0.5);
}
float u24(vec3 c) { return c.r * 65536.0 + c.g * 256.0 + c.b; }
float bit(float flags, float b) { return mod(floor(flags / exp2(b)), 2.0); }

vec3 toVec(float lat, float lon) { return vec3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat)); }

void main() {
    float c = floor(qt_MultiTexCoord0.x * columns + 0.5);
    float slot = floor(c / 3.0);
    float part = c - 3.0 * slot;                          // 0 left tip, 1 top/bottom, 2 right tip
    float side = qt_MultiTexCoord0.y < 0.5 ? 1.0 : -1.0;

    vLocal = vec2(0.0);
    vColor = vec4(0.0);
    vInfo = vec4(0.0);
    gl_Position = qt_Matrix * vec4(-64.0, -64.0, 0.0, 1.0);   // collapsed

    float shadow = drawLayer > 1.5 ? 1.0 : 0.0;
    float k = slot;
    float ring = 0.0;
    if (drawLayer > 0.5 && drawLayer < 1.5) {
        k = slot < 0.5 ? selectedSlot : hoveredSlot;
        ring = slot < 0.5 ? 1.0 : 2.0;
        if (slot > 0.5 && abs(hoveredSlot - selectedSlot) < 0.5) return;
    } else if (shadow < 0.5 && (abs(k - selectedSlot) < 0.5 || abs(k - hoveredSlot) < 0.5)) {
        return;                                           // drawn by the focus layer
    }
    if (k < 0.0 || k >= texCount) return;

    float lat = radians(u24(fetch(k, 0.0)) / 16777215.0 * 180.0 - 90.0);
    float lon = radians(u24(fetch(k, 1.0)) / 16777215.0 * 360.0 - 180.0);
    vec3 r2 = fetch(k, 2.0);
    vec3 r3 = fetch(k, 3.0);
    float trk = (r2.r * 256.0 + r2.g) / 65535.0 * 6.28318530717959;
    float flags = r2.b;
    float gs = (r3.r * 256.0 + r3.g) / 16.0;
    float altBand = r3.b;
    float age = texTime - u24(fetch(k, 4.0)) / 1000.0;

    float alpha = 1.0 - smoothstep(0.7 * maxAge, maxAge, age);
    if (alpha <= 0.0) return;

    float onGround = bit(flags, 0.0);
    if (shadow > 0.5 && onGround > 0.5) return;           // ground traffic sits on its shadow

    // ---- dead reckoning along the great circle through the observed point p0
    // with initial direction t0: w = p0 cos d + t0 sin d, whose direction of
    // travel there is -p0 sin d + t0 cos d (the heading, exactly). The same
    // points as Model.reckon's destination formula, without asin and atan;
    // shaders/trails.vert uses the same form, so trails end under the sprite.
    float d = gs * KT_TO_RAD_PER_S * clamp(age, 0.0, maxAge);
    float sla = sin(lat), cla = cos(lat), slo = sin(lon), clo = cos(lon);
    vec3 p0 = vec3(cla * clo, cla * slo, sla);
    vec3 t0 = cos(trk) * vec3(-sla * clo, -sla * slo, cla) + sin(trk) * vec3(-slo, clo, 0.0);
    float cd = cos(d), sd = sin(d);
    vec3 w = p0 * cd + t0 * sd;
    vec3 tw = t0 * cd - p0 * sd;

    // ---- orthographic projection
    float la = radians(centerLat), lo = radians(centerLon);
    vec3 F = toVec(la, lo);
    vec3 E = vec3(-sin(lo), cos(lo), 0.0);
    vec3 N = vec3(-sin(la) * cos(lo), -sin(la) * sin(lo), cos(la));
    vec2 centre = 0.5 * vec2(width, height);
    vec2 s = centre + radius * vec2(dot(w, E), -dot(w, N));
    float z = dot(w, F);

    // ---- look: glyph class, size and colour from flags and altitude
    float emergency = bit(flags, 1.0);
    float glyph = floor(flags / 8.0);
    glyph = glyph > 5.0 ? 4.0 : glyph;                    // reserved bits: the generic glyph
    float scale = glyph < 0.5 ? 1.0 : glyph < 1.5 ? 1.2 : glyph < 2.5 ? 0.8 : glyph < 3.5 ? 0.9 : glyph < 4.5 ? 0.85 : 0.6;
    float t = clamp(altBand / 160.0, 0.0, 1.0);           // 0 .. 40,000 ft
    vec4 col = t < 0.5 ? mix(lowColor, midColor, t * 2.0) : mix(midColor, highColor, t * 2.0 - 1.0);
    if (onGround > 0.5) {
        col = groundColor * 0.75;
        scale *= 0.6;
    }
    if (emergency > 0.5) {
        col = emergencyColor;
        scale *= 1.15;
        ring = max(ring, 3.0);
    }
    if (shadow > 0.5) {
        ring = 0.0;                                       // a shadow is only the silhouette
    } else if (ring > 0.5 && ring < 2.5) {
        if (ring < 1.5) col = selectedColor;
        scale = max(scale, 1.0) * 1.8;                    // room for the ring around the glyph
    } else if (ring > 2.5) {
        scale *= 1.5;
    }
    float halfPx = spritePx * scale;

    float margin = 2.0 * halfPx + 2.0 + shadowPx * shadow;
    if (z < 0.0 || any(lessThan(s, vec2(-margin))) || any(greaterThan(s, vec2(width, height) + margin)))
        return;                                           // behind the globe or off screen

    vec2 fwd = vec2(dot(tw, E), -dot(tw, N));               // the heading on screen
    fwd = dot(fwd, fwd) > 1e-12 ? normalize(fwd) : vec2(0.0, -1.0);
    vec2 right = vec2(-fwd.y, fwd.x);
    vec2 corner = part < 0.5 ? vec2(-2.0, 0.0) : (part > 1.5 ? vec2(2.0, 0.0) : vec2(0.0, 2.0 * side));
    float limb = smoothstep(0.0, 0.08, z);                // fade into the limb

    if (shadow > 0.5) {
        // Light from the north-west like the hillshade: the shadow falls to the
        // local south-east, further and softer the higher the aircraft flies.
        vec3 east = normalize(vec3(-w.y, w.x, 0.0) + vec3(1e-9, 0.0, 0.0));
        vec3 north = cross(w, east);
        vec3 down = east - north;                         // towards the local south-east
        vec2 se = vec2(dot(down, E), -dot(down, N));
        se = dot(se, se) > 1e-12 ? normalize(se) : vec2(0.7071, 0.7071);
        s += se * shadowPx * (0.15 + 0.85 * t);
        vLocal = corner;
        vColor = shadowColor * alpha * limb;
        vInfo = vec4(glyph, 0.0, halfPx, 0.6 + 1.6 * t);
        gl_Position = qt_Matrix * vec4(s + halfPx * (corner.x * right + corner.y * fwd), 0.0, 1.0);
        return;
    }

    // Tiny sprites are dots with a glow around them; give the glow room.
    float reach = ring < 0.5 ? 1.0 + 0.6 * glow * (1.0 - smoothstep(3.5, 5.0, halfPx)) : 1.0;
    corner *= reach;

    vLocal = corner;
    vColor = col * alpha * limb;
    // No dark outline for plain ground traffic: dozens of them at one airport
    // would merge into a smudge.
    vInfo = vec4(glyph, ring, halfPx, onGround > 0.5 && ring < 0.5 ? 0.0 : 1.0);
    // sprite x = right, sprite y = forward (towards the nose)
    gl_Position = qt_Matrix * vec4(s + halfPx * (corner.x * right + corner.y * fwd), 0.0, 1.0);
}
