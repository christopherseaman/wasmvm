# tools/ — disk image build pipeline (W3)

Builds the i386 ext2 images that ship inside the iOS app bundle and serve as
the base for the CheerpX root and `/home` overlays.

## Files

| File | Purpose |
|---|---|
| `Dockerfile.disk` | i386 Debian bookworm-slim rootfs: MVP package list, `user` account with NOPASSWD sudo, LazyVim starter copied into `/etc/skel/.config/nvim`. |
| `build-disk.sh` | Runs the Docker build, exports the rootfs, scrubs ephemeral state, runs `mke2fs` to produce `out/base.ext2` + `out/base.ext2.sha256`. |
| `build-home-empty.sh` | Produces an empty 1 GiB ext2 at `out/home-empty.ext2` for the `/home` overlay base. |
| `disk-smoke.sh` | Loop-mounts a built image read-only and asserts required binaries, LazyVim skel, and the `user` account/NOPASSWD sudoers entry are present. |

## Order of operations

```bash
# from repo root
tools/build-disk.sh           # → out/base.ext2 (+ .sha256)
tools/build-home-empty.sh     # → out/home-empty.ext2 (+ .sha256)
tools/disk-smoke.sh           # asserts out/base.ext2 is well-formed
```

All scripts run with sensible defaults; positional args allow overrides:

```bash
tools/build-disk.sh [image_name] [size] [dockerfile]
tools/build-home-empty.sh [image_name] [size]
tools/disk-smoke.sh [image_path]
```

`OUT_DIR` env var overrides the output directory (default `<repo>/out`).

## Requirements

Host tools: `docker`, `tar`, `truncate`, `mke2fs` (e2fsprogs), `sha256sum`, `stat`,
`mount`/`umount` (with sudo or root for the smoke test), `mktemp`.

`build-disk.sh` requires Docker with `linux/386` platform support. On a
non-x86 host (e.g. Apple Silicon) ensure binfmt/qemu emulation is configured
(`docker run --privileged --rm tonistiigi/binfmt --install all` once).

The smoke test loop-mounts the produced ext2; on a Mac dev box use a Linux VM
or a Linux CI runner (macOS lacks loop-mount + ext2 support out of the box).
On Linux it works directly with sudo.

## Reproducibility notes

- `Dockerfile.disk` pins to `i386/debian:bookworm-slim` (tag, not digest).
  Tag was chosen over digest because the i386 mirror rotates manifests
  frequently and a stale digest would block rebuilds. Apt package versions
  inside the image dominate determinism; see `dpkg -l` inside the built
  rootfs for the actual frozen state.
- `build-disk.sh` clears `/var/cache/apt`, `/var/lib/apt/lists`, `/var/log/*`,
  `/tmp/*`, `~/.cache`, and `/.dockerenv` from the rootfs before `mke2fs`.
- The Docker image is tagged with the current git short-SHA (or a UTC
  timestamp if not in a git repo) so successive builds don't clobber each
  other in the local Docker cache.
- `out/base.ext2.sha256` contains a single line: the hex digest only (no
  filename). This is what the JS-side overlay invalidator compares against
  per `spec/05-storage.md` §Update strategy.

## Size budget

Target: ext2 ≤ 500 MiB to stay under the App Store reviewer-flag threshold.
`build-disk.sh` prints final size and warns to stderr if it exceeds 500 MiB.
If exceeded, first-line trims per `spec/05-storage.md` Risk #4: drop
`build-essential`, then consider Alpine.

## LazyVim skel note

The upstream `LazyVim/starter` repo populates `~/.config/nvim/lua/{config,plugins}`
only; the `lazyvim` Lua module itself is installed by `lazy.nvim` on first
`nvim` launch (network-dependent). The smoke test therefore asserts
`lua/config` exists in the skel rather than `lua/lazyvim`.

## CI

Designed to run on a Linux x86_64 GitHub Actions runner with `docker` and
`e2fsprogs` available. Run order: build-disk, build-home-empty, disk-smoke.
Cache the resulting `out/*.ext2` as workflow artifacts for downstream Swift
and JS test jobs.
