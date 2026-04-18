#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Pinned default. Bump deliberately — the harness/shim was tested against this.
# Override by passing a version arg, or by setting CHEERPX_VERSION in the env.
PINNED_VERSION="1.2.11"

VERSION="${1:-${CHEERPX_VERSION:-${PINNED_VERSION}}}"
CDN_BASE="${CDN_BASE:-https://cxrtnc.leaningtech.com}"
NPM_PKG="${NPM_PKG:-@leaningtech/cheerpx}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/webvm-harness/vendor/cheerpx}"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/.temp/vendor-cheerpx}"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
require curl
require sha256sum
require npm
require tar

echo "vendoring ${NPM_PKG}@${VERSION} -> ${OUT_DIR}" >&2

CDN_URL="${CDN_BASE}/${VERSION}"

mkdir -p "${WORK_DIR}" "${OUT_DIR}/tun"
rm -f "${OUT_DIR}"/*.js "${OUT_DIR}"/*.wasm "${OUT_DIR}"/*.d.ts "${OUT_DIR}/tun"/* 2>/dev/null || true

fetch_npm_typings() {
    local pkg_dir="${WORK_DIR}/npm"
    rm -rf "${pkg_dir}"
    mkdir -p "${pkg_dir}"
    (
        cd "${pkg_dir}"
        local tarball
        tarball="$(npm pack --silent "${NPM_PKG}@${VERSION}" 2>/dev/null)"
        tar xzf "${tarball}"
    )
    cp "${pkg_dir}/package/index.d.ts" "${OUT_DIR}/index.d.ts"
    cp "${pkg_dir}/package/LICENSE.txt" "${OUT_DIR}/LICENSE.txt"
    cp "${pkg_dir}/package/README.md"   "${OUT_DIR}/README.npm.md"
}

fetch_one() {
    local rel="$1"
    local dest="${OUT_DIR}/${rel}"
    mkdir -p "$(dirname "${dest}")"
    if [[ -f "${dest}" ]]; then
        return 0
    fi
    local url="${CDN_URL}/${rel}"
    local code
    code="$(curl -sSL -o "${dest}.tmp" -w "%{http_code}" "${url}")"
    case "${code}" in
        200)
            mv "${dest}.tmp" "${dest}"
            echo "  fetched ${rel} ($(stat -c %s "${dest}") bytes)" >&2
            ;;
        204)
            rm -f "${dest}.tmp"
            echo "  skipped ${rel} (HTTP 204 placeholder)" >&2
            return 1
            ;;
        *)
            rm -f "${dest}.tmp"
            echo "  ERROR ${rel}: HTTP ${code}" >&2
            return 2
            ;;
    esac
}

extract_refs() {
    local file="$1"
    grep -oE "['\"][^'\"]+\\.(js|wasm)['\"]" "${file}" \
        | sed -E "s/^['\"]//;s/['\"]$//" \
        | grep -E '[A-Za-z0-9_]' \
        | grep -vE '^\.(js|wasm)$' \
        | sort -u
}

resolve_ref() {
    local from_rel="$1"
    local ref="$2"
    local from_dir
    from_dir="$(dirname "${from_rel}")"
    case "${ref}" in
        /*)
            echo "${ref#/}"
            ;;
        ./*|../*)
            if [[ "${from_dir}" == "." ]]; then
                echo "${ref#./}"
            else
                echo "${from_dir}/${ref}"
            fi
            ;;
        *)
            if [[ "${from_dir}" == "." ]]; then
                echo "${ref}"
            else
                echo "${from_dir}/${ref}"
            fi
            ;;
    esac
}

queue=()
seen=()
contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

enqueue() {
    local rel="$1"
    if ! contains "${rel}" "${seen[@]+"${seen[@]}"}"; then
        seen+=("${rel}")
        queue+=("${rel}")
    fi
}

echo "==> CheerpX ${VERSION} from ${CDN_URL}" >&2
fetch_npm_typings

enqueue "cx.esm.js"

while ((${#queue[@]} > 0)); do
    rel="${queue[0]}"
    queue=("${queue[@]:1}")

    if ! fetch_one "${rel}"; then
        continue
    fi

    case "${rel}" in
        *.js)
            while IFS= read -r ref; do
                [[ -z "${ref}" ]] && continue
                resolved="$(resolve_ref "${rel}" "${ref}")"
                resolved="${resolved#./}"
                if [[ "${resolved}" == */* ]]; then
                    resolved="$(realpath -m --relative-to=. "${resolved}")"
                fi
                enqueue "${resolved}"
            done < <(extract_refs "${OUT_DIR}/${rel}")
            ;;
    esac
done

echo "==> rewriting absolute CDN URLs to relative paths" >&2
files_to_rewrite=()
while IFS= read -r f; do
    files_to_rewrite+=("${f}")
done < <(grep -rlE "https?://cxrtnc\\.leaningtech\\.com" "${OUT_DIR}" 2>/dev/null || true)
for f in "${files_to_rewrite[@]+"${files_to_rewrite[@]}"}"; do
    sed -i -E "s#https?://cxrtnc\\.leaningtech\\.com/${VERSION}/##g; s#https?://cxrtnc\\.leaningtech\\.com/##g" "${f}"
    echo "  rewrote ${f#${OUT_DIR}/}" >&2
done

echo "==> writing CHEERPX_VERSION.md" >&2
manifest="${OUT_DIR}/CHEERPX_VERSION.md"
{
    echo "# CheerpX vendored runtime"
    echo
    echo "- pinned version: \`${VERSION}\`"
    echo "- npm package: \`${NPM_PKG}@${VERSION}\`"
    echo "- CDN base: ${CDN_URL}/"
    echo "- vendored on: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- vendor script: \`tools/vendor-cheerpx.sh\`"
    echo
    echo "## Files (sha256)"
    echo
    echo '| Path | Size | sha256 |'
    echo '|---|---:|---|'
    (
        cd "${OUT_DIR}"
        find . -type f \( -name '*.js' -o -name '*.wasm' -o -name '*.d.ts' \) | sort | while read -r f; do
            f="${f#./}"
            size="$(stat -c %s "${f}")"
            sum="$(sha256sum "${f}" | awk '{print $1}')"
            echo "| \`${f}\` | ${size} | \`${sum}\` |"
        done
    )
    echo
    echo "## Provenance"
    echo
    echo "- \`index.d.ts\`, \`LICENSE.txt\`, \`README.npm.md\` from \`npm pack ${NPM_PKG}@${VERSION}\`"
    echo "- everything else from \`${CDN_URL}/<path>\`"
    echo
    echo "## Notes"
    echo
    echo "- \`fail.wasm\` and \`dump.wasm\` are referenced by string literals but the CDN returns HTTP 204 (no content) — they are intentional placeholders for runtime error fallbacks and are skipped here."
    echo "- All absolute \`https://cxrtnc.leaningtech.com/${VERSION}/...\` references inside \`cx.esm.js\` have been rewritten to relative paths so the runtime loads from the same origin (required for COEP/SharedArrayBuffer)."
} > "${manifest}"

echo "==> done. ${#seen[@]} files vendored under ${OUT_DIR}/" >&2
