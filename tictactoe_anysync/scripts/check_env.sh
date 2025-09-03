#!/usr/bin/env bash
set -euo pipefail

echo "Checking environment..."

if command -v go >/dev/null 2>&1; then
  echo "Go: $(go version)"
else
  echo "Go is not installed (required >= 1.23)." >&2
fi

if command -v docker >/dev/null 2>&1; then
  echo "Docker: $(docker --version)"
else
  echo "Docker not found. Install Docker Desktop." >&2
fi

if command -v flutter >/dev/null 2>&1; then
  echo "Flutter: $(flutter --version | head -n 1)"
else
  echo "Flutter not found. Install Flutter SDK." >&2
fi

echo "Done."

