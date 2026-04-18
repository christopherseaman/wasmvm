#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${1:-${REPO_ROOT}/out/base.ext2}"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
require mount
require umount
require mktemp

if [ ! -f "${IMAGE}" ]; then
    echo "FAIL: image not found: ${IMAGE}" >&2
    exit 1
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    require sudo
    SUDO="sudo"
fi

MNT="$(mktemp -d -t wasmvm-disk-smoke.XXXXXX)"
cleanup() {
    ${SUDO} umount "${MNT}" >/dev/null 2>&1 || true
    rmdir "${MNT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> mounting ${IMAGE} (ro,loop) at ${MNT}"
${SUDO} mount -o ro,loop "${IMAGE}" "${MNT}"

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_bin() {
    local name="$1"
    for d in usr/bin bin usr/local/bin usr/sbin sbin; do
        if [ -e "${MNT}/${d}/${name}" ]; then
            echo "  ok: ${name} at /${d}/${name}"
            return 0
        fi
    done
    fail "binary not found: ${name}"
}

assert_path() {
    local p="$1"
    [ -e "${MNT}/${p}" ] || fail "path missing: /${p}"
    echo "  ok: /${p}"
}

assert_file_contains() {
    local p="$1" pat="$2"
    [ -f "${MNT}/${p}" ] || fail "file missing: /${p}"
    grep -q -- "${pat}" "${MNT}/${p}" || fail "/${p} does not contain: ${pat}"
    echo "  ok: /${p} contains ${pat}"
}

echo "==> checking required binaries"
assert_bin nvim
assert_bin git
assert_bin curl
assert_bin python3
assert_bin cc
assert_bin tmux
assert_bin sudo

echo "==> checking ripgrep (rg) and fd (fd / fdfind)"
if [ -e "${MNT}/usr/bin/rg" ] || [ -e "${MNT}/bin/rg" ] || [ -e "${MNT}/usr/local/bin/rg" ]; then
    echo "  ok: rg present"
else
    fail "binary not found: rg"
fi
if [ -e "${MNT}/usr/bin/fd" ] || [ -e "${MNT}/usr/bin/fdfind" ] \
   || [ -e "${MNT}/bin/fd" ] || [ -e "${MNT}/bin/fdfind" ] \
   || [ -e "${MNT}/usr/local/bin/fd" ]; then
    echo "  ok: fd/fdfind present"
else
    fail "binary not found: fd or fdfind"
fi

echo "==> checking LazyVim skel"
assert_path etc/skel/.config/nvim
assert_path etc/skel/.config/nvim/lua/config

echo "==> checking user account"
assert_file_contains etc/passwd '^user:'
assert_file_contains etc/sudoers.d/user 'NOPASSWD'

echo "OK"
