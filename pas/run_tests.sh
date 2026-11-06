#!/bin/bash
# The .pja suite: the hash, the format, damage, writing the output, and the
# pja command. The codec has its own: run_codec_tests.sh.
#
# Each test demands its own minimum cell count: a test that runs zero cells
# is not green.
#
# set -e on purpose: if something does not compile or does not run, it stops here.
set -euo pipefail
FPC=${FPC:-fpc}
PAS=$(cd "$(dirname "$0")" && pwd); PJA=$(dirname "$PAS"); OUT=${PAS_OUT:-$PAS/build/format}
mkdir -p "$OUT"

echo "== source guards"
python3 "$PAS/collisions.py" "$PAS"
python3 "$PAS/results.py" "$PAS"
# the 7-Zip plugin's module version (major << 16 | minor, minor = the release's
# two digits, 0.9.5 -> 0.95) follows PJA_VERSION
v=$(sed -n "s/^  PJA_VERSION = '\([0-9.]*\)';.*/\1/p" "$PAS/pjacodec.pas")
m=$(echo "$v" | awk -F. '{printf "(%du << 16) | %du;", $1, $2*10+$3}')
grep -qF "$m" "$PAS/lib/pja7z.c" || { echo "pja7z.c: M_VERSION is not $m (PJA_VERSION $v)"; exit 1; }
echo "7-Zip module version follows PJA_VERSION $v"

echo "== build"
"$PAS/build_c.sh" "$OUT/c"
for prog in test_blake3 test_format test_corruption test_pjafs zpaql_segments test_zpaqlargs; do
  $FPC -O2 -Fu"$PAS" -Fi"$PAS" -Fu"$PAS/plugin" -Fi"$PAS/plugin" -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done
# the command as it is shipped: the fast build, with the commit it names in
# --version and report (as the zpaq-std plugin's build.sh)
export PJA_COMMIT=${PJA_COMMIT:-$(git -C "$PAS" describe --always --dirty --abbrev=7 2>/dev/null || true)}
mkdir -p "$OUT/fast"
$FPC -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$OUT/fast" -o"$OUT/pja" "$PAS/pjacli.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }

echo "== tests"
# the samples pja selftest carries: the files of tests/ and the .pja the
# command makes of them (the formats are frozen: they never change)
python3 "$PJA/tools/gen_selftest.py" --check "$OUT/pja"
"$OUT/test_blake3" "$PAS/tests/kat.txt" | tail -1
"$OUT/test_format" "$PJA/tests/jpg" "$PJA/tests/jls" | tail -1
"$OUT/test_corruption" "$PJA/tests/jpg" "$PJA/tests/jls" "$PJA/tests/j2k" | grep -E '^  (format|end to end)|cells, '
# pjafs touches the disk: a directory of its own
rm -rf "$OUT/tmp_pjafs"; mkdir -p "$OUT/tmp_pjafs"; "$OUT/test_pjafs" "$(realpath "$OUT/tmp_pjafs")" | tail -1
"$PAS/tests/cli.sh" "$OUT/pja" "$OUT/tmp_cli" "$PJA/tests/jpg" "$PJA/tests/jls" "$PJA/tests/j2k" | tail -1

echo "== the zpaq-std plugin's ZPAQL decoders (each also as its z codec's, --lz)"
python3 "$PJA/tools/zpaql/gen_pjadec.py" --check
# their H and what they refuse, on what is too large for test_pjadec.py
"$OUT/test_zpaqlargs" "$PJA/tests/jpg" | tail -1
rm -rf "$OUT/zpaql"; mkdir -p "$OUT/zpaql"
ZS=("$PJA/tests/jpg/grayscale.jpg" "$PJA/tests/jpg/solid_color.jpg" "$PJA/tests/jpg/prog_huffman.jpg"
    "$PJA/tests/jpg/arith_restart.jpg"
    "$PJA/tests/jls/gray2.jls" "$PJA/tests/jls/plasma17x13_sample_near1.jls"
    "$PJA/tests/jls/plasma17x13_line_rst4.jls")
