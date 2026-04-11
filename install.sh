#!/usr/bin/env bash
set -euo pipefail

REPO="KffeePt/syncpss"
GITHUB_API_URL="https://api.github.com/repos/${REPO}"
TARGET="${HOME}/installer.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

download() {
    local asset_name="$1"
    local destination="$2"
    local release_tag="$3"
    curl -fsSL --retry 3 --retry-delay 1 \
        "https://github.com/${REPO}/releases/download/${release_tag}/${asset_name}" \
        -o "${destination}"
}

json_field() {
    local json="$1"
    local field_name="$2"
    printf '%s' "${json}" | tr '\n' ' ' | sed -n "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

resolve_release_tag() {
    local requested_tag="${SYNCPSS_RELEASE_TAG:-}"
    local release_json release_tag

    if [ -n "${requested_tag}" ]; then
        printf '%s' "${requested_tag}"
        return
    fi

    release_json="$(curl -fsSL --retry 3 --retry-delay 1 \
        -H 'Accept: application/vnd.github+json' \
        "${GITHUB_API_URL}/releases/latest")" || fail "Could not resolve the latest syncpss release"
    release_tag="$(json_field "${release_json}" "tag_name")"
    [ -n "${release_tag}" ] || fail "GitHub did not return a release tag for the latest syncpss release"
    printf '%s' "${release_tag}"
}

read_checksum() {
    awk 'NR==1 { print $1 }' "$1"
}

sha256_for_file() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${path}" | awk '{print $1}'
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${path}" | awk '{print $1}'
        return
    fi
    fail "Need sha256sum or shasum to verify installer.sh"
}

RELEASE_TAG="$(resolve_release_tag)"
printf 'Downloading syncpss installer release %s...\n' "${RELEASE_TAG}"
download "installer.sh" "${TMP_DIR}/installer.sh" "${RELEASE_TAG}"
download "installer.sh.sha256" "${TMP_DIR}/installer.sh.sha256" "${RELEASE_TAG}"

expected_checksum="$(read_checksum "${TMP_DIR}/installer.sh.sha256")"
actual_checksum="$(sha256_for_file "${TMP_DIR}/installer.sh")"
[ -n "${expected_checksum}" ] || fail "installer.sh.sha256 did not contain a checksum"
[ "${expected_checksum}" = "${actual_checksum}" ] || \
    fail "installer.sh checksum mismatch. Expected ${expected_checksum}, got ${actual_checksum}"

install -m 700 "${TMP_DIR}/installer.sh" "${TARGET}"
printf 'Verified and staged installer to %s\n' "${TARGET}"
exec bash "${TARGET}"
