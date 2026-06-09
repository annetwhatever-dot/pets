const PETDEX_MANIFEST_V1 = "https://assets.petdex.dev/manifests/petdex-v1.json";
const PETDEX_MANIFEST_V2 = "https://assets.petdex.dev/manifests/petdex-v2.json";
const PETDEX_BASE = "https://assets.petdex.dev";
const CUSTOM_DB = "codex-pets-app";
const CUSTOM_STORE = "customPets";
const PAGE_SIZE = 48;

const DEFAULT_STATES = [
  {
    id: "idle",
    label: "Idle",
    row: 0,
    frames: 6,
    durationMs: 1100,
    aliases: ["idle"],
  },
  {
    id: "running-right",
    label: "Run Right",
    row: 1,
    frames: 8,
    durationMs: 1060,
    aliases: ["running-right", "runRight", "right"],
  },
  {
    id: "running-left",
    label: "Run Left",
    row: 2,
    frames: 8,
    durationMs: 1060,
    aliases: ["running-left", "runLeft", "left"],
  },
  {
    id: "waving",
    label: "Wave",
    row: 3,
    frames: 4,
    durationMs: 700,
    aliases: ["waving", "wave"],
  },
  {
    id: "jumping",
    label: "Jump",
    row: 4,
    frames: 5,
    durationMs: 840,
    aliases: ["jumping", "jump"],
  },
  {
    id: "failed",
    label: "Failed",
    row: 5,
    frames: 8,
    durationMs: 1220,
    aliases: ["failed", "failure", "error"],
  },
  {
    id: "waiting",
    label: "Waiting",
    row: 6,
    frames: 6,
    durationMs: 1010,
    aliases: ["waiting", "wait", "extra1"],
  },
  {
    id: "running",
    label: "Running",
    row: 7,
    frames: 6,
    durationMs: 820,
    aliases: ["running", "run", "extra2"],
  },
  {
    id: "review",
    label: "Review",
    row: 8,
    frames: 6,
    durationMs: 1030,
    aliases: ["review", "thinking", "inspect"],
  },
];

const els = {
  manifestForm: document.querySelector("#manifest-form"),
  manifestUrl: document.querySelector("#manifest-url"),
  search: document.querySelector("#pet-search"),
  sourceButtons: [...document.querySelectorAll("[data-source]")],
  folderInput: document.querySelector("#folder-input"),
  filesInput: document.querySelector("#files-input"),
  urlImportForm: document.querySelector("#url-import-form"),
  petJsonUrl: document.querySelector("#pet-json-url"),
  spriteUrl: document.querySelector("#sprite-url"),
  importStatus: document.querySelector("#import-status"),
  manifestTotal: document.querySelector("#manifest-total"),
  visibleTotal: document.querySelector("#visible-total"),
  customCount: document.querySelector("#custom-count"),
  selectedSource: document.querySelector("#selected-source"),
  selectedKind: document.querySelector("#selected-kind"),
  selectedName: document.querySelector("#selected-name"),
  selectedDescription: document.querySelector("#selected-description"),
  selectedTags: document.querySelector("#selected-tags"),
  selectedSprite: document.querySelector("#selected-sprite"),
  stateTabs: document.querySelector("#state-tabs"),
  installCommand: document.querySelector("#install-command"),
  copyCommand: document.querySelector("#copy-command"),
  openPetdex: document.querySelector("#open-petdex"),
  galleryStatus: document.querySelector("#gallery-status"),
  grid: document.querySelector("#pet-grid"),
  loadMore: document.querySelector("#load-more"),
  shuffle: document.querySelector("#shuffle-pet"),
  refresh: document.querySelector("#refresh-manifest"),
  cardTemplate: document.querySelector("#pet-card-template"),
};

const state = {
  manifestUrl: PETDEX_MANIFEST_V1,
  petdexPets: [],
  customPets: [],
  selected: null,
  selectedStateId: "idle",
  filterSource: "all",
  query: "",
  visibleLimit: PAGE_SIZE,
  detailsCache: new Map(),
  activeObjectUrls: new Set(),
};

init();

async function init() {
  bindEvents();
  await loadCustomPets();
  await loadManifest(state.manifestUrl);
}

