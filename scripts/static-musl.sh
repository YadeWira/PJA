#!/bin/sh
# The pja command as one static binary linked with musl instead of glibc:
# it runs on any Linux of its CPU, and on Android (Termux), where neither
# the glibc build nor a static glibc one starts (Android 11's seccomp kills
# glibc's startup: pas/pjadlshim.c). The release ships it for arm64.
#
#   scripts/static-musl.sh <C objects dir> <out dir> [reference pja]
#
# <C objects dir>: what pas/build_c.sh wrote (.github/test.sh's <out>/c).
# Writes <out dir>/pja, then checks it: selftest, and every sample of the
# repository compressed and extracted, each back byte for byte and, given a
# reference pja (the glibc build of the same commit), the same .pja bytes as
# that one writes.
#
# Needs FreePascal (FPC, fpc by default), musl's static libc (Debian and
# Ubuntu: musl-tools) and binutils' ld. FreePascal links the binary through
# a linker script (link.res) that names glibc's startup files and library
# folder; the script is written with -s (no linking), its glibc parts are
# swapped for musl's, and ld links it with pjadlshim.o.
set -eu
CO=${1:?usage: static-musl.sh <C objects dir> <out dir> [reference pja]}
OUT=${2:?usage: static-musl.sh <C objects dir> <out dir> [reference pja]}
REF=${3:-}
FPC=${FPC:-fpc}
abs() { (cd "$1" && pwd); }
CO=$(abs "$CO")
rm -rf "$OUT"; mkdir -p "$OUT/u"; OUT=$(abs "$OUT")

# musl's folder: /usr/lib/<the triple, -gnu -> -musl>
TRIPLE=$(gcc -dumpmachine)
MUSL=/usr/lib/$(echo "$TRIPLE" | sed 's/-gnu$/-musl/')
for f in crt1.o crti.o crtn.o libc.a; do
  [ -f "$MUSL/$f" ] || { echo "no $MUSL/$f: install musl-tools"; exit 1; }
done

echo "== the units, assembled, and FreePascal's link script"
PJA_COMMIT=${PJA_COMMIT:-$(git rev-parse --short=7 HEAD 2>/dev/null || true)}
export PJA_COMMIT
$FPC -O3 -dPJA_FAST -Xt -s -Fupas -Fipas -Fo"$CO" -FU"$OUT/u" -o"$OUT/pja" pas/pjacli.pas \
  > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
# ppas.sh: the assembler's commands, then the linker's; only the first
sed '/^echo Linking/,$d' "$OUT/ppas.sh" > "$OUT/asm.sh"
sh "$OUT/asm.sh" > "$OUT/asm.log" 2>&1 || { cat "$OUT/asm.log"; exit 1; }
RES=$(grep -o -- '-T [^ ]*' "$OUT/ppas.sh" | cut -c4-)
[ -f "$RES" ] || { echo "no link script in ppas.sh"; exit 1; }

echo "== linked with musl"
# glibc's folder out, musl's crti.o and crtn.o in, no libgcc_eh nor libdl
# (pjadlshim.o is the dlopen); FreePascal's own cprt0.o starts the program
# through __libc_start_main, which musl has with the same arguments
sed -e "\|^SEARCH_DIR(\"/usr/lib/$TRIPLE/\")\$|d" \
    -e "\|^SEARCH_DIR(\"/lib/$TRIPLE/\")\$|d" \
    -e "s|^.*/crti\.o\$|$MUSL/crti.o|" \
    -e "s|^.*/crtn\.o\$|$MUSL/crtn.o|" \
    -e '/^-lgcc_eh$/d' -e '/^-ldl$/d' "$RES" > "$OUT/musl.res"
grep -q "$MUSL/crti.o" "$OUT/musl.res" || { echo "link script: crti.o not found"; exit 1; }
CC=${MUSLCC:-musl-gcc}
$CC -O2 -c pas/pjadlshim.c -o "$OUT/pjadlshim.o"
ld -static -s -L"$MUSL" -o "$OUT/pja" "$OUT/pjadlshim.o" -T "$OUT/musl.res" -e _start
file "$OUT/pja" | grep -q 'statically linked' || { file "$OUT/pja"; echo "FAIL: not static"; exit 1; }
# nothing of glibc's: its version symbols would be in the binary's strings
if strings "$OUT/pja" | grep -q 'GLIBC_2\.'; then echo "FAIL: glibc in the binary"; exit 1; fi

echo "== checked"
"$OUT/pja" --version | head -1
"$OUT/pja" selftest > "$OUT/selftest.txt" 2>&1 || { cat "$OUT/selftest.txt"; exit 1; }
tail -1 "$OUT/selftest.txt"
mkdir -p "$OUT/in" "$OUT/p" "$OUT/r" "$OUT/x"
cp tests/jpg/* tests/jls/* tests/j2k/* "$OUT/in/"
"$OUT/pja" a -q --output-dir="$OUT/p" "$OUT"/in/*
"$OUT/pja" x -q --output-dir="$OUT/x" "$OUT"/p/*.pja
n=0
for f in "$OUT"/in/*; do
  n=$((n + 1))
  cmp -s "$f" "$OUT/x/$(basename "$f")" || { echo "FAIL: $(basename "$f") does not come back"; exit 1; }
done
[ "$n" -ge 30 ] || { echo "FAIL: only $n samples"; exit 1; }
if [ -n "$REF" ]; then
  "$REF" a -q --output-dir="$OUT/r" "$OUT"/in/*
  for f in "$OUT"/p/*.pja; do
    cmp -s "$f" "$OUT/r/$(basename "$f")" || { echo "FAIL: $(basename "$f"): not the reference's bytes"; exit 1; }
  done
  [ "$(ls "$OUT/r" | wc -l)" -eq "$(ls "$OUT/p" | wc -l)" ] || { echo "FAIL: not the reference's files"; exit 1; }
fi
echo "$n samples back byte for byte${REF:+, every .pja the reference's}"
