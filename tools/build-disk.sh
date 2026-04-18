#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${OUT_DIR:-${REPO_ROOT}/out}"
IMAGE_NAME="${1:-base.ext2}"
SIZE="${2:-2G}"
DOCKERFILE="${3:-${SCRIPT_DIR}/Dockerfile.disk}"
ROOTFS_DIR="${OUT_DIR}/rootfs"
IMAGE_PATH="${OUT_DIR}/${IMAGE_NAME}"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
# truncate and mke2fs are GNU/Linux native; not on macOS by default. On macOS
# install with `brew install coreutils e2fsprogs` (and ensure they're on PATH
# without the `g` prefix), or run this script from a Linux VM/CI.
require_disk_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required tool: $1" >&2
        echo "  on macOS: brew install coreutils e2fsprogs   # then ensure they're on PATH" >&2
        echo "  or run this script from a Linux host / Docker container" >&2
        exit 1
    fi
}
require docker
require tar
require_disk_tool truncate
require_disk_tool mke2fs
# sha256: GNU sha256sum or BSD/macOS shasum.
if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "missing required tool: sha256sum or shasum" >&2; exit 1
fi
# Portable file size; GNU stat uses -c, BSD uses -f. wc -c works everywhere.
size_of() { wc -c <"$1" | tr -d '[:space:]'; }

if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --short HEAD >/dev/null 2>&1; then
    TAG="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
else
    TAG="$(date -u +%Y%m%d-%H%M%S)"
fi
IMAGE_TAG="webvm-disk-builder:${TAG}"

mkdir -p "${OUT_DIR}"

echo "==> docker build (${IMAGE_TAG})"
docker build --platform=linux/386 -t "${IMAGE_TAG}" -f "${DOCKERFILE}" "${REPO_ROOT}"

CONTAINER="webvm-disk-export-$$"
echo "==> docker create ${CONTAINER}"
docker create --name "${CONTAINER}" "${IMAGE_TAG}" >/dev/null
trap 'docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true' EXIT

echo "==> exporting rootfs to ${ROOTFS_DIR}"
rm -rf "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"
docker export "${CONTAINER}" | tar -C "${ROOTFS_DIR}" -xf -

echo "==> scrubbing ephemeral state from rootfs"
rm -rf \
    "${ROOTFS_DIR}/var/cache/apt/"* \
    "${ROOTFS_DIR}/var/lib/apt/lists/"* \
    "${ROOTFS_DIR}/var/log/"* \
    "${ROOTFS_DIR}/tmp/"* \
    "${ROOTFS_DIR}/root/.cache" \
    "${ROOTFS_DIR}/.dockerenv"

echo "==> creating ${IMAGE_PATH} (${SIZE})"
rm -f "${IMAGE_PATH}"
truncate -s "${SIZE}" "${IMAGE_PATH}"
mke2fs -q -t ext2 -E root_owner=0:0 -d "${ROOTFS_DIR}" "${IMAGE_PATH}"

echo "==> hashing"
HEX="$(sha256_of "${IMAGE_PATH}")"
printf '%s\n' "${HEX}" > "${IMAGE_PATH}.sha256"

BYTES="$(size_of "${IMAGE_PATH}")"
MIB=$(( BYTES / 1024 / 1024 ))
echo "==> done"
echo "    image:  ${IMAGE_PATH}"
echo "    size:   ${BYTES} bytes (${MIB} MiB)"
echo "    sha256: ${HEX}"
if [ "${MIB}" -gt 500 ]; then
    echo "    NOTE: image exceeds 500 MiB budget" >&2
fi
