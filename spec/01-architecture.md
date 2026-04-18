# 01 - Architecture

## System diagram

```
┌─────────────────────────────────────────────────────────────┐
│ iOS App Process (Swift)                                     │
│                                                             │
│  ┌────────────────┐    ┌─────────────┐   ┌───────────────┐  │
│  │ VMHost         │    │ NetBridge   │   │ NinePServer   │  │
│  │ (coordinator)  │    │ WS :8080    │   │ WS :8081      │  │
│  └────────────────┘    └─────────────┘   └───────────────┘  │
│         │                    │                   │          │
│         │                    │                   │          │
│  ┌──────▼──────────────────────────────────────────▼─────┐  │
│  │ WKWebView (WKURLSchemeHandler: webvm://)              │  │
│  │                                                       │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │ WebVM HTML/JS (CheerpX + patched networking)    │  │  │
│  │  │                                                 │  │  │
│  │  │  CheerpX.Linux.create({                         │  │  │
│  │  │    mounts: [                                    │  │  │
│  │  │      { "/", ext2, OverlayDevice(base, idb) },   │  │  │
│  │  │      { "/mnt/data", ext2, readonly dataset },   │  │  │
│  │  │      { "/mnt/host", 9p, ws://127.0.0.1:8081 },  │  │  │
│  │  │    ],                                           │  │  │
│  │  │    net: { transport: ws://127.0.0.1:8080 }      │  │  │
│  │  │  })                                             │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
         │                         │                    │
         │                         │                    │
    NWConnection              NWConnection        Security-scoped
    (TCP/UDP egress)          (TCP/UDP egress)    URL (Files app)
```

## Component responsibilities

### VMHost (Swift, main actor)
- Owns lifecycle of both WS servers
- Owns security-scoped bookmark for user-selected shared folder
- Persists bookmark to `UserDefaults` so folder choice survives relaunch
- Observes app state transitions (foreground/background) and signals subcomponents

### NetBridge (Swift)
- One instance per accepted WS connection on `:8080`
- Translates raw-socket-over-WS frames into NWConnection calls
- Maintains per-WS-connection connection table keyed by `conn_id`
- DNS resolution via `NWEndpoint.hostPort` with hostname (Network.framework resolves)

### NinePServer (Swift)
- One instance per accepted WS connection on `:8081`
- Implements 9P2000.L opcode subset (see `04-ninep-server.md`)
- FID table keyed by 32-bit FID, mapped to Swift `URL` + optional `FileHandle`
- Manages security-scoped resource access around file operations

### WKWebView
- Loads bundled HTML via `webvm://` scheme (custom scheme handler sets COOP/COEP headers)
- Runs patched CheerpX that uses localhost WS transports instead of Tailscale
- WKURLSchemeHandler serves: HTML/JS/WASM bundle, base ext2 image, read-only datasets

### Patched CheerpX (JS/WASM)
- Standard CheerpX except networking code replaced with raw-socket-over-WS client
- Optional: new block device type for Swift-backed overlay (see `08-investigation.md`)
- Otherwise stock: ext2, IDBDevice, OverlayDevice, CloudDevice support retained

## Process model

Single iOS app process. No XPC services, no app extensions in PoC milestone. WKWebView runs in its own process (standard iOS behavior) but this is transparent; communication is via:
- `WKScriptMessageHandler` for JS-initiated control-plane calls
- `WKURLSchemeHandler` for resource loading (disk image, HTML, WASM)
- Localhost WebSocket for bulk data (network sockets, 9P operations)

**Why WebSocket for bulk data and not postMessage/WKScriptMessageHandler?**
- WS is a first-class transport in CheerpX's networking abstraction; less patch surface
- Binary message support is native in WS; `postMessage` requires explicit ArrayBuffer transfer
- Bidirectional, full-duplex, no polling
- Frame boundaries are preserved (unlike stream-style transports)

## Threading model

- VMHost: main actor (UI-adjacent state)
- NetBridge: per-connection work on `DispatchQueue.global(qos: .userInitiated)`
- NinePServer: per-connection work on `DispatchQueue.global(qos: .userInitiated)`
- File I/O in NinePServer blocks its own queue; no thread pool (9P is serialized per FID anyway)

## Lifecycle events

| Event | Behavior |
|---|---|
| App launch | VMHost starts, both WS servers bind, WKWebView loads index |
| CheerpX init | Connects to both WS endpoints during `CheerpX.Linux.create` |
| App foreground→background | WS connections may be interrupted within ~30s; VM pauses |
| App background→foreground | VM resumes; CheerpX must reconnect WS; reconnect logic in fork |
| App terminate | IDB overlay is already persistent; 9P file handles close via WS close |
| User picks new shared folder | VMHost updates bookmark; active NinePServer unchanged until unmount/remount |

## Security boundaries

- WKWebView sandbox: standard iOS
- CheerpX sandbox: x86 code runs entirely in WASM, no iOS syscall access
- Egress: only via NetBridge (Swift-mediated); guest has no direct socket access
- File access: only via NinePServer (security-scoped URL resolved per request) and mounted block devices
- No entitlements beyond default; no NetworkExtension, no BrowserEngineKit
