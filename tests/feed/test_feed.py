# Run: python3 -m unittest discover -s tests/feed -v
# Exercises flightline-feed: sanitising (including a parity check against
# Model.sanitizeAircraft when node is available), the PPM encoding, meta and
# summary contracts, file handling and speed.
import sys
sys.dont_write_bytecode = True   # no __pycache__ next to the helper in the plugin root
import glob
import importlib.machinery
import importlib.util
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
SCRIPT = os.path.join(ROOT, "flightline-feed")
# Saved feed answers (none are committed: curl them from adsb.lol yourself).
# world.json is a whole-world answer; lol_*.json any regional one.
FIXTURES = os.environ.get("FLIGHTLINE_FIXTURES", os.path.join(HERE, "fixtures"))

REGION_FIXTURES = sorted(glob.glob(os.path.join(FIXTURES, "lol_*.json")))

loader = importlib.machinery.SourceFileLoader("flightline_feed", SCRIPT)
spec = importlib.util.spec_from_loader("flightline_feed", loader)
ff = importlib.util.module_from_spec(spec)
loader.exec_module(ff)

FETCHED_MS = 1791058814001
EPOCH_MS = FETCHED_MS - 300000


def plane(hex_id="abcdef", lat=10.0, lon=20.0, **extra):
  row = {"hex": hex_id, "lat": lat, "lon": lon, "alt_baro": 30000, "gs": 400.0, "track": 90.0}
  row.update(extra)
  return row


def decode_ppm(data):
  """Parse a traffic.ppm back into per-slot field dicts (all 40*256 slots)."""
  header = b"P6\n256 200\n255\n"
  assert data.startswith(header), data[:20]
  pixels = data[len(header):]
  assert len(pixels) == 256 * 200 * 3
  out = []
  for k in range(ff.MAX_CAPACITY):
    b, c = k >> 8, k & 255
    texels = []
    for row in range(5):
      off = ((5 * b + row) * 256 + c) * 3
      texels.append(int.from_bytes(pixels[off:off + 3], "big"))
    track_flags, speed_alt = texels[2], texels[3]
    out.append({
      "lat": texels[0] / 16777215 * 180 - 90,
      "lon": texels[1] / 16777215 * 360 - 180,
      "track": (track_flags >> 8) / 65535 * 360,
      "flags": track_flags & 255,
      "gs": (speed_alt >> 8) / 16,
      "altBand": speed_alt & 255,
      "obsMs": texels[4],
      "raw": texels,
    })
  return out


def convert(rows, rev=1, extra_args=(), now=FETCHED_MS, doc=None):
  """Run the whole pipeline in-process on `rows`; returns summary, ppm, meta."""
  tmp = tempfile.mkdtemp(prefix="flightline-feed-test-")
  try:
    src = os.path.join(tmp, "raw.json")
    with open(src, "w") as handle:
      json.dump(doc if doc is not None else {"ac": rows, "now": now}, handle)
    out = os.path.join(tmp, "out")
    args = ff.parse_args(["--in", src, "--out-dir", out, "--rev", str(rev), "--source", "adsb.lol",
                          "--keep-input"] + list(extra_args))
    summary = ff.process(args, now)
    with open(os.path.join(out, "traffic.ppm"), "rb") as handle:
      ppm = handle.read()
    with open(os.path.join(out, "meta.json")) as handle:
      meta = json.load(handle)
    return summary, ppm, meta
  finally:
    shutil.rmtree(tmp, ignore_errors=True)


def run_cli(args, cwd=None):
  proc = subprocess.run([SCRIPT] + args, capture_output=True, text=True, cwd=cwd, timeout=30)
  line = proc.stdout.strip()
  return proc.returncode, (json.loads(line) if line else None), proc.stderr