function bindEvents() {
  els.manifestForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const url = els.manifestUrl.value.trim();
    if (!url) return;
    await loadManifest(url);
  });

  els.refresh.addEventListener("click", () => loadManifest(state.manifestUrl));

  els.search.addEventListener("input", () => {
    state.query = els.search.value.trim().toLowerCase();
    state.visibleLimit = PAGE_SIZE;
    renderGallery();
  });

  for (const button of els.sourceButtons) {
    button.addEventListener("click", () => {
      state.filterSource = button.dataset.source;
      state.visibleLimit = PAGE_SIZE;
      for (const item of els.sourceButtons) {
        item.classList.toggle("is-active", item === button);
      }
      renderGallery();
    });
  }

  els.loadMore.addEventListener("click", () => {
    state.visibleLimit += PAGE_SIZE;
    renderGallery();
  });

  els.shuffle.addEventListener("click", () => {
    const pets = filteredPets();
    if (pets.length === 0) return;
    const next = pets[Math.floor(Math.random() * pets.length)];
    selectPet(next);
  });

  els.copyCommand.addEventListener("click", async () => {
    const value = els.installCommand.textContent.trim();
    try {
      await navigator.clipboard.writeText(value);
      flashButton(els.copyCommand, "Copied");
    } catch {
      flashButton(els.copyCommand, "Copy failed");
    }
  });

  els.folderInput.addEventListener("change", async () => {
    await importFromFiles([...els.folderInput.files]);
    els.folderInput.value = "";
  });

  els.filesInput.addEventListener("change", async () => {
    await importFromFiles([...els.filesInput.files]);
    els.filesInput.value = "";
  });

  els.urlImportForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    await importFromUrls(els.petJsonUrl.value.trim(), els.spriteUrl.value.trim());
  });
}

async function loadManifest(url) {
  setGalleryStatus("Loading Petdex...");
  state.manifestUrl = url;
  els.manifestUrl.value = url;

  try {
    const response = await fetch(url, { cache: "no-store" });
    if (!response.ok) throw new Error(`Manifest returned ${response.status}`);
    const raw = await response.json();
    state.petdexPets = normalizeManifest(raw);
    els.manifestTotal.textContent = formatCount(state.petdexPets.length);
    setGalleryStatus(`Loaded ${formatCount(state.petdexPets.length)} Petdex pets`);

    if (!state.selected) {
      const preferred =
        state.petdexPets.find((pet) => pet.slug === "boba") ?? state.petdexPets[0];
      if (preferred) selectPet(preferred);
    }
    renderGallery();
  } catch (error) {
    setGalleryStatus(error.message || "Could not load manifest");
    if (url !== PETDEX_MANIFEST_V2) {
      els.manifestUrl.value = PETDEX_MANIFEST_V2;
    }
    renderGallery();
  }
}

function normalizeManifest(raw) {
  if (raw?.v === 2 && Array.isArray(raw.pets)) {
    const base = trimSlash(raw.assetBase || PETDEX_BASE);
    return raw.pets
      .map((item) => {
        if (!Array.isArray(item)) return null;
        const [
          slug,
          displayName,
          kind,
          submittedBy,
          spritesheet,
          petJson,
          zip,
        ] = item;
        if (!slug || !displayName || !spritesheet) return null;
        return normalizePet({
          slug,
          displayName,
          kind,
          submittedBy,
          spritesheetUrl: absolutizeAsset(spritesheet, base),
          petJsonUrl: petJson ? absolutizeAsset(petJson, base) : "",
          zipUrl: zip ? absolutizeAsset(zip, base) : null,
        });
      })
      .filter(Boolean);
  }

  if (Array.isArray(raw?.pets)) {
    return raw.pets.map(normalizePet).filter(Boolean);
  }

  throw new Error("Manifest shape is not supported");
}

