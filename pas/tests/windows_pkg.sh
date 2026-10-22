#!/bin/bash
# The Windows test package: pja.exe (release) and pja_ref.exe (checked), both
# cross-compiled for x86_64-win64, the samples, the .pja the Linux build
# makes of them (full and fast) with their SHA-256, and windows.ps1. On a
# Windows machine, unpack it and run windows.ps1: Windows has to write the
# very same .pja files and give every original back.
#
#   pas/tests/windows_pkg.sh <out dir>    -> <out dir>/pja_win.tar
#
# With PPC386 (an i386-win32 cross compiler) and RTL386 (its units), the
# package also carries pja32.exe and pja32_ref.exe: the Pascal path, no asm.
set -euo pipefail
FPC=${FPC:-fpc}
PAS=$(cd "$(dirname "$0")/.." && pwd); PJA=$(dirname "$PAS"); OUT=${1:?usage: windows_pkg.sh <out dir>}
mkdir -p "$OUT"; OUT=$(realpath "$OUT"); B=$OUT/build; K=$OUT/pkg
rm -rf "$K"; mkdir -p "$B/lin" "$B/win" "$B/winref" "$K/in" "$K/lin_full" "$K/lin_fast"
$FPC -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -FU"$B/lin" -o"$B/pja" "$PAS/pjacli.pas" > "$B/fpc.log" 2>&1 || { cat "$B/fpc.log"; exit 1; }
$FPC -Twin64 -Px86_64 -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -FU"$B/win" -o"$K/pja.exe" "$PAS/pjacli.pas" > "$B/fpc.log" 2>&1 \
  || { cat "$B/fpc.log"; exit 1; }
$FPC -Twin64 -Px86_64 -O2 -Fu"$PAS" -Fi"$PAS" -FU"$B/winref" -o"$K/pja_ref.exe" "$PAS/pjacli.pas" > "$B/fpc.log" 2>&1 \
  || { cat "$B/fpc.log"; exit 1; }
if [ -n "${PPC386:-}" ]; then
  mkdir -p "$B/w32" "$B/w32ref"
  "$PPC386" -n -Twin32 -O3 -dPJA_FAST -Fu"$RTL386" -Fu"$PAS" -Fi"$PAS" -FU"$B/w32" -o"$K/pja32.exe" "$PAS/pjacli.pas" \
    > "$B/fpc.log" 2>&1 || { cat "$B/fpc.log"; exit 1; }
  "$PPC386" -n -Twin32 -O2 -Fu"$RTL386" -Fu"$PAS" -Fi"$PAS" -FU"$B/w32ref" -o"$K/pja32_ref.exe" "$PAS/pjacli.pas" \
    > "$B/fpc.log" 2>&1 || { cat "$B/fpc.log"; exit 1; }
fi
cp "$PJA"/tests/jpg/* "$PJA"/tests/jls/* "$K/in/"
cp "$K/in/grayscale.jpg" "$K/in/-dash.jpg"
# the non-ASCII sample is made on Windows (tar would mangle a UTF-8 name);
# its streams are grayscale's, made under its name there
"$B/pja" a -q -th 1 -o "$K/lin_full/" -- "$K"/in/*
"$B/pja" a -q -th 1 --fast -o "$K/lin_fast/" -- "$K"/in/*
for d in in lin_full lin_fast; do (cd "$K/$d" && sha256sum -- * > "../$d.sha256"); done
cp "$PAS/tests/windows.ps1" "$K/"
tar -cf "$OUT/pja_win.tar" -C "$K" .
echo "$OUT/pja_win.tar"