class SanitizeTest(unittest.TestCase):
  def test_valid_record_is_normalised(self):
    ac = ff.sanitize_aircraft({
      "hex": "ABCDEF", "flight": "ba123  ", "r": "g-abcd", "t": "a320", "ownOp": "Some Air",
      "category": "A3", "lat": "10.5", "lon": 20, "alt_baro": 34012.4, "gs": 450.2, "track": 725,
      "baro_rate": -1500.4, "squawk": "1200", "emergency": "none", "dbFlags": 1, "seen_pos": 2.5})
    self.assertEqual(ac.hex, "abcdef")
    self.assertEqual((ac.callsign, ac.registration, ac.type, ac.operator, ac.category),
                     ("BA123", "G-ABCD", "A320", "Some Air", "A3"))
    self.assertEqual((ac.lat, ac.lon), (10.5, 20))
    self.assertEqual(ac.alt, 34012)
    self.assertAlmostEqual(ac.track, 5)
    self.assertEqual(ac.vr, -1500)
    self.assertEqual(ac.squawk, "1200")
    self.assertEqual(ac.emergency, "")
    self.assertTrue(ac.military)
    self.assertEqual(ac.seen, 2.5)

  def test_rejects_unplaceable_records(self):
    for bad in [None, 5, "x", [], {}, {"hex": "abcdef"}, plane(hex_id="xyz"), plane(hex_id="abcde"),
                plane(hex_id="abcdef0"), plane(hex_id=123456), plane(lat=91), plane(lat=-91), plane(lon=181),
                plane(lat=None), plane(lat=True), plane(lat="abc"), plane(lat=float("nan")),
                plane(lon=float("inf")), plane(lat=10 ** 400), plane(lat="1_0")]:
      self.assertIsNone(ff.sanitize_aircraft(bad), repr(bad)[:60])

  def test_tisb_hex_prefix_is_kept(self):
    self.assertEqual(ff.sanitize_aircraft(plane(hex_id="~ABCDEF")).hex, "~abcdef")

  def test_ground_and_altitude(self):
    ground = ff.sanitize_aircraft(plane(alt_baro="ground"))
    self.assertTrue(ground.on_ground)
    self.assertEqual(ground.alt, -1)
    self.assertEqual(ff.sanitize_aircraft(plane(alt_baro=None, alt_geom=5000)).alt, 5000)
    self.assertIsNone(ff.sanitize_aircraft(plane(alt_baro=None)).alt)
    self.assertIsNone(ff.sanitize_aircraft(plane(alt_baro="flying")).alt)
    self.assertEqual(ff.sanitize_aircraft(plane(alt_baro=999999)).alt, 80000)
    self.assertEqual(ff.sanitize_aircraft(plane(alt_baro=-9999)).alt, -2000)
    self.assertEqual(ff.sanitize_aircraft(plane(alt_baro=1000.5)).alt, 1001)
    self.assertEqual(ff.sanitize_aircraft(plane(alt_baro=-0.5)).alt, 0)

  def test_speed_track_and_vertical_rate(self):
    ac = ff.sanitize_aircraft(plane(gs=99999, track=None, true_heading=-90, baro_rate=None, geom_rate=99999))
    self.assertEqual(ac.gs, 2500)
    self.assertAlmostEqual(ac.track, 270)
    self.assertEqual(ac.vr, 20000)
    self.assertAlmostEqual(ff.sanitize_aircraft(plane(track=None, mag_heading=45)).track, 45)
    ac = ff.sanitize_aircraft(plane(gs="fast", track=None))
    self.assertIsNone(ac.gs)
    self.assertIsNone(ac.track)
    self.assertEqual(ff.sanitize_aircraft(plane(gs=-5)).gs, 0)
    self.assertAlmostEqual(ff.sanitize_aircraft(plane(track=360)).track, 0)

  def test_seen_pos_falls_back_to_seen_and_is_clamped(self):
    self.assertEqual(ff.sanitize_aircraft(plane(seen_pos=3, seen=9)).seen, 3)
    self.assertEqual(ff.sanitize_aircraft(plane(seen=9)).seen, 9)
    self.assertEqual(ff.sanitize_aircraft(plane(seen_pos=-4)).seen, 0)
    self.assertEqual(ff.sanitize_aircraft(plane(seen_pos=9000)).seen, 600)
    self.assertEqual(ff.sanitize_aircraft(plane()).seen, 0)

  def test_strings_are_validated(self):
    ac = ff.sanitize_aircraft(plane(flight="<b>x</b>", r="N1\u0000 2", t="TOOLONG", squawk="12", category="Z9",
                                    ownOp="A\u0007B\nC" + "x" * 100, emergency="a" * 40))
    self.assertEqual(ac.callsign, "")
    self.assertEqual(ac.registration, "")
    self.assertEqual(ac.type, "TOOL", "over-long values are cut before they are matched, as in v0.1")
    self.assertEqual(ac.squawk, "")
    self.assertEqual(ac.category, "")
    self.assertEqual(ac.operator, "ABC" + "x" * 45)
    self.assertEqual(ac.emergency, "a" * 16)
    self.assertEqual(ff.sanitize_aircraft(plane(squawk="1289")).squawk, "")
    self.assertEqual(ff.sanitize_aircraft(plane(squawk="7700\n")).squawk, "7700")
    self.assertEqual(ff.sanitize_aircraft(plane(flight=1234)).callsign, "1234")
    self.assertEqual(ff.sanitize_aircraft(plane(flight=["A"])).callsign, "")
    self.assertEqual(ff.sanitize_aircraft(plane(flight="ABCDEFGHIJ")).callsign, "ABCDEFGH")
    # C1 controls and bidi/format characters cannot reorder or hide panel text.
    bidi = ff.sanitize_aircraft(plane(ownOp="A\u202eB\u0085C\u200bD\u2066E\ufeffF\u061cG"))
    self.assertEqual(bidi.operator, "ABCDEFG")

  def test_emergency_and_military_flags(self):
    for squawk in ("7500", "7600", "7700"):
      self.assertTrue(ff.sanitize_aircraft(plane(squawk=squawk)).flags & ff.FLAG_EMERGENCY, squawk)
    self.assertFalse(ff.sanitize_aircraft(plane(squawk="7000")).flags & ff.FLAG_EMERGENCY)
    self.assertFalse(ff.sanitize_aircraft(plane(emergency="none")).flags & ff.FLAG_EMERGENCY)
    self.assertTrue(ff.sanitize_aircraft(plane(emergency="lifeguard")).flags & ff.FLAG_EMERGENCY)
    self.assertTrue(ff.sanitize_aircraft(plane(dbFlags=3)).flags & ff.FLAG_MILITARY)
    self.assertFalse(ff.sanitize_aircraft(plane(dbFlags=2)).flags & ff.FLAG_MILITARY)
    self.assertFalse(ff.sanitize_aircraft(plane(dbFlags="x")).flags & ff.FLAG_MILITARY)
    self.assertTrue(ff.sanitize_aircraft(plane(alt_baro="ground")).flags & ff.FLAG_GROUND)
    self.assertEqual(ff.sanitize_aircraft(plane()).flags & 7, 0)

  def test_glyph_classes(self):
    expected = {
      "A1": 2, "A2": 0, "A3": 0, "A4": 1, "A5": 1, "A7": 3, "A0": 0, "A6": 0,
      "B1": 4, "B2": 4, "B4": 4, "B6": 4, "B3": 4, "B7": 4,
      "C0": 5, "C1": 5, "C2": 5, "C3": 5, "": 0, "D1": 0}
    for category, glyph in expected.items():
      ac = ff.sanitize_aircraft(plane(category=category))
      self.assertEqual((ac.flags >> 3) & 7, glyph, category)
      self.assertEqual(ac.flags >> 6, 0, "reserved bits stay zero")

  def test_duplicates_and_garbage_rows_are_dropped(self):
    rows = [plane("aaaaaa"), plane("aaaaaa", lat=11), None, {"hex": "bbbbbb"}, plane("cccccc")]
    aircraft, dropped = ff.parse_feed({"ac": rows})
    self.assertEqual([a.hex for a in aircraft], ["aaaaaa", "cccccc"])
    self.assertEqual(aircraft[0].lat, 10.0, "first record wins")
    self.assertEqual(dropped, 3)

  def test_feed_shapes(self):
    self.assertEqual(len(ff.parse_feed({"aircraft": [plane()]})[0]), 1)
    self.assertEqual(ff.parse_feed({"ac": []})[0], [])
    for bad in [[], "x", None, {}, {"ac": None}, {"ac": "x"}, {"message": "rate limited"}]:
      with self.assertRaises(ff.FeedError):
        ff.parse_feed(bad)


