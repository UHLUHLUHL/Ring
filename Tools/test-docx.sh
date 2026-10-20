#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge arm64 .work/CodecBridge-test.o
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -module-cache-path .work/module-cache -parse-as-library \
 -import-objc-header Sources/Engine/CodecBridge.h -Xlinker -dead_strip Sources/Engine/*.swift Tests/DOCXTests.swift \
 .work/CodecBridge-test.o "${ENGINE_LIBS[@]}" -o .work/docx-tests
/usr/bin/time -l .work/docx-tests "$@"
