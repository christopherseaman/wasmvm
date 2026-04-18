# 05 - Storage

## Block device stack

### Mount layout

```
/          ext2   OverlayDevice(HttpBytesDevice("webvm:///disk/base.ext2"), IDBDevice("root-overlay"))
/home      ext2   OverlayDevice(DataDevice(empty 1GB ext2), IDBDevice("home-overlay"))
/mnt/data  ext2   HttpBytesDevice("webvm:///datasets/data.ext2")   [read-only]
/mnt/host  9p     ws://127.0.0.1:8081/9p                           [security-scoped folder]
/dev       devs   (built-in)
/proc      proc   (built-in)
/sys       sysfs  (built-in, limited)
/tmp       tmpfs  (built-in)
```

### Rationale for split `/` and `/home` overlays

- "Reset VM" wipes `/` overlay only; user data in `/home` preserved
- "Reset home" wipes `/home` overlay only; installed packages retained
- IDBDevice instances are keyed by name; Swift UI can target each independently
- Costs: two overlays instead of one, negligible

## Base ext2 image

### Contents

- Debian or Alpine minimal rootfs for i386 (CheerpX does not support x86_64 at time of writing)
- Preinstalled: neovim, git, curl, python3, build-essential basics, ripgrep, fd, tmux
- User account `user` with passwordless sudo (required by WebVM convention)
- LazyVim preinstalled in `/etc/skel/.config/nvim`, copied to `~user` on first boot
- Locale configured (en_US.UTF-8)

### Build via Dockerfile

Follow CheerpX's custom-disk-images tutorial. Key constraints:
- `--platform=linux/386` on FROM line
- Dockerfile ends with user creation and skel copy
- `mke2fs -t ext2 -d rootfs_dir base.ext2 2G` to convert container contents to ext2

Build artifact committed to `Resources/disk/base.ext2`. App bundle size impact: ~500-800 MiB depending on preinstalled packages.

### Update strategy