class ModelParityTest(unittest.TestCase):
  """The Python sanitiser must agree with v0.1's Model.sanitizeAircraft."""

  CORPUS = [
    plane(flight="ABC123  ", r="pt-xyz", t="b738", category="A3", squawk="7700", emergency="general"),
    plane(alt_baro="ground", gs=3.2, track=181.5, seen=4.2),
    plane(alt_baro=None, alt_geom=12000.6, true_heading=359.99, geom_rate=-640.5),
    plane(lat="-23.7", lon="133.88", gs="450", track="720", baro_rate="12.5"),
    plane(hex_id="~ABCDEF", seen_pos=900, seen=3),
    plane(gs=1e9, baro_rate=-1e9, alt_baro=-5000),
    plane(squawk="12345", flight="TOOLONGCALLSIGN", r="BAD REG", t="A320x"),
    plane(ownOp="A" * 60, dbFlags=5, emergency="none"),
    plane(flight="<script>", category="E1", alt_baro="flying"),
    plane(flight=" x1 ", t=" b738 ", squawk=" 1234 ", emergency="  lifeguard  "),
    plane(lat=90, lon=-180, mag_heading=-1),
    plane(lat=0, lon=0, track=None, gs=None, alt_baro=0),
    {"hex": "abcdef", "lat": 1, "lon": 200},
    {"hex": "zzzzzz", "lat": 1, "lon": 2},
    {"lat": 1, "lon": 2},
  ]

  def js_results(self, rows):
    script = (
      "const fs=require('fs'),vm=require('vm');"
      "const src=fs.readFileSync(process.argv[1],'utf8').replace(/^\\.pragma library\\s*/,'');"
      "const M={};vm.createContext(M);vm.runInContext(src,M);"
      "const rows=JSON.parse(fs.readFileSync(0,'utf8'));"
      "process.stdout.write(JSON.stringify(rows.map(r=>{const a=M.sanitizeAircraft(r,0);"
      "if(!a)return null;a.positionTimeMs=-a.positionTimeMs/1000;return a;})))")
    proc = subprocess.run(["node", "-e", script, os.path.join(ROOT, "Model.js")],
                          input=json.dumps(rows), capture_output=True, text=True, timeout=60)
    self.assertEqual(proc.returncode, 0, proc.stderr)
    return json.loads(proc.stdout)

  def compare(self, rows):
    js_rows = self.js_results(rows)
    for raw, js in zip(rows, js_rows):
      py = ff.sanitize_aircraft(raw)
      label = json.dumps(raw)[:100]
      if js is None or py is None:
        self.assertEqual(js is None, py is None, label)
        continue
      self.assertEqual(py.hex, js["hex"], label)
      self.assertEqual(py.callsign, js["callsign"], label)
      self.assertEqual(py.registration, js["registration"], label)
      self.assertEqual(py.type, js["type"], label)
      self.assertEqual(py.operator, js["operator"], label)
      self.assertEqual(py.category, js["category"], label)
      self.assertEqual(py.squawk, js["squawk"], label)
      self.assertEqual(py.emergency, js["emergency"], label)
      self.assertEqual(py.military, js["military"], label)
      self.assertEqual(py.on_ground, js["onGround"], label)
      self.assertAlmostEqual(py.lat, js["lat"], places=9, msg=label)
      self.assertAlmostEqual(py.lon, js["lon"], places=9, msg=label)
      # v0.1 reports 0 ft on the ground, the meta contract says -1.
      self.assertEqual(py.alt, -1 if js["onGround"] else js["altitudeFt"], label)
      for mine, theirs in ((py.gs, js["groundSpeedKt"]), (py.track, js["track"]), (py.vr, js["verticalRateFpm"])):
        if theirs is None:
          self.assertIsNone(mine, label)
        else:
          self.assertAlmostEqual(mine, theirs, places=6, msg=label)
      self.assertAlmostEqual(py.seen, js["positionTimeMs"], places=6, msg=label)

  @unittest.skipUnless(shutil.which("node"), "node not installed")
  def test_corpus(self):
    self.compare(self.CORPUS)

  @unittest.skipUnless(shutil.which("node"), "node not installed")
  def test_random_records(self):
    rng = random.Random(7)
    values = [None, 0, -1, 1.5, 360, 721.25, "12", " 7 ", "", "abc", True, [], {}, 1e12, -1e12,
              "ground", "none", "7700", "A3", "ab12", "ABCDEF"]
    keys = ["hex", "flight", "r", "t", "ownOp", "category", "lat", "lon", "alt_baro", "alt_geom", "gs", "track",
            "true_heading", "mag_heading", "baro_rate", "geom_rate", "squawk", "emergency", "dbFlags",
            "seen_pos", "seen"]
    rows = []
    for _ in range(400):
      row = plane(flight="X1")
      for key in rng.sample(keys, 6):
        row[key] = rng.choice(values)
      # Booleans stringify as "true" in JS; the feeds never send them.
      rows.append({k: v for k, v in row.items() if v is not True})
    self.compare(rows)

  @unittest.skipUnless(shutil.which("node") and os.path.exists(os.path.join(FIXTURES, "world.json")),
                       "node or world.json fixture missing")
  def test_real_world_feed(self):
    with open(os.path.join(FIXTURES, "world.json")) as handle:
      rows = json.load(handle)["ac"][:3000]
    self.compare(rows)


