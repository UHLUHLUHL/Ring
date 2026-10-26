#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
mkdir -p .work/module-cache .work/video-conversion
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge arm64 .work/CodecBridge-video-conversion.o
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos15.0 \
  -import-objc-header Sources/Engine/CodecBridge.h -module-cache-path .work/module-cache \
  -Xlinker -dead_strip Sources/Engine/*.swift Tests/MediaFixture.swift Tests/VideoConversionTests.swift \
  .work/CodecBridge-video-conversion.o "${ENGINE_LIBS[@]}" -o .work/video-conversion-tests
.work/video-conversion-tests "$@"
