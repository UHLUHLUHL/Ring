#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
mkdir -p .work/module-cache
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge arm64 .work/CodecBridge-v2-test.o
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos26.0 \
  -import-objc-header Sources/Engine/CodecBridge.h -module-cache-path .work/module-cache \
  -Xlinker -dead_strip Sources/Engine/*.swift Tests/EngineV2Tests.swift \
  .work/CodecBridge-v2-test.o "${ENGINE_LIBS[@]}" -o .work/engine-v2-tests
.work/engine-v2-tests "$@"
