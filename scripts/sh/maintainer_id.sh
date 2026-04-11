#!/usr/bin/env bash
set -euo pipefail

SYNCPSS_MAINTAINER_ENV_NAME="SYNCPSS_MAINTAINER_ID"
SYNCPSS_MAINTAINER_LEGACY_HASH="4e6840a7429669ff3ed6747d5727cc2cceab1113e1336b87b4a541a1c1ecc0b0"

maintainer_resolve_repo_root() {
    local repo_root="${1:-}"
    if [ -n "${repo_root}" ]; then
        printf '%s' "${repo_root}"
        return 0
    fi

    local helper_dir
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    (cd "${helper_dir}/../.." && pwd)
}

maintainer_env_file_path() {
    printf '%s/.config/syncpss/maintainer-id.env' "${HOME}"
}

maintainer_hash_file_path() {
    local repo_root
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"
    printf '%s/config/maintainer_id.sha256' "${repo_root}"
}

maintainer_legacy_hash_file_paths() {
    local repo_root
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"
    printf '%s\n' \
        "${repo_root}/scripts/maintainer_id.sha256" \
        "${repo_root}/maintainer_id.sha256"
}

maintainer_legacy_identity_path() {
    printf '%s/.config/syncpss/release.identity' "${HOME}"
}

maintainer_manifest_path() {
    local repo_root
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"
    printf '%s/manifest.xml' "${repo_root}"
}

maintainer_validate_id() {
    local value="${1:-}"
    [[ -n "${value}" && "${value}" =~ ^[A-Za-z0-9]+$ ]]
}

maintainer_random_id() {
    local generated=""
    while [ "${#generated}" -lt 32 ]; do
        generated="${generated}$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
        generated="${generated:0:32}"
    done
    printf '%s' "${generated}"
}

maintainer_sha256_text() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

maintainer_current_id() {
    local repo_root seed env_file
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"

    if [ -n "${SYNCPSS_MAINTAINER_ID:-}" ]; then
        printf '%s' "${SYNCPSS_MAINTAINER_ID}"
        return 0
    fi

    env_file="$(maintainer_env_file_path)"
    if [ -f "${env_file}" ]; then
        seed="$(sed -n 's/^export[[:space:]]\+SYNCPSS_MAINTAINER_ID=//p' "${env_file}" | head -n1 | tr -d '\r\n')"
        if [ -n "${seed}" ]; then
            printf '%s' "${seed}"
            return 0
        fi
    fi

    return 1
}

maintainer_expected_hash() {
    local repo_root hash_path manifest_path value candidate_path
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"
    while IFS= read -r candidate_path; do
        [ -n "${candidate_path}" ] || continue
        if [ -f "${candidate_path}" ]; then
            value="$(awk 'NR==1 { print $1 }' "${candidate_path}")"
            if [ -n "${value}" ]; then
                printf '%s' "${value}"
                return 0
            fi
        fi
    done <<EOF
$(maintainer_hash_file_path "${repo_root}")
$(maintainer_legacy_hash_file_paths "${repo_root}")
EOF

    if value="$(maintainer_current_id "${repo_root}" 2>/dev/null)"; then
        if [ -n "${value}" ]; then
            maintainer_update_hash_artifacts "${repo_root}" "${value}"
            return 0
        fi
    fi

    manifest_path="$(maintainer_manifest_path "${repo_root}")"
    if [ -f "${manifest_path}" ]; then
        value="$(tr '\n' ' ' < "${manifest_path}" | sed -n 's:.*<id_hash>\([^<]*\)</id_hash>.*:\1:p' | head -n1)"
        if [ -n "${value}" ]; then
            printf '%s' "${value}"
            return 0
        fi
    fi

    printf '%s' "${SYNCPSS_MAINTAINER_LEGACY_HASH}"
}

