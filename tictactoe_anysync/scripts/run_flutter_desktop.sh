#!/usr/bin/env bash
set -euo pipefail

# Cross-platform launcher for Flutter desktop (macOS/Linux)
# - Ensures the Go FFI library is built
# - Exports ANYSYNC_LIB_PATH so Flutter finds the native lib
# - Runs `flutter run` on the appropriate desktop device

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."

OS_NAME="$(uname -s)"
case "$OS_NAME" in
  Darwin)
    TARGET_DEVICE="macos"
    LIB_CANDIDATES=(
      "$ROOT_DIR/lib/native/anysync_bridge_macos.dylib"
      "$ROOT_DIR/lib/native/anysync_bridge_macos.so"
    )
    ;;
  Linux*)
    TARGET_DEVICE="linux"
    LIB_CANDIDATES=(
      "$ROOT_DIR/lib/native/anysync_bridge_linux.so"
    )
    ;;
  *)
    echo "Unsupported platform: $OS_NAME (only macOS and Linux are supported)" >&2
    exit 1
    ;;
esac

# Build if no candidate library exists
LIB_FOUND=""
for c in "${LIB_CANDIDATES[@]}"; do
  if [ -f "$c" ]; then LIB_FOUND="$c"; break; fi
done

if [ -z "$LIB_FOUND" ]; then
  echo "Native lib not found. Building..."
  (cd "$ROOT_DIR/go" && ./build.sh)
  for c in "${LIB_CANDIDATES[@]}"; do
    if [ -f "$c" ]; then LIB_FOUND="$c"; break; fi
  done
fi

if [ -z "$LIB_FOUND" ]; then
  echo "ERROR: Failed to locate built native library after build." >&2
  exit 1
fi

export ANYSYNC_LIB_PATH="$LIB_FOUND"
echo "Using ANYSYNC_LIB_PATH=$ANYSYNC_LIB_PATH"

cd "$ROOT_DIR"
flutter pub get

# Allow overriding device via args (e.g., -d <id>)
if [[ "$*" == *"-d"* ]]; then
  flutter run "$@"
else
  flutter run -d "$TARGET_DEVICE" "$@"
fi

