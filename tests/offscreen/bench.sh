#!/bin/sh
# CPU and GPU per frame while the globe moves every frame (tests/offscreen/bench.qml),
# offscreen on the real GPU. Needs WORLD_JSON (see run.sh).
#
#   WORLD_JSON=world.json tests/offscreen/bench.sh [seconds]      (default 8, max 10)
#
# Env:  W, H     window size (default 1000 x 800; the user's monitor is 3440 x 1440)
#       RADIUS   breathe (default, the v2.0 bench) | fit | cover, see bench.qml
#       LAYERS   all (default) | globe (no aircraft layer)
#       SPRITE   bench (default, the v2.0 sprite size) | app (GlobeView's size at that zoom)
#
# The GPU number swings with the integrated GPU's clock (a single globe at 60 fps
# leaves it near its 800 MHz floor) and with what the desktop draws meanwhile:
# compare trees with interleaved runs, never against a number from another hour.
#
# The same script runs on a v2.0 tree (copy it there): bench.qml only touches
# v2.1 properties when the tree has them.
#
# Samples the on-CPU time of every thread (/proc/<pid>/task/*/schedstat, ns)
# between the 2nd and the last second, and divides by the frames drawn.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$here/out}
secs=${1:-8}
[ "$secs" -le 10 ] || secs=10
[ -n "${WORLD_JSON:-}" ] || { echo "set WORLD_JSON" >&2; exit 2; }
mkdir -p "$OUT"
# shellcheck disable=SC2046  # feed2ppm.py prints two numbers (count, epoch): split on purpose
set -- $("$here/feed2ppm.py" "$WORLD_JSON" "$OUT/world.ppm")
log=$OUT/bench.log
env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 QSG_INFO=1 \
  timeout $((secs + 6)) /usr/lib/qt6/bin/qml "$here/bench.qml" -- "$OUT" "world:$1:$2" "$secs" \
  "${W:-1000}" "${H:-800}" "${RADIUS:-breathe}" "${LAYERS:-all}" "${SPRITE:-bench}" > "$log" 2>&1 &
pid=$!

# wait for the first fps line, then measure until the process is about to quit
while ! grep -q "bench fps" "$log" 2>/dev/null; do
  kill -0 $pid 2>/dev/null || { cat "$log"; exit 1; }
  sleep 0.2
done
qml=$(pgrep -P $pid | head -1)                # timeout's child: the qml process
threads() { for t in /proc/"$qml"/task/*; do echo "$(tr " " _ < "$t/comm") $(cut -d' ' -f1 "$t/schedstat")"; done 2>/dev/null; }
# GPU time of this process from DRM fdinfo (ns on the gfx engine, per DRM client)
gpu() { for f in /proc/"$qml"/fdinfo/*; do awk '/drm-client-id/ {id = $2} /drm-engine-gfx/ {print id, $2}' "$f"; done 2>/dev/null | sort -u | awk '{s += $2} END {print s + 0}'; }
f1=$(grep -c "bench fps" "$log"); a=$(threads); g1=$(gpu); t1=$(date +%s.%N)
sleep $((secs - 2))
f2=$(grep -c "bench fps" "$log"); b=$(threads); g2=$(gpu); t2=$(date +%s.%N)
wait $pid || true

frames=$(grep "bench fps" "$log" | sed -n "$((f1 + 1)),${f2}p" | awk '{s += $4} END {print s}')
grep -E "render loop|Using sg animation driver|threaded|basic" "$log" | head -3
grep "bench fps" "$log" | tail -2
GPU=$((g2 - g1)) CLK=1000000000 FRAMES=$frames T1=$t1 T2=$t2 A="$a" B="$b" python3 - <<'PY'
import os
clk, frames = int(os.environ["CLK"]), int(os.environ["FRAMES"] or 0)
dt = float(os.environ["T2"]) - float(os.environ["T1"])
def parse(s):
    out = {}
    for line in s.strip().splitlines():
        name, ticks = line.split()
        out.setdefault(name, []).append(int(ticks))
    return {k: sum(v) for k, v in out.items()}
a, b = parse(os.environ["A"]), parse(os.environ["B"])
total = sum(b.values()) - sum(a.values())
print("window %.1f s, %d frames (%.1f fps)" % (dt, frames, frames / dt))
print("process CPU %.1f %% = %.2f ms per frame" % (100.0 * total / clk / dt, 1000.0 * total / clk / max(frames, 1)))
print("GPU (gfx engine, this process) %.2f ms per frame" % (int(os.environ["GPU"]) / 1e6 / max(frames, 1)))
for name in sorted(b, key=lambda n: -(b[n] - a.get(n, 0))):
    d = b[name] - a.get(name, 0)
    if d:
        print("  %-16s %.2f ms per frame" % (name, 1000.0 * d / clk / max(frames, 1)))
PY
