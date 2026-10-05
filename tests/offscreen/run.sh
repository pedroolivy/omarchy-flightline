#!/bin/sh
# Render offscreen tests on the real GPU (OpenGL RHI, offscreen QPA: no window).
#
#   tests/offscreen/run.sh [test.qml ...]      default: every test except bench.qml
#
# More globe checks, each with its own driver or arguments:
#   globe-looks.qml   every v2.1 globe look in three themes; with run.sh it renders the
#                     dark theme (TIMEOUT=40 for all three: globe-looks.qml -- OUT all)
#   globe-shimmer.sh  aliasing while dragging, as a number per scene
#   globe-idle.sh     idle frames, keepTextures and the texture VRAM
#
# Env:  OUT=dir            where the PNGs go (default: tests/offscreen/out)
#       WORLD_JSON=file    a saved adsb.lol / adsb.fi response for world-traffic.qml
#                          and bench.qml (skipped without it; no network in tests)
#       TIMEOUT=s          per test (default 15)
#
# Fixtures are packed into $OUT/<name>.ppm with feed2ppm.py and handed to QML as
# "name:count:epochMs" arguments after the out dir (see Shots.qml fixture()).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$here/out}
mkdir -p "$OUT"

fixtures=""
pack() {  # pack <name> <raw.json>
  set -- "$1" "$2" $("$here/feed2ppm.py" "$2" "$OUT/$1.ppm")
  fixtures="$fixtures $1:$3:$4"
}
pack outback "$here/fixtures/outback.json"
pack deadreckon "$here/fixtures/deadreckon.json"
[ -n "${WORLD_JSON:-}" ] && pack world "$WORLD_JSON"

[ $# -gt 0 ] || set -- globe-night.qml regional.qml globe-looks.qml deadreckon.qml world-traffic.qml
status=0
for test in "$@"; do
  case $test in
    world-traffic.qml|bench.qml)
      [ -n "${WORLD_JSON:-}" ] || { echo "skip $test (set WORLD_JSON)"; continue; } ;;
  esac
  echo "== $test"
  # shellcheck disable=SC2086
  timeout "${TIMEOUT:-15}" env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen \
    QT_FORCE_STDERR_LOGGING=1 ${QSG_INFO:+QSG_INFO=1} \
    /usr/lib/qt6/bin/qml "$here/${test##*/}" -- "$OUT" $fixtures || { echo "FAIL $test ($?)"; status=1; }
done
exit $status
