#!/bin/bash
# Builds libgoddard (the title screen's face) on this Mac the way install_mario64mr.py's build_goddard does (the
# decomp's src/goddard, native/goddard/patches, the shim) straight into a test program, and runs it.
#   [TEST=face_test] run_goddard_test.sh <scratch dir> [Mario64MRData-work]
set -e -o pipefail
TEST=${TEST:-face_test}
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$HERE/.." && pwd)
SCRATCH=${1:?scratch directory}
WORK=${2:-$HOME/Repos/mario64mr/Mario64MRData-work}
DECOMP=$WORK/sm64-decomp
mkdir -p "$SCRATCH"
SRC=$SCRATCH/src
rm -rf "$SRC"; mkdir -p "$SRC"
cp -R "$DECOMP/src/goddard" "$SRC/goddard"
for p in "$KIT"/patches/*.patch; do patch -s -d "$SRC/goddard" -p1 < "$p"; done
echo '#include "gd_texture_table.inc.c"' >> "$SRC/goddard/renderer.c"
rm -rf "$SCRATCH/gen"
python3 "$KIT/gen_textures.py" "$DECOMP" "$WORK/sm64ex" "$SCRATCH/gen" > /dev/null
sources=("$SRC"/goddard/*.c "$SRC"/goddard/dynlists/*.c)
for n in guPerspectiveF guOrthoF guRotateF guTranslateF guMtxF2L guScaleF guNormalize; do sources+=("$DECOMP/lib/src/$n.c"); done
cc -std=gnu99 -O1 -g -fno-strict-aliasing -fsigned-char -w -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DVERSION_US=1 -DF3D_OLD=1 -DNON_MATCHING=1 -DAVOID_UB=1 \
    -D_LANGUAGE_C -DNO_SEGMENTED_MEMORY -DGBI_FLOATS -I"$SCRATCH/gen" -I"$SRC" -I"$DECOMP/include" -I"$DECOMP/src" \
    -I"$DECOMP" -I"$KIT/shim" "${sources[@]}" "$KIT/shim/n64_stubs.c" "$KIT/shim/gd_api.c" "$HERE/$TEST.c" -lm \
    -o "$SCRATCH/$TEST"
"$SCRATCH/$TEST"
