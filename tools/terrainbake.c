/*
 * terrainbake - bake Flightline's relief texture (assets/terrain.png) from a NOAA ETOPO grid.
 *
 *   terrainbake dem cols rows lon0 lat0 le|be land.pgm W out.ppm [ve_land ve_sea gain_land gain_sea]
 *
 *   dem       raw int16 heights in metres, rows north to south, "-" reads stdin
 *   lon0 lat0 centre of the first (north-west) cell, degrees; cells are 360/cols wide
 *             and 180/rows tall, columns wrap around the antimeridian
 *   land.pgm  earth.png's R plane (signed coast distance, > 127.5 on land), any size:
 *             it decides land and sea, the DEM only shades
 *   W         output width; the output is W x W/2, texel (i,j) centre at
 *             lon = (i+0.5)*360/W - 180, lat = 90 - (j+0.5)*180/H, like earth.png
 *
 * Output planes (8 bit, P6):
 *   R  hillshade, 128 = flat:  byte = 128 + round(127 * clamp(gain * x, -1, 1))
 *      x = Lambertian shade under the light set below, relative to flat ground and scaled to
 *      -1 (full shade) .. +1 (facing the light), see shade().  Land texels shade the land
 *      surface max(z, 0), sea texels the sea floor min(z, 0), each with its own vertical
 *      exaggeration and gain (gain 0: the sea is a flat 128).
 *   G  ocean depth:     round(255 * sqrt(clamp(depth_m, 0, 8000) / 8000)), 0 on land
 *   B  land elevation:  round(255 * sqrt(clamp(h_m, 0, 6000) / 6000)),   0 at sea
 *
 * Everything is computed per DEM cell and then area-averaged into the output texels
 * (exact box overlaps, also for non-integer ratios): the shade at the DEM's resolution keeps
 * ridges and valleys that a texel-sized slope would smear into a flat grey, and averaging
 * instead of point sampling keeps them from aliasing. depth and height are averaged in metres
 * over the whole texel (land cells count as 0 depth and vice versa), so both taper to 0 at the
 * DEM's shoreline.
 *
 * Slopes are in true metres: a cell is R*dlat tall and R*dlon*cos(lat) wide, so the east-west
 * gradient is not stretched towards the poles. Gradients use Horn's 3x3 operator, with the
 * east-west taps spread to about one cell height of ground; columns wrap, the first and last
 * rows are reused past the poles.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define R_EARTH 6371008.8
#define COS_MIN 0.02            /* caps the east-west tap spread at 50 cells within ~1.1 deg of a pole */

/* Light set: north-west at 45 deg dominates; weaker west and north lights at the same
   altitude, and a sky term (the mean of a ring of 45 deg lights, exact for slopes below 45
   deg), which darkens steep ground of any aspect. With one light, ridges running NW-SE get
   the same shade on both flanks and vanish; the sky term and the side lights keep them. */
static const double LIGHT_AZ[3] = {315.0, 270.0, 0.0};   /* degrees clockwise from north */
static const double LIGHT_W[3] = {0.50, 0.15, 0.15};
static const double SKY_W = 0.20;
static const double ZEN = 45.0;

static void die(const char *m) { fprintf(stderr, "terrainbake: %s\n", m); exit(1); }

static int W, H, C, R;          /* output and DEM sizes */
static int16_t *dem;
static double lx[3], ly[3], lz;  /* unit light vectors, x east, y north */
static double s0;               /* shade of flat ground */

static inline double zat(int i, int j) {
    if (j < 0) j = 0; else if (j > R - 1) j = R - 1;
    i %= C; if (i < 0) i += C;
    return dem[(size_t)j * C + i];
}

/* Shade of the surface h(z) = sign*max(sign*z, 0) at cell (i,j), exaggerated by ve.  The
   east-west taps are e cells apart (e*dx ~ dy), so the slope is measured over the same ground
   distance both ways: near the poles a single cell is a few hundred metres wide and the DEM's
   interpolation steps would read as cliffs. */
