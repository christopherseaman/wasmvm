# 08 - Investigation: Persistent Shared Storage

## Motivating question

Given the PoC has `/mnt/host` available as a 9P mount and `~` as an IDBDevice-backed overlay, **where should actual project work live?**

Constraints:
- Editing in `~` (fast) means files are invisible to iOS Files app
- Editing in `/mnt/host` (visible) means 9P overhead on every stat/read

This milestone is an **investigation**, not an implementation. It produces a findings document and a recommendation.

## Direction candidates

### Direction A: Swift-backed block overlay + File Provider

Replace IDBDevice with a native file that Swift owns. On top of that, implement `NSFileProviderExtension` that parses the ext2 overlay + base stack to surface individual files to iOS.

**Pros:**
- VM home stays native-speed ext2
- iOS apps can read/write VM files via Files app
- Overlay file can be backed up, versioned, exported

**Cons:**
- Requires ext2 parsing in Swift (read, then later write)
- File Provider coordination with running VM is non-trivial
- Concurrent write semantics need design

### Direction B: Heavily cached 9P

Keep the 9P architecture but add aggressive caching in the Swift NinePServer: directory stat cache, attribute cache with invalidation, readahead on sequential reads.

**Pros:**
- Single architecture, no block-level ext2 work
- Incremental improvement path

**Cons:**
- Cache invalidation is famously hard
- Fundamental RTT cost remains
- May not close enough of the gap for LSP/treesitter workloads

### Direction C: Bidirectional sync

Use rsync/Syncthing/custom sync between `~/projects` and a `/mnt/host/projects` folder. Both fast, neither live.

**Pros:**
- Both sides native speed
- Conceptually simple

**Cons:**
- Sync staleness
- Conflict resolution UX
- Editing same file from both sides (iOS app + VM) is a mess

### Direction D: Accept the status quo

Document limitations, ship PoC, move on. User keeps occasional-transfer files in `/mnt/host`, actual work in `~`.

**Pros:**
- Zero additional work
- Honest about tradeoffs

**Cons:**
- Reduced utility if users want to use VSCode on Mac to edit the same files they edit in Neovim on iPad

## Instrumentation

Before evaluating directions, PoC must be instrumented to answer "where does time actually go?" Instrument:

### In Swift (NinePServer)
- Per-opcode latency histograms (p50, p95, p99)
- Opcode frequency counts
- Security-scoped URL access time (start/stop overhead)
- FileHandle I/O time vs. 9P framing time

### In Swift (NetBridge)
- Per-connection throughput
- Connection setup latency
- WS frame size distribution

### In Swift (WKURLSchemeHandler)
- Disk image Range request frequency and size
- Serve latency

### In JS (patched CheerpX)
- IDBDevice read/write operation rates
- Block cache hit/miss rates on base disk
- Guest syscall rates that trigger network or 9P traffic

All metrics logged to `os.Logger` with a dedicated subsystem; sampled via Instruments or exported to a file for analysis.

## Workload suite

Run each workload with and without various mount configurations. Capture metrics above.

### Workload 1: Neovim cold open, large project
- Guest path: `/home/user/testrepo` (IDB overlay)
- Guest path: `/mnt/host/testrepo` (9P mount)
- Test repo: 10,000 files, ~50k lines of Python
- Command: `cd <path> && time nvim -c 'quit'`
- Measures: LazyVim startup + file scan cost

### Workload 2: Telescope fuzzy find
- Same test repo
- Command: within nvim, `:Telescope find_files` and scroll through results
- Measures: interactive stat/read rate

### Workload 3: LSP initialization
- Same test repo
- Command: open a .py file with pyright LSP active, wait for "ready"
- Measures: indexing cost, workspace scan

### Workload 4: Git operations
- Same test repo, initialized as git
- Commands: `git status`, `git log --oneline -100`, `git diff HEAD~10`
- Measures: git's heavy stat patterns

### Workload 5: Save cycle
- Open a 500-line file, edit, save
- Measures: buffer write + possible swap file activity

### Workload 6: Install cycle
- `npm install` of a typical Node project (~500 packages)
- Measures: rapid small-file creation

Each workload measured:
- On IDB overlay home (`~/testrepo`): **fast baseline**
- On 9P mount (`/mnt/host/testrepo`): **current shared-folder perf**
- On Swift-backed overlay (Direction A prototype, if built): **native ext2 under Swift ownership**

## Evaluation criteria

For each direction (A, B, C, D), evaluate against:

### Performance
- Ratio of mount perf to IDB baseline across all workloads
- Must be <2x on W1/W2/W4 to be considered viable
- <3x acceptable for W3/W6 (one-time costs)
- Anything >5x on interactive paths rules out the direction

### Implementation cost
- Lines of code (rough)
- External dependencies
- CheerpX patch surface

### Correctness risk
- Concurrent write safety (for A, if File Provider runs alongside VM)
- Cache coherence (for B)
- Sync conflicts (for C)

### User-facing complexity
- Does the user need to understand "which folder is fast"?
- Does the user need to configure sync?
- Does the user need to resolve conflicts?

## Pre-investigation hypothesis

State upfront to allow falsification:

- **W1-W4 on 9P will be 5-20x slower than IDB** based on ~1ms RTT per opcode × thousands of opcodes
- **Direction B caching will help W4 (git status) significantly but won't close the gap on W1/W2 (fresh opens)**
- **Direction A, if built, will match IDB perf for W1-W6 since guest sees native ext2**
- **File Provider implementation risk is the real blocker for Direction A**, not the perf benefit

If hypothesis holds, recommendation is likely: build Direction A only if File Provider is a user requirement; otherwise Direction D.

## Findings document template

Investigation produces `FINDINGS.md` with sections:

1. Instrumentation results (numbers per workload per configuration)
2. Hypothesis validation (did predictions hold?)
3. Direction recommendation with justification
4. If recommending A/B/C: implementation plan at milestone-spec level
5. If recommending D: documented limitations for user guidance

## What is not in this investigation

- Deciding *when* to ship. Decision is "which direction" or "none," not scheduling.
- Prototyping multiple directions in parallel. Prototype only what's needed for measurement (e.g., a minimal Swift-backed block device for Direction A numbers).
- User research. This is a technical investigation; assume one target user (the developer) with defined workflow.