maintainer_update_hash_artifacts() {
    local repo_root seed hash hash_path manifest_path temp_file legacy_path
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"
    seed="$2"
    hash="$(maintainer_sha256_text "${seed}")"

    hash_path="$(maintainer_hash_file_path "${repo_root}")"
    mkdir -p "$(dirname "${hash_path}")"
    printf '%s  SYNCPSS_MAINTAINER_ID\n' "${hash}" > "${hash_path}"

    while IFS= read -r legacy_path; do
        [ -n "${legacy_path}" ] || continue
        rm -f "${legacy_path}"
    done <<EOF
$(maintainer_legacy_hash_file_paths "${repo_root}")
EOF

    manifest_path="$(maintainer_manifest_path "${repo_root}")"
    if [ -f "${manifest_path}" ]; then
        temp_file="$(mktemp)"
        sed "0,/<id_hash>[^<]*<\\/id_hash>/s//<id_hash>${hash//\//\\/}<\\/id_hash>/" "${manifest_path}" > "${temp_file}"
        mv "${temp_file}" "${manifest_path}"
    fi

    printf '%s' "${hash}"
}

maintainer_persist_id_environment() {
    local value="$1"
    local config_dir env_file
    config_dir="${HOME}/.config/syncpss"
    env_file="$(maintainer_env_file_path)"

    mkdir -p "${config_dir}"
    printf 'export %s=%s\n' "${SYNCPSS_MAINTAINER_ENV_NAME}" "${value}" > "${env_file}"
    maintainer_ensure_profile_hook

    export SYNCPSS_MAINTAINER_ID="${value}"
    rm -f "$(maintainer_legacy_identity_path)"
}

maintainer_ensure_profile_hook() {
    local profile_path env_file marker_start marker_end
    profile_path="${HOME}/.profile"
    env_file="$(maintainer_env_file_path)"
    marker_start="# syncpss maintainer id start"
    marker_end="# syncpss maintainer id end"

    touch "${profile_path}"
    if grep -Fq "${marker_start}" "${profile_path}" 2>/dev/null; then
        return 0
    fi

    {
        printf '\n%s\n' "${marker_start}"
        printf 'if [ -f "%s" ]; then\n' "${env_file}"
        printf '    . "%s"\n' "${env_file}"
        printf 'fi\n'
        printf '%s\n' "${marker_end}"
    } >> "${profile_path}"
}

maintainer_set_persisted_id() {
    local repo_root value hash
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"
    value="$2"

    maintainer_validate_id "${value}" || {
        printf 'error: Maintainer ID must be alphanumeric.\n' >&2
        return 1
    }

    maintainer_persist_id_environment "${value}"
    hash="$(maintainer_update_hash_artifacts "${repo_root}" "${value}")"
    printf '%s' "${hash}"
}

maintainer_use_id() {
    local repo_root value hash_path expected_hash actual_hash
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"
    value="$2"

    maintainer_validate_id "${value}" || {
        printf 'error: Maintainer ID must be alphanumeric.\n' >&2
        return 1
    }

    hash_path="$(maintainer_hash_file_path "${repo_root}")"
    if [ -f "${hash_path}" ]; then
        expected_hash="$(maintainer_expected_hash "${repo_root}")"
        actual_hash="$(maintainer_sha256_text "${value}")"
        if [ "${actual_hash}" != "${expected_hash}" ]; then
            printf 'error: The entered maintainer ID does not match config/maintainer_id.sha256.\n' >&2
            return 1
        fi

        maintainer_persist_id_environment "${value}"
        printf '%s' "${expected_hash}"
        return 0
    fi

    maintainer_set_persisted_id "${repo_root}" "${value}"
}

maintainer_remove_persisted_id() {
    rm -f "$(maintainer_env_file_path)" "$(maintainer_legacy_identity_path)"
    unset SYNCPSS_MAINTAINER_ID || true
}

maintainer_format_id() {
    local value="${1:-}"
    if [ -z "${value}" ]; then
        printf '<not set>'
        return 0
    fi
    if [ "${#value}" -le 8 ]; then
        printf '%s' "${value}"
        return 0
    fi
    printf '%s...%s' "${value:0:4}" "${value:${#value}-4}"
}

maintainer_can_prompt() {
    [ -t 0 ] && [ -t 1 ]
}

