#version 440
// Flightline globe, fragment stage: the whole Earth in one pass.
//
// earth.png  (Image smooth: false, fetched by hand; equirectangular, texel centres)
//   R = signed distance to the coast (+ on land), G = country borders,
//   B = state borders. Distances are metric texels: d = (t - 0.5) * 2 * spread.
//   The border channels are only side-signed, so they are decoded from four
//   manual taps (lineDist) instead of hardware filtering.
// lights.png (Image smooth: true)
//   R = night lights, G = R blurred (bloom), B = coarse signed coast distance.
// terrain.png (Image smooth: true; any size, width not a power of two: no mipmaps,
//   u wrapped by hand)
//   R = hillshade, 128 flat (land only), G = sea depth 8000 m * g^2,
//   B = land elevation 6000 m * b^2. Land and sea still come from earth.png: the
//   terrain only shades, so it can never draw a second coastline.
//
// Every line (coast, borders, graticule, isobaths, contours, rings) is a distance in pixels,
// measured with screen-space derivatives, so it stays one pixel sharp at any zoom
// and fades out where it would alias (far zoom, limb, poles).
layout(location = 0) in vec2 vPix;
layout(location = 1) in vec3 vEast;
layout(location = 2) in vec3 vNorth;
layout(location = 3) in vec3 vFwd;
layout(location = 4) in vec3 vHome;     // home and the live-data centre as unit vectors
layout(location = 5) in vec3 vLive;
layout(location = 0) out vec4 fragColor;

// Keep this block identical in globe.vert and globe.frag (build-shaders.sh checks).
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float width;            // item size, px
    float height;
    float centerLat;        // view centre, degrees
    float centerLon;
    float radius;           // globe radius, px
    float time;             // seconds (unused for now: no idle animation by design)
    float nightStrength;    // 0..1
    vec3 sunVector;         // unit vector to the sun, ECEF
    vec4 earthInfo;         // earth.png: width, height, land spread, border spread (texels)
    vec4 lightsInfo;        // lights.png: width, height, coarse coast spread, -
    vec4 spaceColor;        // colours arrive premultiplied
    vec4 oceanColor;
    vec4 landColor;
    vec4 coastColor;
    vec4 borderColor;
    vec4 gridColor;
    vec4 glowColor;
    vec4 lightsColor;
    vec4 homeColor;
    vec4 liveColor;
    float gridOn;           // the show* toggles as 0/1
    float bordersOn;
    float nightOn;
    float lightsOn;
    float homeLat;
    float homeLon;
    float homeRingNm;       // <= 0: no home
    float liveLat;
    float liveLon;
    float liveRadiusNm;     // <= 0: hidden
    vec4 terrainInfo;       // terrain.png: width, height, on (0/1: loaded and showRelief), relief strength
    vec4 shelfColor;        // shallow sea (continental shelves)
    vec4 deepColor;         // the abyss; oceanColor sits in between
    vec4 highlandColor;     // hypsometric tint towards the high ground
    vec4 snowColor;         // snow line and ice sheets
    vec4 shadeColor;        // relief: the side away from the light (alpha = strength)
    vec4 sheenColor;        // relief: the side facing the light (alpha = strength)
    vec4 twilightColor;     // hue of the narrow band at the terminator (alpha = how far it turns)
    vec4 isobathColor;      // 200 / 1,000 / 4,000 m depth contours at region zoom
    vec4 glintColor;        // sunlight reflected off the sea towards the viewer
    vec4 starColor;         // sparse stars around the disc
    float starsOn;          // 0/1 (showStars on a dark ocean)
    float isobathsOn;       // 0/1
};
layout(binding = 1) uniform sampler2D earth;
layout(binding = 2) uniform sampler2D lights;
layout(binding = 3) uniform sampler2D terrain;

const float PI = 3.14159265358979;
const float TAU = 6.28318530717959;
const float RAD_PER_NM = 1.0 / 3440.065;
const float EARTH_KM = 6371.0;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

