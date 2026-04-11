#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME}"
RUNTIME_DIR="${HOME_DIR}/.syncpss"
SETTINGS_DIR="${HOME_DIR}/.config/syncpss"
SETTINGS_FILE="${SETTINGS_DIR}/preferences.env"
STORE_DIR="${HOME_DIR}/.password-store"
DEFAULT_REPO_NAME="password-store"
LOCAL_BIN_DIR="${HOME_DIR}/.local/bin"
GLOBAL_BIN_DIR="/usr/local/bin"
GLOBAL_CONFIG_DIR="/etc/syncpass"
INSTALL_NOTE="${HOME_DIR}/syncpss-install-note.txt"
SELF_PATH="${0}"
WINDOWS_SHORTCUT_PURGE_MARKER="${HOME_DIR}/.syncpss-purge-windows-shortcut"
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_GROUP="$(id -gn "${REAL_USER}" 2>/dev/null || id -gn)"

PURGE_STORE=0
PURGE_GNUPG=0
PURGE_ALL=0
PURGE_WINDOWS_SHORTCUT=0
ASSUME_YES=0
FORGET_REPO_NAME=0

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

sudo_run() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        local status answer
        while true; do
            if sudo "$@"; then
                return 0
            fi
            status=$?
            if [ ! -t 0 ] || [ ! -t 1 ]; then
                return "${status}"
            fi
            warn "sudo did not complete. If the prompt closed after 3 password attempts, you can try again."
            read -r -p "Retry this sudo step? [Y/n] " answer || {
                printf '\n' >&2
                return "${status}"
            }
            case "${answer}" in
                ""|y|Y|yes|YES)
                    sudo -k >/dev/null 2>&1 || true
                    ;;
                *)
                    return "${status}"
                    ;;
            esac
        done
    fi
}

repair_runtime_ownership_if_needed() {
    if [ -e "${RUNTIME_DIR}" ]; then
        sudo_run chown -R "${REAL_USER}:${REAL_GROUP}" "${RUNTIME_DIR}" || true
    fi
}

