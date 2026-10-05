/*
 * sdfbake - bake Flightline globe distance textures from Natural Earth polylines.
 *
 *   sdfbake geo.bin W outdir [land_spread line_spread wide_spread border_eps]
 *
 * Writes 8-bit PGM (P5) planes, all equirectangular W x W/2, texel (i,j) centre at
 *   lon = (i+0.5)*360/W - 180,  lat = 90 - (j+0.5)*180/H.
 *
 *   land.pgm    signed distance to the coast (land minus lakes), + on land.
 *   adm0.pgm    "side-signed" distance to country borders  (sign = side of nearest segment).
 *   adm1.pgm    "side-signed" distance to state/province borders.
 *   wide.pgm    coarse signed distance to the coast (Felzenszwalb EDT on the land mask),
 *               spread = wide_spread texels; for glows, shelves, fog.
 *
 * Distances are exact Euclidean distances to the source segments (not to a raster),
 * measured in a locally isometric metric: one unit = one texel at the equator
 * (40075/W km).  Horizontal offsets are scaled by cos(lat) of the texel.
 *
 * Signed encoding:   byte = round(127.5 + 127.5 * clamp(d / S, -1, 1))
 *   decode (shader): d = (t - 0.5) * 2 * S        with t = byte/255 = texture() value
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int cls; int n; float *xy; } Line;
static Line *lines; static int nlines;
static int W, H;

static void die(const char *m) { fprintf(stderr, "sdfbake: %s\n", m); exit(1); }

static void load(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) die("cannot open geo.bin");
    int cap = 1024; lines = malloc(cap * sizeof(Line));
    uint8_t hdr[8];
    while (fread(hdr, 1, 8, f) == 8) {
        uint32_t n; memcpy(&n, hdr + 4, 4);
        if (nlines == cap) { cap *= 2; lines = realloc(lines, cap * sizeof(Line)); }
        Line *l = &lines[nlines++]; l->cls = hdr[0]; l->n = (int)n;
        l->xy = malloc(8 * (size_t)n);
        if (fread(l->xy, 8, n, f) != n) die("short read");
    }
    fclose(f);
}

static inline double lon2x(double lon) { return (lon + 180.0) / 360.0 * W; }   /* texel units */
static inline double lat2y(double lat) { return (90.0 - lat) / 180.0 * H; }

/* --- Douglas-Peucker in the local texel metric --------------------------------------
   Detail far below one texel cannot be represented by a distance field anyway; leaving it in
   makes the field non-affine inside a cell, which shows up as blobs when the line is magnified. */
static int dp_keep(const float *xy, int a, int b, double eps, uint8_t *keep) {
    int stack[2 * 65536], sp = 0, kept = 0;
    stack[sp++] = a; stack[sp++] = b;
    while (sp) {
        int j = stack[--sp], i = stack[--sp];
        if (j <= i + 1) continue;
        double c = cos(0.5 * (xy[2*i+1] + xy[2*j+1]) * M_PI / 180.0);
        double ax = lon2x(xy[2*i]) * c, ay = lat2y(xy[2*i+1]), bx = lon2x(xy[2*j]) * c, by = lat2y(xy[2*j+1]);
        double dx = bx - ax, dy = by - ay, L2 = dx*dx + dy*dy, best = -1; int bi = -1;
        for (int k = i + 1; k < j; k++) {
            double px = lon2x(xy[2*k]) * c - ax, py = lat2y(xy[2*k+1]) - ay;
            double t = L2 > 0 ? (px*dx + py*dy) / L2 : 0; if (t < 0) t = 0; if (t > 1) t = 1;
            double ex = px - t*dx, ey = py - t*dy, d = ex*ex + ey*ey;
            if (d > best) { best = d; bi = k; }
        }
        if (best > eps * eps && sp < 2 * 65536 - 4) {
            keep[bi] = 1; kept++;
            stack[sp++] = i; stack[sp++] = bi; stack[sp++] = bi; stack[sp++] = j;
        }
    }
    return kept;
}
static void simplify(int clsmask, double eps) {
    long before = 0, after = 0;
    for (int k = 0; k < nlines; k++) {
        Line *l = &lines[k]; if (!((1 << l->cls) & clsmask) || l->n < 3) continue;
        uint8_t *keep = calloc(l->n, 1); keep[0] = keep[l->n - 1] = 1;
        dp_keep(l->xy, 0, l->n - 1, eps, keep);
        int m = 0;
        for (int i = 0; i < l->n; i++) if (keep[i]) { l->xy[2*m] = l->xy[2*i]; l->xy[2*m+1] = l->xy[2*i+1]; m++; }
        before += l->n; after += m; l->n = m; free(keep);
    }
    fprintf(stderr, "simplify mask %#x eps %.2f texel: %ld -> %ld vertices\n", clsmask, eps, before, after);
}

