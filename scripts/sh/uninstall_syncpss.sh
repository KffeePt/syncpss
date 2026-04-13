#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/managed_paths.sh" ]; then
    . "${SCRIPT_DIR}/managed_paths.sh"
else
    printf 'error: uninstall helper missing: %s\n' "${SCRIPT_DIR}/managed_paths.sh" >&2
    exit 1
fi
RUNTIME_DIR="${HOME_DIR}/.syncpss"
SETTINGS_DIR="${HOME_DIR}/.config/syncpss"
SETTINGS_FILE="${SETTINGS_DIR}/preferences.env"
WINDOWS_SHORTCUT_MARKER="${HOME_DIR}/.syncpss-purge-windows-shortcut"
STORE_DIR="${HOME_DIR}/.password-store"
DEFAULT_REPO_NAME="password-store"
LOCAL_BIN_DIR="${HOME_DIR}/.local/bin"
GLOBAL_BIN_DIR="/usr/local/bin"
GLOBAL_CONFIG_DIR="/etc/syncpass"
INSTALL_NOTE="${HOME_DIR}/syncpss-install-note.txt"
MOUNT_POINT="/mnt/keys"
SELF_PATH="${0}"
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_GROUP="$(id -gn "${REAL_USER}" 2>/dev/null || id -gn)"
UNINSTALL_LOG_FILE="${SYNCPSS_UNINSTALL_LOG_PATH:-${TMPDIR:-/tmp}/syncpss-uninstall-${REAL_USER}.log}"

PURGE_STORE=0
PURGE_GNUPG=0
PURGE_ALL=0
PURGE_WINDOWS_SHORTCUT=0
ASSUME_YES=0
FORGET_REPO_NAME=0
WINDOWS_APPDATA_PATH=""
WINDOWS_LOCALAPPDATA_PATH=""
WINDOWS_USERPROFILE_PATH=""
WINDOWS_PURGE_HELPER_NAME="purge.ps1"

initialize_uninstall_log() {
    local log_dir
    log_dir="$(dirname "${UNINSTALL_LOG_FILE}")"
    mkdir -p "${log_dir}" 2>/dev/null || true
    : >> "${UNINSTALL_LOG_FILE}" 2>/dev/null || true
    chmod 600 "${UNINSTALL_LOG_FILE}" 2>/dev/null || true

    if [ "${SYNCPSS_UNINSTALL_LOG_REDIRECTED:-0}" != "1" ] && command -v tee >/dev/null 2>&1; then
        export SYNCPSS_UNINSTALL_LOG_REDIRECTED=1
        exec > >(tee -a "${UNINSTALL_LOG_FILE}") 2>&1
    fi
}

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

prompt_label() {
    if [ -w /dev/tty ]; then
        printf '%s' "$1" > /dev/tty
    else
        printf '%s' "$1" >&2
    fi
}