is_safe_home_target() {
    local path="$1"
    case "${path}" in
        /home/*|/Users/*)
            [ "${#path}" -gt 10 ]
            ;;
        *)
            return 1
            ;;
    esac
}

prompt_yes_no() {
    local message="$1"
    local default_yes="${2:-0}"
    local answer suffix

    if [ "${ASSUME_YES}" = "1" ]; then
        [ "${default_yes}" = "1" ]
        return
    fi

    if [ "${default_yes}" = "1" ]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    read -r -p "${message} ${suffix} " answer
    if [ -z "${answer}" ]; then
        [ "${default_yes}" = "1" ]
        return
    fi

    case "${answer}" in
        y|Y|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

load_saved_private_repo_name() {
    [ -f "${SETTINGS_FILE}" ] || return 0
    sed -n 's/^SYNCPSS_PRIVATE_REPO_NAME=//p' "${SETTINGS_FILE}" | head -n 1
}

has_purgeable_targets() {
    local path

    for path in \
        "${LOCAL_BIN_DIR}/syncpss" \
        "${LOCAL_BIN_DIR}/syncpass" \
        "${RUNTIME_DIR}" \
        "${INSTALL_NOTE}" \
        "${GLOBAL_BIN_DIR}/syncpss" \
        "${GLOBAL_BIN_DIR}/syncpass" \
        "${GLOBAL_CONFIG_DIR}" \
        "${STORE_DIR}" \
        "${HOME_DIR}/.gnupg" \
        "${SETTINGS_FILE}"
    do
        if [ -e "${path}" ] || [ -L "${path}" ]; then
            return 0
        fi
    done

    [ "${PURGE_WINDOWS_SHORTCUT}" = "1" ]
}

typed_delete_guard() {
    if [ "${ASSUME_YES}" = "1" ]; then
        return
    fi

    local answer=""
    while true; do
        log "This will uninstall syncpss from the current Linux/WSL environment."
        if ! read -r -p "Type DELETE to continue: " answer; then
            printf '\n' >&2
            fail "Uninstall cancelled."
        fi
        if [ "${answer}" = "DELETE" ]; then
            return
        fi
        if [ -z "${answer}" ]; then
            warn "Input is required. Type DELETE to confirm, or press Ctrl+C to abort."
            continue
        fi
        fail "Uninstall cancelled."
    done
}

remove_if_exists() {
    local path="$1"
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        rm -f "${path}"
    fi
}

remove_dir_if_exists() {
    local path="$1"
    if [ -e "${path}" ]; then
        rm -rf "${path}"
    fi
}

remove_home_dir_if_safe() {
    local path="$1"
    if [ ! -e "${path}" ]; then
        return
    fi
    is_safe_home_target "${path}" || fail "Refusing to delete unsafe path: ${path}"
    rm -rf "${path}"
}

remove_system_path() {
    local path="$1"
    case "${path}" in
        /usr/local/bin/syncpss|/usr/local/bin/syncpass|/etc/syncpass)
            ;;
        *)
            fail "Refusing to remove unmanaged system path: ${path}"
            ;;
    esac

    if [ -e "${path}" ] || [ -L "${path}" ]; then
        sudo_run rm -rf "${path}"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --purge-store)
                PURGE_STORE=1
                ;;
            --purge-gnupg)
                PURGE_GNUPG=1
                ;;
            --purge-all)
                PURGE_ALL=1
                PURGE_STORE=1
                PURGE_GNUPG=1
                FORGET_REPO_NAME=1
                PURGE_WINDOWS_SHORTCUT=1
                ;;
            --purge-windows-shortcut)
                PURGE_WINDOWS_SHORTCUT=1
                ;;
            --yes)
                ASSUME_YES=1
                ;;
            --forget-repo-name)
                FORGET_REPO_NAME=1
                ;;
            --help|-h)
                cat <<EOF
Usage:
  bash ~/uninstall_syncpss.sh [--purge-store] [--purge-gnupg] [--purge-all] [--forget-repo-name] [--yes]

Options:
  --purge-store  Also delete ~/.password-store
  --purge-gnupg  Also delete ~/.gnupg
  --purge-all  Remove all syncpss-managed local files and skip the individual purge prompts
  --purge-windows-shortcut  Also remove the Windows Start Menu shortcut and local syncpss launcher files
  --forget-repo-name  Remove the saved private repo-name preference too
  --yes          Skip prompts and typed confirmation
EOF
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"
    typed_delete_guard
    repair_runtime_ownership_if_needed

    if [ "${PURGE_ALL}" = "0" ]; then
        if prompt_yes_no "Remove everything syncpss managed on this machine?" 0; then
            PURGE_ALL=1
            PURGE_STORE=1
            PURGE_GNUPG=1
            FORGET_REPO_NAME=1
            PURGE_WINDOWS_SHORTCUT=1
        fi
    fi

    if [ "${PURGE_ALL}" = "0" ]; then
        if [ "${PURGE_STORE}" = "0" ] && prompt_yes_no "Also remove ${STORE_DIR}?" 0; then
            PURGE_STORE=1
        fi
        if [ "${PURGE_GNUPG}" = "0" ] && prompt_yes_no "Also remove ${HOME_DIR}/.gnupg?" 0; then
            PURGE_GNUPG=1
        fi
        if [ "${FORGET_REPO_NAME}" = "0" ] && [ -f "${SETTINGS_FILE}" ]; then
            saved_repo_name="$(load_saved_private_repo_name)"
            [ -n "${saved_repo_name}" ] || saved_repo_name="${DEFAULT_REPO_NAME}"
            if prompt_yes_no "Forget your custom ${saved_repo_name} repo name? You will have to set it up again later." 0; then
                FORGET_REPO_NAME=1
            fi
        fi
        if [ "${PURGE_WINDOWS_SHORTCUT}" = "0" ] && prompt_yes_no "Also remove the Windows Start Menu shortcut and local syncpss launcher files?" 0; then
            PURGE_WINDOWS_SHORTCUT=1
        fi
    fi

    if [ "${PURGE_WINDOWS_SHORTCUT}" = "1" ]; then
        : > "${WINDOWS_SHORTCUT_PURGE_MARKER}"
    fi

    if ! has_purgeable_targets; then
        log "No persistent syncpss-managed files were found to remove."
    fi

    log
    log "Removing local wrapper commands..."
    remove_if_exists "${LOCAL_BIN_DIR}/syncpss"
    remove_if_exists "${LOCAL_BIN_DIR}/syncpass"

    log "Removing runtime data..."
    remove_home_dir_if_safe "${RUNTIME_DIR}"
    remove_if_exists "${INSTALL_NOTE}"

    log "Removing system binaries..."
    remove_system_path "${GLOBAL_BIN_DIR}/syncpss"
    remove_system_path "${GLOBAL_BIN_DIR}/syncpass"

    log "Removing system config..."
    remove_system_path "${GLOBAL_CONFIG_DIR}"

    if [ "${PURGE_STORE}" = "1" ]; then
        log "Removing password store..."
        remove_home_dir_if_safe "${STORE_DIR}"
    fi

    if [ "${PURGE_GNUPG}" = "1" ]; then
        log "Removing GPG home..."
        remove_home_dir_if_safe "${HOME_DIR}/.gnupg"
    fi

    if [ "${FORGET_REPO_NAME}" = "1" ]; then
        log "Removing saved private repo-name preference..."
        remove_if_exists "${SETTINGS_FILE}"
        rmdir "${SETTINGS_DIR}" >/dev/null 2>&1 || true
    fi

    log "Removing uninstall script..."
    remove_if_exists "${SELF_PATH}"

    log
    log "syncpss uninstall completed."
}

main "$@"
