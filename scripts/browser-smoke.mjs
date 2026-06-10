import { createReadStream } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize } from "node:path";
import { deflateSync } from "node:zlib";
import { spawn } from "node:child_process";
import { once } from "node:events";
import os from "node:os";

const root = new URL("../", import.meta.url);
const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const screenshotPath = "/tmp/codex-pets-browser-smoke.png";

const types = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".webp", "image/webp"],
  [".png", "image/png"],
]);

const server = createStaticServer();
await listen(server, 0);
const port = server.address().port;
const profileDir = await mkdir(join(os.tmpdir(), `codex-pets-chrome-${process.pid}`), {
  recursive: true,
}).then(() => join(os.tmpdir(), `codex-pets-chrome-${process.pid}`));

let chrome;
try {
  const pageURL = `http://127.0.0.1:${port}/index.html`;
  chrome = await launchChrome(pageURL, profileDir);
  const page = await waitForPage(chrome.port, pageURL);
  const cdp = await connectCDP(page.webSocketDebuggerUrl);
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");
  await waitForReadyState(cdp);

  const spriteURL = makePNGAtlasDataURL(8, 8);
  const result = await evaluateSmoke(cdp, spriteURL);
  assertSmokeResult(result);

  const screenshot = await cdp.send("Page.captureScreenshot", { format: "png" });
  if (!screenshot.data || screenshot.data.length < 1000) {
    throw new Error("browser smoke screenshot was unexpectedly small");
  }
  await writeFile(screenshotPath, Buffer.from(screenshot.data, "base64"));
  cdp.close();
  console.log(`browser smoke passed (${screenshotPath})`);
} finally {
  if (chrome) await stopChrome(chrome.process);
  server.close();
  await rm(profileDir, { recursive: true, force: true });
}

function createStaticServer() {
  return createServer((request, response) => {
    const url = new URL(request.url || "/", `http://${request.headers.host}`);
    const cleanPath = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, "");
    const requested = cleanPath === "/" ? "index.html" : cleanPath.replace(/^[/\\]+/, "");
    const filePath = join(root.pathname, requested);

    response.setHeader("Cache-Control", "no-store");
    response.setHeader("Content-Type", types.get(extname(filePath)) || "application/octet-stream");
    createReadStream(filePath)
      .on("error", () => {
        response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
        response.end("Not found");
      })
      .pipe(response);
  });
}

function listen(server, port) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
}

async function launchChrome(pageURL, profileDir) {
  const chrome = spawn(
    chromePath,
    [
      "--headless=new",
      "--disable-gpu",
      "--no-first-run",
      "--no-default-browser-check",
      "--remote-debugging-port=0",
      `--user-data-dir=${profileDir}`,
      pageURL,
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );

  let stderr = "";
  const portPromise = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`Chrome did not expose DevTools:\n${stderr}`)), 10_000);
    chrome.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
      const match = stderr.match(/DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//);
      if (match) {
        clearTimeout(timeout);
        resolve(Number(match[1]));
      }
    });
    chrome.once("exit", (code, signal) => {
      clearTimeout(timeout);
      reject(new Error(`Chrome exited before DevTools was ready: ${code ?? signal}\n${stderr}`));
    });
  });

  return { process: chrome, port: await portPromise };
}

async function waitForPage(port, pageURL) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const pages = await fetch(`http://127.0.0.1:${port}/json/list`).then((response) => response.json());
    const page = pages.find((item) => item.type === "page" && item.url === pageURL);
    if (page?.webSocketDebuggerUrl) return page;
    await delay(100);
  }
  throw new Error("Chrome page target was not found");
}

async function connectCDP(webSocketURL) {
  const socket = new WebSocket(webSocketURL);
  await once(socket, "open");

  let nextID = 0;
  const pending = new Map();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (!message.id) return;
    const callbacks = pending.get(message.id);
    if (!callbacks) return;
    pending.delete(message.id);
    if (message.error) callbacks.reject(new Error(message.error.message));
    else callbacks.resolve(message.result || {});
  });
  return {
    send(method, params = {}) {
      const id = ++nextID;
      socket.send(JSON.stringify({ id, method, params }));
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
      });
    },
    close() {
      socket.close();
    },
  };
}

