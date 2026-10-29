#!/bin/sh
# The check every platform runs (CI): the pja command and dump_streams built
# with the shipped options, every sample of the repository compressed and
# extracted by the command (each must come back byte for byte), the zpaq-std
# plugin built, and the SHA-256 of all the codec's streams written to
# hash.txt: the format makes the same bytes on every platform, which the
# last CI job checks.
#
#   FPC=<compiler> PJA_OUT=<dir> sh .github/test.sh
set -eu
FPC=${FPC:-fpc}
OUT=${PJA_OUT:-build/ci}
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; *) EXE= ;; esac
if command -v sha256sum > /dev/null; then SHA="sha256sum"; else SHA="shasum -a 256"; fi
rm -rf "$OUT"; mkdir -p "$OUT/u" "$OUT/pu" "$OUT/in" "$OUT/p" "$OUT/x" "$OUT/st"

echo "== build"
# the C part (CC: the platform's C compiler). A compiler given by its full
# path (MSYS2's MinGW-w64 gcc on Windows) needs its own folder on PATH for
# its DLLs and its cc1/as; without it, it fails without a word.
case ${CC:-} in /*) PATH=$(dirname "$CC"):$PATH; export PATH ;; esac
sh pas/build_c.sh "$OUT/c" || { echo "the C part did not build (CC=${CC:-cc})"; exit 1; }
$FPC -O3 -dPJA_FAST -Fupas -Fipas -Fo"$OUT/c" -FU"$OUT/u" -o"$OUT/pja$EXE" pas/pjacli.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
$FPC -O3 -dPJA_FAST -Fupas -Fipas -Fo"$OUT/c" -FU"$OUT/u" -o"$OUT/dump_streams$EXE" pas/tests/dump_streams.pas > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
# the plugin: a shared library (position-independent code where it is one)
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) PIC= ;; *) PIC=-Cg ;; esac
$FPC -O3 -dPJA_FAST $PIC -Fupas -Fipas -Fupas/plugin -Fipas/plugin -FU"$OUT/pu" -o"$OUT/pja_plugin" \
  pas/plugin/pja_zpaqstd.pas > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
"$OUT/pja$EXE" --version

echo "== the command: every sample, a then x"
cp tests/jpg/* tests/jls/* "$OUT/in/"
"$OUT/pja$EXE" a -q --output-dir="$OUT/p" "$OUT"/in/*
"$OUT/pja$EXE" x -q --output-dir="$OUT/x" "$OUT"/p/*.pja
n=0
for f in "$OUT"/in/*; do
  n=$((n + 1))
  cmp -s "$f" "$OUT/x/$(basename "$f")" || { echo "FAIL: $(basename "$f") does not come back"; exit 1; }
done
[ "$n" -ge 30 ] || { echo "FAIL: only $n samples"; exit 1; }
echo "$n samples back byte for byte"

echo "== the streams"
"$OUT/dump_streams$EXE" tests/jpg "$OUT/st"
"$OUT/dump_streams$EXE" tests/jls "$OUT/st"
# and version 7's, the C model: the same bytes on every platform too
mkdir -p "$OUT/st7"
PJA_TEST_V7=1 "$OUT/dump_streams$EXE" tests/jpg "$OUT/st7"
for f in "$OUT"/st7/*; do mv "$f" "$OUT/st/v7_$(basename "$f")"; done
(cd "$OUT/st" && $SHA * | sed 's/ [ *]/  /' | sort) > "$OUT/streams.txt"
[ "$(wc -l < "$OUT/streams.txt")" -ge 30 ] || { echo "FAIL: too few streams"; exit 1; }
$SHA "$OUT/streams.txt" | cut -c1-64 > hash.txt
echo "$(wc -l < "$OUT/streams.txt" | tr -d ' ') streams, SHA-256 of their list: $(cat hash.txt)"
