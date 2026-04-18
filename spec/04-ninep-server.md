# 04 - 9P2000.L Server

## Goal

Expose a user-selected iOS folder as a 9P2000.L-mountable filesystem accessible at `/mnt/host` in the guest. Enables file exchange between iOS Files app and guest Linux userland.

## Protocol choice: 9P2000.L

Linux kernel has two 9P dialects: `9p2000.u` (Plan 9 + Unix extensions) and `9p2000.L` (Linux-specific, full POSIX semantics). We use `.L`:
- Native Linux error codes (errno)
- `getattr`/`setattr` with Linux stat semantics
- `readdir` instead of translating directory reads through file I/O
- Extended attribute support (optional)
- Better performance than `.u` for Linux clients

Guest mount command: `mount -t 9p -o trans=fd,rfd=N,wfd=N,version=9p2000.L,msize=65536 host /mnt/host`

In our setup, `trans=fd` is replaced by the WS transport via CheerpX's mount shim.

## Wire format

All messages: `size(4 LE) | type(1) | tag(2 LE) | body`
- `size` includes header
- `tag` is client-generated request identifier (server echoes in reply)
- `type` is opcode; T-messages are requests, R-messages are replies

One WS binary message = one 9P message. Server never fragments; client MUST NOT fragment (9P allows it but we don't).

## Opcode coverage

### Required for PoC (mount + basic I/O)

| Opcode | Name | Function |
|---|---|---|
| 100/101 | Tversion/Rversion | Negotiate msize and protocol version |
| 104/105 | Tattach/Rattach | Establish root FID |
| 110/111 | Twalk/Rwalk | Traverse path, create new FID |
| 120/121 | Tclunk/Rclunk | Release FID |
| 12/13 | Tlopen/Rlopen | Open file for I/O |
| 116/117 | Tread/Rread | Read from open FID |
| 118/119 | Twrite/Rwrite | Write to open FID |
| 24/25 | Tgetattr/Rgetattr | Stat a FID |
| 40/41 | Treaddir/Rreaddir | Read directory entries |
| 14/15 | Tlcreate/Rlcreate | Create and open a file |
| 6/7 | Tlerror/Rlerror | Error reply (Linux errno) |

### Required for common workflows

| Opcode | Name | Function |
|---|---|---|
| 70/71 | Tmkdir/Rmkdir | Create directory |
| 72/73 | Tunlinkat/Runlinkat | Remove file/directory |
| 20/21 | Trename/Rrename | Rename (deprecated; prefer Trenameat) |
| 74/75 | Trenameat/Rrenameat | Rename relative to two FIDs |
| 26/27 | Tsetattr/Rsetattr | Change permissions/owner/times |
| 76/77 | Tsymlinkat | Create symlink (if allowed by iOS sandbox) |
| 8/9 | Tstatfs/Rstatfs | Filesystem statistics |
| 50/51 | Tfsync/Rfsync | Force pending writes to storage |

### Out of scope for PoC

- `Txattrwalk`/`Txattrcreate` (extended attributes)
- `Tlock`/`Tgetlock` (POSIX advisory locks)
- `Treadlink` (acceptable if Tsymlinkat is also out)
- `Tlink` (hardlinks; iOS security-scoped URLs don't support cleanly)

### Error mapping

All errors via Rlerror with Linux errno value. Mapping from Swift errors:

| Swift / NSError | Linux errno |
|---|---|
| `POSIXError.ENOENT` | 2 |
| File-not-readable `NSFileReadNoPermissionError` | 13 (EACCES) |
| `POSIXError.EEXIST` | 17 |
| `POSIXError.ENOTDIR` | 20 |
| `POSIXError.EISDIR` | 21 |
| `POSIXError.EINVAL` | 22 |
| `POSIXError.ENOSPC` | 28 |
| Security-scoped access failure | 13 (EACCES) |
| Generic I/O failure | 5 (EIO) |
| Unimplemented opcode | 38 (ENOSYS) |

## FID lifecycle

### FID table

```swift
struct Fid {
    var url: URL                // Absolute URL within security-scoped root
    var handle: FileHandle?     // nil until Tlopen for files; always nil for dirs
    var isDir: Bool
    var dirEnumerator: [URL]?   // Cached directory contents for Treaddir offset semantics
    var dirOffset: UInt64       // Logical offset into dirEnumerator
}

private var fids: [UInt32: Fid] = [:]
```

### FID rules

- Server allocates FID 0 to root on Tattach (guest specifies FID; we use whatever they pass)
- Twalk with `nwname=0` clones an existing FID (points to same URL, fresh handle=nil)
- Twalk with `newfid == fid` is allowed (replaces in place) only if no file handle
- Twalk that fails partway leaves `newfid` unestablished; client must not use it
- Tclunk MUST succeed even on garbage FID (idempotent cleanup)
- Abandoned FIDs (client crashes, WS drops): all FIDs released when WS closes

### File handle management

- Tlopen opens and caches a `FileHandle` in the Fid struct
- Subsequent Tread/Twrite seek to offset, then I/O
- Tclunk closes the handle
- Max open handles per NinePServer: 128 (configurable); LRU eviction when exceeded (reopen on next Tread)

## Security-scoped URL handling

### Root acquisition

On NinePServer init, caller passes the root `URL` (already security-scoped from file importer). Server calls:

```swift
guard url.startAccessingSecurityScopedResource() else {
    throw NinePError.rootAccessDenied
}
```

One access token per server instance. Released in deinit.

### Path traversal safety

Twalk components MUST be validated:
- No `..` in component names (reject with ENOENT)
- No `/` in component names (9P forbids this at protocol level; validate anyway)
- Result URL MUST have root URL as prefix after canonicalization

```swift
func walkComponent(base: URL, name: String) throws -> URL {
    guard !name.contains("/"), name != "..", name != "." else {
        throw POSIXError(.EINVAL)
    }
    let candidate = base.appendingPathComponent(name)
    let canonical = candidate.standardized
    guard canonical.path.hasPrefix(root.standardized.path) else {
        throw POSIXError(.EACCES)
    }
    return canonical
}
```

### Bookmark staleness

If the security-scoped URL becomes stale during server runtime (user revoked access in system settings, iCloud sync removed underlying file), operations return EACCES. Server does not proactively re-request access; that is the app shell's responsibility.

## Directory reading semantics

Treaddir takes (fid, offset, count) and returns entries up to `count` bytes. 9P.L uses opaque offsets: server gives any offset, client passes it back.

Strategy:
1. On first Treaddir with offset=0, enumerate directory and cache `[URL]` in Fid
2. Use array index as offset
3. On subsequent Treaddir, slice cache starting at offset, emit entries until count bytes consumed
4. Invalidate cache on Tclunk

Trade-off: snapshot semantics. If files are added during enumeration, client won't see them until re-open. Consistent with Linux VFS 9P client behavior.

### Entry encoding

Each entry: `qid(13) | offset(8 LE) | type(1) | name(s)` where name is `len(2 LE) | utf8_bytes`.

`type` is Linux `DT_*` value: DT_DIR=4, DT_REG=8, DT_LNK=10, etc.

## Qid construction

9P qid is 13 bytes: `type(1) | version(4 LE) | path(8 LE)`.

- `type`: 0x80 for directories, 0x00 for files, 0x02 for symlinks
- `version`: 0 (we don't track versioning; acceptable per spec)
- `path`: **must be stable per file for the lifetime of the mount**

### Inode-based qid.path

Use `stat()` via Darwin to get `st_ino`:

```swift
var s = stat()
guard url.path.withCString({ stat($0, &s) }) == 0 else {
    throw POSIXError(.ENOENT)
}
let inode = UInt64(s.st_ino)
```

**Caveat:** iCloud-synced files may have shifting inodes when re-downloaded. This is acceptable - it causes the 9P cache to invalidate, which is correct behavior when the file has actually changed.

## msize negotiation

- Client proposes msize in Tversion
- Server replies with `min(proposed, 65536)` for PoC
- Read/write operations must not exceed `msize - header` bytes per frame
- Recommended msize: 32768 (balance between latency and throughput)

## Validation

### Unit tests (Swift)
- Frame encode/decode round-trip for each implemented opcode
- Path traversal attacks (`../../etc/passwd` in Twalk names) rejected
- FID reuse guards (Tattach twice with same FID: second wins or errors cleanly)
- Directory cache invalidation on clunk

### Integration tests (via VM)
- Guest mounts `/mnt/host` without error
- `ls -la /mnt/host` shows expected entries with correct permissions
- `cat /mnt/host/foo.txt > /tmp/bar && cmp /tmp/bar /mnt/host/foo.txt`
- `echo hello > /mnt/host/newfile.txt` creates file visible in iOS Files
- `mkdir /mnt/host/subdir && rmdir /mnt/host/subdir`
- `git init /mnt/host/repo && cd /mnt/host/repo && git add . && git commit` (stresses stat, readdir, small writes)

### Known-limitation tests
- `mknod` returns ENOSYS (acceptable)
- `chown` to non-current UID returns EPERM (security-scoped URLs are single-UID)
- Advisory locks (`flock`) return ENOSYS in PoC

## Performance notes

- Each 9P request-reply is one WS round-trip through loopback
- Loopback WS RTT in WKWebView: empirically 0.5-2ms
- Cold `git status` in 10k-file repo: several thousand stat calls → several seconds
- This is the motivating limitation for the Direction B investigation (see `08-investigation.md`)

Server should not attempt aggressive caching (readahead, stat cache) in PoC. Investigation milestone decides if the complexity is worth it.