prompt_read_line() {
    local __resultvar="$1"
    local input=""

    if [ -r /dev/tty ]; then
        if ! IFS= read -r input < /dev/tty; then
            return 1
        fi
    else
        if ! IFS= read -r input; then
            return 1
        fi
    fi

    printf -v "${__resultvar}" '%s' "${input}"
    return 0
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
            prompt_label "Retry this sudo step? [Y/n] "
            if ! prompt_read_line answer; then
                printf '\n' >&2
                return "${status}"
            fi
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
    syncpss_require_path_in_roots "${path}" "home target" "${RUNTIME_DIR}" "${SETTINGS_DIR}" "${STORE_DIR}" "${HOME_DIR}/.gnupg"
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

    prompt_label "${message} ${suffix} "
    if ! prompt_read_line answer; then
        printf '\n' >&2
        return 1
    fi
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
        "${RUNTIME_DIR}" \
        "${SETTINGS_DIR}" \
        "${GLOBAL_BIN_DIR}/syncpss" \
        "${GLOBAL_BIN_DIR}/syncpass" \
        "${GLOBAL_CONFIG_DIR}" \
        "${MOUNT_POINT}" \
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
    log "This will uninstall syncpss from the current Linux/WSL environment."
    while true; do
        prompt_label "Type DELETE to continue: "
        if ! prompt_read_line answer; then
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

remove_managed_file_if_safe() {
    local path="$1"
    local description="$2"
    shift 2
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        syncpss_require_path_in_roots "${path}" "${description}" "$@" || \
            fail "Refusing to delete unmanaged file: ${path}"
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

remove_windows_path_if_safe() {
    local path="$1"
    local windows_path=""
    local removed_via_wsl=0
    shift
    syncpss_require_exact_path "${path}" "Windows-mounted path" "$@" || \
        fail "Refusing to delete unmanaged Windows path: ${path}"

    if [ -e "${path}" ] || [ -L "${path}" ]; then
        if rm -rf "${path}" 2>/dev/null; then
            removed_via_wsl=1
        fi
        if [ -e "${path}" ] || [ -L "${path}" ]; then
            if [ "${removed_via_wsl}" = "0" ]; then
                warn "WSL could not remove ${path} directly. Retrying with Windows Remove-Item."
            fi
            if command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
                windows_path="$(wslpath -w "${path}" 2>/dev/null || true)"
                if [ -n "${windows_path}" ]; then
                    WINDOWS_TARGET_PATH="${windows_path}" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass \
                        -Command '$target = $env:WINDOWS_TARGET_PATH; if ($target -and (Test-Path -LiteralPath $target)) { Remove-Item -LiteralPath $target -Force -Recurse -ErrorAction Stop }' \
                        >/dev/null 2>&1 || true
                fi
            fi
        fi
        if [ -e "${path}" ] || [ -L "${path}" ]; then
            warn "Windows-managed path could not be removed cleanly: ${path}"
            return 1
        fi
    fi
}

run_windows_purge_helper_if_present() {
    local mode="$1"
    local expected_path="$2"
    local helper_path=""
    local helper_windows_path=""

    if [ -z "${WINDOWS_USERPROFILE_PATH}" ]; then
        cache_windows_profile_paths
    fi

    [ -n "${WINDOWS_USERPROFILE_PATH}" ] || return 1
    [ -n "${expected_path}" ] || return 1
    command -v powershell.exe >/dev/null 2>&1 || return 1
    command -v wslpath >/dev/null 2>&1 || return 1

    helper_path="${WINDOWS_USERPROFILE_PATH}/${WINDOWS_PURGE_HELPER_NAME}"
    [ -f "${helper_path}" ] || return 1

    helper_windows_path="$(wslpath -w "${helper_path}" 2>/dev/null || true)"
    [ -n "${helper_windows_path}" ] || return 1

    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass \
        -File "${helper_windows_path}" \
        -Mode "${mode}" >/dev/null 2>&1 || return 1

    [ ! -e "${expected_path}" ] && [ ! -L "${expected_path}" ]
}

windows_env_path() {
    local variable="$1"
    local raw=""

    command -v wslpath >/dev/null 2>&1 || return 1
    if command -v powershell.exe >/dev/null 2>&1; then
        case "${variable}" in
            APPDATA)
                raw="$(powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass \
                    -Command "[Environment]::GetFolderPath('ApplicationData')" 2>/dev/null | tr -d '\r' | tail -n 1)"
                ;;
            LOCALAPPDATA)
                raw="$(powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass \
                    -Command "[Environment]::GetFolderPath('LocalApplicationData')" 2>/dev/null | tr -d '\r' | tail -n 1)"
                ;;
            USERPROFILE)
                raw="$(powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass \
                    -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r' | tail -n 1)"
                ;;
            *)
                raw=''
                ;;
        esac
        if [ -n "${raw}" ]; then
            wslpath -u "${raw}" && return 0
        fi
    fi

    command -v cmd.exe >/dev/null 2>&1 || return 1

    raw="$(cmd.exe /c "echo %${variable}%" 2>/dev/null | tr -d '\r')"
    [ -n "${raw}" ] || return 1
    [ "${raw}" != "%${variable}%" ] || return 1

    wslpath -u "${raw}"
}

windows_username() {
    local raw=""

    if command -v powershell.exe >/dev/null 2>&1; then
        raw="$(powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass \
            -Command "[Environment]::GetEnvironmentVariable('USERNAME')" 2>/dev/null | tr -d '\r' | tail -n 1)"
        if [ -n "${raw}" ]; then
            printf '%s' "${raw}"
            return 0
        fi
    fi

    if command -v cmd.exe >/dev/null 2>&1; then
        raw="$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')"
        if [ -n "${raw}" ] && [ "${raw}" != "%USERNAME%" ]; then
            printf '%s' "${raw}"
            return 0
        fi
    fi

    return 1
}

