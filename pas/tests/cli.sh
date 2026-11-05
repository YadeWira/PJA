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
  for k in commit built fpc c_compiler target system cpu_features cpu_path cpu_paths_supported processors; do
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
  u=\$('$PJA' report '$W/scans1024.jpg' | grep '^https://') && [ \${#u} -le 6000 ] && grep -q '%5Bcut' <<< \"\$u\""
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

echo "--- usage"
check "selftest with a file: rc 2" test "$(rc "$PJA" selftest "$W/bug.jpg")" -eq 2
check "info -o: rc 2" test "$(rc "$PJA" info -o "$W/x.txt" "$W/bug.jpg")" -eq 2
check "-r for a: rc 2" test "$(rc "$PJA" a -r 2 "$W/bug.jpg")" -eq 2
check "report -f: rc 2" test "$(rc "$PJA" report -f "$W/bug.jpg")" -eq 2

echo "$cells cells, $failures failures"
[ "$failures" -eq 0 ] && [ "$cells" -ge 100 ]
