#!/bin/sh
# Bake Flightline's shaders (shaders/*.vert|frag, Vulkan-style GLSL 440) into the
# .qsb packs Qt Quick loads. The .qsb files are committed, so users never run this.
#
#   tools/build-shaders.sh            (needs /usr/lib/qt6/bin/qsb from qt6-shadertools)
#
# Targets:
#   SPIR-V 1.0 (always in a .qsb: Vulkan RHI)
#   GLSL 100 es, 120, 150: the OpenGL RHI picks the best one the context accepts.
#     The Omarchy shell runs OpenGL (Mesa gives a 4.6 compatibility context, so
#     150 is used); 120 covers GL 2.1 drivers, 100 es covers GLES 2 / Raspberry Pi.
#     The shaders use no feature that needs 330 / 300 es (no integer or bitwise
#     ops, no texelFetch, constant loop bounds), so that is the widest set.
#   HLSL 5.0 (D3D11/12) and MSL 1.2 (Metal): free, keeps the shaders portable.
#
# A ShaderEffect fills ONE uniform buffer for both stages, so each .vert/.frag pair
# must declare an identical uniform block; this script refuses to bake otherwise.
set -eu
cd "$(dirname "$0")/.."
QSB=${QSB:-/usr/lib/qt6/bin/qsb}

block() { sed -n '/uniform buf {/,/^};/p' "$1"; }

# With arguments, only those files are baked (and only their pairs checked), so
# several people can work on different shaders at once:
#   tools/build-shaders.sh shaders/globe.vert shaders/globe.frag
if [ "$#" -eq 0 ]; then set -- shaders/*.vert shaders/*.frag; fi

for src in "$@"; do
  case $src in
    *.vert) vert=$src; frag=${src%.vert}.frag ;;
    *.frag) frag=$src; vert=${src%.frag}.vert ;;
    *) echo "error: not a .vert/.frag shader: $src" >&2; exit 1 ;;
  esac
  if [ -f "$vert" ] && [ -f "$frag" ] && [ "$(block "$vert")" != "$(block "$frag")" ]; then
    echo "error: uniform blocks of $vert and $frag differ" >&2
    exit 1
  fi
done

for src in "$@"; do
  "$QSB" --glsl "100es,120,150" --hlsl 50 --msl 12 -o "$src.qsb" "$src"
  echo "baked $src.qsb"
done
