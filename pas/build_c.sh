#!/bin/sh
# The C part of PJA (stream version 7's model, pjav7c.c) as an object for
# FreePascal to link: pjav7.pas takes it with {$L pjav7c.o}, found through
# -Fo<dir>.
#
#   pas/build_c.sh <out dir> [extra C flags]
#
# CC picks the compiler (cc by default): gcc or clang, native or a cross
# compiler (x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc, "gcc -m32").
# PJA_V7_PLAIN in the extra flags leaves SSE2 out (the suite checks that it
# gives the same streams).
#
# The object calls no library and needs no runtime: no stack protector, no
# loop turned into memset (gcc), no position-independent code where the
# executable is not (32-bit x86). -fwrapv and -ffp-contract=off keep the
# arithmetic the same everywhere.
set -eu
OUT=${1:?usage: build_c.sh <out dir> [extra C flags]}
shift
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-cc}
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector"
if ! $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-tree-loop-distribute-patterns"
fi
case "$CC $*" in
  *-m32*|*i686*|*i386*) FLAGS="$FLAGS -fno-pic" ;;
esac
mkdir -p "$OUT"
# shellcheck disable=SC2086
$CC $FLAGS "$@" -c "$HERE/pjav7c.c" -o "$OUT/pjav7c.o"