"$OUT/zpaql_segments" "$OUT/zpaql" "${ZS[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" "$OUT/zpaql" "${ZS[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --lz "$OUT/zpaql" "${ZS[@]}" | tail -1
# the o codecs (opt=2): pjalso and pjalszo, on the JPEG-LS files
ZO=("$PJA/tests/jls/gray2.jls" "$PJA/tests/jls/plasma17x13_sample_near1.jls" "$PJA/tests/jls/plasma17x13_line_rst4.jls")
python3 "$PJA/tools/zpaql/test_pjadec.py" --o "$OUT/zpaql" "${ZO[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --o --lz "$OUT/zpaql" "${ZO[@]}" | tail -1
# the 8 codecs (opt=3): pjals8 and pjalsz8
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 "$OUT/zpaql" "${ZO[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --lz "$OUT/zpaql" "${ZO[@]}" | tail -1
# pjax: a DNL (version 5), and a JPEG after the EOI (version 6)
rm -rf "$OUT/zpaqlx"; mkdir -p "$OUT/zpaqlx"
ZX=("$PJA/tests/jpg/dnl_baseline.jpg" "$PJA/tests/jpg/image_after_eoi.jpg")
"$OUT/zpaql_segments" --pjax "$OUT/zpaqlx" "${ZX[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" --pjax "$OUT/zpaqlx" "${ZX[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --lz --pjax "$OUT/zpaqlx" "${ZX[@]}" | tail -1
# pjall's decoder: lossless JPEG, with restarts and with a DNL
rm -rf "$OUT/zpaqlll"; mkdir -p "$OUT/zpaqlll"
ZL=("$PJA/tests/jpg/lossless_restart.jpg" "$PJA/tests/jpg/dnl_lossless.jpg")
"$OUT/zpaql_segments" --pjall "$OUT/zpaqlll" "${ZL[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" --pjall "$OUT/zpaqlll" "${ZL[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --lz --pjall "$OUT/zpaqlll" "${ZL[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --o --pjall "$OUT/zpaqlll" "${ZL[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --o --lz --pjall "$OUT/zpaqlll" "${ZL[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --pjall "$OUT/zpaqlll" "${ZL[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --lz --pjall "$OUT/zpaqlll" "${ZL[@]}" | tail -1
# pjalsx's: subsampled JPEG-LS, without interleave and in groups of lines
rm -rf "$OUT/zpaqlsx"; mkdir -p "$OUT/zpaqlsx"
ZSX=("$PJA/tests/jls/plasma33x17_none_sub.jls" "$PJA/tests/jls/color_line_subsampled.jls")
"$OUT/zpaql_segments" --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --lz --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --o --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --o --lz --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --lz --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}" | tail -1
# the JPEG 2000 codec (stream version 8, modes 0 and 1): a raw codestream and a
# JP2, each with the H and M of its query, then both in one block
rm -rf "$OUT/zpaqlk"; mkdir -p "$OUT/zpaqlk"
ZK=("$PJA/tests/j2k/plasma_cs.j2k" "$PJA/tests/j2k/gray_12bit.jp2")
"$OUT/zpaql_segments" --pja2k "$OUT/zpaqlk" "${ZK[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" --pja2k "$OUT/zpaqlk" "${ZK[@]}" | tail -1
# the plugin as zpaq-std loads it (ctypes): its codecs, what the JPEG 2000
# codec takes, its compress, query and decompress
sh "$PAS/build_c.sh" "$OUT/pc" -fPIC
mkdir -p "$OUT/pu"
$FPC -O3 -dPJA_FAST -Cg -Fu"$PAS" -Fi"$PAS" -Fu"$PAS/plugin" -Fi"$PAS/plugin" -Fo"$OUT/pc" -FU"$OUT/pu" \
  -o"$OUT/pja_plugin.so" "$PAS/plugin/pja_zpaqstd.pas" > "$OUT/fpc.log" 2>&1 || { cat "$OUT/fpc.log"; exit 1; }
python3 "$PAS/tests/probe_plugin.py" "$OUT/pja_plugin.so" "$PJA/tests/j2k" "$PJA/tests/jpg" "$PJA/tests/jls"
# the version 7 codecs: pja7 (gray and 4:2:0, chroma against the luma, Cr
# against Cb), pjax7 (a DNL, 12 bits); each also as its z
rm -rf "$OUT/zpaql7"; mkdir -p "$OUT/zpaql7"
Z7=("$PJA/tests/jpg/grayscale.jpg" "$PJA/tests/jpg/baseline_color.jpg")
"$OUT/zpaql_segments" --pja7 "$OUT/zpaql7" "${Z7[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" --pja7 "$OUT/zpaql7" "${Z7[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --lz --pja7 "$OUT/zpaql7" "${Z7[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --pja7 "$OUT/zpaql7" "${Z7[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --lz --pja7 "$OUT/zpaql7" "${Z7[@]}" | tail -1
rm -rf "$OUT/zpaqlx7"; mkdir -p "$OUT/zpaqlx7"
ZX7=("$PJA/tests/jpg/dnl_baseline.jpg" "$PJA/tests/jpg/twelve_bit.jpg")
"$OUT/zpaql_segments" --pjax7 "$OUT/zpaqlx7" "${ZX7[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" --pjax7 "$OUT/zpaqlx7" "${ZX7[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --lz --pjax7 "$OUT/zpaqlx7" "${ZX7[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --pjax7 "$OUT/zpaqlx7" "${ZX7[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --v8 --lz --pjax7 "$OUT/zpaqlx7" "${ZX7[@]}" | tail -1
