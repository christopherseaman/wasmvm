# wasmvm

iPad-local Linux dev environment. CheerpX (WASM x86) runs inside WKWebView; the
iOS Swift wrapper provides localhost network egress and a 9P2000.L file bridge
to a user-picked iOS folder. No remote backend, no Tailscale, no jailbreak.

## Status

**Research project. MVP code complete; never run end-to-end on a real iPad yet.**

What's done:
- Swift package (Core / Net / NineP / Server / App) — 188 tests passing
- Browser harness (vendored CheerpX 1.2.11 + transport shim + 9P shim) — 81 tests passing
- Disk image build pipeline (Docker → i386 Debian + LazyVim)
- Architectural and implementation decisions documented

What's *not* done (next person picks this up on a macOS dev box):
- Run `swift test` on macOS to verify Telegraph-dependent server tests
- Build the disk image (`tools/build-disk.sh` — needs Docker)
- Create the Xcode app project, wire SwiftPM dep, sign, run on iPad Simulator
- Walk the 11 verification gates (`crossOriginIsolated === true`, CheerpX boots,
  `apt install`, `vim /mnt/host/test.txt`, `git commit`, app-relaunch persistence)

## Architecture in 30 seconds

```
iOS app process
├── Telegraph HTTP+WS server, 127.0.0.1:<ephemeral>
│     GET /index.html, /vendor/cheerpx/*, /disk/base.ext2 (Range, COOP/COEP/CORP)
│     WS  /net  → NetBridge   (raw-socket-over-WS → POSIX sockets)
│     WS  /9p   → NinePServer (9P2000.L → security-scoped FileHandle)
└── WKWebView → http://127.0.0.1:<port>/index.html
      └── bootstrap.js loads vendored CheerpX, wires both WS endpoints,
          mounts root ext2 (over IDB overlay) + /home (over IDB overlay)
          + /mnt/host (9P shim using dir-mount), spawns bash in xterm.js
```

Full spec: [`spec/README.md`](spec/README.md) (architecture, ops, milestones).

## Repo layout

| Path | What |
|---|---|
| `spec/` | Original architectural specification (8 numbered docs + reference Swift sketches) |
| `Sources/`, `Tests/`, `Package.swift` | SwiftPM package — Core, Net, NineP, Server, App + tests |
| `App/` | iOS app shim — `@main`, `Info.plist` (links the SwiftPM library) |
| `webvm-harness/` | Browser side — `index.html`, `bootstrap.js`, transport + 9P shims, vendored CheerpX, Vitest + Playwright tests |
| `tools/` | Disk image build (`Dockerfile.disk`, `build-disk.sh`, `disk-smoke.sh`, `vendor-cheerpx.sh`) |
| `DECISIONS.md` | Decisions log — why CheerpX, why Telegraph, why localhost HTTP, etc. |
| `INVESTIGATION-CHEERPX-API.md` | W4 findings — how we discovered CheerpX's `networkInterface` injection point (no fork needed) |
| `CLAUDE.md` | Guidance for Claude Code agents working in this repo |
| `tools/README.md` | Disk image pipeline docs |

## First-time setup (after cloning)

