#!/bin/zsh
# Build SIMD-enabled static codecs separately for each architecture, then merge.
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
python3 Tools/fetch-codecs.py
mkdir -p .work/tools/bin .work/tmp
export TMPDIR="$ROOT/.work/tmp"
CMAKE="$ROOT/Vendor/build/source/cmake/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/cmake"
NASM_SRC="$ROOT/Vendor/build/source/nasm/nasm-2.16.03"
if [[ ! -x "$ROOT/.work/tools/bin/nasm" ]]; then
  (cd "$NASM_SRC"; ./configure --prefix="$ROOT/.work/tools"; make -j4; make install)
fi
export PATH="$ROOT/.work/tools/bin:$PATH"
for ARCH in arm64 x86_64; do
  PREFIX="$ROOT/Vendor/build/$ARCH/install"
  COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
          -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON
          -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' -DBUILD_SHARED_LIBS=OFF)
  configure_build() {
    local NAME=$1 SRC=$2
    shift 2
    "$CMAKE" -S "$SRC" -B "$ROOT/Vendor/build/$ARCH/$NAME" "${COMMON[@]}" "$@"
    "$CMAKE" --build "$ROOT/Vendor/build/$ARCH/$NAME" -j4
    "$CMAKE" --install "$ROOT/Vendor/build/$ARCH/$NAME"
  }
  configure_build webp "$ROOT/Vendor/build/source/webp/libwebp-1.6.0" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
    -DWEBP_BUILD_LIBWEBPMUX=ON -DWEBP_BUILD_LIBWEBPDEMUX=ON -DWEBP_BUILD_EXTRAS=OFF -DWEBP_ENABLE_SIMD=ON
  configure_build aom "$ROOT/Vendor/build/source/aom" \
    -DAOM_TARGET_CPU=$ARCH -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF -DENABLE_TOOLS=OFF -DENABLE_EXAMPLES=OFF \
    -DCONFIG_AV1_DECODER=0 -DCONFIG_AV1_ENCODER=1 -DCONFIG_AV1_HIGHBITDEPTH=1 -DCONFIG_RUNTIME_CPU_DETECT=1
  configure_build avif "$ROOT/Vendor/build/source/avif/libavif-1.4.2" \
    -DCMAKE_PREFIX_PATH=$PREFIX -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_DECODE=OFF -DAVIF_CODEC_AOM_ENCODE=ON \
    -DAVIF_CODEC_DAV1D=OFF -DAVIF_CODEC_LIBGAV1=OFF -DAVIF_CODEC_RAV1E=OFF -DAVIF_CODEC_SVT=OFF \
    -DAVIF_LIBYUV=OFF -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF
  configure_build jpeg "$ROOT/Vendor/build/source/jpeg/libjpeg-turbo-3.2.0" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=ON -DWITH_SIMD=ON
 done
mkdir -p Vendor/build/universal
for LIB in webp webpmux webpdemux sharpyuv aom avif turbojpeg jpeg; do
  lipo -create "Vendor/build/arm64/install/lib/lib$LIB.a" "Vendor/build/x86_64/install/lib/lib$LIB.a" -output "Vendor/build/universal/lib$LIB.a"
done
