#!/bin/sh
# The aircraft layers' offscreen tests on the real GPU (no window):
#   aircraft-checks.qml  trail heads against sprites, antimeridian, limb, stale, ground
#   aircraft-glyphs.qml  every glyph class at 7, 10 and 14 px, three palettes
#   aircraft-scenes.qml  GlobeView's stack over a real world answer (needs WORLD_JSON)
#
#   [WORLD_JSON=world.json] tests/offscreen/aircraft.sh
#
# Env: OUT (default tests/offscreen/out), TIMEOUT per run (default 25 s).
# Prints where the trail head and the sprite put the deadreckon aircraft
# (both must be within half a pixel of x = 208.73).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$here/out}
mkdir -p "$OUT"
export PYTHONDONTWRITEBYTECODE=1
run() {  # run <test.qml> <args...>
  qml=$1
  shift
  timeout "${TIMEOUT:-25}" env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen \
    QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qml "$here/$qml" -- "$OUT" "$@" 2>&1 | grep -v "^qt\.\|^  " || true
}
pack() {  # pack <name> <raw.json> -> name:count:epochMs
  set -- "$1" $(python3 "$here/feed2ppm.py" "$2" "$OUT/$1.ppm")
  echo "$1:$2:$3"
}

dr=$(pack deadreckon "$here/fixtures/deadreckon.json")
run aircraft-checks.qml "$dr" "$(pack edge "$here/aircraft-edge.json")"
glyphs=$(pack glyphs "$here/aircraft-glyphs.json")
for palette in dark light warm; do run aircraft-glyphs.qml "$glyphs" "$palette"; done
if [ -n "${WORLD_JSON:-}" ]; then
  world=$(pack world "$WORLD_JSON")
  for palette in dark light warm; do run aircraft-scenes.qml "$world" "$palette" 3440 1440; done
fi

# The trail's round end reaches 1 px past its head, the sprite's nose 7.16 px
# (0.895 half-sizes at spritePx 8) past its centre.
for f in check-head-trail check-head-sprite; do magick "$OUT/$f.png" -colorspace gray -depth 8 "$OUT/$f.pgm"; done
OUT=$OUT python3 - <<'PY'
import os
def right_edge(name):
    data = open(os.path.join(os.environ["OUT"], name + ".pgm"), "rb").read().split(b"\n", 3)
    w, h = map(int, data[1].split())
    px = data[3]
    base = px[0]
    # coverage-weighted right edge: the last lit column plus its coverage
    edge = 0.0
    for y in range(h):
        for x in range(w):
            v = (px[y * w + x] - base) / (255 - base)
            if v > 0.02:
                edge = max(edge, x + min(1.0, v))
    return edge
trail = right_edge("check-head-trail") - 1.0
sprite = right_edge("check-head-sprite") - 0.895 * 8
print("head x: trail %.2f, sprite %.2f, expected 208.73" % (trail, sprite))
PY
