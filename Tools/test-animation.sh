#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
ARCH=${RING_TEST_ARCH:-$(uname -m)}
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1;; esac
mkdir -p .work/module-cache
source "$ROOT/Tools/engine-build-env.sh"
compile_engine_bridge "$ARCH" ".work/CodecBridge-animation-$ARCH.o"
xcrun swiftc -swift-version 5 -O -parse-as-library -target "$ARCH-apple-macos15.0" \
  -import-objc-header Sources/Engine/CodecBridge.h -module-cache-path .work/module-cache \
  -Xlinker -dead_strip Sources/Engine/*.swift Tests/MediaFixture.swift Tests/AnimationTests.swift \
  ".work/CodecBridge-animation-$ARCH.o" "${ENGINE_LIBS[@]}" -o ".work/animation-tests-$ARCH"
/usr/bin/arch -"$ARCH" ".work/animation-tests-$ARCH" "$@"
