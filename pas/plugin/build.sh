#!/bin/bash
# PJA as a zpaq-std plugin (pja_zpaqstd.pas): the .so for Linux and the .dll
# for 64-bit Windows; with PPC386 (an i386-win32 cross compiler) and RTL386
# (its units), the 32-bit .dll too. Since 0.6.0 the plugin links the version 7
# model's C (pas/build_c.sh: pjav7c.c, pjasysc.c), built here for each target:
# cc -fPIC, x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc.
#
#   pas/plugin/build.sh <out dir>   -> <out dir>/pja.so, pja.dll, pja32.dll
#
# zpaq-std looks for codecs/pja.so (or codecs\pja.dll) next to its binary.
set -euo pipefail
FPC=${FPC:-fpc}
PAS=$(cd "$(dirname "$0")/.." && pwd); OUT=${1:?usage: build.sh <out dir>}
mkdir -p "$OUT"; OUT=$(realpath "$OUT"); B=$OUT/build
rm -rf "$B"; mkdir -p "$B/lin" "$B/win" "$B/w32"
SRC=$PAS/plugin/pja_zpaqstd.pas
# the commit the plugin's info card names (codecinfoex in zpaq-std)
export PJA_COMMIT=${PJA_COMMIT:-$(git -C "$PAS" describe --always --dirty --abbrev=7 2>/dev/null || true)}
run() { "$@" > "$B/fpc.log" 2>&1 || { cat "$B/fpc.log"; exit 1; }; }
# -Cg: position-independent code, needed by a shared library (and -fPIC for its C)
run sh "$PAS/build_c.sh" "$B/lin/c" -fPIC
run $FPC -O3 -dPJA_FAST -Cg -Fu"$PAS" -Fi"$PAS" -Fo"$B/lin/c" -FU"$B/lin" -o"$B/lin/pja.so" "$SRC"
cp "$B/lin/pja.so" "$OUT/pja.so"
CC=x86_64-w64-mingw32-gcc run sh "$PAS/build_c.sh" "$B/win/c"
run $FPC -Twin64 -Px86_64 -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -Fo"$B/win/c" -FU"$B/win" -o"$OUT/pja.dll" "$SRC"
if [ -n "${PPC386:-}" ]; then
  CC=i686-w64-mingw32-gcc run sh "$PAS/build_c.sh" "$B/w32/c"
  run "$PPC386" -n -Twin32 -O3 -dPJA_FAST -Fu"$RTL386" -Fu"$PAS" -Fi"$PAS" -Fo"$B/w32/c" -FU"$B/w32" -o"$OUT/pja32.dll" "$SRC"
fi
ls -l "$OUT"/pja*.so "$OUT"/pja*.dll
