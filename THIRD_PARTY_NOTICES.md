# Third-Party Notices

The MIT [`LICENSE`](LICENSE) covers the original code authored for this
project. It does **not** cover bundled or fetched third-party software, which
keeps its own license and notices.

## CheerpX

**Where:** `webvm-harness/vendor/cheerpx/` after running
`tools/vendor-cheerpx.sh`. **Not committed to this repo** — fetched from the
upstream CDN on each developer's machine.

**Licence:** Proprietary, [Leaning Technologies Ltd. tiered Community/Commercial
licence](https://cheerpx.io/docs/licensing). The full licence text ships
inside the vendored package as `webvm-harness/vendor/cheerpx/LICENSE.txt`.

**Practical scope** (paraphrased — read the licence text directly for anything
load-bearing):

- §1.4(a): individuals may use CheerpX for any purpose, including personal
  projects (revenue or not), open-source projects, and public-facing
  applications.
- §1.4(b): businesses may only use CheerpX for technical evaluation/testing
  unless they hold a Commercial Licence.
- §2.1(i): the licensee may not provide or otherwise make the Software
  available to third parties without prior written consent. This is why we
  do not commit the binaries to git — see [`DECISIONS.md`](DECISIONS.md) D1.
- §2.1(h): copies of the Software must carry the upstream copyright notice
  (`vendor/cheerpx/LICENSE.txt`).

If you fork this project for any business or commercial purpose, contact
Leaning Technologies for a Commercial Licence before deploying.

## LazyVim

**Where:** Baked into the disk image at `/etc/skel/.config/nvim` by
`tools/Dockerfile.disk`.

**Licence:** [Apache-2.0](https://github.com/LazyVim/LazyVim/blob/main/LICENSE).

The starter is cloned from `https://github.com/LazyVim/starter` at
disk-image-build time; its `.git` directory is stripped before the rootfs is
turned into ext2.

## Debian and the package set inside the disk image

**Where:** Inside `out/base.ext2` after running `tools/build-disk.sh`. The
image is built from `i386/debian:bookworm-slim` and adds the package set
listed in `tools/Dockerfile.disk` (neovim, git, curl, python3,
build-essential, ripgrep, fd-find, tmux, sudo, etc.).

**Licences:** Each Debian package keeps its upstream licence. For the exact
license inventory of a built image, run
`dpkg -l` inside the rootfs before `mke2fs`, or mount and inspect the built
image:

```bash
sudo mount -o ro,loop out/base.ext2 /mnt/x
ls /mnt/x/usr/share/doc/*/copyright
```

## Telegraph (Swift dependency)

**Where:** SwiftPM dependency in `Package.swift`; resolved into
`.build/checkouts/Telegraph/` on `swift package resolve`.

**Licence:** [MIT](https://github.com/Building42/Telegraph/blob/master/LICENSE).
Transitively brings in CocoaAsyncSocket (MIT) and HTTPParserC (MIT).

## xterm.js + addons (npm dependencies)

**Where:** `webvm-harness/node_modules/@xterm/xterm/`,
`webvm-harness/node_modules/@xterm/addon-fit/` after `npm install`.

**Licence:** [MIT](https://github.com/xtermjs/xterm.js/blob/master/LICENSE).

## idb (npm dependency)

**Licence:** [ISC](https://github.com/jakearchibald/idb/blob/main/LICENSE).
