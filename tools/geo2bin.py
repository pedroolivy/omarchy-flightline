#!/usr/bin/env python3
"""Flatten Natural Earth GeoJSON into a tiny binary polyline file for sdfbake.

Record layout (little endian):  u8 class, u8 pad, u16 pad, u32 n, then n x (f32 lon, f32 lat)
Classes: 0 land ring, 1 minor-island ring, 2 lake ring, 3 admin-0 line, 4 admin-1 line.
Usage: geo2bin.py <ne_dir> <out.bin> [W]
W is the width of the texture the lakes will be baked into (0 = keep every lake).
A lake is kept only if the bake can draw it: at least CORE_MIN texel centres (and
CORE_FRAC of its area) must lie CORE_DIST texels or more inside its shore.  Thin,
dendritic water (most reservoirs: Furnas, Tres Marias, Itaipu, Lake Nasser, also
Saimaa and the Alpine lakes at 4096) has no such core; a distance field one texel
coarser than the water turns it into a cloud of coastline blobs.
"""
import json, math, struct, sys, os

NE = sys.argv[1]
OUT = sys.argv[2]
W = int(sys.argv[3]) if len(sys.argv) > 3 else 0
H = W // 2
CORE_DIST, CORE_MIN, CORE_FRAC = 0.5, 3, 0.15

# Which features to keep.  Natural Earth ships a 1 m "Null island" polygon at 0,0
# in ne_10m_land; it is a joke feature and must not end up on the globe.
SOURCES = [
    (0, "ne_10m_land", lambda p: (p.get("featurecla") or "Land") != "Null island"),
    (1, "ne_10m_minor_islands", lambda p: True),
    (2, "ne_10m_lakes", lambda p: True),
    (3, "ne_10m_admin_0_boundary_lines_land",
        lambda p: p.get("FEATURECLA") not in ("Lease limit", "Overlay limit", "Unrecognized")),
    (4, "ne_10m_admin_1_states_provinces_lines",
        lambda p: p.get("FEATURECLA") == "Admin-1 boundary"),
]


def ring_km2(ring):
    """Planar area of a lon/lat ring on a sphere (equal-area approximation, fine for lakes)."""
    R = 6371.0088
    a = 0.0
    for (x0, y0), (x1, y1) in zip(ring, ring[1:] + ring[:1]):
        a += math.radians(x1 - x0) * (2 + math.sin(math.radians(y0)) + math.sin(math.radians(y1)))
    return abs(a) * R * R / 2


def core_texels(poly):
    """Texel centres (same grid and metric as sdfbake: one unit = one texel at the equator,
    x scaled by cos(lat)) inside the polygon and at least CORE_DIST from every ring."""
    segs = []
    for ring in poly:
        pts = [((lon + 180.0) / 360.0 * W, (90.0 - lat) / 180.0 * H) for lon, lat in ring]
        segs += list(zip(pts, pts[1:] + pts[:1]))
    ys = [y for s in segs for (_, y) in s]
    n = 0
    for j in range(max(0, int(min(ys))), min(H, int(max(ys)) + 1)):
        yc = j + 0.5
        c = math.cos(math.radians(90.0 - yc * 180.0 / H))
        xs = sorted(x0 + (x1 - x0) * (yc - y0) / (y1 - y0)
                    for (x0, y0), (x1, y1) in segs if (y0 <= yc) != (y1 <= yc))
        near = [s for s in segs if min(s[0][1], s[1][1]) - CORE_DIST <= yc <= max(s[0][1], s[1][1]) + CORE_DIST]
        for a, b in zip(xs[0::2], xs[1::2]):              # even-odd spans: holes are islands
            for i in range(math.ceil(a - 0.5), math.ceil(b - 0.5)):
                xc = i + 0.5
                for (x0, y0), (x1, y1) in near:
                    px, py, dx, dy = (x0 - xc) * c, y0 - yc, (x1 - x0) * c, y1 - y0
                    L2 = dx * dx + dy * dy
                    t = max(0.0, min(1.0, -(px * dx + py * dy) / L2)) if L2 > 0 else 0.0
                    if math.hypot(px + t * dx, py + t * dy) < CORE_DIST:
                        break
                else:
                    n += 1
    return n


