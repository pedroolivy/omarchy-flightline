#!/usr/bin/env bash
# Bake assets/terrain.png (relief, sea depth, elevation) from NOAA ETOPO1. Called by
# tools/build-textures.sh once earth.png exists, because earth.png decides land and sea.
#
#   tools/build-terrain.sh [outdir]           (default: assets/; reads outdir/earth.png)
#
# Env knobs:  TW=3072 (terrain.png width)   CACHE=~/.cache/flightline-build
# Needs: curl, python3, gcc, ImageMagick 7 (magick), sha256sum.  No numpy/GDAL.
#
# terrain.png  TW x TW/2, 8-bit RGB, no alpha, no colour chunks, earth.png's mapping
# (lon -180..180 left->right, lat 90..-90 top->bottom, texel centres at ((i+0.5)/W, (j+0.5)/H)):
#   R = hillshade, 128 = flat, land only (the sea is 128)    relief = (t * 255 - 128) / 127
#   G = ocean depth,    0 on land:  depth_m = 8000 * t^2      (byte = round(255 sqrt(d / 8000)))
#   B = land elevation, 0 at sea:   h_m     = 6000 * t^2      (byte = round(255 sqrt(h / 6000)))
# (t = texture() value.)  Heights are the ice surface: Greenland and Antarctica show their ice
# sheets.  See tools/terrainbake.c for the light set and the averaging.
#
# Source: ETOPO1 Ice Surface, cell-registered (21600 x 10800 int16, 1 arc-minute), 323 MB
# zipped.  Compared on 2026-10-03:
#   * ETOPO5 (18.7 MB, 4320 x 2160): barely larger than the output, so the hillshade cannot be
#     computed finer and averaged down, and its 1980s compilation shows: vertical striping over
#     Antarctica, blocky terraces, survey-line fabric across the South Atlantic.
#   * ETOPO 2022 60 s surface GeoTIFF (444 MB, float32): newer, same grid as ETOPO1, but a
#     bigger download and 3.7 GB through ImageMagick; at a 13 km texel the two look the same.
#   * ETOPO1 (int16 raw, streamed out of the zip into terrainbake): the smallest clean one.
#
# Why TW=3072 (not 4096 or 2048): the file must stay <= 4 MB (docs/VISUAL.md).  4096 x 2048 does
# not fit: 6.4 MB with a flat sea, 3.3 MB with G zeroed, 4.8 MB with G and B blurred by 2 and 1
# texels, and ImageMagick already matches the best PNG filter / zlib strategy.  2048 x 1024 fits
# with room for sea-floor relief (2.6 MB), but at 250 NM (magnified ~20x) the Alps and the
# Himalaya turn into soft mush; 3072 keeps distinct ridges and valleys.  The sea-floor relief does
# not fit next to it (5.9 MB at 3072), and the depth tones in G already draw the ridges, trenches
# and seamount chains, so R is 128 over water.  RGBA8 VRAM: 3072 x 1536 x 4 = 18 MiB.
# Decoders take the size from textureSize(), so TW=2048 or 4096 stays a rebuild, not a code change;
# 3072 is not a power of two, which needs no more than clamp-to-edge and no mipmaps (core GLES 2).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../assets}
TW=${TW:-3072}
CACHE=${CACHE:-$HOME/.cache/flightline-build}
UA="Flightline-texture-build"
# Vertical exaggeration and contrast of the land hillshade, tuned by eye on 250 NM views of the
# Alps, the Andes and the Himalaya (tools/terrainbake.c); gain 2.5 clips 0.1 % of land texels.
VE_LAND=3 GAIN_LAND=2.5 VE_SEA=4 GAIN_SEA=0
mkdir -p "$CACHE/src" "$CACHE/work/t"
src=$CACHE/src; work=$CACHE/work

E1=https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO1/data/ice_surface/cell_registered/binary
# sha256 as fetched 2026-10-03 (upstream may republish -> warn, do not fail)
name=etopo1_ice_c_i2.zip
sum=dcad80619f91773d0ba9c159f6d7b504664a42f0222c059689ea8efc207dd25d
if [[ ! -s $src/$name ]]; then
  echo "fetch $name (323 MB)"
  curl -fsSL -A "$UA" -o "$src/$name.part" "$E1/$name" && mv "$src/$name.part" "$src/$name"
  sleep 3                                     # be polite: one request per 3 s
fi
echo "$sum  $src/$name" | sha256sum -c --quiet - 2>/dev/null || echo "warning: $name differs from the recorded sha256 (upstream update?)"
[[ -s $out/earth.png ]] || { echo "error: $out/earth.png is missing (run tools/build-textures.sh)" >&2; exit 1; }

echo "compile terrainbake"
gcc -O2 -o "$work/terrainbake" "$here/terrainbake.c" -lm

# earth.png's R plane: the signed coast distance that decides land (> 127.5) and sea.
magick "$out/earth.png" -channel R -separate +channel -depth 8 "$work/t/land.pgm"
# The grid is little-endian int16, rows from 90N, first cell centred half a cell from the corner.
python3 -c 'import sys, zipfile, shutil
shutil.copyfileobj(zipfile.ZipFile(sys.argv[1]).open("etopo1_ice_c_i2.bin"), sys.stdout.buffer, 1 << 20)' "$src/$name" |
  "$work/terrainbake" - 21600 10800 -179.99166666666667 89.99166666666667 le "$work/t/land.pgm" "$TW" \
    "$work/t/terrain.ppm" "$VE_LAND" "$VE_SEA" "$GAIN_LAND" "$GAIN_SEA"
magick "$work/t/terrain.ppm" -strip -define png:compression-level=9 -define png:compression-filter=5 \
  -define png:exclude-chunks=all "PNG24:$out/terrain.png"
ls -l "$out/terrain.png"
echo "params: TW=$TW VE_LAND=$VE_LAND GAIN_LAND=$GAIN_LAND GAIN_SEA=$GAIN_SEA"
