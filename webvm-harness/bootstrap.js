// Browser entry. Wires CheerpX to:
//   - the WS transport at ws://<host>/net  (WebVMRawSocketTransport)
//   - the optional 9P shim at ws://<host>/9p (NinePDirDevice, dir-mount)
//   - xterm.js terminal UI
//
// Reads window.__WEBVM__ (config injected by Telegraph's index route, W7).
// Falls back to defaults so this file is testable directly with `python -m http.server`.
//
// CheerpX and xterm are loaded via dynamic import so we can present a
// friendly setup-error overlay if the runtime hasn't been vendored / npm
// hasn't been installed. Static imports would fail at module-load time
// before any of our error handling runs.

import { WebVMRawSocketTransport } from "./webvm-net-transport.js";
import { NinePDirDevice, setBaseClass } from "./webvm-9p-mount.js";

const cfg = Object.assign({
  diskUrl: "./disk/base.ext2",
  netWs: `ws://${location.host}/net`,
  ninePWs: `ws://${location.host}/9p`,
  sharedFolderAvailable: false,
  homeIdb: "wasmvm-home",
  rootIdb: "wasmvm-root",
}, window.__WEBVM__ || {});

const statusEl = document.getElementById("status");
function setStatus(text, state = "boot") {
  if (!statusEl) return;
  statusEl.textContent = text;
  statusEl.dataset.state = state;
}

async function loadDeps() {
  const targets = [
    { name: "@xterm/xterm",          path: "./node_modules/@xterm/xterm/lib/xterm.js",            fix: "cd webvm-harness && npm install" },
    { name: "@xterm/addon-fit",      path: "./node_modules/@xterm/addon-fit/lib/addon-fit.js",    fix: "cd webvm-harness && npm install" },
    { name: "CheerpX runtime",       path: "./vendor/cheerpx/cx.esm.js",                          fix: "tools/vendor-cheerpx.sh   (from repo root)" },
  ];
  const loaded = {};
  const missing = [];
  for (const t of targets) {
    try {
      loaded[t.name] = await import(t.path);
    } catch (err) {
      missing.push({ ...t, error: err && err.message ? err.message : String(err) });
    }
  }
  if (missing.length) {
    showSetupError(missing);
    throw new Error("missing dependencies: " + missing.map(m => m.name).join(", "));
  }
  return {
    Terminal: loaded["@xterm/xterm"].Terminal,
    FitAddon: loaded["@xterm/addon-fit"].FitAddon,
    CX:       loaded["CheerpX runtime"],
  };
}

function showSetupError(missing) {
  setStatus("setup incomplete", "err");
  const target = document.getElementById("term") || document.body;
  // why: replace, don't append — terminal element may have partial state.
  target.innerHTML = `
    <div style="
      font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
      color: #eee; background: #1a1a1a; padding: 2em; max-width: 60em;
      margin: 2em auto; border: 1px solid #444; border-radius: 6px;">
      <h2 style="margin-top:0;color:#f66">Setup incomplete &mdash; some bundles aren't on disk yet</h2>
      <p>The browser couldn't load the following local modules. This usually
      means a one-time install step hasn't been run after cloning.</p>
      <ul>
        ${missing.map(m => `
          <li style="margin:.6em 0">
            <b>${escapeHtml(m.name)}</b> &mdash; expected at <code>${escapeHtml(m.path)}</code><br>
            Fix: <code style="background:#2a2a2a;padding:.1em .4em;border-radius:3px">${escapeHtml(m.fix)}</code>
          </li>`).join("")}
      </ul>
      <p>See <code>README.md</code> &sect;"First-time setup" in the repo for the full sequence.
      Then refresh this page.</p>
      <details style="margin-top:1em;color:#999">
        <summary>Underlying errors</summary>
        <pre style="white-space:pre-wrap">${missing.map(m => `${escapeHtml(m.name)}: ${escapeHtml(m.error)}`).join("\n")}</pre>
      </details>
    </div>`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

async function boot() {
  setStatus("loading deps…");
  const { Terminal, FitAddon, CX } = await loadDeps();

  if (!self.crossOriginIsolated) {
    setStatus("not crossOriginIsolated — refusing to boot CheerpX", "err");
    throw new Error("crossOriginIsolated required (need COOP+COEP headers on same-origin)");
  }

  const term = new Terminal({
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
    fontSize: 13,
    cursorBlink: true,
    convertEol: true,
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById("term"));
  fit.fit();
  window.addEventListener("resize", () => fit.fit());

  // why: the 9P device must extend CheerpX.CheerpOSDevice so dev.this is a
  // valid C++ handle the engine can store; we couldn't import CheerpX at
  // module-load time inside Vitest, so binding happens here.
  if (CX.WebDevice && Object.getPrototypeOf(CX.WebDevice).name) {
    const COSD = Object.getPrototypeOf(CX.WebDevice);
    setBaseClass(COSD);
  }

  setStatus("opening base disk…");
  const baseDevice = await CX.HttpBytesDevice.create(cfg.diskUrl);
  const rootIdb = await CX.IDBDevice.create(cfg.rootIdb);
  const rootOverlay = await CX.OverlayDevice.create(baseDevice, rootIdb);
  const homeIdb = await CX.IDBDevice.create(cfg.homeIdb);
  const homeOverlay = await CX.OverlayDevice.create(baseDevice, homeIdb);

  const mounts = [
    { type: "ext2", path: "/",     dev: rootOverlay },
    { type: "ext2", path: "/home", dev: homeOverlay },
    { type: "devs", path: "/dev",  dev: await CX.DataDevice.create() },
    { type: "proc", path: "/proc", dev: await CX.DataDevice.create() },
  ];

  let nineP = null;
  if (cfg.sharedFolderAvailable) {
    setStatus("opening 9P share…");
    nineP = new NinePDirDevice(cfg.ninePWs);
    await nineP.connect();
    mounts.push({ type: "dir", path: "/mnt/host", dev: nineP });
  }

  setStatus("opening network…");
  const net = new WebVMRawSocketTransport(cfg.netWs);
  // why: don't await up() before Linux.create — CheerpX calls .up() itself
  // during boot. Just construct and pass.

  setStatus("starting CheerpX…");
  const linux = await CX.Linux.create({ mounts, networkInterface: net });

  // Bidirectional console wiring.
  const writeFn = (buffer, _vt) => term.write(buffer);
  const inputCallback = linux.setCustomConsole(writeFn, term.cols, term.rows);
  term.onKey(({ domEvent }) => {
    const code = domEvent.keyCode || domEvent.which;
    inputCallback(code);
  });

  setStatus("ready", "ok");
  await linux.run("/bin/bash", ["--login"], {
    env: ["HOME=/home/user", "TERM=xterm-256color", "USER=user"],
    cwd: "/home/user",
    uid: 1000, gid: 1000,
  });
  setStatus("shell exited", "boot");
}

boot().catch((err) => {
  console.error("[wasmvm] boot failed:", err);
  // showSetupError already rendered for missing-deps case; this branch is
  // for runtime errors after deps loaded.
  if (statusEl?.dataset.state !== "err") {
    setStatus("boot failed: " + (err && err.message ? err.message : String(err)), "err");
  }
});
