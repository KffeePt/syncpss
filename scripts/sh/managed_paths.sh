#!/usr/bin/env bash

syncpss_trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

syncpss_strip_control_chars() {
    local value="${1:-}"
    printf '%s' "${value}" | LC_ALL=C tr -cd '\11\12\15\40-\176'
}

syncpss_has_control_chars() {
    local value="${1:-}"
    if printf '%s' "${value}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        printf 'True'
        return
    fi
    printf 'False'
}

syncpss_is_single_line_safe() {
    local value
    value="$(syncpss_trim "${1:-}")"
    [ -n "${value}" ] || return 1
    [ "$(syncpss_has_control_chars "${value}")" = "False" ] || return 1
    case "${value}" in
        *$'\n'*|*$'\r'*)
            return 1
            ;;
    esac
    return 0
}

syncpss_validate_repo_name() {
    local value
    value="$(syncpss_trim "${1:-}")"
    syncpss_is_single_line_safe "${value}" || return 1
    [ "${#value}" -le 100 ] || return 1
    case "${value}" in
        .*|-*|*..*|*/*.lock|*.lock|*//*|*/)
            return 1
            ;;
        *[!A-Za-z0-9._-]*)
            return 1
            ;;
    esac
    return 0
}

syncpss_validate_account_name() {
    local value
    value="$(syncpss_trim "${1:-}")"
    syncpss_is_single_line_safe "${value}" || return 1
    [ "${#value}" -le 39 ] || return 1
    case "${value}" in
        -*|*.|*..*)
            return 1
            ;;
        *[!A-Za-z0-9-]*)
            return 1
            ;;
    esac
    return 0
}

syncpss_validate_repo_id() {
    local owner repo
    owner="${1%%/*}"
    repo="${1#*/}"
    [ "${owner}" != "${repo}" ] || return 1
    syncpss_validate_account_name "${owner}" && syncpss_validate_repo_name "${repo}"
}

syncpss_validate_branch_name() {
    local value
    value="$(syncpss_trim "${1:-}")"
    syncpss_is_single_line_safe "${value}" || return 1
    [ "${#value}" -le 255 ] || return 1
    case "${value}" in
        -*|*..*|*@\{*|*.lock|*//*|*/|*.)
            return 1
            ;;
        *[!A-Za-z0-9._/-]*)
            return 1
            ;;
    esac
    return 0
}

syncpss_validate_gpg_key_id() {
    local value
    value="$(syncpss_trim "${1:-}")"
    syncpss_is_single_line_safe "${value}" || return 1
    case "${value}" in
        0x[0-9A-Fa-f]*|[0-9A-Fa-f]*)
            ;;
        *)
            return 1
            ;;
    esac
    local stripped="${value#0x}"
    case "${#stripped}" in
        8|16|40)
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

syncpss_normalize_path() {
    local path="${1:-}"
    path="$(syncpss_trim "${path}")"
    syncpss_is_single_line_safe "${path}" || return 1
    case "${path}" in
        /*)
            ;;
        *)
            printf 'relative path is not allowed: %s\n' "${path}" >&2
            return 1
            ;;
    esac
    if command -v realpath >/dev/null 2>&1; then
        if [ -e "${path}" ] || [ -L "${path}" ]; then
            realpath -- "${path}" 2>/dev/null && return
        fi
        realpath -m -- "${path}" 2>/dev/null && return
    fi
    printf '%s' "${path}"
}

syncpss_is_root_like_path() {
    local normalized="${1:-}"
    case "${normalized}" in
        /|/home|/mnt|/tmp|/usr|/etc|/var|/opt|/root|/proc|/sys|/dev|/run|/mnt/[A-Za-z]|/mnt/[A-Za-z]/Users)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

syncpss_is_windows_mount_path() {
    local normalized="${1:-}"
    case "${normalized}" in
        /mnt/[A-Za-z]/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

syncpss_validate_path_candidate() {
    local path="$1"
    local description="$2"
    local normalized

    normalized="$(syncpss_normalize_path "${path}")" || {
        printf 'unsafe path for %s: %s\n' "${description}" "${path}" >&2
        return 1
    }

    if syncpss_is_root_like_path "${normalized}"; then
        printf 'root-like path for %s is not allowed: %s\n' "${description}" "${normalized}" >&2
        return 1
    fi

    printf '%s' "${normalized}"
}

syncpss_normalize_allowlist_root() {
    local path="$1"
    local description="$2"
    local normalized

    normalized="$(syncpss_normalize_path "${path}")" || {
        printf 'unsafe allowlist root for %s: %s\n' "${description}" "${path}" >&2
        return 1
    }
    printf '%s' "${normalized}"
}

syncpss_path_is_within_root() {
    local candidate root
    candidate="$(syncpss_validate_path_candidate "${1:-}" "candidate path")" || return 1
    root="$(syncpss_normalize_allowlist_root "${2:-}" "root path")" || return 1
    case "${candidate}" in
        "${root}"|"${root}"/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

syncpss_require_path_in_roots() {
    local path="$1"
    local description="$2"
    shift 2
    local root normalized normalized_root allows_windows_mount=0

    normalized="$(syncpss_validate_path_candidate "${path}" "${description}")" || return 1

    for root in "$@"; do
        normalized_root="$(syncpss_normalize_allowlist_root "${root}" "${description} allowlist root")" || return 1
        if syncpss_is_windows_mount_path "${normalized_root}"; then
            allows_windows_mount=1
            break
        fi
    done

    if syncpss_is_windows_mount_path "${normalized}" && [ "${allows_windows_mount}" -ne 1 ]; then
        printf 'unmanaged Windows-mounted path for %s: %s\n' "${description}" "${normalized}" >&2
        return 1
    fi

    for root in "$@"; do
        if syncpss_path_is_within_root "${normalized}" "${root}"; then
            return 0
        fi
    done

    printf 'unmanaged path for %s: %s\n' "${description}" "${normalized}" >&2
    return 1
}

syncpss_require_exact_path() {
    local path="$1"
    local description="$2"
    shift 2
    local normalized allowed

    normalized="$(syncpss_validate_path_candidate "${path}" "${description}")" || return 1

    for allowed in "$@"; do
        if [ "${normalized}" = "$(syncpss_normalize_allowlist_root "${allowed}" "${description} allowlist path")" ]; then
            return 0
        fi
    done

    printf 'unmanaged exact path for %s: %s\n' "${description}" "${normalized}" >&2
    return 1
}
