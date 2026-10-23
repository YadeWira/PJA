#!/bin/bash
# The pja command, from the outside: round trips, and each refusal with
# nothing written where it must not be.
#
#   tests/cli.sh <pja binary> <work directory> <dir with samples>...
set -uo pipefail
PJA=$(realpath "$1"); W=$2; shift 2
cells=0; failures=0
check() {   # check <description> <command...>: the command has to succeed
  local what=$1; shift
  cells=$((cells + 1))
  if "$@" > /dev/null 2>&1; then printf '  %-66s ok\n' "$what"
  else printf '  %-66s FAIL\n' "$what"; failures=$((failures + 1)); fi
}
rc() { "$@" > /dev/null 2>&1; echo $?; }

rm -rf "$W"; mkdir -p "$W/in" "$W/out"
for d in "$@"; do cp "$d"/* "$W/in/"; done
n=$(ls "$W/in" | wc -l)
check "samples: $n files" test "$n" -ge 10

echo "--- round trip of every sample"
check "a, all at once, into a directory" "$PJA" a -q "$W"/in/* -o "$W/pja/"
check "  one .pja per input" test "$(ls "$W/pja" | wc -l)" -eq "$n"
check "x, all at once" "$PJA" x -q "$W"/pja/*.pja -o "$W/out/"
same=0
for f in "$W"/in/*; do cmp -s "$f" "$W/out/$(basename "$f")" && same=$((same + 1)); done
check "  every file back byte for byte, with its extension ($same of $n)" test "$same" -eq "$n"
check "the same .pja with 1 thread and with 4" bash -c "
  '$PJA' a -q -th 1 '$W/in/color_plasma.jpg' -o '$W/t1.pja' && '$PJA' a -q --threads=4 '$W/in/color_plasma.jpg' -o '$W/t4.pja' &&
  cmp -s '$W/t1.pja' '$W/t4.pja'"
check "with -th 4 and several files, the lines follow the input order" bash -c "
  '$PJA' a -th 4 -f '$W'/in/*.jpg -o '$W/ord/' | sed 's/ ->.*//' > '$W/ord.txt' &&
  ls '$W'/in/*.jpg > '$W/ord_in.txt' && cmp -s '$W/ord.txt' '$W/ord_in.txt'"
check "--fast: every JPEG back byte for byte" bash -c "
  '$PJA' a -q --fast '$W'/in/*.jpg -o '$W/fast/' && '$PJA' x -q '$W'/fast/*.pja -o '$W/fastx/' &&
  for f in '$W'/in/*.jpg; do cmp -s \"\$f\" '$W/fastx/'\$(basename \"\$f\") || exit 1; done"
check "--fast with x: rc 2" test "$(rc "$PJA" x --fast "$W/pja/grayscale.pja" -o "$W/fx.jpg")" -eq 2
check "a file the codec cannot shrink is stored as is, and says so" bash -c "
  '$PJA' a -f '$W/in/gray8.jls' -o '$W/st.pja' | grep -q 'stored as is' && '$PJA' list '$W/st.pja' | grep -q 'stored as is' &&
  '$PJA' x -q '$W/st.pja' -o '$W/st.jls' && cmp -s '$W/in/gray8.jls' '$W/st.jls'"
check "--no-verify: the very same .pja" bash -c "
  '$PJA' a -q -f '$W/in/color_plasma.jpg' -o '$W/v1.pja' && '$PJA' a -q -f --no-verify '$W/in/color_plasma.jpg' -o '$W/v2.pja' &&
  cmp -s '$W/v1.pja' '$W/v2.pja'"
check "--no-verify with x: rc 2" test "$(rc "$PJA" x --no-verify "$W/v1.pja" -o "$W/nv.jpg")" -eq 2
check "the extension comes back as written (photo.JPEG, scan.Jls)" bash -c "
  cp '$W/in/grayscale.jpg' '$W/photo.JPEG' && cp '$W/in/gray2.jls' '$W/scan.Jls' &&
  '$PJA' a -q -f '$W/photo.JPEG' '$W/scan.Jls' -o '$W/ext/' && '$PJA' x -q '$W'/ext/*.pja -o '$W/extx/' &&
  cmp -s '$W/photo.JPEG' '$W/extx/photo.JPEG' && cmp -s '$W/scan.Jls' '$W/extx/scan.Jls'"
check "an extension the format does not keep: by the content" bash -c "
  cp '$W/in/grayscale.jpg' '$W/odd.x.y z' && '$PJA' a -q -f '$W/odd.x.y z' -o '$W/odd.pja' &&
  '$PJA' x -q '$W/odd.pja' -o '$W/oddx/' && cmp -s '$W/in/grayscale.jpg' '$W/oddx/odd.jpg'"
check "list shows the original size" bash -c "'$PJA' list '$W/pja/color_plasma.pja' | grep -q 'original $(stat -c %s "$W/in/color_plasma.jpg") B'"

echo "--- existing outputs"
cp "$W/in/grayscale.jpg" "$W/g.jpg"; "$PJA" a -q "$W/g.jpg"
echo old > "$W/g.jpg"
check "x over an existing file: refused (rc 1)" test "$(rc "$PJA" x "$W/g.pja")" -eq 1
check "  and the file is untouched" test "$(cat "$W/g.jpg")" = old
check "with -f: replaced" "$PJA" x -q -f "$W/g.pja"
check "  by the original" cmp -s "$W/g.jpg" "$W/in/grayscale.jpg"
echo victim > "$W/victim"; rm -f "$W/g.jpg"; ln -s "$W/victim" "$W/g.jpg"
check "a symbolic link with the output's name: refused" test "$(rc "$PJA" x "$W/g.pja")" -eq 1
check "  with -f, the link is replaced" bash -c "'$PJA' x -q -f '$W/g.pja' && [ ! -L '$W/g.jpg' ]"
check "  and its target never written through" test "$(cat "$W/victim")" = victim
rm -f "$W/g.jpg"; ln -s "$W/nowhere" "$W/g.jpg"
check "a dangling link also takes the name" test "$(rc "$PJA" x "$W/g.pja")" -eq 1
check "  and nothing is created where it points" test ! -e "$W/nowhere"
rm -f "$W/g.jpg"

echo plain > "$W/plain"
check "a write the system refuses: its own words, not just a number" bash -c "
  ! '$PJA' a '$W/in/grayscale.jpg' -o '$W/plain/x.pja' 2> '$W/err.txt' && grep -q 'could not write it: [A-Za-z]' '$W/err.txt'"
echo "--- what does not verify"
python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[20] ^= 1; open(sys.argv[2], 'wb').write(d)" "$W/g.pja" "$W/h.pja"
check "a .pja with one hash bit changed: rc 1" test "$(rc "$PJA" x "$W/h.pja")" -eq 1
check "  nothing written under the name" test ! -e "$W/h.jpg"
check "with --keep-corrupt: still rc 1" test "$(rc "$PJA" x --keep-corrupt "$W/h.pja")" -eq 1
check "  kept as h.jpg.corrupt, not as h.jpg" bash -c "[ -e '$W/h.jpg.corrupt' ] && [ ! -e '$W/h.jpg' ]"
python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[60] ^= 4; open(sys.argv[2], 'wb').write(d)" "$W/g.pja" "$W/p.pja"
check "one bit in the stream: rc 1, nothing written" bash -c "! '$PJA' x '$W/p.pja' 2>/dev/null && [ ! -e '$W/p.jpg' ]"
check "--max-output below the original: refused" test "$(rc "$PJA" x --max-output=100 "$W/g.pja" -o "$W/m.jpg")" -eq 1
check "  nothing written" test ! -e "$W/m.jpg"
check "--max-output=1K is enough for a 988-byte original" "$PJA" x -q --max-output=1K "$W/g.pja" -o "$W/m.jpg"

echo "--- what is not for this command"
check "a on a .pja: rc 1" test "$(rc "$PJA" a "$W/g.pja" -o "$W/gg.pja")" -eq 1
check "x on a JPEG: rc 1" test "$(rc "$PJA" x "$W/in/grayscale.jpg" -o "$W/xx.jpg")" -eq 1
echo "not a jpeg" > "$W/text.jpg"
check "a on something else: rc 1, nothing written" bash -c "! '$PJA' a '$W/text.jpg' 2>/dev/null && [ ! -e '$W/text.pja' ]"
check "one bad among good ones: rc 1" test "$(rc "$PJA" a "$W/text.jpg" "$W/in/grayscale.jpg" -o "$W/mix/")" -eq 1
check "  and the good one is written" test -e "$W/mix/grayscale.pja"
check "a directory as input: rc 1" test "$(rc "$PJA" a "$W/in")" -eq 1
check "a missing input: rc 1" test "$(rc "$PJA" a "$W/missing.jpg")" -eq 1

echo "--- options"
check "-n writes nothing" bash -c "'$PJA' a -q -n '$W/in/grayscale.jpg' -o '$W/dry.pja' && [ ! -e '$W/dry.pja' ]"
cp "$W/in/grayscale.jpg" "$W/-dash.jpg"
check "-- and a file that starts with a dash" bash -c "cd '$W' && '$PJA' a -q -- -dash.jpg && [ -e '-dash.pja' ]"
check "-o with several inputs and no directory: rc 2" test "$(rc "$PJA" a "$W/in/grayscale.jpg" "$W/in/solid_color.jpg" -o "$W/one.pja")" -eq 2
cp "$W/in/grayscale.jpg" "$W/写真ñ.jpg"
check "a non-ASCII name, both ways" bash -c "'$PJA' a -q '$W/写真ñ.jpg' -o '$W/u.pja' && '$PJA' x -q '$W/u.pja' -o '$W/写真ñ2.jpg' &&
  cmp -s '$W/写真ñ.jpg' '$W/写真ñ2.jpg'"
check "--output-dir" bash -c "'$PJA' a -q '$W/in/grayscale.jpg' --output-dir='$W/od' && [ -e '$W/od/grayscale.pja' ]"
check "an unknown option: rc 2" test "$(rc "$PJA" a --frobnicate "$W/in/grayscale.jpg")" -eq 2
check "the old glued -th4: rc 2, naming the spelling" bash -c "'$PJA' a -th4 x.jpg 2>&1 | grep -q 'write -th 4'"
check "an unknown command: rc 2" test "$(rc "$PJA" mix "$W/in/grayscale.jpg")" -eq 2
check "no files: rc 2" test "$(rc "$PJA" a)" -eq 2
check "--help: rc 0" "$PJA" --help

echo "$cells cells, $failures failures"
[ "$failures" -eq 0 ] && [ "$cells" -ge 40 ]