static double shade(int i, int j, int e, double sign, double ve, double dx, double dy) {
    double a = fmax(sign * zat(i-e, j-1), 0), b = fmax(sign * zat(i, j-1), 0), c = fmax(sign * zat(i+e, j-1), 0);
    double d = fmax(sign * zat(i-e, j),   0),                                  f = fmax(sign * zat(i+e, j),   0);
    double g = fmax(sign * zat(i-e, j+1), 0), h = fmax(sign * zat(i, j+1), 0), k = fmax(sign * zat(i+e, j+1), 0);
    /* gradient of the real (signed) surface; rows run north to south */
    double gx = sign * ((c + 2*f + k) - (a + 2*d + g)) / (8 * e * dx) * ve;
    double gy = sign * ((a + 2*b + c) - (g + 2*h + k)) / (8 * dy) * ve;
    double n = 1.0 / sqrt(gx*gx + gy*gy + 1.0);              /* normal = (-gx, -gy, 1) * n */
    double s = 0;
    for (int l = 0; l < 3; l++) s += LIGHT_W[l] * fmax(0.0, (-gx*lx[l] - gy*ly[l] + lz) * n);
    s += SKY_W * lz * n;
    /* Relative to flat ground, scaled so a slope facing the light (s = 1) and one in full
       shade (s = 0) are +-1: Lambert alone has 0.29 of headroom above flat and 0.71 below,
       which turns mountains into dark masses with dim highlights. */
    return s >= s0 ? (s - s0) / (1.0 - s0) : (s - s0) / s0;
}

/* Box-filter weights from n source cells to m output cells along one axis.  In source units
   (cell k spans [k, k+1)) output cell o spans [o, o+1) * n/m + off.  wrap: the source axis is
   periodic, otherwise indices clamp to [0, n-1] (the poles). */
typedef struct { int k; float w; } Tap;
typedef struct { int n; Tap *t; } Taps;
static Taps *box(int m, int n, double off, int wrap) {
    Taps *out = calloc(m, sizeof(Taps));
    double s = (double)n / m;
    for (int o = 0; o < m; o++) {
        double a = o * s + off, b = (o + 1) * s + off;
        int k0 = (int)floor(a), k1 = (int)ceil(b) - 1;
        out[o].t = malloc((k1 - k0 + 1) * sizeof(Tap));
        for (int k = k0; k <= k1; k++) {
            double w = (fmin(b, k + 1) - fmax(a, k)) / s;
            if (w <= 0) continue;
            int kk = wrap ? ((k % n) + n) % n : (k < 0 ? 0 : k > n - 1 ? n - 1 : k);
            out[o].t[out[o].n++] = (Tap){kk, (float)w};
        }
    }
    return out;
}

static uint8_t *readpgm(const char *path, int *w, int *h) {
    FILE *f = fopen(path, "rb"); if (!f) die("cannot open land.pgm");
    int mx;
    if (fscanf(f, "P5 %d %d %d", w, h, &mx) != 3 || mx != 255) die("land.pgm: want an 8-bit P5");
    fgetc(f);
    uint8_t *p = malloc((size_t)*w * *h);
    if (fread(p, 1, (size_t)*w * *h, f) != (size_t)*w * *h) die("land.pgm: short read");
    fclose(f);
    return p;
}

static inline uint8_t enc_sqrt(double v, double vmax) {
    return (uint8_t)lrint(255.0 * sqrt(fmin(fmax(v, 0.0), vmax) / vmax));
}
static inline uint8_t enc_shade(double x, double gain) {
    return (uint8_t)(128 + lrint(127.0 * fmax(-1.0, fmin(1.0, gain * x))));
}

