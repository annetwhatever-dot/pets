const PETDEX_MANIFEST_URL = "https://assets.petdex.dev/manifests/petdex-v1.json";
const PETDEX_MANIFEST_V2_URL = "https://assets.petdex.dev/manifests/petdex-v2.json";
const PETDEX_ASSET_BASE = "https://assets.petdex.dev";
const PREBUNDLED_MANIFEST_URL = "prebundled-pets/manifest.json";
const CATALOG_FETCH_TIMEOUT_MS = 8000;
const BUNDLED_MANIFEST_URLS = [
  "petdex/manifest.json",
  "vendor/petdex/manifest.json",
  "petdex/source-manifest.json",
  "vendor/petdex/source-manifest.json",
];

const PREBUNDLED_PETS = [
  {
    slug: "aqua-wisp",
    displayName: "Aqua Wisp",
    description: "Animated Codex-compatible pet bundled with the browser.",
    kind: "creature",
    submittedBy: "denghaowen59",
    tags: ["prebundled"],
    spritesheetUrl: "pets/aqua-wisp/sprite.webp",
    petJsonUrl: "pets/aqua-wisp/pet.json",
    frameWidth: 192,
    frameHeight: 208,
  },
  {
    slug: "boba",
    displayName: "Boba",
    description: "Animated Codex-compatible pet bundled with the browser.",
    kind: "creature",
    submittedBy: "railly",
    tags: ["prebundled"],
    spritesheetUrl: "pets/boba/spritesheet.webp",
    petJsonUrl: "pets/boba/pet.json",
    frameWidth: 192,
    frameHeight: 208,
  },
  {
    slug: "cat",
    displayName: "Cat",
    description: "Animated Codex-compatible pet bundled with the browser.",
    kind: "creature",
    submittedBy: "huigegood",
    tags: ["prebundled"],
    spritesheetUrl: "pets/cat/sprite.webp",
    petJsonUrl: "pets/cat/pet.json",
    frameWidth: 192,
    frameHeight: 208,
  },
  {
    slug: "pc-guy",
    displayName: "PC Guy",
    description: "Animated Codex-compatible pet bundled with the browser.",
    kind: "character",
    submittedBy: "c",
    tags: ["prebundled"],
    spritesheetUrl: "pets/pc-guy/sprite.webp",
    petJsonUrl: "pets/pc-guy/pet.json",
    frameWidth: 192,
    frameHeight: 208,
  },
  {
    slug: "pochita",
    displayName: "Pochita",
    description: "Animated Codex-compatible pet bundled with the browser.",
    kind: "creature",
    submittedBy: "DeryFerd",
    tags: ["prebundled"],
    spritesheetUrl: "pets/pochita/spritesheet.webp",
    petJsonUrl: "pets/pochita/pet.json",
    frameWidth: 192,
    frameHeight: 208,
  },
];

const IDLE_STATE = {
  row: 0,
  frames: 6,
  durationMs: 1100,
};

const els = {
  search: document.querySelector("#search"),
  status: document.querySelector("#status"),
  list: document.querySelector("#pet-list"),
  spritePreview: document.querySelector("#sprite-preview"),
  sourceLabel: document.querySelector("#source-label"),
  petName: document.querySelector("#pet-name"),
  petDescription: document.querySelector("#pet-description"),
  primaryAction: document.querySelector("#primary-action"),
  installPiAction: document.querySelector("#install-pi-action"),
  rowTemplate: document.querySelector("#pet-row-template"),
};

const state = {
  catalog: [],
  installed: [],
  selected: null,
  query: "",
  nativeReady: false,
  busy: false,
  piInstallBusy: false,
  lastMessage: "",
};

window.__codexPetsAppBoot = {
  started: true,
  loaded: false,
  error: "",
};

try {
  init();
  window.__codexPetsAppBoot.loaded = true;
} catch (error) {
  window.__codexPetsAppBoot.error = error?.stack || error?.message || String(error);
  throw error;
}