// Premultiplied colour `c` over `dst` with coverage k.
vec3 over(vec3 dst, vec4 c, float k) { return dst * (1.0 - c.a * k) + c.rgb * k; }
vec3 straight(vec4 c) { return c.rgb / max(c.a, 1e-4); }

// Derivative of something that wraps every `period` (longitude, bearing) without the jump.
float unwrap(float d, float period) { return d - period * floor(d / period + 0.5); }

// Coverage of a line `w` px wide at distance `d` px, with one pixel of antialiasing.
float hairline(float d, float w) { return clamp(0.5 * w + 0.5 - abs(d), 0.0, 1.0); }

// Screen-space length of a gradient (px per unit of the field).
float grad(float x) { return max(length(vec2(dFdx(x), dFdy(x))), 1e-12); }

// Earth texel (i, j): x wraps around the antimeridian by hand, y clamps at the poles.
vec3 tap(float i, float j) {
    vec2 uv = vec2(fract((i + 0.5) / earthInfo.x), clamp((j + 0.5) / earthInfo.y, 0.0, 1.0));
    return textureLod(earth, uv, 0.0).rgb;
}

// Border distance (texels) from a side-signed channel: bilinear over the 4 taps, but the
// signed values are only trusted when a corner is within 0.75 texel of the line;
// otherwise |d| is interpolated (no false zero crossings on medial axes / sign seams).
float lineDist(vec4 c, vec2 f, float spread) {
    vec4 d = (c - 0.5) * 2.0 * spread;
    vec4 a = abs(d);
    vec4 v = min(min(a.x, a.y), min(a.z, a.w)) < 0.75 ? d : a;
    return abs(mix(mix(v.x, v.y, f.x), mix(v.z, v.w, f.x), f.y));
}

// Cubic B-spline of `tex` from 4 bilinear taps (st in texels, centres at i + 0.5 - 0.5).
// u wraps by hand. Magnified ~20x at regional zoom, plain bilinear shows diamond texels.
vec3 bspline(sampler2D tex, vec2 st, vec2 size) {
    vec2 i = floor(st), f = st - i;
    vec2 f2 = f * f, f3 = f2 * f;
    vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    vec2 w3 = f3 / 6.0;
    vec2 g0 = w0 + w1, g1 = 1.0 - g0;
    vec2 h0 = (i - 0.5 + w1 / g0) / size;
    vec2 h1 = (i + 1.5 + w3 / g1) / size;
    h0 = vec2(fract(h0.x), clamp(h0.y, 0.0, 1.0));
    h1 = vec2(fract(h1.x), clamp(h1.y, 0.0, 1.0));
    return g0.y * (g0.x * textureLod(tex, h0, 0.0).rgb + g1.x * textureLod(tex, vec2(h1.x, h0.y), 0.0).rgb)
         + g1.y * (g0.x * textureLod(tex, vec2(h0.x, h1.y), 0.0).rgb + g1.x * textureLod(tex, h1, 0.0).rgb);
}

// One tap while a lights texel spans less than ~1.5 px, or where it shows no bloom (G, R
// blurred wider than the B-spline reaches: no light within its 4 x 4 texels); the B-spline
// only around the lit places, magnified.
vec3 lightsAt(vec2 uv, float pxL) {
    vec3 l = textureLod(lights, vec2(fract(uv.x), uv.y), 0.0).rgb;
    if (pxL > 0.65 || l.g < 0.5 / 255.0) return l;
    return bspline(lights, uv * lightsInfo.xy - 0.5, lightsInfo.xy);
}

