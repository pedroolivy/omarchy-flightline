#version 440
// Flightline trails, fragment stage: a tapered comet tail, 0 wide and
// transparent at the tail, `trailWidth` and full strength where it meets the
// sprite (the last `headPx`, under the sprite, stay full), antialiased to the
// pixel even where it is thinner than one.
layout(location = 0) in vec4 vShape;
layout(location = 1) in vec4 vColor;
layout(location = 2) in float vZ;
layout(location = 0) out vec4 fragColor;

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

void main() {
    if (vColor.a <= 0.0) discard;
    float along = vShape.x, across = abs(vShape.y), len = vShape.z, w = vShape.w;
    float u = clamp(along / max(len - headPx, 1.0), 0.0, 1.0);   // 0 tail .. 1 where the sprite starts

    // Half-width tapers linearly; past the head the end is round.
    float hw = w * u;
    float d = along > len ? length(vec2(along - len, across)) : across;
    // A line thinner than a pixel keeps a one-pixel footprint and loses
    // coverage instead, so the taper fades rather than breaking into dots.
    float hwPx = max(hw, 0.5);
    float cov = clamp(hwPx + 0.5 - d, 0.0, 1.0) * (hw / hwPx);

    // Comet fade: most of the light near the head.
    float fade = u * sqrt(u);
    fragColor = vColor * cov * fade * smoothstep(0.0, 0.08, vZ) * qt_Opacity;
}
