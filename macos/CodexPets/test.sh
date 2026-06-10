#!/bin/sh
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/codex-pets-tests"
mkdir -p "$BUILD_DIR"

swiftc \
  -framework Cocoa \
  -framework WebKit \
  -framework Network \
  "$SCRIPT_DIR/Sources/CodexPets/DialogueEngine.swift" \
  "$SCRIPT_DIR/Sources/CodexPets/PetModels.swift" \
  "$SCRIPT_DIR/Sources/CodexPets/PetdexBrowser.swift" \
  "$SCRIPT_DIR/Sources/CodexPets/DaemonClient.swift" \
  "$SCRIPT_DIR/Sources/CodexPets/InAppDaemon.swift" \
  "$SCRIPT_DIR/Sources/CodexPets/StateServer.swift" \
  "$SCRIPT_DIR/Sources/CodexPets/PetBrain.swift" \
  "$SCRIPT_DIR/Sources/CodexPets/PetOverlay.swift" \
  "$SCRIPT_DIR/tests/PetBrainTests/main.swift" \
  -o "$BUILD_DIR/PetBrainTests"

"$BUILD_DIR/PetBrainTests"
