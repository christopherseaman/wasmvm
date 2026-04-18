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
require docker
require tar
require truncate
require mke2fs
require sha256sum
require stat

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
HEX="$(sha256sum "${IMAGE_PATH}" | awk '{print $1}')"
printf '%s\n' "${HEX}" > "${IMAGE_PATH}.sha256"

BYTES="$(stat -c '%s' "${IMAGE_PATH}")"
MIB=$(( BYTES / 1024 / 1024 ))
echo "==> done"
echo "    image:  ${IMAGE_PATH}"
echo "    size:   ${BYTES} bytes (${MIB} MiB)"
echo "    sha256: ${HEX}"
if [ "${MIB}" -gt 500 ]; then
    echo "    NOTE: image exceeds 500 MiB budget" >&2
fi