class EncodingTest(unittest.TestCase):
  def test_round_trip_within_quantisation(self):
    rows = [
      plane("000001", lat=-23.7, lon=133.88, alt_baro=36000, gs=451.3, track=41.7, seen_pos=1.5, category="A3"),
      plane("000002", lat=51.47, lon=-0.45, alt_baro=1250, gs=120.0, track=359.9, seen_pos=0, category="A5",
            squawk="7700", dbFlags=1),
      plane("000003", lat=-89.99, lon=179.99, alt_baro=0, gs=0, track=0, seen_pos=250, category="A7"),
      plane("000004", lat=89.99, lon=-179.99, alt_baro=80000, gs=2500, track=180, category="B2"),
      plane("000005", lat=0, lon=0, alt_baro="ground", gs=12, track=270, category="C2"),
    ]
    summary, ppm, meta = convert(rows)
    self.assertEqual(len(ppm), len(b"P6\n256 200\n255\n") + 256 * 200 * 3)
    slots = decode_ppm(ppm)
    self.assertEqual(summary["n"], 5)
    by_hex = {h: k for k, h in enumerate(meta["hex"])}
    for raw in rows:
      k = by_hex[raw["hex"]]
      px = slots[k]
      self.assertAlmostEqual(px["lat"], raw["lat"], delta=180 / 16777215)
      lon_expected = raw["lon"]
      self.assertAlmostEqual(px["lon"], lon_expected, delta=360 / 16777215)
      self.assertAlmostEqual(px["track"], raw["track"], delta=360 / 65535)
      self.assertAlmostEqual(px["gs"], raw["gs"], delta=1 / 16)
      if raw["alt_baro"] == "ground":
        self.assertEqual(px["altBand"], 0)
        self.assertTrue(px["flags"] & ff.FLAG_GROUND)
      else:
        self.assertAlmostEqual(px["altBand"] * 250, min(raw["alt_baro"], 63750), delta=125)
      seen = raw.get("seen_pos", 0)
      self.assertAlmostEqual(px["obsMs"], 300000 - seen * 1000, delta=1)
      self.assertAlmostEqual(meta["t"][k], 300 - seen, delta=0.05)
    # flags: bit1 emergency + bit2 military, glyph class 1 (heavy) in bits 3-5.
    self.assertEqual(slots[by_hex["000002"]]["flags"], 2 | 4 | (1 << 3))
    self.assertEqual(slots[by_hex["000001"]]["flags"], 0)
    self.assertEqual(slots[by_hex["000003"]]["flags"], 3 << 3)
    self.assertEqual(slots[by_hex["000004"]]["flags"], 4 << 3)
    self.assertEqual(slots[by_hex["000005"]]["flags"], 1 | (5 << 3))
    # Altitude above the 8-bit band range saturates at 255.
    self.assertEqual(slots[by_hex["000004"]]["altBand"], 255)

  def test_unused_slots_are_zero_and_size_is_fixed(self):
    _, ppm, _ = convert([plane("000001"), plane("000002", lat=11)])
    slots = decode_ppm(ppm)
    self.assertTrue(all(s["raw"] == [0, 0, 0, 0, 0] for s in slots[2:]))
    self.assertTrue(any(s["raw"][0] for s in slots[:2]))
    _, empty, meta = convert([])
    self.assertEqual(len(empty), len(ppm))
    self.assertEqual(meta["n"], 0)
    self.assertEqual(meta["hex"], [])

  def test_exact_texel_values(self):
    _, ppm, meta = convert([plane("00000a", lat=0, lon=0, alt_baro=10000, gs=100, track=90, seen_pos=10,
                                  category="A1")])
    raw = decode_ppm(ppm)[0]["raw"]
    self.assertEqual(raw[0], round(90 / 180 * 16777215))
    self.assertEqual(raw[1], round(180 / 360 * 16777215))
    self.assertEqual(raw[2], (round(90 / 360 * 65535) << 8) | (2 << 3))
    self.assertEqual(raw[3], (1600 << 8) | 40)
    self.assertEqual(raw[4], 290000)
    # Row 0 of pixel 0 is the first pixel after the header: big-endian RGB.
    start = len(b"P6\n256 200\n255\n")
    self.assertEqual(ppm[start:start + 3], raw[0].to_bytes(3, "big"))

  def test_longitude_wraps_at_the_antimeridian(self):
    _, ppm, _ = convert([plane("00000a", lon=180), plane("00000b", lon=-180, lat=11)])
    slots = decode_ppm(ppm)
    self.assertEqual(slots[0]["raw"][1], 0)
    self.assertEqual(slots[1]["raw"][1], 0)

  def test_missing_track_or_speed_does_not_move(self):
    _, ppm, meta = convert([plane("00000a", track=None, gs=300), plane("00000b", track=10, gs=None, lat=11)])
    slots = decode_ppm(ppm)
    self.assertEqual(slots[0]["gs"], 0)
    self.assertEqual(slots[1]["gs"], 0)
    self.assertIsNone(meta["trk"][0])
    self.assertEqual(meta["gs"][0], 300)
    self.assertIsNone(meta["gs"][1])

  def test_speed_saturates(self):
    _, ppm, _ = convert([plane(gs=2500)])
    self.assertEqual(decode_ppm(ppm)[0]["raw"][3] >> 8, 40000)

  def test_second_block_addressing(self):
    rows = [plane("%06x" % (i + 1), lat=-80 + 160 * i / 599, lon=-170 + 340 * i / 599, alt_baro=1000 + i,
                  gs=100 + i % 400, track=i % 360)
            for i in range(600)]
    _, ppm, meta = convert(rows)
    slots = decode_ppm(ppm)
    self.assertEqual(meta["n"], 600)
    for k in (0, 255, 256, 257, 511, 512, 599):
      raw = rows[meta["hex"].index("%06x" % (int(meta["hex"][k], 16)))]
      self.assertAlmostEqual(slots[k]["lat"], raw["lat"], delta=1e-5)
      self.assertAlmostEqual(slots[k]["lon"], raw["lon"], delta=1.1e-5)
    self.assertTrue(all(s["raw"] == [0, 0, 0, 0, 0] for s in slots[600:]))

  def test_old_observations_clamp_to_epoch(self):
    _, ppm, meta = convert([plane(seen_pos=500)])
    self.assertEqual(decode_ppm(ppm)[0]["obsMs"], 0)
    self.assertEqual(meta["t"][0], 0)


