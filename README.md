# Codex Pets

A small project for Codex-compatible pets:

- A browser gallery for browsing Petdex pets and adding custom packages.
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

The app appears as a `CP` status-bar item. Use that menu to import a pet folder, switch pets, choose animation states, resize the overlay, copy a state API curl command, or quit.

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

Imported pets are copied to:

```text
~/Library/Application Support/CodexPets/Pets
```

The app also scans existing compatible installs:

```text
~/.petdex/pets
~/.codex/pets
```

The local state API writes connection info here:

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

Supported event types include `task.succeeded`, `task.needs_user`, `review`, and `task.failed`. `/state` remains the backward-compatible shortcut; `/event` is preferred for one-shot success, waiting/review, and failure moments. Known workflow events show curated Pet Murmurs instead of raw labels; use `/bubble` when you explicitly want to display caller-provided text.

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

Pet package rendering follows Petdex's 8-column by 9-row atlas format with `192x208` default frames.

Native app imports use the same folder shape:

```text
my-pet/
  pet.json
  spritesheet.webp
```

`spritesheet.png`, `sprite.webp`, and `sprite.png` are also accepted.
