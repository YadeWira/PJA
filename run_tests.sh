#!/bin/bash
# Everything: the compiler to ZPAQL, the codec suite, then the .pja suite.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
echo "== zpaqlc: the compiler to ZPAQL"
(cd "$HERE/tools/zpaql" && python3 test_zpaqlc.py | tail -1)
bash "$HERE/pas/run_codec_tests.sh"
bash "$HERE/pas/run_tests.sh"
echo "all green"
