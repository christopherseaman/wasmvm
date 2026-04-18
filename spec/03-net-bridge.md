# 03 - Network Bridge

## Goal

Replace CheerpX's Tailscale-over-WebSocket networking with a local raw-socket-over-WebSocket bridge. The iOS app acts as the userspace TCP/IP egress for the VM; guest networking calls are translated into `NWConnection` operations.

## Protocol

Little-endian binary framing. Each WS binary message is exactly one frame.

### Frame header (9 bytes)

| Offset | Size | Field | Description |
|---|---|---|---|
| 0 | 1 | `op` | Operation code (see below) |
| 1 | 4 | `conn_id` | Connection identifier (u32 LE) |
| 5 | 4 | `length` | Payload length in bytes (u32 LE) |
| 9 | N | `payload` | Operation-specific data |

### Operations

| Op | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | `CONNECT` | guest→host | family(1) proto(1) host_len(2 LE) host_str port(2 LE) |
| 0x02 | `DATA` | bidirectional | raw bytes |
| 0x03 | `CLOSE` | bidirectional | empty |
| 0x04 | `CONNECT_OK` | host→guest | empty |
| 0x05 | `CONNECT_ERR` | host→guest | ASCII reason string |
| 0x06 | `LISTEN` | guest→host | family(1) proto(1) port(2 LE) |
| 0x07 | `LISTEN_OK` | host→guest | bound_port(2 LE) |
| 0x08 | `ACCEPT` | host→guest | new_conn_id(4 LE) peer_host(s) peer_port(2 LE) |
| 0x09 | `RESOLVE` | guest→host | hostname(s) |
| 0x0A | `RESOLVE_OK` | host→guest | addr_count(1) [family(1) addr(4 or 16)]* |

### Connect payload

| Offset | Size | Field | Values |
|---|---|---|---|
| 0 | 1 | `family` | 4 = IPv4, 6 = IPv6 |
| 1 | 1 | `proto` | 6 = TCP, 17 = UDP |
| 2 | 2 | `host_len` | u16 LE |
| 4 | N | `host` | UTF-8 hostname or IP literal |
| 4+N | 2 | `port` | u16 LE |

### Connection ID allocation

- Guest assigns `conn_id`. Host trusts it (single-tenant app).
- Guest MUST NOT reuse a `conn_id` until it has both sent and received `CLOSE` for it.
- `conn_id = 0` is reserved for control-plane (future use).

### Message size limits

- `maximumMessageSize` on `NWProtocolWebSocket.Options` set to 16 MiB
- Guest MUST NOT send DATA payloads larger than 1 MiB
- If guest wants to send N bytes of app data where N > 1 MiB, it splits into multiple DATA frames
- Host pumps from socket in 64 KiB chunks regardless of guest's chunking

### Listen/accept

Optional for PoC. Required if user wants to run servers inside the VM (e.g., Jupyter, dev servers) accessible from other apps on the iPad.

If omitted in PoC:
- Guest code path for `bind()`/`listen()` returns `EACCES`
- Document as known limitation

## Swift implementation

See `/mnt/user-data/outputs/NetBridge.swift` for the reference implementation (covers CONNECT/DATA/CLOSE ops; LISTEN/ACCEPT/RESOLVE are TODO).

### Connection table

```swift
private var conns: [UInt32: NWConnection] = [:]
private let lock = NSLock()
```

Single-WS-connection scope. If the WS closes, all NWConnections cancel.

### DNS resolution

Two options:

**Option A (simpler):** let `NWConnection` do it. Pass hostname directly in `NWEndpoint.hostPort(host: .init("example.com"), port: ...)`. Network.framework resolves. No explicit RESOLVE op needed.

**Option B (explicit):** implement RESOLVE op. Guest can cache results, do happy eyeballs, etc.

Recommendation: **Option A for PoC**, add RESOLVE op later if guest caching matters.

### Backpressure

- NWConnection has its own flow control per socket
- WS layer has no backpressure primitive; large sends buffer in NWConnection
- Socket→WS pump reads in 64 KiB chunks and sends one WS frame per chunk
- If WS can't keep up, Network.framework accumulates unsent frames in memory
- **Mitigation:** monitor `NWConnection.currentPath.isExpensive` and log warning if WS send queue depth exceeds 32 frames

Not a PoC blocker; a production concern.

### UDP handling

- UDP is connectionless; CONNECT-then-DATA model emulates it by binding a default peer
- DATA frames on a UDP connection are single datagrams (preserve boundaries)
- `DataDatagramProtocol` on NWConnection gives per-datagram receive; pump uses `receiveMessage` not `receive`

### IPv6

- If guest specifies `family=6`, host passes IPv6 literal or lets Network.framework pick
- `NWParameters.tcp.defaultProtocolStack` supports both; no special config

## CheerpX fork points

See `06-cheerpx-fork.md` for fork surface. Minimum viable patch:

1. Identify Tailscale WireGuard endpoint in CheerpX network stack
2. Replace with WS client speaking protocol above
3. Route guest socket syscalls through new transport
4. Init-time config: accept `transport: "ws://127.0.0.1:8080/net"` option in `CheerpX.Linux.create`

### Expected patch surface

- One TypeScript/JS module: the networking transport adapter
- No changes to syscall emulation layer (same socket API surface)
- No changes to lwIP or equivalent TCP/IP stack (since we're replacing it with host-native)

Actually: we are *replacing* the guest TCP/IP stack with host-native sockets. This means lwIP (if CheerpX uses it for TCP state) is bypassed. Guest `socket()/connect()/send()/recv()` map directly to CONNECT/DATA frames.

**Alternative design:** keep lwIP in guest, tunnel raw IP packets over WS to the iOS app which runs a userspace TCP/IP stack. More faithful to "VM" semantics but 2-3x more code on both sides.

Recommendation: **bypass guest TCP/IP stack for PoC.** Side effects:
- No control over MTU, TCP timers, congestion from guest
- Can't run packet captures inside the VM
- pcap, tcpdump, etc. won't see traffic
- Raw socket programs inside VM won't work

These are acceptable PoC compromises. Revisit if needed.

## Validation

### Unit tests (Swift)
- Frame encoder/decoder round-trip
- Connection table FID allocation/reuse guards
- Graceful handling of malformed frames (short header, inconsistent length)

### Integration tests
- Guest `curl http://example.com` resolves + fetches via host bridge
- Guest `curl https://example.com` with TLS in guest
- Guest `ping` fails cleanly (no raw sockets, not supported)
- Guest opens 100 concurrent connections; host enforces per-WS connection limit (e.g., 256)
- WS disconnect during active transfer: guest sees EPIPE, host cancels NWConnection

### Performance targets
- `curl` of 10 MiB payload: ≥10 MiB/s on localhost (WS framing overhead dominates)
- Concurrent 32 connections: aggregate throughput ≥50 MiB/s
- Connection setup latency: ≤20ms added over native
