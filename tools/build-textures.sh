#!/usr/bin/env bash
# Rebuild Flightline's bundled assets from public-domain sources.
#
#   tools/build-textures.sh [outdir]          (default: assets/)
#
# Env knobs:  W=4096 (earth.png width)  LW=2048 (lights.png width)
#             CACHE=~/.cache/flightline-build   SL=8 SB=4 EB=0.5 (see tools/sdfbake.c)
# Needs: curl, python3, gcc, ImageMagick 7 (magick), sha256sum.  No numpy/PIL.
#
# Outputs (both equirectangular, lon -180..180 left->right, lat 90..-90 top->bottom,
# texel centres at ((i+0.5)/W, (j+0.5)/H); 8-bit RGB, no alpha, no colour chunks):
#   earth.png   W x W/2   R = land signed distance   (+ on land)     spread SL texels
#                         G = country border side-signed distance     spread SB texels
#                         B = state/province border side-signed dist. spread SB texels
#   lights.png  LW x LW/2 R = NASA Black Marble 2016 night lights (linear-light downsample)
#                         G = R blurred (sigma 3 texels at 2048): a free pre-baked bloom
#                         B = coarse signed distance to the coast, spread LW/64 texels (626 km)
#   places.json           Natural Earth populated places (tools/build-geo.py)
#   terrain.png           NOAA ETOPO1 relief, sea depth and elevation, land/sea from earth.png
#                         (tools/build-terrain.sh, TW=3072; its header has the encoding)
# Decode: d = (t - 0.5) * 2 * spread   [texels of that texture; 1 unit = 40075/W km; t = texture() value]
#   * horizontal distances were measured with cos(lat), so d is a true ground distance.
#   * land: plain bilinear is fine.  borders: the sign is only "which side of the nearest
#     segment", so fetch the 4 texels yourself (Image{smooth:false}), and if no corner has
#     |d| < 0.75 interpolate |d| instead of d (kills false zero crossings on medial axes).
#   * the u axis wraps: fetch column (i mod W).  Column 0 and column W-1 are neighbours on
#     the globe and were baked as such, so there is no seam to hide.  lights.png is sampled
#     with plain texture() (clamp to edge); its edge columns match, so the clamp is invisible.
#   * AA: alpha = clamp(1 - |d| / px) for a 1 px hairline, px = pixel footprint in texels;
#     fade lines out as px approaches the spread (limb / far zoom).
#   * Qt Quick uploads every 8-bit image as RGBA8 (measured): a gray PNG costs as much VRAM
#     as an RGB one, so channels are packed 3 per texture.  Never use alpha (premultiplied).
#
# Why lights.png is 2048 wide and earth.png 4096: earth carries the coast and borders as
# distance fields, which stay sharp under magnification but lose every feature smaller than
# a texel (9.8 km at 4096), so it needs the resolution.  The lights are a soft glow.  Side by
# side renders (globe radius 420 px; 250 NM over the Andes and the Alps in a 900 px view):
#   * globe zoom: 2048 is ~1.3 px per texel and reads brighter and fuller; 4096 is minified
#     2:1 without mipmaps, so small towns fall between samples (dimmer, patchier, and prone
#     to shimmer while the globe turns).
#   * 250 NM: 2048 is magnified ~19x, 4096 ~10x.  4096 shows small towns as separate dots,
#     2048 as a faint haze around the metros.  Visible, but it is night-side decoration.
# RGBA8 costs W*H*4: earth 32 MiB + lights 8 MiB = 40 MiB of VRAM (measured: +43 MB on
# amdgpu) and the same again in Qt's image cache, instead of 64 MiB (+68 MB) with LW=4096.
# Decoders should take sizes from textureSize(), so LW=4096 stays a rebuild, not a code change.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../assets}
W=${W:-4096}; LW=${LW:-2048}
SL=${SL:-8}; SB=${SB:-4}; EB=${EB:-0.5}
CACHE=${CACHE:-$HOME/.cache/flightline-build}
UA="Flightline-texture-build"
mkdir -p "$out" "$CACHE/src" "$CACHE/work"
src=$CACHE/src; work=$CACHE/work

