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

echo "== build"
"$PAS/build_c.sh" "$OUT/c"
for prog in test_blake3 test_format test_corruption test_pjafs zpaql_segments; do
  $FPC -O2 -Fu"$PAS" -Fi"$PAS" -Fu"$PAS/plugin" -Fi"$PAS/plugin" -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done
# the command as it is shipped: the fast build
mkdir -p "$OUT/fast"
$FPC -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$OUT/fast" -o"$OUT/pja" "$PAS/pjacli.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }

echo "== tests"
"$OUT/test_blake3" "$PAS/tests/kat.txt" | tail -1
"$OUT/test_format" "$PJA/tests/jpg" "$PJA/tests/jls" | tail -1
"$OUT/test_corruption" "$PJA/tests/jpg" "$PJA/tests/jls" | grep -E '^  (format|end to end)|cells, '
# pjafs touches the disk: a directory of its own
rm -rf "$OUT/tmp_pjafs"; mkdir -p "$OUT/tmp_pjafs"; "$OUT/test_pjafs" "$(realpath "$OUT/tmp_pjafs")" | tail -1
"$PAS/tests/cli.sh" "$OUT/pja" "$OUT/tmp_cli" "$PJA/tests/jpg" "$PJA/tests/jls" | tail -1

echo "== the zpaq-std plugin's ZPAQL decoders (each also as its z codec's, --lz)"
python3 "$PJA/tools/zpaql/gen_pjadec.py" --check
rm -rf "$OUT/zpaql"; mkdir -p "$OUT/zpaql"
ZS=("$PJA/tests/jpg/grayscale.jpg" "$PJA/tests/jpg/solid_color.jpg" "$PJA/tests/jpg/prog_huffman.jpg"
    "$PJA/tests/jpg/arith_restart.jpg"
    "$PJA/tests/jls/gray2.jls" "$PJA/tests/jls/plasma17x13_sample_near1.jls"
    "$PJA/tests/jls/plasma17x13_line_rst4.jls")
"$OUT/zpaql_segments" "$OUT/zpaql" "${ZS[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" "$OUT/zpaql" "${ZS[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --lz "$OUT/zpaql" "${ZS[@]}" | tail -1
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
# pjalsx's: subsampled JPEG-LS, without interleave and in groups of lines
rm -rf "$OUT/zpaqlsx"; mkdir -p "$OUT/zpaqlsx"
ZSX=("$PJA/tests/jls/plasma33x17_none_sub.jls" "$PJA/tests/jls/color_line_subsampled.jls")
"$OUT/zpaql_segments" --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}"
python3 "$PJA/tools/zpaql/test_pjadec.py" --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}" | tail -1
python3 "$PJA/tools/zpaql/test_pjadec.py" --lz --pjalsx "$OUT/zpaqlsx" "${ZSX[@]}" | tail -1