- Base image updates require app update via App Store
- On first boot after update, if overlay exists, it is preserved (blocks still valid as long as base file layout for unchanged files hasn't moved - ext2 is stable on that front)
- Overlay blocks pointing to files that moved or were deleted in new base will cause silent corruption
- **Mitigation:** version the base image; invalidate overlay on version mismatch

Version check: store base image hash in overlay metadata. On CheerpX init:
```js
const baseHash = await fetch("webvm:///disk/base.ext2.sha256").then(r => r.text());
const stored = await idbDevice.getMetadata("base_hash");
if (stored !== baseHash) {
    await idbDevice.clear();
    await idbDevice.setMetadata("base_hash", baseHash);
}
```

This requires a small `setMetadata`/`getMetadata` extension to IDBDevice. If unavailable, store in a separate IDB keyspace.

## HttpBytesDevice via WKURLSchemeHandler

### Range request handling

WKURLSchemeHandler implementation:

```swift
func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    let request = urlSchemeTask.request
    guard let url = request.url else { return }
    
    // Route by path
    switch url.path {
    case "/disk/base.ext2":
        serveFile(at: diskImageURL, request: request, task: urlSchemeTask)
    case "/datasets/...":
        ...
    default:
        serveBundleResource(url: url, task: urlSchemeTask)
    }
}

func serveFile(at fileURL: URL, request: URLRequest, task: WKURLSchemeTask) {
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: fileURL) }
    catch { task.didFailWithError(error); return }
    defer { try? handle.close() }

    let totalSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    
    if let rangeHeader = request.value(forHTTPHeaderField: "Range") {
        let (start, end) = parseRange(rangeHeader, totalSize: totalSize)
        try? handle.seek(toOffset: UInt64(start))
        let data = try? handle.read(upToCount: end - start + 1)
        
        let headers = [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(data?.count ?? 0)",
            "Content-Range": "bytes \(start)-\(end)/\(totalSize)",
            "Accept-Ranges": "bytes",
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
        ]
        let response = HTTPURLResponse(url: request.url!, statusCode: 206,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        if let data = data { task.didReceive(data) }
        task.didFinish()
    } else {
        // Full-file request; rare for ext2 but possible during init
        let data = try? handle.readToEnd()
        let headers = [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(totalSize)",
            "Accept-Ranges": "bytes",
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
        ]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        if let data = data { task.didReceive(data) }
        task.didFinish()
    }
}
```

### Range parsing

Handle these formats:
- `bytes=0-1023` (first 1024 bytes)
- `bytes=1024-` (from 1024 to EOF)
- `bytes=-1024` (last 1024 bytes)

HttpBytesDevice in practice only sends the first form.

### Multi-range

Not needed; CheerpX issues single-range requests.

## IDBDevice (stock)

No changes from upstream CheerpX. IndexedDB is scoped to the WKWebView's origin (derived from `webvm://`), so storage is per-app-install. Not visible to other apps.

### Quota

WKWebView IndexedDB on iOS:
- Default quota varies; typically 50MB-1GB depending on total device free space
- Grows on demand without prompting up to some limit
- Eviction: WebKit may evict origin data when device runs low on storage
- Mitigation for eviction: `navigator.storage.persist()` request. Unclear if honored on iOS.

For PoC, accept default behavior. Investigation milestone evaluates whether Direction A (Swift-backed overlay) is needed.

## Bundled datasets

### Use case

User wants read-only large files (e.g., training datasets, reference corpora, package caches) available inside the VM without routing through 9P.

### Implementation

- Build ext2 images for each dataset: `mke2fs -t ext2 -d dataset_dir dataset.ext2 <size>`
- Place in `Resources/datasets/` in app bundle
- Mount at predictable paths in guest: `/mnt/data/<name>`
- Served via same WKURLSchemeHandler with Range support

### Size considerations

- App bundle size on App Store: IPA up to 4 GiB technically, reviewer-flagged above 500 MiB
- On-device unpacked size: no per-app limit beyond device free space
- If dataset > 1 GiB, ship as App Store asset pack (on-demand resource) rather than bundled

### Mount config

```javascript
const datasets = [
    { name: "corpus", path: "/mnt/data/corpus" },
    // ...
];

for (const ds of datasets) {
    const dev = await CheerpX.HttpBytesDevice.create(`webvm:///datasets/${ds.name}.ext2`);
    mounts.push({ type: "ext2", path: ds.path, dev, readonly: true });
}
```

**Verify:** CheerpX mount options support `readonly: true`. If not, mount as overlay with `DataDevice` stub writable layer (writes discarded on unmount).

## Disk image tooling

### Build script

`tools/build-disk.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${1:-base.ext2}"
SIZE="${2:-2G}"
DOCKERFILE="${3:-Dockerfile.disk}"

docker build --platform=linux/386 -t webvm-disk-builder -f "$DOCKERFILE" .
docker create --name disk-export webvm-disk-builder
rm -rf ./rootfs
mkdir ./rootfs
docker export disk-export | tar -C ./rootfs -xf -
docker rm disk-export

truncate -s "$SIZE" "$IMAGE_NAME"
mke2fs -t ext2 -d ./rootfs "$IMAGE_NAME"
sha256sum "$IMAGE_NAME" > "${IMAGE_NAME}.sha256"
```

### Dockerfile.disk skeleton

```dockerfile
FROM --platform=linux/386 i386/debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        neovim git curl ca-certificates python3 python3-pip \
        build-essential ripgrep fd-find tmux \
        locales sudo \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

RUN useradd -m -s /bin/bash -G sudo user && \
    echo 'user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/user

# LazyVim preinstall in skel
USER user
RUN git clone https://github.com/LazyVim/starter /home/user/.config/nvim && \
    rm -rf /home/user/.config/nvim/.git
USER root
RUN cp -r /home/user/.config /etc/skel/

WORKDIR /home/user
```

Committed in `tools/` with README explaining the build flow.

## Reset flows

### Reset `/` (system)

```javascript
await idbDevice_root.clear();
location.reload();
```

Preserves `/home` overlay. Reapplies base image state; any `apt install` is gone.

### Reset `/home` (user data)

```javascript
await idbDevice_home.clear();
location.reload();
```

Preserves `/` overlay. User's files, shell history, nvim state all gone.

### Full reset

Both clears, plus optionally delete any IDBDevice instances for datasets. UI presents as "Reset everything" with explicit confirmation.
