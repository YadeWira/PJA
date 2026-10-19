#!/bin/bash
# Everything: the codec suite, then the .pja suite.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
bash "$HERE/pas/run_codec_tests.sh"
bash "$HERE/pas/run_tests.sh"
echo "all green"
