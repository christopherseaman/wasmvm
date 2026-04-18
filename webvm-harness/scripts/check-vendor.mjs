#!/usr/bin/env node
// Pretest preflight: verify the vendored CheerpX runtime is on disk.
// Runs as `npm test`'s `pretest` hook; aborts with a clear message and a
// fix-it command if the dev hasn't run tools/vendor-cheerpx.sh yet.
//
// Codec unit tests don't need CheerpX — they exercise pure-JS modules.
// But the harness E2E (Playwright) and any browser-based smoke do.
// We check up-front rather than letting the dev wonder why the harness 404s.

import { access } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const harness = resolve(here, "..");
const sentinel = resolve(harness, "vendor/cheerpx/cx.esm.js");

try {
  await access(sentinel);
} catch {
  process.stderr.write(`
\x1b[31mCheerpX runtime not vendored.\x1b[0m

Expected:  ${sentinel}

This repo deliberately does not vendor CheerpX into git. CheerpX's licence
restricts redistribution, so each developer fetches it directly from the
upstream CDN at first checkout.

Fix (from repo root):

    tools/vendor-cheerpx.sh

That downloads ~24 MiB of bytes into webvm-harness/vendor/cheerpx/. Then
re-run \`npm test\`.

`);
  process.exit(1);
}