// terrain.png at uv: (relief -1..1, depth m, elevation m).
// One bilinear tap while a texel is about a pixel or smaller, the B-spline once it spans
// several (`smoothK` 0..1: no texel grid in the hillshade or the isobaths). Next to water
// (`shoreK` 0..1) B comes from four exact taps averaged over the land taps only: a lake
// or the sea (B = 0) would otherwise pull its shore down to sea level, a dark
// hypsometric ring around every high lake. Elsewhere those four taps are skipped.
vec3 terrainAt(vec2 uv, float smoothK, float shoreK) {
    vec2 size = terrainInfo.xy;
    vec2 st = uv * size - 0.5;
    vec3 t = vec3(0.0);
    if (smoothK < 1.0)
        t = textureLod(terrain, vec2(fract(uv.x), uv.y), 0.0).rgb;
    if (smoothK > 0.0)
        t = mix(t, bspline(terrain, st, size), smoothK);
    if (shoreK > 0.0) {
        vec2 i = floor(st), f = st - i;
        vec2 a = vec2(fract((i.x + 0.5) / size.x), clamp((i.y + 0.5) / size.y, 0.0, 1.0));
        vec2 b = vec2(fract((i.x + 1.5) / size.x), clamp((i.y + 1.5) / size.y, 0.0, 1.0));
        vec4 bb = vec4(textureLod(terrain, a, 0.0).b, textureLod(terrain, vec2(b.x, a.y), 0.0).b,
                       textureLod(terrain, vec2(a.x, b.y), 0.0).b, textureLod(terrain, b, 0.0).b);
        vec4 w = vec4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
        w *= step(0.5 / 255.0, bb);
        t.b = mix(t.b, dot(w, bb) / max(dot(w, vec4(1.0)), 1e-6), shoreK);
    }
    return vec3((t.r * 255.0 - 128.0) / 127.0, 8000.0 * t.g * t.g, 6000.0 * t.b * t.b);
}

// One graticule level every `s` degrees; fades in once its lines are far enough apart.
float graticule(float latD, float lonD, float sLat, float sLon, float s, float lo, float hi) {
    float gapLat = s / sLat, gapLon = s / sLon;           // spacing between lines, px
    float dLat = abs(fract(latD / s + 0.5) - 0.5) * gapLat;
    float dLon = abs(fract(lonD / s + 0.5) - 0.5) * gapLon;
    return max(hairline(dLat, 1.0) * smoothstep(lo, hi, gapLat),
               hairline(dLon, 1.0) * smoothstep(lo, hi, gapLon));
}