dropped = []


def drawable(poly, name):
    texel_km2 = (40075.0 / W) ** 2
    area = ring_km2(poly[0]) / texel_km2                  # in equatorial texels
    if area < math.pi * CORE_DIST * CORE_DIST:
        return False
    n = core_texels(poly)
    if n >= CORE_MIN and n >= CORE_FRAC * area:
        return True
    if area >= 3:
        dropped.append(f"{name or '?'} ({area:.0f} texels, core {n})")
    return False


def polygons(geom):
    t, c = geom["type"], geom["coordinates"]
    if t == "Polygon":
        yield c
    elif t == "MultiPolygon":
        yield from c


def parts(geom, cls, props):
    if cls == 2 and W > 0:
        for poly in polygons(geom):
            if drawable(poly, props.get("name")):
                yield from poly
        return
    t, c = geom["type"], geom["coordinates"]
    if t == "Polygon":
        yield from c
    elif t == "MultiPolygon":
        for poly in c:
            yield from poly
    elif t == "LineString":
        yield c
    elif t == "MultiLineString":
        yield from c


def chain(pieces):
    """Join line pieces that meet end-to-end at degree-2 nodes into long, consistently
    oriented polylines.  Natural Earth stores borders as many short pieces with arbitrary
    direction; every direction flip would flip the 'side' sign the shader relies on."""
    key = lambda p: (round(p[0], 7), round(p[1], 7))
    ends = {}
    for i, pc in enumerate(pieces):
        ends.setdefault(key(pc[0]), []).append((i, 0))
        ends.setdefault(key(pc[-1]), []).append((i, 1))
    used = [False] * len(pieces)
    out = []

    def extend(line, at_end):
        while True:
            k = key(line[-1] if at_end else line[0])
            nb = [e for e in ends.get(k, []) if not used[e[0]]]
            if len(ends.get(k, [])) != 2 or len(nb) != 1:
                return line
            j, which = nb[0]
            used[j] = True
            seg = pieces[j] if which == 0 else pieces[j][::-1]   # seg now starts at k
            if at_end:
                line = line + seg[1:]
            else:
                line = seg[::-1][:-1] + line
    for i, pc in enumerate(pieces):
        if used[i]:
            continue
        used[i] = True
        line = extend(list(pc), True)
        line = extend(line, False)
        out.append(line)
    return out


stats = {}
with open(OUT, "wb") as out:
    for cls, name, keep in SOURCES:
        path = os.path.join(NE, name + ".geojson")
        data = json.load(open(path))
        nrec = nvert = 0
        lines = []
        for f in data["features"]:
            g = f.get("geometry")
            props = f.get("properties") or {}
            if not g or not keep(props):
                continue
            lines.extend(parts(g, cls, props))
        if cls >= 3:
            n0 = len(lines)
            lines = chain(lines)
            print(f"  {name}: chained {n0} pieces into {len(lines)} polylines")
        for line in lines:
            if len(line) < 2:
                continue
            out.write(struct.pack("<BBHI", cls, 0, 0, len(line)))
            out.write(struct.pack("<%df" % (2 * len(line)),
                                  *[v for pt in line for v in (pt[0], pt[1])]))
            nrec += 1
            nvert += len(line)
        stats[name] = (nrec, nvert)
for k, (r, v) in stats.items():
    print(f"{k:42s} {r:6d} parts {v:8d} vertices")
if dropped:
    print(f"  dropped {len(dropped)} lakes too thin for W={W} (>= 3 texels): " + ", ".join(dropped[:12])
          + (" ..." if len(dropped) > 12 else ""))
