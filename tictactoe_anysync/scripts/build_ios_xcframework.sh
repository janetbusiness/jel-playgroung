#!/usr/bin/env bash
set -euo pipefail

# Build an iOS xcframework from the Go bridge (static c-archive)
# Outputs to: lib/native/ios/AnySyncBridge.xcframework

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
GO_DIR="$ROOT_DIR/go"
OUT_BASE="$ROOT_DIR/lib/native/ios"

IOS_MIN_SDK=${IOS_MIN_SDK:-13.0}

if ! command -v go >/dev/null 2>&1; then
  echo "Go is required. Install Go 1.23+" >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode command line tools are required (xcrun, xcodebuild)." >&2
  exit 1
fi

mkdir -p "$OUT_BASE/iphoneos" "$OUT_BASE/simulator"

echo "Building c-archive (iphoneos, arm64)"
(
  cd "$GO_DIR"
  SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
  env \
    CGO_ENABLED=1 \
    GOOS=ios \
    GOARCH=arm64 \
    CC="$(xcrun --sdk iphoneos -f clang)" \
    CGO_CFLAGS="-isysroot $SDK_PATH -miphoneos-version-min=$IOS_MIN_SDK" \
    CGO_LDFLAGS="-isysroot $SDK_PATH -miphoneos-version-min=$IOS_MIN_SDK" \
    go build -buildmode=c-archive -o "$OUT_BASE/iphoneos/anysync_bridge.a" anysync_bridge.go
)

echo "Building c-archive (simulator, arm64)"
(
  cd "$GO_DIR"
  SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
  env \
    CGO_ENABLED=1 \
    GOOS=ios \
    GOARCH=arm64 \
    CC="$(xcrun --sdk iphonesimulator -f clang)" \
    CGO_CFLAGS="-isysroot $SDK_PATH -mios-simulator-version-min=$IOS_MIN_SDK" \
    CGO_LDFLAGS="-isysroot $SDK_PATH -mios-simulator-version-min=$IOS_MIN_SDK" \
    go build -buildmode=c-archive -o "$OUT_BASE/simulator/anysync_bridge.a" anysync_bridge.go
)

echo "Creating xcframework"
xcodebuild -create-xcframework \
  -library "$OUT_BASE/iphoneos/anysync_bridge.a" -headers "$OUT_BASE/iphoneos/anysync_bridge.h" \
  -library "$OUT_BASE/simulator/anysync_bridge.a" -headers "$OUT_BASE/simulator/anysync_bridge.h" \
  -output "$OUT_BASE/AnySyncBridge.xcframework"

echo "Done. XCFramework at: $OUT_BASE/AnySyncBridge.xcframework"
echo "Integrate it into Runner (Xcode) and Dart will use DynamicLibrary.process()."

