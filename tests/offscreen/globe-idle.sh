#!/bin/sh
# Globe idle frames, keepTextures and texture VRAM (tests/offscreen/globe-idle.qml),
# offscreen on the real GPU. VRAM is drm-total-vram summed over the process's
# DRM clients (/proc/<pid>/fdinfo, one line per distinct drm-client-id), at the
# "empty" phase (no textures) and again once they are loaded.
#
#   tests/offscreen/globe-idle.sh             OUT=dir for the log (default tests/offscreen/out)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$here/out}
mkdir -p "$OUT"
log=$OUT/globe-idle.log
env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
  timeout 25 /usr/lib/qt6/bin/qml "$here/globe-idle.qml" > "$log" 2>&1 &
pid=$!
vram() {  # KiB
  for f in /proc/"$qml"/fdinfo/*; do awk '/drm-client-id/ {id = $2} /drm-total-vram/ {print id, $2}' "$f"; done 2>/dev/null |
    sort -u | awk '{s += $2} END {print s + 0}'
}
wait_for() {
  while ! grep -q "globe-idle $1" "$log" 2>/dev/null; do
    kill -0 $pid 2>/dev/null || { cat "$log"; exit 1; }
    sleep 0.1
  done
}
wait_for empty
qml=$(pgrep -P $pid | head -1)                # timeout's child: the qml process
v0=$(vram)
wait_for loaded
sleep 1                                       # let the uploads land
v1=$(vram)
wait $pid || true
grep "globe-idle" "$log" | sed 's/^qml: //'
echo "texture VRAM: $(( (v1 - v0) / 1024 )) MiB (drm-total-vram $v0 -> $v1 KiB)"
