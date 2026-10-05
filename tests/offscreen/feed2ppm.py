#!/usr/bin/env python3
"""Test-only: pack a saved adsb.lol / adsb.fi response into traffic.ppm.

Written straight from the data-texture section of docs/ARCHITECTURE.md (not
from flightline-feed), so the offscreen renders also check that the shader and
the contract agree. No sanitising, no meta.json: use flightline-feed for that.

Usage:
  tests/offscreen/feed2ppm.py RAW.json OUT.ppm      prints "<count> <epochMs>"
"""

import json
import sys

W, H, CAPACITY = 256, 200, 10240
GLYPHS = {"A1": 2, "A2": 0, "A3": 0, "A4": 1, "A5": 1, "A7": 3}


def glyph(category):
    category = category or ""
    if category in GLYPHS:
        return GLYPHS[category]
    return {"B": 4, "C": 5}.get(category[:1], 0)


def main(raw_path, out_path):
    raw = json.load(open(raw_path))
    now = float(raw["now"])
    epoch = now - 300000
    rows = []
    for a in raw.get("ac", []):
        lat, lon = a.get("lat"), a.get("lon")
        if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)):
            continue
        ground = a.get("alt_baro") == "ground"
        alt = a.get("alt_baro") if isinstance(a.get("alt_baro"), (int, float)) else a.get("alt_geom")
        alt = 0 if ground or not isinstance(alt, (int, float)) else alt
        track = a.get("track")
        gs = a.get("gs") if isinstance(track, (int, float)) and isinstance(a.get("gs"), (int, float)) else 0
        emergency = a.get("squawk") in ("7500", "7600", "7700") or a.get("emergency", "none") not in ("none", None)
        flags = (1 if ground else 0) | (2 if emergency else 0) | (4 if a.get("dbFlags", 0) & 1 else 0)
        flags |= glyph(a.get("category")) << 3
        seen = a.get("seen_pos", a.get("seen", 0)) or 0
        rows.append((-1 if ground else alt, lat, lon, track or 0, gs, flags, now - seen * 1000))
    rows.sort(key=lambda r: r[0])                        # ground first, then by altitude
    rows = rows[:CAPACITY]

    buf = bytearray(W * H * 3)

    def put(k, row, v):
        i = ((5 * (k >> 8) + row) * W + (k & 255)) * 3
        buf[i:i + 3] = bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255))

    for k, (alt, lat, lon, track, gs, flags, obs) in enumerate(rows):
        put(k, 0, round((lat + 90) / 180 * 16777215))
        put(k, 1, round(((lon + 180) % 360) / 360 * 16777215))
        put(k, 2, (round((track % 360) / 360 * 65535) << 8) | flags)
        put(k, 3, (min(65535, round(gs * 16)) << 8) | (0 if alt < 0 else max(0, min(255, round(alt / 250)))))
        put(k, 4, max(0, min(16777215, round(obs - epoch))))
    with open(out_path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (W, H))
        f.write(buf)
    print(len(rows), int(epoch))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
