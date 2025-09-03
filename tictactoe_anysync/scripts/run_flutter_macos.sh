#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

# Ensure native lib exists; build if missing
LIB_SO="$ROOT_DIR/lib/native/anysync_bridge_macos.so"
LIB_DYLIB="$ROOT_DIR/lib/native/anysync_bridge_macos.dylib"
if [ ! -f "$LIB_SO" ] && [ ! -f "$LIB_DYLIB" ]; then
  echo "Native lib not found. Building..."
  (cd "$ROOT_DIR/go" && ./build.sh)
fi

if [ -f "$LIB_DYLIB" ]; then
  export ANYSYNC_LIB_PATH="$LIB_DYLIB"
else
  export ANYSYNC_LIB_PATH="$LIB_SO"
fi
echo "Using ANYSYNC_LIB_PATH=$ANYSYNC_LIB_PATH"

cd "$ROOT_DIR"
flutter pub get
flutter run -d macos