/* --- even-odd rasterisation at texel centres ------------------------------------ */
static void parity(uint8_t *buf, int clsmask) {
    memset(buf, 0, (size_t)W * H);
    for (int k = 0; k < nlines; k++) {
        Line *l = &lines[k]; if (!((1 << l->cls) & clsmask)) continue;
        for (int s = 0; s < l->n; s++) {               /* ring is closed in GeoJSON; also close it */
            int s1 = (s + 1) % l->n;
            double x0 = lon2x(l->xy[2*s]),  y0 = lat2y(l->xy[2*s+1]);
            double x1 = lon2x(l->xy[2*s1]), y1 = lat2y(l->xy[2*s1+1]);
            if (y0 == y1) continue;
            double ya = fmin(y0, y1), yb = fmax(y0, y1);
            int j0 = (int)ceil(ya - 0.5), j1 = (int)ceil(yb - 0.5) - 1;   /* rows with ya <= yc < yb */
            if (j0 < 0) j0 = 0;
            if (j1 > H - 1) j1 = H - 1;
            for (int j = j0; j <= j1; j++) {
                double yc = j + 0.5;
                double xc = x0 + (x1 - x0) * (yc - y0) / (y1 - y0);
                int i = (int)ceil(xc - 0.5);           /* first texel centre right of the crossing */
                if (i < 0) i = 0;
                if (i < W) buf[(size_t)j * W + i] ^= 1;
            }
        }
    }
    for (int j = 0; j < H; j++) { uint8_t a = 0; uint8_t *r = buf + (size_t)j * W;
        for (int i = 0; i < W; i++) { a ^= r[i]; r[i] = a; } }
}

/* --- exact banded distance to segments ------------------------------------------ */
static float *coslat;
/* best: distance (init = big), side: +1/-1 */
static void band(int clsmask, double S, float *best, int8_t *side, int skip_artificial) {
    for (int k = 0; k < nlines; k++) {
        Line *l = &lines[k]; if (!((1 << l->cls) & clsmask)) continue;
        for (int s = 0; s + 1 < l->n; s++) {
            double lo0 = l->xy[2*s], la0 = l->xy[2*s+1], lo1 = l->xy[2*s+2], la1 = l->xy[2*s+3];
            if (skip_artificial) {      /* polygon edges along the antimeridian / south pole are not coast */
                if (fabs(lo0) > 179.9999 && fabs(lo1) > 179.9999 && lo0 == lo1) continue;
                if (la0 < -89.9999 && la1 < -89.9999) continue;
            }
            double ax = lon2x(lo0), ay = lat2y(la0), bx = lon2x(lo1), by = lat2y(la1);
            int j0 = (int)floor(fmin(ay, by) - S - 0.5), j1 = (int)ceil(fmax(ay, by) + S - 0.5);
            if (j0 < 0) j0 = 0;
            if (j1 > H - 1) j1 = H - 1;
            double cmin = 1.0;
            for (int j = j0; j <= j1; j++) if (coslat[j] < cmin) cmin = coslat[j];
            if (cmin < 0.02) cmin = 0.02;
            double ex = S / cmin;
            int i0 = (int)floor(fmin(ax, bx) - ex - 0.5), i1 = (int)ceil(fmax(ax, bx) + ex - 0.5);
            if (i1 - i0 >= W) { i0 = 0; i1 = W - 1; }
            for (int j = j0; j <= j1; j++) {
                double c = coslat[j], ty = j + 0.5;
                double py0 = ay - ty, py1 = by - ty;
                for (int iu = i0; iu <= i1; iu++) {
                    double tx = iu + 0.5;
                    double px0 = (ax - tx) * c, px1 = (bx - tx) * c;
                    double dx = px1 - px0, dy = py1 - py0;
                    double L2 = dx*dx + dy*dy;
                    double t = L2 > 0 ? -(px0*dx + py0*dy) / L2 : 0;
                    if (t < 0) t = 0; else if (t > 1) t = 1;
                    double qx = px0 + t*dx, qy = py0 + t*dy;
                    double d = sqrt(qx*qx + qy*qy);
                    int i = ((iu % W) + W) % W;
                    size_t o = (size_t)j * W + i;
                    if (d < best[o]) {
                        best[o] = (float)d;
                        /* side of the directed segment the texel lies on: cross(b-a, p-a), p = origin */
                        double cr = dx * (-py0) - dy * (-px0);
                        side[o] = (int8_t)(cr >= 0 ? 1 : -1);
                    }
                }
            }
        }
    }
}

static inline uint8_t enc_s(double d, double S) {
    double v = 127.5 + 127.5 * fmax(-1.0, fmin(1.0, d / S));
    return (uint8_t)lrint(v);
}

static void writepgm(const char *dir, const char *name, const uint8_t *p) {
    char path[4096]; snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb"); if (!f) die("cannot write");
    fprintf(f, "P5\n%d %d\n255\n", W, H); fwrite(p, 1, (size_t)W * H, f); fclose(f);
    fprintf(stderr, "  wrote %s\n", path);
}

