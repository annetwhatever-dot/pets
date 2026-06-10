# Codex Pets

A small project for Codex-compatible pets:

- A compact WebView Petdex picker for browsing and importing pets.
- A native macOS status-bar app that shows an imported pet in an always-on-top transparent overlay.

## Native macOS App

Build the `.app` bundle with the Swift command-line toolchain:

```sh
sh macos/CodexPets/build.sh
```

Open it:

```sh
open build/CodexPets.app
```

The app appears as a `CP` status-bar item. Use that menu to open Petdex, import a pet folder, switch pets, choose animation states, resize the overlay, or quit.

The menu also includes Calm Pet Engine controls:

- **Animation:** Focus, Default, or Playful attention budgets.
- **Bubbles / Pet Murmurs:** Silent, Quiet, Default, or Chatty. Default is intentionally calm: short curated replies, daily budgets, global cooldowns, semantic anti-repeat, and no raw workflow labels for known Codex events.
- **Mute Murmurs Today:** clears the current murmur and keeps the pet quiet until tomorrow.
- **Reduced Motion:** follow macOS Reduce Motion or force static poses.
- **Full-screen:** hidden in full-screen apps by default; opt in from Settings.

Pet Murmurs are stored locally in:

```text
~/Library/Application Support/CodexPets/DialogueHistory.json
```

Clicking a visible murmur bubble dismisses it and mutes additional murmurs for a few hours. Direct `/bubble` API messages still display as explicit caller-provided text.

The transparent overlay is click-through outside the real pet sprite, so padding around the window does not block apps underneath. Mouse proximity, hover, click, double-click, drag, and spam-click reactions work without Accessibility or Input Monitoring permissions.

Use **Browse Petdex...** from the CP menu to open the WebView-backed Petdex picker. It presents a native-style split view with search, a pet list, a preview, and compact actions. Petdex pets are downloaded into local app storage with **Import**; installed pets can be selected with **Use**. **Install to Pi** copies the bundled Pi extension to `~/.pi/agent/extensions/codex-pets.ts`.

Imported pets are copied to:

```text
~/Library/Application Support/CodexPets/Pets
```

The app also scans existing compatible installs:

```text
~/.petdex/pets
~/.codex/pets
```

The legacy local HTTP state API is disabled by default. For manual debugging only, launch the app with:

```sh
CODEX_PETS_ENABLE_HTTP_STATE_API=1 ./build/CodexPets.app/Contents/MacOS/CodexPets
```

When enabled, it writes connection info here:

```text
~/Library/Application Support/CodexPets/Runtime/state-api.json
```

Example state update:

```sh
TOKEN=$(cat "$HOME/Library/Application Support/CodexPets/Runtime/state-token")
curl -X POST http://127.0.0.1:7777/state \
  -H "content-type: application/json" \
  -H "x-codex-pets-token: $TOKEN" \
  -d '{"state":"running","duration":1200}'
```

Example bubble:

```sh
TOKEN=$(cat "$HOME/Library/Application Support/CodexPets/Runtime/state-token")
curl -X POST http://127.0.0.1:7777/bubble \
  -H "content-type: application/json" \
  -H "x-codex-pets-token: $TOKEN" \
  -d '{"text":"Working on it"}'
```

Example workflow event:

```sh
TOKEN=$(cat "$HOME/Library/Application Support/CodexPets/Runtime/state-token")
curl -X POST http://127.0.0.1:7777/event \
  -H "content-type: application/json" \
  -H "x-codex-pets-token: $TOKEN" \
  -d '{"type":"task.succeeded","label":"Tests passed","importance":"low"}'
```

Supported states are `idle`, `running`, `running-left`, `running-right`, `waving`, `jumping`, `failed`, `waiting`, and `review`.

Supported event types include `task.succeeded`, `task.needs_user`, `review`, and `task.failed`. `/state` remains the backward-compatible debug shortcut; `/event` is preferred for one-shot success, waiting/review, and failure moments. Known workflow events show curated Pet Murmurs instead of raw labels; use `/bubble` when you explicitly want to display caller-provided text.

Run the native tests:

```sh
sh macos/CodexPets/test.sh
```

## Browser Gallery

Run:

```sh
/Users/anna/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node server.mjs
```

Open <http://localhost:4173>.

## Petdex Support

- Loads the Petdex public snapshot from `https://assets.petdex.dev/manifests/petdex-v1.json`.
- Also understands the compact v2 manifest shape.
- Imports custom folders or paired files containing `pet.json` and `spritesheet.webp` or `spritesheet.png`.
- Stores custom pets in IndexedDB so spritesheets survive a refresh.

