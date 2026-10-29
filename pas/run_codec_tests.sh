#!/bin/bash
# The codec test suite (doc/CODEC.md), layer by layer.
#
#   pas/run_codec_tests.sh                       what is in the repo
#   JPEG_CORPUS=dir1:dir2 pas/run_codec_tests.sh  plus the round trip over those directories
#
# Each test demands its own minimum count: one that runs zero cells is not green.
set -euo pipefail
FPC=${FPC:-fpc}
PAS=$(cd "$(dirname "$0")" && pwd); PJA=$(dirname "$PAS"); OUT=${PAS_OUT:-$PAS/build/codec}
mkdir -p "$OUT"

echo "== source guards"
python3 "$PAS/collisions.py" "$PAS"
python3 "$PAS/results.py" "$PAS"

echo "== build"
# the C part (stream version 7's model), and the same without SSE2
"$PAS/build_c.sh" "$OUT/c"
"$PAS/build_c.sh" "$OUT/cplain" -DPJA_V7_PLAIN
for prog in test_jpeg test_jpeg_corrupt test_tolerances test_jls test_arith test_codec test_codec_corrupt; do
  $FPC -O2 -g -gl -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== layer 1: JPEG <-> coefficients"
"$OUT/test_jpeg" "$PJA/tests/jpg" 11 | tail -1
# every bit of the first 2 KB and every truncation: no exception; the same
# verdicts with the Huffman scans in C (pjasysc.c) and in Pascal
"$OUT/test_jpeg" "$PJA/tests/jpg" 11 > "$OUT/jpeg_c.txt"; PJA_NOASM=1 "$OUT/test_jpeg" "$PJA/tests/jpg" 11 > "$OUT/jpeg_pas.txt"
cmp -s "$OUT/jpeg_c.txt" "$OUT/jpeg_pas.txt" || { echo "FAIL: test_jpeg differs with PJA_NOASM=1"; exit 1; }
"$OUT/test_jpeg_corrupt" "$PJA/tests/jpg" 2048 | tail -1 | tee "$OUT/corrupt_c.txt"
PJA_NOASM=1 "$OUT/test_jpeg_corrupt" "$PJA/tests/jpg" 2048 | tail -1 > "$OUT/corrupt_pas.txt"
cmp -s "$OUT/corrupt_c.txt" "$OUT/corrupt_pas.txt" || { echo "FAIL: other verdicts with PJA_NOASM=1"; cat "$OUT/corrupt_pas.txt"; exit 1; }
# what libjpeg does not do but other encoders do: extra RSTs, EOB runs cut by the table
"$OUT/test_tolerances" "$PJA/tests/jpg" | tail -1
echo "== layer 1, JPEG-LS: samples"
"$OUT/test_jls" "$PJA/tests/jls" 8 | tail -1
"$OUT/test_jpeg_corrupt" "$PJA/tests/jls" 256 | tail -1
IFS=: read -ra dirs <<< "${JPEG_CORPUS:-}"
for d in "${dirs[@]}"; do "$OUT/test_jpeg" "$d" 1 | tail -1; done

echo "== layer 2: arithmetic coder"
"$OUT/test_arith" | tail -1

echo "== layers 3 and 4: model and stream"
"$OUT/test_codec" "$PJA/tests/jpg" 11 | tail -2
"$OUT/test_codec" "$PJA/tests/jls" 8 | tail -2
echo "-- the fast model"
PJA_TEST_FAST=1 "$OUT/test_codec" "$PJA/tests/jpg" 11 | tail -2
# every bit of the first 128 bytes of each stream and every truncation: no
# exception. On the checked build, the one that catches an access out of
# range; 128 and not more because a damaged header can declare a huge image.
"$OUT/test_codec_corrupt" "$PJA/tests/jpg" 128 | tail -1
"$OUT/test_codec_corrupt" "$PJA/tests/jls" 64 | tail -1
PJA_TEST_FAST=1 "$OUT/test_codec_corrupt" "$PJA/tests/jpg" 128 | tail -1
echo "-- stream version 7 (the C model)"
PJA_TEST_V7=1 "$OUT/test_codec" "$PJA/tests/jpg" 11 | tail -2
PJA_TEST_V7=1 "$OUT/test_codec_corrupt" "$PJA/tests/jpg" 128 | tail -1
# bands decoded last first (PJA_BANDS_REVERSE=1, one thread): no band reads
# what an earlier one decodes. Several bands each, one with a fractional
# vertical sampling (luma 1x3, chroma 1x2: a chroma row maps to the luma of
# the band before), one 4:2:0
SAMP=$OUT/sampling; rm -rf "$SAMP"; mkdir -p "$SAMP"
python3 "$PAS/tests/mkjpg_sampling.py" "$SAMP/y13c12.jpg" 100 200 13,12,12 1 > /dev/null
python3 "$PAS/tests/mkjpg_sampling.py" "$SAMP/y22c11.jpg" 150 200 22,11,11 2 > /dev/null
PJA_BANDS_REVERSE=1 PJA_TEST_V7=1 "$OUT/test_codec" "$SAMP" 2 | tail -2
for d in "${dirs[@]}"; do "$OUT/test_codec" "$d" 1 | tail -2; done
for d in "${dirs[@]}"; do PJA_TEST_V7=1 "$OUT/test_codec" "$d" 1 | tail -2; done

