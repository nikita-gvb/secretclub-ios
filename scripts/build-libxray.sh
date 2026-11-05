#!/bin/bash
# Собирает Vendor/LibXray.xcframework (iOS + симулятор) из исходников libXray
# с нашим memory_ios.go (scripts/libxray). Нужны Xcode и Go; запускается в CI на macOS.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST_ARG=${1:-$ROOT/Vendor}
mkdir -p "$DEST_ARG"
DEST=$(cd "$DEST_ARG" && pwd)
SHA=$(tr -d '[:space:]' < "$ROOT/scripts/libxray/COMMIT")
WORK=${RUNNER_TEMP:-/tmp}/libxray-src
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
git init -q . && git remote add origin https://github.com/XTLS/libXray.git
git fetch -q --depth 1 origin "$SHA" && git checkout -q FETCH_HEAD
cp "$ROOT/scripts/libxray/memory_ios.go" memory/memory_ios.go
grep -q "checkInterval" memory/memory_ios.go
go version
OUT="$WORK/out"
mkdir -p "$OUT"

build() {
  local sdk=$1 goarch=$2 arch=$3
  local dir="$OUT/$sdk-$arch"
  mkdir -p "$dir"
  local sysroot
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  local flags="-isysroot $sysroot -m$sdk-version-min=15.0 -arch $arch"
  echo "▸ $sdk $arch"
  env GOOS=ios GOARCH="$goarch" GOFLAGS="-tags=ios" CGO_ENABLED=1 DARWIN_SDK="$sdk" \
    CC="xcrun --sdk $sdk --toolchain $sdk clang" CXX="xcrun --sdk $sdk --toolchain $sdk clang++" \
    CGO_CFLAGS="$flags" CGO_CXXFLAGS="$flags" CGO_LDFLAGS="$flags -Wl,-Bsymbolic-functions" \
    go build -trimpath -ldflags "-s -w -buildid=" -o "$dir/libXray.a" -buildmode=c-archive ./cgo_bridge
}

build iphoneos arm64 arm64
build iphonesimulator amd64 x86_64
build iphonesimulator arm64 arm64
mkdir -p "$OUT/iphonesimulator-arm64-x86_64" "$OUT/include"
lipo -create -arch x86_64 "$OUT/iphonesimulator-x86_64/libXray.a" -arch arm64 "$OUT/iphonesimulator-arm64/libXray.a" \
  -output "$OUT/iphonesimulator-arm64-x86_64/libXray.a"
cp "$OUT/iphoneos-arm64/libXray.h" "$OUT/include/"
cp build/template/module.modulemap "$OUT/include/"
rm -rf "$DEST/LibXray.xcframework" && mkdir -p "$DEST"
xcodebuild -create-xcframework \
  -library "$OUT/iphoneos-arm64/libXray.a" -headers "$OUT/include" \
  -library "$OUT/iphonesimulator-arm64-x86_64/libXray.a" -headers "$OUT/include" \
  -output "$DEST/LibXray.xcframework"
echo "SecretClub libXray $SHA (memory: 20s/GOGC30)" > "$DEST/LibXray.xcframework/SECRETCLUB"
ls -la "$DEST/LibXray.xcframework"
