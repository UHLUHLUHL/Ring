#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
mkdir -p .work/module-cache .work/quality-video
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge arm64 .work/quality-video/CodecBridge.o
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos15.0 \
  -import-objc-header Sources/Engine/CodecBridge.h -module-cache-path .work/module-cache \
  -Xlinker -dead_strip Sources/Engine/*.swift Tests/MediaFixture.swift Tests/VideoQualityTests.swift \
  .work/quality-video/CodecBridge.o "${ENGINE_LIBS[@]}" -o .work/quality-video/tests
.work/quality-video/tests "$@"