async function waitForReadyState(cdp) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const result = await cdp.send("Runtime.evaluate", {
      expression: "document.readyState",
      returnByValue: true,
    });
    if (result.result?.value === "complete") return;
    await delay(100);
  }
  throw new Error("browser page did not finish loading");
}

async function evaluateSmoke(cdp, spriteURL) {
  const source = `
    (async (spriteURL) => {
      const nextFrame = () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      window.__nativeMessages = [];
      window.CodexPetsNative = {
        postMessage(payload) {
          window.__nativeMessages.push(payload);
        }
      };
      window.dispatchEvent(new CustomEvent("codex-pets-native-ready"));
      window.dispatchEvent(new CustomEvent("codex-pets-native-installed-pets", {
        detail: {
          pets: [{
            source: "installed",
            slug: "smoke-pet",
            displayName: "Smoke Pet",
            description: "Installed smoke pet",
            kind: "fox",
            submittedBy: "Imported",
            tags: ["smoke"],
            spritesheetUrl: spriteURL,
            nativePetId: "native-smoke-pet",
            frameWidth: 8,
            frameHeight: 8,
            canUninstall: true
          }]
        }
      }));
      window.dispatchEvent(new CustomEvent("codex-pets-native-daemon-snapshot", {
        detail: {
          attention: "approval_required",
          sessions: [{
            id: "session-1",
            cwd: "/repo",
            title: "Repo",
            status: "running",
            safeSummary: "running tests"
          }],
          pendingApprovals: [{
            id: "approval-1",
            sessionId: "session-1",
            toolName: "bash",
            commandSummary: "git push origin main",
            risk: "medium",
            state: "pending"
          }]
        }
      }));
      await nextFrame();

      document.querySelector('[data-source="installed"]').click();
      await nextFrame();
      document.querySelector(".pet-card-button").click();
      await nextFrame();

      const nativeImport = document.querySelector("#native-import");
      const importButtonEnabledBeforeClick = !nativeImport.disabled && nativeImport.textContent.trim() === "Use Pet";
      nativeImport.click();
      await nextFrame();

      const approve = [...document.querySelectorAll(".approval-row button")]
        .find((button) => button.textContent.trim() === "Approve");
      approve.click();
      await nextFrame();

      const remove = document.querySelector(".pet-remove");
      remove.click();
      await nextFrame();

      const selectedFrame = document.querySelector("#selected-sprite .pet-sprite-frame");
      const selectedSprite = document.querySelector("#selected-sprite .pet-sprite");
      const cardSprite = document.querySelector(".pet-card-sprite .pet-sprite-static");
      const selectedStyle = getComputedStyle(selectedSprite);

      return {
        nativeShell: document.documentElement.classList.contains("native-shell"),
        installedTabDisplay: getComputedStyle(document.querySelector('[data-source="installed"]')).display,
        daemonPanelDisplay: getComputedStyle(document.querySelector("#daemon-panel")).display,
        cardCount: document.querySelectorAll(".pet-card").length,
        selectedSource: document.querySelector("#selected-source").textContent.trim(),
        selectedName: document.querySelector("#selected-name").textContent.trim(),
        nativeImportText: nativeImport.textContent.trim(),
        importButtonEnabledBeforeClick,
        approvalCount: document.querySelector("#approval-count").textContent.trim(),
        approvalText: document.querySelector(".approval-row")?.textContent || "",
        sessionText: document.querySelector(".session-row")?.textContent || "",
        selectedBackground: selectedStyle.backgroundImage,
        selectedSpriteY: selectedSprite.style.getPropertyValue("--sprite-y"),
        selectedSpriteFrames: selectedSprite.style.getPropertyValue("--sprite-frames"),
        selectedFrameWidth: selectedFrame.style.getPropertyValue("--frame-w"),
        selectedFrameHeight: selectedFrame.style.getPropertyValue("--frame-h"),
        cardBackground: getComputedStyle(cardSprite).backgroundImage,
        messages: window.__nativeMessages,
      };
    })(${JSON.stringify(spriteURL)})
  `;
  const result = await cdp.send("Runtime.evaluate", {
    expression: source,
    awaitPromise: true,
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || "browser smoke evaluation failed");
  }
  return result.result.value;
}

