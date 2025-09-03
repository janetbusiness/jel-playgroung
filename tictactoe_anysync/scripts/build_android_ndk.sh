#!/usr/bin/env bash
set -euo pipefail

# Build Android NDK shared libraries for multiple ABIs
# Outputs to: android/src/main/jniLibs/<abi>/libanysync_bridge.so

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
GO_DIR="$ROOT_DIR/go"
# Output to the app module so Gradle packages the .so files
OUT_DIR="$ROOT_DIR/android/app/src/main/jniLibs"

ABIS=(arm64-v8a armeabi-v7a x86_64)
ANDROID_API=${ANDROID_API:-21}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--ndk <path>] [--abis "arm64-v8a armeabi-v7a x86_64"] [--api <level>]

Environment:
  ANDROID_NDK_HOME / ANDROID_NDK_ROOT: Preferred NDK location
  ANDROID_SDK_ROOT / ANDROID_HOME: Fallback to SDK ndk/*
  ANDROID_API: API level (default: 21)
EOF
}

NDK_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ndk)
      NDK_ROOT="$2"; shift 2;;
    --abis)
      IFS=' ' read -r -a ABIS <<< "$2"; shift 2;;
    --api)
      ANDROID_API="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if ! command -v go >/dev/null 2>&1; then
  echo "Go is required. Install Go 1.23+" >&2
  exit 1
fi

if [[ -z "$NDK_ROOT" ]]; then
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then NDK_ROOT="$ANDROID_NDK_HOME"; fi
fi
if [[ -z "$NDK_ROOT" ]]; then
  if [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then NDK_ROOT="$ANDROID_NDK_ROOT"; fi
fi
if [[ -z "$NDK_ROOT" ]]; then
  SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -n "$SDK" && -d "$SDK/ndk" ]]; then
    # pick the highest version
    NDK_ROOT="$(ls -1d "$SDK/ndk"/* 2>/dev/null | sort -V | tail -n1 || true)"
  elif [[ -n "$SDK" && -d "$SDK/ndk-bundle" ]]; then
    NDK_ROOT="$SDK/ndk-bundle"
  fi
fi

if [[ -z "$NDK_ROOT" || ! -d "$NDK_ROOT" ]]; then
  echo "Could not locate Android NDK. Set --ndk or ANDROID_NDK_HOME/ANDROID_SDK_ROOT." >&2
  exit 1
fi

HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64) HOST_ARCH="x86_64";;
  arm64|aarch64) HOST_ARCH="aarch64";;
esac

TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/${HOST_OS}-${HOST_ARCH}"
CLANG_BIN="$TOOLCHAIN/bin"

mkdir -p "$OUT_DIR"

build_abi() {
  local abi="$1" goarch cc target outdir
  case "$abi" in
    arm64-v8a)
      goarch=arm64
      cc="$CLANG_BIN/aarch64-linux-android${ANDROID_API}-clang"
      target="aarch64-linux-android";;
    armeabi-v7a)
      goarch=arm
      cc="$CLANG_BIN/armv7a-linux-androideabi${ANDROID_API}-clang"
      target="armv7a-linux-androideabi";;
    x86_64)
      goarch=amd64
      cc="$CLANG_BIN/x86_64-linux-android${ANDROID_API}-clang"
      target="x86_64-linux-android";;
    x86)
      goarch=386
      cc="$CLANG_BIN/i686-linux-android${ANDROID_API}-clang"
      target="i686-linux-android";;
    *)
      echo "Unsupported ABI: $abi" >&2; return 1;;
  esac

  outdir="$OUT_DIR/$abi"
  mkdir -p "$outdir"
  echo "Building for $abi (GOARCH=$goarch, CC=$(basename "$cc"))"
  (
    cd "$GO_DIR"
    env \
      GOOS=android \
      GOARCH="$goarch" \
      CGO_ENABLED=1 \
      CC="$cc" \
      CGO_CFLAGS="--target=$target" \
      CGO_LDFLAGS="--target=$target" \
      go build -buildmode=c-shared -o "$outdir/libanysync_bridge.so" anysync_bridge.go
  )
}

for abi in "${ABIS[@]}"; do
  build_abi "$abi"
done

echo "Done. Copied libraries to $OUT_DIR/<abi>/libanysync_bridge.so"
