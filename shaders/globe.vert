#version 440
// Flightline globe, vertex stage: the item's own quad. Builds the view basis and the
// overlay centres once per vertex so the fragment stage only does per-pixel work.
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 vPix;     // px from the globe centre, y up
layout(location = 1) out vec3 vEast;    // view basis in ECEF (x = lon 0, z = north)
layout(location = 2) out vec3 vNorth;
layout(location = 3) out vec3 vFwd;
layout(location = 4) out vec3 vHome;    // home and the live-data centre as unit vectors, once per vertex
layout(location = 5) out vec3 vLive;

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
out gl_PerVertex { vec4 gl_Position; };

vec3 toVec(float latDeg, float lonDeg) {
    float la = radians(latDeg), lo = radians(lonDeg);
    return vec3(cos(la) * cos(lo), cos(la) * sin(lo), sin(la));
}

void main() {
    vPix = (qt_MultiTexCoord0 - 0.5) * vec2(width, -height);
    float la = radians(centerLat), lo = radians(centerLon);
    float sl = sin(la), cl = cos(la), sn = sin(lo), cn = cos(lo);
    vFwd = vec3(cl * cn, cl * sn, sl);
    vEast = vec3(-sn, cn, 0.0);
    vNorth = vec3(-sl * cn, -sl * sn, cl);
    vHome = toVec(homeLat, homeLon);
    vLive = toVec(liveLat, liveLon);
    gl_Position = qt_Matrix * qt_Vertex;
}