class OrderingAndCapacityTest(unittest.TestCase):
  def test_ground_first_then_ascending_altitude(self):
    rows = [
      plane("00000a", alt_baro=35000), plane("00000b", alt_baro="ground", lat=11),
      plane("00000c", alt_baro=5000, lat=12), plane("00000d", alt_baro=None, lat=13),
      plane("00000e", alt_baro="ground", lat=14), plane("00000f", alt_baro=-300, lat=15),
      plane("000010", alt_baro=35000, lat=16),
    ]
    _, _, meta = convert(rows)
    self.assertEqual(meta["hex"], ["00000b", "00000e", "00000d", "00000f", "00000c", "00000a", "000010"])
    self.assertEqual(meta["alt"], [-1, -1, None, -300, 5000, 35000, 35000])

  def test_capacity_keeps_closest_to_query_centre(self):
    rows = [plane("%06x" % (i + 1), lat=i * 0.5, lon=0, alt_baro=10000 + i) for i in range(40)]
    summary, ppm, meta = convert(rows, extra_args=["--capacity", "10", "--query=0,0,3000"])
    self.assertEqual(meta["n"], 10)
    self.assertEqual(summary["n"], 10)
    self.assertEqual(summary["dropped"], 30)
    self.assertEqual(sorted(meta["lat"]), [i * 0.5 for i in range(10)])
    # Centred elsewhere, a different set survives.
    _, _, meta = convert(rows, extra_args=["--capacity", "10", "--query=19.5,0,3000"])
    self.assertEqual(sorted(meta["lat"]), [i * 0.5 for i in range(30, 40)])

  def test_capacity_drops_ground_traffic_first(self):
    rows = [plane("%06x" % (i + 1), lat=i * 0.5, lon=0, alt_baro=10000 + i) for i in range(10)]
    rows += [plane("%06x" % (i + 100), lat=0.1 * i, lon=0, alt_baro="ground") for i in range(5)]
    summary, _, meta = convert(rows, extra_args=["--capacity", "12", "--query=0,0,3000"])
    self.assertEqual(summary["airborne"], 10, "every airborne aircraft is kept")
    self.assertEqual(meta["alt"].count(-1), 2, "the two ground aircraft closest to the centre stay")
    self.assertEqual(sorted(meta["hex"][:2]), ["000064", "000065"])

  def test_records_beyond_the_limit_are_not_read(self):
    rows = [plane("%06x" % (i + 1), lat=(i % 160) - 80, lon=0) for i in range(ff.MAX_RECORDS + 7)]
    summary, _, _ = convert(rows, extra_args=["--capacity", "10"])
    self.assertEqual(summary["n"], 10)
    self.assertEqual(summary["dropped"], ff.MAX_RECORDS + 7 - 10)

  def test_capacity_wraps_around_the_antimeridian(self):
    rows = [plane("000001", lat=0, lon=179), plane("000002", lat=0, lon=-179), plane("000003", lat=0, lon=0)]
    _, _, meta = convert(rows, extra_args=["--capacity", "2", "--query=0,180,500"])
    self.assertEqual(sorted(meta["hex"]), ["000001", "000002"])

  def test_default_capacity_is_the_texture_size(self):
    rng = random.Random(3)
    rows = [plane("%06x" % (i + 1), lat=rng.uniform(-80, 80), lon=rng.uniform(-180, 180), alt_baro=rng.randint(0, 40000))
            for i in range(10400)]
    summary, ppm, meta = convert(rows)
    self.assertEqual(meta["n"], 10240)
    self.assertEqual(summary["dropped"], 160)
    slots = decode_ppm(ppm)
    self.assertTrue(all(s["raw"][0] for s in slots))

  def test_capacity_above_texture_is_refused(self):
    with self.assertRaises(ff.FeedError):
      ff.parse_args(["--in", "x", "--out-dir", "y", "--rev", "1", "--source", "s", "--capacity", "10241"])


class SummaryTest(unittest.TestCase):
  def test_home_count_and_nearest(self):
    home = (10.0, 20.0)
    rows = [
      plane("000001", lat=10.5, lon=20.0, alt_baro=30000),                        # ~55.6 km north
      plane("000002", lat=10.0, lon=20.2, alt_baro=20000, flight="NEAR2"),        # ~21.9 km east
      plane("000003", lat=9.9, lon=20.0, alt_baro="ground"),                      # ground: ignored
      plane("000004", lat=10.0, lon=19.0, alt_baro=10000),                        # ~109.5 km west
      plane("000005", lat=12.0, lon=20.0, alt_baro=10000),                        # ~222 km: outside 100 NM
      plane("000006", lat=9.4, lon=20.0, alt_baro=None),                          # ~66.7 km south; unknown alt counts as airborne
    ]
    summary, _, meta = convert(rows, extra_args=["--home=10,20", "--radius=100"])
    h = summary["home"]
    self.assertEqual((h["lat"], h["lon"], h["radiusNm"]), (10, 20, 100))
    self.assertEqual(h["count"], 4)
    self.assertEqual([n["hex"] for n in h["nearest"]], ["000002", "000001", "000006", "000004"])
    first = h["nearest"][0]
    self.assertAlmostEqual(first["km"], 21.9, delta=0.2)
    self.assertAlmostEqual(first["brg"], 90.0, delta=0.5)
    self.assertEqual(first["cs"], "NEAR2")
    second = h["nearest"][1]
    self.assertAlmostEqual(second["km"], 55.6, delta=0.2)
    self.assertAlmostEqual(second["brg"], 0.0, delta=0.5)
    west = h["nearest"][3]
    self.assertAlmostEqual(west["brg"], 270.0, delta=0.5)
    for row in h["nearest"]:
      self.assertEqual(meta["hex"][row["i"]], row["hex"])
      self.assertEqual(meta["alt"][row["i"]], row["alt"])
    for key in ("i", "hex", "cs", "ty", "rg", "op", "lat", "lon", "alt", "gs", "trk", "vr", "km", "brg"):
      self.assertIn(key, first)

  def test_nearest_is_limited_to_eight(self):
    rows = [plane("%06x" % (i + 1), lat=10 + i * 0.01, lon=20) for i in range(30)]
    summary, _, _ = convert(rows, extra_args=["--home=10,20", "--radius=250"])
    self.assertEqual(summary["home"]["count"], 30)
    self.assertEqual(len(summary["home"]["nearest"]), 8)
    kms = [n["km"] for n in summary["home"]["nearest"]]
    self.assertEqual(kms, sorted(kms))

  def test_radius_edge_across_the_antimeridian(self):
    rows = [plane("000001", lat=0, lon=-179.9), plane("000002", lat=0, lon=-175)]
    summary, _, _ = convert(rows, extra_args=["--home=0,179.9", "--radius=50"])
    self.assertEqual([n["hex"] for n in summary["home"]["nearest"]], ["000001"])
    self.assertAlmostEqual(summary["home"]["nearest"][0]["km"], 22.2, delta=0.2)
    self.assertAlmostEqual(summary["home"]["nearest"][0]["brg"], 90, delta=0.5)

  def test_no_home_no_query(self):
    summary, _, _ = convert([plane()])
    self.assertIsNone(summary["home"])
    self.assertIsNone(summary["query"])
    self.assertEqual(set(summary), {"ok", "rev", "source", "epochMs", "fetchedMs", "n", "airborne", "dropped",
                                    "query", "home", "emergencies", "maxGs"})

  def test_query_basics_and_times(self):
    summary, _, meta = convert([plane()], rev=12, extra_args=["--query=0,0,10800"])
    self.assertEqual(summary["query"], {"lat": 0, "lon": 0, "radiusNm": 10800})
    self.assertEqual(summary["rev"], 12)
    self.assertEqual(summary["source"], "adsb.lol")
    self.assertEqual(summary["fetchedMs"], FETCHED_MS)
    self.assertEqual(summary["epochMs"], FETCHED_MS - 300000)
    self.assertEqual((meta["rev"], meta["epochMs"]), (12, FETCHED_MS - 300000))

  def test_airborne_and_max_gs(self):
    rows = [plane("000001", alt_baro="ground", gs=900), plane("000002", gs=410.4, lat=11),
            plane("000003", gs=612.4, lat=12), plane("000004", gs=700, track=None, lat=13)]
    summary, _, _ = convert(rows)
    self.assertEqual(summary["n"], 4)
    self.assertEqual(summary["airborne"], 3)
    # Ground traffic and aircraft without a track (they do not move) are ignored.
    self.assertEqual(summary["maxGs"], 612)
    self.assertEqual(convert([])[0]["maxGs"], 0)

  def test_max_gs_ignores_one_bad_report(self):
    rows = [plane("%06x" % (i + 1), lat=i * 0.01, gs=400 + i % 50) for i in range(400)]
    rows.append(plane("ffffff", gs=2400))
    self.assertEqual(convert(rows)[0]["maxGs"], 449)
    # Few aircraft: the real maximum, but never above 1000 kt.
    self.assertEqual(convert([plane(gs=2400)])[0]["maxGs"], 1000)

  def test_nearest_any_when_nothing_is_inside(self):
    rows = [plane("000001", lat=10, lon=20), plane("000002", lat=12, lon=20),
            plane("000003", lat=0, lon=0, alt_baro="ground"), plane("000004", lat=40, lon=20)]
    summary, _, _ = convert(rows, extra_args=["--home=0,0", "--radius=50"])
    h = summary["home"]
    self.assertEqual(h["count"], 0)
    self.assertEqual([r["hex"] for r in h["nearestAny"]], ["000001", "000002", "000004"], "airborne only, closest first")
    self.assertGreater(h["nearestAny"][0]["km"], 2000)
    summary, _, _ = convert(rows, extra_args=["--home=10,20", "--radius=50"])
    self.assertEqual(summary["home"]["nearestAny"], [], "only when the circle is empty")

  def test_emergencies(self):
    rows = [plane("000001", squawk="7700", flight="MAYDAY1", alt_baro=12000),
            plane("000002", squawk="7500", lat=11), plane("000003", squawk="7600", lat=12, alt_baro="ground"),
            plane("000004", emergency="minfuel", lat=13), plane("000005", squawk="1200", lat=14),
            plane("000006", emergency="none", lat=15)]
    summary, _, meta = convert(rows)
    got = {e["hex"]: e for e in summary["emergencies"]}
    self.assertEqual(set(got), {"000001", "000002", "000003", "000004"})
    self.assertEqual(got["000001"]["sq"], "7700")
    self.assertEqual(got["000001"]["cs"], "MAYDAY1")
    self.assertEqual(got["000001"]["alt"], 12000)
    self.assertEqual(got["000003"]["alt"], -1)
    for e in summary["emergencies"]:
      self.assertEqual(meta["hex"][e["i"]], e["hex"])
      self.assertTrue(meta["flags"][e["i"]] & ff.FLAG_EMERGENCY)

  def test_summary_stays_small(self):
    rows = [plane("%06x" % (i + 1), lat=10 + i * 0.001, squawk="7700", flight="LONGCS%d" % (i % 10), ownOp="Op" * 24)
            for i in range(200)]
    summary, _, _ = convert(rows, extra_args=["--home=10,20", "--radius=250", "--query=10,20,250"])
    self.assertLess(len(json.dumps(summary, separators=(",", ":"))), 8192)
    self.assertEqual(len(summary["emergencies"]), ff.EMERGENCY_LIMIT)

  def test_meta_contract(self):
    rows = [plane("00000a", flight="CS1", t="B738", r="PR-ABC", ownOp="Op", squawk="1234", category="A3",
                  alt_baro="ground", gs=3, track=None, baro_rate=64),
            plane("00000b", lat=11, alt_baro=None, gs=None, track=359.123456, baro_rate=None, geom_rate=None)]
    _, _, meta = convert(rows)
    keys = ["hex", "cs", "ty", "rg", "op", "lat", "lon", "alt", "gs", "trk", "t", "vr", "sq", "cat", "flags"]
    self.assertEqual(set(meta), set(keys) | {"rev", "epochMs", "n"})
    for key in keys:
      self.assertEqual(len(meta[key]), 2, key)
    self.assertEqual(meta["cs"][0], "CS1")
    self.assertEqual(meta["ty"][0], "B738")
    self.assertEqual(meta["rg"][0], "PR-ABC")
    self.assertEqual(meta["op"][0], "Op")
    self.assertEqual(meta["sq"][0], "1234")
    self.assertEqual(meta["cat"][0], "A3")
    self.assertEqual(meta["alt"], [-1, None])
    self.assertEqual(meta["trk"], [None, 359.12])
    self.assertEqual(meta["gs"], [3, None])
    self.assertEqual(meta["vr"], [64, None])
    self.assertEqual(meta["lat"][1], 11)


