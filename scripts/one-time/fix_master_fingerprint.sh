#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
. "${REPO_ROOT}/scripts/sh/maintainer_id.sh"
MASTER_FINGERPRINT_FILE="master_fingerprint.sha256"

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

read_repo_id_seed() {
    local seed
    seed="$(maintainer_current_id "${REPO_ROOT}" || true)"
    [ -n "${seed}" ] || fail "Missing SYNCPSS_MAINTAINER_ID. Set it from config/maintainer_id.sha256 or run bash scripts/sh/set_fingerprint.sh"
    printf '%s' "${seed}"
}

sha256_text() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

compute_master_fingerprint() {
    local payload
    payload="$(mktemp)"
    cat \
        "${REPO_ROOT}/bin/syncpss-linux-x86_64" \
        "${REPO_ROOT}/bin/install" \
        "${REPO_ROOT}/bin/installer.sh" \
        "${REPO_ROOT}/bin/uninstall_syncpss.sh" > "${payload}"
    sha256sum "${payload}" | awk '{print $1}'
    rm -f "${payload}"
}

main() {
    cd "${REPO_ROOT}"

    local seed seed_hash expected_hash fingerprint
    seed="$(read_repo_id_seed)"
    seed_hash="$(sha256_text "${seed}")"
    expected_hash="$(maintainer_expected_hash "${REPO_ROOT}")"
    [ "${seed_hash}" = "${expected_hash}" ] || fail "SYNCPSS_MAINTAINER_ID hash mismatch. Expected ${expected_hash} but found ${seed_hash}."

    fingerprint="$(compute_master_fingerprint)"
    mkdir -p "${REPO_ROOT}/bin"

    printf '%s  master_fingerprint.sha256\n' "${fingerprint}" > "${REPO_ROOT}/${MASTER_FINGERPRINT_FILE}"
    printf '%s  master_fingerprint.sha256\n' "${fingerprint}" > "${REPO_ROOT}/bin/${MASTER_FINGERPRINT_FILE}"

    log "Regenerated ${MASTER_FINGERPRINT_FILE}: ${fingerprint}"
    log "Wrote:"
    log "  ${REPO_ROOT}/${MASTER_FINGERPRINT_FILE}"
    log "  ${REPO_ROOT}/bin/${MASTER_FINGERPRINT_FILE}"
    log
    log "This prepares the repo for the next cd.bat run."
}

main "$@"
