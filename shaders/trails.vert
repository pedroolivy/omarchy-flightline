#version 440
// Flightline trails, vertex stage: a comet tail behind every airborne aircraft,
// from ONE GridMesh, drawn under the sprites (Aircraft.qml stacks it).
//
// Mesh: GridMesh resolution (3 * slots - 1) x 1 (61,440 vertices for 10,240
// slots). Slot k owns columns 3k (tail point), 3k+1 (head edge, the two rows on
// either side) and 3k+2 (a point ahead of the head): a kite around the tail.
// The cell between two slots joins two points and has no area; hidden slots
// collapse onto one point, as in aircraft.vert.
//
// The tail is the aircraft's own dead reckoning run backwards: the head is
// exactly aircraft.vert's position (same decode, same great-circle form, same
// clamp of the age), the tail the same great circle `trailSeconds` of flight
// earlier, plus the `headPx` the sprite hides, so a slow aircraft still shows
// its tail. A tail of a few tens of px is straight on screen to well under a
// pixel, so the kite is straight. Ground traffic and aircraft without speed
// draw nothing; stale ones fade exactly like their sprites.
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec4 vShape;   // along (px from the tail), across (px), length px, head half-width px
layout(location = 1) out vec4 vColor;   // premultiplied, already dimmed and faded
layout(location = 2) out float vZ;      // depth towards the viewer, for the limb

// Keep this block identical in trails.vert and trails.frag (build-shaders.sh checks).
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
    float maxAge;           // s; as Aircraft.maxAge
    float trailSeconds;     // flight time the tail covers, s
    float trailWidth;       // half-width at the head, px
    float headPx;           // px behind the head that the sprite covers; the tail starts there
    float strength;         // 0..1: the trail's share of the aircraft colour
    float selectedSlot;     // its trail takes selectedColor (-1 none)
    vec4 lowColor;          // colours arrive premultiplied
    vec4 midColor;
    vec4 highColor;
    vec4 selectedColor;
    vec4 emergencyColor;
};
layout(binding = 1) uniform sampler2D dataTex;
out gl_PerVertex { vec4 gl_Position; };

const vec2 TEX_SIZE = vec2(256.0, 200.0);
const float KT_TO_RAD_PER_S = 1.852 / 3600.0 / 6371.0;

// fetch, u24, bit, toVec and the dead reckoning in main(): keep identical to aircraft.vert.
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
    float part = c - 3.0 * slot;                          // 0 tail, 1 head edge, 2 ahead
    float side = qt_MultiTexCoord0.y < 0.5 ? 1.0 : -1.0;

    vShape = vec4(0.0);
    vColor = vec4(0.0);
    vZ = 0.0;
    gl_Position = qt_Matrix * vec4(-64.0, -64.0, 0.0, 1.0);   // collapsed

    float k = slot;
    if (k >= texCount) return;

    vec3 r2 = fetch(k, 2.0);
    vec3 r3 = fetch(k, 3.0);
    float flags = r2.b;
    float gs = (r3.r * 256.0 + r3.g) / 16.0;
    float glyph = floor(flags / 8.0);
    if (bit(flags, 0.0) > 0.5 || gs < 1.0 || (glyph > 4.5 && glyph < 5.5)) return;   // ground, parked, vehicle

    float age = texTime - u24(fetch(k, 4.0)) / 1000.0;
    float alpha = 1.0 - smoothstep(0.7 * maxAge, maxAge, age);
    if (alpha <= 0.0) return;

    float lat = radians(u24(fetch(k, 0.0)) / 16777215.0 * 180.0 - 90.0);
    float lon = radians(u24(fetch(k, 1.0)) / 16777215.0 * 360.0 - 180.0);
    float trk = (r2.r * 256.0 + r2.g) / 65535.0 * 6.28318530717959;
    float altBand = r3.b;

    // ---- the head is where the sprite is; the tail trailSeconds before it,
    // on the same great circle p0 cos d + t0 sin d as in aircraft.vert.
    float flown = clamp(age, 0.0, maxAge);
    float dh = gs * KT_TO_RAD_PER_S * flown;
    float dt = dh - gs * KT_TO_RAD_PER_S * trailSeconds - headPx / max(radius, 1.0);
    float sla = sin(lat), cla = cos(lat), slo = sin(lon), clo = cos(lon);
    vec3 p0 = vec3(cla * clo, cla * slo, sla);
    vec3 t0 = cos(trk) * vec3(-sla * clo, -sla * slo, cla) + sin(trk) * vec3(-slo, clo, 0.0);
    vec3 wh = p0 * cos(dh) + t0 * sin(dh);
    vec3 wt = p0 * cos(dt) + t0 * sin(dt);

    float la = radians(centerLat), lo = radians(centerLon);
    vec3 F = toVec(la, lo);
    vec3 E = vec3(-sin(lo), cos(lo), 0.0);
    vec3 N = vec3(-sin(la) * cos(lo), -sin(la) * sin(lo), cos(la));
    vec2 centre = 0.5 * vec2(width, height);
    vec2 sh = centre + radius * vec2(dot(wh, E), -dot(wh, N));
    vec2 st = centre + radius * vec2(dot(wt, E), -dot(wt, N));
    float zh = dot(wh, F), zt = dot(wt, F);

    vec2 axis = sh - st;
    float len = length(axis);
    if (zh < 0.0 || len < headPx + 1.5) return;           // behind the globe, or too short to see
    float margin = trailWidth + 3.0;
    if (max(sh.x, st.x) < -margin || max(sh.y, st.y) < -margin
            || min(sh.x, st.x) > width + margin || min(sh.y, st.y) > height + margin)
        return;                                           // off screen

    float t = clamp(altBand / 160.0, 0.0, 1.0);           // the sprite's altitude ramp
    vec4 col = t < 0.5 ? mix(lowColor, midColor, t * 2.0) : mix(midColor, highColor, t * 2.0 - 1.0);
    if (bit(flags, 1.0) > 0.5) col = emergencyColor;
    if (abs(k - selectedSlot) < 0.5) col = selectedColor;

    vec2 dir = axis / len;
    vec2 nrm = vec2(-dir.y, dir.x);
    float pad = 1.5;                                      // room for antialiasing
    float w = trailWidth + pad;
    vec2 at;
    if (part < 0.5) {
        at = st - dir * pad;
        vShape = vec4(-pad, 0.0, len, trailWidth);
        vZ = zt;
    } else if (part < 1.5) {
        at = sh + nrm * w * side;
        vShape = vec4(len, w * side, len, trailWidth);
        vZ = zh;
    } else {
        at = sh + dir * w * 2.3;                          // the kite's nose covers the round head
        vShape = vec4(len + w * 2.3, 0.0, len, trailWidth);
        vZ = zh;
    }
    // The head's own limb fade too: no trail without its sprite.
    vColor = col * strength * alpha * smoothstep(0.0, 0.08, zh);
    gl_Position = qt_Matrix * vec4(at, 0.0, 1.0);
}