function assertSmokeResult(result) {
  const failures = [];
  if (!result.nativeShell) failures.push("native-shell class was not enabled");
  if (result.installedTabDisplay === "none") failures.push("installed source tab is hidden");
  if (result.daemonPanelDisplay === "none") failures.push("daemon panel is hidden");
  if (result.cardCount !== 1) failures.push(`installed card count = ${result.cardCount}`);
  if (result.selectedSource !== "Installed") failures.push(`selected source = ${result.selectedSource}`);
  if (result.selectedName !== "Smoke Pet") failures.push(`selected pet = ${result.selectedName}`);
  if (!result.importButtonEnabledBeforeClick) failures.push("Use Pet button was not enabled for installed pet");
  if (result.approvalCount !== "1") failures.push(`approval count = ${result.approvalCount}`);
  if (!result.approvalText.includes("git push origin main")) failures.push("approval row did not render safe command summary");
  if (!result.sessionText.includes("running tests")) failures.push("session row did not render safe summary");
  if (!result.selectedBackground.includes("data:image/png")) failures.push("selected sprite did not use data PNG spritesheet");
  if (!result.cardBackground.includes("data:image/png")) failures.push("card sprite did not use data PNG spritesheet");
  if (!["0px", "-0px"].includes(result.selectedSpriteY)) failures.push(`selected sprite y = ${result.selectedSpriteY}`);
  if (result.selectedSpriteFrames !== "6") failures.push(`selected sprite frames = ${result.selectedSpriteFrames}`);
  if (result.selectedFrameWidth !== "8px" || result.selectedFrameHeight !== "8px") {
    failures.push(`selected frame size = ${result.selectedFrameWidth} x ${result.selectedFrameHeight}`);
  }
  const actions = result.messages.map((message) => message.action);
  for (const action of ["listInstalledPets", "getDaemonSnapshot", "selectInstalledPet", "approvalDecision", "uninstallInstalledPet"]) {
    if (!actions.includes(action)) failures.push(`missing native message ${action}`);
  }
  const approval = result.messages.find((message) => message.action === "approvalDecision");
  if (approval?.decision !== "approved" || approval?.approvalId !== "approval-1") {
    failures.push(`bad approval decision payload ${JSON.stringify(approval)}`);
  }
  if (failures.length > 0) {
    throw new Error(`browser smoke failed:\n- ${failures.join("\n- ")}`);
  }
}

async function stopChrome(chrome) {
  if (chrome.exitCode !== null) return;
  chrome.kill("SIGTERM");
  await Promise.race([once(chrome, "exit"), delay(1000)]);
  if (chrome.exitCode === null) chrome.kill("SIGKILL");
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function makePNGAtlasDataURL(frameWidth, frameHeight) {
  const width = frameWidth * 8;
  const height = frameHeight * 9;
  const stride = width * 4 + 1;
  const raw = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y += 1) {
    const row = Math.floor(y / frameHeight);
    raw[y * stride] = 0;
    for (let x = 0; x < width; x += 1) {
      const col = Math.floor(x / frameWidth);
      const offset = y * stride + 1 + x * 4;
      raw[offset] = row * 24;
      raw[offset + 1] = col * 28;
      raw[offset + 2] = 180;
      raw[offset + 3] = 255;
    }
  }
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", Buffer.concat([uint32(width), uint32(height), Buffer.from([8, 6, 0, 0, 0])])),
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
  return `data:image/png;base64,${png.toString("base64")}`;
}

function pngChunk(type, data) {
  const name = Buffer.from(type);
  return Buffer.concat([uint32(data.length), name, data, uint32(crc32(Buffer.concat([name, data])))]);
}

function uint32(value) {
  const out = Buffer.alloc(4);
  out.writeUInt32BE(value >>> 0);
  return out;
}

function crc32(data) {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = crc & 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}
