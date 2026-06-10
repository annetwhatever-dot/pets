#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="$ROOT_DIR/build/CodexPets.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
WEB_DIR="$RESOURCES_DIR/PetdexBrowser"
PI_EXTENSION_DIR="$RESOURCES_DIR/PiExtension"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$WEB_DIR" "$PI_EXTENSION_DIR"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/index.html" "$WEB_DIR/index.html"
cp "$ROOT_DIR/app.js" "$WEB_DIR/app.js"
cp "$ROOT_DIR/styles.css" "$WEB_DIR/styles.css"
cp "$ROOT_DIR/pi-extension/index.ts" "$PI_EXTENSION_DIR/index.ts"
if [ -d "$ROOT_DIR/prebundled-pets" ]; then
  cp -R "$ROOT_DIR/prebundled-pets" "$WEB_DIR/prebundled-pets"
fi
if [ "${CODEX_PETS_SKIP_VENDOR_PETDEX:-0}" != "1" ] && [ -d "$ROOT_DIR/vendor/petdex" ]; then
  cp -R "$ROOT_DIR/vendor/petdex" "$WEB_DIR/petdex"
fi

swiftc \
  -O \
  -framework Cocoa \
  -framework WebKit \
  -framework Network \
  "$SCRIPT_DIR/Sources/CodexPets/"*.swift \
  -o "$MACOS_DIR/CodexPets"

chmod +x "$MACOS_DIR/CodexPets"

echo "Built $APP_DIR"
