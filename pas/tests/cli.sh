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
# the raw bytes' model in C (pjav7c.c) and in Pascal (PJA_NOASM=1): the
# same .pja, and each one's extracted by the other
check "the raw model in C = in Pascal: the same .pja, each extracted by the other" bash -c "
  PJA_NOASM=1 '$PJA' a -q '$W'/in/* -o '$W/pjan/' && for f in '$W'/pja/*.pja; do cmp -s \"\$f\" '$W/pjan/'\$(basename \"\$f\") || exit 1; done &&
  PJA_NOASM=1 '$PJA' x -q '$W'/pja/*.pja -o '$W/outn/' && '$PJA' x -q '$W'/pjan/*.pja -o '$W/outc/' &&
  for f in '$W'/in/*; do b=\$(basename \"\$f\"); cmp -s \"\$f\" '$W/outn/'\$b && cmp -s \"\$f\" '$W/outc/'\$b || exit 1; done"
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
check "a JPEG PJA cannot take (cut short): as bytes, says why, back byte for byte" bash -c "
  head -c 9000 '$W/in/color_plasma.jpg' > '$W/cut.jpg' && '$PJA' a -f '$W/cut.jpg' -o '$W/cut.pja' | grep -q 'as bytes: Truncated' &&
  '$PJA' x -q -f '$W/cut.pja' -o '$W/cutx/' && cmp -s '$W/cut.jpg' '$W/cutx/cut.jpg'"
python3 -I -c "
import sys, struct
for n, out in ((1024, sys.argv[1]), (1025, sys.argv[2])):
    b = b'\xff\xd8\xff\xdb\x00\x43\x00' + bytes([1] * 64)
    b += b'\xff\xc0' + struct.pack('>HBHHB', 11, 8, 8, 8, 1) + b'\x01\x11\x00'
    b += b'\xff\xc4\x00\x14\x00' + bytes([1] + [0] * 15) + b'\x00'
    b += b'\xff\xc4\x00\x14\x10' + bytes([1] + [0] * 15) + b'\x00'
    b += (b'\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00' + b'\x3f') * n + b'\xff\xd9'
    open(out, 'wb').write(b)" "$W/scans1024.jpg" "$W/scans1025.jpg"
check "1024 scans (the cap): taken, back byte for byte" bash -c "
  o=\$('$PJA' a -f '$W/scans1024.jpg' -o '$W/s1024.pja') && ! grep -q 'as bytes' <<< \"\$o\" &&
  '$PJA' x -q -f '$W/s1024.pja' -o '$W/s1024x/' && cmp -s '$W/scans1024.jpg' '$W/s1024x/s1024.jpg'"
check "1025 scans: as bytes, says why, back byte for byte" bash -c "
  '$PJA' a -f '$W/scans1025.jpg' -o '$W/s1025.pja' | grep -q 'as bytes: TooLarge' &&
  '$PJA' x -q -f '$W/s1025.pja' -o '$W/s1025x/' && cmp -s '$W/scans1025.jpg' '$W/s1025x/s1025.jpg'"
check "a JPEG-LS that ends with its scan, no EOI: as bytes, says why, back byte for byte" bash -c "
  head -c \$(( \$(wc -c < '$W/in/gray2.jls') - 2 )) '$W/in/gray2.jls' > '$W/noeoi.jls' &&
  '$PJA' a -f '$W/noeoi.jls' -o '$W/noeoi.pja' | grep -q 'as bytes: Truncated' &&
  '$PJA' x -q -f '$W/noeoi.pja' -o '$W/noeoix/' && cmp -s '$W/noeoi.jls' '$W/noeoix/noeoi.jls'"
check "a cut progressive scan with a restart every 3 blocks: repaired, back byte for byte" bash -c "
  '$PJA' a -f '$W/in/prog_restarts_cut.jpg' -o '$W/prc.pja' | grep -q 'repaired' &&
  '$PJA' x -q -f '$W/prc.pja' -o '$W/prcx/' && cmp -s '$W/in/prog_restarts_cut.jpg' '$W/prcx/prc.jpg'"
# a scan cut short at 1000 bytes of 17 KB, whose filler is longer than what
# is left: zero bits are empty blocks (EOB has the shortest code here)
python3 -I - "$W/cutlong.jpg" <<'EOF'
import sys, struct, math
dcb = [0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0]; acb = [0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d]
acv = bytes.fromhex('00020301041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa')
def codes(nb, vals):
    t = {}; c = 0; k = 0
    for l in range(16):
        for _ in range(nb[l]): t[vals[k]] = (c, l + 1); c += 1; k += 1
        c <<= 1
    return t
DC = codes(dcb, list(range(12))); AC = codes(acb, list(acv))
bits = []
def put(v, l): bits.extend((v >> (l - 1 - i)) & 1 for i in range(l))
def coef(t, run, v):
    s = abs(v).bit_length(); put(*t[run * 16 + s] if t is AC else t[s])
    if s: put(v if v >= 0 else v + (1 << s) - 1, s)
prev = 0
for by in range(64):
    for bx in range(64):
        dc = round(40 * math.sin(bx / 5) + 30 * math.cos(by / 7)); coef(DC, 0, dc - prev); prev = dc
        run = 0
        for k in range(1, 5):
            a = round(9 * math.cos(bx / (2 + k) + by / (3 + k)))
            if a: coef(AC, run, a); run = 0
            else: run += 1
        put(*AC[0])
bits += [1] * (-len(bits) % 8)
scan = bytearray()
for i in range(0, len(bits), 8):
    scan.append(int(''.join(map(str, bits[i:i + 8])), 2))
    if scan[-1] == 0xFF: scan.append(0)
o = b'\xff\xd8\xff\xdb\x00\x43\x00' + bytes([4] * 64)
o += b'\xff\xc0\x00\x0b\x08\x02\x00\x02\x00\x01\x01\x11\x00'
o += b'\xff\xc4\x00\x1f\x00' + bytes(dcb) + bytes(range(12))
o += b'\xff\xc4' + struct.pack('>H', 19 + len(acv)) + bytes([0x10] + acb) + acv
o += b'\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00' + scan + b'\xff\xd9'
open(sys.argv[1], 'wb').write(o[:1000])
EOF
check "a cut scan whose filler outgrows the file: repaired, back byte for byte" bash -c "
  '$PJA' a -f '$W/cutlong.jpg' -o '$W/cl.pja' | grep -q 'repaired' &&
  '$PJA' x -q -f '$W/cl.pja' -o '$W/clx/' && cmp -s '$W/cutlong.jpg' '$W/clx/cl.jpg'"
check "  with --no-verify: the very same .pja" bash -c "
  '$PJA' a -q -f --no-verify '$W/cutlong.jpg' -o '$W/cl2.pja' && cmp -s '$W/cl.pja' '$W/cl2.pja'"
check "list shows the original size" bash -c "'$PJA' list '$W/pja/color_plasma.pja' | grep -q 'original $(wc -c < "$W/in/color_plasma.jpg" | tr -d ' ') B'"

if [ -e "$W/in/plasma.jp2" ]; then
  echo "--- the JPEG 2000 family (stream version 8)"
  check "a says JPEG 2000, list too, x gives it back as .jp2" bash -c "
    '$PJA' a -f '$W/in/plasma.jp2' -o '$W/j2k/p.pja' | grep -q 'JPEG 2000' && '$PJA' list '$W/j2k/p.pja' | grep -q 'as .jp2, JPEG 2000' &&
    '$PJA' x -q '$W/j2k/p.pja' -o '$W/j2k/x/' && cmp -s '$W/in/plasma.jp2' '$W/j2k/x/p.jp2'"
  check "its codestream modelled (mode 1), not as bytes, and the .pja smaller than the file" bash -c "
    '$PJA' a -f '$W/in/plasma.jp2' -o '$W/j2k/m.pja' > '$W/j2k/m.txt' && grep -q '(JPEG 2000)' '$W/j2k/m.txt' &&
    ! grep -q 'as bytes' '$W/j2k/m.txt' && [ \$(wc -c < '$W/j2k/m.pja') -lt \$(wc -c < '$W/in/plasma.jp2') ]"
  check "the tests' PJA_J2K_SLICE does not change what the command writes (a codestream of tiles)" bash -c "
    '$PJA' a -q -f '$W/in/pcrl_tiles_plt_tlm.j2k' -o '$W/j2k/s0.pja' &&
    PJA_J2K_SLICE=1 '$PJA' a -q -f '$W/in/pcrl_tiles_plt_tlm.j2k' -o '$W/j2k/s1.pja' && cmp -s '$W/j2k/s0.pja' '$W/j2k/s1.pja'"
  check "an extension the format does not keep: .jp2, .j2k, .jpx, .mj2 by the content" bash -c "
    for f in plasma.jp2 plasma_cs.j2k two_codestreams.jpx two_frames.mj2; do
      cp '$W/in/'\$f '$W/j2k/odd.x y' && '$PJA' a -q -f '$W/j2k/odd.x y' -o '$W/j2k/odd.pja' &&
      rm -rf '$W/j2k/ox' && '$PJA' x -q '$W/j2k/odd.pja' -o '$W/j2k/ox/' && cmp -s '$W/in/'\$f '$W/j2k/ox/odd.'\${f##*.} || exit 1
    done"
  check "a JPEG 2000 file cut in half: taken, back byte for byte" bash -c "
    head -c 1800 '$W/in/plasma.jp2' > '$W/j2k/half.jp2' && '$PJA' a -q -f '$W/j2k/half.jp2' &&
    '$PJA' x -q '$W/j2k/half.pja' -o '$W/j2k/hx/' && cmp -s '$W/j2k/half.jp2' '$W/j2k/hx/half.jp2'"
  # the .pja's header is 40 B with the extension: a stream no smaller than
  # the file goes stored as is (612 B + 40), one smaller is kept even when
  # the .pja comes out larger than the file (cprl_poc: 1206 B in a stream
  # of 1190 B, 1230 B in all, where stored it would be 1246)
  check "a JPEG 2000 file whose stream is no smaller: stored as is; one a little smaller: the stream" bash -c "
    '$PJA' a -f '$W/in/plasma_cs.j2k' -o '$W/j2k/st.pja' | grep -q 'stored as is' &&
    [ \$(wc -c < '$W/j2k/st.pja') -eq \$((\$(wc -c < '$W/in/plasma_cs.j2k') + 40)) ] &&
    '$PJA' info '$W/j2k/st.pja' | grep -q 'stored: true' &&
    '$PJA' a -f '$W/in/cprl_poc.j2k' -o '$W/j2k/sk.pja' > '$W/j2k/sk.txt' && ! grep -q 'stored as is' '$W/j2k/sk.txt' &&
    [ \$(wc -c < '$W/j2k/sk.pja') -lt \$((\$(wc -c < '$W/in/cprl_poc.j2k') + 40)) ] &&
    '$PJA' info '$W/j2k/sk.pja' | grep -q 'stored: false' &&
    '$PJA' x -q '$W/j2k/st.pja' -o '$W/j2k/stx/' && cmp -s '$W/in/plasma_cs.j2k' '$W/j2k/stx/st.j2k' &&
    '$PJA' x -q '$W/j2k/sk.pja' -o '$W/j2k/skx/' && cmp -s '$W/in/cprl_poc.j2k' '$W/j2k/skx/sk.j2k'"
  python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[len(d) // 2] ^= 8; open(sys.argv[2], 'wb').write(d)" "$W/j2k/p.pja" "$W/j2k/bad.pja"
  check "one bit in a version 8 stream: rc 1, nothing written" bash -c "! '$PJA' x '$W/j2k/bad.pja' 2>/dev/null && [ ! -e '$W/j2k/bad.jp2' ]"
  # p.pja keeps the extension jp2: its stream from byte 40, the first codestream's mode 18 bytes in
  python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[40 + 18] = 5; open(sys.argv[2], 'wb').write(d)" "$W/j2k/p.pja" "$W/j2k/mode.pja"
  check "a codestream mode of a later release: rc 1, says FutureVersion" bash -c "
    ! '$PJA' x '$W/j2k/mode.pja' 2> '$W/j2k/err.txt' && grep -q 'FutureVersion' '$W/j2k/err.txt' && [ ! -e '$W/j2k/mode.jp2' ]"
fi
if [ -e "$W/in/bitonal.j2k" ]; then
  # b.pja keeps the extension j2k: its stream from byte 40, the codestream's mode 18 bytes in
  check "a 1-bit lossless codestream as its pixels (mode 2): JPEG 2000, under 60% of the file, back byte for byte" bash -c "
    '$PJA' a -f '$W/in/bitonal.j2k' -o '$W/j2k/b.pja' > '$W/j2k/b.txt' && grep -q '(JPEG 2000)' '$W/j2k/b.txt' &&
    [ \$(wc -c < '$W/j2k/b.pja') -lt \$((\$(wc -c < '$W/in/bitonal.j2k') * 6 / 10)) ] &&
    python3 -I -c 'import sys; sys.exit(open(sys.argv[1], \"rb\").read()[40 + 18] != 2)' '$W/j2k/b.pja' &&
    '$PJA' x -q '$W/j2k/b.pja' -o '$W/j2k/bx/' && cmp -s '$W/in/bitonal.j2k' '$W/j2k/bx/b.j2k'"
  check "a lossless RGB codestream of tiles (mode 2), back byte for byte" bash -c "
    '$PJA' a -q -f '$W/in/rgb_tiles53.j2k' -o '$W/j2k/r.pja' &&
    '$PJA' x -q '$W/j2k/r.pja' -o '$W/j2k/rx/' && cmp -s '$W/in/rgb_tiles53.j2k' '$W/j2k/rx/r.j2k'"
  python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[len(d) - 20] ^= 16; open(sys.argv[2], 'wb').write(d)" "$W/j2k/b.pja" "$W/j2k/bbad.pja"
  check "one bit in a mode 2 stream's pixels: rc 1, nothing written" bash -c "! '$PJA' x '$W/j2k/bbad.pja' 2>/dev/null && [ ! -e '$W/j2k/bbad.j2k' ]"
fi
if [ -e "$W/in/ht_ojph_tiles.j2c" ]; then
  # h.pja keeps the extension j2c: its stream from byte 40, the codestream's mode 18 bytes in
  check "an HTJ2K codestream modelled (mode 3): JPEG 2000, smaller than the file, back byte for byte" bash -c "
    '$PJA' a -f '$W/in/ht_ojph_tiles.j2c' -o '$W/j2k/h.pja' > '$W/j2k/h.txt' && grep -q '(JPEG 2000)' '$W/j2k/h.txt' &&
    [ \$(wc -c < '$W/j2k/h.pja') -lt \$(wc -c < '$W/in/ht_ojph_tiles.j2c') ] &&
    python3 -I -c 'import sys; sys.exit(open(sys.argv[1], \"rb\").read()[40 + 18] != 3)' '$W/j2k/h.pja' &&
    '$PJA' x -q '$W/j2k/h.pja' -o '$W/j2k/hx/' && cmp -s '$W/in/ht_ojph_tiles.j2c' '$W/j2k/hx/h.j2c'"
  check "a lossless HTJ2K file (JPH) as its pixels (mode 4), back byte for byte" bash -c "
    '$PJA' a -q -f '$W/in/ht_grk_lossless.jph' -o '$W/j2k/hp.pja' &&
    python3 -I -c 'import sys; sys.exit(open(sys.argv[1], \"rb\").read()[40 + 18] != 4)' '$W/j2k/hp.pja' &&
    '$PJA' x -q '$W/j2k/hp.pja' -o '$W/j2k/hpx/' && cmp -s '$W/in/ht_grk_lossless.jph' '$W/j2k/hpx/hp.jph'"
  python3 -I -c "
import sys
for a, b in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    d = bytearray(open(a, 'rb').read()); d[len(d) - 30] ^= 4; open(b, 'wb').write(d)" \
    "$W/j2k/h.pja" "$W/j2k/hbad.pja" "$W/j2k/hp.pja" "$W/j2k/hpbad.pja"
  check "one bit in a mode 3 stream, and in a mode 4 stream: rc 1, nothing written" bash -c "
    ! '$PJA' x '$W/j2k/hbad.pja' 2>/dev/null && [ ! -e '$W/j2k/hbad.j2c' ] &&
    ! '$PJA' x '$W/j2k/hpbad.pja' 2>/dev/null && [ ! -e '$W/j2k/hpbad.jph' ]"
  check "info --estimate on an HTJ2K codestream: mode 3, its code-blocks modelled" bash -c "
    o=\$('$PJA' info --estimate '$W/in/ht_ojph_tiles.j2c') && grep -q 'pja: mode 3 (HTJ2K, modelled): 2501 B -> ' <<< \"\$o\" &&
    grep -q 'B of HTJ2K codestreams modelled (mode 3)' <<< \"\$o\""
fi

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
check "cut short while writing (ulimit -f): nothing under the output's name" bash -c "
  (ulimit -f 1; '$PJA' x '$W/pja/color_plasma.pja' -o '$W/cutw/c.jpg') ; [ ! -e '$W/cutw/c.jpg' ]"
check "-n with an existing output: refused like the real run (rc 1)" test "$(rc "$PJA" a -n "$W/in/grayscale.jpg" -o "$W/g.pja")" -eq 1
L=$(printf 'n%.0s' $(seq 250)); cp "$W/in/grayscale.jpg" "$W/$L.jpg"
check "-f with a 254-byte name: the temporary is short" bash -c "
  '$PJA' a -q '$W/$L.jpg' && '$PJA' a -q -f '$W/$L.jpg' && rm '$W/$L.jpg' && '$PJA' x -q -f '$W/$L.pja' &&
  cmp -s '$W/in/grayscale.jpg' '$W/$L.jpg'"

echo "--- two inputs, one output"
mkdir -p "$W/dup/d1" "$W/dup/d2"; cp "$W/in/grayscale.jpg" "$W/dup/a.jpg"; cp "$W/in/color_plasma.jpg" "$W/dup/a.jpeg"
cp "$W/in/grayscale.jpg" "$W/dup/d1/p.jpg"; cp "$W/in/color_plasma.jpg" "$W/dup/d2/p.jpg"
check "a -f a.jpg a.jpeg: the later one fails, rc 1" bash -c "
  ! '$PJA' a -f -th 4 '$W/dup/a.jpg' '$W/dup/a.jpeg' 2> '$W/dup/err.txt' &&
  grep -q 'a.pja: also the output of .*a.jpg' '$W/dup/err.txt'"
check "  and a.pja holds a.jpg" bash -c "'$PJA' list '$W/dup/a.pja' | grep -q 'original $(wc -c < "$W/in/grayscale.jpg" | tr -d ' ') B'"
check "--output-dir with the same name from two folders: rc 1, one written" bash -c "
  ! '$PJA' a -f --output-dir='$W/dup/o' '$W/dup/d1/p.jpg' '$W/dup/d2/p.jpg' 2>/dev/null && [ -e '$W/dup/o/p.pja' ]"
check "x -f with the same output twice: rc 1" bash -c "
  '$PJA' a -q '$W/dup/d2/p.jpg' && ! '$PJA' x -f -q --output-dir='$W/dup/x' '$W/dup/o/p.pja' '$W/dup/d2/p.pja' 2>/dev/null"
check "the same with -n: rc 1" test "$(rc "$PJA" a -n -f "$W/dup/a.jpg" "$W/dup/a.jpeg")" -eq 1
cp "$W/in/grayscale.jpg" "$W/dup/q.jpg"; cp "$W/in/grayscale.jpg" "$W/dup/q.pja"
check "an output that is another input (a JPEG named q.pja): refused" bash -c "
  ! '$PJA' a -f -th 1 '$W/dup/q.jpg' '$W/dup/q.pja' 2> '$W/dup/err2.txt' && grep -q 'q.pja: also an input' '$W/dup/err2.txt'"
mkdir -p "$W/many"; for i in $(seq 24); do cp "$W/pja/grayscale.pja" "$W/many/g$i.pja"; done
check "x -th 8 of 24 files into one folder, 5 times: no job trips on another's temporary" bash -c "
  for n in 1 2 3 4 5; do rm -rf '$W/many/o'; '$PJA' x -q -th 8 '$W'/many/*.pja -o '$W/many/o/' || exit 1; done &&
  [ \$(ls -A '$W/many/o' | wc -l) -eq 24 ]"
mkdir -p "$W/bs";cp "$W/in/grayscale.jpg" "$W/bs/a\\x.jpg"; cp "$W/in/solid_color.jpg" "$W/bs/b\\x.jpg"
check "a backslash is part of the name on Unix: a\\x.jpg and b\\x.jpg" bash -c "
  '$PJA' a -q --output-dir='$W/bs/o' '$W/bs/a\\x.jpg' '$W/bs/b\\x.jpg' && [ -e '$W/bs/o/a\\x.pja' ] && [ -e '$W/bs/o/b\\x.pja' ]"

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

echo "--- interrupted runs, and the disk"
# strace with fault injection holds the write at its fsync, between a
# complete temporary and its rename, for as long as the test needs: the
# signal lands exactly there. Without it, the signal is sent as soon as a
# temporary shows up (a race the write usually wins: a weaker check).
mkdir -p "$W/sig"
for i in $(seq 24); do cp "$W/pja/color_plasma.pja" "$W/sig/c$i.pja"; done
HOLD=0
if command -v strace > /dev/null 2>&1 &&
   strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:delay_enter=1ms true > /dev/null 2>&1; then HOLD=1; fi
cat > "$W/sig.py" <<'EOF'
import glob, os, signal, subprocess, sys, time
pja, d, sig, hold, ignore = sys.argv[1], sys.argv[2], getattr(signal, sys.argv[3]), sys.argv[4] == '1', sys.argv[5] == '1'
out = os.path.join(d, 'o')
# ignored, the run goes to the end: one file, held twice (its data, its directory)
files = sorted(glob.glob(os.path.join(d, 'c*.pja')))[:1 if ignore else None]
cmd = [pja, 'x', '-q', '-f', '-th', '1'] + files + ['-o', out + '/']
if hold:
    cmd = ['strace', '-f', '-qq', '-o', '/dev/null', '-e', 'trace=fsync', '-e', 'inject=fsync:delay_enter=3s'] + cmd
# like nohup: an ignored signal stays ignored. Otherwise its default, set
# here: a suite started in the background by a script (cli.sh &) has
# SIGINT ignored, which pja would rightly keep (the cell failed so, never
# from the load itself)
def pre():
    signal.signal(sig, signal.SIG_IGN if ignore else signal.SIG_DFL)
p = subprocess.Popen(cmd, preexec_fn=pre)
def state(pid):
    try: return open('/proc/%d/stat' % pid).read().rsplit(')', 1)[1].split()[0]
    except (OSError, IndexError): return ''
# a temporary there (polled, not a fixed delay: the load only makes it later)
seen, t0 = False, time.time()
while time.time() - t0 < 120 and p.poll() is None:
    if glob.glob(os.path.join(out, '.pja-tmp-*')): seen = True; break
    time.sleep(0.005)
target = p.pid
if hold and seen and p.poll() is None:
    target = int(open('/proc/%d/task/%d/children' % (p.pid, p.pid)).read().split()[0])
    # and the write held at its fsync: stopped by the tracer (state t) on
    # five reads in a row, 20 ms apart (its other stops last microseconds)
    run, t1 = 0, time.time()
    while run < 5 and time.time() - t1 < 60 and p.poll() is None:
        run = run + 1 if state(target) == 't' else 0
        time.sleep(0.02)
if p.poll() is None: os.kill(target, sig)
rc = p.wait()
rc = 128 - rc if rc < 0 else rc
left = glob.glob(os.path.join(out, '.pja-tmp-*'))
print(rc, 'seen' if seen else 'missed', len(left))
EOF
sigcheck() {   # sigcheck <signal> <rc> [ignore]: no temporary left, and the conventional rc
  rm -rf "$W/sig/o"
  local r; r=$(python3 -I "$W/sig.py" "$PJA" "$W/sig" "$1" "$HOLD" "${3:-0}") || return 1
  set -- $r "$2"
  [ "$3" -eq 0 ] || return 1                         # a temporary left behind
  if [ "$HOLD" = 1 ]; then [ "$2" = seen ] && [ "$1" -eq "$4" ]
  else [ "$1" -eq "$4" ] || [ "$1" -eq 0 ]; fi        # the write may have won the race
}
if [ "$HOLD" = 1 ]; then how="held at its fsync"; else how="strace not here: racy"; fi
check "SIGINT while a temporary is written: deleted, rc 130 ($how)" sigcheck SIGINT 130
check "SIGTERM: the same, rc 143" sigcheck SIGTERM 143
check "SIGHUP: the same, rc 129" sigcheck SIGHUP 129
check "SIGPIPE: the same, rc 141" sigcheck SIGPIPE 141
# the real way to get it: the reader of the listing goes away (| head)
cat > "$W/pipe.py" <<'EOF2'
import glob, os, subprocess, sys
pja, d = sys.argv[1], sys.argv[2]
out = os.path.join(d, 'p')
bad = 0
for _ in range(3):
    subprocess.run(['rm', '-rf', out])
    r, w = os.pipe()
    os.close(r)                               # nobody reads: the first line written gets SIGPIPE
    p = subprocess.Popen([pja, 'x', '-f', '-th', '8'] + sorted(glob.glob(os.path.join(d, 'c*.pja'))) + ['-o', out + '/'],
                         stdout=w, preexec_fn=lambda: __import__('signal').signal(13, __import__('signal').SIG_DFL))
    os.close(w)
    rc = p.wait()
    rc = 128 - rc if rc < 0 else rc
    left = glob.glob(os.path.join(out, '.pja-tmp-*'))
    if left or rc not in (0, 141): bad += 1; print(rc, left)
sys.exit(1 if bad else 0)
EOF2
check "  the reader of its output gone (pja x | head): no temporary left, 3 runs" python3 -I "$W/pipe.py" "$PJA" "$W/sig"
if [ "$HOLD" = 1 ]; then
  check "a SIGINT ignored by whoever started it (nohup) stays ignored: rc 0" bash -c "
    r=\$(python3 -I '$W/sig.py' '$PJA' '$W/sig' SIGINT 1 1) && [ \"\$r\" = '0 seen 0' ] && [ -e '$W/sig/o/c1.jpg' ]"
  check "the data and then the directory reach the disk: fsync, rename, fsync" bash -c "
    strace -f -qq -o '$W/sync.txt' -e trace=fsync,rename,renameat2,link '$PJA' a -q -f '$W/in/grayscale.jpg' -o '$W/sync.pja' &&
    grep -oE '^[0-9]+ +(fsync|rename|renameat2|link)\(' '$W/sync.txt' | sed -E 's/^[0-9]+ +//; s/renameat2|link/rename/' | tr -d '(' |
      tr '\n' ' ' | grep -qx 'fsync rename fsync '"
  check "  and with -f, through the rename on top" bash -c "
    strace -f -qq -o '$W/sync2.txt' -e trace=fsync,rename,renameat2 '$PJA' x -q -f '$W/sync.pja' -o '$W/sync.jpg' &&
    grep -oE '^[0-9]+ +(fsync|rename|renameat2)\(' '$W/sync2.txt' | sed -E 's/^[0-9]+ +//; s/renameat2/rename/' | tr -d '(' |
      tr '\n' ' ' | grep -qx 'fsync rename fsync ' && cmp -s '$W/sync.jpg' '$W/in/grayscale.jpg'"
  check "the directory flush fails: rc 1, and the message says the file is there" bash -c "
    rm -f '$W/sync4.pja'
    ! strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:error=EIO:when=2 '$PJA' a -q '$W/in/grayscale.jpg' -o '$W/sync4.pja' 2> '$W/sync4.txt' &&
    grep -q 'sync4.pja: written, but its directory could not be flushed to the disk' '$W/sync4.txt' &&
    ! grep -q 'could not write it' '$W/sync4.txt' && [ -s '$W/sync4.pja' ]"
  check "  the data flush fails: rc 1, nothing left, not even a temporary" bash -c "
    rm -rf '$W/sync5'; mkdir '$W/sync5'
    ! strace -f -qq -o /dev/null -e trace=fsync -e inject=fsync:error=EIO:when=1 '$PJA' a -q '$W/in/grayscale.jpg' -o '$W/sync5/g.pja' 2> '$W/sync5.txt' &&
    grep -q 'could not write it' '$W/sync5.txt' && [ -z \"\$(ls -A '$W/sync5')\" ]"
  check "--no-sync: no fsync at all, and the file comes back" bash -c "
    strace -f -qq -o '$W/sync3.txt' -e trace=fsync,fdatasync '$PJA' a -q -f --no-sync '$W/in/grayscale.jpg' -o '$W/sync3.pja' &&
    ! grep -qE 'fsync|fdatasync' '$W/sync3.txt' && '$PJA' x -q -f '$W/sync3.pja' -o '$W/sync3.jpg' && cmp -s '$W/sync3.jpg' '$W/in/grayscale.jpg'"
else
  check "--no-sync: the file comes back" bash -c "
    '$PJA' a -q -f --no-sync '$W/in/grayscale.jpg' -o '$W/sync3.pja' && '$PJA' x -q -f --no-sync '$W/sync3.pja' -o '$W/sync3.jpg' &&
    cmp -s '$W/sync3.jpg' '$W/in/grayscale.jpg'"
  check "the data reaches the disk before the name (no strace: the round trip)" bash -c "
    '$PJA' a -q -f '$W/in/grayscale.jpg' -o '$W/sync.pja' && '$PJA' x -q -f '$W/sync.pja' -o '$W/sync.jpg' &&
    cmp -s '$W/sync.jpg' '$W/in/grayscale.jpg'"
fi

# what a SIGKILL leaves: noticed by the next run there, deleted only when asked
L="$W/left"; rm -rf "$L"; mkdir -p "$L"; cp "$W/in/grayscale.jpg" "$L/g.jpg"
sh -c 'exit 0' & wait $!; DEAD=$!                     # a pid that is gone
while kill -0 "$DEAD" 2> /dev/null; do DEAD=$((DEAD + 1)); done
mk() { echo left > "$L/$1"; touch -d "${2:-2 hours ago}" "$L/$1"; }
mk ".pja-tmp-$DEAD-0"; mk ".pja-tmp4"                 # old, of a dead run (and of 0.9.0)
mk ".pja-tmp-$DEAD-1" now                             # fresh: maybe still being written
mk ".pja-tmp-$$-0"                                    # old, but its process (this shell) lives
mk ".pja-tmp-$DEAD-x"                                 # not PJA's pattern
echo victim > "$W/left_victim"; ln -s "$W/left_victim" "$L/.pja-tmp-$DEAD-2"; touch -h -d '2 hours ago' "$L/.pja-tmp-$DEAD-2"
check "a run that writes there names the leftovers, rc 0, deletes nothing" bash -c "
  '$PJA' a -q '$L/g.jpg' 2> '$W/left.txt' && grep -q 'found 2 leftover temporaries of an interrupted run' '$W/left.txt' &&
  grep -q -- '--clean-temps' '$W/left.txt' && [ -e '$L/.pja-tmp-$DEAD-0' ] && [ -e '$L/.pja-tmp4' ]"
check "--clean-temps deletes the old one of a dead pid and the old pattern's" bash -c "
  '$PJA' a -q -f --clean-temps '$L/g.jpg' 2> '$W/left2.txt' && grep -q 'deleted 2 leftover temporaries' '$W/left2.txt' &&
  [ ! -e '$L/.pja-tmp-$DEAD-0' ] && [ ! -e '$L/.pja-tmp4' ]"
check "  not a fresh one, not a live process's, not another name" bash -c "
  [ -e '$L/.pja-tmp-$DEAD-1' ] && [ -e '$L/.pja-tmp-$$-0' ] && [ -e '$L/.pja-tmp-$DEAD-x' ]"
check "  not a symbolic link with the name, nor its target" bash -c "
  [ -L '$L/.pja-tmp-$DEAD-2' ] && [ \"\$(cat '$W/left_victim')\" = victim ]"
check "a run with nothing left there says nothing" bash -c "
  '$PJA' a -q -f --clean-temps '$L/g.jpg' 2> '$W/left3.txt' && [ ! -s '$W/left3.txt' ]"
check "--clean-temps with list: rc 2" test "$(rc "$PJA" list --clean-temps "$W/g.pja")" -eq 2
check "--no-sync with list: rc 2" test "$(rc "$PJA" list --no-sync "$W/g.pja")" -eq 2

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

echo "--- version, selftest, --cpu"
check "--version: the build, the compilers, the SIMD path" bash -c "
  o=\$('$PJA' --version) && head -1 <<< \"\$o\" | grep -q '^pja [0-9]' &&
  for k in commit built fpc c_compiler target system cpu_features cpu_path cpu_paths_supported c_simd_copies processors; do
    grep -q \"^\$k: \" <<< \"\$o\" || exit 1; done"
check "-V: the same" bash -c "[ \"\$('$PJA' -V)\" = \"\$('$PJA' --version)\" ]"
check "selftest: every check passed, rc 0" bash -c "'$PJA' selftest | grep -q 'checks passed'"
check "selftest -q: the summary alone" bash -c "[ \$('$PJA' selftest -q | wc -l) -eq 1 ]"
PATHS=$("$PJA" --version | sed -n 's/^cpu_paths_supported: //p')
check "--cpu: every path here ($PATHS) gives the very same .pja, and x takes it back" bash -c "
  '$PJA' a -q -f '$W/in/color_plasma.jpg' '$W/in/prog_huffman.jpg' '$W/in/gray8.jls' -o '$W/cpu/' || exit 1
  for p in $PATHS; do
    '$PJA' --cpu=\$p a -q -f '$W/in/color_plasma.jpg' '$W/in/prog_huffman.jpg' '$W/in/gray8.jls' -o '$W/cpu_'\$p/ || exit 1
    for f in color_plasma prog_huffman gray8; do cmp -s '$W/cpu/'\$f.pja '$W/cpu_'\$p/\$f.pja || exit 1; done
    '$PJA' x -q -f --cpu=\$p '$W/cpu_'\$p/color_plasma.pja -o '$W/cpu_x_'\$p.jpg &&
      cmp -s '$W/in/color_plasma.jpg' '$W/cpu_x_'\$p.jpg || exit 1
  done"
check "--cpu with a path that is no path: rc 2" test "$(rc "$PJA" --cpu=avx512 selftest)" -eq 2
for p in plain sse41 avx2; do
  case " $PATHS " in *" $p "*) ;; *)
    check "--cpu=$p, which this machine lacks: rc 2, naming those it has" bash -c "
      ! '$PJA' --cpu=$p selftest 2> '$W/cpuerr.txt' && grep -q 'it has: plain' '$W/cpuerr.txt'" ;;
  esac
done

echo "--- t"
mkdir -p "$W/t"; cp "$W/pja/grayscale.pja" "$W/pja/color_plasma.pja" "$W/pja/gray2.pja" "$W/t/"
cp "$W/p.pja" "$W/t/damaged.pja"
check "t: OK for each good .pja, rc 0" bash -c "
  [ \$('$PJA' t '$W/t/grayscale.pja' '$W/t/color_plasma.pja' '$W/t/gray2.pja' | grep -c ': OK') -eq 3 ]"
check "t -q -th 4: nothing printed, rc 0" bash -c "[ -z \"\$('$PJA' t -q -th 4 '$W/t/grayscale.pja' '$W/t/color_plasma.pja')\" ]"
check "t on a damaged .pja: FAILED, rc 1" bash -c "
  ! '$PJA' t '$W/t/grayscale.pja' '$W/t/damaged.pja' > '$W/t.out' 2> '$W/t.err' &&
  grep -q 'grayscale.pja: OK' '$W/t.out' && grep -q 'damaged.pja: FAILED' '$W/t.err'"
check "  and t wrote nothing" test "$(ls "$W/t" | wc -l)" -eq 4
check "t on a JPEG: rc 1" test "$(rc "$PJA" t "$W/in/grayscale.jpg")" -eq 1
check "t -o: rc 2 (t writes nothing)" test "$(rc "$PJA" t -o "$W/t/x" "$W/t/grayscale.pja")" -eq 2
check "t --max-output below the original: rc 1" test "$(rc "$PJA" t --max-output=100 "$W/t/grayscale.pja")" -eq 1

echo "--- info"
check "info on a JPEG: its frame, its scans, and that PJA takes it" bash -c "
  o=\$('$PJA' info '$W/in/prog_huffman.jpg') && grep -q 'format: JPEG' <<< \"\$o\" &&
  grep -q 'SOF2 at' <<< \"\$o\" && grep -q 'progressive: true' <<< \"\$o\" && grep -q 'pja: takes it: stream version 7' <<< \"\$o\""
check "info on an MPO: its MPF index and the image after the EOI" bash -c "
  o=\$('$PJA' info '$W/in/stereo.mpo') && grep -q 'format: MPO' <<< \"\$o\" && grep -q 'multi-frame disparity' <<< \"\$o\" &&
  grep -q 'after the EOI, ' <<< \"\$o\" && grep -q 'stream version 6 (parts)' <<< \"\$o\""
check "info on a JPEG-LS: NEAR and the interleave" bash -c "
  '$PJA' info '$W/in/color_sample_near2.jls' | grep -q 'NEAR 2, interleave 2'"
check "info on a JPEG PJA repairs: says why" bash -c "'$PJA' info '$W/in/restarts_misnumbered.jpg' | grep -q 'repaired: BadRst'"
check "info on a .pja: the container and its stream" bash -c "
  o=\$('$PJA' info '$W/pja/two_images.pja') && grep -q 'format: PJA' <<< \"\$o\" && grep -q 'original_size: ' <<< \"\$o\" &&
  grep -q 'kind: parts' <<< \"\$o\" && grep -q 'bands: ' <<< \"\$o\" && grep -q 'pja: extracts it' <<< \"\$o\""
check "info on a damaged .pja: does not extract it, rc 0" bash -c "'$PJA' info '$W/t/damaged.pja' | grep -q 'does not extract it'"
check "info on something else: PJA refuses it, rc 0" bash -c "'$PJA' info '$W/text.jpg' | grep -q 'refuses it: '"
check "info on a missing file: rc 1" test "$(rc "$PJA" info "$W/missing.jpg")" -eq 1
if [ -e "$W/in/two_codestreams.jpx" ]; then
  mkdir -p "$W/j2ki"
  check "info --estimate on a JPX: its boxes, two codestreams with SIZ and COD, each in mode 1, and that PJA takes it" bash -c "
    o=\$('$PJA' info --estimate '$W/in/two_codestreams.jpx') && grep -q 'format: JPX' <<< \"\$o\" && grep -q 'ftyp at 12, 24 B: brand jpx' <<< \"\$o\" &&
    grep -q '  ihdr at 44, 22 B: 64x64, 3 component(s), 8 bits' <<< \"\$o\" && grep -q 'jp2c at 809, 2421 B: codestream 1' <<< \"\$o\" &&
    grep -q 'codestream_count: 2' <<< \"\$o\" && grep -q 'SIZ at 199, 47 B: 64x64, 3 component(s) of 8 8 8 bits' <<< \"\$o\" &&
    grep -q 'COD at .*5 level(s), 1 layer(s), LRCP, code-blocks 64x64 (none), 5/3 reversible' <<< \"\$o\" &&
    [ \$(grep -c 'pja: mode 1 (modelled): ' <<< \"\$o\") -eq 2 ] &&
    grep -q 'pja: takes it: stream version 8 (JPEG 2000), .* B of codestreams modelled (mode 1)' <<< \"\$o\""
  check "info on a tiled codestream: the tile grid, its tile-parts, TLM and PLT, PCRL" bash -c "
    o=\$('$PJA' info '$W/in/pcrl_tiles_plt_tlm.j2k') && grep -q 'format: JPEG 2000 codestream' <<< \"\$o\" &&
    grep -q 'tile_grid: 2x2' <<< \"\$o\" && grep -q 'tile 1 part 0 at ' <<< \"\$o\" && grep -q 'tiles_present: 4' <<< \"\$o\" &&
    grep -q 'markers: SOC, SIZ, COD, TLM, PLT x36, QCD, COM, SOT x36, SOD x36, EOC' <<< \"\$o\" &&
    grep -q 'progression: PCRL' <<< \"\$o\" && grep -q 'eoc: true' <<< \"\$o\""
  # the code-block style's HT bit set in the COD (byte 63): an HTJ2K codestream whose code-blocks are not HT
  # ones, which mode 3 keeps as bytes, its stream no smaller: mode 0
  python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[63] = 0x40; open(sys.argv[2], 'wb').write(d)" "$W/in/plasma_cs.j2k" "$W/j2ki/ht.j2k"
  check "info --estimate on an HTJ2K codestream: ht true, mode 0 and the analysis's reason" bash -c "
    o=\$('$PJA' info --estimate '$W/j2ki/ht.j2k') && grep -q 'code-blocks 64x64 (HT)' <<< \"\$o\" && grep -q '  ht: true' <<< \"\$o\" &&
    grep -q 'pja: mode 0 (as bytes): mode 3: ' <<< \"\$o\" && grep -q 'no codestream modelled: all as bytes (mode 0)' <<< \"\$o\""
  check "info on it (no --estimate): the headers' verdict, HTJ2K for both modes, nothing coded" bash -c "
    o=\$('$PJA' info '$W/j2ki/ht.j2k') &&
    grep -q 'pja: not estimated (pja info --estimate codes it): mode 2: not eligible: HTJ2K; mode 1: not analysable: HTJ2K' <<< \"\$o\" &&
    grep -q 'pja: takes it: stream version 8 (JPEG 2000), or stored as is if that is no smaller; sizes not computed' <<< \"\$o\""
  # the COD's wavelet byte (64) set to 9/7, and the QCD's style (byte 69) to scalar expounded: not reversible
  python3 -I -c "
import sys; d = bytearray(open(sys.argv[1], 'rb').read()); d[64] = 0; open(sys.argv[2], 'wb').write(d)
d = bytearray(open(sys.argv[1], 'rb').read()); d[69] = (d[69] & 0xE0) | 2; open(sys.argv[3], 'wb').write(d)" \
    "$W/in/plasma_cs.j2k" "$W/j2ki/w97.j2k" "$W/j2ki/quant.j2k"
  check "info: mode 2 not eligible for the 9/7 wavelet or a quantization, mode 1 analysable, complete" bash -c "
    o=\$('$PJA' info '$W/j2ki/w97.j2k') && grep -q '9/7 irreversible' <<< \"\$o\" &&
    grep -q 'mode 2: not eligible: not reversible: the 9/7 wavelet; mode 1: analysable by its headers' <<< \"\$o\" &&
    '$PJA' info '$W/j2ki/quant.j2k' | grep -q 'mode 2: not eligible: not reversible: quantized; mode 1: analysable' &&
    '$PJA' info --json '$W/j2ki/w97.j2k' | head -1 | python3 -I -c '
import json, sys; c = json.load(sys.stdin)[\"codestreams\"][0][\"pja\"]
assert c[\"estimated\"] is False and c[\"complete\"] is True and c[\"mode2\"] == \"not eligible\" and c[\"mode1\"] == \"analysable\"
assert \"stream_bytes\" not in c'"
  check "info: a lossless codestream eligible by its headers; --estimate: mode 2 with its saving, mode 1's size" bash -c "
    '$PJA' info '$W/in/bitonal.j2k' | grep -q 'mode 2: eligible by its headers (whether every code-block has all its passes only --estimate tells); mode 1: analysable by its headers' &&
    o=\$('$PJA' info --estimate '$W/in/bitonal.j2k') &&
    grep -q 'pja: mode 2 (pixels): 1448 B -> [0-9]* B, [0-9.]*% less; mode 1: [0-9]* B' <<< \"\$o\" &&
    grep -q 'B of codestreams as pixels (mode 2)' <<< \"\$o\" &&
    '$PJA' info --estimate --json '$W/in/bitonal.j2k' | head -1 | python3 -I -c '
import json, sys; o = json.load(sys.stdin); c = o[\"codestreams\"][0][\"pja\"]
assert c[\"mode\"] == 2 and c[\"stream_bytes\"] == c[\"mode2_stream_bytes\"] < c[\"mode1_stream_bytes\"]
assert o[\"pja\"][\"j2k_pixels_bytes\"] == 1448 and o[\"pja\"][\"estimated\"] is True'"
  check "info --estimate on a rate-truncated codestream: mode 1, and mode 2's reason" bash -c "
    '$PJA' info --estimate '$W/in/cprl_poc.j2k' |
    grep -q 'pja: mode 1 (modelled): 1206 B -> [0-9]* B, [0-9.]*% less; mode 2: rate-truncated: a code-block without all its passes'"
  check "--estimate is for info: a and report refuse it, rc 2" bash -c "
    [ \$('$PJA' a --estimate '$W/in/bitonal.j2k' -o '$W/j2ki/e.pja' > /dev/null 2>&1; echo \$?) -eq 2 ] &&
    [ \$('$PJA' report --estimate '$W/in/bitonal.j2k' > /dev/null 2>&1; echo \$?) -eq 2 ] && [ ! -e '$W/j2ki/e.pja' ]"
  check "info on a JPEG: --estimate changes nothing (its dry run is the default)" bash -c "
    [ \"\$('$PJA' info '$W/in/prog_huffman.jpg')\" = \"\$('$PJA' info --estimate '$W/in/prog_huffman.jpg')\" ]"
  check "report: the dry run of a JPEG 2000 file (each codestream's mode and size)" bash -c "
    o=\$('$PJA' report '$W/in/bitonal.j2k') && grep -q 'pja: mode 2 (pixels): 1448 B -> ' <<< \"\$o\" &&
    grep -q 'pja: takes it: stream version 8 (JPEG 2000), 1448 B -> ' <<< \"\$o\""
  # past 64 MB a report does no dry run: the codestream and 64 MB of zeros after it
  cp "$W/in/plasma_cs.j2k" "$W/j2ki/big.j2k"
  truncate -s 65M "$W/j2ki/big.j2k"
  check "report on a file above 64 MB: no dry run, a note, the headers' verdict" bash -c "
    o=\$(timeout 60 '$PJA' report '$W/j2ki/big.j2k') &&
    grep -q 'pja: not estimated: the file is larger than 64 MB (pja info --estimate does the dry run)' <<< \"\$o\" &&
    grep -q 'pja: not estimated (pja info --estimate codes it): mode 2' <<< \"\$o\""
  rm -f "$W/j2ki/big.j2k"
  check "  privacy: no XML, label or COM text, in info, --json and report, only their sizes" bash -c "
    for c in info 'info --json' report; do
      o=\$('$PJA' \$c '$W/in/two_codestreams.jpx') || exit 1
      ! grep -q 'a test file of PJA' <<< \"\$o\" && ! grep -q 'two codestreams' <<< \"\$o\" && ! grep -q 'OpenJPEG' <<< \"\$o\" || exit 1
    done
    '$PJA' info '$W/in/two_codestreams.jpx' | grep -q 'metadata_bytes: XML 31 B, UUID 0 B, ICC 0 B, labels 15 B, URLs 0 B, IPR 0 B, 2 COM (66 B); contents not shown' &&
    '$PJA' info '$W/in/two_codestreams.jpx' | grep -q 'xml  at 112, 39 B: contents not shown'"
  check "info --json on the JPEG 2000 family: each file an object with its codestreams" bash -c "
    '$PJA' info --json '$W/in/two_codestreams.jpx' '$W/in/two_frames.mj2' '$W/in/plasma.jp2' '$W/in/plasma_cs.j2k' |
    python3 -I -c 'import json, sys; o = [json.loads(l) for l in sys.stdin]; assert len(o) == 5 and \"summary\" in o[-1]
assert all(x[\"format\"] != \"unknown\" and len(x[\"codestreams\"]) >= 1 for x in o[:-1])' &&
    '$PJA' info --json '$W/in/two_frames.mj2' | head -1 | python3 -I -c '
import json, sys; o = json.load(sys.stdin); assert o[\"format\"] == \"Motion JPEG 2000\" and o[\"codestream_count\"] == 2
assert all(c[\"pja\"][\"estimated\"] is False and c[\"siz\"][\"components\"] >= 1 for c in o[\"codestreams\"])
assert o[\"pja\"][\"stream_version\"] == 8'"
  check "info on a JPEG 2000 file cut short and damaged: its problems, rc 0, no internal error" bash -c "
    head -c 1500 '$W/in/pcrl_tiles_plt_tlm.j2k' > '$W/j2ki/cut.j2k' && o=\$('$PJA' info '$W/j2ki/cut.j2k') &&
    grep -q 'problems:' <<< \"\$o\" && grep -q 'no EOC' <<< \"\$o\" && ! grep -q internal_error <<< \"\$o\""
  check "info on the .pja of a JPEG 2000 file: stream version 8, each codestream's mode and slices" bash -c "
    '$PJA' a -q -f '$W/in/two_codestreams.jpx' -o '$W/j2ki/t.pja' && o=\$('$PJA' info '$W/j2ki/t.pja') &&
    grep -q 'version: 8' <<< \"\$o\" && [ \$(grep -c 'mode 1 (modelled), stream .* B in 1 slice(s)' <<< \"\$o\") -eq 2 ] &&
    grep -q 'bands: 2' <<< \"\$o\" && grep -q 'pja: extracts it' <<< \"\$o\""
  check "a --stats on a JPEG 2000 file: parse, encode and verify, its slices as bands; bench too" bash -c "
    '$PJA' a -f --stats -th 1 '$W/in/two_codestreams.jpx' -o '$W/j2ki/s.pja' |
    grep -q 'stats: read .*parse .*encode .*verify .*write .*; 1 thread(s), 2 band(s)' &&
    '$PJA' bench -r 1 '$W/in/two_codestreams.jpx' | grep -q '^  a .* MB/s  (.*encode .*verify'"
  check "mode 2 in --stats (its own check is the verify) and in info on its .pja: pixels, one band" bash -c "
    '$PJA' a -f --stats -th 1 '$W/in/bitonal.j2k' -o '$W/j2ki/b2.pja' |
    grep -q 'stats: read .*parse .*encode .*verify .*write .*; 1 thread(s), 1 band(s)' &&
    o=\$('$PJA' info '$W/j2ki/b2.pja') && grep -q 'at 0, 1448 B, mode 2 (pixels), stream [0-9]* B' <<< \"\$o\" &&
    grep -q 'pixels: 1' <<< \"\$o\" && grep -q 'bands: 1' <<< \"\$o\" && grep -q 'pja: extracts it' <<< \"\$o\""
fi

echo "--- report"
python3 -I -c "
import sys, struct
d = open(sys.argv[1], 'rb').read()
ex = b'Exif\0\0MM\0*\0\0\0\x08' + b'PRIVATE-EXIF-OWNER-NAME' * 3
com = b'PRIVATE-COMMENT-TEXT'
xmp = b'http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>PRIVATE-XMP-TEXT</x:xmpmeta>'
seg = lambda m, p: b'\xff' + bytes([m]) + struct.pack('>H', len(p) + 2) + p
open(sys.argv[2], 'wb').write(d[:2] + seg(0xE1, ex) + seg(0xE1, xmp) + seg(0xFE, com) + d[2:])" \
  "$W/in/grayscale.jpg" "$W/private.jpg"
mkdir -p "$W/rep"
check "report: the system, the file's hash, its structure, what PJA does" bash -c "
  '$PJA' report '$W/private.jpg' > '$W/rep/r.txt' && grep -q '^cpu_path: ' '$W/rep/r.txt' &&
  grep -q '^blake3_128: ' '$W/rep/r.txt' && grep -q 'APP1 Exif at 2' '$W/rep/r.txt' && grep -q 'COM at ' '$W/rep/r.txt' &&
  grep -q '^pja: takes it' '$W/rep/r.txt'"
check "  privacy: no EXIF, XMP or COM text in it, only their sizes" bash -c "
  ! grep -q 'PRIVATE' '$W/rep/r.txt' && grep -q 'Exif 83 B, XMP ' '$W/rep/r.txt' && grep -q '1 COM (20 B)' '$W/rep/r.txt'"
check "  privacy: the file's name, never its folders" bash -c "
  ! grep -q '$(basename "$W")/' '$W/rep/r.txt' && grep -q '^pja report private.jpg$' '$W/rep/r.txt'"
check "  a link to a new issue, its body the report, under 6000 characters" bash -c "
  u=\$(grep '^https://' '$W/rep/r.txt') &&
  [[ \$u == https://github.com/YadeWira/PJA/issues/new?template=bug_report.yml\&title=*\&body=PJA%20bug%20report* ]] &&
  [ \${#u} -le 6000 ] && ! grep -q PRIVATE <<< \"\$u\""
check "  a long one: the link cut, saying so" bash -c "
  u=\$('$PJA' report '$W/scans1024.jpg' | grep '^https://') && [ \${#u} -le 6000 ] && grep -q 'lines%20cut%20here' <<< \"\$u\""
check "report -o: the report in that file, the link on the screen" bash -c "
  '$PJA' report '$W/private.jpg' -o '$W/rep/out.txt' | grep -q '^https://github.com/YadeWira/PJA/issues/new' &&
  grep -q '^PJA bug report' '$W/rep/out.txt' && ! grep -q PRIVATE '$W/rep/out.txt'"
check "  an existing report is not replaced: rc 1" bash -c "
  echo keep > '$W/rep/keep.txt' && ! '$PJA' report '$W/private.jpg' -o '$W/rep/keep.txt' 2>/dev/null &&
  [ \"\$(cat '$W/rep/keep.txt')\" = keep ]"
check "report --with-file: the file copied beside the report, byte for byte" bash -c "
  '$PJA' report --with-file '$W/private.jpg' -o '$W/rep/w.txt' > /dev/null && cmp -s '$W/private.jpg' '$W/rep/pja-report-private.jpg'"
check "report with no file: the system part, rc 0" bash -c "'$PJA' report | grep -q '^== No file'"
check "report with two files: rc 2" test "$(rc "$PJA" report "$W/private.jpg" "$W/in/grayscale.jpg")" -eq 2
check "--with-file is for report: rc 2" test "$(rc "$PJA" a --with-file "$W/private.jpg")" -eq 2

echo "--- --stats and --json"
check "a --stats: each stage, the threads and bands, and a summary" bash -c "
  o=\$('$PJA' a -f --stats -th 1 '$W/in/color_plasma.jpg' '$W/in/gray2.jls' -o '$W/st/') &&
  [ \$(grep -c '  stats: read .*parse .*encode .*verify .*write .*; 1 thread(s), 1 band(s)' <<< \"\$o\") -eq 2 ] &&
  grep -q '^pja: 2 file(s), ' <<< \"\$o\""
check "x --stats: decode and hash" bash -c "
  '$PJA' x -f --stats '$W/st/color_plasma.pja' -o '$W/st/' | grep -q 'stats: read .*decode .*hash .*write'"
check "t --stats -q: the stats alone" bash -c "
  o=\$('$PJA' t -q --stats '$W/st/color_plasma.pja') && ! grep -q OK <<< \"\$o\" && grep -q 'stats: read' <<< \"\$o\""
check "--stats is not for list: rc 2" test "$(rc "$PJA" list --stats "$W/st/color_plasma.pja")" -eq 2
JS="import json, sys
lines = sys.stdin.read().splitlines()
objs = [json.loads(l) for l in lines]
assert objs and 'summary' in objs[-1], objs[-1:]
for o in objs[:-1]: assert 'file' in o and o['ok'] in (True, False)
assert len(objs) - 1 == int(sys.argv[1]), len(objs)"
check "a --json: a JSON object a file and a summary" bash -c "
  '$PJA' a -f --json --stats '$W/in/grayscale.jpg' '$W/in/cut_short.jpg' '$W/text.jpg' -o '$W/js/' 2>/dev/null |
  python3 -I -c \"\$1\" 3" _ "$JS"
check "  with the failure as ok false and its error" bash -c "
  '$PJA' a -f --json '$W/text.jpg' -o '$W/js/' 2>/dev/null | head -1 |
  python3 -I -c 'import json,sys; o=json.load(sys.stdin); assert o[\"ok\"] is False and \"Codec\" in o[\"error\"]'"
check "x --json" bash -c "'$PJA' x -f --json '$W'/js/*.pja -o '$W/js/' | python3 -I -c \"\$1\" 2" _ "$JS"
check "t --json" bash -c "'$PJA' t --json '$W/t/grayscale.pja' '$W/t/damaged.pja' 2>/dev/null | python3 -I -c \"\$1\" 2" _ "$JS"
check "list --json" bash -c "'$PJA' list --json '$W'/js/*.pja | python3 -I -c \"\$1\" 2" _ "$JS"
check "info --json, a JPEG, an MPO, a JPEG-LS, a .pja" bash -c "
  '$PJA' info --json '$W/in/thumbs_twice.jpg' '$W/in/stereo.mpo' '$W/in/color_line.jls' '$W/pja/two_images.pja' |
  python3 -I -c \"\$1\" 4" _ "$JS"
check "--json is not for bench: rc 2" test "$(rc "$PJA" bench --json "$W/in/grayscale.jpg")" -eq 2

echo "--- bench"
mkdir -p "$W/bench"; cp "$W/in/grayscale.jpg" "$W/pja/gray2.pja" "$W/bench/"
check "bench: a, a --no-verify and x, each with MB/s, rc 0" bash -c "
  o=\$('$PJA' bench -r 2 -th 2 '$W/bench/grayscale.jpg' '$W/bench/gray2.pja') && grep -q '^cpu_path: ' <<< \"\$o\" &&
  grep -q '^  a --no-verify .* MB/s' <<< \"\$o\" && [ \$(grep -c '^  x .* MB/s' <<< \"\$o\") -eq 3 ]"
check "  and nothing written beside the inputs" test "$(ls "$W/bench" | wc -l)" -eq 2
check "bench -r 0: rc 2" test "$(rc "$PJA" bench -r 0 "$W/bench/grayscale.jpg")" -eq 2
check "bench on something else: rc 1" test "$(rc "$PJA" bench "$W/text.jpg")" -eq 1

echo "--- a bug in PJA"
cp "$W/in/grayscale.jpg" "$W/bug.jpg"
check "an internal error (a range check): its own exit code, 3, and what to do" bash -c "
  PJA_TEST_CRASH=range '$PJA' a -f '$W/bug.jpg' -o '$W/bug.pja' 2> '$W/bug.txt'; [ \$? -eq 3 ] &&
  grep -q 'internal error: ERangeError' '$W/bug.txt' &&
  grep -q 'This is a bug in PJA. Please run: pja report .*bug.jpg and open an issue at https://github.com/YadeWira/PJA/issues' '$W/bug.txt'"
check "  and nothing written" test ! -e "$W/bug.pja"
check "an access violation, in a worker thread: rc 3" bash -c "
  PJA_TEST_CRASH=access '$PJA' a -f -th 4 '$W/bug.jpg' '$W/in/solid_color.jpg' -o '$W/bugs/' 2> '$W/bug2.txt'; [ \$? -eq 3 ] &&
  grep -q 'EAccessViolation' '$W/bug2.txt' && grep -q 'This is a bug in PJA' '$W/bug2.txt'"
check "a file that fails as a file is not a bug: rc 1" bash -c "'$PJA' a '$W/text.jpg' 2> '$W/nb.txt'; [ \$? -eq 1 ] && ! grep -q 'bug' '$W/nb.txt'"

echo "--- the review's cases"
check "selftest has a stream version 5 sample (its own SSE4.1 kernels)" bash -c "'$PJA' selftest | grep -q '(version 5): '"
check "selftest --cpu=plain: that path alone" bash -c "'$PJA' selftest --cpu=plain -q | grep -q 'on 1 path(s) (plain)'"
check "the default path is among those --cpu takes" bash -c "
  p=\$('$PJA' --version | sed -n 's/^cpu_path: //p') && '$PJA' --cpu=\$p --version > /dev/null"
check "--cpu avx2 (a space) before the command: rc 2, naming --cpu=avx2" bash -c "
  '$PJA' --cpu avx2 selftest 2>&1 | grep -q 'write --cpu=avx2' && [ \$('$PJA' --cpu avx2 selftest > /dev/null 2>&1; echo \$?) -eq 2 ]"
check "  and after it" bash -c "'$PJA' selftest --cpu plain 2>&1 | grep -q 'write --cpu=plain'"
check "report --with-file without a file: rc 2" test "$(rc "$PJA" report --with-file)" -eq 2
# a .pja that declares 65536 times its payload (about 4 GB) of version 5
python3 -I -c "
import sys, struct, random
random.seed(1); hdr = random.randbytes(65562)
payload = bytes([5, 0]) + struct.pack('<I', len(hdr)) + hdr
open(sys.argv[1], 'wb').write(b'PJA\x01' + bytes([3, 0, 0, 0]) + struct.pack('<Q', 65536 * len(payload)) + bytes(16) + payload)" \
  "$W/bomb.pja"
check "info on a .pja declaring more than --max-output: not decoded, at once" bash -c "
  timeout 10 '$PJA' info '$W/bomb.pja' | grep -q 'not_decoded: the original is larger than --max-output'"
check "  report too" bash -c "timeout 10 '$PJA' report '$W/bomb.pja' | grep -q 'not_decoded'"
python3 -I -c "
import sys; open(sys.argv[1], 'wb').write(b'\xff\xd8' + b'\xff\x00' * (1 << 19) + b'\xff\xd9')" "$W/ff00.jpg"
check "a JPEG of FF 00 only: its problems listed up to 100, then counted" bash -c "
  o=\$('$PJA' info '$W/ff00.jpg') && [ \$(grep -c 'FF 00 outside a scan' <<< \"\$o\") -eq 100 ] &&
  grep -q 'problems_not_listed: 524188' <<< \"\$o\""
check "  info --json of it small, report too" bash -c "
  [ \$('$PJA' info --json '$W/ff00.jpg' | wc -c) -lt 20000 ] && [ \$('$PJA' report '$W/ff00.jpg' | wc -c) -lt 30000 ]"
if [ -w /dev/full ]; then
  check "output on a full disk: said, rc 1, not a bug (t, list, info, --version, selftest)" bash -c "
    for c in 't $W/t/grayscale.pja' 'list $W/t/grayscale.pja' 'info $W/in/grayscale.jpg' '--version' 'selftest -q'; do
      '$PJA' \$c > /dev/full 2> '$W/full.txt'; [ \$? -eq 1 ] || exit 1
      grep -q 'could not write the output' '$W/full.txt' && ! grep -q 'bug' '$W/full.txt' || exit 1
    done"
fi
python3 -I -c "
import sys; b = bytearray(open(sys.argv[1], 'rb').read()); b[0x12] ^= 1; open(sys.argv[2], 'wb').write(b)" \
  "$W/t/grayscale.pja" "$W/hashbad.pja"
check "x -n on a .pja whose hash does not match: rc 1, as x and t" bash -c "
  ! '$PJA' x -n -o '$W/hb.jpg' '$W/hashbad.pja' 2> '$W/hb.txt' && grep -q 'does not verify' '$W/hb.txt' &&
  ! '$PJA' t '$W/hashbad.pja' 2> /dev/null && [ ! -e '$W/hb.jpg' ]"
check "-q --stats: each stats line under its file's name" bash -c "
  o=\$('$PJA' t -q --stats '$W/t/grayscale.pja' '$W/t/color_plasma.pja') &&
  [ \"\$(grep -A1 -x '$W/t/grayscale.pja:' <<< \"\$o\" | grep -c '^  stats: ')\" -eq 1 ] &&
  [ \"\$(grep -A1 -x '$W/t/color_plasma.pja:' <<< \"\$o\" | grep -c '^  stats: ')\" -eq 1 ]"
check "a near-lossless JPEG-LS is not said lossless" bash -c "
  o=\$('$PJA' info '$W/in/color_sample_near2.jls') && grep -q '^  lossless: false' <<< \"\$o\" &&
  grep -q 'near_lossless: true' <<< \"\$o\""
check "MPF entries at their place in the file, as the embedded image" bash -c "
  o=\$('$PJA' info '$W/in/stereo.mpo') && at=\$(sed -n 's/.*after the EOI, \\([0-9]*\\) B.*/\\1/p' <<< \"\$o\" | head -1) &&
  pos=\$(sed -n 's/.* - at \\([0-9]*\\) after the EOI.*/\\1/p' <<< \"\$o\" | head -1) &&
  grep -q \"B at \$pos (.* in the MPF index)\" <<< \"\$o\""
mkdir -p "$W/-private_dir"; cp "$W/in/grayscale.jpg" "$W/-private_dir/x.jpg"
check "report: a folder starting with a dash (after --) is not shown" bash -c "
  cd '$W' && o=\$('$PJA' report -- -private_dir/x.jpg) && ! grep -q private_dir <<< \"\$o\" && grep -q '^file: x.jpg' <<< \"\$o\""
cp "$W/in/grayscale.jpg" "$W/a.$(printf 'é%.0s' $(seq 110))"
check "  a long UTF-8 name: the issue's title cut between characters" bash -c "
  '$PJA' report '$W'/a.é* | grep '^https://' | python3 -I -c '
import sys, urllib.parse as u
q = u.urlparse(sys.stdin.read().strip()).query
t = u.parse_qs(q, errors=\"strict\")[\"title\"][0]
assert len(t.encode()) <= 200'"
python3 -I -c "
import sys, struct
d = open(sys.argv[1], 'rb').read()
com = b''.join(b'\xff\xfe' + struct.pack('>H', 10) + b'NOTE%04d' % i for i in range(200))
open(sys.argv[2], 'wb').write(d[:2] + com + d[2:])" "$W/in/grayscale.jpg" "$W/many.jpg"
check "a report too long for the link: says so, keeps the frame and PJA's verdict" bash -c "
  o=\$('$PJA' report '$W/many.jpg') && grep -q 'room for part of it' <<< \"\$o\" &&
  u=\$(grep '^https://' <<< \"\$o\") && [ \${#u} -le 6000 ] && grep -q 'frame%3A' <<< \"\$u\" &&
  grep -q 'pja%3A%20takes%20it' <<< \"\$u\" && ! grep -q NOTE <<< \"\$u\""
check "--json: original_size and pja_size in a, x, t, list; info's stream_version" bash -c "
  '$PJA' a -f --json '$W/in/grayscale.jpg' -o '$W/jn/' | head -1 > '$W/jn.txt' &&
  '$PJA' x -f --json '$W/jn/grayscale.pja' -o '$W/jn/' | head -1 >> '$W/jn.txt' &&
  '$PJA' t --json '$W/jn/grayscale.pja' | head -1 >> '$W/jn.txt' &&
  '$PJA' list --json '$W/jn/grayscale.pja' | head -1 >> '$W/jn.txt' &&
  '$PJA' info --json '$W/in/grayscale.jpg' | head -1 >> '$W/jn.txt' &&
  python3 -I -c '
import json, sys
o = [json.loads(l) for l in open(sys.argv[1])]
for k in o[:4]: assert isinstance(k[\"original_size\"], int) and isinstance(k[\"pja_size\"], int), k
assert o[4][\"pja\"][\"stream_version\"] == 7' '$W/jn.txt'"

echo "--- usage"
check "selftest with a file: rc 2" test "$(rc "$PJA" selftest "$W/bug.jpg")" -eq 2
check "info -o: rc 2" test "$(rc "$PJA" info -o "$W/x.txt" "$W/bug.jpg")" -eq 2
check "-r for a: rc 2" test "$(rc "$PJA" a -r 2 "$W/bug.jpg")" -eq 2
check "report -f: rc 2" test "$(rc "$PJA" report -f "$W/bug.jpg")" -eq 2

echo "--- durable writes with the new commands (0.9.5)"
for c in t info; do
  check "--no-sync with $c: rc 2" test "$(rc "$PJA" $c --no-sync "$W/g.pja")" -eq 2
  check "--clean-temps with $c: rc 2" test "$(rc "$PJA" $c --clean-temps "$W/g.pja")" -eq 2
done
check "--no-sync with selftest: rc 2" test "$(rc "$PJA" selftest --no-sync)" -eq 2
check "--clean-temps with bench: rc 2" test "$(rc "$PJA" bench --clean-temps "$W/bench/grayscale.jpg")" -eq 2
check "--clean-temps with report: rc 2" test "$(rc "$PJA" report --clean-temps "$W/bench/grayscale.jpg")" -eq 2
mkdir -p "$W/btmp"
check "bench --no-sync: its write measured without the flush, rc 0" bash -c "
  TMPDIR='$W/btmp' '$PJA' bench --no-sync -r 1 '$W/bench/grayscale.jpg' | grep -q '^  write .*(--no-sync)'"
check "bench: the write flushed by default (no --no-sync on it)" bash -c "
  o=\$(TMPDIR='$W/btmp' '$PJA' bench -r 1 '$W/bench/grayscale.jpg') && grep -q '^  write ' <<< \"\$o\" &&
  ! grep -q 'no-sync' <<< \"\$o\""
check "  and its temporary directory left empty" test -z "$(ls -A "$W/btmp")"
check "report -o --no-sync: the report written" bash -c "
  rm -f '$W/rep/ns.txt' && '$PJA' report --no-sync '$W/private.jpg' -o '$W/rep/ns.txt' > /dev/null &&
  grep -q '^PJA bug report' '$W/rep/ns.txt'"
L2="$W/left2"; rm -rf "$L2"; mkdir -p "$L2"; cp "$W/g.pja" "$L2/g.pja"
echo left > "$L2/.pja-tmp-$DEAD-0"; touch -d '2 hours ago' "$L2/.pja-tmp-$DEAD-0"
check "t beside a leftover: rc 0, says nothing of it, deletes nothing" bash -c "
  '$PJA' t -q '$L2/g.pja' 2> '$W/t_left.txt' && [ ! -s '$W/t_left.txt' ] && [ -e '$L2/.pja-tmp-$DEAD-0' ]"
check "x -n --clean-temps: names the leftover, deletes nothing, writes nothing" bash -c "
  '$PJA' x -n --clean-temps '$L2/g.pja' 2> '$W/xn_left.txt' && grep -q 'leftover' '$W/xn_left.txt' &&
  [ -e '$L2/.pja-tmp-$DEAD-0' ] && [ \$(ls -A '$L2' | wc -l) -eq 2 ]"
check "an internal error during x: rc 3, the bug message, no temporary left" bash -c "
  mkdir -p '$W/bugx' && PJA_TEST_CRASH=range '$PJA' x -f '$W/g.pja' -o '$W/bugx/' 2> '$W/bugx.txt'; [ \$? -eq 3 ] &&
  grep -q 'This is a bug in PJA' '$W/bugx.txt' && [ -z \"\$(ls -A '$W/bugx')\" ]"
check "--stats -th 2 on a one-band JPEG: verified live, 2 threads, 1 band" bash -c "
  '$PJA' a -f --stats -th 2 '$W/in/color_plasma.jpg' -o '$W/st2.pja' | grep -q 'encode .*total .*2 thread(s), 1 band(s)' &&
  '$PJA' a -q -f -th 1 '$W/in/color_plasma.jpg' -o '$W/st1.pja' && cmp -s '$W/st1.pja' '$W/st2.pja'"

echo "$cells cells, $failures failures"
[ "$failures" -eq 0 ] && [ "$cells" -ge 100 ]
