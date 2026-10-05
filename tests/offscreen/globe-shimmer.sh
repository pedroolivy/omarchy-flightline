#!/bin/sh
# Shimmer while dragging (tests/offscreen/globe-shimmer.qml): renders each
# scene at its centre and 1 and 3 px further east, shifts those back and
# prints the mean absolute difference (0..255) in a 300 x 200 box at the
# centre, where the move is a plain translation. Lower is calmer; run it on a
# v2.0 tree for the reference. Needs ImageMagick.
#
#   tests/offscreen/globe-shimmer.sh            OUT=dir for the PNGs (default tests/offscreen/out)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$here/out}
mkdir -p "$OUT"
timeout 25 env QT_QUICK_BACKEND=rhi QSG_RHI_BACKEND=opengl QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
  /usr/lib/qt6/bin/qml "$here/globe-shimmer.qml" -- "$OUT" > "$OUT/globe-shimmer.log" 2>&1 || { cat "$OUT/globe-shimmer.log"; exit 1; }
box=300x200+250+200
for a in "$OUT"/shimmer-*-0.png; do
  name=${a##*/shimmer-}; name=${name%-0.png}
  line="$name"
  for px in 1 3; do
    b="$OUT/shimmer-$name-$px.png"
    # the globe moved east, so the ground moved left: shift the new frame right
    mae=$(magick "$a" \( "$b" -roll +${px}+0 \) -crop $box +repage -compose difference -composite \
          -colorspace gray -format "%[fx:mean*255]" info:)
    line="$line  ${px}px $(printf %.2f "$mae")"
  done
  echo "$line"
done
