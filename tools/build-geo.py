#!/usr/bin/env python3
"""Build Flightline's place list (assets/places.json) from Natural Earth GeoJSON.

Natural Earth data is in the public domain (https://www.naturalearthdata.com/).
The plugin never runs this tool; tools/build-textures.sh calls it.

Usage:
  tools/build-geo.py <natural-earth-geojson-dir> <output-assets-dir>

Input (from github.com/nvkelso/natural-earth-vector/geojson):
  ne_10m_populated_places_simple

Output:
  {"v": 1, "places": [[name, lat, lon, minZoom, isCapital], ...]}

sorted by minZoom (Natural Earth's web-map zoom at which the place deserves a
label), capitals first within a zoom level. Coast, lakes and borders are no
longer vector data: they live in the distance-field textures (sdfbake.c).
"""

import json
import os
import sys


def places(path, max_min_zoom):
    """Populated places as [name, lat, lon, minZoom, isCapital]. minZoom is
    Natural Earth's web-map zoom at which the place deserves a label."""
    data = json.load(open(path))
    out = []
    for feature in data["features"]:
        p = feature["properties"]
        min_zoom = p.get("min_zoom")
        if min_zoom is None or min_zoom > max_min_zoom:
            continue
        name = (p.get("name") or "").strip()
        if not name or len(name) > 40:
            continue
        out.append([name, round(p["latitude"], 3), round(p["longitude"], 3),
                    round(float(min_zoom), 1), 1 if p.get("adm0cap") else 0])
    out.sort(key=lambda row: (row[3], -row[4]))
    return out


def write(path, payload):
    with open(path, "w") as handle:
        json.dump(payload, handle, separators=(",", ":"))
    print(f"{path}: {os.path.getsize(path) // 1024} KiB")


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source, target = sys.argv[1], sys.argv[2]
    src = lambda name: os.path.join(source, name + ".geojson")

    write(os.path.join(target, "places.json"), {
        "v": 1,
        "places": places(src("ne_10m_populated_places_simple"), 7.0),
    })


if __name__ == "__main__":
    main()
