#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
source "$ROOT/Tools/engine-build-env.sh"
mkdir -p .work/module-cache
compile_engine_bridge arm64 .work/CodecBridge-additional.o
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos15.0 -parse-as-library \
  -import-objc-header Sources/Engine/CodecBridge.h -module-cache-path .work/module-cache -Xlinker -dead_strip \
  Sources/Engine/*.swift Tests/MediaFixture.swift Tests/AdditionalCodecTests.swift \
  .work/CodecBridge-additional.o "${ENGINE_LIBS[@]}" -o .work/additional-codec-tests
.work/additional-codec-tests
