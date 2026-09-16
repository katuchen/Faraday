#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/shim}"
WORK="${DERIVED_FILE_DIR:-$ROOT/build/shim}/shim-objects"
MIN_IOS=17.0

unset SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET TOOLCHAINS
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$OUT" "$WORK"

slices=()
for arch in arm64 x86_64; do
  target="$arch-apple-ios$MIN_IOS-simulator"
  xcrun --sdk iphonesimulator clang -c -fobjc-arc -fmodules -O2 -Wall \
    -target "$target" -isysroot "$SDK" -I "$ROOT/Shim" \
    -o "$WORK/FaradayShim-$arch.o" "$ROOT/Shim/FaradayShim.m"
  xcrun --sdk iphonesimulator swiftc -emit-library -parse-as-library -module-name FaradayShim \
    -swift-version 6 -O -target "$target" -sdk "$SDK" \
    -import-objc-header "$ROOT/Shim/FaradayShim.h" \
    -Xlinker -install_name -Xlinker @rpath/FaradayShim.dylib \
    -o "$WORK/FaradayShim-$arch.dylib" \
    "$ROOT/Shim/NetworkInterposes.swift" "$WORK/FaradayShim-$arch.o"
  slices+=("$WORK/FaradayShim-$arch.dylib")
done

xcrun lipo -create "${slices[@]}" -output "$OUT/FaradayShim.dylib"

for symbol in \
  '_$s7Network6NWPathV11FaradayShimE14faraday_statusAC6StatusOvg' \
  '_$s7Network13NWPathMonitorC11FaradayShimE25faraday_pathUpdateHandleryAA0B0VYbcSgvs'; do
  if ! xcrun nm -arch arm64 -gU "$OUT/FaradayShim.dylib" | grep -qF "$symbol"; then
    echo "error: $symbol is missing from FaradayShim.dylib" >&2
    exit 1
  fi
done

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] || [ -z "$identity" ]; then
  codesign --force --sign - "$OUT/FaradayShim.dylib"
else
  codesign --force --sign "$identity" --timestamp --options runtime "$OUT/FaradayShim.dylib"
fi
echo "Built $OUT/FaradayShim.dylib"
