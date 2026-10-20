#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .work
ROOT=$PWD
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge arm64 .work/CodecBridge-test.o
xcrun swiftc -import-objc-header Sources/Engine/CodecBridge.h -Xlinker -dead_strip -swift-version 5 -O -target arm64-apple-macos26.0 -module-cache-path .work/module-cache -parse-as-library Sources/Engine/*.swift Tests/EngineTests.swift .work/CodecBridge-test.o "${ENGINE_LIBS[@]}" -o .work/engine-tests
/usr/bin/time -l .work/engine-tests "${1:-.work/tests}" "${@:2}"
