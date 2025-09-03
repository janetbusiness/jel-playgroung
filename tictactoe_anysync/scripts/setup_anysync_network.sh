#!/usr/bin/env bash
set -euo pipefail

ensure_docker_running() {
  if docker info >/dev/null 2>&1; then
    echo "Docker daemon is running."
    return 0
  fi

  echo "Docker daemon not running — attempting to start..."
  OS_NAME="$(uname -s)"
  case "$OS_NAME" in
    Darwin)
      # Start Docker Desktop on macOS if available
      if ! pgrep -f "/Applications/Docker.app" >/dev/null 2>&1; then
        if command -v open >/dev/null 2>&1; then
          open -g -a Docker || true
        fi
      fi
      ;;
    Linux)
      # Try to start the Docker service on Linux
      if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl start docker || true
      elif command -v service >/dev/null 2>&1; then
        sudo service docker start || true
      fi
      ;;
  esac

  # Wait up to ~120s for Docker to become ready
  for i in {1..60}; do
    if docker info >/dev/null 2>&1; then
      echo "Docker is ready."
      return 0
    fi
    sleep 2
  done

  echo "ERROR: Docker daemon is not available. Please start Docker Desktop (macOS) or the docker service (Linux), then re-run this script." >&2
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker CLI is required. Please install Docker Desktop and try again." >&2
  exit 1
fi

ensure_docker_running

WORKDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/.."
cd "$WORKDIR"

mkdir -p research && cd research
if [ ! -d any-sync-dockercompose ]; then
  git clone https://github.com/anyproto/any-sync-dockercompose.git
fi
cd any-sync-dockercompose

echo "Starting any-sync docker network..."
# Prefer upstream Makefile which generates .env and configs
if command -v make >/dev/null 2>&1 && [ -f Makefile ]; then
  make start
else
  echo "WARN: 'make' not found; attempting raw docker compose up (may fail without env)." >&2
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d
  else
    docker compose up -d
  fi
fi

echo "Network started. Endpoints are exposed on localhost; run 'docker ps' to view ports."

# Build native Go FFI library
echo "Building native Go FFI library..."
if command -v go >/dev/null 2>&1; then
  (
    cd "$WORKDIR/go"
    ./build.sh
  )
  echo "Native library built: $(cd "$WORKDIR" && ls -1 lib/native/anysync_bridge_* 2>/dev/null || echo 'not found')"
else
  echo "WARN: Go not installed; skipping native build. Install Go 1.23+ and run: cd tictactoe_anysync/go && ./build.sh" >&2
fi
