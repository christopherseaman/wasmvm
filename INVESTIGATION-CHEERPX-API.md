# Investigation: CheerpX API surface (W4)

**Pinned version:** `@leaningtech/cheerpx@1.2.11` (latest as of 2026-04-17, published 2026-04-13).
**Vendored under:** `webvm-harness/vendor/cheerpx/` via `tools/vendor-cheerpx.sh`.
**Total bytes vendored:** ~24 MiB (the bulk is `tun/tailscale.wasm` at 18.7 MiB, which we will not actually load).

This document answers the four transport-injection experiments (E1–E4) and the 9P mount viability question. It ends with a Recommendation that gates W6 (the JS harness).

---

## Method

Two complementary approaches:

1. **Static inspection** of the vendored runtime — minified Cheerp-compiled JS still contains C++ class names in mangled symbols (e.g. `__ZN13StreamNetwork9TCPSocketEPN6client6StringEj`), the `cx_esm.js` glue layer is fully readable as a state machine, and `tun/tailscale.wasm` has Go `strings`-visible package names.
2. **Dynamic probing** in Node — `cx.esm.js` cannot fully boot under Node (it depends on `window.location` / `document` / browser ESM dynamic-import resolution), but `tun/direct.js` can be eagerly imported as a normal ES module, exposing the four `*Network` constructors. This let us instantiate `StreamNetwork` / `DirectSocketsNetwork` / `TailscaleNetwork` / `DummyNetwork` and observe their prototype methods, signatures, and return shapes.

All experiments below were run against the real vendored runtime; no mocks. Reproduction steps are inlined.

---

## Public API surface (recap)

The npm package `@leaningtech/cheerpx@1.2.11` ships `index.js` + `index.d.ts`. The TypeScript `.d.ts` declares:

```ts
class Linux {
    static create(opt?: {
        mounts?: MountPointConfiguration[],
        networkInterface?: NetworkInterface,
    }): Promise<Linux>;
    // ...
}
interface MountPointConfiguration {
    type: "ext2" | "dir" | "devs" | "proc";  // <-- no "9p"
    path: string;
    dev: Device;
}
interface NetworkInterface {
    authKey?: string;
    controlUrl?: string;
    loginUrlCb?: (url: string) => void;
    stateUpdateCb?: (state: number) => void;
    netmapUpdateCb?: (map: any) => void;
}
```

`networkInterface` looks Tailscale-shaped because the public contract has historically been "give us a Tailscale config, we'll dial controlplane.tailscale.com." But the runtime accepts more than the typings expose — see E2 below.

---

## E2 — does CheerpX accept a custom transport? **YES.**

This is the highest-value experiment and the one that determines the rest of the plan.

### What we found

Inside `cx_esm.js`, the `Linux.create` function (mangled name `Hz`) implements this branching for the network argument:

```
if (M.hasOwnProperty("networkInterface")) {
    if (M.networkInterface.hasOwnProperty("netmapUpdateCb")) {
        return cX(h, u4(M.networkInterface));   // wrap as TailscaleNetwork
    }
    h.a47 = M.networkInterface;                 // <-- store user object directly
    return cX(h, null);                         // pass null for the network promise
}
return cX(h, vD(null));                         // DummyNetwork (no networking)
```

And the engine later calls (in `cheerpOS.js` / `cx_esm.js`):

- `Ho(a) { return a.a47.up(); }` — bring the network online
- `A.TCPSocket(host, port)` — outbound TCP connect
- `r.TCPServerSocket("0.0.0.0", { localPort: n })` — guest LISTEN
- `r.UDPSocket({ localPort: n })` — UDP bind
- `r.delete()` — teardown

These are the exact methods exposed by every `*Network` class in `tun/direct.js`. Confirmed by listing `Object.getOwnPropertyNames(Object.getPrototypeOf(new direct.StreamNetwork({})))`:

```
[ 'constructor', 'TCPServerSocket', 'TCPSocket', 'UDPSocket', 'delete', 'up' ]
```

(All four classes — `StreamNetwork`, `DirectSocketsNetwork`, `TailscaleNetwork`, `DummyNetwork` — share this prototype shape; they differ only in implementation.)

### The transport injection contract

Pass `Linux.create({ networkInterface: customNet })` where `customNet` does NOT have a `netmapUpdateCb` property. CheerpX will:

1. Skip the Tailscale wrap path.
2. Stash `customNet` at the engine's `a47` slot.
3. Call `customNet.up()` once.
4. On every guest TCP `connect()`, call `customNet.TCPSocket(host, port)` and use the returned object.
5. On every guest TCP `listen()`, call `customNet.TCPServerSocket("0.0.0.0", {localPort})`.
6. On every guest UDP `socket()`, call `customNet.UDPSocket({localPort})`.

The return shape for `TCPSocket(host, port)` (verified empirically via `StreamNetwork`):

```ts
{
    opened: Promise<{
        readable: ReadableStream<Uint8Array>,
        writable: WritableStream<Uint8Array>,
        remoteAddress: string,
        remotePort: number,
        localAddress: string,
        localPort: number,
    }>,
    closed: Promise<void>,
    close: () => void,
}
```

This is the **WHATWG Direct Sockets API** shape exactly. The engine reads `Uint8Array` chunks from `readable` and writes `Uint8Array` chunks to `writable`.

`TCPServerSocket("0.0.0.0", {localPort})` returns:
```ts
{
    opened: Promise<{
        readable: ReadableStream<TCPSocket>,   // yields incoming connections
        localAddress: string,
        localPort: number,
    }>,
    closed: Promise<void>,
    close: () => void,
}
```

### Why this matters

We do **not need to fork CheerpX, monkey-patch `WebSocket`, or string-substitute the minified runtime.** A ~150-LOC duck-typed `WSTransportNetwork` class that fronts our `/net` WebSocket and conforms to this interface is sufficient. CheerpX never knew it wasn't talking to its own implementation.

The original spec assumption that CheerpX uses Tailscale-only networking is **invalidated** in CheerpX 1.2.x: the engine has a generic Network interface internally and `networkInterface` is the injection point. The public typings just don't surface it.

### Reproduction (run from repo root after `tools/vendor-cheerpx.sh`)

```bash
cat > /tmp/probe.mjs << 'EOF'
import * as M from './webvm-harness/vendor/cheerpx/tun/direct.js';
const direct = await M.default();
const sn = new direct.StreamNetwork({});
console.log('proto:', Object.getOwnPropertyNames(Object.getPrototypeOf(sn)));
await sn.up();
const srv = sn.TCPServerSocket('0.0.0.0', { localPort: 9999 });
console.log('server keys:', Object.keys(srv));
const cli = sn.TCPSocket('0.0.0.0', 9999);
const op = await cli.opened;
console.log('client opened:', Object.keys(op));
console.log('  readable:', op.readable.constructor.name);
console.log('  writable:', op.writable.constructor.name);
EOF
node /tmp/probe.mjs
```

Expected output:
```
proto: [ 'constructor', 'TCPServerSocket', 'TCPSocket', 'UDPSocket', 'delete', 'up' ]
server keys: [ 'opened', 'closed', 'close' ]
client opened: [ 'readable', 'writable', 'remoteAddress', 'remotePort', 'localAddress', 'localPort' ]
  readable: ReadableStream
  writable: WritableStream
```

### Caveat — needs one browser-level confirmation

Static + Node-level evidence is unambiguous about the contract, but the full path (`Linux.create({networkInterface: customNet})` actually leading to `customNet.TCPSocket()` being called on a guest `connect()`) cannot be exercised from Node — `Hz` calls `document` early, and `bG()` (the dynamic-import base resolver) requires a `https://` URL in the Error stack trace. **W6 must validate the contract end-to-end inside Playwright** by:

1. Loading the harness from `http://127.0.0.1:<port>/`.
2. `Linux.create({ networkInterface: ourTransport, mounts: [...] })`.
3. Booting a guest that runs `nc 1.2.3.4 80` or similar.
4. Verifying the harness saw a `TCPSocket('1.2.3.4', 80)` call on `ourTransport`.

If this turns out to fail (e.g. Hz silently rejects the unknown shape post-1.2.11), fall back to E3 below. But every static and dynamic signal we have says it will work.

---

## E1 — `network: undefined` baseline

### What we found

Same `Hz` branching:

```
if (M.hasOwnProperty("networkInterface")) { ... }
return cX(h, vD(null));    // <-- DummyNetwork, no arg
```

Without `networkInterface`, CheerpX constructs `DummyNetwork`. `DummyNetwork.TCPSocket(host, port)` was probed in Node and **returns `null`** (no `{opened, closed, close}` object at all). The C++ `__ZN12DummyNetwork9TCPSocket...` returns null too.

