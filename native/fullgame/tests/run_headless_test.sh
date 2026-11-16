#!/bin/bash
# Builds the game library on this Mac (no host: CC=cc, a plain shared library) from a scratch copy of the sm64ex
# checkout, patched as install_mario64mr.py patches it, and runs one of the tests here against it.
#   run_headless_test.sh <test.c> <scratch dir> [Mario64MRData-work] [base.zip]
set -e -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TEST=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
SCRATCH=${2:?scratch directory}
WORK=${3:-$HOME/Repos/mario64mr/Mario64MRData-work}
BASE=${4:-$HOME/Repos/mario64mr/Mario64MRData/sm64/res/base.zip}
mkdir -p "$SCRATCH"
SCRATCH=$(cd "$SCRATCH" && pwd)
[ -d "$SCRATCH/sm64ex" ] || cp -cR "$WORK/sm64ex" "$SCRATCH/sm64ex"
cd "$SCRATCH/sm64ex"
git checkout HEAD -- .
python3 -c "import sys; sys.path.insert(0, '$HERE/..'); import patch_sm64ex as p; from pathlib import Path; p.prepare(Path('.'), Path('baserom.us.z64').read_bytes(), sixty=True, external_data=True)"
for f in assets/demos/*.bin; do printf '\0\0\0\0' > "$f"; done
flags="-Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=incompatible-pointer-types"
make -j"$(sysctl -n hw.ncpu)" HOST_OS=Linux OSX_BUILD=0 BUILD_DIR=build/headless CC=cc CXX=c++ LD=cc "CPP=cc -E -P -x c" \
    RENDER_API=UNITY WINDOW_API=UNITY AUDIO_API=UNITY CONTROLLER_API=UNITY NOEXTRACT=1 EXTERNAL_DATA=1 EXT_OPTIONS_MENU=1 \
    TEXTURE_FIX=0 BETTERCAMERA=0 NODRAWINGDISTANCE=0 "LDFLAGS=-shared -lm" "OPT_FLAGS=-O2 -fPIC $flags" \
    "CC_CHECK=cc -fsyntax-only -fPIC -Isrc -Iinclude -I. -Ibuild/headless -Ibuild/headless/include -DVERSION_US -D_LANGUAGE_C -DNON_MATCHING -DAVOID_UB -DF3DEX_GBI_2E -DRAPI_UNITY -DWAPI_UNITY -DAAPI_UNITY $flags" \
    > "$SCRATCH/make.log" 2>&1 || { grep -B2 -A6 "error:" "$SCRATCH/make.log" | head -40; exit 1; }
cp build/headless/sm64.us.f3dex2e "$SCRATCH/libsm64game.dylib"
install_name_tool -id @rpath/libsm64game.dylib "$SCRATCH/libsm64game.dylib"
NAME=$(basename "$TEST" .c)
cc -O1 -g -w -I include -I build/headless -I build/headless/include -I src -I . -DVERSION_US -D_LANGUAGE_C -DNON_MATCHING \
    -DAVOID_UB -DF3DEX_GBI_2E -DEXT_OPTIONS_MENU -DEXTERNAL_DATA -fno-strict-aliasing -fwrapv "$TEST" \
    -L"$SCRATCH" -lsm64game -Wl,-rpath,"$SCRATCH" -o "$SCRATCH/$NAME"
mkdir -p "$SCRATCH/save/res"
ln -sf "$BASE" "$SCRATCH/save/res/base.zip"
cd "$SCRATCH/save"
"$SCRATCH/$NAME" "$SCRATCH/save" 2>&1 | grep -v "texture format"