windows_username_from_path_hints() {
    local path_entry trimmed username

    IFS=':' read -r -a _syncpss_path_entries <<< "${PATH:-}"
    for path_entry in "${_syncpss_path_entries[@]}"; do
        trimmed="${path_entry%/}"
        case "${trimmed}" in
            /mnt/[A-Za-z]/Users/*)
                username="${trimmed#"/mnt/"}"
                username="${username#?/Users/}"
                username="${username%%/*}"
                if [ -n "${username}" ]; then
                    printf '%s' "${username}"
                    return 0
                fi
                ;;
        esac
    done

    return 1
}

fallback_windows_env_path() {
    local variable="$1"
    local username raw_path

    command -v wslpath >/dev/null 2>&1 || return 1
    username="$(windows_username || windows_username_from_path_hints || true)"
    [ -n "${username}" ] || return 1

    case "${variable}" in
        APPDATA)
            raw_path="C:\\Users\\${username}\\AppData\\Roaming"
            ;;
        LOCALAPPDATA)
            raw_path="C:\\Users\\${username}\\AppData\\Local"
            ;;
        USERPROFILE)
            raw_path="C:\\Users\\${username}"
            ;;
        *)
            return 1
            ;;
    esac

    wslpath -u "${raw_path}"
}

discover_windows_profile_root_from_mounts() {
    local users_root="/mnt/c/Users"
    local candidate name hinted_username hinted_root

    [ -d "${users_root}" ] || return 1

    for candidate in "${users_root}"/*; do
        [ -d "${candidate}" ] || continue
        name="${candidate##*/}"
        case "${name}" in
            All\ Users|Default|Default\ User|Public|defaultuser0)
                continue
                ;;
        esac

        if [ -e "${candidate}/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/syncpss.lnk" ] || \
           [ -e "${candidate}/.syncpss" ] || \
           [ -e "${candidate}/AppData/Local/syncpss" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    hinted_username="$(windows_username || windows_username_from_path_hints || true)"
    if [ -n "${hinted_username}" ]; then
        hinted_root="${users_root}/${hinted_username}"
        if [ -d "${hinted_root}" ]; then
            printf '%s' "${hinted_root}"
            return 0
        fi
    fi

    return 1
}

cache_windows_profile_paths() {
    local profile_root=""

    WINDOWS_APPDATA_PATH="$(windows_env_path APPDATA || fallback_windows_env_path APPDATA || true)"
    WINDOWS_LOCALAPPDATA_PATH="$(windows_env_path LOCALAPPDATA || fallback_windows_env_path LOCALAPPDATA || true)"
    WINDOWS_USERPROFILE_PATH="$(windows_env_path USERPROFILE || fallback_windows_env_path USERPROFILE || true)"

    if [ -z "${WINDOWS_USERPROFILE_PATH}" ] || [ -z "${WINDOWS_APPDATA_PATH}" ] || [ -z "${WINDOWS_LOCALAPPDATA_PATH}" ]; then
        profile_root="$(discover_windows_profile_root_from_mounts || true)"
        if [ -n "${profile_root}" ]; then
            [ -n "${WINDOWS_USERPROFILE_PATH}" ] || WINDOWS_USERPROFILE_PATH="${profile_root}"
            [ -n "${WINDOWS_APPDATA_PATH}" ] || WINDOWS_APPDATA_PATH="${profile_root}/AppData/Roaming"
            [ -n "${WINDOWS_LOCALAPPDATA_PATH}" ] || WINDOWS_LOCALAPPDATA_PATH="${profile_root}/AppData/Local"
        fi
    fi
}

purge_windows_shortcut_assets() {
    local shortcut_path runtime_dir app_dir
    local cleanup_failed=0

    if [ -z "${WINDOWS_APPDATA_PATH}" ] || [ -z "${WINDOWS_LOCALAPPDATA_PATH}" ] || [ -z "${WINDOWS_USERPROFILE_PATH}" ]; then
        cache_windows_profile_paths
    fi

    if [ -z "${WINDOWS_APPDATA_PATH}" ] && [ -z "${WINDOWS_LOCALAPPDATA_PATH}" ] && [ -z "${WINDOWS_USERPROFILE_PATH}" ]; then
        warn "Could not resolve Windows profile paths from WSL. Skipping Start Menu cleanup."
        return
    fi

    if [ -n "${WINDOWS_APPDATA_PATH}" ]; then
        shortcut_path="${WINDOWS_APPDATA_PATH}/Microsoft/Windows/Start Menu/Programs/syncpss.lnk"
        if [ -e "${shortcut_path}" ] || [ -L "${shortcut_path}" ]; then
            log "Removing Windows Start Menu shortcut..."
            if ! run_windows_purge_helper_if_present "start-menu-shortcut" "${shortcut_path}"; then
                remove_windows_path_if_safe "${shortcut_path}" "${shortcut_path}" || cleanup_failed=1
            fi
        fi
    fi

    if [ -n "${WINDOWS_USERPROFILE_PATH}" ]; then
        runtime_dir="${WINDOWS_USERPROFILE_PATH}/.syncpss"
        if [ -e "${runtime_dir}" ]; then
            log "Removing Windows syncpss runtime helper directory..."
            remove_windows_path_if_safe "${runtime_dir}" "${runtime_dir}" || cleanup_failed=1
        fi
    fi

    if [ -n "${WINDOWS_LOCALAPPDATA_PATH}" ]; then
        app_dir="${WINDOWS_LOCALAPPDATA_PATH}/syncpss"
        if [ -e "${app_dir}" ]; then
            log "Removing Windows syncpss local app assets..."
            if ! run_windows_purge_helper_if_present "local-app-assets" "${app_dir}"; then
                remove_windows_path_if_safe "${app_dir}" "${app_dir}" || cleanup_failed=1
            fi
        fi
    fi

    return "${cleanup_failed}"
}

