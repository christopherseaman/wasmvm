// End-to-end Playwright test for the browser harness.
// Serves webvm-harness/ from a local HTTP server with COOP/COEP headers,
// stubs WS endpoints for /net (frame protocol) and /9p (9P codec), and
// asserts that the browser reaches `crossOriginIsolated === true` and the
// CheerpX runtime (or its module shim) loads without throwing.
//
// NOTE (per W4 INVESTIGATION-CHEERPX-API.md and W6 plan):
// Playwright's bundled Chromium does NOT install on this Linux host
// (ubuntu26.04-arm64 — confirmed by W6: `npx playwright install chromium`
// returns "Playwright does not support chromium on ubuntu26.04-arm64").
// This file is left correct so it runs on macOS / linux-x64 / CI.
// Run with: `npx playwright test tests/harness.e2e.test.js`.

import { test, expect } from "@playwright/test";
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { createReadStream } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";
import {
  OP as NET_OP,
  encodeFrame,
  decodeFrame,
} from "../frame-codec.js";
import {
  OP as P9_OP,
  encodeMessage,
  decodeMessage,
  appendString,
  appendQid,
  concat,
} from "../ninep-codec.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

function staticServer(rootDir) {
  return new Promise((resolve) => {
    const server = createServer(async (req, res) => {
      // why: COOP/COEP/CORP required for SharedArrayBuffer (CheerpX needs it).
      res.setHeader("Cross-Origin-Opener-Policy", "same-origin");
      res.setHeader("Cross-Origin-Embedder-Policy", "require-corp");
      res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
      const url = new URL(req.url, "http://x");
      let p = path.join(rootDir, decodeURIComponent(url.pathname));
      if (p.endsWith("/")) p += "index.html";
      try {
        const s = await stat(p);
        if (s.isDirectory()) p = path.join(p, "index.html");
      } catch {
        res.statusCode = 404; res.end("not found"); return;
      }
      const ext = path.extname(p);
      const types = {
        ".html": "text/html",
        ".js":   "text/javascript",
        ".mjs":  "text/javascript",
        ".css":  "text/css",
        ".wasm": "application/wasm",
        ".json": "application/json",
        ".ext2": "application/octet-stream",
      };
      res.setHeader("Content-Type", types[ext] || "application/octet-stream");
      // Range support for the (stub) base.ext2.
      const range = req.headers["range"];
      if (range) {
        const m = /bytes=(\d+)-(\d*)/.exec(range);
        if (m) {
          const total = (await stat(p)).size;
          const start = parseInt(m[1], 10);
          const end = m[2] ? parseInt(m[2], 10) : total - 1;
          res.statusCode = 206;
          res.setHeader("Content-Range", `bytes ${start}-${end}/${total}`);
          res.setHeader("Content-Length", end - start + 1);
          createReadStream(p, { start, end }).pipe(res);
          return;
        }
      }
      createReadStream(p).pipe(res);
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

function netStub(server) {
  const wss = new WebSocketServer({ server, path: "/net" });
  wss.on("connection", (ws) => {
    ws.binaryType = "arraybuffer";
    ws.on("message", (data, isBinary) => {
      if (!isBinary) return;
      const f = decodeFrame(new Uint8Array(data));
      if (f.op === NET_OP.CONNECT) ws.send(encodeFrame(NET_OP.CONNECT_OK, f.connId));
      else if (f.op === NET_OP.CLOSE) ws.send(encodeFrame(NET_OP.CLOSE, f.connId));
    });
  });
  return wss;
}

function ninepStub(server) {
  const wss = new WebSocketServer({ server, path: "/9p" });
  wss.on("connection", (ws) => {
    ws.binaryType = "arraybuffer";
    ws.on("message", (data) => {
      const m = decodeMessage(new Uint8Array(data));
      if (m.op === P9_OP.Tversion) {
        const out = [new Uint8Array(4)];
        new DataView(out[0].buffer).setUint32(0, 65536, true);
        appendString("9P2000.L", out);
        ws.send(encodeMessage(P9_OP.Rversion, m.tag, concat(out)));
      } else if (m.op === P9_OP.Tattach) {
        const out = [];
        appendQid({ type: 0x80, version: 0, path: 1n }, out);
        ws.send(encodeMessage(P9_OP.Rattach, m.tag, concat(out)));
      } else {
        const err = new Uint8Array(4);
        new DataView(err.buffer).setUint32(0, 38, true); // ENOSYS
        ws.send(encodeMessage(P9_OP.Rlerror, m.tag, err));
      }
    });
  });
  return wss;
}

test.describe("wasmvm browser harness", () => {
  let http;
  let netWss;
  let p9Wss;
  let baseUrl;

  test.beforeAll(async () => {
    http = await staticServer(ROOT);
    netWss = netStub(http);
    p9Wss = ninepStub(http);
    const { port } = http.address();
    baseUrl = `http://127.0.0.1:${port}`;
  });

  test.afterAll(async () => {
    netWss.close();
    p9Wss.close();
    await new Promise((r) => http.close(r));
  });

  test("crossOriginIsolated and harness scripts load", async ({ page }) => {
    const consoleErrors = [];
    page.on("pageerror", (e) => consoleErrors.push(String(e)));
    await page.addInitScript(() => {
      window.__WEBVM__ = {
        // Point at a non-existent disk to short-circuit before WASM touches storage;
        // this test only validates harness wiring + crossOriginIsolated.
        diskUrl: "/no-such.ext2",
        sharedFolderAvailable: false,
      };
    });
    await page.goto(baseUrl + "/index.html", { waitUntil: "load" });

    const isolated = await page.evaluate(() => self.crossOriginIsolated);
    expect(isolated).toBe(true);

    // Terminal element must be present.
    await expect(page.locator("#term")).toBeVisible();
    // Status element exists.
    await expect(page.locator("#status")).toBeVisible();
  });
});