/* --- Felzenszwalb & Huttenlocher 1-D squared EDT ------------------------------- */
static void edt1d(const double *f, double *d, int n, double w2, int *v, double *z) {
    /* d[q] = min_p w2*(q-p)^2 + f[p]   (Felzenszwalb & Huttenlocher 2012) */
    int k = 0; v[0] = 0; z[0] = -HUGE_VAL; z[1] = HUGE_VAL;
    for (int q = 1; q < n; q++) {
        double s;
        for (;;) {
            int p = v[k];
            s = ((f[q] + w2*(double)q*q) - (f[p] + w2*(double)p*p)) / (2.0 * w2 * (q - p));
            if (s <= z[k]) { k--; continue; }
            break;
        }
        k++; v[k] = q; z[k] = s; z[k+1] = HUGE_VAL;
    }
    k = 0;
    for (int q = 0; q < n; q++) { while (z[k+1] < q) k++; double t = q - v[k]; d[q] = w2*t*t + f[v[k]]; }
}

/* squared distance (isometric metric) from every texel to the nearest texel where m==target;
   horizontal wrap handled by tripling each row. */
static void edt2d(const uint8_t *m, int target, float *out) {
    const double INF = 1e20;
    int n = (W > H ? W : H) * 3 + 2;
    double *f = malloc(n * sizeof(double)), *d = malloc(n * sizeof(double)), *z = malloc((n + 1) * sizeof(double));
    int *v = malloc(n * sizeof(int));
    double *g = malloc((size_t)W * H * sizeof(double));
    for (int i = 0; i < W; i++) {                         /* columns: plain vertical metric */
        for (int j = 0; j < H; j++) f[j] = (m[(size_t)j*W+i] == target) ? 0 : INF;
        edt1d(f, d, H, 1.0, v, z);
        for (int j = 0; j < H; j++) g[(size_t)j*W+i] = d[j];
    }
    for (int j = 0; j < H; j++) {                         /* rows: cos(lat)^2 weight, wrapped */
        double c = coslat[j]; double w2 = c*c; if (w2 < 1e-6) w2 = 1e-6;
        for (int r = 0; r < 3; r++) for (int i = 0; i < W; i++) f[r*W+i] = g[(size_t)j*W+i];
        edt1d(f, d, 3*W, w2, v, z);
        for (int i = 0; i < W; i++) out[(size_t)j*W+i] = (float)d[W+i];
    }
    free(f); free(d); free(z); free(v); free(g);
}

int main(int argc, char **argv) {
    if (argc < 4) die("usage: sdfbake geo.bin W outdir [land_spread line_spread wide_spread border_eps]");
    load(argv[1]); W = atoi(argv[2]); H = W / 2; const char *dir = argv[3];
    double SL = argc > 4 ? atof(argv[4]) : 8, SB = argc > 5 ? atof(argv[5]) : 4, SW = argc > 6 ? atof(argv[6]) : 0;
    double EB = argc > 7 ? atof(argv[7]) : 0;      /* border simplification tolerance, texels */
    if (EB > 0) simplify((1 << 3) | (1 << 4), EB);
    size_t N = (size_t)W * H;
    coslat = malloc(H * sizeof(float));
    for (int j = 0; j < H; j++) coslat[j] = (float)cos((90.0 - (j + 0.5) * 180.0 / H) * M_PI / 180.0);

    uint8_t *land = malloc(N), *isl = malloc(N), *lake = malloc(N), *out = malloc(N);
    parity(land, 1 << 0); parity(isl, 1 << 1); parity(lake, 1 << 2);
    size_t nl = 0;
    for (size_t o = 0; o < N; o++) { land[o] = (land[o] | isl[o]) & !lake[o]; nl += land[o]; }
    fprintf(stderr, "W=%d land texels %.2f%%\n", W, 100.0 * nl / N);
    free(isl); free(lake);

    float *best = malloc(N * sizeof(float)); int8_t *side = malloc(N);

    /* land SDF */
    for (size_t o = 0; o < N; o++) best[o] = 1e9f;
    band((1<<0)|(1<<1)|(1<<2), SL + 1, best, side, 1);
    for (size_t o = 0; o < N; o++) out[o] = enc_s(land[o] ? best[o] : -best[o], SL);
    writepgm(dir, "land.pgm", out);

    /* borders */
    const char *nm[2] = {"adm0.pgm", "adm1.pgm"};
    for (int c = 0; c < 2; c++) {
        for (size_t o = 0; o < N; o++) { best[o] = 1e9f; side[o] = 1; }
        band(1 << (3 + c), SB + 1, best, side, 0);
        for (size_t o = 0; o < N; o++) out[o] = enc_s((side[o] > 0 ? 1 : -1) * best[o], SB);
        writepgm(dir, nm[c], out);
    }

    if (SW > 0) {   /* coarse field from the raster mask (Felzenszwalb EDT), +-0.5 texel bias corrected */
        float *din = malloc(N * sizeof(float)), *dout = malloc(N * sizeof(float));
        edt2d(land, 0, din);    /* for land texels: distance to nearest water texel */
        edt2d(land, 1, dout);   /* for water texels: distance to nearest land texel */
        for (size_t o = 0; o < N; o++) {
            double d = land[o] ? sqrt(din[o]) - 0.5 : -(sqrt(dout[o]) - 0.5);
            out[o] = enc_s(d, SW);
        }
        writepgm(dir, "wide.pgm", out);
        free(din); free(dout);
    }
    return 0;
}