function normalizePet(input) {
  const slug = cleanString(input.slug || input.id);
  const displayName = cleanString(input.displayName || input.name || slug);
  const spritesheetUrl = cleanString(
    input.spritesheetUrl || input.spritesheetPath || input.spriteUrl,
  );
  if (!slug || !displayName || !spritesheetUrl) return null;

  return {
    source: input.source || "petdex",
    slug,
    displayName,
    description: cleanString(input.description) || "Animated Codex pet.",
    kind: cleanString(input.kind) || "pet",
    submittedBy: cleanString(input.submittedBy || input.author) || "",
    tags: listStrings(input.tags || input.vibes),
    spritesheetUrl,
    petJsonUrl: cleanString(input.petJsonUrl),
    zipUrl: cleanString(input.zipUrl),
    petJson: input.petJson || null,
    frameWidth: positiveNumber(input.frameWidth) || 192,
    frameHeight: positiveNumber(input.frameHeight) || 208,
    states: normalizeStates(input.petJson || input),
    addedAt: input.addedAt || Date.now(),
  };
}

async function loadPetDetails(pet) {
  if (pet.source === "custom" || !pet.petJsonUrl) return pet;
  if (state.detailsCache.has(pet.slug)) {
    return { ...pet, ...state.detailsCache.get(pet.slug) };
  }

  try {
    const response = await fetch(pet.petJsonUrl);
    if (!response.ok) throw new Error(`pet.json ${response.status}`);
    const petJson = await response.json();
    const details = normalizeDetails(petJson);
    state.detailsCache.set(pet.slug, details);
    return { ...pet, ...details };
  } catch {
    return pet;
  }
}

function normalizeDetails(petJson) {
  return {
    petJson,
    displayName: cleanString(petJson.displayName || petJson.name),
    description: cleanString(petJson.description),
    kind: cleanString(petJson.kind),
    tags: listStrings(petJson.tags || petJson.vibes),
    frameWidth: positiveNumber(petJson.frameWidth) || 192,
    frameHeight: positiveNumber(petJson.frameHeight) || 208,
    states: normalizeStates(petJson),
  };
}

async function selectPet(pet) {
  const detailed = await loadPetDetails(pet);
  state.selected = { ...pet, ...dropEmptyDetails(detailed) };
  state.selectedStateId = state.selectedStateId || "idle";
  renderSelected();
  renderGallery();
}

function dropEmptyDetails(pet) {
  const next = { ...pet };
  if (!next.displayName) delete next.displayName;
  if (!next.description) delete next.description;
  if (!next.kind) delete next.kind;
  return next;
}

function renderSelected() {
  const pet = state.selected;
  if (!pet) return;
  const selectedState =
    pet.states.find((item) => item.id === state.selectedStateId) ?? pet.states[0];

  els.selectedSource.textContent = pet.source === "custom" ? "Custom" : "Petdex";
  els.selectedKind.textContent = pet.kind;
  els.selectedName.textContent = pet.displayName;
  els.selectedDescription.textContent = pet.description || "Animated Codex pet.";
  els.installCommand.textContent =
    pet.source === "custom"
      ? `custom pet: ${pet.slug}`
      : `npx petdex install ${pet.slug}`;
  els.openPetdex.href =
    pet.source === "custom"
      ? "https://github.com/crafter-station/petdex"
      : `https://petdex.dev/pets/${encodeURIComponent(pet.slug)}`;
  els.openPetdex.textContent = pet.source === "custom" ? "Format" : "Petdex";

  els.selectedTags.replaceChildren(
    ...pet.tags.slice(0, 8).map((tag) => {
      const span = document.createElement("span");
      span.textContent = tag;
      return span;
    }),
  );

  els.selectedSprite.replaceChildren(
    createSpriteElement(pet, selectedState, { scale: responsiveSpriteScale(), animated: true }),
  );

  els.stateTabs.replaceChildren(
    ...pet.states.map((item) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `state-tab ${item.id === selectedState.id ? "is-active" : ""}`;
      button.textContent = item.label;
      button.addEventListener("click", () => {
        state.selectedStateId = item.id;
        renderSelected();
      });
      return button;
    }),
  );
}

function responsiveSpriteScale() {
  const width = window.innerWidth;
  if (width < 420) return 0.95;
  if (width < 760) return 1.08;
  if (width < 1280) return 1.25;
  return 1.55;
}