To create a local Petdex snapshot for bundling:

```sh
npm run dump:petdex
```

This writes `vendor/petdex/manifest.json`, `manifest.remote.json`, `source-manifest.json`, and downloaded pet assets under `vendor/petdex/pets/`. `macos/CodexPets/build.sh` copies `vendor/petdex` into the WebView bundle when that directory exists, and the browser tries `petdex/manifest.json` before falling back to the public manifest.

Pet package rendering follows Petdex's 8-column by 9-row atlas format with `192x208` default frames.

Native app imports use the same folder shape:

```text
my-pet/
  pet.json
  spritesheet.webp
```

`spritesheet.png`, `sprite.webp`, and `sprite.png` are also accepted.

## Pi Pet v1 Components

The cross-platform Pi Pet v1 work is split into native pieces instead of using Electron:

- `macos/CodexPets/Sources/CodexPets/InAppDaemon.swift`: macOS in-app daemon host. The AppKit process owns the Unix socket that Pi connects to.
- `cmd/pi-pet-daemon`: standalone per-user daemon over a Unix domain socket for headless/testing flows.
- `internal/protocol`: newline-delimited JSON protocol shared by Pi extension, daemon hosts, overlays, and browser bridge.
- `internal/daemon`: Go session state machine, approval broker, selected/installed pet state, catalog cache state, and subscriber broadcasts for app-owned and standalone daemon hosts.
- `pi-extension/index.ts`: Pi TypeScript extension that observes session/agent/tool lifecycle events and blocks risky bash calls until daemon approval returns.
- `internal/catalog`: Petdex manifest normalization, local `.codex/pets` and `.petdex/pets` importer validation, and PadX provider stub behind the same provider interface.
- `macos/CodexPets`: current AppKit overlay and WebKit pet browser.
- `cmd/pi-pet-overlay-x11`: Linux X11 native app. It starts the daemon socket in-process, subscribes to snapshots over that socket, and renders the selected PNG spritesheet pet in an always-on-top X11 window.

On macOS, build and launch the app; it starts the daemon socket inside the app process:

```sh
sh macos/CodexPets/build.sh
./build/CodexPets.app/Contents/MacOS/CodexPets
```

The app-owned daemon listens only on:

```text
$XDG_RUNTIME_DIR/pi-pet.sock
```

or, when `XDG_RUNTIME_DIR` is unset:

```text
/tmp/codex-pets-$UID/pi-pet.sock
```

The Pi extension uses the same path. Override it with `PI_PET_SOCKET_DIR` for tests or custom launchers. Install the extension by adding `pi-extension/index.ts` to Pi's extension paths, for example through Pi settings or by copying/symlinking it into `~/.pi/agent/extensions/`.

On Linux X11, build and run the overlay app; it also starts the daemon socket inside the app process:

```sh
sh linux/build-x11.sh
./build/linux/pi-pet-overlay-x11
```

Install the Pi extension from the Linux build with:

```sh
./build/linux/pi-pet-overlay-x11 -install-pi-extension
```

The standalone Go daemon can still be run with `go run ./cmd/pi-pet-daemon` for headless protocol checks.

Current verification:

```sh
npm test
node --check app.js
npm run test:browser-smoke
npm run test:macos-gui-smoke
sh macos/CodexPets/test.sh
sh macos/CodexPets/build.sh
env GOCACHE=/tmp/codex-pets-go-build GOOS=linux CGO_ENABLED=0 go build -o /tmp/pi-pet-overlay-x11-check ./cmd/pi-pet-overlay-x11
```

Latest checkpoint results on macOS:

