#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${OUT_DIR:-${REPO_ROOT}/out}"
IMAGE_NAME="${1:-home-empty.ext2}"
SIZE="${2:-1G}"
IMAGE_PATH="${OUT_DIR}/${IMAGE_NAME}"

require_disk_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required tool: $1" >&2
        echo "  on macOS: brew install coreutils e2fsprogs   # then ensure they're on PATH" >&2
        echo "  or run this script from a Linux host / Docker container" >&2
        exit 1
    fi
}
require_disk_tool truncate
require_disk_tool mke2fs
if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
    sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
    echo "missing required tool: sha256sum or shasum" >&2; exit 1
fi
size_of() { wc -c <"$1" | tr -d '[:space:]'; }

mkdir -p "${OUT_DIR}"

echo "==> creating empty ${IMAGE_PATH} (${SIZE})"
rm -f "${IMAGE_PATH}"
truncate -s "${SIZE}" "${IMAGE_PATH}"
mke2fs -q -t ext2 -E root_owner=0:0 -L home "${IMAGE_PATH}"

HEX="$(sha256_of "${IMAGE_PATH}")"
printf '%s\n' "${HEX}" > "${IMAGE_PATH}.sha256"

BYTES="$(size_of "${IMAGE_PATH}")"
MIB=$(( BYTES / 1024 / 1024 ))
echo "==> done"
echo "    image:  ${IMAGE_PATH}"
echo "    size:   ${BYTES} bytes (${MIB} MiB)"
echo "    sha256: ${HEX}"
