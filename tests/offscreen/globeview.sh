#!/bin/sh
# GlobeView offscreen on the real GPU (no window), fed by flightline-feed.
#
#   WORLD_JSON=world.json tests/offscreen/globeview.sh [scene ...]
#   WORLD_JSON=world.json tests/offscreen/globeview.sh drag [seconds] [route]
#
# Scenes: world, europe, sparse (Alice Springs, where the feed hears a handful
# of aircraft; all need WORLD_JSON) and drag (WORLD_JSON; prints CPU per frame while the
# globe is dragged every frame; with "route", JFK-LHR is selected and drawn), idle (WORLD_JSON; frames while nobody touches
# it), interact (WORLD_JSON; camera and picking checks, PASS / FAIL lines),
# hover (WORLD_JSON; GUI-thread ms of the first hover after a new revision),
# labels and route (WORLD_JSON plus the test aircraft of labels-fixture.py:
# label-dense views, and three routes at three zooms).
# PNGs go to $OUT (default tests/offscreen/out). THEME=latte or THEME=gruvbox
# renders with a light or a warm theme instead of Tokyo Night.
# The saved responses are only read (--keep-input); nothing is fetched.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
OUT=${OUT:-$here/out}
mkdir -p "$OUT"

fixture() {  # fixture <name> <raw.json> <query> -> prints the dir
  dir=$OUT/gv-$1
  mkdir -p "$dir" && chmod 700 "$dir"
  "$root/flightline-feed" --in="$2" --out-dir="$dir" --rev=7 --source=adsb.lol --query="$3" \
    --home=-23.8000,133.9000 --radius=100 --keep-input > "$dir/summary.json"
  echo "$dir"
}

run() {  # run <scene> <dir> [seconds]
  timeout "${TIMEOUT:-15}" env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen \
    QT_FORCE_STDERR_LOGGING=1 QML_XHR_ALLOW_FILE_READ=1 \
    /usr/lib/qt6/bin/qml "$here/globeview.qml" -- "$OUT" "$@" ${THEME:+theme=$THEME}
}

if [ "${1:-}" = drag ]; then
  [ -n "${WORLD_JSON:-}" ] || { echo "set WORLD_JSON" >&2; exit 2; }
  secs=${2:-10}
  [ "$secs" -le 10 ] || secs=10
  scene=drag
  if [ "${3:-}" = route ]; then
    scene=dragroute
    python3 "$here/labels-fixture.py" "$WORLD_JSON" "$OUT/labels-world.json"
    world=$(fixture labels "$OUT/labels-world.json" 0,0,10800)
  else
    world=$(fixture world "$WORLD_JSON" 0,0,10800)
  fi
  log=$OUT/gv-$scene.log
  TIMEOUT=$((secs + 8)) run $scene "$world" "$secs" > "$log" 2>&1 &
  pid=$!
  while ! grep -q "bench fps" "$log" 2>/dev/null; do
    kill -0 $pid 2>/dev/null || { cat "$log"; exit 1; }
    sleep 0.2
  done
  qml=$(pgrep -P "$(pgrep -P $pid | head -1)" | head -1)   # timeout -> env -> qml
  [ -n "$qml" ] || qml=$(pgrep -P $pid | head -1)
  threads() { for t in /proc/"$qml"/task/*; do echo "$(tr " " _ < "$t/comm") $(cut -d' ' -f1 "$t/schedstat")"; done 2>/dev/null; }
  # GPU time of this process from DRM fdinfo (ns on the gfx engine, per DRM client), as bench.sh
  gpu() { for f in /proc/"$qml"/fdinfo/*; do awk '/drm-client-id/ {id = $2} /drm-engine-gfx/ {print id, $2}' "$f"; done 2>/dev/null | sort -u | awk '{s += $2} END {print s + 0}'; }
  f1=$(grep -c "bench fps" "$log"); a=$(threads); g1=$(gpu); t1=$(date +%s.%N)
  sleep $((secs - 3))
  f2=$(grep -c "bench fps" "$log"); b=$(threads); g2=$(gpu); t2=$(date +%s.%N)
  wait $pid || true
  frames=$(grep "bench fps" "$log" | sed -n "$((f1 + 1)),${f2}p" | awk '{s += $4} END {print s + 0}')
  grep "bench fps" "$log" | tail -2
  GPU=$((g2 - g1)) FRAMES=$frames T1=$t1 T2=$t2 A="$a" B="$b" python3 - <<'PY'
import os
frames = int(os.environ["FRAMES"] or 0)
dt = float(os.environ["T2"]) - float(os.environ["T1"])
def parse(s):
    out = {}
    for line in s.strip().splitlines():
        name, ns = line.split()
        out[name] = out.get(name, 0) + int(ns)
    return out
a, b = parse(os.environ["A"]), parse(os.environ["B"])
print("window %.1f s, %d frames (%.1f fps)" % (dt, frames, frames / dt))
total = sum(b.values()) - sum(a.values())
print("process CPU %.2f ms per frame" % (total / 1e6 / max(frames, 1)))
print("GPU (gfx engine, this process) %.3f ms per frame" % (int(os.environ["GPU"]) / 1e6 / max(frames, 1)))
for name in sorted(b, key=lambda n: -(b[n] - a.get(n, 0))):
    d = b[name] - a.get(name, 0)
    if d > 0:
        print("  %-16s %.3f ms per frame" % (name, d / 1e6 / max(frames, 1)))
PY
  exit 0
fi

[ $# -gt 0 ] || set -- world europe sparse
status=0
for scene in "$@"; do
  case $scene in
    world|europe|sparse|idle|interact|hover)
      [ -n "${WORLD_JSON:-}" ] || { echo "skip $scene (set WORLD_JSON)"; continue; }
      dir=$(fixture world "$WORLD_JSON" 0,0,10800) ;;
    labels|route)
      [ -n "${WORLD_JSON:-}" ] || { echo "skip $scene (set WORLD_JSON)"; continue; }
      python3 "$here/labels-fixture.py" "$WORLD_JSON" "$OUT/labels-world.json"
      dir=$(fixture labels "$OUT/labels-world.json" 0,0,10800) ;;
    *) echo "unknown scene $scene" >&2; exit 2 ;;
  esac
  echo "== $scene"
  # idle watches the clock for 16 s, hover waits out 8 revisions; the rest is quick
  t=${TIMEOUT:-15}
  case $scene in idle|hover|route) t=${TIMEOUT:-25} ;; esac
  TIMEOUT=$t run "$scene" "$dir" > "$OUT/gv-$scene.log" 2>&1 || { echo "FAIL $scene ($?)"; status=1; }
  grep -E "^qml: |Error|error" "$OUT/gv-$scene.log" | sed 's/^qml: //'
  grep -q "^qml: FAIL" "$OUT/gv-$scene.log" && status=1
done
exit $status
