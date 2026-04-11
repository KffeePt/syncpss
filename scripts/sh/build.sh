#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ "${OS}" != "linux" ]]; then
    echo "syncpss targets Linux and WSL only."
    exit 1
fi

BUILD_DIR="${SYNCPSS_BUILD_DIR:-build}"
BIN_DIR="${SYNCPSS_BIN_DIR:-bin}"
BUILD_TYPE="${SYNCPSS_BUILD_TYPE:-Release}"
BUILD_TARGET="${SYNCPSS_BUILD_TARGET:-all}"

if [[ "${BUILD_DIR}" != /* ]]; then
    BUILD_DIR="${REPO_ROOT}/${BUILD_DIR}"
fi

if [[ "${BIN_DIR}" != /* ]]; then
    BIN_DIR="${REPO_ROOT}/${BIN_DIR}"
fi

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
cmake "${REPO_ROOT}" -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"

case "${BUILD_TARGET}" in
    tui)
        cmake --build . --target syncpss -- -j"$(nproc 2>/dev/null || sysctl -n hw.logicalcpu)"
        ;;
    installer)
        cmake --build . --target syncpss_install -- -j"$(nproc 2>/dev/null || sysctl -n hw.logicalcpu)"
        ;;
    all)
        cmake --build . -- -j"$(nproc 2>/dev/null || sysctl -n hw.logicalcpu)"
        ;;
    *)
        echo "Unknown SYNCPSS_BUILD_TARGET: ${BUILD_TARGET}" >&2
        exit 1
        ;;
esac

case "${OS}-${ARCH}" in
    linux-x86_64)  ASSET="syncpss-linux-x86_64" ;;
    *)             ASSET="syncpss-${OS}-${ARCH}" ;;
esac

mkdir -p "${BIN_DIR}"
case "${BUILD_TARGET}" in
    tui|all)
        cp syncpss "${BIN_DIR}/${ASSET}"
        ;;
esac

case "${BUILD_TARGET}" in
    installer|all)
        cp install "${BIN_DIR}/install"
        cp "${REPO_ROOT}/scripts/sh/installer.sh" "${BIN_DIR}/installer.sh"
        cp "${REPO_ROOT}/scripts/sh/uninstall_syncpss.sh" "${BIN_DIR}/uninstall_syncpss.sh"
        cp "${REPO_ROOT}/manifest.xml" "${BIN_DIR}/manifest.xml"
        ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
    if [[ "${BUILD_TARGET}" == "tui" || "${BUILD_TARGET}" == "all" ]]; then
        sha256sum "${BIN_DIR}/${ASSET}" > "${BIN_DIR}/${ASSET}.sha256"
    fi
    if [[ "${BUILD_TARGET}" == "installer" || "${BUILD_TARGET}" == "all" ]]; then
        sha256sum "${BIN_DIR}/install" > "${BIN_DIR}/install.sha256"
        sha256sum "${BIN_DIR}/installer.sh" > "${BIN_DIR}/installer.sh.sha256"
        sha256sum "${BIN_DIR}/uninstall_syncpss.sh" > "${BIN_DIR}/uninstall_syncpss.sh.sha256"
        sha256sum "${BIN_DIR}/manifest.xml" > "${BIN_DIR}/manifest.xml.sha256"
    fi
elif command -v shasum >/dev/null 2>&1; then
    if [[ "${BUILD_TARGET}" == "tui" || "${BUILD_TARGET}" == "all" ]]; then
        shasum -a 256 "${BIN_DIR}/${ASSET}" > "${BIN_DIR}/${ASSET}.sha256"
    fi
    if [[ "${BUILD_TARGET}" == "installer" || "${BUILD_TARGET}" == "all" ]]; then
        shasum -a 256 "${BIN_DIR}/install" > "${BIN_DIR}/install.sha256"
        shasum -a 256 "${BIN_DIR}/installer.sh" > "${BIN_DIR}/installer.sh.sha256"
        shasum -a 256 "${BIN_DIR}/uninstall_syncpss.sh" > "${BIN_DIR}/uninstall_syncpss.sh.sha256"
        shasum -a 256 "${BIN_DIR}/manifest.xml" > "${BIN_DIR}/manifest.xml.sha256"
    fi
else
    echo "Warning: no SHA-256 tool found; checksum not written." >&2
fi

if [[ "${BUILD_TARGET}" == "tui" || "${BUILD_TARGET}" == "all" ]]; then
    echo "Binary: ${BIN_DIR}/${ASSET}"
fi
if [[ "${BUILD_TARGET}" == "installer" || "${BUILD_TARGET}" == "all" ]]; then
    echo "Binary: ${BIN_DIR}/install"
    echo "Helper: ${BIN_DIR}/installer.sh"
    echo "Helper: ${BIN_DIR}/uninstall_syncpss.sh"
    echo "Asset: ${BIN_DIR}/manifest.xml"
fi
