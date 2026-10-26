#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
mkdir -p .work/module-cache
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge arm64 .work/CodecBridge-animated-images.o
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos15.0 \
  -import-objc-header Sources/Engine/CodecBridge.h -module-cache-path .work/module-cache \
  -Xlinker -dead_strip Sources/Engine/*.swift Sources/App/RingFeatures.swift Sources/App/FileInfo.swift Tests/AnimatedImageTests.swift \
  .work/CodecBridge-animated-images.o "${ENGINE_LIBS[@]}" -o .work/animated-image-tests
.work/animated-image-tests "$@"
