# Sourced by build/test scripts. ROOT is an absolute checkout path.
ENGINE_LIBS=()
for LIB in qpdf webpmux webp sharpyuv avif aom turbojpeg jpeg; do
  ENGINE_LIBS+=("$ROOT/Vendor/build/universal/lib$LIB.a")
done
ENGINE_LIBS+=(-lc++ -lz)
compile_engine_bridge() {
  local ARCH=$1 OBJECT=$2
  xcrun clang -std=c11 -O3 -arch "$ARCH" -mmacosx-version-min=26.0 \
    -I"$ROOT/Sources/Engine" -I"$ROOT/Vendor/build/$ARCH/install/include" \
    -c "$ROOT/Sources/Engine/CodecBridge.c" -o "$OBJECT.base.o"
  xcrun clang -std=c11 -O3 -arch "$ARCH" -mmacosx-version-min=26.0 \
    -I"$ROOT/Sources/Engine" -I"$ROOT/Vendor/build/$ARCH/install/include" \
    -c "$ROOT/Sources/Engine/CodecV2.c" -o "$OBJECT.v2.o"
  xcrun clang++ -std=c++17 -O2 -arch "$ARCH" -mmacosx-version-min=26.0 \
    -I"$ROOT/Sources/Engine" -I"$ROOT/Vendor/build/$ARCH/install/include" \
    -I"$ROOT/Vendor/build/source/qpdf/qpdf-12.4.2/include" \
    -c "$ROOT/Sources/Engine/PDFBridge.cpp" -o "$OBJECT.pdf.o"
  xcrun ld -r -arch "$ARCH" "$OBJECT.base.o" "$OBJECT.v2.o" "$OBJECT.pdf.o" -o "$OBJECT"
}
