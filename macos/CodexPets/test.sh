#!/bin/sh
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/codex-pets-tests"
mkdir -p "$BUILD_DIR"

swiftc \
  -framework Cocoa \
  "$SCRIPT_DIR/Sources/CodexPets/PetBrain.swift" \
  "$SCRIPT_DIR/tests/PetBrainTests/main.swift" \
  -o "$BUILD_DIR/PetBrainTests"

"$BUILD_DIR/PetBrainTests"
