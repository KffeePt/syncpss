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

RELEASE_SIGNING_FINGERPRINT="89974211D53E5FFEB3FA74745A21FD7339CC230D"
RELEASE_SIGNING_PUBLIC_KEY='-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEadnR5xYJKwYBBAHaRw8BAQdAfrq0eZ24KOJBnNvpiq1BCUdSFXAtB/54chwY
C4/bsvS0tvZmZlZSBQb3QgTWFpboi1BBMWCgBdFiEEiZdCEdU+X/6z+nR0WiH9
cznMIw0FAmnZ0ecbFIAAAAAABAAObWFudTIsMi41KzEuMTIsMiwxAhsDBQkFpFS5
BQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAAAoJEFoh/XM5zCMNm6YBAOKgk1Gn
2bT5xNUMuAUGBV8ONiVA2kmgw4X9VClCOS63APwMG683OkVeO1kJkfF1C20Bi1mm
mjCQ1NMe5AmmjpoTBbg4BGnZ0ecSCisGAQQBl1UBBQEBB0B670QnggtMmfwAy+Le
i6JP8nQtfFg0QSlsUKxOBoEIQwMBCAeImgQYFgoAQhYhBImXQhHVPl/+s/p0dFoh
/XM5zCMNBQJp2dHnGxSAAAAAAAQADm1hbnUyLDIuNSsxLjEyLDIsMQIbDAUJBaRU
uQAKCRBaIf1zOcwjDbKZAP9vDYVWR9l99fSOGb/akwRqQ4meYawl4dtQRYxkbKco
CQD/TC0/8yGytWiFv6PmMfj58vS0RYjhrHCpq/GNpXhv2AM=
=VhQF
-----END PGP PUBLIC KEY BLOCK-----'

verify_release_signature() {
    local asset_path="$1"
    local signature_path="$2"
    local verifier_home="${TMP_DIR}/release-verifier"
    local key_path="${verifier_home}/release-signing-key.asc"
    local status_output signer_fingerprint observed_fingerprint

    command -v gpg >/dev/null 2>&1 || fail "gpg is required to verify the signed syncpss installer"
    mkdir -p "${verifier_home}"
    chmod 700 "${verifier_home}"
    if [ ! -f "${key_path}" ]; then
        printf '%s\n' "${RELEASE_SIGNING_PUBLIC_KEY}" > "${key_path}"
        chmod 600 "${key_path}"
        gpg --batch --no-options --no-auto-key-retrieve --homedir "${verifier_home}" \
            --import "${key_path}" >/dev/null 2>&1 || fail "Could not load the trusted syncpss release key"
    fi

    observed_fingerprint="$(gpg --batch --no-options --no-auto-key-retrieve --homedir "${verifier_home}" \
        --with-colons --list-keys "${RELEASE_SIGNING_FINGERPRINT}" 2>/dev/null | \
        awk -F: '$1 == "fpr" { print toupper($10); exit }')"
    [ "${observed_fingerprint}" = "${RELEASE_SIGNING_FINGERPRINT}" ] || \
        fail "The trusted syncpss release key fingerprint did not match policy"

    status_output="$(gpg --batch --no-options --no-auto-key-retrieve --homedir "${verifier_home}" \
        --status-fd 1 --verify "${signature_path}" "${asset_path}" 2>/dev/null)" || \
        fail "Release signature verification failed for ${asset_path}"
    signer_fingerprint="$(printf '%s\n' "${status_output}" | \
        awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print toupper($3); exit }')"
    [ "${signer_fingerprint}" = "${RELEASE_SIGNING_FINGERPRINT}" ] || \
        fail "Release asset was not signed by the trusted syncpss release key"
}

download() {
    local asset_name="$1"
    local destination="$2"
    local release_tag="$3"
    curl -fL --progress-bar --retry 3 --retry-delay 1 \
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
download "installer.sh.asc" "${TMP_DIR}/installer.sh.asc" "${RELEASE_TAG}"

expected_checksum="$(read_checksum "${TMP_DIR}/installer.sh.sha256")"
actual_checksum="$(sha256_for_file "${TMP_DIR}/installer.sh")"
[ -n "${expected_checksum}" ] || fail "installer.sh.sha256 did not contain a checksum"
[ "${expected_checksum}" = "${actual_checksum}" ] || \
    fail "installer.sh checksum mismatch. Expected ${expected_checksum}, got ${actual_checksum}"
verify_release_signature "${TMP_DIR}/installer.sh" "${TMP_DIR}/installer.sh.asc"

install -m 700 "${TMP_DIR}/installer.sh" "${TARGET}"
printf 'Verified and staged installer to %s\n' "${TARGET}"
exec bash "${TARGET}"
