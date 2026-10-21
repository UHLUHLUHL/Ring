#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
OUTPUT=${1:-$ROOT/.work/engine-resources-$(date +%Y%m%d-%H%M%S)}
RUNS=${RING_BENCH_RUNS:-3}
[[ "$RUNS" == <-> && "$RUNS" -ge 1 && "$RUNS" -le 20 ]] || { echo 'RING_BENCH_RUNS must be 1...20' >&2; exit 1; }
ARCH=$(uname -m)
mkdir -p "$OUTPUT/fixtures" .work/module-cache
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge "$ARCH" "$OUTPUT/bridge.o"
xcrun swiftc -swift-version 5 -O -parse-as-library -target "$ARCH-apple-macos26.0" \
  -import-objc-header Sources/Engine/CodecBridge.h -module-cache-path .work/module-cache \
  -Xlinker -dead_strip Sources/Engine/*.swift Tests/MediaFixture.swift Tests/EngineResourceBench.swift \
  "$OUTPUT/bridge.o" "${ENGINE_LIBS[@]}" -o "$OUTPUT/resource-bench"
"$OUTPUT/resource-bench" fixture "$OUTPUT/fixtures" all
shasum -a 256 "$OUTPUT"/fixtures/*.{mp4,mov}(N) > "$OUTPUT/inputs.sha256"
shasum -a 256 Sources/Engine/*.swift Sources/Engine/*.[ch] Tests/EngineResourceBench.swift Tests/MediaFixture.swift > "$OUTPUT/sources.sha256"
sysctl -n hw.model hw.memsize > "$OUTPUT/hardware.txt"
pmset -g batt > "$OUTPUT/power.txt"
: > "$OUTPUT/results.jsonl"
for run in {1..$RUNS}; do
  for scenario in h264-webp h264-gif hevc-4k hevc-4k-dual prores long single dual; do
    "$OUTPUT/resource-bench" run "$OUTPUT/fixtures" "$scenario" | sed '/^[[:space:]]*$/d' | tee -a "$OUTPUT/results.jsonl"
  done
done
echo "Saved $OUTPUT/results.jsonl"