maintainer_prompt_initialize() {
    local repo_root message answer selection entered generated hash hash_path
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"
    hash_path="$(maintainer_hash_file_path "${repo_root}")"
    if [ -f "${hash_path}" ]; then
        message="Missing SYNCPSS_MAINTAINER_ID. The repo already has ${hash_path}, so enter the existing maintainer ID or rotate it."
    else
        message="Missing SYNCPSS_MAINTAINER_ID and no source maintainer hash exists yet at ${hash_path}."
    fi

    if ! maintainer_can_prompt; then
        printf '%s\n' "${message}" >&2
        return 1
    fi

    printf '%s\n' "${message}" >&2
    read -r -p "Set SYNCPSS_MAINTAINER_ID now for this Linux user? [Y/n] " answer
    if [ -n "${answer}" ] && ! [[ "${answer}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        printf '%s\n' "${message}" >&2
        return 1
    fi

    while true; do
        printf '\n' >&2
        local default_selection
        if [ -f "${hash_path}" ]; then
            default_selection="1"
        else
            default_selection="2"
        fi
        if [ -f "${hash_path}" ]; then
            printf '  [1] Enter the existing maintainer ID and save it to the user environment\n' >&2
            printf '  [2] Rotate the maintainer ID and rewrite config/maintainer_id.sha256\n' >&2
        else
            printf '  [1] Enter an existing maintainer ID and create config/maintainer_id.sha256\n' >&2
            printf '  [2] Generate a new 32-character maintainer ID\n' >&2
        fi
        printf '  [3] Cancel\n' >&2
        read -r -p "Choose an option [${default_selection}]: " selection
        selection="${selection:-$default_selection}"
        case "${selection}" in
            1)
                read -r -p "Enter the maintainer ID: " entered
                maintainer_validate_id "${entered}" || {
                    printf 'error: Maintainer ID must be alphanumeric.\n' >&2
                    continue
                }
                if ! hash="$(maintainer_use_id "${repo_root}" "${entered}")"; then
                    continue
                fi
                printf 'Saved maintainer ID. Repo hash is %s\n' "${hash}" >&2
                printf '%s' "${entered}"
                return 0
                ;;
            2)
                generated="$(maintainer_random_id)"
                hash="$(maintainer_set_persisted_id "${repo_root}" "${generated}")"
                printf 'Generated maintainer ID: %s\n' "${generated}" >&2
                printf 'Repo hash is now %s\n' "${hash}" >&2
                printf '%s' "${generated}"
                return 0
                ;;
            3)
                printf '%s\n' "${message}" >&2
                return 1
                ;;
            *)
                printf 'error: Invalid selection.\n' >&2
                ;;
        esac
    done
}

maintainer_menu() {
    local repo_root current_id current_hash selection entered generated hash confirm
    repo_root="$(maintainer_resolve_repo_root "${1:-}")"

    while true; do
        current_id="$(maintainer_current_id "${repo_root}" || true)"
        current_hash="$(maintainer_expected_hash "${repo_root}")"

        printf '\n'
        printf 'syncpss maintainer ID manager\n'
        printf 'Current ID: %s\n' "$(maintainer_format_id "${current_id}")"
        printf 'Repo hash:  %s\n' "${current_hash}"
        printf '\n'
        printf '  [1] Set maintainer ID\n'
        printf '  [2] Remove maintainer ID\n'
        printf '  [3] Rotate maintainer ID\n'
        printf '  [4] Exit\n'
        read -r -p "Choose an option [4]: " selection
        selection="${selection:-4}"

        case "${selection}" in
            1)
                read -r -p "Enter the maintainer ID: " entered
                maintainer_validate_id "${entered}" || {
                    printf 'error: Maintainer ID must be alphanumeric.\n' >&2
                    continue
                }
                if ! hash="$(maintainer_use_id "${repo_root}" "${entered}")"; then
                    continue
                fi
                printf 'Saved maintainer ID. Repo hash is %s\n' "${hash}"
                ;;
            2)
                read -r -p "Remove the persisted maintainer ID from this machine? [y/N] " confirm
                if [[ "${confirm}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
                    maintainer_remove_persisted_id
                    printf 'Removed the persisted maintainer ID from this machine.\n'
                fi
                ;;
            3)
                generated="$(maintainer_random_id)"
                hash="$(maintainer_set_persisted_id "${repo_root}" "${generated}")"
                printf 'Rotated maintainer ID to %s\n' "${generated}"
                printf 'Repo hash is now %s\n' "${hash}"
                ;;
            4)
                return 0
                ;;
            *)
                printf 'error: Invalid selection.\n' >&2
                ;;
        esac
    done
}
