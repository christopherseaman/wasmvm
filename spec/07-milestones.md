# 07 - Milestones

Each milestone has explicit in-scope and out-of-scope items. Milestones are sequential; later milestones assume earlier milestones complete.

## M0: Upstream WebVM on iPad via WKWebView

**In scope:**
- iOS app with single WKWebView loading `https://webvm.io` (or local copy of upstream WebVM)
- Verify CheerpX initializes: SharedArrayBuffer available, COOP/COEP headers correct
- Verify guest Linux boots and shell is interactive
- Verify touch keyboard input works for terminal

**Out of scope:**
- Custom networking (whatever upstream uses, including Tailscale fail, is acceptable)
- Shared folder
- Custom disk image
- Pause/resume

**Exit criteria:**
- User can open app, boot reaches shell prompt, can type commands
- Document any CheerpX init errors or perf issues observed; these inform M1+

## M1: Custom disk image + scheme handler

**In scope:**
- `Dockerfile.disk` and build script producing `base.ext2`
- WebVMSchemeHandler with COOP/COEP and Range request support
- App bundles base.ext2; CheerpX loads it via `webvm:///disk/base.ext2`
- IDBDevice overlay working (persistence across app restarts)
- Split `/` and `/home` overlays
- Reset flows in UI

**Out of scope:**
- Networking changes
- Shared folder

**Exit criteria:**
- Base image includes Neovim; `nvim` launches at shell
- `apt install <package>` works (no network yet; or network via upstream's Tailscale if reachable)
- Reboot app; changes persist in overlay
- "Reset /" preserves home, and vice versa

## M2: Raw-socket network bridge

**In scope:**
- LocalWSServer and NetBridge Swift implementation
- CheerpX fork with P1 (networking transport replacement)
- Patched `cheerpx.js` bundled in app
- CONNECT/DATA/CLOSE ops (TCP only)
- Hostname resolution via NWConnection (no explicit RESOLVE op)

**Out of scope:**
- UDP
- LISTEN/ACCEPT
- IPv6 (accept if free, don't block on it)
- Reconnection logic beyond basic EPIPE on disconnect

**Exit criteria:**
- `curl https://example.com` from guest succeeds
- `apt update && apt install -y <package>` succeeds
- LSP servers (pyright, gopls) can install and reach internet
- No Tailscale account required, no external service dependency

## M3: 9P shared folder

**In scope:**
- NinePServer Swift implementation with required opcode set from `04-ninep-server.md`
- Security-scoped bookmark persistence
- UIDocumentPickerViewController for folder selection
- CheerpX fork P2 (9P mount support)
- Mount at `/mnt/host` automatically on VM boot if bookmark exists

**Out of scope:**
- Extended attributes (xattr)
- Advisory locks (flock)
- Symlinks (acceptable to ENOSYS)
- Performance optimization (caching, readahead)

**Exit criteria:**
- User picks folder in iOS Files app
- `ls /mnt/host` in guest shows folder contents
- `echo hello > /mnt/host/test.txt` creates file visible in iOS Files
- `vim /mnt/host/test.txt` opens, edits, saves correctly
- `git init && git commit` in `/mnt/host/repo` succeeds (exercises stat, readdir, small writes)
- Bookmark survives app relaunch

## M4: Pause/resume + app lifecycle

**In scope:**
- CheerpX fork P3 (pause/resume hooks)
- Swift observes foreground/background notifications
- Calls `pause()` before background, `resume()` on foreground
- Reconnection of both WS endpoints if closed during background
- User-visible "VM paused" indicator

**Out of scope:**
- Background execution entitlement (VM genuinely stops)
- Automatic state snapshots
- Migration between devices

**Exit criteria:**
- Background app for 5 minutes, resume: VM is in same state, shell responsive
- Active `curl` download interrupted by backgrounding: guest sees error, can retry
- Active `nvim` session in `/mnt/host`: on resume, buffer still open, can save

## M5: Read-only datasets

**In scope:**
- Additional ext2 images for bundled datasets
- Mount configuration for `/mnt/data/<n>`
- Build pipeline extended to pack datasets

**Out of scope:**
- User-provided datasets (would require Files app integration beyond folder share)
- On-demand download of datasets

**Exit criteria:**
- Datasets appear in `/mnt/data/` read-only
- Reading large files from datasets is fast (limited only by local disk speed)
- Writes fail cleanly with EROFS

## M6: Investigation milestone

See `08-investigation.md` for full scope.

**In scope:**
- Instrument PoC with tracing (9P op latencies, IDB read/write throughput, CheerpX block fetch rates)
- Run defined workload suite
- Produce written findings document recommending which direction (A, B, or C) to pursue, if any
- Do NOT implement any of the directions in this milestone

**Out of scope:**
- Implementation of findings (follows as separate milestones M7+)
- User-facing features

**Exit criteria:**
- Findings document committed
- Decision on whether to proceed with any direction
- If proceeding: subsequent milestones (M7+) defined with appropriate scope

## Cross-cutting: not in any milestone

These are explicitly excluded from the PoC-through-investigation arc. They may be future milestones.

- x86_64 guest support (blocked on CheerpX)
- GPU acceleration in guest (blocked on WebGPU from CheerpX)
- Multiple concurrent VMs
- VM state snapshotting / export / import
- BrowserEngineKit EU-only path
- Native (non-WebVM) Linux binary execution on iOS (would require a fundamentally different architecture)
- Remote VM access (SSH from other devices into the iPad VM)

## Ordering rationale

- M0 validates the platform before committing to any code
- M1 is the biggest infrastructure payload (scheme handler, build pipeline); nothing else depends on external services once done
- M2 before M3: networking is a more common need than shared folders, and simpler to validate
- M4 after M2/M3: lifecycle coordination requires both transports to be exercised
- M5 is additive and could move earlier; ordered after M4 for clean cumulative testing
- M6 requires M1-M5 complete to have meaningful data to investigate