NE=https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson
BM=https://assets.science.nasa.gov/content/dam/science/esd/eo/images/imagerecords/144000/144897
# name  url  sha256 (as fetched 2026-10-03; upstream may republish -> warn, do not fail)
sources=(
  "ne_10m_land.geojson $NE/ne_10m_land.geojson 1ac90796408bc6ad6911d69448485d3c4dbf2190370080368a09976e1c9f7416"
  "ne_10m_minor_islands.geojson $NE/ne_10m_minor_islands.geojson 8c933ca7a4760256bdc46408355706e39764b0fa01c160c28888b90b4faec29f"
  "ne_10m_lakes.geojson $NE/ne_10m_lakes.geojson 2d036f53dedec578001c5c30c2959ee7d4eebc1306900fa4367c49929ec8f2d9"
  "ne_10m_admin_0_boundary_lines_land.geojson $NE/ne_10m_admin_0_boundary_lines_land.geojson 74d9c16229c095fde65943a9919e337682f044bcebccb120764f38edf3b70f4a"
  "ne_10m_admin_1_states_provinces_lines.geojson $NE/ne_10m_admin_1_states_provinces_lines.geojson 1a1f30ccaaf4cc9c4bde34266f0b8cbb955d3a4cf254b756912255f2ec7c75b6"
  "ne_10m_populated_places_simple.geojson $NE/ne_10m_populated_places_simple.geojson fd3fa867a320cbd5c5b6bb5bc550afeec2939fb2cef688e508007282a55ac42f"
  "BlackMarble_2016_3km_gray_geo.tif $BM/BlackMarble_2016_3km_gray_geo.tif 3c1bc09978fa6a7f2c65453460fbd290b66441389f1135c111d699816b59b926"
)
for s in "${sources[@]}"; do
  read -r name url sum <<<"$s"
  if [[ ! -s $src/$name ]]; then
    echo "fetch $name"
    curl -fsSL --compressed -A "$UA" -o "$src/$name.part" "$url" && mv "$src/$name.part" "$src/$name"
    sleep 3                                   # be polite: one request per 3 s
  fi
  echo "$sum  $src/$name" | sha256sum -c --quiet - 2>/dev/null || echo "warning: $name differs from the recorded sha256 (upstream update?)"
done

echo "compile tools"
gcc -O2 -o "$work/sdfbake" "$here/sdfbake.c" -lm

# Lakes the W-wide distance field cannot draw (reservoirs, thin water) are dropped here.
python3 "$here/geo2bin.py" "$src" "$work/geo.bin" "$W"

mkdir -p "$work/a" "$work/b"
"$work/sdfbake" "$work/geo.bin" "$W" "$work/a" "$SL" "$SB" 0 "$EB"
"$work/sdfbake" "$work/geo.bin" "$LW" "$work/b" "$SL" "$SB" "$((LW / 64))" "$EB"

# Night lights: average in linear light (lights add up), back to sRGB-ish 8 bit.  The source
# spans exactly -180..180, so tile the edges: the antimeridian columns then filter across it.
bloom=$(python3 -c "print(round(6 * $LW / 4096, 2))")
magick "$src/BlackMarble_2016_3km_gray_geo.tif" -channel R -separate +channel -virtual-pixel tile \
  -set colorspace sRGB -colorspace RGB -filter Triangle -resize "${LW}x$((LW / 2))!" \
  -colorspace sRGB -colorspace Gray -depth 8 "$work/b/lights.pgm"
magick "$work/b/lights.pgm" -virtual-pixel tile -blur "0x$bloom" -level 0,35% -depth 8 "$work/b/bloom.pgm"

enc() {  # enc <out> <r> <g> <b>
  magick "$2" "$3" "$4" -combine -colorspace sRGB -strip -define png:compression-level=9 \
    -define png:compression-filter=5 -define png:exclude-chunks=all "PNG24:$1"
}
enc "$out/earth.png"  "$work/a/land.pgm"   "$work/a/adm0.pgm"  "$work/a/adm1.pgm"
enc "$out/lights.png" "$work/b/lights.pgm" "$work/b/bloom.pgm" "$work/b/wide.pgm"
python3 "$here/build-geo.py" "$src" "$out"
"$here/build-terrain.sh" "$out"                # after earth.png: it decides land and sea
ls -l "$out/earth.png" "$out/lights.png" "$out/places.json" "$out/terrain.png"
echo "params: W=$W LW=$LW SL=$SL SB=$SB EB=$EB wide_spread=$((LW / 64)) bloom_sigma=$bloom"
