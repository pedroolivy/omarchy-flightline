#!/usr/bin/env python3
"""Add the label and route test aircraft to a saved feed answer.

    labels-fixture.py world.json out.json

Copies a saved adsb.lol / adsb.fi answer and appends:
  ~0f1001  TST1  JFK -> LHR, 40 % of the way, 30 km north of the great circle
                 (real tracks wander; the route must still pass through the sprite)
  ~0f1002  TST2  SYD -> LAX, 40 % of the way, on the great circle
  ~0f1003  TST3  GRU -> LIS, 40 % of the way, on the great circle
  ~0f1004  EMG77 squawking 7700 over Surrey, for the label priority checks
Each route aircraft heads along its great circle at 480 kt, FL370, just seen.
The input is only read. Python standard library only.
"""
import json
import math
import sys

R = 6371.0088
AIRPORTS = {
    "JFK": (40.6413, -73.7781), "LHR": (51.4700, -0.4543),
    "SYD": (-33.9399, 151.1753), "LAX": (33.9416, -118.4085),
    "GRU": (-23.4356, -46.4731), "LIS": (38.7742, -9.1342),
}
ROUTES = [("~0f1001", "TST1", "JFK", "LHR", 30.0),
          ("~0f1002", "TST2", "SYD", "LAX", 0.0),
          ("~0f1003", "TST3", "GRU", "LIS", 0.0)]


def vec(lat, lon):
    la, lo = math.radians(lat), math.radians(lon)
    return (math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo), math.sin(la))


def latlon(v):
    return math.degrees(math.asin(max(-1.0, min(1.0, v[2])))), math.degrees(math.atan2(v[1], v[0]))


def bearing(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return math.degrees(math.atan2(y, x)) % 360


def destination(p, brg, km):
    d, b = km / R, math.radians(brg)
    p1, l1 = math.radians(p[0]), math.radians(p[1])
    p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(b))
    l2 = l1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * math.sin(p2))
    return math.degrees(p2), (math.degrees(l2) + 540) % 360 - 180


def along(a, b, f):
    """Point at fraction f of the great circle a -> b, and the track there."""
    va, vb = vec(*a), vec(*b)
    w = math.acos(max(-1.0, min(1.0, sum(x * y for x, y in zip(va, vb)))))
    s = math.sin(w)
    p = latlon(tuple((math.sin((1 - f) * w) * x + math.sin(f * w) * y) / s for x, y in zip(va, vb)))
    return p, bearing(p, b)


def aircraft(hex_, cs, lat, lon, track, squawk="2000"):
    return {"hex": hex_, "type": "adsb_icao", "flight": cs.ljust(8), "r": "", "t": "B77W",
            "alt_baro": 37000, "gs": 480.0, "track": round(track, 2), "baro_rate": 0,
            "squawk": squawk, "emergency": "none", "category": "A5",
            "lat": round(lat, 6), "lon": round(lon, 6), "seen_pos": 0.0, "seen": 0.0}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for hex_, cs, a, b, off in ROUTES:
        (lat, lon), trk = along(AIRPORTS[a], AIRPORTS[b], 0.4)
        if off:
            lat, lon = destination((lat, lon), trk - 90, off)
        data["ac"].append(aircraft(hex_, cs, lat, lon, trk))
    data["ac"].append(aircraft("~0f1004", "EMG77", 51.30, -0.42, 250.0, squawk="7700"))
    with open(sys.argv[2], "w") as f:
        json.dump(data, f)


if __name__ == "__main__":
    main()
