# 06 - CheerpX Fork

## Goal

Minimize delta from upstream CheerpX. Patch only what's needed to accept localhost WS transports and (optionally, Direction A) a Swift-backed block device.

## Fork location

- Fork `leaningtech/cheerpx` (or the relevant package; structure may have moved to `@leaningtech/cheerpx` npm)
- Maintain patches as a series, not a long-running divergent branch
- Prefer patches that could conceivably be upstreamed

## Patch categories

### P1: Networking transport replacement (required)

**Files (locate during investigation):**
- The Tailscale/WireGuard WebSocket client in CheerpX network code
- The guest syscall adapter for socket family operations

**Change:**
- Add a new transport option: `ws-raw-socket` that speaks the protocol from `03-net-bridge.md`
- When configured, bypass lwIP (or equivalent guest TCP/IP) and route guest `connect/send/recv` syscalls directly to raw-socket protocol frames
- Preserve Tailscale transport as the default (no regression for upstream users)

**Config API:**
```javascript
const cx = await CheerpX.Linux.create({
    mounts: [...],
    network: {
        transport: "ws-raw-socket",
        endpoint: "ws://127.0.0.1:8080/net",
    },
});
```

**Reconnection:**
- On WS disconnect, all open guest sockets should see EPIPE / EBADF
- New `connect()` calls after reconnect succeed
- No automatic resume of in-flight transfers (guest application must retry)

### P2: WS-based 9P mount (required)

**Files (locate during investigation):**
- CheerpX mount type registry (where `ext2`, `dir`, `devs` are registered)

**Change:**
- Register new mount type `9p` with config `{ transport: "ws", endpoint: "ws://..." }`
- Connect to endpoint during mount; send Tversion; negotiate
- Route guest VFS operations against `/mnt/host` through 9P requests to endpoint
- 9P response from server translated back to VFS result

**Config API:**
```javascript
mounts: [
    { type: "9p", path: "/mnt/host",
      endpoint: "ws://127.0.0.1:8081/9p",
      msize: 32768 },
]
```

**Reconnection:**
- On WS disconnect, open FIDs invalidated; pending requests fail with EIO
- Next VFS operation reopens the mount silently (new Tversion/Tattach)
- If reconnect fails, mount returns EIO persistently; guest can `umount` and remount

### P3: Pause/resume hooks (required)

**Change:**
- Expose `window.webvm.pause()` / `window.webvm.resume()` on the global object
- `pause()` halts x86 execution loop, stops timers
- `resume()` reconnects WS endpoints if disconnected, restarts execution loop

Rationale: iOS app lifecycle requires VM suspension during backgrounding.

### P4: Swift-backed block device (optional, Direction A)

**Scope:** only if investigation milestone concludes Direction A is warranted.

**Change:**
- Add new block device type: `NativeDevice` implementing the standard CheerpX Device interface
- Communicates with Swift via `WKScriptMessageHandler` or a dedicated WS endpoint
- Request/response: `{op: "read", offset, length}` / `{op: "write", offset, data}`

Protocol to prefer for Swift communication:
- **postMessage via WKScriptMessageHandler** - lower latency, no WS framing overhead, but requires promise-based wrapper in JS
- **Dedicated WS** - consistent with other transports, but adds WS framing overhead to every block read

Recommendation pending measurement.

**Config API:**
```javascript
const nativeDevice = await CheerpX.NativeDevice.create("overlay-root");
const overlayDevice = await CheerpX.OverlayDevice.create(baseDevice, nativeDevice);
```

Where `"overlay-root"` is a handle the Swift side uses to look up the backing file.

## Non-patches (keep stock)

- ext2 filesystem driver
- x86→WASM JIT
- Linux syscall emulation layer (except networking syscalls)
- IDBDevice
- OverlayDevice
- HttpBytesDevice
- DataDevice
- WebDevice
- Console / terminal integration

## Build output

- `cheerpx.js` (patched)
- `cheerpx.wasm` (unchanged unless syscall layer was touched)
- Source maps committed to repo for debug builds

## Patch delivery

Two options:

### A. Maintain a fork branch

Pros: easy to build, easy to rebase on upstream
Cons: all-or-nothing; hard to cherry-pick specific patches

### B. Patch files applied at build time

Pros: clear visibility of what changed; easier to review
Cons: more fragile across upstream versions

**Recommendation: A for PoC.** Switch to B if patches stabilize and Leaning Tech shows interest in accepting upstream.

## Upstream engagement

- File issues on leaningtech/cheerpx for each patch category describing the use case
- Offer patches upstream for P3 (pause/resume hooks) - broadly useful
- P1/P2 might be accepted as transport plugins if structured as such
- P4 is more controversial; likely stays in fork

## Version pinning

- Pin to a specific CheerpX version in fork
- Document upstream commit/tag in `CHEERPX_VERSION.md`
- Rebase process: scripted `git rebase upstream/main` with conflict resolution log

## Testing in fork

- Upstream test suite must pass
- Fork adds test suite for P1, P2, P3, P4
- CI runs both on PR