static int cmpu8(const void *a, const void *b) { return *(const uint8_t *)a - *(const uint8_t *)b; }
static void stats(const char *name, const uint8_t *px, int ch, const uint8_t *mask, int want) {
    size_t N = (size_t)W * H, n = 0;
    uint8_t *v = malloc(N);
    for (size_t o = 0; o < N; o++) if (mask[o] == want) v[n++] = px[3 * o + ch];
    if (!n) { free(v); return; }
    qsort(v, n, 1, cmpu8);
    double sum = 0; for (size_t o = 0; o < n; o++) sum += v[o];
    fprintf(stderr, "  %-14s n=%-8zu min %3d  p1 %3d  p5 %3d  p25 %3d  p50 %3d  p75 %3d  p95 %3d  p99 %3d  p99.9 %3d  max %3d  mean %.1f\n",
            name, n, v[0], v[n/100], v[n/20], v[n/4], v[n/2], v[3*n/4], v[n*95/100], v[n*99/100], v[n*999/1000], v[n-1], sum / n);
    free(v);
}

int main(int argc, char **argv) {
    if (argc < 10) die("usage: terrainbake dem cols rows lon0 lat0 le|be land.pgm W out.ppm [ve_land ve_sea gain_land gain_sea]");
    C = atoi(argv[2]); R = atoi(argv[3]);
    double lon0 = atof(argv[4]), lat0 = atof(argv[5]);
    int big = strcmp(argv[6], "be") == 0;
    W = atoi(argv[8]); H = W / 2;
    double veL = argc > 10 ? atof(argv[10]) : 2.0, veS = argc > 11 ? atof(argv[11]) : 6.0;
    double gL = argc > 12 ? atof(argv[12]) : 2.5, gS = argc > 13 ? atof(argv[13]) : 2.5;
    if (C <= 0 || R <= 0 || W <= 0 || (W & 1)) die("bad sizes");

    /* DEM */
    size_t NC = (size_t)C * R;
    dem = malloc(NC * sizeof(int16_t));
    FILE *f = strcmp(argv[1], "-") ? fopen(argv[1], "rb") : stdin;
    if (!f || fread(dem, sizeof(int16_t), NC, f) != NC) die("cannot read the DEM");
    if (f != stdin) fclose(f);
    if (big) for (size_t o = 0; o < NC; o++) { uint16_t u = (uint16_t)dem[o]; dem[o] = (int16_t)((u >> 8) | (u << 8)); }
    int zmin = 0, zmax = 0;
    for (size_t o = 0; o < NC; o++) { if (dem[o] < zmin) zmin = dem[o]; if (dem[o] > zmax) zmax = dem[o]; }
    fprintf(stderr, "DEM %dx%d, %d..%d m\n", C, R, zmin, zmax);
    if (zmin < -12000 || zmax > 9000) die("heights out of range: wrong byte order or size?");

    for (int l = 0; l < 3; l++) {
        double az = LIGHT_AZ[l] * M_PI / 180, z = ZEN * M_PI / 180;
        lx[l] = sin(z) * sin(az); ly[l] = sin(z) * cos(az); lz = cos(z);
    }
    s0 = lz;                    /* weights sum to 1 */

    /* cell k covers [lon0 + (k - 0.5) * dlon, ...): in source units the output starts at
       (-180 - lon0) / dlon + 0.5 */
    double dlon = 360.0 / C, dlat = 180.0 / R;
    Taps *tx = box(W, C, (-180.0 - lon0) / dlon + 0.5, 1);
    Taps *ty = box(H, R, (lat0 - 90.0) / dlat + 0.5, 0);
    /* invert ty: for each source row, the output rows it feeds */
    typedef struct { int o; float w; } Feed;
    Feed (*feed)[4] = calloc(R, sizeof *feed); int *nfeed = calloc(R, sizeof(int));
    for (int o = 0; o < H; o++) for (int t = 0; t < ty[o].n; t++) {
        int k = ty[o].t[t].k;
        if (nfeed[k] == 4) die("output finer than the DEM");
        feed[k][nfeed[k]++] = (Feed){o, ty[o].t[t].w};
    }

    /* accumulators per output texel: land shade, sea shade, height, depth, mean z */
    size_t N = (size_t)W * H;
    double *acc = calloc(5 * N, sizeof(double));
    double *row = malloc(5 * (size_t)C * sizeof(double));
    for (int j = 0; j < R; j++) {
        if (!nfeed[j]) continue;
        double lat = lat0 - j * dlat;
        double cl = fmax(cos(lat * M_PI / 180), COS_MIN);
        double dx = R_EARTH * dlon * M_PI / 180 * cl, dy = R_EARTH * dlat * M_PI / 180;
        int e = (int)lrint(dy / dx); if (e < 1) e = 1;
        for (int i = 0; i < C; i++) {
            double z = dem[(size_t)j * C + i];
            double *r = row + 5 * (size_t)i;
            r[0] = shade(i, j, e, 1.0, veL, dx, dy);
            r[1] = gS != 0 ? shade(i, j, e, -1.0, veS, dx, dy) : 0;   /* gain 0: a flat sea */
            r[2] = fmax(z, 0); r[3] = fmax(-z, 0); r[4] = z;
        }
        for (int o = 0; o < W; o++) {
            double v[5] = {0, 0, 0, 0, 0};
            for (int t = 0; t < tx[o].n; t++) {
                const double *r = row + 5 * (size_t)tx[o].t[t].k; double w = tx[o].t[t].w;
                for (int c = 0; c < 5; c++) v[c] += w * r[c];
            }
            for (int q = 0; q < nfeed[j]; q++) {
                double *a = acc + 5 * ((size_t)feed[j][q].o * W + o); double w = feed[j][q].w;
                for (int c = 0; c < 5; c++) a[c] += w * v[c];
            }
        }
    }

    /* land / sea from earth.png, sampled bilinearly at each output texel centre */
    int ew, eh; uint8_t *earth = readpgm(argv[7], &ew, &eh);
    uint8_t *land = malloc(N), *px = malloc(3 * N);
    size_t nland = 0, demSea = 0, demLand = 0, hiWater = 0;
    for (int j = 0; j < H; j++) for (int i = 0; i < W; i++) {
        double u = (i + 0.5) / W * ew - 0.5, v = (j + 0.5) / H * eh - 0.5;
        int i0 = (int)floor(u), j0 = (int)floor(v); double fu = u - i0, fv = v - j0;
        int ia = ((i0 % ew) + ew) % ew, ib = (ia + 1) % ew;
        int ja = j0 < 0 ? 0 : j0 > eh - 1 ? eh - 1 : j0, jb = j0 + 1 > eh - 1 ? eh - 1 : j0 + 1;
        double t = (1 - fv) * ((1 - fu) * earth[(size_t)ja * ew + ia] + fu * earth[(size_t)ja * ew + ib])
                 +      fv  * ((1 - fu) * earth[(size_t)jb * ew + ia] + fu * earth[(size_t)jb * ew + ib]);
        size_t o = (size_t)j * W + i; const double *a = acc + 5 * o;
        uint8_t *p = px + 3 * o;
        land[o] = t > 127.5;
        if (land[o]) {
            nland++; demSea += a[4] <= 0;
            p[0] = enc_shade(a[0], gL); p[1] = 0; p[2] = enc_sqrt(a[2], 6000);
        } else {
            demLand += a[4] > 0; hiWater += a[4] > 200;
            p[0] = enc_shade(a[1], gS); p[1] = enc_sqrt(a[3], 8000); p[2] = 0;
        }
    }
    fprintf(stderr, "W=%d: land %.2f%% (earth.png); DEM disagrees on %zu texels (%.3f%%): "
            "%zu land with mean z <= 0, %zu water with mean z > 0 (%zu of them > 200 m: lakes, ice shelves)\n",
            W, 100.0 * nland / N, demSea + demLand, 100.0 * (demSea + demLand) / N, demSea, demLand, hiWater);
    fprintf(stderr, "ve land %.2f sea %.2f, gain land %.2f sea %.2f\n", veL, veS, gL, gS);
    stats("R land", px, 0, land, 1); stats("R sea", px, 0, land, 0);
    stats("G sea", px, 1, land, 0); stats("B land", px, 2, land, 1);

    FILE *g = fopen(argv[9], "wb"); if (!g) die("cannot write");
    fprintf(g, "P6\n%d %d\n255\n", W, H); fwrite(px, 3, N, g); fclose(g);
    return 0;
}
