#!/bin/bash
# PJA as a zpaq-std plugin (pja_zpaqstd.pas): the .so for Linux and the .dll
# for 64-bit Windows; with PPC386 (an i386-win32 cross compiler) and RTL386
# (its units), the 32-bit .dll too.
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
run() { "$@" > "$B/fpc.log" 2>&1 || { cat "$B/fpc.log"; exit 1; }; }
# -Cg: position-independent code, needed by a shared library
run $FPC -O3 -dPJA_FAST -Cg -Fu"$PAS" -Fi"$PAS" -FU"$B/lin" -o"$B/lin/pja.so" "$SRC"
cp "$B/lin/pja.so" "$OUT/pja.so"
run $FPC -Twin64 -Px86_64 -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -FU"$B/win" -o"$OUT/pja.dll" "$SRC"
if [ -n "${PPC386:-}" ]; then
  run "$PPC386" -n -Twin32 -O3 -dPJA_FAST -Fu"$RTL386" -Fu"$PAS" -Fi"$PAS" -FU"$B/w32" -o"$OUT/pja32.dll" "$SRC"
fi
ls -l "$OUT"/pja*.so "$OUT"/pja*.dll