function init() {
  bindEvents();
  installPrebundledCatalog();
  if (nativeBridgeAvailable()) {
    handleNativeReady();
  }
  loadCatalog();
}

function bindEvents() {
  els.search.addEventListener("input", () => {
    state.query = els.search.value.trim().toLowerCase();
    state.lastMessage = "";
    renderList();
  });

  els.search.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      selectAdjacentPet(1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      selectAdjacentPet(-1);
    } else if (event.key === "Enter" && state.selected) {
      event.preventDefault();
      useSelectedPet();
    }
  });

  els.primaryAction.addEventListener("click", useSelectedPet);
  els.installPiAction.addEventListener("click", installPiExtension);

  window.addEventListener("codex-pets-native-ready", handleNativeReady);
  window.addEventListener("codex-pets-native-installed-pets", (event) => {
    const pets = Array.isArray(event.detail?.pets) ? event.detail.pets : [];
    const selectedSlug = state.selected?.slug || "";
    const selectedWasCatalog = state.selected?.source === "petdex";
    state.installed = pets.map(normalizePet).filter(Boolean);
    if (selectedSlug && selectedWasCatalog) {
      const installedMatch = state.installed.find((pet) => pet.slug === selectedSlug);
      if (installedMatch) state.selected = installedMatch;
    }
    chooseInitialPet();
    render();
  });
  window.addEventListener("codex-pets-native-import-result", (event) => {
    const detail = event.detail || {};
    state.busy = false;
    state.lastMessage = detail.message || (detail.ok ? "Done" : "Could not update pet");
    requestInstalledPets();
    render();
  });
  window.addEventListener("codex-pets-native-pi-install-result", (event) => {
    const detail = event.detail || {};
    state.piInstallBusy = false;
    state.lastMessage = detail.message || (detail.ok ? "Installed Pi extension" : "Could not install Pi extension");
    render();
  });
}

async function loadCatalog() {
  if (state.catalog.length === 0) {
    setStatus("Loading Petdex...");
  } else {
    setStatus("Loading full Petdex...");
  }
  const candidates = [
    ...BUNDLED_MANIFEST_URLS,
    PETDEX_MANIFEST_URL,
    PETDEX_MANIFEST_V2_URL,
  ];

  for (const url of candidates) {
    try {
      const manifest = await fetchJSON(url, CATALOG_FETCH_TIMEOUT_MS);
      const pets = normalizeManifest(manifest, new URL(url, document.baseURI));
      if (pets.length === 0) throw new Error("Manifest is empty");
      state.catalog = pets;
      state.lastMessage = "";
      chooseInitialPet();
      render();
      return;
    } catch {
      // Try the next source. The bundled app uses petdex/source-manifest.json;
      // local development uses vendor/petdex/source-manifest.json.
    }
  }

  state.lastMessage =
    state.catalog.length > 0 ? "Using prebundled pets" : "Petdex could not be loaded";
  chooseInitialPet();
  render();
}

function installPrebundledCatalog() {
  const pets = normalizeManifest(
    { pets: PREBUNDLED_PETS },
    new URL(PREBUNDLED_MANIFEST_URL, document.baseURI),
  );
  state.catalog = pets;
  state.lastMessage = "";
  chooseInitialPet();
  render();
}

async function fetchJSON(url, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      cache: "no-store",
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}

function normalizeManifest(raw, manifestURL = new URL(document.baseURI)) {
  if (raw?.v === 2 && Array.isArray(raw.pets)) {
    const base = trimSlash(raw.assetBase || PETDEX_ASSET_BASE);
    return raw.pets
      .map((item) => {
        if (!Array.isArray(item)) return null;
        const [slug, displayName, kind, submittedBy, spritesheet, petJson, zip] = item;
        return normalizePet({
          source: "petdex",
          slug,
          displayName,
          kind,
          submittedBy,
          spritesheetUrl: absolutizeAsset(spritesheet, base),
          petJsonUrl: petJson ? absolutizeAsset(petJson, base) : "",
          zipUrl: zip ? absolutizeAsset(zip, base) : "",
        });
      })
      .filter(Boolean);
  }

  if (Array.isArray(raw?.pets)) {
    return raw.pets
      .map((pet) => normalizePet({ ...pet, source: "petdex" }))
      .map((pet) => resolveManifestPetAssets(pet, manifestURL))
      .filter(Boolean);
  }

  throw new Error("Unsupported manifest shape");
}

