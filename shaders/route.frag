#version 440
// Flightline route of the selected flight, fragment stage (see route.vert).
//   flown leg    a 2 px line over a dark halo, brightening towards the aircraft, with a
//                soft glow that grows the same way: where it has been, fading behind it
//   to go        round dots anchored to the ground (they do not crawl as the aircraft
//                advances) over a faint hairline, so the path still reads at globe zoom
//   airports     the origin a filled dot, the destination a ring with a centre dot
// The line stops short of the aircraft so its sprite is never covered, and everything
// fades into the limb like the sprites do.
layout(location = 0) in vec2 vPix;
layout(location = 1) in vec4 vRibbon;
layout(location = 2) in vec4 vInfo;
layout(location = 3) in vec2 vAt;
layout(location = 0) out vec4 fragColor;

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

// Coverage of a line `w` px wide at distance `d` px, with one pixel of antialiasing.
float hairline(float d, float w) { return clamp(0.5 * w + 0.5 - abs(d), 0.0, 1.0); }

// Coverage of a disc of radius `r` px at distance `d` px.
float disc(float d, float r) { return clamp(r + 0.5 - d, 0.0, 1.0); }

// Premultiplied `c` with coverage k over the premultiplied `dst`.
vec4 over(vec4 dst, vec4 c, float k) { return dst * (1.0 - c.a * k) + c * k; }

void main() {
    float across = vRibbon.x;
    float fromAt = vRibbon.y;
    // Dot phase: angle back from the destination in units of the dot spacing. Derivatives
    // are taken before any branching.
    float phase = (vInfo.w - fromAt) * radius / dotPx;
    float perPx = max(length(vec2(dFdx(phase), dFdy(phase))), 1e-6);
    float front = smoothstep(0.0, 0.08, vRibbon.w);

    vec4 col = vec4(0.0);
    if (vInfo.x < 0.5) {
        // ---- the ribbon
        float clear = smoothstep(gapPx, gapPx + 3.0, length(vPix - vAt));
        if (fromAt < 0.0) {
            float g = vRibbon.z;                         // 0 at the origin, 1 at the aircraft
            float k = mix(0.4, 1.0, g * g);
            col = over(col, haloColor, hairline(across, 4.0) * 0.6 * k);
            col = over(col, flownColor, exp(-across * across / 32.0) * 0.32 * g * g);
            col = over(col, flownColor, hairline(across, 2.0) * k);
        } else {
            float along = (fract(phase) - 0.5) / perPx;  // px from the nearest dot centre
            col = over(col, restColor, hairline(across, 1.0) * 0.28);
            float d = length(vec2(along, across));
            col = over(col, haloColor, disc(d, 2.6) * 0.6);
            col = over(col, flownColor, disc(d, 1.45));
        }
        col *= clear;
    } else {
        // ---- airports
        float d = length(vInfo.yz);
        col = over(col, haloColor, disc(d, 6.0) * 0.6);
        if (vInfo.x < 1.5) {
            col = over(col, flownColor, disc(d, 3.4));
        } else {
            col = over(col, flownColor, hairline(d - 4.0, 1.6));
            col = over(col, flownColor, disc(d, 1.3));
        }
    }
    fragColor = col * front * qt_Opacity;
}
