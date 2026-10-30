#!/bin/sh
# libpja: PJA as a shared library (pja.h) and 7-Zip codec plugin, from
# pjalib.pas, the C part (pas/build_c.sh), the filter (pjafilter.c) and
# the 7-Zip side (pja7z.c), all position-independent.
#
#   pas/lib/build.sh <out dir>     -> <out dir>/pja.so (pja.dll, pja.dylib)
#
# FPC picks the FreePascal compiler and its target options (fpc by default:
# "fpc -Twin64 -Px86_64" cross-compiles), CC the C compiler for the same
# target (pas/build_c.sh).
set -eu
OUT=${1:?usage: build.sh <out dir>}
# a folder's absolute path; on Windows (MSYS, Git Bash) in Windows' form,
# since FreePascal gets it glued to an option (-Fu...), which MSYS does not
# translate
apath() { (cd "$1" && { cygpath -m "$(pwd)" 2>/dev/null || pwd; }); }
HERE=$(apath "$(dirname "$0")"); PAS=$(dirname "$HERE")
FPC=${FPC:-fpc}
CC=${CC:-cc}
mkdir -p "$OUT/c" "$OUT/u"
OUT=$(apath "$OUT")
case "$CC $FPC" in
  *mingw*|*-Twin*) PIC=; EXT=dll ;;
  *) PIC=-fPIC; EXT=so ;;
esac
[ "$(uname -s)" = Darwin ] && EXT=dylib
# shellcheck disable=SC2086
CC="$CC" "$PAS/build_c.sh" "$OUT/c" $PIC
FLAGS="-O3 -fwrapv -ffp-contract=off -fno-stack-protector"
if ! $CC --version 2>/dev/null | grep -qi clang; then
  FLAGS="$FLAGS -fno-tree-loop-distribute-patterns"
fi
# shellcheck disable=SC2086
for f in pjafilter pja7z; do
  $CC $FLAGS $PIC -c "$HERE/$f.c" -o "$OUT/c/$f.o"
done
CG=; [ -n "$PIC" ] && CG=-Cg
# shellcheck disable=SC2086
$FPC -O3 -dPJA_FAST $CG -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$OUT/u" -o"$OUT/pja.$EXT" "$HERE/pjalib.pas" \
  > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
echo "$OUT/pja.$EXT"
