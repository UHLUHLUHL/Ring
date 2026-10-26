#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
python3 Tools/fetch-codecs.py
CMAKE="$ROOT/Vendor/build/source/cmake/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/cmake"
SRC="$ROOT/Vendor/build/source/qpdf/qpdf-12.4.2"
for ARCH in arm64 x86_64; do
 PREFIX="$ROOT/Vendor/build/$ARCH/install"
 "$CMAKE" -S "$SRC" -B "$ROOT/Vendor/build/$ARCH/qpdf" -DCMAKE_BUILD_TYPE=MinSizeRel \
 -DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_INSTALL_PREFIX="$PREFIX" \
 -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' \
 -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_DOC=OFF -DINSTALL_EXAMPLES=OFF \
 -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON -DDEFAULT_CRYPTO=native \
 -DJPEG_LIBRARY="$PREFIX/lib/libjpeg.a" -DJPEG_INCLUDE_DIR="$PREFIX/include" -DZOPFLI=OFF
 "$CMAKE" --build "$ROOT/Vendor/build/$ARCH/qpdf" --target libqpdf -j4
 mkdir -p "$PREFIX/include/qpdf"
 cp "$SRC/include/qpdf/"*.h "$SRC/include/qpdf/"*.hh "$PREFIX/include/qpdf/"
 cp "$ROOT/Vendor/build/$ARCH/qpdf/libqpdf/libqpdf.a" "$PREFIX/lib/libqpdf.a"
done
lipo -create Vendor/build/arm64/install/lib/libqpdf.a Vendor/build/x86_64/install/lib/libqpdf.a -output Vendor/build/universal/libqpdf.a
mkdir -p Resources/Licenses/qpdf-12.4.2
cp "$SRC/LICENSE.txt" "$SRC/NOTICE.md" Resources/Licenses/qpdf-12.4.2/