function resolveManifestPetAssets(pet, manifestURL) {
  if (!pet) return null;
  return {
    ...pet,
    spritesheetUrl: absolutizeManifestAsset(pet.spritesheetUrl, manifestURL),
    petJsonUrl: absolutizeManifestAsset(pet.petJsonUrl, manifestURL),
    zipUrl: absolutizeManifestAsset(pet.zipUrl, manifestURL),
  };
}

function normalizePet(input) {
  if (!input || typeof input !== "object") return null;
  const slug = cleanString(input.slug || input.id);
  const displayName = cleanString(input.displayName || input.name || slug);
  const spritesheetUrl = cleanString(
    input.spritesheetUrl ||
      input.spritesheetURL ||
      input.spritesheetPath ||
      input.spritesheet ||
      input.spriteUrl ||
      input.spriteURL,
  );

  if (!slug || !displayName || !spritesheetUrl) return null;

  return {
    source: cleanString(input.source) || "petdex",
    nativePetId: cleanString(input.nativePetId),
    slug,
    displayName,
    description: cleanString(input.description) || "Animated Codex-compatible pet.",
    kind: cleanString(input.kind) || "pet",
    submittedBy: cleanString(input.submittedBy || input.author),
    tags: listStrings(input.tags || input.vibes),
    spritesheetUrl,
    petJsonUrl: cleanString(input.petJsonUrl || input.petJSONUrl || input.petJsonURL),
    zipUrl: cleanString(input.zipUrl || input.zipURL),
    frameWidth: positiveNumber(input.frameWidth) || 192,
    frameHeight: positiveNumber(input.frameHeight) || 208,
  };
}

function chooseInitialPet() {
  if (state.selected && allPets().some((pet) => samePet(pet, state.selected))) return;
  state.selected =
    state.installed[0] ||
    state.catalog.find((pet) => pet.slug === "boba") ||
    state.catalog[0] ||
    null;
}

function render() {
  renderList();
  renderSelected();
}

function renderList() {
  const pets = filteredPets();
  const fragment = document.createDocumentFragment();

  for (const pet of pets) {
    const row = els.rowTemplate.content.firstElementChild.cloneNode(true);
    row.dataset.slug = pet.slug;
    row.dataset.source = pet.source;
    row.setAttribute("aria-selected", samePet(pet, state.selected) ? "true" : "false");
    row.classList.toggle("is-selected", samePet(pet, state.selected));
    row.querySelector(".pet-row-name").textContent = pet.displayName;
    row.querySelector(".pet-row-meta").textContent = rowMeta(pet);
    row.addEventListener("click", () => {
      state.selected = pet;
      state.lastMessage = "";
      render();
    });
    fragment.append(row);
  }

  els.list.replaceChildren(fragment);

  if (state.lastMessage) {
    setStatus(state.lastMessage);
  } else if (pets.length === 0) {
    setStatus("No matching pets");
  } else {
    const installedCount = state.installed.length;
    const total = allPets().length;
    const suffix = installedCount > 0 ? `, ${installedCount} installed` : "";
    setStatus(`${formatCount(pets.length)} of ${formatCount(total)} pets${suffix}`);
  }
}

function renderSelected() {
  const pet = state.selected;
  if (!pet) {
    els.sourceLabel.textContent = "Petdex";
    els.petName.textContent = "No Pet Selected";
    els.petDescription.textContent = "Choose a pet to preview it.";
    els.spritePreview.replaceChildren(emptyPreview());
    updateAction();
    return;
  }

  els.sourceLabel.textContent = sourceLabel(pet);
  els.petName.textContent = pet.displayName;
  els.petDescription.textContent = pet.description;
  els.spritePreview.replaceChildren(createSpriteElement(pet));
  updateAction();
}