class CliTest(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.mkdtemp(prefix="flightline-feed-cli-")
    self.addCleanup(shutil.rmtree, self.tmp, True)
    self.out = os.path.join(self.tmp, "run", "flightline")

  def write_raw(self, doc, name="raw-1.json", inside=False):
    # inside: in the out dir, where Service.qml puts the raw answer.
    if inside:
      os.makedirs(self.out, 0o700, exist_ok=True)
    path = os.path.join(self.out if inside else self.tmp, name)
    with open(path, "w") as handle:
      handle.write(doc if isinstance(doc, str) else json.dumps(doc))
    return path

  def feed(self, path, *extra):
    return run_cli(["--in", path, "--out-dir", self.out, "--rev", "5", "--source", "adsb.lol"] + list(extra))

  def test_success_end_to_end(self):
    path = self.write_raw({"ac": [plane("000001", lat=-23.9, lon=133.8, flight="QFA1492 ")], "now": 1}, inside=True)
    code, summary, _ = self.feed(path, "--home=-23.7,133.88", "--radius=100", "--query=-23.7,133.88,250")
    self.assertEqual(code, 0)
    self.assertTrue(summary["ok"])
    self.assertEqual(summary["home"]["nearest"][0]["cs"], "QFA1492")
    self.assertEqual(sorted(os.listdir(self.out)), ["meta.json", "traffic.ppm"], "the raw input is deleted afterwards")
    self.assertEqual(os.stat(self.out).st_mode & 0o777, 0o700)
    self.assertEqual(os.stat(os.path.join(self.out, "traffic.ppm")).st_mode & 0o777, 0o600)
    self.assertFalse(os.path.exists(path), "the raw input is deleted afterwards")
    with open(os.path.join(self.out, "traffic.ppm"), "rb") as handle:
      self.assertEqual(len(handle.read()), 153615)

  def test_keep_input(self):
    path = self.write_raw({"ac": []}, inside=True)
    self.assertEqual(self.feed(path, "--keep-input")[0], 0)
    self.assertTrue(os.path.exists(path))

  def test_input_outside_the_out_dir_is_never_deleted(self):
    # A saved fixture passed by hand must survive, on success and on failure.
    good = self.write_raw({"ac": [plane()]}, "saved.json")
    bad = self.write_raw("not json", "broken.json")
    self.assertEqual(self.feed(good)[0], 0)
    self.assertEqual(self.feed(bad)[0], 2)
    self.assertTrue(os.path.exists(good) and os.path.exists(bad))

  def test_reuse_replaces_previous_files(self):
    first = self.write_raw({"ac": [plane("000001")]}, "a.json")
    second = self.write_raw({"ac": [plane("000002"), plane("000003", lat=1)]}, "b.json")
    self.feed(first)
    code, summary, _ = self.feed(second)
    self.assertEqual((code, summary["n"]), (0, 2))
    with open(os.path.join(self.out, "meta.json")) as handle:
      self.assertEqual(json.load(handle)["n"], 2)
    self.assertEqual(sorted(os.listdir(self.out)), ["meta.json", "traffic.ppm"])

  def test_garbage_input_exits_2(self):
    cases = ["", "not json", "{", "[]", "null", "42", '{"ac": "x"}', '{"message": "rate limited"}',
             "[" * 100000, '{"ac": [' + "{" * 50 + "]}", "\x00\x01\x02", '{"ac":[1,"x",null,[],{"hex":5}]}x']
    for i, doc in enumerate(cases):
      path = self.write_raw(doc, "g%d.json" % i, inside=True)
      code, summary, _ = self.feed(path)
      self.assertEqual(code, 2, repr(doc)[:40])
      self.assertFalse(summary["ok"], repr(doc)[:40])
      self.assertTrue(summary["error"])
      self.assertFalse(os.path.exists(path))
    self.assertEqual(os.listdir(self.out), [], "no output on failure")

  def test_garbage_rows_are_survivable(self):
    path = self.write_raw({"ac": [1, "x", None, [], {"hex": 5}, {"hex": "abcdef", "lat": "x"}, plane("000001")]})
    code, summary, _ = self.feed(path)
    self.assertEqual((code, summary["n"], summary["dropped"]), (0, 1, 6))

  def test_binary_input(self):
    path = os.path.join(self.tmp, "bin.json")
    with open(path, "wb") as handle:
      handle.write(bytes(range(256)) * 10)
    code, summary, _ = self.feed(path)
    self.assertEqual(code, 2)
    self.assertFalse(summary["ok"])

  def test_missing_input(self):
    code, summary, _ = self.feed(os.path.join(self.tmp, "nope.json"))
    self.assertEqual(code, 2)
    self.assertFalse(summary["ok"])

  def test_directory_input_is_refused_and_kept(self):
    path = os.path.join(self.tmp, "dir.json")
    os.mkdir(path)
    code, summary, _ = self.feed(path)
    self.assertEqual(code, 2)
    self.assertTrue(os.path.isdir(path))

  def test_oversize_input_is_refused(self):
    path = os.path.join(self.tmp, "big.json")
    with open(path, "wb") as handle:
      handle.truncate(16 * 1024 * 1024 + 1)
    code, summary, _ = self.feed(path)
    self.assertEqual(code, 2)
    self.assertEqual(summary["error"], "input too large")

  def test_bad_arguments_exit_2_with_json(self):
    path = self.write_raw({"ac": []})
    base = ["--in", path, "--out-dir", self.out, "--rev", "1", "--source", "x"]
    for extra in (["--home=1,2"], ["--home=95,2", "--radius=5"], ["--home=a,b", "--radius=5"],
                  ["--radius=-1"], ["--query=1,2"], ["--query=1,2,0"], ["--capacity", "-1"],
                  ["--capacity", "x"], ["--bogus"], ["--home=nan,2", "--radius=5"]):
      code, summary, _ = run_cli(base + extra)
      self.assertEqual(code, 2, extra)
      self.assertFalse(summary["ok"], extra)
    code, summary, _ = run_cli(["--in", path])
    self.assertEqual((code, summary["ok"]), (2, False))
    code, summary, _ = run_cli(["--in", path, "--out-dir", self.out, "--rev", "-1", "--source", "x"])
    self.assertEqual(code, 2)
    self.assertTrue(os.path.exists(path), "bad arguments never delete the input")

  def test_fetched_ms_is_the_request_start(self):
    now = int(time.time() * 1000)
    path = self.write_raw({"ac": [plane(seen_pos=10)]})
    code, summary, _ = self.feed(path, "--fetched-ms=%d" % (now - 4000))
    self.assertEqual(code, 0)
    self.assertLess(abs(summary["fetchedMs"] - (now - 4000)), 50)
    # Never later than now, never more than two minutes back.
    self.assertLessEqual(self.feed(path, "--fetched-ms=%d" % (now + 600000))[1]["fetchedMs"], int(time.time() * 1000))
    self.assertGreaterEqual(self.feed(path, "--fetched-ms=0")[1]["fetchedMs"], now - 120000)

  def test_source_name_is_sanitised(self):
    path = self.write_raw({"ac": []})
    code, summary, _ = run_cli(["--in", path, "--out-dir", self.out, "--rev", "1", "--source", "bad name\n<x>"])
    self.assertEqual((code, summary["source"]), (0, "unknown"))

  def test_out_dir_symlink_is_refused(self):
    target = os.path.join(self.tmp, "elsewhere")
    os.mkdir(target)
    link = os.path.join(self.tmp, "link")
    os.symlink(target, link)
    path = self.write_raw({"ac": [plane()]})
    code, summary, _ = run_cli(["--in", path, "--out-dir", link, "--rev", "1", "--source", "x"])
    self.assertEqual(code, 3)
    self.assertFalse(summary["ok"])
    self.assertEqual(os.listdir(target), [])

  def test_output_symlinks_are_replaced_not_followed(self):
    os.makedirs(self.out)
    victim = os.path.join(self.tmp, "victim")
    with open(victim, "w") as handle:
      handle.write("precious")
    os.symlink(victim, os.path.join(self.out, "traffic.ppm"))
    os.symlink(victim, os.path.join(self.out, "meta.json"))
    path = self.write_raw({"ac": [plane()]})
    code, summary, _ = self.feed(path)
    self.assertEqual(code, 0)
    with open(victim) as handle:
      self.assertEqual(handle.read(), "precious")
    self.assertFalse(os.path.islink(os.path.join(self.out, "traffic.ppm")))
    self.assertFalse(os.path.islink(os.path.join(self.out, "meta.json")))

  def test_loose_out_dir_is_tightened(self):
    os.makedirs(self.out)
    os.chmod(self.out, 0o777)
    self.assertEqual(self.feed(self.write_raw({"ac": []}))[0], 0)
    self.assertEqual(os.stat(self.out).st_mode & 0o777, 0o700)

  def test_unwritable_out_dir_exits_3(self):
    blocker = os.path.join(self.tmp, "file")
    with open(blocker, "w") as handle:
      handle.write("x")
    code, summary, _ = run_cli(["--in", self.write_raw({"ac": []}), "--out-dir", os.path.join(blocker, "sub"),
                                "--rev", "1", "--source", "x"])
    self.assertEqual(code, 3)
    self.assertFalse(summary["ok"])

  def test_stdout_is_one_line(self):
    proc = subprocess.run([SCRIPT, "--in", self.write_raw({"ac": [plane()]}), "--out-dir", self.out, "--rev", "1",
                           "--source", "x", "--home=10,20", "--radius=100"], capture_output=True, text=True)
    self.assertEqual(proc.stdout.count("\n"), 1)
    self.assertEqual(proc.stderr, "")

  def test_script_is_executable_python3(self):
    self.assertTrue(os.access(SCRIPT, os.X_OK))
    with open(SCRIPT) as handle:
      self.assertEqual(handle.readline().strip(), "#!/usr/bin/env python3")


def synthetic_world(count=9400, seed=11):
  rng = random.Random(seed)
  cats = ["A1", "A3", "A3", "A3", "A5", "A2", "A7", "B1", "C2", ""]
  rows = []
  for i in range(count):
    rows.append({
      "hex": "%06x" % (0x100000 + i * 7), "type": "adsb_icao", "flight": "TST%04d " % i, "r": "XX-%03d" % (i % 1000),
      "t": rng.choice(["B738", "A320", "C172", "A359", "E190"]), "alt_baro": rng.choice(["ground", rng.randint(0, 43000)]),
      "alt_geom": 1000, "gs": rng.uniform(0, 600), "track": rng.uniform(0, 360), "baro_rate": 0, "squawk": "1200",
      "emergency": "none", "category": rng.choice(cats), "lat": rng.uniform(-80, 80), "lon": rng.uniform(-180, 180),
      "seen_pos": rng.uniform(0, 30), "seen": 0.1, "messages": 100, "rssi": -20.5, "mlat": [], "tisb": []})
  return {"ac": rows, "now": FETCHED_MS, "total": count}


class PerformanceTest(unittest.TestCase):
  BUDGET_S = 0.5

  def time_cli(self, path):
    tmp = tempfile.mkdtemp(prefix="flightline-feed-perf-")
    try:
      best = None
      for _ in range(3):
        start = time.perf_counter()
        code, summary, _ = run_cli(["--in", path, "--out-dir", os.path.join(tmp, "o"), "--rev", "1", "--source", "adsb.lol",
                                    "--home=-23.7,133.88", "--radius=100", "--query=0,0,10800", "--keep-input"])
        elapsed = time.perf_counter() - start
        self.assertEqual(code, 0)
        best = elapsed if best is None else min(best, elapsed)
      return best, summary
    finally:
      shutil.rmtree(tmp, ignore_errors=True)

  def check(self, path, label):
    elapsed, summary = self.time_cli(path)
    size = os.path.getsize(path) / 1e6
    print("\n  %s: %.1f MB, %d aircraft, %.3f s wall (best of 3, whole process)" % (label, size, summary["n"], elapsed),
          file=sys.stderr)
    self.assertLess(elapsed, self.BUDGET_S)
    return summary

  def test_synthetic_world(self):
    path = os.path.join(tempfile.mkdtemp(prefix="flightline-feed-perf-"), "world.json")
    self.addCleanup(shutil.rmtree, os.path.dirname(path), True)
    with open(path, "w") as handle:
      json.dump(synthetic_world(), handle)
    self.assertEqual(self.check(path, "synthetic world")["n"], 9400)

  @unittest.skipUnless(os.path.exists(os.path.join(FIXTURES, "world.json")), "world.json fixture missing")
  def test_real_world(self):
    summary = self.check(os.path.join(FIXTURES, "world.json"), "real world.json")
    self.assertGreater(summary["n"], 9000)
    self.assertGreater(summary["maxGs"], 400)

  @unittest.skipUnless(REGION_FIXTURES, "no lol_*.json regional fixture")
  def test_real_region(self):
    for path in REGION_FIXTURES:
      summary = self.check(path, "real " + os.path.basename(path))
      self.assertGreater(summary["n"], 100)

  @unittest.skipUnless(os.path.exists(os.path.join(FIXTURES, "world.json")), "world.json fixture missing")
  def test_real_world_decodes_back_to_the_input(self):
    with open(os.path.join(FIXTURES, "world.json")) as handle:
      rows = json.load(handle)["ac"]
    summary, ppm, meta = convert(rows, extra_args=["--query=0,0,10800"])
    slots = decode_ppm(ppm)
    expected = {}
    for raw in rows:
      ac = ff.sanitize_aircraft(raw)
      if ac is not None:
        expected.setdefault(ac.hex, ac)
    self.assertEqual(summary["n"], len(expected))
    for k in range(summary["n"]):
      ac = expected[meta["hex"][k]]
      px = slots[k]
      self.assertAlmostEqual(px["lat"], ac.lat, delta=180 / 16777215)
      self.assertAlmostEqual(px["lon"], ac.lon, delta=360 / 16777215)
      if ac.track is not None and ac.gs is not None:
        self.assertAlmostEqual(px["gs"], ac.gs, delta=1 / 16)
        self.assertLessEqual(abs((px["track"] - ac.track + 180) % 360 - 180), 360 / 65535)
      if not ac.on_ground and ac.alt is not None:
        self.assertAlmostEqual(px["altBand"] * 250, min(max(ac.alt, 0), 63750), delta=125)
      self.assertEqual(bool(px["flags"] & ff.FLAG_GROUND), ac.on_ground)
      self.assertAlmostEqual(px["obsMs"], 300000 - ac.seen * 1000, delta=1)
    alts = [a for a, g in zip(meta["alt"], [s["flags"] & 1 for s in slots]) if a is not None and not g]
    self.assertEqual(alts, sorted(alts), "airborne aircraft ascend in altitude")
    ground = [bool(s["flags"] & 1) for s in slots[:summary["n"]]]
    self.assertEqual(ground, sorted(ground, reverse=True), "ground traffic comes first")


if __name__ == "__main__":
  unittest.main()
