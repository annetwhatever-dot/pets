#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$ROOT_DIR/build/CodexPets.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

swiftc \
  -O \
  -framework Cocoa \
  -framework Network \
  "$SCRIPT_DIR/Sources/CodexPets/"*.swift \
  -o "$MACOS_DIR/CodexPets"

chmod +x "$MACOS_DIR/CodexPets"

echo "Built $APP_DIR"