function updateAction() {
  const pet = state.selected;
  const canUse =
    state.nativeReady &&
    !state.busy &&
    (pet?.source === "petdex" || (pet?.source === "installed" && pet.nativePetId));
  els.primaryAction.disabled = !canUse;
  els.primaryAction.textContent = pet?.source === "installed" ? "Use" : "Import";
  els.installPiAction.disabled = !state.nativeReady || state.busy || state.piInstallBusy;
  els.installPiAction.textContent = state.piInstallBusy ? "Installing..." : "Install to Pi";
}

function useSelectedPet() {
  if (!state.selected || state.busy) return;

  if (state.selected.source === "installed") {
    if (!state.selected.nativePetId) return;
    state.busy = true;
    state.lastMessage = `Selecting ${state.selected.displayName}...`;
    postNativeMessage({
      action: "selectInstalledPet",
      petId: state.selected.nativePetId,
    });
    render();
    return;
  }

  if (state.selected.source !== "petdex") return;
  state.busy = true;
  state.lastMessage = `Importing ${state.selected.displayName}...`;
  postNativeMessage({
    action: "importPet",
    pet: nativePetPayload(state.selected),
  });
  render();
}

function installPiExtension() {
  if (!state.nativeReady || state.busy || state.piInstallBusy) return;
  state.piInstallBusy = true;
  state.lastMessage = "Installing Pi extension...";
  postNativeMessage({ action: "installPiExtension" });
  render();
}

function handleNativeReady() {
  state.nativeReady = true;
  document.documentElement.classList.add("native-shell");
  requestInstalledPets();
  render();
}

function requestInstalledPets() {
  if (!nativeBridgeAvailable()) return;
  postNativeMessage({ action: "listInstalledPets" });
}

function postNativeMessage(payload) {
  if (window.CodexPetsNative?.postMessage) {
    window.CodexPetsNative.postMessage(payload);
    return true;
  }
  if (window.webkit?.messageHandlers?.codexPets?.postMessage) {
    window.webkit.messageHandlers.codexPets.postMessage(payload);
    return true;
  }
  return false;
}

function nativeBridgeAvailable() {
  return Boolean(
    window.CodexPetsNative?.postMessage ||
      window.webkit?.messageHandlers?.codexPets?.postMessage,
  );
}

function nativePetPayload(pet) {
  return {
    slug: pet.slug,
    displayName: pet.displayName,
    description: pet.description,
    kind: pet.kind,
    submittedBy: pet.submittedBy,
    tags: pet.tags,
    spritesheetUrl: absoluteAssetURL(pet.spritesheetUrl),
    petJsonUrl: absoluteAssetURL(pet.petJsonUrl),
    zipUrl: absoluteAssetURL(pet.zipUrl),
    frameWidth: pet.frameWidth,
    frameHeight: pet.frameHeight,
  };
}

function createSpriteElement(pet) {
  const frameWidth = pet.frameWidth || 192;
  const frameHeight = pet.frameHeight || 208;
  const scale = spriteScale(frameWidth, frameHeight);

  const frame = document.createElement("span");
  frame.className = "pet-sprite-frame";
  frame.setAttribute("role", "img");
  frame.setAttribute("aria-label", pet.displayName);
  frame.style.setProperty("--frame-w", `${frameWidth}px`);
  frame.style.setProperty("--frame-h", `${frameHeight}px`);
  frame.style.setProperty("--sheet-w", `${frameWidth * 8}px`);
  frame.style.setProperty("--sheet-h", `${frameHeight * 9}px`);
  frame.style.setProperty("--scale", String(scale));

  const sprite = document.createElement("span");
  sprite.className = "pet-sprite";
  sprite.style.setProperty("--sprite-url", `url("${cssEscapeUrl(pet.spritesheetUrl)}")`);
  sprite.style.setProperty("--sprite-frames", String(IDLE_STATE.frames));
  sprite.style.setProperty("--sprite-duration", `${IDLE_STATE.durationMs}ms`);
  sprite.style.setProperty("--sprite-end-x", `-${IDLE_STATE.frames * frameWidth}px`);
  frame.append(sprite);
  return frame;
}