function renderGallery() {
  const pets = filteredPets();
  const visible = pets.slice(0, state.visibleLimit);
  els.visibleTotal.textContent = formatCount(visible.length);
  els.customCount.textContent = String(state.customPets.length);

  els.grid.replaceChildren(...visible.map(createPetCard));
  els.loadMore.hidden = visible.length >= pets.length;

  if (pets.length === 0) {
    setGalleryStatus("No pets match");
  } else {
    setGalleryStatus(`${formatCount(pets.length)} match${pets.length === 1 ? "" : "es"}`);
  }
}

function filteredPets() {
  const combined = [...state.customPets, ...state.petdexPets];
  return combined.filter((pet) => {
    if (state.filterSource !== "all" && pet.source !== state.filterSource) {
      return false;
    }
    if (!state.query) return true;
    const haystack = [
      pet.displayName,
      pet.slug,
      pet.kind,
      pet.submittedBy,
      pet.description,
      ...pet.tags,
    ]
      .join(" ")
      .toLowerCase();
    return haystack.includes(state.query);
  });
}

function createPetCard(pet) {
  const fragment = els.cardTemplate.content.cloneNode(true);
  const card = fragment.querySelector(".pet-card");
  const button = fragment.querySelector(".pet-card-button");
  const spriteSlot = fragment.querySelector(".pet-card-sprite");
  const name = fragment.querySelector("strong");
  const meta = fragment.querySelector("small");
  const cardState = pet.states[hashString(pet.slug) % pet.states.length];

  name.textContent = pet.displayName;
  meta.textContent = pet.source === "custom" ? pet.slug : pet.submittedBy || pet.kind;
  spriteSlot.append(createSpriteElement(pet, cardState, { scale: 0.44, animated: false }));
  button.classList.toggle("is-selected", state.selected?.slug === pet.slug);
  button.addEventListener("click", () => selectPet(pet));

  if (pet.source === "custom") {
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "pet-remove";
    remove.title = "Remove custom pet";
    remove.textContent = "x";
    remove.addEventListener("click", async (event) => {
      event.stopPropagation();
      await deleteCustomPet(pet.slug);
    });
    card.append(remove);
  }

  return fragment;
}

function createSpriteElement(pet, stateDef, options) {
  const frameWidth = pet.frameWidth || 192;
  const frameHeight = pet.frameHeight || 208;
  const frame = document.createElement("span");
  frame.className = "pet-sprite-frame";
  frame.setAttribute("role", "img");
  frame.setAttribute("aria-label", `${pet.displayName} ${stateDef.label}`);
  frame.style.setProperty("--frame-w", `${frameWidth}px`);
  frame.style.setProperty("--frame-h", `${frameHeight}px`);
  frame.style.setProperty("--sheet-w", `${frameWidth * 8}px`);
  frame.style.setProperty("--sheet-h", `${frameHeight * 9}px`);
  frame.style.setProperty("--scale", String(options.scale));

  const sprite = document.createElement("span");
  sprite.className = options.animated ? "pet-sprite" : "pet-sprite-static";
  sprite.style.setProperty("--sprite-url", `url("${cssEscapeUrl(pet.spritesheetUrl)}")`);
  sprite.style.setProperty("--sprite-y", `-${stateDef.row * frameHeight}px`);
  sprite.style.setProperty("--sprite-end-x", `-${stateDef.frames * frameWidth}px`);
  sprite.style.setProperty("--sprite-frames", String(stateDef.frames));
  sprite.style.setProperty("--sprite-duration", `${stateDef.durationMs}ms`);
  frame.append(sprite);
  return frame;
}

