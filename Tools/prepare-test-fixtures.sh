#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
Tools/test-engine.sh .work/stage1-check --prepare
python3 Tools/prepare-test-fixtures.py
.work/engine-tests .work/stage1-check --prepare-scan
