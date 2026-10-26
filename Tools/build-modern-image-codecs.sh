#!/bin/zsh
# Bundled static libjxl plus AVIF decoding; no Homebrew/runtime dependencies.
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
python3 Tools/fetch-codecs.py
python3 - <<'PY'
import pathlib,json,hashlib,urllib.request,tarfile
root=pathlib.Path('Vendor'); lock=json.loads((root/'modern-image-dependencies.lock.json').read_text())
src=root/'build/source/jxl/libjxl-0.12.0'
for name,entry in lock.items():
    archive=root/'downloads'/entry['archive'];archive.parent.mkdir(parents=True,exist_ok=True)
    if not archive.exists():urllib.request.urlretrieve(entry['url'],archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=entry['sha256']:raise SystemExit('Checksum failed: '+name)
    dest=src if name=='jxl' else src/'third_party'/name
    if (dest/'CMakeLists.txt').exists() or (name=='skcms' and (dest/'skcms.h').exists()):continue
    dest.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            member.name='/'.join(member.name.split('/')[1:])
            if member.name:package.extract(member,dest,filter='data')
PY
if ! rg -q 'if \(!dedupStream\)' Vendor/build/source/avif/libavif-1.4.2/src/write.c; then
  patch -d Vendor/build/source/avif/libavif-1.4.2 -p1 < Vendor/patches/libavif-1.4.2-animation-transform.patch
fi
CMAKE="$ROOT/Vendor/build/source/cmake/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/cmake"
if [[ ! -x "$ROOT/.work/tools/bin/nasm" ]]; then
  NASM_SRC="$ROOT/Vendor/build/source/nasm/nasm-2.16.03"
  (cd "$NASM_SRC"; ./configure --prefix="$ROOT/.work/tools"; make -j4; make install)
fi
export PATH="$ROOT/.work/tools/bin:$PATH"
ARCHS=(${=RING_CODEC_ARCHS:-arm64 x86_64})
for ARCH in "${ARCHS[@]}"; do
  PREFIX="$ROOT/Vendor/build/$ARCH/install"
  COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
    -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' -DBUILD_SHARED_LIBS=OFF)
  "$CMAKE" -S "$ROOT/Vendor/build/source/aom" -B "$ROOT/Vendor/build/$ARCH/aom" "${COMMON[@]}" \
    -DAOM_TARGET_CPU=$ARCH -DENABLE_TESTS=OFF -DENABLE_DOCS=OFF -DENABLE_TOOLS=OFF -DENABLE_EXAMPLES=OFF \
    -DCONFIG_AV1_DECODER=1 -DCONFIG_AV1_ENCODER=1 -DCONFIG_AV1_HIGHBITDEPTH=1 -DCONFIG_RUNTIME_CPU_DETECT=1
  "$CMAKE" --build "$ROOT/Vendor/build/$ARCH/aom" -j4
  "$CMAKE" --install "$ROOT/Vendor/build/$ARCH/aom"
  "$CMAKE" -S "$ROOT/Vendor/build/source/avif/libavif-1.4.2" -B "$ROOT/Vendor/build/$ARCH/avif" "${COMMON[@]}" \
    -DCMAKE_PREFIX_PATH=$PREFIX -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_DECODE=ON -DAVIF_CODEC_AOM_ENCODE=ON \
    -DAVIF_CODEC_DAV1D=OFF -DAVIF_CODEC_LIBGAV1=OFF -DAVIF_CODEC_RAV1E=OFF -DAVIF_CODEC_SVT=OFF \
    -DAVIF_LIBYUV=OFF -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF
  "$CMAKE" --build "$ROOT/Vendor/build/$ARCH/avif" -j4
  "$CMAKE" --install "$ROOT/Vendor/build/$ARCH/avif"
  "$CMAKE" -S "$ROOT/Vendor/build/source/jxl/libjxl-0.12.0" -B "$ROOT/Vendor/build/$ARCH/jxl" "${COMMON[@]}" \
    -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF -DJPEGXL_ENABLE_JPEG=OFF \
    -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_TCMALLOC=OFF \
    -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF
  "$CMAKE" --build "$ROOT/Vendor/build/$ARCH/jxl" -j4
  "$CMAKE" --install "$ROOT/Vendor/build/$ARCH/jxl"
done
mkdir -p Vendor/build/universal
for LIB in aom avif jxl jxl_cms jxl_threads brotlienc brotlidec brotlicommon hwy; do
  lipo -create "Vendor/build/arm64/install/lib/lib$LIB.a" "Vendor/build/x86_64/install/lib/lib$LIB.a" -output "Vendor/build/universal/lib$LIB.a"
done
mkdir -p Resources/Licenses/ModernImage
cp Vendor/build/source/jxl/libjxl-0.12.0/LICENSE Resources/Licenses/ModernImage/libjxl-LICENSE
cp Vendor/build/source/jxl/libjxl-0.12.0/PATENTS Resources/Licenses/ModernImage/libjxl-PATENTS
for DEP in brotli highway skcms; do
  cp "Vendor/build/source/jxl/libjxl-0.12.0/third_party/$DEP/LICENSE" "Resources/Licenses/ModernImage/$DEP-LICENSE"
done
