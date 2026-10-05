#!/bin/sh
# GPU and CPU per frame of the aircraft layers, globe or region zoom
# (tests/offscreen/aircraft-bench.qml), offscreen on the real GPU.
#
#   WORLD_JSON=world.json tests/offscreen/aircraft-bench.sh [layers] [seconds] [W] [H] [NM]
#
# layers: globe | sprites | all (default all), seconds: default 10 (max 10),
# size: default 3440 x 1440 (the user's monitor), NM: visible radius (default:
# the whole globe at GlobeView's fit radius). Run it on the same machine for
# "globe", "sprites" and "all": the differences are the cost of each layer.
#
# GPU: drm-engine-gfx (ns) summed over the process's DRM clients
# (/proc/<pid>/fdinfo, one line per distinct drm-client-id), delta between the
# 2nd second and the end, divided by the frames drawn meanwhile.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$here/out}
layers=${1:-all}
secs=${2:-10}
[ "$secs" -le 10 ] || secs=10
w=${3:-3440}
h=${4:-1440}
nm=${5:-0}
[ -n "${WORLD_JSON:-}" ] || { echo "set WORLD_JSON" >&2; exit 2; }
mkdir -p "$OUT"
set -- $(PYTHONDONTWRITEBYTECODE=1 python3 "$here/feed2ppm.py" "$WORLD_JSON" "$OUT/world.ppm")
log=$OUT/aircraft-bench-$layers-$nm.log
env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
  timeout $((secs + 8)) /usr/lib/qt6/bin/qml "$here/aircraft-bench.qml" -- "$OUT" "world:$1:$2" "$secs" "$w" "$h" "$layers" "$nm" \
  > "$log" 2>&1 &
pid=$!

while ! grep -q "bench fps" "$log" 2>/dev/null; do
  kill -0 $pid 2>/dev/null || { cat "$log"; exit 1; }
  sleep 0.2
done
qml=$(pgrep -P $pid | head -1)                # timeout's child: the qml process
cpu() { awk '{print $14 + $15}' "/proc/$qml/stat"; }
gpu() { for f in /proc/$qml/fdinfo/*; do awk '/drm-client-id/ {id = $2} /drm-engine-gfx/ {print id, $2}' "$f"; done 2>/dev/null | sort -u | awk '{s += $2} END {print s + 0}'; }
f1=$(grep -c "bench fps" "$log"); c1=$(cpu); g1=$(gpu); t1=$(date +%s.%N)
sleep $((secs - 2))
f2=$(grep -c "bench fps" "$log"); c2=$(cpu); g2=$(gpu); t2=$(date +%s.%N)
wait $pid || true

frames=$(grep "bench fps" "$log" | sed -n "$((f1 + 1)),${f2}p" | awk '{s += $4} END {print s + 0}')
grep "bench fps" "$log" | tail -1
GPU=$((g2 - g1)) CPU=$((c2 - c1)) HZ=$(getconf CLK_TCK) FRAMES=$frames T1=$t1 T2=$t2 LAYERS=$layers python3 - <<'PY'
import os
frames = max(int(os.environ["FRAMES"]), 1)
dt = float(os.environ["T2"]) - float(os.environ["T1"])
cpu = int(os.environ["CPU"]) / int(os.environ["HZ"])
print("%s: %d frames in %.1f s (%.1f fps), GPU %.3f ms per frame, CPU %.2f ms per frame"
      % (os.environ["LAYERS"], frames, dt, frames / dt, int(os.environ["GPU"]) / 1e6 / frames, 1000 * cpu / frames))
PY
