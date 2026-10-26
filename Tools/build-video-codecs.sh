#!/bin/zsh
# Deterministic, static, library-only video backend. No FFmpeg command is installed.
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
export PATH="$ROOT/.work/tools/bin:$PATH"
CMAKE="$ROOT/Vendor/build/source/cmake/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/cmake"
JOBS=${RING_VIDEO_BUILD_JOBS:-4}
ARCHES=(${=RING_VIDEO_ARCHES:-arm64 x86_64})
python3 - <<'PY'
import hashlib,json,pathlib,tarfile,urllib.request
root=pathlib.Path.cwd()
for name,d in json.loads((root/'Vendor/video-dependencies.lock.json').read_text()).items():
 archive=root/'Vendor/downloads/video'/f'{name}.tar'; archive.parent.mkdir(parents=True,exist_ok=True)
 if not archive.exists(): urllib.request.urlretrieve(d['url'],archive)
 if hashlib.sha256(archive.read_bytes()).hexdigest()!=d['sha256']: raise SystemExit(f'{name}: SHA256 mismatch')
 target=root/'Vendor/build/source/video'/name
 if not target.exists():
  target.mkdir(parents=True)
  with tarfile.open(archive) as t:
   members=t.getmembers(); prefix=members[0].name.split('/')[0]+'/'
   for m in members:
    if m.name.startswith(prefix):m.name=m.name[len(prefix):]
    else:continue
    if m.name:t.extract(m,target,filter='data')
PY
# Preserve source presentation timestamps instead of rounding WebM to milliseconds.
if ! rg -q 'MATROSKA_ID_TIMECODESCALE, 1\);' Vendor/build/source/video/ffmpeg/libavformat/matroskaenc.c; then
 patch -d Vendor/build/source/video/ffmpeg -p1 < Tools/patches/ffmpeg-9-webm-nanosecond-timestamps.patch
fi
for ARCH in $ARCHES; do
 PREFIX="$ROOT/Vendor/build/$ARCH/install"
 BASE="$ROOT/Vendor/build/$ARCH/video"
 SRC="$ROOT/Vendor/build/source/video"
 mkdir -p "$PREFIX" "$BASE/x264" "$BASE/ffmpeg"
 COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
 -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON
 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=$ARCH
 -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local' -DBUILD_SHARED_LIBS=OFF)
 if [[ ! -f "$PREFIX/lib/libx264.a" ]]; then
  HOST=$ARCH; [[ $ARCH == arm64 ]] && HOST=aarch64
  (cd "$BASE/x264"; CC="clang -arch $ARCH -mmacosx-version-min=15.0" "$SRC/x264/configure" --host=$HOST-apple-darwin --prefix="$PREFIX" --enable-static --enable-pic --disable-cli --disable-opencl --bit-depth=8 --chroma-format=420; make -j$JOBS; make install-lib-static install-lib-dev)
 fi
 if [[ ! -f "$PREFIX/lib/libx265.a" ]]; then
  "$CMAKE" -S "$SRC/x265/source" -B "$BASE/x265" "${COMMON[@]}" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF -DENABLE_LIBNUMA=OFF -DHIGH_BIT_DEPTH=OFF
  "$CMAKE" --build "$BASE/x265" -j$JOBS; "$CMAKE" --install "$BASE/x265"
 fi
 if [[ ! -f "$PREFIX/lib/libSvtAv1Enc.a" ]]; then
  "$CMAKE" -S "$SRC/svt-av1" -B "$BASE/svt-av1" "${COMMON[@]}" -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DENABLE_NASM=OFF
  "$CMAKE" --build "$BASE/svt-av1" -j$JOBS; "$CMAKE" --install "$BASE/svt-av1"
 fi
 if [[ ! -f "$PREFIX/lib/libopus.a" ]]; then
  "$CMAKE" -S "$SRC/opus" -B "$BASE/opus" "${COMMON[@]}" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=ON
  "$CMAKE" --build "$BASE/opus" -j$JOBS; "$CMAKE" --install "$BASE/opus"
 fi
 # libaom is shared with the image backend and must be built with decoder enabled.
 [[ -f "$PREFIX/lib/libaom.a" ]] || { print -u2 'Build image codecs with AOM decoder enabled first.'; exit 1; }
 if [[ ! -f "$PREFIX/lib/libavcodec.a" ]]; then
  CPU=$ARCH; [[ $ARCH == arm64 ]] && CPU=aarch64
  (cd "$BASE/ffmpeg"; PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
   "$SRC/ffmpeg/configure" --prefix="$PREFIX" --cc=clang --cxx=clang++ --arch=$CPU --target-os=darwin --enable-cross-compile \
   --extra-cflags="-arch $ARCH -mmacosx-version-min=15.0 -I$PREFIX/include" --extra-ldflags="-arch $ARCH -mmacosx-version-min=15.0 -L$PREFIX/lib" \
   --pkg-config-flags=--static --enable-static --disable-shared --enable-pic --enable-gpl --disable-autodetect \
   --disable-programs --disable-doc --disable-debug --disable-everything --enable-pthreads --enable-zlib \
   --enable-avcodec --enable-avformat --enable-swscale --enable-swresample \
   --enable-libx264 --enable-libx265 --enable-libsvtav1 --enable-libaom --enable-libopus \
   --enable-encoder=libx264,libx265,libsvtav1,libopus \
   --enable-decoder=h264,hevc,vp8,vp9,mpeg4,prores,libaom_av1,aac,mp3,opus,vorbis,flac,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le \
   --enable-parser=h264,hevc,av1,vp8,vp9,aac,mpegaudio,opus,vorbis,flac,mpeg4video \
   --enable-demuxer=mov,matroska,avi,mpegts,flv,ogg --enable-muxer=mp4,mov,webm,matroska \
   --enable-bsf=aac_adtstoasc,av1_metadata,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb \
   --enable-protocol=file; make -j$JOBS; make install)
 fi
 done
mkdir -p Vendor/build/universal
for LIB in avformat avcodec swscale swresample avutil x264 x265 SvtAv1Enc opus; do
 if [[ -f Vendor/build/arm64/install/lib/lib$LIB.a && -f Vendor/build/x86_64/install/lib/lib$LIB.a ]]; then
  lipo -create Vendor/build/arm64/install/lib/lib$LIB.a Vendor/build/x86_64/install/lib/lib$LIB.a -output Vendor/build/universal/lib$LIB.a
 fi
 done
# Ship exact upstream license text and source provenance beside other codec licenses.
python3 - <<'PY'
import pathlib,shutil,json
root=pathlib.Path.cwd(); src=root/'Vendor/build/source/video'; out=root/'Resources/Licenses/SoftwareVideo'; out.mkdir(parents=True,exist_ok=True)
files={'ffmpeg':['COPYING.GPLv2','COPYING.LGPLv2.1','LICENSE.md'],'x264':['COPYING'],'x265':['COPYING'],'svt-av1':['LICENSE.md','PATENTS.md'],'opus':['COPYING']}
for name,names in files.items():
 d=out/name; d.mkdir(exist_ok=True)
 for n in names:
  p=src/name/n
  if p.exists():shutil.copy2(p,d/n)
shutil.copy2(root/'Vendor/video-dependencies.lock.json',out/'dependencies.lock.json')
PY
