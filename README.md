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

Supported states are `idle`, `running`, `running-left`, `running-right`, `waving`, `jumping`, `failed`, `waiting`, and `review`.

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