CheerpX is not vendored into git (its licence restricts redistribution; see
the [License](#license) section). Devs fetch it directly from upstream:

```bash
tools/vendor-cheerpx.sh                     # ~24 MiB, pinned to 1.2.11 by default
cd webvm-harness && npm install
swift package resolve                       # populates SwiftPM dependencies
```

If you skip the vendoring step, `npm run test:e2e` aborts with a clear
fix-it message, and the in-browser harness shows a setup overlay instead
of failing silently.

## Build and test

### Swift (requires macOS for the Telegraph-dependent targets)

```bash
swift test --filter WasmVMCoreTests        # 59 tests, runs on Linux too
swift test --filter WasmVMNetTests         # 16 tests, runs on Linux too
swift test --filter WasmVMNinePTests       # 42 tests, runs on Linux too
swift test --filter WasmVMServerTests      # 12 tests, macOS only (CocoaAsyncSocket)
```

`WasmVMCore`/`Net`/`NineP` are platform-portable (use POSIX sockets via Darwin/Glibc).
`WasmVMServer` pulls Telegraph → CocoaAsyncSocket which is Apple-only.

### Browser harness

```bash
cd webvm-harness
npm install
npx vitest run                              # 81 tests
npx playwright install chromium
npx playwright test                         # E2E (CheerpX boot + crossOriginIsolated)
```

### Disk image

```bash
tools/build-disk.sh                         # → out/base.ext2 (+ .sha256)
tools/build-home-empty.sh                   # → out/home-empty.ext2
tools/disk-smoke.sh                         # asserts contents
```

Requires Docker with `linux/386` platform support. See [`tools/README.md`](tools/README.md).

### Re-vendor CheerpX

```bash
tools/vendor-cheerpx.sh                     # default: pinned 1.2.11
tools/vendor-cheerpx.sh 1.2.12              # or a specific version
CHEERPX_VERSION=1.2.12 tools/vendor-cheerpx.sh
```

Recursively walks dynamic-import string literals, downloads from
`cxrtnc.leaningtech.com/<version>/`, rewrites absolute URLs to relative paths,
writes sha256 manifest at `webvm-harness/vendor/cheerpx/CHEERPX_VERSION.md`.

The pinned version lives in `tools/vendor-cheerpx.sh` (search for
`PINNED_VERSION=`). Bump deliberately — the harness/shims have been tested
against the pinned version.

## Run on iPad (manual steps)

1. **macOS** with Xcode 15+ installed
2. `swift test` (above) green
3. `tools/build-disk.sh` produces `out/base.ext2` (~500 MiB target)
4. `cd webvm-harness && npm install` populates `node_modules/`
5. New Xcode iOS App project, deployment target iOS 17.0
6. Add this repo as a local SwiftPM dependency, link `WasmVMApp` library
7. Add `App/WasmVMApp.swift` and `App/Info.plist` to the app target
8. Add `webvm-harness/` to the app bundle as a **folder reference** (blue
   folder in Xcode — preserves `vendor/cheerpx/...` subpaths)
9. Add `out/base.ext2` and `out/home-empty.ext2` to the app bundle
10. Configure code signing (personal team is fine)
11. Run on iPad device or iPad Simulator (iPadOS 17+)
12. Tap "Pick Shared Folder" to grant the 9P mount

Verification gates (the bar for "MVP done"):
- `crossOriginIsolated === true` confirmed in Safari Web Inspector
- Boots to `bash` prompt at `/home/user`
- `curl https://example.com` succeeds
- `apt update && apt install -y fortune` succeeds
- `vim /mnt/host/test.txt` opens, edits, saves to picked iOS folder
- `git init /mnt/host/repo && git add . && git commit -m x` succeeds
- App relaunch resumes with the same picked folder still mounted

## Documentation map

| Document | Use when |
|---|---|
| [`spec/README.md`](spec/README.md) | Understanding the project's *why* and goals |
| [`spec/01-architecture.md`](spec/01-architecture.md) | Understanding the system architecture |
| [`spec/03-net-bridge.md`](spec/03-net-bridge.md) | Working on NetBridge / wire format |
| [`spec/04-ninep-server.md`](spec/04-ninep-server.md) | Working on NinePServer / 9P |
| [`spec/05-storage.md`](spec/05-storage.md) | Working on disk images / mounts |
| [`spec/07-milestones.md`](spec/07-milestones.md) | Understanding scope (M0–M6) |
| [`DECISIONS.md`](DECISIONS.md) | Understanding *why* a particular implementation choice was made |
| [`INVESTIGATION-CHEERPX-API.md`](INVESTIGATION-CHEERPX-API.md) | Understanding the CheerpX integration approach |
| [`tools/README.md`](tools/README.md) | Building disk images |
| [`CLAUDE.md`](CLAUDE.md) | If you're a Claude agent picking this up |

## License

This project's own code is **MIT** ([`LICENSE`](LICENSE)).

Bundled and fetched third-party software (CheerpX, LazyVim, Debian packages,
Telegraph, xterm.js, idb) keep their own licenses. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the inventory and
relevant scope notes — in particular CheerpX's Community/Commercial tier
and the §2.1(i) redistribution clause that drove our "fetch, don't
commit" policy ([`DECISIONS.md`](DECISIONS.md) D1).
