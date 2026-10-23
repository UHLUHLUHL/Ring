#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h:h:h}
CAPTURE="$ROOT/.work/usage-demo/Capture.app"
mkdir -p "$CAPTURE/Contents/MacOS"
source "$ROOT/Tools/engine-build-env.sh"
BRIDGE="$ROOT/build/CodecBridge-arm64.o"
if [[ ! -f "$BRIDGE" ]]; then
  BRIDGE="$ROOT/.work/usage-demo/CodecBridge-arm64.o"
  compile_engine_bridge arm64 "$BRIDGE"
fi
APP_SOURCES=($ROOT/Sources/App/*.swift)
APP_SOURCES=(${APP_SOURCES:#*/main.swift})
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/.work/module-cache" \
  -import-objc-header "$ROOT/Sources/Engine/CodecBridge.h" -Xlinker -dead_strip \
  -target arm64-apple-macos26.0 -module-name RingDemoCapture \
  -o "$CAPTURE/Contents/MacOS/Capture" \
  "$ROOT/docs/demo/source/CaptureStudio.swift" "${APP_SOURCES[@]}" "$ROOT"/Sources/Engine/*.swift \
  "$BRIDGE" "${ENGINE_LIBS[@]}"
cat > "$CAPTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Capture</string>
<key>CFBundleIdentifier</key><string>com.dlgksdnf.Ring.DemoCapture</string>
<key>CFBundleName</key><string>Ring Demo Capture</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$CAPTURE"