- `npm test`: passed; covers Go protocol, daemon attention state, tool progress updates, selected/installed pet state, catalog cache state, approval broker/integration flow, Petdex provider normalization, Linux X11 PNG atlas/frame/text helper logic, Pi extension unit tests, turn/tool lifecycle hooks, abort-aware approval, serialized notification delivery, and a scripted Pi-extension-to-real-daemon-to-overlay Unix-socket approval flow.
- `node --check app.js`: passed; verifies the bundled WebView picker script parses after native bridge and installed-pet edits.
- `npm run test:browser-smoke`: passed; renders the bundled WebView picker in local headless Chrome, verifies installed pet spritesheet preview, Pi extension install, and installed-pet selection bridge messages, and writes `/tmp/codex-pets-browser-smoke.png`.
- `npm run test:macos-gui-smoke`: passed; builds and launches the real AppKit app, verifies the app creates its in-process Unix-socket daemon, sends fake Pi `running`, `failed`, and `approval_required` events to that socket, and verifies native overlay-state mapping.
- `sh macos/CodexPets/test.sh`: passed; covers PetBrain, Petdex parser/importer, WebView bridge action allowlist and payload validation, Pi extension install, installed-pet bridge payloads, daemon snapshot overlay presentation, in-app daemon Unix-socket protocol handling, and overlay hit testing.
- `sh macos/CodexPets/build.sh`: passed; produced `build/CodexPets.app`.
- `env GOCACHE=/tmp/codex-pets-go-build GOOS=linux CGO_ENABLED=0 go build -o /tmp/pi-pet-overlay-x11-check ./cmd/pi-pet-overlay-x11`: passed; verifies the Linux overlay command wrapper, Pi extension installer flag, and non-cgo fallback compile from macOS.

## Security Model

- The macOS AppKit app and Linux X11 app run the daemon inside the app process, default to Unix domain sockets only, and create socket directories with user-only permissions. The standalone Go daemon uses the same Unix-socket protocol for headless/testing flows.
- No TCP listener is enabled by default. The macOS legacy HTTP state API starts only when `CODEX_PETS_ENABLE_HTTP_STATE_API=1` is set explicitly for manual debugging.
- The Pi extension does not send prompts, provider payloads, tool output, or full approval payload logs to the daemon. It sends lifecycle events and bounded safe summaries such as tool name and a shortened command summary.
- Pet packs are treated as data-only packages. The local importer requires `pet.json` plus a PNG/WebP raster spritesheet, enforces size limits, rejects path traversal for spritesheet paths, and stores license/attribution metadata when present.
- The WebView picker is separate from overlay rendering. The native shell bridge is allowlisted to pet import, installed-pet list, installed-pet select, and Pi extension install messages.

## Platform Limitations

- The macOS AppKit app hosts the Unix-socket daemon in-process, subscribes to it through the same local protocol path as external clients, and maps daemon attention states to native pet states. The older local HTTP state API remains as an opt-in debug compatibility path.
- The Linux X11 app source is implemented behind `linux,cgo` build tags and can be built on Linux with `sh linux/build-x11.sh` after installing `pkg-config` and `libX11` development headers. The Linux binary also supports `-install-pi-extension`, which copies the bundled Pi extension to `~/.pi/agent/extensions/codex-pets.ts`. Native X11 build/run verification is unavailable in this macOS environment; local tests cover the renderer's PNG atlas loading, frame selection, drag direction helpers, scaling, status text helpers, and Pi extension installer without requiring X11. The current Linux renderer supports PNG spritesheets; WebP spritesheets need conversion or a future native decoder dependency.
- The WebView picker can preview Petdex spritesheets, import Petdex pets in the macOS shell, install the Pi extension, list installed pets through the native bridge, and select installed pets. The local rendered browser smoke covers those bridge-driven flows in headless Chrome. The macOS GUI smoke covers the real AppKit app's in-process daemon socket and native overlay-state mapping without requiring live Pi inference.
- PadX is represented by `PadXProvider` behind the catalog interface. Web searches for `PadX pet package format API PadX pets manifest`, `PadX provider pet catalog API`, `"PadX" "pets"`, `"PadX" "pet" "manifest"`, and `"PadX" "package" "manifest"` did not reveal a public pet catalog API or package format. To replace the stub, provide a PadX manifest URL, SDK/API docs, or local package format.

Manual standalone daemon smoke test:

```sh
SOCKET=/tmp/pi-pet.sock
go run ./cmd/pi-pet-daemon -socket "$SOCKET"
```

In another shell, run `npm test` for scripted protocol and approval-flow checks. The integration tests prove Pi-extension-style session updates reach a subscribed overlay client, and `pi-extension/index.test.ts` starts the actual daemon, registers the real Pi extension hooks, sends approval responses through the daemon, and verifies the blocked hook resumes.

Manual macOS app smoke test:

1. Build and open `build/CodexPets.app`; the app creates the Pi socket itself.
3. Add `pi-extension/index.ts` to Pi's extension paths and start a Pi session.
4. Confirm the AppKit overlay changes state for `approval_required`, `failed`, `done`, `running`, `thinking`, and `idle`.
5. Trigger a risky Pi bash tool call and confirm the overlay moves into its approval-needed waiting state.
6. In **Browse Petdex...**, use **Install to Pi** to copy the Pi extension, then use **Import** for a Petdex pet or **Use** for an installed pet.
