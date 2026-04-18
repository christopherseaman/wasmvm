# WebVM on iPad: Build Spec

## Project goal

Bring a full Linux development environment to iPad with no remote backend, no jailbreak, and no developer account gymnastics beyond standard App Store distribution. Specifically: run LazyVim (Neovim with plugins, LSP servers, treesitter) plus the usual shell toolchain (git, curl, python, build-essential, ripgrep, fd, tmux) on iPad, with files accessible to other iOS apps and network access that doesn't depend on a third-party VPN.

## Why this exists

iPad is a capable hardware platform trapped behind iOS app restrictions. Existing options all compromise:

- **SSH/mosh to a remote server** (Blink, Termius): requires always-on connectivity and paying for a server; latency affects interactive editing
- **iSH / a-Shell**: constrained userspace, no package manager that matches Linux, limited toolchain
- **WebVM via Safari browser**: works, but browser chrome is intrusive, no iOS Files integration, depends on Tailscale for networking, subject to Safari storage eviction
- **Full remote dev (Codespaces, Coder)**: same remote-dependence problem, requires subscription

The goal here is a **self-contained iPad app** that runs unmodified Linux x86 binaries locally via WebVM/CheerpX (WebAssembly x86 virtualization), with the iOS app providing the three things a raw WebVM-in-browser cannot:

1. **Networking** without depending on Tailscale or any external control plane
2. **Persistent storage** that isn't subject to Safari's opportunistic eviction
3. **File exchange** with iOS Files (Working Copy, iCloud Drive, share sheet, etc.)

## Non-goals

- Replacing desktop-class development for heavy workloads (compiling LLVM, running containers, training models). This is for editing, scripting, light builds, reading, note-taking.
- Supporting x86_64 Linux binaries. CheerpX is i386-only at time of writing. Accepted constraint.
- Background execution. iOS suspends apps; the VM suspends with the app. Acceptable tradeoff.
- EU-only BrowserEngineKit path with full JIT. Staying on WKWebView for broad distribution.

## Architectural stance

The iOS app is a **services provider** to the WASM VM, not merely a chrome around it. Two localhost WebSocket endpoints expose network egress (raw-socket-over-WS) and filesystem access (9P2000.L over WS). The VM runs patched CheerpX that speaks these protocols directly instead of Tailscale-over-WireGuard. Swift owns the security-scoped URLs, the NWConnection egress, and the disk image hosting; the WASM VM focuses on being a Linux.

This inverts the usual WebVM deployment (browser + cloud backends) into a single-process app where everything runs on-device. It also means any local-network-only iPad is a fully usable dev machine.

## What this spec covers

The spec is oriented around implementation, not narrative. It assumes familiarity with CheerpX/WebVM architecture, 9P2000.L, iOS app lifecycle, and Network.framework. It is deliberately terse on process and rich on technical specifics.

## Document map

- `01-architecture.md` - system diagram, component responsibilities, process model
- `02-ios-wrapper.md` - Swift app structure, WKWebView config, URL scheme handler, security-scoped bookmarks
- `03-net-bridge.md` - raw-socket-over-WebSocket protocol, NetBridge implementation, CheerpX fork points
- `04-ninep-server.md` - 9P2000.L server implementation, opcode coverage, FID lifecycle, security-scoped URL handling
- `05-storage.md` - block device stack, disk image provisioning, overlay strategy, bundled datasets
- `06-cheerpx-fork.md` - what needs to change upstream vs stay stock, patch surface
- `07-milestones.md` - ordered milestones with in/out-of-scope definition
- `08-investigation.md` - post-PoC investigation plan for persistent shared storage

Sketch code for NetBridge, NinePServer, LocalWSServer, and VMHost lives alongside in `code/` as reference implementations for the core Swift components.

## Non-goals for this document

- No time estimates, no user stories, no narrative process description
- No speculation about features past the investigation milestone
- No coverage of EU-specific BrowserEngineKit alternatives (WKWebView only)

## Assumed reader context

Familiar with CheerpX/WebVM architecture, 9P2000.L basics, iOS app lifecycle, Network.framework. Spec assumes Xcode 15+ toolchain and iOS 17+ deployment target (required for WKWebView COOP/COEP header support via WKURLSchemeHandler).
