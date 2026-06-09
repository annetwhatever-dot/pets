# Codex Pets

A small browser app for browsing Codex-compatible pets from Petdex and adding local custom pet packages.

## Run

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