async function importFromFiles(files) {
  if (!files.length) return;
  setImportStatus("Reading package...");

  const petJsonFile = findFile(files, (file) => basename(file).toLowerCase() === "pet.json");
  const spriteFile = findFile(files, (file) => {
    const name = basename(file).toLowerCase();
    return (
      name === "spritesheet.webp" ||
      name === "spritesheet.png" ||
      name === "sprite.webp" ||
      name === "sprite.png"
    );
  });

  if (!petJsonFile || !spriteFile) {
    setImportStatus("Need pet.json and spritesheet.webp/png");
    return;
  }

  let previewUrl = "";
  try {
    const petJson = JSON.parse(await petJsonFile.text());
    const slugSeed =
      cleanString(petJson.id || petJson.slug) ||
      stripExtension(basename(petJsonFile.webkitRelativePath || petJsonFile.name));
    const dimensions = await measureImageFile(spriteFile);
    previewUrl = URL.createObjectURL(spriteFile);
    const pet = normalizePet({
      source: "custom",
      slug: slugify(slugSeed || petJson.displayName || "custom-pet"),
      displayName: petJson.displayName || petJson.name || slugSeed,
      description: petJson.description,
      kind: petJson.kind || "custom",
      tags: petJson.tags || petJson.vibes,
      spritesheetUrl: previewUrl,
      petJson,
      frameWidth: positiveNumber(petJson.frameWidth) || Math.round(dimensions.width / 8),
      frameHeight: positiveNumber(petJson.frameHeight) || Math.round(dimensions.height / 9),
      addedAt: Date.now(),
    });

    if (!pet) throw new Error("Could not read pet metadata");
    await saveCustomPet(pet, spriteFile, petJson);
    setImportStatus(`Added ${pet.displayName}`);
    await loadCustomPets();
    selectPet(state.customPets.find((item) => item.slug === pet.slug) || pet);
  } catch (error) {
    setImportStatus(error.message || "Could not import package");
  } finally {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
  }
}

async function importFromUrls(petJsonUrl, spriteUrl) {
  if (!petJsonUrl || !spriteUrl) {
    setImportStatus("Need both URLs");
    return;
  }
  setImportStatus("Fetching URLs...");

  try {
    const jsonResponse = await fetch(petJsonUrl);
    if (!jsonResponse.ok) throw new Error(`pet.json returned ${jsonResponse.status}`);

    const petJson = await jsonResponse.json();
    let dimensions = { width: 1536, height: 1872 };
    try {
      dimensions = await measureImageUrl(spriteUrl);
    } catch {
      dimensions = { width: 1536, height: 1872 };
    }
    const slugSeed = cleanString(petJson.id || petJson.slug || petJson.displayName);
    const pet = normalizePet({
      source: "custom",
      slug: slugify(slugSeed || `custom-${Date.now()}`),
      displayName: petJson.displayName || petJson.name || slugSeed,
      description: petJson.description,
      kind: petJson.kind || "custom",
      tags: petJson.tags || petJson.vibes,
      spritesheetUrl: spriteUrl,
      petJson,
      frameWidth: positiveNumber(petJson.frameWidth) || Math.round(dimensions.width / 8),
      frameHeight: positiveNumber(petJson.frameHeight) || Math.round(dimensions.height / 9),
      addedAt: Date.now(),
    });

    if (!pet) throw new Error("Could not read pet metadata");
    await saveCustomPet(pet, null, petJson, { persistedSpriteUrl: spriteUrl });
    els.petJsonUrl.value = "";
    els.spriteUrl.value = "";
    setImportStatus(`Added ${pet.displayName}`);
    await loadCustomPets();
    selectPet(state.customPets.find((item) => item.slug === pet.slug) || pet);
  } catch (error) {
    setImportStatus(error.message || "Could not fetch URLs");
  }
}

async function loadCustomPets() {
  for (const url of state.activeObjectUrls) URL.revokeObjectURL(url);
  state.activeObjectUrls.clear();

  const db = await openCustomDb();
  const records = await readAll(db);
  state.customPets = records
    .sort((a, b) => b.addedAt - a.addedAt)
    .map((record) => {
      const spritesheetUrl = record.spriteBlob
        ? URL.createObjectURL(record.spriteBlob)
        : record.meta.spritesheetUrl;
      if (record.spriteBlob) state.activeObjectUrls.add(spritesheetUrl);
      return normalizePet({
        ...record.meta,
        source: "custom",
        spritesheetUrl,
        petJson: record.petJson,
      });
    })
    .filter(Boolean);

  els.customCount.textContent = String(state.customPets.length);
}