echo "== the fast build (PJA_FAST, with and without asm) writes the same streams as the reference"
FAST=$OUT/fast; PLAIN=$OUT/plain; mkdir -p "$FAST" "$PLAIN"
$FPC -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$FAST" -FE"$FAST" "$PAS/tests/dump_streams.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
$FPC -O2 -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/c" -FU"$OUT" -FE"$OUT" "$PAS/tests/dump_streams.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
# version 7 with the C part built without SSE2 (and so without its SSE4.1 copy)
$FPC -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -Fo"$OUT/cplain" -FU"$PLAIN" -FE"$PLAIN" "$PAS/tests/dump_streams.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
SRC_DIRS=("$PJA/tests/jpg" "$PJA/tests/jls" "${dirs[@]}" "fast:$PJA/tests/jpg" "v7:$PJA/tests/jpg")
for d in "${dirs[@]}"; do SRC_DIRS+=("v7:$d"); done
for d in "${SRC_DIRS[@]}"; do
  # fast:DIR = the same, with the fast model; v7:DIR, with stream version 7's
  unset PJA_TEST_FAST PJA_TEST_V7; tag=
  if [ "${d#fast:}" != "$d" ]; then d=${d#fast:}; export PJA_TEST_FAST=1; tag=" (fast model)"; fi
  if [ "${d#v7:}" != "$d" ]; then d=${d#v7:}; export PJA_TEST_V7=1; tag=" (version 7)"; fi
  [ -d "$d" ] || continue
  R=$OUT/streams_ref; F1=$OUT/streams_fast; F2=$OUT/streams_fast_noasm; F3=$OUT/streams_fast_t4
  rm -rf "$R" "$F1" "$F2" "$F3"; mkdir -p "$R" "$F1" "$F2" "$F3"
  PJA_NOASM=1 "$OUT/dump_streams" "$d" "$R"
  "$FAST/dump_streams" "$d" "$F1"
  PJA_NOASM=1 "$FAST/dump_streams" "$d" "$F2"
  "$FAST/dump_streams" "$d" "$F3" 4
  n=$(ls "$R" | wc -l)
  [ "$n" -ge 1 ] || { echo "FAIL: no streams from $d"; exit 1; }
  diff -rq "$R" "$F1" > /dev/null && diff -rq "$R" "$F2" > /dev/null && diff -rq "$R" "$F3" > /dev/null \
    || { echo "FAIL: the builds differ on $d"; diff -rq "$R" "$F1" | head -3; exit 1; }
  if [ -n "${PJA_TEST_V7:-}" ]; then
    F4=$OUT/streams_plain; rm -rf "$F4"; mkdir -p "$F4"
    "$PLAIN/dump_streams" "$d" "$F4"
    diff -rq "$R" "$F4" > /dev/null || { echo "FAIL: C without SSE2 differs on $d"; diff -rq "$R" "$F4" | head -3; exit 1; }
    # the SSE4.1 copy of the C loop, where the AVX2 one would run
    F5=$OUT/streams_noavx2; rm -rf "$F5"; mkdir -p "$F5"
    PJA_NOAVX2=1 "$FAST/dump_streams" "$d" "$F5"
    diff -rq "$R" "$F5" > /dev/null || { echo "FAIL: the SSE4.1 copy differs on $d"; diff -rq "$R" "$F5" | head -3; exit 1; }
    tag="$tag, = C without SSE2 = SSE4.1 copy"
  fi
  echo "$n streams from $(basename "$d")$tag: reference = fast = fast without asm = fast with 4 threads"
done
