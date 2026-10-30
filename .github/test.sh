#!/bin/sh
# The check every platform runs (CI): the pja command and dump_streams built
# with the shipped options, every sample of the repository compressed and
# extracted by the command (each must come back byte for byte), the zpaq-std
# plugin built, libpja built and its C test run (pas/lib: with 7-Zip's
# plugin through a real 7-Zip where one is installed), and the SHA-256 of all the codec's streams written to
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

echo "== libpja"
sh pas/lib/build.sh "$OUT/lib" > "$OUT/lib.log" 2>&1 || { cat "$OUT/lib.log"; echo "FAIL: libpja did not build"; exit 1; }
LIBF=$(tail -1 "$OUT/lib.log")
RP=; case "$(uname -s)" in Linux) RP="-Wl,-rpath,$OUT/lib" ;; esac
# shellcheck disable=SC2086
${CC:-cc} -O2 -Ipas/lib pas/lib/test_lib.c -o "$OUT/lib/test_lib$EXE" "$LIBF" $RP
DYLD_LIBRARY_PATH="$OUT/lib" "$OUT/lib/test_lib$EXE" tests/jpg/* tests/jls/* README.md > "$OUT/lib/test.txt" \
  || { cat "$OUT/lib/test.txt"; echo "FAIL: libpja's test"; exit 1; }
tail -4 "$OUT/lib/test.txt"
# 7-Zip 23 or later (not p7zip, whose IUnknown differs): a copy with the
# plugin in its Codecs folder (the same word size as the library), an
# archive written and extracted
case "${CC:-} $FPC" in *-m32*|*i386*) SEVEN= ;; *) SEVEN=/usr/lib/7zip ;; esac
if [ -n "$SEVEN" ] && [ -f "$SEVEN/7z.so" ] && [ -x "$SEVEN/7z" ]; then
  Z="$OUT/7z"; rm -rf "$Z"; cp -r "$SEVEN" "$Z"; mkdir -p "$Z/Codecs" "$OUT/7in" "$OUT/7x"
  cp "$LIBF" "$Z/Codecs/"
  cp tests/jpg/* tests/jls/* README.md "$OUT/7in/"
  "$Z/7z" i | grep -q '37F01 PJA' || { echo "FAIL: 7-Zip does not list PJA"; exit 1; }
  (cd "$OUT/7in" && "../7z/7z" a -bso0 -bsp0 -m0=PJA -m1=LZMA2 ../a.7z .)
  "$Z/7z" x -bso0 -bsp0 -o"$OUT/7x" "$OUT/a.7z"
  for f in "$OUT"/7in/*; do
    cmp -s "$f" "$OUT/7x/$(basename "$f")" || { echo "FAIL: 7-Zip: $(basename "$f") does not come back"; exit 1; }
  done
  echo "7-Zip with the PJA plugin: every sample back, $(wc -c < "$OUT/a.7z" | tr -d ' ') bytes"
fi

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
