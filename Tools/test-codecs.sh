#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
ARCH=${RING_TEST_ARCH:-$(uname -m)}
case "$ARCH" in arm64|x86_64) ;; *) exit 2;; esac
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge "$ARCH" ".work/CodecBridge-test-$ARCH.o"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos26.0" -module-cache-path .work/module-cache -parse-as-library \
 -import-objc-header Sources/Engine/CodecBridge.h -Xlinker -dead_strip Sources/Engine/*.swift Tests/CodecTests.swift \
 ".work/CodecBridge-test-$ARCH.o" "${ENGINE_LIBS[@]}" -o ".work/codec-tests-$ARCH"
/usr/bin/time -l /usr/bin/arch -"$ARCH" ".work/codec-tests-$ARCH" "$@"
