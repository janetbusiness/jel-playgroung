#!/usr/bin/env bash
set -euo pipefail
echo "Building any-sync FFI bridge..."

pushd "$(dirname "$0")" >/dev/null

case "$(uname -s)" in
  Linux*)
    CGO_ENABLED=1 go build -buildmode=c-shared -o ../lib/native/anysync_bridge_linux.so anysync_bridge.go
    ;;
  Darwin*)
    mkdir -p ../lib/native
    # Build macOS dynamic library with .dylib extension and also provide a .so copy for compatibility
    CGO_ENABLED=1 go build -buildmode=c-shared -o ../lib/native/anysync_bridge_macos.dylib anysync_bridge.go
    cp -f ../lib/native/anysync_bridge_macos.dylib ../lib/native/anysync_bridge_macos.so
    ;;
  *)
    echo "Platform not supported" >&2
    exit 1
    ;;
esac

popd >/dev/null
echo "Build complete!"
