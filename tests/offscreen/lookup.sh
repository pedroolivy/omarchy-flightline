#!/bin/sh
# Render the "Look up" lens offscreen (tests/offscreen/lookup.qml) over a real
# saved response, and time the scan the way the lens runs it; then its sky
# (lookup-sky.qml: dusk, night and noon in a dark, a light and a warm theme).
#
#   WORLD_JSON=world.json tests/offscreen/lookup.sh
#
# flightline-feed turns the response into the meta.json that Service.meta()
# would hand the lens. PNGs go to $OUT (default tests/offscreen/out).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$here/out}
[ -n "${WORLD_JSON:-}" ] || { echo "set WORLD_JSON (a saved adsb.lol response)" >&2; exit 2; }
mkdir -p "$OUT/lookup-data"
"$here/../../flightline-feed" --in "$WORLD_JSON" --keep-input --out-dir "$OUT/lookup-data" --rev 1 --source test > /dev/null
timeout "${TIMEOUT:-15}" env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen \
  QT_FORCE_STDERR_LOGGING=1 QML_XHR_ALLOW_FILE_READ=1 \
  /usr/lib/qt6/bin/qml "$here/lookup.qml" -- "$OUT"
timeout "${TIMEOUT:-15}" env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen \
  QT_FORCE_STDERR_LOGGING=1 QML_XHR_ALLOW_FILE_READ=1 \
  /usr/lib/qt6/bin/qml "$here/lookup-sky.qml" -- "$OUT"
