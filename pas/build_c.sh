#!/bin/sh
# The C part of PJA (stream version 7's model, pjav7c.c, and the helpers
# around it, pjasysc.c) as objects for FreePascal to link: pjav7.pas takes
# them with {$L pjav7c.o} and {$L pjasysc.o}, found through -Fo<dir>.
#
#   pas/build_c.sh <out dir> [extra C flags]
#
# CC picks the compiler (cc by default): gcc or clang, native or a cross
# compiler (x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc, "gcc -m32").
# PJA_V7_PLAIN in the extra flags leaves SSE2 out (the suite checks that it
# gives the same streams).
#
# The object calls no library and needs no runtime: no stack protector, no
# loop turned into memset or memcpy (gcc's -fno-tree-loop-distribute-patterns,
# clang's -fno-builtin), no position-independent code where the executable is
# not (32-bit x86). -fwrapv and -ffp-contract=off keep the arithmetic the
# same everywhere. clang's code is about 8% faster than gcc's on x86-64, with
# the same bytes: the releases use it where they can.
set -eu
OUT=${1:?usage: build_c.sh <out dir> [extra C flags]}
shift
HERE=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-cc}
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector"
if $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-builtin"
else
  FLAGS="$FLAGS -fno-tree-loop-distribute-patterns"
fi
# 32-bit x86, by the flags or by what the compiler targets (MSYS2's
# mingw32 gcc is plain "gcc"): -march=i686, since those compilers assume
# SSE2 (Pentium 4) by default and pjav7c.c takes its SSE2 path when they
# do; without it the plain path, the same bits, runs on any 686 (Windows
# XP's Pentium III and Athlon XP). The SSE4.1 and AVX2 copies still go by
# cpuid.
case "$CC $* $($CC -dumpmachine 2>/dev/null)" in
  *-m32*|*i686*|*i386*|*i586*) FLAGS="$FLAGS -fno-pic -march=i686" ;;
esac
mkdir -p "$OUT"
# shellcheck disable=SC2086
$CC $FLAGS "$@" -c "$HERE/pjav7c.c" -o "$OUT/pjav7c.o"
# shellcheck disable=SC2086
$CC $FLAGS "$@" -c "$HERE/pjasysc.c" -o "$OUT/pjasysc.o"