// Three pseudo-random numbers per screen cell, float maths only (no integer ops on the
// GLSL 100 es / 120 targets). "Hash without Sine", Copyright (c) 2014 David Hoskins,
// https://www.shadertoy.com/view/4djSRW, MIT License (full notice in NOTICE.md).
vec3 hash32(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// Contour of a height field at `level` (m): a hairline in px from the field and its
// gradient `hpx` (m per px).
float isobath(float h, float hpx, float level) { return hairline((h - level) / hpx, 1.0); }

void main() {
    vec2 p = vPix / radius;                               // unit-disc coordinates
    float rho = length(p);
    float disc = clamp((1.0 - rho) * radius + 0.5, 0.0, 1.0);
    float nightK = nightStrength * nightOn;
    vec4 glow = vec4(straight(glowColor), glowColor.a);

    // Everything on the sphere is skipped a few pixels outside the limb: at the fit radius
    // most of the item is space. The margin keeps whole 2x2 quads inside the branch where
    // the disc shows, so the screen-space derivatives below stay defined.
    vec3 col = vec3(0.0);
    if (rho < 1.0 + 3.0 / radius) {
        // ---- point on the sphere; clamped just inside the limb so derivatives stay finite
        vec2 q = p * min(1.0, 0.9995 / max(rho, 1e-6));
        float z = sqrt(max(0.0, 1.0 - dot(q, q)));
        vec3 w = q.x * vEast + q.y * vNorth + z * vFwd;
        float lat = asin(clamp(w.z, -1.0, 1.0));
        float lon = atan(w.y, w.x);
        float cl = cos(lat);
        vec2 uv = vec2(lon / TAU + 0.5, 0.5 - lat / PI);

        // ---- pixel footprint (radians of ground per px), unwrapped across the antimeridian
        vec2 dLon = vec2(unwrap(dFdx(lon), TAU), unwrap(dFdy(lon), TAU));
        vec2 dLat = vec2(dFdx(lat), dFdy(lat));
        float foot = max(max(length(vec2(dLon.x * cl, dLat.x)), length(vec2(dLon.y * cl, dLat.y))), 1e-7);
        float km = foot * EARTH_KM;                           // ground km per px

        // ---- earth: land, coast and borders from four exact taps
        float W = earthInfo.x;
        float px = foot * W / TAU;                            // footprint in earth texels
        float u = uv.x * W - 0.5;
        float v = uv.y * earthInfo.y - 0.5;
        float i0 = floor(u), j0 = floor(v);
        vec2 f = vec2(u - i0, v - j0);
        vec3 t00 = tap(i0, j0), t10 = tap(i0 + 1.0, j0), t01 = tap(i0, j0 + 1.0), t11 = tap(i0 + 1.0, j0 + 1.0);
        float dl = (mix(mix(t00.r, t10.r, f.x), mix(t01.r, t11.r, f.x), f.y) - 0.5) * 2.0 * earthInfo.z;
        float d0 = lineDist(vec4(t00.g, t10.g, t01.g, t11.g), f, earthInfo.w);
        float d1 = lineDist(vec4(t00.b, t10.b, t01.b, t11.b), f, earthInfo.w);

        float land = clamp(0.5 + dl / px, 0.0, 1.0);
        float fadeCoast = clamp((earthInfo.z - px) / (0.5 * earthInfo.z), 0.0, 1.0);
        float fadeBorder = clamp((earthInfo.w - px) / (0.5 * earthInfo.w), 0.0, 1.0) * bordersOn;
        float coast = clamp(1.0 - abs(dl) / px, 0.0, 1.0) * fadeCoast;
        float border0 = clamp(1.0 - d0 / px, 0.0, 1.0) * land * fadeBorder;
        float border1 = clamp(1.0 - d1 / px, 0.0, 1.0) * land * fadeBorder * smoothstep(1.1, 0.6, px);  // states: zoomed in only

        // ---- sun: which side of the terminator, and how far past it
        float sd = dot(w, sunVector);

        // ---- overlays: their coverage is worked out here, while w and the derivatives are at
        // hand, and composited further down in the usual order. Done late they would keep
        // those alive through the terrain, the most register-hungry part: fewer registers
        // keep more pixels in flight to hide the texture fetches.
        // Graticule: 15 deg at globe zoom, 5 and 1 deg join as the lines spread apart.
        float gridK = 0.0;
        if (gridOn > 0.5) {
            float sLat = max(degrees(length(dLat)), 1e-9);    // degrees of latitude per px
            float sLon = max(degrees(length(dLon)), 1e-9);
            float latD = degrees(lat), lonD = degrees(lon);
            gridK = graticule(latD, lonD, sLat, sLon, 15.0, 10.0, 28.0);
            gridK = max(gridK, graticule(latD, lonD, sLat, sLon, 5.0, 40.0, 90.0) * 0.6);
            gridK = max(gridK, graticule(latD, lonD, sLat, sLon, 1.0, 40.0, 90.0) * 0.45);
        }
        // The relief's east-west footprint (the texture's rows shrink towards the poles).
        float pxU = max(abs(dLon.x), abs(dLon.y)) * terrainInfo.x / TAU;
        // Sunlight glinting off the sea towards the viewer (orthographic: the view is vFwd).
        float glintK = 0.0;
        if (sd > 0.0 && glintColor.a > 0.0)
            glintK = pow(max(dot(w, normalize(sunVector + vFwd)), 0.0), 32.0) * smoothstep(0.0, 0.2, sd) * nightOn;

        // Rings (the live-data boundary, home) measure the chord to their centre and its
        // gradient: the same zero and the same slope as the arc, without an inverse sine on
        // every pixel. The ring sits at the chord 2 sin(r / 2).
        // Live-data boundary: a faint line with a soft inner edge.
        float liveK = 0.0;
        if (liveRadiusNm > 0.0 && liveRadiusNm * RAD_PER_NM < PI - 1e-3) {
            float q = length(w - vLive);
            float d = (q - 2.0 * sin(0.5 * liveRadiusNm * RAD_PER_NM)) / grad(q);
            liveK = hairline(d, 1.0) * 0.8 + exp(min(d, 0.0) / 10.0) * step(d, 0.0) * 0.12;
        }
        // Home: a dotted ring of homeRingNm and a marker (dm: px to it, 1e6 behind the globe).
        float ringK = 0.0, dm = 1e6;
        if (homeRingNm > 0.0) {
            vec3 H = vHome;
            float ring = min(homeRingNm * RAD_PER_NM, PI - 1e-3);
            float q = length(w - H);
            float across = (q - 2.0 * sin(0.5 * ring)) / grad(q);
            // The dots are worked out only where the ring is (the bearing takes an atan). Their
            // spacing on screen comes from the ring's tangent cross(H, w), whose length is the
            // sine of the angle from home, projected: radius times that is px per radian of
            // bearing, with no derivative inside the branch.
            if (abs(across) < 2.0) {
                vec3 e = vec3(-H.y, H.x, 0.0);
                e = dot(e, e) > 1e-10 ? normalize(e) : vec3(0.0, 1.0, 0.0);
                float bearing = atan(dot(w, e), dot(w, cross(H, e)));
                float n = clamp(floor(TAU * sin(ring) * radius / 9.0), 12.0, 4096.0);  // ~9 px apart
                vec3 tr = cross(H, w);
                float along = (fract(bearing / TAU * n + 0.5) - 0.5) * TAU / n
                            * radius * length(vec2(dot(tr, vEast), dot(tr, vNorth)));
                ringK = 1.0 - smoothstep(0.7, 1.7, length(vec2(along, across)));
            }
            if (dot(H, vFwd) >= 0.0)
                dm = length(vPix - radius * vec2(dot(H, vEast), dot(H, vNorth)));
        }

        // ---- lights.png: R lights, G bloom, B coarse coast distance. Read late, only where
        // the lights show; early only for the coast proxy when there is no terrain.
        float tOn = terrainInfo.z;
        vec3 L = vec3(0.0, 0.0, 0.5);
        if (tOn < 0.5)
            L = lightsAt(uv, foot * lightsInfo.x / TAU);

        vec3 ocean = straight(oceanColor);
        vec3 ground = straight(landColor);
        vec3 sea = ocean;
        if (tOn > 0.5) {
            // ---- terrain: sea-floor depth, hypsometric tint, snow and hillshade
            float pxT = foot * terrainInfo.x / TAU;           // footprint in terrain texels
            // Land within ~2 terrain texels of water (dl: earth texels to the coast) needs the
            // exact taps; the sea never reads B.
            float shore = 1.0 - smoothstep(1.5, 2.5, dl * terrainInfo.x / W);
            // Bilinear up to ~4 px a texel, where it still looks crisper than the B-spline's
            // blur; past ~6 px its creases show (kinked contours, a diamond grid in the shading).
            vec3 T = terrainAt(uv, smoothstep(0.24, 0.16, pxT), land > 0.0 ? shore : 0.0);
            float depth = T.y, elev = T.z;
            // Magnified past ~4 px a texel the 13 km data has no more detail to show, only soft
            // blobs: the hillshade and the sea-floor tones step back, and contours carry the shape.
            float soft = smoothstep(0.25, 0.07, pxT);

            // Isobaths and land contours need the gradient of the height, taken here in
            // (near-)uniform control flow: the branch follows the zoom, which only changes
            // smoothly across the disc. Elevation minus depth is one field (one of the two is 0
            // everywhere but at the coast), so both line sets share one gradient (m per px).
            float isoK = isobathsOn * smoothstep(2.2, 1.3, km);
            float conK = isoK * smoothstep(0.06, 0.14, km);
            float hpx = 1.0;
            if (isoK > 0.0)
                hpx = grad(elev - depth);

            // The sea and the land are each only worked out where they show.
            if (land < 1.0) {
                // Shelves lighter, the open ocean the theme's own colour, the abyss darker, and
                // the trenches carry the same trend on (darker, or more accent on a light ocean)
                // instead of turning grey. Ridges (~2.5 km) stay apart from the plains (~5 km).
                vec3 deep = straight(deepColor);
                sea = mix(straight(shelfColor), ocean, smoothstep(40.0, 1800.0, depth));
                sea = mix(sea, deep, smoothstep(2000.0, 6000.0, depth) * mix(1.0, 0.7, soft));
                sea = mix(sea, deep + (deep - ocean) * 0.8, smoothstep(6000.0, 8000.0, depth));
                // Magnified, the 13 km floor only shows as blotches: keep half of its tones.
                sea = mix(ocean, sea, mix(1.0, 0.5, soft));
                // Isobaths at region zoom, one faint hairline each at 200, 1,000 and 4,000 m (the G
                // codes 40.5, 90.5, 180.5: halfway between two, so a flat run of one code never
                // fills in). The 200 m line leaves the shore alone where the shelf is narrow, or
                // it would read as a second coast; the 4,000 m one is half as strong, since it
                // rings every seamount on the abyssal plains.
                if (isoK > 0.0) {
                    float iso = isobath(depth, hpx, 201.8) * clamp((-dl - 1.5) * 0.5, 0.0, 1.0);
                    iso = max(iso, isobath(depth, hpx, 1007.7));
                    iso = max(iso, isobath(depth, hpx, 4008.4) * 0.5);
                    sea = over(sea, isobathColor, iso * isoK);
                }
            }

            if (land > 0.0) {
                // Lowlands keep the land colour, the high ground leans towards the highland tint.
                float latD = degrees(lat);
                float ice = max(smoothstep(-60.0, -63.0, latD),
                                smoothstep(58.0, 66.0, latD) * smoothstep(900.0, 1800.0, elev));
                // Magnified past the data, the tint comes in layers (an atlas's hypsometric
                // steps, antialiased on the height gradient): clean shapes where a smooth tint
                // would only show the 13 km blur.
                float tintH = elev;
                if (soft > 0.0 && isoK > 0.0) {
                    float q = 500.0 * clamp((elev - 500.0) / hpx + 0.5, 0.0, 1.0)
                            + 500.0 * clamp((elev - 1000.0) / hpx + 0.5, 0.0, 1.0)
                            + 1000.0 * clamp((elev - 2000.0) / hpx + 0.5, 0.0, 1.0)
                            + 1000.0 * clamp((elev - 3000.0) / hpx + 0.5, 0.0, 1.0)
                            + 1000.0 * clamp((elev - 4000.0) / hpx + 0.5, 0.0, 1.0);
                    tintH = mix(elev, q + 250.0, soft * isoK);
                }
                ground = mix(ground, straight(highlandColor), smoothstep(300.0, 4500.0, tintH) * (1.0 - 0.7 * ice));
                // Snow on the peaks: a line in texel-mean metres (a 13 km mean sits far below
                // the summits) from ~5,400 m in the dry subtropics (Tibet stays mostly bare) to
                // ~2,400 m in the Alps, lower on the lit flanks. Ice sheets: Antarctica, and high
                // ground towards the Arctic (Greenland, the ice caps), quieter than snow so a
                // continent of ice does not outshine the traffic. Both fade on the night side.
                float line = mix(5400.0, 2300.0, smoothstep(26.0, 50.0, abs(latD))) - 500.0 * T.x;
                float snow = smoothstep(line, line + 900.0, elev);
                snow *= mix(1.0, 0.4, soft);              // magnified, snow fields blur into cloud
                float day = 1.0 - 0.75 * (1.0 - smoothstep(-0.10, 0.04, sd)) * nightK;
                ground = mix(ground, straight(snowColor), mix(snow, 0.16 + 0.12 * smoothstep(1500.0, 3200.0, elev), ice) * snowColor.a * day);

                // Hillshade: calm at globe zoom, alive at region zoom, calmer again on approach
                // charts (one texel is then tens of pixels of soft blur), and gone where a
                // texel is smaller than a pixel (no mipmaps: it would shimmer while the globe
                // turns). Towards the poles the texture's rows shrink, so the east-west
                // footprint counts too. Both sides saturate softly: no black holes on the
                // steepest slopes.
                float k = terrainInfo.w * mix(0.45, 0.85, smoothstep(9.0, 2.0, km))
                        * mix(0.65, 1.0, smoothstep(0.15, 0.7, km)) * smoothstep(3.0, 1.4, max(pxT, pxU));
                k *= mix(1.0, 0.15, soft);
                float r = T.x * k;
                ground = r < 0.0 ? mix(ground, straight(shadeColor), shadeColor.a * (1.0 - exp(2.0 * r)))
                                 : mix(ground, straight(sheenColor), sheenColor.a * (1.0 - exp(-2.5 * r)) * day);
                // Contours: a hairline every 1,000 m, every 500 m fainter where they stand far
                // enough apart; none within reach of the shore, where B is the land-only mean
                // and would kink.
                if (conK > 0.0) {
                    float c1 = isobath(elev, hpx, floor(elev / 1000.0 + 0.5) * 1000.0);
                    float c5 = isobath(elev, hpx, floor(elev / 500.0 + 0.5) * 500.0);
                    float apart = 1.0 / hpx;                      // px per metre of rise
                    float con = max(c1 * smoothstep(3.0, 6.0, 1000.0 * apart), c5 * 0.5 * smoothstep(5.0, 9.0, 500.0 * apart));
                    con *= conK * smoothstep(250.0, 450.0, elev) * (1.0 - shore) * (1.0 - soft);
                    ground = over(ground, vec4(straight(borderColor), 1.0) * 0.16, con);
                }
            }
        } else {
            // No terrain: v2.0's coarse proxy. Deep water darkens and the shelf takes a hint
            // of the coast colour. On a light ocean (light themes) both stay faint, or every
            // island gets a pale halo.
            float wide = (L.b - 0.5) * 2.0;                   // -1 open ocean .. +1 inland
            float lightSea = smoothstep(0.35, 0.8, dot(ocean, LUMA));
            sea = mix(ocean, ocean * mix(0.72, 0.95, lightSea), clamp(-wide, 0.0, 1.0));
            sea = mix(sea, mix(ocean, straight(coastColor), mix(0.10, 0.04, lightSea)), exp(-max(0.0, -wide) * 6.0));
        }

        sea = over(sea, glintColor, glintK);
        col = mix(sea, ground, land);
        col = over(col, borderColor, border1 * 0.45);
        col = over(col, borderColor, border0);
        col = over(col, coastColor, coast);

        col = over(col, gridColor, gridK);

        // Values derived again here rather than kept through the terrain (registers, above).
        float night = (1.0 - smoothstep(-0.10, 0.04, sd)) * nightK;
        float dark = (1.0 - smoothstep(-0.16, -0.02, sd)) * nightK * lightsOn;
        float pxL = foot * lightsInfo.x / TAU;                // footprint in lights texels

        // ---- a lit sphere: darker towards the limb, and on the day side a soft rise towards
        // the subsolar point (no brighter than the theme's own colours)
        col *= mix(0.78, 1.0, smoothstep(0.0, 0.55, z));
        col *= mix(1.0, mix(0.86, 1.0, smoothstep(0.0, 0.85, sd)), nightK * (1.0 - night));

        // ---- night side, twilight band and city lights (crossfaded from sharp to bloom by footprint)
        col = mix(col, col * 0.42, night);
        // Twilight: the theme's twilight hue at the pixel's own brightness, so the light
        // still falls steadily from day to night instead of drawing a bright seam. It rises
        // across the terminator and fades a few degrees into the night; alpha = how far
        // the hue turns.
        if (sd < 0.015 && sd > -0.3) {
            float dusk = smoothstep(0.015, -0.02, sd) * exp(min(sd + 0.02, 0.0) / 0.05);
            vec3 tw = straight(twilightColor);
            vec3 dim = tw * (dot(col, LUMA) / max(dot(tw, LUMA), 1e-3));
            col = mix(col, dim, dusk * twilightColor.a * nightK);
        }
        if (dark > 0.0 && tOn > 0.5)
            L = lightsAt(uv, pxL);
        // Zoomed in, one lights texel spans tens of pixels: capped and without bloom, or
        // a metro area washes out the labels and aircraft drawn over it.
        float capL = mix(0.18, 0.6, smoothstep(0.06, 0.6, pxL));
        float glowL = mix(min(L.r * L.r * 1.2, capL), L.g * 0.8, smoothstep(0.7, 2.2, pxL));
        col += lightsColor.rgb * glowL * dark;

        // ---- inner atmosphere towards the limb, stronger where the sun lights it
        float lit = mix(1.0, mix(0.35, 1.0, smoothstep(-0.3, 0.45, sd)), nightOn);
        col = mix(col, glow.rgb, pow(1.0 - z, 3.0) * 0.6 * glow.a * lit);

        // ---- the live-data boundary and home (coverage from above)
        col = over(col, liveColor, liveK);
        col = over(col, homeColor, ringK);
        col = over(col, spaceColor, (1.0 - smoothstep(4.0, 6.5, dm)) * 0.6);
        col = over(col, homeColor, 1.0 - smoothstep(3.0, 4.0, dm));
        col = over(col, homeColor, hairline(dm - 7.5, 1.2));
    }

    // ---- the limb: one crisp pixel of atmosphere, and outside it a halo in two scales
    // (a tight bright band and a wide soft one), both brighter on the sunlit side
    vec4 space = spaceColor;
    float halo = 0.0;
    if (rho > 1.0 - 3.0 / radius) {
        vec3 limbDir = (p.x * vEast + p.y * vNorth) / max(rho, 1e-6);
        float limbLit = mix(1.0, mix(0.3, 1.0, smoothstep(-0.35, 0.5, dot(limbDir, sunVector))), nightOn);
        col = mix(col, glow.rgb, hairline((1.0 - rho) * radius - 1.0, 1.0) * 0.5 * glow.a * limbLit);
        float thick = clamp(radius * 0.05, 5.0, 40.0);
        float out_ = max(rho - 1.0, 0.0) * radius;        // px outside the limb
        halo = (0.55 * exp(-out_ / (0.25 * thick)) + 0.45 * exp(-out_ / thick)) * 0.6 * glow.a * limbLit;
        space = spaceColor * (1.0 - halo) + vec4(glow.rgb, 1.0) * halo;
    }

    // ---- stars: one in ~9 cells of 22 px, static on the screen, one pixel sharp; they
    // give way to the halo and are never drawn on the disc
    if (starsOn > 0.5 && rho > 1.0) {
        vec2 cell = floor(vPix / 22.0);
        vec3 h = hash32(cell + 71.0);
        if (h.z < 0.11) {
            vec2 c0 = fract(0.5 * vec2(width, height) + 0.5);   // vPix of a pixel centre, mod 1
            vec2 sp = floor((cell + 0.15 + 0.7 * h.xy) * 22.0 - c0) + c0;
            float b = h.z / 0.11;                         // 0..1: a few bright, most faint
            vec2 dd = vPix - sp;
            float star = exp(-dot(dd, dd) / mix(0.12, 0.45, b * b)) * mix(0.25, 1.0, b * b);
            star *= smoothstep(0.35, 0.05, halo) * (1.0 - disc);
            space = space * (1.0 - starColor.a * star) + starColor * star;
        }
    }
    fragColor = mix(space, vec4(col, 1.0), disc) * qt_Opacity;
}