function emptyPreview() {
  const element = document.createElement("span");
  element.className = "empty-preview";
  element.textContent = "No preview";
  return element;
}

function spriteScale(frameWidth, frameHeight) {
  const availableWidth = Math.max(220, window.innerWidth - 340);
  const availableHeight = Math.max(240, window.innerHeight - 150);
  const fit = Math.min(availableWidth / frameWidth, availableHeight / frameHeight, 1.85);
  return Math.max(0.85, fit);
}

function selectAdjacentPet(direction) {
  const pets = filteredPets();
  if (pets.length === 0) return;
  const index = Math.max(0, pets.findIndex((pet) => samePet(pet, state.selected)));
  const nextIndex = Math.min(pets.length - 1, Math.max(0, index + direction));
  state.selected = pets[nextIndex];
  render();
  els.list
    .querySelector(`[data-source="${state.selected.source}"][data-slug="${cssSelectorEscape(state.selected.slug)}"]`)
    ?.scrollIntoView({ block: "nearest" });
}

function filteredPets() {
  const query = state.query;
  if (!query) return allPets();

  return allPets().filter((pet) => {
    const haystack = [
      pet.displayName,
      pet.slug,
      pet.kind,
      pet.submittedBy,
      pet.description,
      ...pet.tags,
      pet.source,
    ]
      .join(" ")
      .toLowerCase();
    return haystack.includes(query);
  });
}

function allPets() {
  return [...state.installed, ...state.catalog];
}

function samePet(left, right) {
  if (!left || !right) return false;
  if (left.source === "installed" || right.source === "installed") {
    return left.nativePetId && right.nativePetId
      ? left.nativePetId === right.nativePetId
      : left.source === right.source && left.slug === right.slug;
  }
  return left.source === right.source && left.slug === right.slug;
}

function rowMeta(pet) {
  const source = pet.source === "installed" ? "Installed" : "Petdex";
  const detail = pet.submittedBy || pet.kind;
  return detail ? `${source} - ${detail}` : source;
}

function sourceLabel(pet) {
  if (pet.source === "installed") {
    return pet.submittedBy ? `Installed - ${pet.submittedBy}` : "Installed";
  }
  return pet.submittedBy ? `Petdex - ${pet.submittedBy}` : "Petdex";
}

function absolutizeAsset(value, base) {
  if (!value) return "";
  if (/^(https?|file|data|blob):/i.test(value)) return value;
  return `${trimSlash(base)}/${String(value).replace(/^\/+/, "")}`;
}

function absolutizeManifestAsset(value, manifestURL) {
  if (!value) return "";
  if (/^(https?|file|data|blob):/i.test(value)) return value;
  try {
    return new URL(value, manifestURL).href;
  } catch {
    return value;
  }
}

function absoluteAssetURL(value) {
  if (!value) return "";
  try {
    return new URL(value, document.baseURI).href;
  } catch {
    return value;
  }
}

function trimSlash(value) {
  return String(value).replace(/\/+$/, "");
}

function cleanString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function listStrings(value) {
  if (!Array.isArray(value)) return [];
  return value.map(cleanString).filter(Boolean).slice(0, 12);
}

function positiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function formatCount(value) {
  return new Intl.NumberFormat("en-US").format(value);
}

function cssEscapeUrl(value) {
  return String(value).replace(/"/g, '\\"');
}

function cssSelectorEscape(value) {
  if (window.CSS?.escape) return CSS.escape(value);
  return String(value).replace(/["\\]/g, "\\$&");
}

function setStatus(message) {
  els.status.textContent = message;
}

window.addEventListener("resize", () => {
  if (state.selected) renderSelected();
});