async function saveCustomPet(pet, spriteBlob, petJson, options = {}) {
  const db = await openCustomDb();
  await putRecord(db, {
    slug: pet.slug,
    addedAt: pet.addedAt,
    meta: {
      slug: pet.slug,
      displayName: pet.displayName,
      description: pet.description,
      kind: pet.kind,
      submittedBy: pet.submittedBy,
      tags: pet.tags,
      spritesheetUrl: options.persistedSpriteUrl || "",
      frameWidth: pet.frameWidth,
      frameHeight: pet.frameHeight,
      states: pet.states,
    },
    petJson,
    spriteBlob,
  });
}

async function deleteCustomPet(slug) {
  const db = await openCustomDb();
  await deleteRecord(db, slug);
  await loadCustomPets();
  if (state.selected?.slug === slug) {
    state.selected = state.petdexPets.find((pet) => pet.slug === "boba") || state.petdexPets[0] || null;
    if (state.selected) await selectPet(state.selected);
  }
  renderGallery();
}

function normalizeStates(petJson) {
  const custom = petJson?.states || petJson?.animations || {};
  return DEFAULT_STATES.map((fallback) => {
    const found = findStateConfig(custom, fallback);
    return {
      id: fallback.id,
      label: cleanString(found?.label || found?.name) || fallback.label,
      row: positiveNumber(found?.row) ?? fallback.row,
      frames:
        positiveNumber(found?.frames || found?.frameCount || found?.columns) ??
        fallback.frames,
      durationMs:
        positiveNumber(found?.durationMs || found?.duration || found?.loopMs) ??
        fallback.durationMs,
      aliases: fallback.aliases,
    };
  });
}

function findStateConfig(custom, fallback) {
  if (!custom || typeof custom !== "object") return null;
  for (const key of fallback.aliases) {
    if (custom[key] && typeof custom[key] === "object") return custom[key];
  }
  return null;
}

function openCustomDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(CUSTOM_DB, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(CUSTOM_STORE)) {
        db.createObjectStore(CUSTOM_STORE, { keyPath: "slug" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function readAll(db) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(CUSTOM_STORE, "readonly");
    const request = tx.objectStore(CUSTOM_STORE).getAll();
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function putRecord(db, record) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(CUSTOM_STORE, "readwrite");
    tx.objectStore(CUSTOM_STORE).put(record);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

function deleteRecord(db, slug) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(CUSTOM_STORE, "readwrite");
    tx.objectStore(CUSTOM_STORE).delete(slug);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

function findFile(files, predicate) {
  return files.find(predicate) || null;
}

function basename(file) {
  const path = file.webkitRelativePath || file.name || "";
  return path.split("/").pop() || path;
}

function stripExtension(name) {
  return name.replace(/\.[^.]+$/, "");
}

function measureImageFile(file) {
  const url = URL.createObjectURL(file);
  return measureImageUrl(url).finally(() => URL.revokeObjectURL(url));
}

function measureImageUrl(url) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => {
      resolve({ width: image.naturalWidth, height: image.naturalHeight });
    };
    image.onerror = () => reject(new Error("Spritesheet could not be read"));
    image.src = url;
  });
}

function absolutizeAsset(value, base) {
  if (/^https?:\/\//i.test(value)) return value;
  return `${trimSlash(base)}/${String(value).replace(/^\/+/, "")}`;
}

function trimSlash(value) {
  return String(value).replace(/\/+$/, "");
}

function cleanString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function listStrings(value) {
  if (!Array.isArray(value)) return [];
  return value.map(cleanString).filter(Boolean).slice(0, 16);
}

function positiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function slugify(value) {
  const slug = String(value)
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
  return slug || `custom-${Date.now()}`;
}

function formatCount(value) {
  return new Intl.NumberFormat("en-US").format(value);
}

function hashString(value) {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 31 + value.charCodeAt(index)) >>> 0;
  }
  return hash;
}

function cssEscapeUrl(value) {
  return String(value).replace(/"/g, '\\"');
}

function setGalleryStatus(message) {
  els.galleryStatus.textContent = message;
}

function setImportStatus(message) {
  els.importStatus.textContent = message;
}

function flashButton(button, text) {
  const original = button.textContent;
  button.textContent = text;
  setTimeout(() => {
    button.textContent = original;
  }, 1200);
}

window.addEventListener("resize", () => {
  if (state.selected) renderSelected();
});
