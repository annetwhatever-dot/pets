#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/linux"
mkdir -p "$OUT_DIR"

if ! pkg-config --exists x11; then
  echo "libX11 development files are required. Install pkg-config and libx11-dev/libX11-devel." >&2
  exit 1
fi

CGO_ENABLED=1 go build -o "$OUT_DIR/pi-pet-overlay-x11" ./cmd/pi-pet-overlay-x11
