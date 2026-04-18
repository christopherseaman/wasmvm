# Decisions Log

This file records architectural and tooling decisions made during MVP development. Each entry: what was decided, when, and *why* (so the next person — or the next Claude session — can judge whether the rationale still holds).

Format: most-recent decisions on top.

---

## 2026-04-17 — Initial MVP planning

### D1. Runtime: CheerpX, fetched-not-committed, never source-forked

**Decision:** Use [CheerpX](https://cheerpx.io) (`@leaningtech/cheerpx@^1.2.x`) as the WASM x86 virtualization runtime. Pin one version (currently `1.2.11`). At first checkout, devs run `tools/vendor-cheerpx.sh` to fetch the runtime ESM, WASM blob, and dynamic-import dependencies into `webvm-harness/vendor/cheerpx/`; the script writes a sha256 manifest. The directory is `.gitignore`'d — **CheerpX bytes are never committed to this repo.** At runtime, the iOS app's Telegraph server serves the (locally-vendored) bytes to the WKWebView from `127.0.0.1`, not from the upstream CDN.

**Why:**
- Alternatives evaluated and rejected:
  - **v86** (BSD): interpreted, ~2–3× slower for optimized code and ~10× slower for general code; no syscall abstraction; raw-disk-image model rather than CheerpX's filesystem-mount model. Wrong shape for a dev environment.
  - **JSLinux** (Bellard): proprietary, redistribution prohibited. Non-starter.
  - **QEMU-WASM** (`ktock/qemu-wasm`): TCI interpreter only upstreamed in QEMU 10.1; TCG (JIT) still WIP. Too immature for MVP. Revisit in 12+ months.
- CheerpX is the only WASM x86 runtime with adequate JIT performance for an MVP.
- Vendoring (vs CDN-loading): required for offline behavior, COEP same-origin requirements, reproducibility, and not depending on Leaning Tech's CDN uptime.

**Why not source-fork:** CheerpX is distributed as minified Cheerp-compiled C++→JS — there is no source repo to fork. The runtime cannot be hand-edited line-by-line. Patches must layer above via a JS shim.

**Why not commit the vendored bytes either:** CheerpX's licence (`webvm-harness/vendor/cheerpx/LICENSE.txt`, §2.1(i)) restricts the licensee from "providing or otherwise making available the Software in whole or in part... in any form to any person other than your employees without prior written consent." Pushing the binaries to a public GitHub repo is, taken literally, in tension with that. §1.2(c) explicitly permits *distribution as part of an application*, but a source repo is not the application. Cleanest fix: don't include the bytes in the repo at all — each licensee fetches them directly from the upstream CDN.

**License:** CheerpX uses a tiered Community/Commercial model. Personal/OSS use (including individuals' "personal projects... open-source projects, public-facing applications" per §1.4(a)) falls under the Community License (free). This MVP is treated as personal research. If commercialization is ever pursued, a Commercial License must be obtained.

### D2. No CheerpX source patches; JS shim layer instead

**Decision:** Spec/06's "fork branch" model is replaced with: pin the upstream artifact, write all CheerpX-side modifications as JS modules that wrap or replace upstream exports.

**Why:** See D1's "Why not source-fork." The minified Cheerp output cannot be rebased across version bumps. A shim layer that consumes CheerpX's documented (and reasonable-effort discovered) public exports is durable across bumps.

**How to apply:** Network transport injection and any 9P client are written as JS modules in `webvm-harness/`. The vendored CheerpX in `vendor/cheerpx/` is treated as immutable bytes (with sha256 verification on each `vendor-cheerpx.sh` run).

### D3. No Tailscale, no WireGuard termination, no NetworkExtension

**Decision:** Networking is provided by a Swift-side raw-socket-over-WebSocket bridge (NetBridge) at `ws://127.0.0.1:<port>/net`. CheerpX's networking is wired to this bridge via a custom transport shim (per D1/D2).

**WireGuard alternative considered:** The user asked whether terminating WireGuard locally (since Tailscale is WireGuard-compatible) would be lighter than swapping CheerpX's network transport.

**Why rejected:** WireGuard termination requires:
- WireGuard cryptography integration (Curve25519, ChaCha20-Poly1305, BLAKE2s) — even with WireGuardKit/wireguard-apple, the integration is non-trivial.
- Faking Tailscale's coordination server (auth, peer discovery, keepalives) — CheerpX's TailscaleNetwork makes control-plane calls that aren't covered by raw WireGuard.
- iOS NetworkExtension entitlement + provisioning profile work for any Apple-blessed WireGuard library.

The transport shim approach (~100 LOC of JS) is genuinely lighter than ~500+ LOC of Swift WireGuard plumbing plus entitlement work. Document and move on.

**Why no Tailscale at all (even as MVP stopgap):** The user confirmed that "networking without Tailscale" is a hard MVP requirement. Tailscale is a stated non-goal of the project (per `spec/README.md`).

### D4. Asset transport: localhost HTTP server, not `webvm://` custom scheme

**Decision:** Run [Telegraph](https://github.com/Building42/Telegraph) (MIT, iOS-compatible HTTP+WS server) on `127.0.0.1:<ephemeral-port>` inside the iOS app. Serve CheerpX assets *and* both WS endpoints from a single origin. WKWebView loads `http://127.0.0.1:<port>/index.html`.

**Why:** WKWebView treats custom URL schemes (like the spec's `webvm://`) as **insecure contexts**. SharedArrayBuffer (which CheerpX requires) is gated on a secure context, even with COOP/COEP headers set. Loopback HTTP *is* a secure context for WebKit. This is the safer pattern.

**Side benefit:** one server, one port, one set of headers — easier to keep COOP/COEP consistent across asset and WS routes, and easier to verify in tests.

**Spec edit needed (post-MVP):** `spec/02-ios-wrapper.md` should be updated to drop `webvm://` and adopt loopback HTTP framing. Out of scope for this MVP work; flagged.

### D5. iOS-side 9P implemented in Swift; CheerpX side likely needs a `dir`-mount shim

**Decision:** The Swift NinePServer (per `spec/04-ninep-server.md`) is in scope as written. The CheerpX side requires investigation (W4).

**Why investigation needed:** The spec assumed CheerpX exposes `9p` as a public mount type. Inspection of `@leaningtech/cheerpx@1.2.11`'s `index.d.ts` shows `MountPointConfiguration.type = "ext2" | "dir" | "devs" | "proc"` — **no `9p`**. The runtime mentions 9P internally but doesn't expose it publicly.

**Decision tree** (W4 deliverable: `INVESTIGATION-CHEERPX-API.md`):
- If `mount: { type: "9p", ... }` is accepted by the runtime despite not being typed: use it, document the undocumented schema.
- Else if a known-good Go 9P-over-WS server can be successfully mounted by CheerpX: same — use it.
- Else: implement 9P client in JS as a `dir`-type mount that proxies VFS operations to our Swift NinePServer over WS. Accept reduced POSIX fidelity (no fsync, possibly no atomic rename); document the limitations explicitly.

### D6. MVP scope = spec milestones M0+M1+M2+M3

**Decision:** MVP delivers booting Linux shell + custom disk image + raw-socket networking + 9P shared folder. Defer:
- M4 (pause/resume hooks) — VM dies on backgrounding; user refreshes.
- M5 (bundled `/mnt/data/` datasets).
- M6 (investigation milestone).
- Reset UI flows.
- LISTEN/ACCEPT, UDP, explicit RESOLVE in NetBridge.
- xattr, locks, symlinks, hardlinks, rename in 9P.

**Why:** These are well-bounded extensions to a working MVP rather than risk areas. The MVP must validate the architectural thesis end-to-end first.

### D7. TDD with real implementations only

**Decision:** No mocks, no fakes, no fallbacks-to-make-tests-pass. Integration tests use real Telegraph, real NWConnection on loopback, real FileHandle on tmpdirs, real WS clients (`URLSessionWebSocketTask` for Swift, Node `ws` for JS). The in-tree Swift 9P client (~300 LOC) used for testing NinePServer is itself a real implementation that reuses the production codec.

**Why:** Per user instruction. Mocks that drift from production behavior invalidate the test. The Swift integration tier runs on macOS host (not iOS Simulator), keeping CI fast.

### D8. Disk image base: Debian bookworm-slim i386

**Decision:** Base ext2 image built from `i386/debian:bookworm-slim` via Docker. Preinstall: neovim, git, curl, python3, build-essential, ripgrep, fd, tmux, sudo, locales, openssh-client, less, bash-completion. Create `user` account with passwordless sudo and UID/GID 1000. LazyVim cloned into `/etc/skel` for first-boot copy.

**Why Debian over Alpine:** matches WebVM convention; broader package availability; glibc compatibility for Python wheels and prebuilt binaries. Alpine is a measured fallback if final IPA size pushes >500 MiB compressed.

**Build:** `tools/Dockerfile.disk` + `tools/build-disk.sh`. Reproducible via `snapshot.debian.org` if/when bit-identical builds are needed.

### D9. Telegraph over SwiftNIO/Vapor/custom NWListener

**Decision:** Use Telegraph for the HTTP+WS server.

**Why:**
- Vapor: server-side framework, overkill for in-app use.
- SwiftNIO + nio-websocket: lower level than needed; more code.
- Manual NWListener (per `spec/code/LocalWSServer.swift`): would need separate HTTP support; can't serve assets and WS on one port without re-implementing HTTP. Telegraph already does it.
- Telegraph is MIT, actively maintained (last commit Jan 2025), iOS-supported, dependencies are stable (CocoaAsyncSocket, HTTPParserC).

### D10. Swift package layout: SwiftPM workspace + thin Xcode app target

**Decision:** Codebase is a SwiftPM package (`Package.swift`). The iOS app target is a thin shim (`App/WasmVMApp.swift`, `App/Info.plist`) that links the SwiftPM library. All non-UI code lives in SwiftPM modules and is testable via `swift test` on macOS.

**Why:** Avoids checking in `.xcodeproj` files; lets `swift test` exercise the bulk of the codebase without an iOS Simulator; cleaner module boundaries.
