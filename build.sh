#!/bin/zsh
# Builds build/Ring.app (app + Finder Sync extension) with the Command Line Tools only.
set -euo pipefail
ROOT=${0:A:h}
BUILD=$ROOT/build
APP=$BUILD/Ring.app
EXT=$APP/Contents/PlugIns/RingFinder.appex
mkdir -p "$ROOT/.work/module-cache"
SWIFTC=(xcrun swiftc -swift-version 5 -O -module-cache-path "$ROOT/.work/module-cache")

rm -rf $BUILD
mkdir -p $APP/Contents/{MacOS,Resources} $EXT/Contents/{MacOS,Resources}

if [[ ! -f "$ROOT/Vendor/build/universal/libavif.a" || ! -f "$ROOT/Vendor/build/universal/libwebpdemux.a" ]]; then
  "$ROOT/Tools/build-codecs.sh"
fi
if [[ ! -f "$ROOT/Vendor/build/universal/libqpdf.a" ]]; then
  "$ROOT/Tools/build-pdf.sh"
fi
source "$ROOT/Tools/engine-build-env.sh"
echo "• app"
for ARCH in arm64 x86_64; do
  compile_engine_bridge $ARCH "$BUILD/CodecBridge-$ARCH.o"
  $SWIFTC -import-objc-header "$ROOT/Sources/Engine/CodecBridge.h" -Xlinker -dead_strip -target $ARCH-apple-macos15.0 -module-name Ring -o $BUILD/Ring-$ARCH $ROOT/Sources/App/*.swift $ROOT/Sources/Engine/*.swift "$BUILD/CodecBridge-$ARCH.o" "${ENGINE_LIBS[@]}"
done
lipo -create $BUILD/Ring-arm64 $BUILD/Ring-x86_64 -output $APP/Contents/MacOS/Ring
cp $ROOT/Resources/App-Info.plist $APP/Contents/Info.plist

echo "• icon"
swift -module-cache-path "$ROOT/.work/module-cache" $ROOT/Tools/make-icon.swift $BUILD/AppIcon.iconset
iconutil -c icns $BUILD/AppIcon.iconset -o $APP/Contents/Resources/AppIcon.icns

echo "• finder extension"
for ARCH in arm64 x86_64; do
$SWIFTC -target $ARCH-apple-macos15.0 -module-name RingFinder -parse-as-library -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain -framework FinderSync \
  -o $BUILD/RingFinder-$ARCH $ROOT/Sources/FinderExtension/*.swift
done
lipo -create $BUILD/RingFinder-arm64 $BUILD/RingFinder-x86_64 -output $EXT/Contents/MacOS/RingFinder
cp $ROOT/Resources/Extension-Info.plist $EXT/Contents/Info.plist

cp -R "$ROOT/Resources/Licenses" "$APP/Contents/Resources/"

echo "• sign (ad-hoc)"
# Ad-hoc signatures default to a cdhash designated requirement, so every build looks like a new
# app to privacy permissions (Accessibility, Finder automation) and the granted switch stops
# applying. Pin the requirement to the bundle identifier so a grant survives rebuilds.
codesign --force --sign - -r='designated => identifier "com.dlgksdnf.Ring.FinderExtension"' --entitlements $ROOT/Resources/Extension.entitlements $EXT
codesign --force --sign - -r='designated => identifier "com.dlgksdnf.Ring"' $APP
codesign --verify --deep --strict $APP && echo "✓ $APP"