remove_system_path() {
    local path="$1"
    syncpss_require_exact_path "${path}" "system path" "/usr/local/bin/syncpss" "/usr/local/bin/syncpass" "/etc/syncpass" || \
        fail "Refusing to remove unmanaged system path: ${path}"

    if [ -e "${path}" ] || [ -L "${path}" ]; then
        sudo_run rm -rf "${path}"
    fi
}

path_is_mounted() {
    local path="$1"

    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "${path}"
        return
    fi

    awk -v target="${path}" '$2 == target { found = 1 } END { exit(found ? 0 : 1) }' /proc/mounts
}

dismount_managed_keys_mount() {
    if ! path_is_mounted "${MOUNT_POINT}"; then
        return 0
    fi

    if command -v veracrypt >/dev/null 2>&1; then
        sudo_run veracrypt --text --dismount "${MOUNT_POINT}" >/dev/null 2>&1 || true
    fi

    if path_is_mounted "${MOUNT_POINT}" && command -v umount >/dev/null 2>&1; then
        sudo_run umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
    fi

    if path_is_mounted "${MOUNT_POINT}"; then
        warn "Could not dismount ${MOUNT_POINT}. Leaving it in place."
        return 1
    fi

    return 0
}

remove_managed_mount_path() {
    local path="$1"
    syncpss_require_exact_path "${path}" "managed mount path" "${MOUNT_POINT}" || \
        fail "Refusing to remove unmanaged mount path: ${path}"

    if [ ! -e "${path}" ] && [ ! -L "${path}" ] && ! path_is_mounted "${path}"; then
        return
    fi

    dismount_managed_keys_mount || return

    if [ -e "${path}" ] || [ -L "${path}" ]; then
        sudo_run rm -rf "${path}"
    fi
}

write_windows_shortcut_marker() {
    if [ "${PURGE_WINDOWS_SHORTCUT}" != "1" ]; then
        return
    fi

    : > "${WINDOWS_SHORTCUT_MARKER}" 2>/dev/null || true
    chmod 600 "${WINDOWS_SHORTCUT_MARKER}" 2>/dev/null || true
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
    initialize_uninstall_log
    parse_args "$@"
    typed_delete_guard
    repair_runtime_ownership_if_needed
    if [ "${PURGE_WINDOWS_SHORTCUT}" = "1" ] || [ "${PURGE_ALL}" = "1" ]; then
        cache_windows_profile_paths
    fi

    if [ "${PURGE_ALL}" = "0" ]; then
        if prompt_yes_no "Remove everything syncpss managed on this machine?" 0; then
            PURGE_ALL=1
            PURGE_STORE=1
            PURGE_GNUPG=1
            FORGET_REPO_NAME=1
            PURGE_WINDOWS_SHORTCUT=1
            cache_windows_profile_paths
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
            cache_windows_profile_paths
        fi
    fi

    if ! has_purgeable_targets; then
        log "No persistent syncpss-managed files were found to remove."
    fi

    log
    log "Local wrapper commands under ${LOCAL_BIN_DIR} are outside the managed syncpss boundary and will be left untouched."

    log "Removing system binaries..."
    remove_system_path "${GLOBAL_BIN_DIR}/syncpss"
    remove_system_path "${GLOBAL_BIN_DIR}/syncpass"

    log "Removing system config..."
    remove_system_path "${GLOBAL_CONFIG_DIR}"

    log "Cleaning managed keys mount..."
    remove_managed_mount_path "${MOUNT_POINT}"

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
        remove_managed_file_if_safe "${SETTINGS_FILE}" "settings file" "${SETTINGS_DIR}"
        rmdir "${SETTINGS_DIR}" >/dev/null 2>&1 || true
    fi

    if [ "${PURGE_WINDOWS_SHORTCUT}" = "1" ]; then
        if ! purge_windows_shortcut_assets; then
            write_windows_shortcut_marker
            warn "Windows cleanup was deferred. Finish it from Windows PowerShell or rerun scripts\\purge.bat so the wrapper can remove the remaining files."
        fi
    fi

    log "Removing runtime data..."
    remove_home_dir_if_safe "${RUNTIME_DIR}"

    log "Removing uninstall script..."
    if syncpss_require_path_in_roots "${SELF_PATH}" "uninstall script" "${RUNTIME_DIR}" "${SETTINGS_DIR}" >/dev/null 2>&1; then
        remove_managed_file_if_safe "${SELF_PATH}" "uninstall script" "${RUNTIME_DIR}" "${SETTINGS_DIR}"
    else
        log "Leaving ${SELF_PATH} in place because it is outside the managed syncpss boundary."
    fi

    log
    log "syncpss uninstall completed."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
