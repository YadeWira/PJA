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
for prog in test_jpeg test_jpeg_corrupt test_tolerances test_jls test_arith test_codec test_codec_corrupt; do
  $FPC -O2 -g -gl -Fu"$PAS" -Fi"$PAS" -FU"$OUT" -FE"$OUT" "$PAS/tests/$prog.pas" > "$OUT/fpc.log" 2>&1 \
    || { cat "$OUT/fpc.log"; exit 1; }
done

echo "== layer 1: JPEG <-> coefficients"
"$OUT/test_jpeg" "$PJA/tests/jpg" 11 | tail -1
# every bit of the first 2 KB and every truncation: no exception
"$OUT/test_jpeg_corrupt" "$PJA/tests/jpg" 2048 | tail -1
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
for d in "${dirs[@]}"; do "$OUT/test_codec" "$d" 1 | tail -2; done

echo "== the fast build (PJA_FAST, with and without asm) writes the same streams as the reference"
FAST=$OUT/fast; mkdir -p "$FAST"
$FPC -O3 -dPJA_FAST -Fu"$PAS" -Fi"$PAS" -FU"$FAST" -FE"$FAST" "$PAS/tests/dump_streams.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
$FPC -O2 -Fu"$PAS" -Fi"$PAS" -FU"$OUT" -FE"$OUT" "$PAS/tests/dump_streams.pas" > "$OUT/fpc.log" 2>&1 \
  || { cat "$OUT/fpc.log"; exit 1; }
SRC_DIRS=("$PJA/tests/jpg" "$PJA/tests/jls" "${dirs[@]}" "fast:$PJA/tests/jpg")
for d in "${SRC_DIRS[@]}"; do
  # fast:DIR = the same, with the fast model
  if [ "${d#fast:}" != "$d" ]; then d=${d#fast:}; export PJA_TEST_FAST=1; tag=" (fast model)"; else unset PJA_TEST_FAST; tag=; fi
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
  echo "$n streams from $(basename "$d")$tag: reference = fast = fast without asm = fast with 4 threads"
done