### Implication for the guest

The `Linux` engine code path on `null` from `TCPSocket` likely surfaces a syscall error (probably `ENETUNREACH` or `ECONNREFUSED`; the exact mapping is in `cxcore.wasm`'s syscall table and not worth disassembling). For our M2 milestone (`curl https://example.com` succeeding), this baseline is unusable. E1 is documented but not a candidate for the MVP.

### Reproduction
```bash
node -e "
import('./webvm-harness/vendor/cheerpx/tun/direct.js').then(async M => {
  const d = await M.default();
  const dum = new d.DummyNetwork();
  await dum.up();
  console.log('DummyNetwork.TCPSocket(\"1.2.3.4\",80) =>', dum.TCPSocket('1.2.3.4', 80));
});
"
# → DummyNetwork.TCPSocket("1.2.3.4",80) => null
```

---

## E3 — monkey-patch `window.WebSocket`

### What we found

CheerpX's only WS dial in 1.2.11 is the Tailscale path. `tun/tailscale.wasm` (18.7 MiB Go-compiled) embeds the full Tailscale Go client. `strings` reveals the default control plane URL:

```
https://controlplane.tailscale.com
```

So if the user passes `networkInterface: { netmapUpdateCb: () => {} }` (which forces the Tailscale path), CheerpX will dial **`controlplane.tailscale.com`** over WSS and run real Tailscale control-plane RPCs (Noise_IK_25519_ChaChaPoly_BLAKE2s handshake, MapRequest long-poll, DERP relay protocol — all visible in the WASM strings).

### Implication

Even if we monkey-patched `window.WebSocket` to redirect that dial to our `/net` endpoint, what we'd receive would be Tailscale's wire protocol — Noise handshakes, MapRequests, DERP frames — **not raw socket frames from a normal guest application**. Faking that protocol in Swift would require implementing a substantial Tailscale coordination-server compatible enough to satisfy the embedded Go client. That's "implement half of Tailscale" territory and a significantly larger project than the original architectural concern.

E3 is a fallback only if E2 fails for an unexpected reason. The cost is much higher than originally estimated.

### Note on `DirectSocketsNetwork`

`DirectSocketsNetwork.TCPSocket(host, port)` calls a browser-global `TCPSocket()` constructor — the [WICG Direct Sockets API](https://wicg.github.io/direct-sockets/), only available in **Isolated Web Apps**. Not available in WKWebView, not viable for our use case.

---

## E4 — string-substitution patches

### What we'd need (documented for completeness, not recommended)

If E2 fails, options to patch the minified runtime:

1. Replace `https://controlplane.tailscale.com` literal in `tun/tailscale.wasm` — requires WASM section editing or post-build binary patch. We control vendoring, so feasible.
2. Patch `cx_esm.js` `Hz` function to add a new branch: if `networkInterface.transport === 'ws-raw-socket'`, construct a custom Network class. The Cheerp-compiled JS uses opaque field names (`a47`, `i13`, etc.) which are stable within a version but rename across versions. Brittle.
3. Patch `cx_esm.js` to override `tun/direct.js`'s default export (intercept the `import(bG().concat('tun/direct.js'))` call by redirecting `bG` or by replacing `direct.js` itself with our own implementation). Cleanest of the three.

**E4 is a last resort.** Pin a CheerpX version, freeze the patch, and document a re-patch protocol on every version bump. We do **not** intend to use E4 for the MVP.

---

## 9P mount investigation

### Static evidence

1. The TypeScript `index.d.ts` declares only `type: "ext2" | "dir" | "devs" | "proc"`.
2. `cxcore.wasm` (the i386 Linux kernel image) `strings`-greps for filesystem types yield only `ext2`, `proc`, `sysfs`, `devtmpfs`. **No `9p` filesystem driver is compiled into the guest kernel.**
3. No `Tversion`, `Rversion`, `9P2000`, or other 9P protocol literals appear in any vendored file (full grep: zero matches across all `.js` and binary `strings` of `.wasm`).

### Dynamic evidence

The mount type string is passed into the WASM kernel as a UTF-8 byte sequence (no JS-side validation of the string). So `Linux.create({ mounts: [{ type: "9p", path: "/mnt/host", dev: someDevice }] })` would be syntactically accepted by the JS layer, but the in-guest Linux kernel mount() call would fail with `ENODEV` (no such filesystem registered). We did not run this end-to-end (browser-only), but the WASM kernel image has no possible way to handle it.

### Conclusion

**Native CheerpX 9P mount is not viable.** The guest kernel doesn't include the 9p.ko driver and no fork/patch we can do at the JS layer changes that. The original spec assumption (P2 — register a "9p" mount type) was correct that we'd need to register one, but missed that the guest kernel side also needs the driver compiled in.

### Fallback: 9P-as-`dir`-mount JS shim

Use the supported `type: "dir"` mount, where `dev` is a `CheerpOSDevice` subclass. We implement a custom `CheerpOSDevice` (or wrap `WebDevice`) whose VFS operations (`stat`, `read`, `write`, `readdir`, `mkdir`, `unlink`, etc.) are forwarded over our `/9p` WebSocket to the Swift `NinePServer`. The Swift server still speaks 9P2000.L wire format (W1/W5 codecs intact); the JS shim is the 9P client that translates `dir`-mount VFS calls into Tmessages.

Approximate shape (W6 will implement):
```js
class NinePDirDevice extends CheerpX.WebDevice {
    constructor(wsUrl) { ... }
    async readdir(path) { /* send Treaddir, await Rreaddir, return entries */ }
    async stat(path)    { /* Tgetattr → Rgetattr → mode/uid/gid/size/etc. */ }
    async read(path, offset, length)  { /* Topen + Tread loop */ }
    async write(path, offset, data)   { /* Topen + Twrite loop */ }
    // ... etc, per the dir-device interface CheerpX expects
}
```

The exact `CheerpOSDevice` subclass interface needs one more browser-level probe (instantiate `WebDevice.create(url)` and inspect prototype) — W6's first task. The interface is enumerable at runtime; static inspection of cheerpOS.js gives partial hints (it has methods around `cookie`, `cors`, `headers`, etc., suggesting WebDevice is HTTP-backed).

POSIX limitations (acceptable for MVP, documented in scope cuts):
- No `xattr`, no locks, no symlinks, no hardlinks, no atomic rename
- `vim` falls back to copy+unlink for save (works if `O_CREAT|O_EXCL` is supported)
- `git` operations on `/mnt/host` will work for basic flows; `.git/index.lock` may be flaky

### Reproduction (browser test, deferred to W6)

```js
// In a Playwright test against our harness:
const linux = await CX.Linux.create({
    mounts: [
        { type: "ext2",  path: "/",         dev: baseExt2Dev },
        { type: "dir",   path: "/mnt/host", dev: ninepShimDev },
        { type: "devs",  path: "/dev",      dev: devsDev },
        { type: "proc",  path: "/proc",     dev: procDev },
    ],
    networkInterface: wsTransportNet,
});
```

---

## Decision tree summary

| # | Question | Answer | Source |
|---|---|---|---|
| 1 | Does CheerpX accept a custom transport? | **YES, via `networkInterface` without `netmapUpdateCb`** | E2 static + dynamic |
| 2 | Is there a published `StreamNetwork` interface we can pass? | **No — `StreamNetwork` is loopback-only**; but a duck-typed object works | E2 |
| 3 | Does `network: undefined` give us any useful guest networking? | No, `DummyNetwork` rejects all sockets | E1 |
| 4 | Can we monkey-patch the WS dial? | Possible but the WS carries Tailscale control-plane RPCs, not raw bytes | E3 |
| 5 | Can the guest kernel mount type `9p`? | No — driver not in `cxcore.wasm` | strings(cxcore.wasm) |
| 6 | What's the 9P fallback? | `dir`-mount with a `CheerpOSDevice` shim that forwards VFS ops over WS | spec/06 |

---

## Recommendation

### 1. Network transport: **use E2** (custom `networkInterface` injection)

Implement `webvm-net-transport.js` as a class that conforms to:
```ts
class WSTransportNetwork {
    constructor(wsUrl: string);
    up(): Promise<void>;                             // open the WebSocket
    delete(): void;                                  // close the WebSocket
    TCPSocket(host: string, port: number): {
        opened: Promise<{ readable: ReadableStream<Uint8Array>,
                          writable: WritableStream<Uint8Array>,
                          remoteAddress: string, remotePort: number,
                          localAddress: string, localPort: number }>,
        closed: Promise<void>,
        close: () => void,
    };
    TCPServerSocket(host: string, opts: { localPort: number }): {...};  // M-post: spec doesn't require LISTEN
    UDPSocket(opts: { localPort: number }): {...};                       // M-post: spec doesn't require UDP
}
```

For MVP scope (TCP-only, no LISTEN/UDP per spec), `TCPServerSocket` and `UDPSocket` can return objects whose `opened` rejects with a clear "not implemented" error. Each `TCPSocket(host, port)` call:

1. Allocates a `connId` (uint32) from a counter.
2. Sends a `CONNECT` frame over the shared `/net` WS (per `spec/03-net-bridge.md`).
3. Waits for `CONNECT_ACK` or `CONNECT_ERR` from the Swift NetBridge.
4. On ACK: builds a `TransformStream` pair; pumps incoming `DATA` frames into the readable side; pumps writable-side chunks out as `DATA` frames; resolves `opened` with the WHATWG-shaped object.
5. On `CLOSE` (either side): rejects `opened` if not yet open, or resolves `closed` if already open.

**No fork needed.** No string patches. ~100–150 LOC of straightforward JS.

### 2. 9P mount: **JS shim (`dir`-mount with WS-backed device)**

Implement `webvm-9p-mount.js` as a `CheerpOSDevice` subclass (exact base class TBD by W6 first probe) that translates VFS operations into 9P2000.L Tmessages on the `/9p` WebSocket. Reuses W2's `ninep-codec.js`. The Swift `NinePServer` (W5) speaks unmodified 9P; only the client side moves into the browser.

Document the limitations (no xattr/locks/symlinks/hardlinks/rename) in user-facing notes.

### 3. What W6 should do

1. **First step in W6:** spike a Playwright test that boots a minimal CheerpX (only `ext2` + `proc` + `devs` mounts, `networkInterface: {up:async()=>{}, TCPSocket: () => {opened:Promise.reject('probe'), closed:Promise.resolve(), close:()=>{}}}`) and confirms via console.log that `TCPSocket` was called when the guest tries to connect. **This validates E2 end-to-end before any real implementation work.** Budget: 1 hour. If it fails, reopen this investigation; do not write the full transport class first.
2. Implement `WSTransportNetwork` per the contract above. Wire to `/net` WS. Pass as `networkInterface` to `Linux.create`.
3. Probe `WebDevice` / `CheerpOSDevice` prototype in the browser to confirm the `dir`-mount device interface, then implement `NinePDirDevice` over the `/9p` WS using `ninep-codec.js`. Pass as a `dir`-mount `dev`.
4. Standard E2E: boot to bash prompt, `curl example.com` resolves through `/net`, `ls /mnt/host` resolves through `/9p`.

### Things that would block W6 if not addressed

- **None known from W4.** All interfaces are mapped. The only outstanding risk is the browser-level E2 confirmation (step 1 above) — handled by spiking it as W6's first action with a tiny stub before any production code.
- One soft block: the exact `dir`-mount `dev:` interface (which subclass of `CheerpOSDevice` to extend, what method names CheerpX's VFS expects). Static inspection of `cheerpOS.js` shows methods like `readdir`, `stat`, `read`, `write`, `cookie`, `cors`, but the canonical mapping needs runtime probing in the browser. W6 owns this probe; it's ~15 minutes of `Object.getOwnPropertyNames` in the dev console.

---

## Commands run during this investigation (all reproducible)

```bash
# Vendor (with version pinning)
tools/vendor-cheerpx.sh 1.2.11

# Static inspection
strings webvm-harness/vendor/cheerpx/cxcore.wasm | grep -iE '^(ext2|9p|proc|sysfs|tmpfs|devtmpfs)$'
strings webvm-harness/vendor/cheerpx/tun/tailscale.wasm | grep -iE 'controlplane|wss?://'
grep -oE '"[^"]+\.(js|wasm)"' webvm-harness/vendor/cheerpx/cx_esm.js | sort -u
grep -oE "concat\('[^']+'\)" webvm-harness/vendor/cheerpx/cx_esm.js   # find dynamic imports

# Dynamic probes (Node)
node -e "
import('./webvm-harness/vendor/cheerpx/tun/direct.js').then(async M => {
  const d = await M.default();
  console.log('Networks:', Object.keys(d));
  for (const cls of Object.keys(d)) {
    const inst = new d[cls](cls === 'TailscaleNetwork' ? {} : (cls === 'DirectSocketsNetwork' ? undefined : {}));
    console.log(cls, Object.getOwnPropertyNames(Object.getPrototypeOf(inst)));
  }
});
"
```
