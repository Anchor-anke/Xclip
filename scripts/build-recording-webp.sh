#!/bin/bash
# Build a universal, statically linked animation helper; runtime never uses PATH tools.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEBP_ROOT="$PROJECT_ROOT/.build/recording-webp"
WEBP_VERSION=1.6.0
WEBP_SHA256=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
WEBP_ARCHIVE="$WEBP_ROOT/libwebp-$WEBP_VERSION.tar.gz"
WEBP_SOURCE="$WEBP_ROOT/libwebp-$WEBP_VERSION"
HELPER_SOURCE="$PROJECT_ROOT/src/RecordingWebPHelper/main.c"
mkdir -p "$WEBP_ROOT"
if [[ ! -f "$WEBP_ARCHIVE" ]]; then
    curl --fail --location --retry 2 --max-time 120 \
        "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP_VERSION.tar.gz" \
        -o "$WEBP_ARCHIVE.download"
    mv "$WEBP_ARCHIVE.download" "$WEBP_ARCHIVE"
fi
ACTUAL_SHA256="$(shasum -a 256 "$WEBP_ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$WEBP_SHA256" ]] || { echo 'libwebp source checksum mismatch.' >&2; exit 1; }
if [[ ! -f "$WEBP_SOURCE/CMakeLists.txt" ]]; then tar -xzf "$WEBP_ARCHIVE" -C "$WEBP_ROOT"; fi
CMAKE_COMMAND="${CMAKE_COMMAND:-$(command -v cmake || true)}"
[[ -x "$CMAKE_COMMAND" ]] || { echo 'Building the WebP helper requires CMake and Xcode command line tools.' >&2; exit 1; }
for WEBP_ARCH in arm64 x86_64; do
    WEBP_BUILD="$WEBP_ROOT/$WEBP_ARCH"
    "$CMAKE_COMMAND" -S "$WEBP_SOURCE" -B "$WEBP_BUILD" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$WEBP_ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
        -DWEBP_BUILD_LIBWEBPMUX=ON > "$WEBP_ROOT/configure-$WEBP_ARCH.log" 2>&1
    "$CMAKE_COMMAND" --build "$WEBP_BUILD" --target libwebpmux webp --parallel 4 > "$WEBP_ROOT/build-$WEBP_ARCH.log" 2>&1
    xcrun clang -O2 -arch "$WEBP_ARCH" -mmacosx-version-min=14.0 -I "$WEBP_SOURCE/src" \
        "$HELPER_SOURCE" "$WEBP_BUILD/libwebpmux.a" "$WEBP_BUILD/libwebp.a" "$WEBP_BUILD/libsharpyuv.a" \
        -o "$WEBP_ROOT/XclipWebP-$WEBP_ARCH"
done
xcrun lipo -create "$WEBP_ROOT/XclipWebP-arm64" "$WEBP_ROOT/XclipWebP-x86_64" -output "$WEBP_ROOT/XclipWebP"
# Current lipo only accepts one architecture per -verify_arch invocation.
for arch in arm64 x86_64; do xcrun lipo "$WEBP_ROOT/XclipWebP" -verify_arch "$arch"; done
cp "$WEBP_SOURCE/COPYING" "$WEBP_ROOT/LICENSE-libwebp.txt"
cp "$WEBP_SOURCE/PATENTS" "$WEBP_ROOT/PATENTS-libwebp.txt"
"$WEBP_ROOT/XclipWebP" --version
printf 'WebP helper: %s\n' "$WEBP_ROOT/XclipWebP"
