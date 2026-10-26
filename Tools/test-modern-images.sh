#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
ROOT=$PWD
ARCH=${RING_TEST_ARCH:-$(uname -m)}
case "$ARCH" in arm64|x86_64) ;; *) exit 2;; esac
source "$ROOT/Tools/engine-build-env.sh"
# Small real high-bit files exercise decoder rejection before any RGBA8 conversion.
mkdir -p .work/modern-input-fixtures
xcrun clang++ -std=c++17 -O2 -arch "$ARCH" -mmacosx-version-min=15.0 \
  -I"$ROOT/Vendor/build/$ARCH/install/include" -x c++ - -x none \
  "$ROOT/Vendor/build/universal/libavif.a" "$ROOT/Vendor/build/universal/libaom.a" \
  "$ROOT/Vendor/build/universal/libjxl.a" "$ROOT/Vendor/build/universal/libjxl_cms.a" \
  "$ROOT/Vendor/build/universal/libjxl_threads.a" "$ROOT/Vendor/build/universal/libbrotlienc.a" \
  "$ROOT/Vendor/build/universal/libbrotlidec.a" "$ROOT/Vendor/build/universal/libbrotlicommon.a" \
  "$ROOT/Vendor/build/universal/libhwy.a" -o ".work/modern-input-fixture-tool-$ARCH" <<'CPP'
#include <avif/avif.h>
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
#include <cstdio>
#include <string>
#include <vector>
int main(int argc,char **argv) {
  if(argc!=2)return 1;
  uint16_t pixels[16]={0,0,0,65535,65535,65535,65535,65535,0,0,0,65535,65535,65535,65535,65535};
  avifImage *image=avifImageCreate(2,2,10,AVIF_PIXEL_FORMAT_YUV444);
  avifRGBImage rgb;avifRGBImageSetDefaults(&rgb,image);rgb.depth=16;rgb.format=AVIF_RGB_FORMAT_RGBA;rgb.pixels=(uint8_t*)pixels;rgb.rowBytes=16;
  if(avifImageRGBToYUV(image,&rgb)!=AVIF_RESULT_OK)return 2;
  avifEncoder *avif=avifEncoderCreate();avif->speed=10;avifRWData bytes=AVIF_DATA_EMPTY;
  if(avifEncoderWrite(avif,image,&bytes)!=AVIF_RESULT_OK)return 3;
  FILE *file=fopen((std::string(argv[1])+"/highbit.avif").c_str(),"wb");if(!file)return 4;fwrite(bytes.data,1,bytes.size,file);fclose(file);
  avifRWDataFree(&bytes);avifEncoderDestroy(avif);avifImageDestroy(image);
  JxlEncoder *jxl=JxlEncoderCreate(nullptr);JxlBasicInfo info;JxlEncoderInitBasicInfo(&info);info.xsize=2;info.ysize=2;info.bits_per_sample=10;info.uses_original_profile=JXL_TRUE;info.num_extra_channels=1;info.alpha_bits=10;
  if(JxlEncoderSetBasicInfo(jxl,&info)!=JXL_ENC_SUCCESS)return 5;
  JxlColorEncoding color;JxlColorEncodingSetToSRGB(&color,JXL_FALSE);if(JxlEncoderSetColorEncoding(jxl,&color)!=JXL_ENC_SUCCESS)return 6;
  JxlPixelFormat fmt={4,JXL_TYPE_UINT16,JXL_NATIVE_ENDIAN,0};auto settings=JxlEncoderFrameSettingsCreate(jxl,nullptr);
  if(JxlEncoderAddImageFrame(settings,&fmt,pixels,sizeof(pixels))!=JXL_ENC_SUCCESS)return 7;
  JxlEncoderCloseInput(jxl);std::vector<uint8_t> output(4096);uint8_t *next=output.data();size_t available=output.size();if(JxlEncoderProcessOutput(jxl,&next,&available)!=JXL_ENC_SUCCESS)return 8;
  file=fopen((std::string(argv[1])+"/highbit.jxl").c_str(),"wb");if(!file)return 9;fwrite(output.data(),1,output.size()-available,file);fclose(file);JxlEncoderDestroy(jxl);
}
CPP
/usr/bin/arch -"$ARCH" ".work/modern-input-fixture-tool-$ARCH" "$ROOT/.work/modern-input-fixtures"
compile_engine_bridge "$ARCH" ".work/CodecBridge-modern-$ARCH.o"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos15.0" -module-cache-path .work/module-cache -parse-as-library \
  -import-objc-header Sources/Engine/CodecBridge.h -Xlinker -dead_strip Sources/Engine/*.swift Tests/ModernImageTests.swift \
  ".work/CodecBridge-modern-$ARCH.o" "${ENGINE_LIBS[@]}" -o ".work/modern-image-tests-$ARCH"
/usr/bin/arch -"$ARCH" ".work/modern-image-tests-$ARCH" "$ROOT/.work/modern-input-fixtures"
