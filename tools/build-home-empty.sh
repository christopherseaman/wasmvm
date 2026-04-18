#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${OUT_DIR:-${REPO_ROOT}/out}"
IMAGE_NAME="${1:-home-empty.ext2}"
SIZE="${2:-1G}"
IMAGE_PATH="${OUT_DIR}/${IMAGE_NAME}"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
require truncate
require mke2fs
require sha256sum
require stat

mkdir -p "${OUT_DIR}"

echo "==> creating empty ${IMAGE_PATH} (${SIZE})"
rm -f "${IMAGE_PATH}"
truncate -s "${SIZE}" "${IMAGE_PATH}"
mke2fs -q -t ext2 -E root_owner=0:0 -L home "${IMAGE_PATH}"

HEX="$(sha256sum "${IMAGE_PATH}" | awk '{print $1}')"
printf '%s\n' "${HEX}" > "${IMAGE_PATH}.sha256"

BYTES="$(stat -c '%s' "${IMAGE_PATH}")"
MIB=$(( BYTES / 1024 / 1024 ))
echo "==> done"
echo "    image:  ${IMAGE_PATH}"
echo "    size:   ${BYTES} bytes (${MIB} MiB)"
echo "    sha256: ${HEX}"
