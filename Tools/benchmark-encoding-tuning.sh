#!/bin/zsh
set -euo pipefail
PROJECT=${0:A:h:h}
cd "$PROJECT"
LABEL=${1:?Pass a benchmark label}
ROOT=${RING_BENCH_ENGINE_ROOT:-$PROJECT}
OUTPUT="$PROJECT/.work/encoding-repair-20261021"
mkdir -p "$OUTPUT" "$PROJECT/.work/module-cache"
source "$PROJECT/Tools/engine-build-env.sh"
compile_engine_bridge arm64 "$OUTPUT/bridge-$LABEL.o"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos15.0 \
  -import-objc-header "$ROOT/Sources/Engine/CodecBridge.h" -module-cache-path "$PROJECT/.work/module-cache" \
  -Xlinker -dead_strip "$ROOT"/Sources/Engine/*.swift Tests/EncodingTuningBench.swift \
  "$OUTPUT/bridge-$LABEL.o" "${ENGINE_LIBS[@]}" -o "$OUTPUT/bench-$LABEL"
"$OUTPUT/bench-$LABEL" "$LABEL" "$OUTPUT/results" > "$OUTPUT/$LABEL.jsonl"
sed '/^$/d' "$OUTPUT/$LABEL.jsonl"
