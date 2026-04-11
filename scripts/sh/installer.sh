#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-install}"
REPO_OWNER="KffeePt"
REPO_NAME="syncpss"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/maintainer_id.sh" ]; then
    . "${SCRIPT_DIR}/maintainer_id.sh"
else
    maintainer_current_id() {
        return 1
    }

    maintainer_expected_hash() {
        return 1
    }
fi
INSTALL_ASSET="install"
INSTALL_SHA_ASSET="install.sha256"
SYNCPS_ASSET="syncpss-linux-x86_64"
SYNCPS_SHA_ASSET="syncpss-linux-x86_64.sha256"
MANIFEST_ASSET="manifest.xml"
MANIFEST_SHA_ASSET="manifest.xml.sha256"
UNINSTALL_ASSET="uninstall_syncpss.sh"
UNINSTALL_SHA_ASSET="uninstall_syncpss.sh.sha256"
MASTER_FINGERPRINT_ASSET="master_fingerprint.sha256"
REPO_MANIFEST_FILE="manifest.xml"
GITHUB_API_BASE="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
STORE_DIR="${HOME}/.password-store"
STORE_HASH_FILE=".syncpss-store.sha256"
DEFAULT_REPO_NAME="password-store"
SSH_KEY_PATH="${HOME}/.ssh/syncpss_ed25519"
SSH_PUB_PATH="${SSH_KEY_PATH}.pub"
RUNTIME_DIR="${HOME}/.syncpss"
RUNTIME_CONFIG_DIR="${RUNTIME_DIR}/config"
TMP_DIR="${RUNTIME_DIR}/tmp"
STORE_BACKUPS_DIR="${RUNTIME_DIR}/store-backups"
GNUPG_BACKUPS_DIR="${RUNTIME_DIR}/gnupg-backups"
INSTALL_ASSETS_DIR="${RUNTIME_DIR}/install-assets"
SETTINGS_DIR="${HOME}/.config/syncpss"
SETTINGS_FILE="${SETTINGS_DIR}/preferences.env"
BRANCH="main"
APT_UPDATED=0
STORE_BOOTSTRAP_MODE=""
STORE_REMOTE_KEYS_PRESENT=0
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_GROUP="$(id -gn "${REAL_USER}" 2>/dev/null || id -gn)"
MAX_STORE_BACKUPS=10
MAX_GNUPG_BACKUPS=20
VERACRYPT_TIMEOUT_SECONDS="${SYNCPSS_VERACRYPT_TIMEOUT_SECONDS:-20}"
ANSI_ENABLED=0
MOTION_ENABLED=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    ANSI_ENABLED=1
    COLOR_RESET=$'\033[0m'
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_CYAN=$'\033[36m'
    COLOR_BLUE=$'\033[34m'
    COLOR_MAGENTA=$'\033[35m'
else
    COLOR_RESET=''
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_CYAN=''
    COLOR_BLUE=''
    COLOR_MAGENTA=''
fi

if [ -t 1 ] && [ "${TERM:-}" != "dumb" ] && [ "${SYNCPSS_REDUCED_MOTION:-0}" != "1" ]; then
    MOTION_ENABLED=1
fi

wave_text() {
    local text="$1"
    if [ "${ANSI_ENABLED}" -ne 1 ]; then
        printf '%s' "${text}"
        return
    fi

    local palette=("${COLOR_CYAN}" "${COLOR_BLUE}" "${COLOR_MAGENTA}" "${COLOR_YELLOW}" "${COLOR_GREEN}")
    local output='' index char color_index
    for ((index=0; index<${#text}; ++index)); do
        char="${text:index:1}"
        if [ "${char}" = ' ' ]; then
            output+=" "
            continue
        fi
        color_index=$(( (index * 3 + index * index) % ${#palette[@]} ))
        output+="${palette[${color_index}]}${char}"
    done
    output+="${COLOR_RESET}"
    printf '%s' "${output}"
}

progress_step() {
    local current="$1"
    local total="$2"
    local label="$3"
    local percent filled empty

    percent=$(( current * 100 / total ))
    filled=$(( percent / 10 ))
    empty=$(( 10 - filled ))

    printf '\n'
    printf '%s>> [%s%s] %3d%%%s %s\n' \
        "${COLOR_GREEN}" \
        "$(printf '%*s' "${filled}" '' | tr ' ' '#')" \
        "$(printf '%*s' "${empty}" '' | tr ' ' '-')" \
        "${percent}" \
        "${COLOR_RESET}" \
        "${label}"
}

run_with_spinner() {
    local message="$1"
    shift

    if [ "${MOTION_ENABLED}" -ne 1 ]; then
        info "${message}"
        "$@"
        return
    fi

    local log_file pid status=0 spinner_index=0
    local spinner='|/-\'
    log_file="$(mktemp)"
    "$@" >"${log_file}" 2>&1 &
    pid=$!

    while kill -0 "${pid}" >/dev/null 2>&1; do
        printf '\r%s>> %s %s%s' "${COLOR_CYAN}" "${message}" "${spinner:${spinner_index}:1}" "${COLOR_RESET}"
        spinner_index=$(( (spinner_index + 1) % 4 ))
        sleep 0.12
    done

    wait "${pid}" || status=$?
    printf '\r\033[K' 2>/dev/null || true

    if [ "${status}" -ne 0 ]; then
        cat "${log_file}" >&2
        rm -f "${log_file}"
        return "${status}"
    fi

    rm -f "${log_file}"
    success ">> ${message}"
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf '%swarning:%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
}

fail() {
    printf '%serror:%s %s\n' "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2
    exit 1
}

section() {
    local text="$*"
    if [ -n "${text}" ]; then
        text="$(printf '%s' "${text}" | awk '{ if (length($1) > 0) { $1 = toupper(substr($1,1,1)) substr($1,2) } print }')"
    fi
    printf '\n%s>> %s%s\n' "${COLOR_YELLOW}" "${text}" "${COLOR_RESET}"
}

info() {
    printf '%s%s%s\n' "${COLOR_CYAN}" "$*" "${COLOR_RESET}"
}

success() {
    printf '%s%s%s\n' "${COLOR_GREEN}" "$*" "${COLOR_RESET}"
}

prompt_label() {
    printf '%s>> %s%s' "${COLOR_BLUE}" "$1" "${COLOR_RESET}" >&2
}

auto_accept_default_enabled() {
    [ "${SYNCPSS_AUTO_ADVANCE_DEFAULTS:-0}" = "1" ]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
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
            if ! answer_is_yes "${answer}"; then
                return "${status}"
            fi
            sudo -k >/dev/null 2>&1 || true
        done
    fi
}

ensure_runtime_dir_ownership() {
    if [ -e "${RUNTIME_DIR}" ]; then
        sudo_run chown -R "${REAL_USER}:${REAL_GROUP}" "${RUNTIME_DIR}"
    fi

    sudo_run install -d -m 700 -o "${REAL_USER}" -g "${REAL_GROUP}" "${RUNTIME_DIR}"
    sudo_run install -d -m 700 -o "${REAL_USER}" -g "${REAL_GROUP}" "${RUNTIME_CONFIG_DIR}"
    sudo_run install -d -m 700 -o "${REAL_USER}" -g "${REAL_GROUP}" "${TMP_DIR}"
    sudo_run install -d -m 700 -o "${REAL_USER}" -g "${REAL_GROUP}" "${STORE_BACKUPS_DIR}"
    sudo_run install -d -m 700 -o "${REAL_USER}" -g "${REAL_GROUP}" "${GNUPG_BACKUPS_DIR}"
    sudo_run install -d -m 700 -o "${REAL_USER}" -g "${REAL_GROUP}" "${INSTALL_ASSETS_DIR}"
}

ensure_settings_dir() {
    sudo_run install -d -m 700 -o "${REAL_USER}" -g "${REAL_GROUP}" "${SETTINGS_DIR}"
}

load_saved_private_repo_name() {
    if [ -n "${SYNCPSS_PRIVATE_REPO_NAME:-}" ]; then
        printf '%s\n' "${SYNCPSS_PRIVATE_REPO_NAME}"
        return 0
    fi
    [ -f "${SETTINGS_FILE}" ] || return 0
    sed -n 's/^SYNCPSS_PRIVATE_REPO_NAME=//p' "${SETTINGS_FILE}" | head -n 1
}

save_saved_private_repo_name() {
    local repo_name="$1"
    local temp_file

    [ -n "${repo_name}" ] || return 0
    ensure_settings_dir
    temp_file="$(mktemp)"
    printf 'SYNCPSS_PRIVATE_REPO_NAME=%s\n' "${repo_name}" > "${temp_file}"
    sudo_run install -m 600 -o "${REAL_USER}" -g "${REAL_GROUP}" "${temp_file}" "${SETTINGS_FILE}"
    rm -f "${temp_file}"
}

prune_old_store_backups() {
    ensure_runtime_dir_ownership

    [ -d "${STORE_BACKUPS_DIR}" ] || return 0

    local backups=()
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        backups+=("${entry}")
    done < <(find "${STORE_BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)

    local count="${#backups[@]}"
    if [ "${count}" -le "${MAX_STORE_BACKUPS}" ]; then
        return 0
    fi

    local to_remove=$((count - MAX_STORE_BACKUPS))
    local index
    for ((index=0; index<to_remove; ++index)); do
        local target="${STORE_BACKUPS_DIR}/${backups[${index}]}"
        log "Pruning old backup ${target}"
        rm -rf "${target}"
    done
}

prune_old_gnupg_backups() {
    ensure_runtime_dir_ownership

    [ -d "${GNUPG_BACKUPS_DIR}" ] || return 0

    local backups=()
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        backups+=("${entry}")
    done < <(find "${GNUPG_BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)

    local count="${#backups[@]}"
    if [ "${count}" -le "${MAX_GNUPG_BACKUPS}" ]; then
        return 0
    fi

    local to_remove=$((count - MAX_GNUPG_BACKUPS))
    local index
    for ((index=0; index<to_remove; ++index)); do
        local target="${GNUPG_BACKUPS_DIR}/${backups[${index}]}"
        log "Pruning old GPG backup ${target}"
        rm -rf "${target}"
    done
}

apt_run() {
    local timeout_seconds="${SYNCPSS_APT_LOCK_TIMEOUT:-300}"
    sudo_run env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout="${timeout_seconds}" "$@"
}

wait_for_apt_processes() {
    local timeout_seconds elapsed
    timeout_seconds="${SYNCPSS_APT_LOCK_TIMEOUT:-300}"
    elapsed=0

    while pgrep -x apt >/dev/null 2>&1 || \
          pgrep -x apt-get >/dev/null 2>&1 || \
          pgrep -x dpkg >/dev/null 2>&1 || \
          pgrep -f unattended-upgrade >/dev/null 2>&1; do
        if [ "${elapsed}" -ge "${timeout_seconds}" ]; then
            fail "Timed out waiting for other apt/dpkg processes to finish"
        fi
        if [ $((elapsed % 10)) -eq 0 ]; then
            log "Waiting for other apt/dpkg processes to finish... ${elapsed}/${timeout_seconds}s"
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
}

apt_process_summary() {
    ps -ef | grep -E 'apt|dpkg|unattended' | grep -v grep || true
}

apt_update_once() {
    if [ "${APT_UPDATED}" -eq 1 ]; then
        return
    fi
    wait_for_apt_processes
    apt_run update
    APT_UPDATED=1
}

detect_pkg_manager() {
    if command_exists apt-get; then
        printf 'apt'
    elif command_exists dnf; then
        printf 'dnf'
    elif command_exists pacman; then
        printf 'pacman'
    elif command_exists zypper; then
        printf 'zypper'
    else
        printf 'unknown'
    fi
}

install_packages() {
    local pkg_manager
    pkg_manager="$(detect_pkg_manager)"
    case "${pkg_manager}" in
        apt)
            log "Using apt to install packages: $*"
            apt_update_once
            wait_for_apt_processes
            apt_run install -y "$@"
            ;;
        dnf)
            sudo_run dnf install -y "$@"
            ;;
        pacman)
            sudo_run pacman -Sy --noconfirm "$@"
            ;;
        zypper)
            sudo_run zypper install -y "$@"
            ;;
        *)
            fail "Unsupported package manager. Install these manually: $*"
            ;;
    esac
}

install_runtime_dependencies() {
    local pkg_manager
    pkg_manager="$(detect_pkg_manager)"
    case "${pkg_manager}" in
        apt)
            install_packages git pass gnupg openssh-client curl xclip zip unzip
            ;;
        dnf)
            install_packages git gh pass gnupg2 openssh-clients curl xclip zip unzip
            ;;
        pacman)
            install_packages git github-cli pass gnupg openssh curl xclip zip unzip
            ;;
        zypper)
            install_packages git gh pass gpg2 openssh curl xclip zip unzip
            ;;
        *)
            fail "Unsupported package manager for runtime dependencies"
            ;;
    esac
}

install_github_cli() {
    if command_exists gh; then
        return
    fi

    local pkg_manager
    pkg_manager="$(detect_pkg_manager)"
    case "${pkg_manager}" in
        apt)
            apt_update_once
            wait_for_apt_processes
            sudo_run install -d -m 0755 /etc/apt/keyrings
            if [ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]; then
                curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
                    sudo_run tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
                sudo_run chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
            fi
            local arch
            arch="$(dpkg --print-architecture)"
            printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "${arch}" |
                sudo_run tee /etc/apt/sources.list.d/github-cli.list >/dev/null
            APT_UPDATED=0
            apt_update_once
            wait_for_apt_processes
            apt_run install -y gh
            ;;
        dnf)
            install_packages gh
            ;;
        pacman)
            install_packages github-cli
            ;;
        zypper)
            install_packages gh
            ;;
        *)
            fail "Unsupported package manager for GitHub CLI installation"
            ;;
    esac
}

install_build_dependencies() {
    local pkg_manager
    pkg_manager="$(detect_pkg_manager)"
    case "${pkg_manager}" in
        apt)
            install_packages cmake g++ make pkg-config libncurses5-dev nlohmann-json3-dev
            ;;
        dnf)
            install_packages cmake gcc-c++ make pkgconf-pkg-config ncurses-devel nlohmann-json-devel
            ;;
        pacman)
            install_packages cmake gcc make pkgconf ncurses nlohmann-json
            ;;
        zypper)
            install_packages cmake gcc-c++ make pkg-config ncurses-devel nlohmann_json-devel
            ;;
        *)
            fail "Unsupported package manager for build dependencies"
            ;;
    esac
}

install_veracrypt() {
    if command_exists veracrypt; then
        return
    fi

    local pkg_manager
    pkg_manager="$(detect_pkg_manager)"
    case "${pkg_manager}" in
        apt)
            if apt-cache show veracrypt >/dev/null 2>&1; then
                apt_run install -y veracrypt || true
            fi
            ;;
        dnf)
            sudo_run dnf install -y veracrypt || true
            ;;
        pacman)
            sudo_run pacman -Sy --noconfirm veracrypt || true
            ;;
        zypper)
            sudo_run zypper install -y veracrypt || true
            ;;
    esac

    if ! command_exists veracrypt; then
        warn "VeraCrypt is not installed yet. Install it manually later if you want encrypted GPG key portability."
    fi
}

clipboard_copy() {
    local source_file="$1"
    if command_exists clip.exe; then
        clip.exe < "${source_file}"
        return 0
    fi
    if command_exists xclip; then
        xclip -selection clipboard < "${source_file}"
        return 0
    fi
    if command_exists xsel; then
        xsel --clipboard --input < "${source_file}"
        return 0
    fi
    return 1
}

prompt_value() {
    local message="$1"
    local default_value="${2:-}"
    local input

    if [ -n "${default_value}" ]; then
        if auto_accept_default_enabled; then
            prompt_label "${message} [${default_value}]"
            printf ' %s(auto)%s %s\n' "${COLOR_GREEN}" "${COLOR_RESET}" "${default_value}" >&2
            printf '%s' "${default_value}"
            return 0
        fi
        prompt_label "${message} [${default_value}]: "
        read -r input
        printf '%s' "${input:-${default_value}}"
    else
        prompt_label "${message}: "
        read -r input
        printf '%s' "${input}"
    fi
}

validate_github_repo_name() {
    local repo_name="$1"
    [ -n "${repo_name}" ] || return 1
    case "${repo_name}" in
        *[!A-Za-z0-9._-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

prompt_private_repo_name() {
    local default_value="$1"
    local github_user="$2"
    local repo_name

    while true; do
        repo_name="$(prompt_value 'Private password-store repo name' "${default_value}")"
        repo_name="$(printf '%s' "${repo_name}" | tr -d '\r')"
        if validate_github_repo_name "${repo_name}"; then
            printf '%s' "${repo_name}"
            return 0
        fi
        warn "Use only letters, numbers, '.', '_' or '-' in the repo name. Example: ${github_user}/${default_value}"
    done
}

repo_name_from_repo_id() {
    local repo_id="$1"
    case "${repo_id}" in
        */*)
            printf '%s' "${repo_id##*/}"
            ;;
        *)
            printf '%s' "${repo_id}"
            ;;
    esac
}

parse_repo_name_from_remote_url() {
    local remote_url="$1"
    local trimmed
    trimmed="$(printf '%s' "${remote_url}" | tr -d '\r')"
    trimmed="${trimmed%.git}"

    case "${trimmed}" in
        git@github.com:*)
            printf '%s' "${trimmed##*/}"
            return 0
            ;;
        https://github.com/*)
            printf '%s' "${trimmed##*/}"
            return 0
            ;;
        ssh://git@github.com/*)
            printf '%s' "${trimmed##*/}"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

detected_private_repo_name() {
    local configured_repo configured_repo_name remote_url remote_repo_name

    configured_repo_name="$(load_saved_private_repo_name || true)"
    if [ -n "${configured_repo_name}" ]; then
        printf '%s' "${configured_repo_name}"
        return 0
    fi

    configured_repo_name="$(runtime_config_string_field "repo_name" || true)"
    if [ -n "${configured_repo_name}" ]; then
        printf '%s' "${configured_repo_name}"
        return 0
    fi

    configured_repo="$(runtime_config_string_field "repo" || true)"
    if [ -n "${configured_repo}" ]; then
        configured_repo_name="$(repo_name_from_repo_id "${configured_repo}")"
        if [ -n "${configured_repo_name}" ]; then
            printf '%s' "${configured_repo_name}"
            return 0
        fi
    fi

    if [ -d "${STORE_DIR}/.git" ] && git -C "${STORE_DIR}" remote get-url origin >/dev/null 2>&1; then
        remote_url="$(git -C "${STORE_DIR}" remote get-url origin 2>/dev/null || true)"
        if remote_repo_name="$(parse_repo_name_from_remote_url "${remote_url}")"; then
            printf '%s' "${remote_repo_name}"
            return 0
        fi
    fi

    return 1
}

prompt_secret() {
    local message="$1"
    local input
    while true; do
        prompt_label "${message}: "
        if ! read -r -s input; then
            printf '\n' >&2
            fail "${message} input was not provided."
        fi
        printf '\n' >&2
        if [ -n "${input}" ]; then
            printf '%s' "${input}"
            return 0
        fi
        warn "${message} is required."
    done
}

answer_is_yes() {
    local value="${1:-}"
    [ -z "${value}" ] && return 0
    case "${value}" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_github_auth() {
    if gh auth status >/dev/null 2>&1; then
        return
    fi

    log "GitHub CLI is not authenticated yet. Starting gh auth login for GitHub.com over SSH..."
    if gh auth login --hostname github.com --git-protocol ssh --web --clipboard; then
        return
    fi

    warn "Retrying GitHub auth without automatic clipboard copy."
    gh auth login --hostname github.com --git-protocol ssh --web
}

ensure_git_identity() {
    local current_name current_email new_name new_email
    current_name="$(git config --global --get user.name || true)"
    current_email="$(git config --global --get user.email || true)"

    new_name="$(prompt_value 'Git user.name (optional)' "${current_name}")"
    new_email="$(prompt_value 'Git user.email (optional)' "${current_email}")"

    if [ -n "${new_name}" ]; then
        git config --global user.name "${new_name}"
    fi
    if [ -n "${new_email}" ]; then
        git config --global user.email "${new_email}"
    fi
}

find_existing_pubkey() {
    local candidate
    for candidate in \
        "${SSH_PUB_PATH}" \
        "${HOME}/.ssh/id_ed25519.pub" \
        "${HOME}/.ssh/id_rsa.pub"
    do
        if [ -f "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

ensure_ssh_key() {
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"

    local pubkey_path created_new_key=0
    if pubkey_path="$(find_existing_pubkey)"; then
        log "Using existing SSH public key: ${pubkey_path}"
    else
        log "Generating a new Ed25519 SSH key at ${SSH_KEY_PATH}"
        ssh-keygen -t ed25519 -f "${SSH_KEY_PATH}" -N "" -C "syncpss@$(hostname)"
        pubkey_path="${SSH_PUB_PATH}"
        created_new_key=1
    fi

    if clipboard_copy "${pubkey_path}"; then
        log "Copied SSH public key to your clipboard."
    else
        warn "Could not copy the SSH key automatically. Copy it manually from: ${pubkey_path}"
    fi

    if [ "${created_new_key}" = "1" ]; then
        log
        log "Add this SSH key to GitHub before continuing:"
        log "  Personal/account key for normal sync access:"
        log "    https://github.com/settings/keys"
        log "  Repo deploy key for invited/read-only use:"
        log "    Open your pass-store repo > Settings > Deploy keys"
        log "    Use a deploy key when you want to share access without giving write access."
        log
        read -r -p "Press Enter after the key is authorized on GitHub..."
    else
        info "Existing SSH key detected. Reusing it and continuing."
    fi

    verify_github_host_key
    ssh -o StrictHostKeyChecking=yes -T git@github.com >/dev/null 2>&1 || true
}

verify_github_host_key() {
    local expected_fingerprint="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
    local temp_scan
    temp_scan="$(mktemp)"

    ssh-keyscan -t ed25519 github.com > "${temp_scan}" 2>/dev/null || {
        rm -f "${temp_scan}"
        fail "Unable to retrieve GitHub's Ed25519 host key."
    }

    local actual_fingerprint
    actual_fingerprint="$(ssh-keygen -lf "${temp_scan}" -E sha256 2>/dev/null | awk 'NR==1 { print $2 }')"
    [ "${actual_fingerprint}" = "${expected_fingerprint}" ] || {
        rm -f "${temp_scan}"
        fail "GitHub host key fingerprint mismatch. Expected ${expected_fingerprint}, got ${actual_fingerprint:-<none>}."
    }

    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    touch "${HOME}/.ssh/known_hosts"
    chmod 600 "${HOME}/.ssh/known_hosts"
    awk '
        $1 != "github.com" || $2 != "ssh-ed25519" { print }
    ' "${HOME}/.ssh/known_hosts" > "${HOME}/.ssh/known_hosts.syncpss.tmp" 2>/dev/null || true
    mv "${HOME}/.ssh/known_hosts.syncpss.tmp" "${HOME}/.ssh/known_hosts"
    if [ -s "${HOME}/.ssh/known_hosts" ] && [ "$(tail -c 1 "${HOME}/.ssh/known_hosts" 2>/dev/null || true)" != "" ]; then
        printf '\n' >> "${HOME}/.ssh/known_hosts"
    fi
    cat "${temp_scan}" >> "${HOME}/.ssh/known_hosts"
    rm -f "${temp_scan}"
}

veracrypt_with_password() {
    local password="$1"
    shift
    if command_exists timeout; then
        printf '%s\n' "${password}" | timeout --foreground "${VERACRYPT_TIMEOUT_SECONDS}s" \
            veracrypt --text --non-interactive --stdin "$@"
        return $?
    fi

    printf '%s\n' "${password}" | veracrypt --text --non-interactive --stdin "$@"
}

list_secret_key_fingerprints() {
    gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }'
}

list_public_key_fingerprints() {
    gpg --list-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }'
}

count_secret_key_fingerprints() {
    local fingerprints
    fingerprints="$(list_secret_key_fingerprints || true)"
    if [ -z "${fingerprints}" ]; then
        printf '0'
        return
    fi
    printf '%s\n' "${fingerprints}" | sed '/^$/d' | wc -l | tr -d ' '
}

count_public_key_fingerprints() {
    local fingerprints
    fingerprints="$(list_public_key_fingerprints || true)"
    if [ -z "${fingerprints}" ]; then
        printf '0'
        return
    fi
    printf '%s\n' "${fingerprints}" | sed '/^$/d' | wc -l | tr -d ' '
}

describe_local_gnupg_state() {
    local secret_count public_count

    if [ ! -d "${HOME}/.gnupg" ]; then
        printf 'No local ~/.gnupg directory exists yet on this Linux profile.'
        return
    fi

    secret_count="$(count_secret_key_fingerprints)"
    public_count="$(count_public_key_fingerprints)"

    if [ "${secret_count}" -gt 0 ]; then
        printf 'Local ~/.gnupg exists and already contains %s secret key(s) and %s public key(s).' "${secret_count}" "${public_count}"
        return
    fi

    if [ "${public_count}" -gt 0 ]; then
        printf 'Local ~/.gnupg exists and contains %s public key(s), but no secret keys.' "${public_count}"
        return
    fi

    printf 'Local ~/.gnupg exists, but no GPG keys were detected in it yet.'
}

extract_key_fingerprints_from_file() {
    local key_file="$1"
    [ -f "${key_file}" ] || return 0
    gpg --show-keys --with-colons "${key_file}" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }'
}

collect_current_key_bundle() {
    local bundle_dir="$1"
    mkdir -p "${bundle_dir}"
    if gpg --list-keys >/dev/null 2>&1; then
        gpg --armor --export > "${bundle_dir}/pubkeys.asc" 2>/dev/null || true
    else
        : > "${bundle_dir}/pubkeys.asc"
    fi

    if gpg --list-secret-keys >/dev/null 2>&1; then
        gpg --armor --export-secret-keys > "${bundle_dir}/seckeys.asc" 2>/dev/null || true
    else
        : > "${bundle_dir}/seckeys.asc"
    fi

    gpg --export-ownertrust > "${bundle_dir}/ownertrust.txt" 2>/dev/null || : > "${bundle_dir}/ownertrust.txt"
}

same_file_content() {
    local left="$1"
    local right="$2"
    if [ ! -f "${left}" ] && [ ! -f "${right}" ]; then
        return 0
    fi
    if [ ! -f "${left}" ] || [ ! -f "${right}" ]; then
        return 1
    fi
    cmp -s "${left}" "${right}"
}

directory_size_bytes() {
    local target_dir="$1"
    [ -d "${target_dir}" ] || {
        printf '0'
        return 0
    }

    find "${target_dir}" -type f -printf '%s\n' 2>/dev/null | awk '{ total += $1 } END { print total + 0 }'
}

keys_container_size_mb_for() {
    local target_dir="$1"
    local bytes megabytes
    bytes="$(directory_size_bytes "${target_dir}")"
    megabytes=$(( (bytes + 1048575) / 1048576 ))
    if [ "${megabytes}" -lt 20 ]; then
        megabytes=20
    fi
    if [ $((megabytes % 5)) -ne 0 ]; then
        megabytes=$(( megabytes + 5 - (megabytes % 5) ))
    fi
    printf '%s' "${megabytes}"
}

write_keys_container_manifest() {
    local destination="$1"
    cat > "${destination}/manifest.xml" <<'EOF'
<syncpss>
  <type>keys</type>
  <exports>
    <file>
      <path>manifest.xml</path>
      <description>Container manifest describing the portable GPG key backup.</description>
    </file>
    <file>
      <path>pubkeys.asc</path>
      <description>Exported public keys from the GPG keyring stored in this container.</description>
    </file>
    <file>
      <path>seckeys.asc</path>
      <description>Exported secret keys from the GPG keyring stored in this container.</description>
    </file>
    <file>
      <path>ownertrust.txt</path>
      <description>Ownertrust assignments associated with the exported GPG keys.</description>
    </file>
    <file>
      <path>.gnupg/</path>
      <description>Raw .gnupg directory snapshot used for full keyring replacement and recovery.</description>
    </file>
  </exports>
</syncpss>
EOF
}

find_gnupg_source_dir() {
    local mount_point="$1"
    local candidate
    for candidate in \
        "${mount_point}/.gnupg" \
        "${mount_point}/gnupg"
    do
        if [ -d "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

find_existing_veracrypt_mount() {
    local volume_path="$1"
    veracrypt --text --list 2>/dev/null | tr -d '\r' | awk -v volume="${volume_path}" '
        index($0, volume) > 0 {
            for (i = NF; i >= 1; --i) {
                if ($i ~ /^\// && $i != volume) {
                    print $i
                    exit
                }
            }
        }
    '
}

direct_mount_veracrypt() {
    local volume_path="$1"
    local requested_mount="$2"
    local password="$3"
    local mount_options="${4:-ro}"
    local attempt_label="${5:-standard mount}"
    local log_file
    local exit_code=0
    log_file="$(mktemp)"

    log "Attempting VeraCrypt ${attempt_label} for ${volume_path} at ${requested_mount}..."
    log "Waiting for VeraCrypt to respond. Timeout: ${VERACRYPT_TIMEOUT_SECONDS}s."

    if veracrypt_with_password "${password}" --mount "${volume_path}" "${requested_mount}" \
        --pim 0 \
        --keyfiles "" \
        --protect-hidden no \
        --mount-options "${mount_options}" >"${log_file}" 2>&1; then
        rm -f "${log_file}"
        return 0
    fi
    exit_code=$?

    if [ "${exit_code}" -eq 124 ]; then
        warn "VeraCrypt ${attempt_label} timed out after ${VERACRYPT_TIMEOUT_SECONDS}s."
    else
        warn "VeraCrypt ${attempt_label} failed with exit code ${exit_code}."
    fi

    if [ -s "${log_file}" ]; then
        cat "${log_file}" >&2
    fi
    rm -f "${log_file}"
    return 1
}

mount_veracrypt_rw() {
    local volume_path="$1"
    local mount_point="$2"
    local password="$3"
    local log_file
    local exit_code=0
    log_file="$(mktemp)"

    if veracrypt_with_password "${password}" --mount "${volume_path}" "${mount_point}" \
        --pim 0 \
        --keyfiles "" \
        --protect-hidden no >"${log_file}" 2>&1; then
        rm -f "${log_file}"
        return 0
    fi
    exit_code=$?
    if [ -s "${log_file}" ]; then
        cat "${log_file}" >&2
    fi
    rm -f "${log_file}"
    return "${exit_code}"
}

path_is_mounted() {
    local target="$1"
    if command_exists mountpoint; then
        mountpoint -q "${target}" >/dev/null 2>&1
        return $?
    fi

    grep -Fqs " ${target} " /proc/mounts 2>/dev/null
}

dismount_veracrypt_mount() {
    local mount_point="$1"
    local attempt

    [ -n "${mount_point}" ] || return 0

    for attempt in 1 2 3 4 5; do
        veracrypt --text --dismount "${mount_point}" >/dev/null 2>&1 || true
        if ! path_is_mounted "${mount_point}"; then
            return 0
        fi
        sleep 1
    done

    return 1
}

cleanup_mount_dir_if_safe() {
    local mount_dir="$1"
    local attempt=1
    [ -n "${mount_dir}" ] || return 0

    while [ "${attempt}" -le 3 ]; do
        if ! path_is_mounted "${mount_dir}"; then
            break
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    if path_is_mounted "${mount_dir}"; then
        info "VeraCrypt is still using ${mount_dir}, so it will be left in place for safety."
        return 1
    fi

    rmdir "${mount_dir}" >/dev/null 2>&1 || rm -rf "${mount_dir}" >/dev/null 2>&1 || true
}

cleanup_restore_mount() {
    local mounted_here_flag="${1:-0}"
    local mount_point="${2:-}"
    local cleanup_mount_dir="${3:-}"

    if [ "${mounted_here_flag}" -eq 1 ] && [ -n "${mount_point}" ]; then
        if ! dismount_veracrypt_mount "${mount_point}"; then
            warn "VeraCrypt did not dismount cleanly from ${mount_point}. Leaving the mount directory alone."
            cleanup_mount_dir=""
        fi
    fi

    cleanup_mount_dir_if_safe "${cleanup_mount_dir}" || true
}

find_external_header_backup() {
    local volume_dir
    volume_dir="$(dirname "$1")"
    local candidate
    for candidate in \
        "${volume_dir}/header.bk" \
        "${volume_dir}/keys.header.bk"
    do
        if [ -f "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

restore_veracrypt_headers_if_needed() {
    local volume_path="$1"
    local password="$2"
    local header_backup
    local exit_code=0

    header_backup="$(find_external_header_backup "${volume_path}" || true)"
    if [ -z "${header_backup}" ]; then
        return 1
    fi

    log
    log "The VeraCrypt volume may have a damaged header."
    log "Found external header backup: ${header_backup}"
    log "Launching VeraCrypt header restore now."
    log "If VeraCrypt asks which backup source to use, choose the external backup file."
    log "Waiting for VeraCrypt to restore headers. Timeout: ${VERACRYPT_TIMEOUT_SECONDS}s."
    log

    if veracrypt_with_password "${password}" --restore-headers "${volume_path}" --pim 0 --keyfiles ""; then
        return 0
    fi
    exit_code=$?

    if [ "${exit_code}" -eq 124 ]; then
        warn "VeraCrypt header restore timed out after ${VERACRYPT_TIMEOUT_SECONDS}s."
    else
        warn "VeraCrypt header restore failed with exit code ${exit_code}."
    fi
    return 1
}

mount_or_reuse_veracrypt_volume() {
    local volume_path="$1"
    local requested_mount="$2"
    local password="$3"
    local existing_mount choice

    existing_mount="$(find_existing_veracrypt_mount "${volume_path}" || true)"
    if [ -n "${existing_mount}" ]; then
        read -r -p "The keys container is already mounted at ${existing_mount}. [c]ontinue with it or [r]emount? [c]: " choice
        choice="${choice:-c}"

        if [ "${choice}" = "r" ] || [ "${choice}" = "R" ]; then
            veracrypt --text --dismount "${existing_mount}" >/dev/null 2>&1 || fail "Failed to dismount ${existing_mount}"
            existing_mount=""
        else
            printf 'existing\t%s' "${existing_mount}"
            return 0
        fi
    fi

    if [ -z "${existing_mount}" ]; then
        if direct_mount_veracrypt "${volume_path}" "${requested_mount}" "${password}" "ro" "standard mount"; then
            printf 'mounted\t%s' "${requested_mount}"
            return 0
        fi

        if direct_mount_veracrypt "${volume_path}" "${requested_mount}" "${password}" "headerbak,ro" "embedded-backup-header mount"; then
            log "Mounted the keys container using VeraCrypt's embedded backup header."
            printf 'mounted\t%s' "${requested_mount}"
            return 0
        fi

        if restore_veracrypt_headers_if_needed "${volume_path}" "${password}"; then
            if direct_mount_veracrypt "${volume_path}" "${requested_mount}" "${password}" "ro" "post-header-restore mount"; then
                log "Mounted the keys container after restoring its header from backup."
                printf 'mounted\t%s' "${requested_mount}"
                return 0
            fi
            if direct_mount_veracrypt "${volume_path}" "${requested_mount}" "${password}" "headerbak,ro" "post-header-restore backup-header mount"; then
                log "Mounted the keys container after header restore using the embedded backup header."
                printf 'mounted\t%s' "${requested_mount}"
                return 0
            fi
        fi

        fail "Failed to mount ${volume_path}."
    fi
}

generate_syncpss_gpg_key() {
    local name_real="$1"
    local name_email="$2"
    local uid

    if [ -z "${name_real}" ]; then
        name_real="$(git config --global --get user.name || true)"
    fi
    if [ -z "${name_real}" ]; then
        name_real="$(id -un)"
    fi
    if [ -z "${name_email}" ]; then
        name_email="$(git config --global --get user.email || true)"
    fi

    uid="${name_real}"
    if [ -n "${name_email}" ]; then
        uid="${uid} <${name_email}>"
    fi

    mkdir -p "${HOME}/.gnupg"
    chmod 700 "${HOME}/.gnupg" 2>/dev/null || true
    if [ ! -f "${HOME}/.gnupg/gpg.conf" ] || ! grep -Eq '^[[:space:]]*cert-digest-algo[[:space:]]+SHA256([[:space:]]|$)' "${HOME}/.gnupg/gpg.conf"; then
        {
            printf '\n'
            printf '# syncpss defaults\n'
            printf 'personal-digest-preferences SHA256\n'
            printf 'cert-digest-algo SHA256\n'
        } >> "${HOME}/.gnupg/gpg.conf"
        chmod 600 "${HOME}/.gnupg/gpg.conf" 2>/dev/null || true
    fi

    log "No reusable GPG key was found. Generating a new RSA 4096-bit signing/encryption key for syncpss..."
    gpg --batch --quick-generate-key "${uid}" rsa4096 cert,sign 0

    local generated_fingerprint
    generated_fingerprint="$(list_secret_key_fingerprints | tail -n 1 | tr -d '\r')"
    [ -n "${generated_fingerprint}" ] || fail "GPG key generation completed, but no secret key fingerprint was detected."

    gpg --batch --quick-add-key "${generated_fingerprint}" rsa4096 encrypt 0
    printf '%s' "${generated_fingerprint}"
}

ensure_gpg_key_id() {
    local fingerprints public_fingerprints name_real name_email preferred_key runtime_key

    preferred_key="$(store_gpg_id || true)"
    if [ -n "${preferred_key}" ] && local_has_public_key "${preferred_key}"; then
        info "Using the existing password-store GPG recipient from .gpg-id: ${preferred_key}"
        printf '%s' "${preferred_key}"
        return 0
    fi

    runtime_key="$(runtime_config_string_field "key_id" || true)"
    if [ -n "${runtime_key}" ] && local_has_public_key "${runtime_key}"; then
        info "Using the saved syncpss GPG key from runtime config: ${runtime_key}"
        printf '%s' "${runtime_key}"
        return 0
    fi

    fingerprints="$(list_secret_key_fingerprints || true)"
    if [ -z "${fingerprints}" ]; then
        public_fingerprints="$(list_public_key_fingerprints || true)"
        if [ -n "${public_fingerprints}" ]; then
            preferred_key="$(printf '%s\n' "${public_fingerprints}" | sed -n '1p')"
            info "Using the first available local GPG public key for pass initialization: ${preferred_key}"
            printf '%s' "${preferred_key}"
            return 0
        fi

        name_real="$(git config --global --get user.name || true)"
        name_email="$(git config --global --get user.email || true)"
        generate_syncpss_gpg_key "${name_real}" "${name_email}"
        return 0
    fi

    preferred_key="$(printf '%s\n' "${fingerprints}" | sed -n '1p')"
    info "Using the first available local GPG secret key: ${preferred_key}"
    printf '%s' "${preferred_key}"
}

repo_exists() {
    gh repo view "$1" >/dev/null 2>&1
}

resolve_private_repo_target() {
    local github_user="$1"
    local requested_repo_name="$2"
    local candidate="${github_user}/${requested_repo_name}"

    if repo_exists "${candidate}"; then
        printf '%s' "${candidate}"
        return 0
    fi

    if [ "${requested_repo_name}" != "pass-store" ] && repo_exists "${github_user}/pass-store"; then
        info "Detected existing legacy private repo: ${github_user}/pass-store"
        printf '%s' "${github_user}/pass-store"
        return 0
    fi

    printf '%s' "${candidate}"
}

backup_existing_store_dir() {
    if [ ! -e "${STORE_DIR}" ]; then
        return
    fi

    local backup_dir
    ensure_runtime_dir_ownership
    backup_dir="${STORE_BACKUPS_DIR}/password-store.$(date +%Y%m%dT%H%M%S)"
    log "Backing up existing local password store to ${backup_dir}"
    mv "${STORE_DIR}" "${backup_dir}"
    prune_old_store_backups
}

clone_remote_store_directly() {
    local github_repo="$1"
    info "Cloning remote password store directly into ${STORE_DIR}..."
    git clone --quiet "git@github.com:${github_repo}.git" "${STORE_DIR}"
}

git_current_branch_or_default() {
    local branch_name
    branch_name="$(git -C "${STORE_DIR}" branch --show-current 2>/dev/null || true)"
    printf '%s' "${branch_name:-${BRANCH}}"
}

ensure_store_repo_remote() {
    local github_repo="$1"
    local remote_url="git@github.com:${github_repo}.git"

    if git -C "${STORE_DIR}" remote get-url origin >/dev/null 2>&1; then
        git -C "${STORE_DIR}" remote set-url origin "${remote_url}"
    else
        git -C "${STORE_DIR}" remote add origin "${remote_url}"
    fi
}

list_git_conflict_paths() {
    local local_branch merge_base local_paths_file remote_paths_file
    local_branch="$(git_current_branch_or_default)"
    merge_base="$(git -C "${STORE_DIR}" merge-base "HEAD" "origin/${BRANCH}" 2>/dev/null || true)"
    [ -n "${merge_base}" ] || return 0

    local_paths_file="$(mktemp)"
    remote_paths_file="$(mktemp)"

    {
        git -C "${STORE_DIR}" diff --name-only "${merge_base}..HEAD" 2>/dev/null || true
        git -C "${STORE_DIR}" diff --name-only 2>/dev/null || true
        git -C "${STORE_DIR}" diff --cached --name-only 2>/dev/null || true
    } | sed '/^$/d' | LC_ALL=C sort -u > "${local_paths_file}"

    git -C "${STORE_DIR}" diff --name-only "${merge_base}..origin/${BRANCH}" 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u > "${remote_paths_file}"

    comm -12 "${local_paths_file}" "${remote_paths_file}" || true

    rm -f "${local_paths_file}" "${remote_paths_file}"
}

show_store_conflict_preview() {
    local conflict_paths="$1"
    local count
    count="$(printf '%s\n' "${conflict_paths}" | sed '/^$/d' | wc -l | tr -d ' ')"
    [ "${count}" -gt 0 ] || return 0

    printf '%sPassword-store merge conflicts detected:%s\n' "${COLOR_RED}" "${COLOR_RESET}"
    printf '%s\n' "${conflict_paths}" | sed '/^$/d' | head -n 20 | while IFS= read -r item; do
        printf '  %s- %s%s\n' "${COLOR_RED}" "${item}" "${COLOR_RESET}"
    done
    if [ "${count}" -gt 20 ]; then
        printf '  %s... and %s more conflict paths%s\n' "${COLOR_RED}" "$((count - 20))" "${COLOR_RESET}"
    fi
    log
    log "What you are looking at:"
    log "  - these files changed both locally and in the remote password store"
    log "  - keeping local preserves your local versions"
    log "  - integrating remote replaces your local store with the remote state"
}

prompt_store_conflict_mode() {
    local choice
    while true; do
        read -r -p "Password-store conflict mode ([k]eep local / [i]ntegrate remote) [k]: " choice
        choice="${choice:-k}"
        case "${choice}" in
            k|K) printf 'keep-local'; return 0 ;;
            i|I) printf 'integrate-remote'; return 0 ;;
        esac
    done
}

fast_forward_store_repo_if_possible() {
    local local_branch
    local_branch="$(git_current_branch_or_default)"
    git -C "${STORE_DIR}" checkout "${local_branch}" >/dev/null 2>&1 || true

    if git -C "${STORE_DIR}" merge-base --is-ancestor HEAD "origin/${BRANCH}" >/dev/null 2>&1; then
        info "No local password-store conflicts detected. Fast-forwarding to origin/${BRANCH}..."
        git -C "${STORE_DIR}" merge --ff-only "origin/${BRANCH}" >/dev/null 2>&1 || true
        success "Password store updated from remote."
        return 0
    fi

    return 1
}

backup_current_gnupg_if_requested() {
    local local_gnupg="${HOME}/.gnupg"
    local answer backup_dir
    [ -d "${local_gnupg}" ] || return 0

    answer="$(prompt_value "Back up the current ~/.gnupg into ${GNUPG_BACKUPS_DIR}? [Y/n]" "Y")"
    if ! answer_is_yes "${answer}"; then
        return 0
    fi

    ensure_runtime_dir_ownership
    backup_dir="${GNUPG_BACKUPS_DIR}/gnupg.$(date +%Y%m%dT%H%M%S)"
    log "Backing up current ~/.gnupg to ${backup_dir}"
    cp -a "${local_gnupg}" "${backup_dir}"
    prune_old_gnupg_backups
}

installation_exists_binary() {
    local configured_binary
    configured_binary="$(runtime_config_string_field "binary" || true)"
    if [ -n "${configured_binary}" ] && [ -x "${configured_binary}" ]; then
        return 0
    fi
    [ -x /usr/local/bin/syncpss ] || [ -x /bin/syncpss ] || command_exists syncpss
}

installation_exists_alias() {
    local configured_binary alias_dir configured_alias
    configured_binary="$(runtime_config_string_field "binary" || true)"
    if [ -n "${configured_binary}" ]; then
        alias_dir="$(dirname "${configured_binary}")"
        configured_alias="${alias_dir}/syncpass"
        if [ -e "${configured_alias}" ] || [ -L "${configured_alias}" ]; then
            return 0
        fi
    fi
    [ -e /usr/local/bin/syncpass ] || [ -L /usr/local/bin/syncpass ] || \
    [ -e /bin/syncpass ] || [ -L /bin/syncpass ] || \
    command_exists syncpass
}

installation_exists_runtime() {
    [ -d "${RUNTIME_DIR}" ] && [ -f "${RUNTIME_DIR}/config.json" ]
}

installation_exists_system_config() {
    local configured_dir
    configured_dir="$(runtime_config_string_field "config_dir" || true)"
    if [ -n "${configured_dir}" ] && [ -f "${configured_dir}/config" ]; then
        return 0
    fi
    [ -f /etc/syncpass/config ]
}

runtime_config_string_field() {
    local field_name="$1"
    local config_path="${RUNTIME_DIR}/config.json"
    [ -f "${config_path}" ] || return 1
    sed -n "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "${config_path}" | head -n 1
}

installation_alias_matches_binary() {
    local configured_binary configured_alias resolved_alias
    configured_binary="$(runtime_config_string_field "binary" || true)"
    if [ -n "${configured_binary}" ]; then
        configured_alias="$(dirname "${configured_binary}")/syncpass"
        if [ -L "${configured_alias}" ]; then
            resolved_alias="$(readlink "${configured_alias}" || true)"
            [ "${resolved_alias}" = "${configured_binary}" ] && return 0
        fi
    fi

    if [ -L /usr/local/bin/syncpass ]; then
        resolved_alias="$(readlink /usr/local/bin/syncpass || true)"
        [ "${resolved_alias}" = "/usr/local/bin/syncpss" ] && return 0
    fi
    if [ -L /bin/syncpass ]; then
        resolved_alias="$(readlink /bin/syncpass || true)"
        [ "${resolved_alias}" = "/bin/syncpss" ] && return 0
    fi
    return 1
}

installation_health_report() {
    local issues=()

    if ! installation_exists_binary; then
        issues+=("Missing /usr/local/bin/syncpss")
    fi
    if ! installation_exists_alias; then
        issues+=("Missing /usr/local/bin/syncpass")
    fi
    if ! installation_exists_runtime; then
        issues+=("Missing ~/.syncpss/config.json")
    fi
    if ! installation_exists_system_config; then
        issues+=("Missing /etc/syncpass/config")
    fi

    if installation_exists_alias && ! installation_alias_matches_binary; then
        issues+=("syncpass alias does not point to the installed syncpss binary")
    fi

    if installation_exists_runtime; then
        local configured_binary configured_config_dir
        configured_binary="$(runtime_config_string_field "binary" || true)"
        configured_config_dir="$(runtime_config_string_field "config_dir" || true)"
        if [ -n "${configured_binary}" ] && [ ! -x "${configured_binary}" ]; then
            issues+=("Runtime config points to a missing binary: ${configured_binary}")
        fi
        if [ -n "${configured_config_dir}" ] && [ ! -f "${configured_config_dir}/config" ]; then
            issues+=("Runtime config points to a missing system config: ${configured_config_dir}/config")
        fi
    fi

    if [ "${#issues[@]}" -eq 0 ]; then
        printf 'healthy'
        return 0
    fi

    if ! installation_exists_binary && \
       ! installation_exists_alias && \
       ! installation_exists_runtime && \
       ! installation_exists_system_config; then
        printf 'missing'
        return 0
    fi

    printf 'broken\n'
    printf '%s\n' "${issues[@]}"
}

run_uninstall_from_installer() {
    local uninstall_script="${SCRIPT_DIR}/uninstall_syncpss.sh"
    [ -f "${uninstall_script}" ] || fail "Uninstall helper was not found at ${uninstall_script}"

    chmod u+x "${uninstall_script}" 2>/dev/null || true
    log
    log "Launching uninstall helper..."
    bash "${uninstall_script}"
}

select_install_action() {
    local status="$1"
    shift || true
    local issues=("$@")
    local choice

    case "${status}" in
        healthy)
            printf '%s\n' "Detected a healthy syncpss installation." >&2
            while true; do
                read -r -p "Choose [r]einstall/update, [u]ninstall, or [c]ancel [r]: " choice
                choice="${choice:-r}"
                case "${choice}" in
                    r|R) printf 'reinstall'; return 0 ;;
                    u|U) printf 'uninstall'; return 0 ;;
                    c|C) printf 'cancel'; return 0 ;;
                esac
            done
            ;;
        broken)
            printf '%s\n' "Detected an incomplete or unhealthy syncpss installation." >&2
            for issue in "${issues[@]}"; do
                [ -n "${issue}" ] || continue
                printf '  - %s\n' "${issue}" >&2
            done
            while true; do
                read -r -p "Choose [r]epair, [u]ninstall, or [c]ancel [r]: " choice
                choice="${choice:-r}"
                case "${choice}" in
                    r|R) printf 'repair'; return 0 ;;
                    u|U) printf 'uninstall'; return 0 ;;
                    c|C) printf 'cancel'; return 0 ;;
                esac
            done
            ;;
        missing)
            printf '%s\n' "Detected no existing syncpss installation." >&2
            while true; do
                read -r -p "Choose [i]nstall or [c]ancel [i]: " choice
                choice="${choice:-i}"
                case "${choice}" in
                    i|I) printf 'install'; return 0 ;;
                    c|C) printf 'cancel'; return 0 ;;
                esac
            done
            ;;
        *)
            warn "Installer could not classify the current install health cleanly. Falling back to repair."
            printf 'repair'
            ;;
    esac
}

handle_existing_install_state() {
    local report status action
    local issues=()

    if [ "${SYNCPSS_FORCE_INSTALL:-0}" = "1" ]; then
        log "Proceeding with forced install."
        return 0
    fi

    report="$(installation_health_report)"
    status="$(printf '%s\n' "${report}" | sed -n '1p')"
    if [ "${status}" = "broken" ]; then
        while IFS= read -r issue; do
            [ -n "${issue}" ] || continue
            issues+=("${issue}")
        done <<EOF
$(printf '%s\n' "${report}" | tail -n +2)
EOF
    fi

    action="$(select_install_action "${status}" "${issues[@]}")"
    case "${action}" in
        install|repair|reinstall)
            log
            log "Action selected: ${action^}"
            ;;
        uninstall)
            run_uninstall_from_installer
            exit 0
            ;;
        cancel)
            log "Installer cancelled."
            exit 0
            ;;
        *)
            warn "Unexpected installer action '${action}'. Proceeding with repair."
            ;;
    esac
}

ensure_store_clone_or_init() {
    local github_repo="$1"
    local clone_answer conflict_paths conflict_mode
    STORE_BOOTSTRAP_MODE="existing-local"
    STORE_REMOTE_KEYS_PRESENT=0

    if repo_exists "${github_repo}"; then
        section "Private password-store sync"
        info "Found your private password-store repo: git@github.com:${github_repo}.git"

        if [ ! -e "${STORE_DIR}" ]; then
            info "Local password store status: missing"
            if auto_accept_default_enabled; then
                info "Auto-accepting clone of the existing private password store into ${STORE_DIR}."
                clone_answer="Y"
            else
                clone_answer="$(prompt_value "Clone your existing private password store into ${STORE_DIR} now? [Y/n]" "Y")"
            fi
            if ! answer_is_yes "${clone_answer}"; then
                fail "A remote password store exists, and no local ${STORE_DIR} is present. Clone is required to continue."
            fi
            clone_remote_store_directly "${github_repo}"
            STORE_BOOTSTRAP_MODE="cloned-remote"
            if [ -f "${STORE_DIR}/keys" ]; then
                STORE_REMOTE_KEYS_PRESENT=1
            fi
            return
        fi

        if [ ! -d "${STORE_DIR}/.git" ]; then
            info "Local password store status: incomplete (no .git directory)"
            info "Backing up the incomplete local store and reconnecting it to your private GitHub repo."
            backup_existing_store_dir
            clone_remote_store_directly "${github_repo}"
            STORE_BOOTSTRAP_MODE="cloned-remote"
            if [ -f "${STORE_DIR}/keys" ]; then
                STORE_REMOTE_KEYS_PRESENT=1
            fi
            return
        fi

        info "Local password store status: existing git repository"
        if auto_accept_default_enabled; then
            info "Auto-accepting fetch and reconcile for the existing private password store."
            clone_answer="Y"
        else
            clone_answer="$(prompt_value "Fetch and reconcile your private password store now? [Y/n]" "Y")"
        fi
        if ! answer_is_yes "${clone_answer}"; then
            log "Keeping the current local git-backed password store and skipping remote reconciliation."
            STORE_BOOTSTRAP_MODE="kept-local"
            return
        fi

        ensure_store_repo_remote "${github_repo}"
        info "Fetching origin/${BRANCH} for password-store comparison..."
        git -C "${STORE_DIR}" fetch --quiet origin "${BRANCH}"
        if [ -f "${STORE_DIR}/keys" ]; then
            STORE_REMOTE_KEYS_PRESENT=1
        fi

        conflict_paths="$(list_git_conflict_paths)"
        if [ -n "${conflict_paths}" ]; then
            show_store_conflict_preview "${conflict_paths}"
            conflict_mode="$(prompt_store_conflict_mode)"
            case "${conflict_mode}" in
                keep-local)
                    info "Keeping local password-store content. Remote changes will not be applied right now."
                    STORE_BOOTSTRAP_MODE="kept-local"
                    return
                    ;;
                integrate-remote)
                    info "Integrating from remote by backing up the current local store and replacing it with the remote state."
                    backup_existing_store_dir
                    clone_remote_store_directly "${github_repo}"
                    STORE_BOOTSTRAP_MODE="cloned-remote"
                    if [ -f "${STORE_DIR}/keys" ]; then
                        STORE_REMOTE_KEYS_PRESENT=1
                    else
                        STORE_REMOTE_KEYS_PRESENT=0
                    fi
                    success "Password store replaced with the remote version."
                    return
                    ;;
            esac
        fi

        fast_forward_store_repo_if_possible || info "Remote password-store fetch completed. No conflicting paths were found."
        STORE_BOOTSTRAP_MODE="existing-local"
        return
    fi

    if [ -d "${STORE_DIR}/.git" ]; then
        return
    fi

    mkdir -p "${STORE_DIR}"
    git -C "${STORE_DIR}" init -b "${BRANCH}"
    STORE_BOOTSTRAP_MODE="new-local"
    STORE_REMOTE_KEYS_PRESENT=0
}

ensure_pass_initialized() {
    local gpg_key_id="$1"
    if [ -f "${STORE_DIR}/.gpg-id" ]; then
        return
    fi

    pass init "${gpg_key_id}"
}

store_has_password_entries() {
    [ -d "${STORE_DIR}" ] || return 1
    find "${STORE_DIR}" \
        -path "${STORE_DIR}/.git" -prune -o \
        -type f -name '*.gpg' -print -quit 2>/dev/null | grep -q .
}

package_local_gnupg_keys_to_remote() {
    local remote_keys="${STORE_DIR}/keys"
    local password confirmation staging_volume mount_point size_mb

    command_exists veracrypt || fail "veracrypt is required to create the encrypted remote keys container"
    [ -d "${HOME}/.gnupg" ] || fail "No local ~/.gnupg directory exists to package into the remote keys container"

    section "Remote keys container bootstrap"
    info "The cloned password store has encrypted entries but no usable remote keys container."
    info "syncpss will package the current ~/.gnupg into ${remote_keys} so future installs can restore keys safely."

    password="$(prompt_secret 'New VeraCrypt container password')"
    confirmation="$(prompt_secret 'Confirm VeraCrypt container password')"
    [ "${confirmation}" = "${password}" ] || fail "Container passwords did not match"

    ensure_runtime_dir_ownership
    staging_volume="${TMP_DIR}/keys.vc"
    mount_point="$(mktemp -d)"
    size_mb="$(keys_container_size_mb_for "${HOME}/.gnupg")"
    rm -f "${staging_volume}"

    trap 'dismount_veracrypt_mount "'"${mount_point}"'" >/dev/null 2>&1 || true; rm -rf "'"${mount_point}"'" "'"${staging_volume}"'"' RETURN

    veracrypt_with_password "${password}" --create "${staging_volume}" \
        --size "${size_mb}M" \
        --volume-type normal \
        --encryption AES \
        --hash sha-512 \
        --filesystem FAT \
        --pim 0 \
        --keyfiles "" \
        --random-source /dev/urandom >/dev/null 2>&1 || fail "Failed to create a VeraCrypt keys container"

    mount_veracrypt_rw "${staging_volume}" "${mount_point}" "${password}" || fail "Failed to mount the new VeraCrypt keys container"
    collect_current_key_bundle "${mount_point}"
    mkdir -p "${mount_point}/.gnupg"
    copy_live_gnupg_runtime "${HOME}/.gnupg" "${mount_point}/.gnupg"
    write_keys_container_manifest "${mount_point}"
    dismount_veracrypt_mount "${mount_point}" || fail "Failed to dismount the new VeraCrypt keys container"
    cp -f "${staging_volume}" "${remote_keys}"
    chmod 600 "${remote_keys}" 2>/dev/null || true
    STORE_REMOTE_KEYS_PRESENT=1

    rm -rf "${mount_point}" "${staging_volume}"
    trap - RETURN
    success "Encrypted remote keys container refreshed at ${remote_keys}"
}

write_store_readme() {
    local github_user="$1"
    local github_repo="$2"
    cat > "${STORE_DIR}/README.md" <<EOF
# pass-store

Encrypted password store managed by [syncpss](https://github.com/${REPO_OWNER}/${REPO_NAME}).

| Field | Value |
|---|---|
| Owner | ${github_user} |
| Repo | ${github_repo} |
| Distro | ${WSL_DISTRO_NAME:-$(uname -s)} |
| Created | $(date -u +"%Y-%m-%dT%H:%M:%SZ") |
| Host | $(hostname) |
EOF
}

write_store_manifest() {
    cat > "${STORE_DIR}/manifest.xml" <<'EOF'
<syncpss>
  <type>backup</type>
  <exports>
    <file>
      <path>manifest.xml</path>
      <description>Store-level manifest that describes this password-store backup layout.</description>
    </file>
    <file>
      <path>.git/</path>
      <description>Git repository metadata for the password store, including commit history and refs.</description>
    </file>
    <file>
      <path>.gpg-id</path>
      <description>The pass recipient key id used to encrypt entries in this store.</description>
    </file>
    <file>
      <path>keys</path>
      <description>Encrypted VeraCrypt container that carries only the .gnupg keyring backup.</description>
    </file>
    <file>
      <path>backup</path>
      <description>Encrypted VeraCrypt backup container with store export data and a full snapshot.</description>
    </file>
    <file>
      <path>*.gpg</path>
      <description>Encrypted password entries managed by the pass CLI inside this store.</description>
    </file>
  </exports>
</syncpss>
EOF
}

next_store_version() {
    local latest patch
    latest="$(git -C "${STORE_DIR}" tag --list 'v0.0.*' | sed 's/^v//' | sort | tail -n1 || true)"
    if [ -z "${latest}" ]; then
        printf '0.0.0001'
        return
    fi

    patch="${latest##*.}"
    patch=$((10#${patch} + 1))
    printf '0.0.%04d' "${patch}"
}

write_store_hash() {
    local version="$1"
    local manifest hash
    manifest="$(mktemp)"

    (
        cd "${STORE_DIR}"
        find . \
            -path './.git' -prune -o \
            -type f ! -name "${STORE_HASH_FILE}" -print0 |
            sort -z |
            while IFS= read -r -d '' file; do
                sha256sum "${file}"
            done
    ) > "${manifest}"

    hash="$(sha256sum "${manifest}" | awk '{print $1}')"
    rm -f "${manifest}"
    printf '%s  v%s\n' "${hash}" "${version}" > "${STORE_DIR}/${STORE_HASH_FILE}"
}

ensure_store_remote() {
    local github_repo="$1"
    if git -C "${STORE_DIR}" remote get-url origin >/dev/null 2>&1; then
        return
    fi

    if repo_exists "${github_repo}"; then
        git -C "${STORE_DIR}" remote add origin "git@github.com:${github_repo}.git"
        info "Using existing private GitHub repo: ${github_repo}"
        return
    fi

    info "Creating your private GitHub repo: ${github_repo}"
    gh repo create "${github_repo}" --private --source "${STORE_DIR}" --remote origin
    success "Private GitHub repo created: ${github_repo}"
}

fix_gnupg_permissions() {
    local gnupg_dir="${HOME}/.gnupg"
    [ -d "${gnupg_dir}" ] || return 0
    sudo_run chown -R "${REAL_USER}:${REAL_GROUP}" "${gnupg_dir}" 2>/dev/null || \
        sudo_run chown -R "${REAL_USER}" "${gnupg_dir}" 2>/dev/null || true
    chmod 700 "${gnupg_dir}" || true
    find "${gnupg_dir}" -type d -exec chmod 700 {} \; 2>/dev/null || true
    find "${gnupg_dir}" -type f -exec chmod 600 {} \; 2>/dev/null || true
}

should_skip_live_gnupg_entry() {
    local entry_name="$1"
    case "${entry_name}" in
        .git|README.md|.#lk*|S.gpg-agent*|S.scdaemon|*.lock)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

copy_live_gnupg_runtime() {
    local source_dir="$1"
    local destination_dir="$2"
    local entry base_name

    mkdir -p "${destination_dir}"
    shopt -s dotglob nullglob
    for entry in "${source_dir}"/* "${source_dir}"/.*; do
        [ -e "${entry}" ] || continue
        base_name="$(basename "${entry}")"
        if [ "${base_name}" = "." ] || [ "${base_name}" = ".." ]; then
            continue
        fi
        if should_skip_live_gnupg_entry "${base_name}"; then
            continue
        fi
        if [ -S "${entry}" ]; then
            continue
        fi
        cp -a "${entry}" "${destination_dir}/"
    done
    shopt -u dotglob nullglob
}

sanitize_live_gnupg_runtime() {
    local gnupg_dir="${HOME}/.gnupg"
    [ -d "${gnupg_dir}" ] || return 0

    rm -rf "${gnupg_dir}/.git" "${gnupg_dir}/README.md" 2>/dev/null || true
    find "${gnupg_dir}" -maxdepth 1 \( -name '.#lk*' -o -name 'S.gpg-agent*' -o -name 'S.scdaemon' -o -name '*.lock' \) \
        -exec rm -rf {} + 2>/dev/null || true
}

directory_tree_hash() {
    local target_dir="$1"
    [ -d "${target_dir}" ] || return 1

    (
        cd "${target_dir}"
        find . -type f -print0 |
            sort -z |
            while IFS= read -r -d '' file; do
                printf '%s\0' "${file}"
                sha256sum "${file}"
            done
    ) | sha256sum | awk '{print $1}'
}

gnupg_matches_raw_backup() {
    local raw_dir="$1"
    local local_gnupg="${HOME}/.gnupg"
    [ -d "${raw_dir}" ] || return 1
    [ -d "${local_gnupg}" ] || return 1

    local raw_hash local_hash
    raw_hash="$(directory_tree_hash "${raw_dir}" || true)"
    local_hash="$(directory_tree_hash "${local_gnupg}" || true)"
    [ -n "${raw_hash}" ] && [ "${raw_hash}" = "${local_hash}" ]
}

key_container_matches_local_exports() {
    local mount_point="$1"
    local bundle_dir
    bundle_dir="$(mktemp -d)"
    trap 'rm -rf "'"${bundle_dir}"'"' RETURN

    collect_current_key_bundle "${bundle_dir}"

    local matched=0
    same_file_content "${bundle_dir}/pubkeys.asc" "${mount_point}/pubkeys.asc" && matched=$((matched + 1))
    same_file_content "${bundle_dir}/seckeys.asc" "${mount_point}/seckeys.asc" && matched=$((matched + 1))
    same_file_content "${bundle_dir}/ownertrust.txt" "${mount_point}/ownertrust.txt" && matched=$((matched + 1))

    rm -rf "${bundle_dir}"
    trap - RETURN
    [ "${matched}" -eq 3 ]
}

store_gpg_id() {
    if [ -f "${STORE_DIR}/.gpg-id" ]; then
        head -n 1 "${STORE_DIR}/.gpg-id" | tr -d '\r'
        return 0
    fi
    return 1
}

local_has_secret_key() {
    local key_id="${1:-}"
    [ -n "${key_id}" ] || return 1
    gpg --list-secret-keys --with-colons "${key_id}" 2>/dev/null | grep -q '^sec:'
}

local_has_public_key() {
    local key_id="${1:-}"
    [ -n "${key_id}" ] || return 1
    gpg --list-keys --with-colons "${key_id}" 2>/dev/null | grep -Eq '^(pub|sub):'
}

refresh_gpg_after_restore() {
    local mount_point="$1"
    gpgconf --kill all >/dev/null 2>&1 || true
    if [ -f "${mount_point}/pubkeys.asc" ]; then
        gpg --import "${mount_point}/pubkeys.asc" >/dev/null 2>&1 || true
    fi
    if [ -f "${mount_point}/seckeys.asc" ]; then
        gpg --import "${mount_point}/seckeys.asc" >/dev/null 2>&1 || true
    fi
    if [ -f "${mount_point}/ownertrust.txt" ]; then
        gpg --import-ownertrust < "${mount_point}/ownertrust.txt" >/dev/null 2>&1 || true
    fi
    gpgconf --launch gpg-agent >/dev/null 2>&1 || true
    gpg --check-trustdb >/dev/null 2>&1 || true
}

show_merge_preview() {
    local mount_point="$1"
    local container_fingerprints local_fingerprints fingerprint raw_dir
    local bundle_dir
    local new_keys=()
    local existing_keys=()
    raw_dir="$(find_gnupg_source_dir "${mount_point}" || true)"

    container_fingerprints="$(
        {
            extract_key_fingerprints_from_file "${mount_point}/pubkeys.asc"
            extract_key_fingerprints_from_file "${mount_point}/seckeys.asc"
        } | sed '/^$/d' | sort -u
    )"
    local_fingerprints="$(
        {
            list_public_key_fingerprints
            list_secret_key_fingerprints
        } | sed '/^$/d' | sort -u
    )"

    log
    log "Merge preview:"

    if [ -n "${container_fingerprints}" ]; then
        while IFS= read -r fingerprint; do
            [ -n "${fingerprint}" ] || continue
            if printf '%s\n' "${local_fingerprints}" | grep -Fxq "${fingerprint}"; then
                existing_keys+=("${fingerprint}")
            else
                new_keys+=("${fingerprint}")
            fi
        done <<EOF
${container_fingerprints}
EOF
    fi

    if [ "${#new_keys[@]}" -gt 0 ]; then
        log "  These key fingerprints will be merged in:"
        for fingerprint in "${new_keys[@]}"; do
            log "    + ${fingerprint}"
        done
    else
        log "  No new key fingerprints need to be imported."
    fi

    if [ "${#existing_keys[@]}" -gt 0 ]; then
        log "  These key fingerprints already exist locally and stay the same:"
        for fingerprint in "${existing_keys[@]}"; do
            log "    = ${fingerprint}"
        done
    fi

    if [ -f "${mount_point}/ownertrust.txt" ]; then
        bundle_dir="$(mktemp -d)"
        trap 'rm -rf "'"${bundle_dir}"'"' RETURN
        collect_current_key_bundle "${bundle_dir}"
        if same_file_content "${bundle_dir}/ownertrust.txt" "${mount_point}/ownertrust.txt"; then
            log "  ownertrust.txt already matches and stays the same."
        else
            log "  ownertrust.txt will be imported and may update trust assignments."
        fi
        rm -rf "${bundle_dir}"
        trap - RETURN
    fi

    if [ -n "${raw_dir}" ] && [ -f "${raw_dir}/gpg.conf" ]; then
        if [ -f "${HOME}/.gnupg/gpg.conf" ]; then
            log "  Existing ~/.gnupg/gpg.conf stays the same."
        else
            log "  $(basename "${raw_dir}")/gpg.conf will be copied into ~/.gnupg."
        fi
    fi

    if [ -n "${raw_dir}" ] && [ -f "${raw_dir}/gpg-agent.conf" ]; then
        if [ -f "${HOME}/.gnupg/gpg-agent.conf" ]; then
            log "  Existing ~/.gnupg/gpg-agent.conf stays the same."
        else
            log "  $(basename "${raw_dir}")/gpg-agent.conf will be copied into ~/.gnupg."
        fi
    fi

    if [ -n "${raw_dir}" ] && [ -d "${raw_dir}/openpgp-revocs.d" ]; then
        log "  Revocation certificates will be copied only if missing locally."
    fi
    log
}

guess_gpg_key_id() {
    if [ -f "${STORE_DIR}/.gpg-id" ]; then
        head -n 1 "${STORE_DIR}/.gpg-id" | tr -d '\r'
        return 0
    fi

    list_secret_key_fingerprints | sed -n '1p'
}

restore_gpg_from_remote_keys() {
    local remote_keys="${STORE_DIR}/keys"
    [ -f "${remote_keys}" ] || fail "Remote keys container was not found at ${remote_keys}"
    command_exists veracrypt || fail "veracrypt is required to restore encrypted GPG keys"

    local mode password mount_point requested_mount raw_dir mount_result mount_mode mounted_here cleanup_mount_dir expected_gpg_id local_gnupg_summary
    section "Encrypted remote GPG keys"
    info "Found a VeraCrypt keys container at ${remote_keys}."
    local_gnupg_summary="$(describe_local_gnupg_state)"
    info "${local_gnupg_summary}"
    info "Choose how syncpss should apply those remote GPG keys to this Linux profile."
    read -r -p "GPG key restore mode ([m]erge / [r]eplace / [l]eave as is) [r]: " mode
    mode="${mode:-r}"
    if [ "${mode}" = "l" ] || [ "${mode}" = "L" ]; then
        log "Leaving the current ~/.gnupg unchanged."
        return
    fi

    backup_current_gnupg_if_requested

    password="$(prompt_secret 'VeraCrypt container password')"
    [ -n "${password}" ] || fail "A VeraCrypt password is required to restore GPG keys"

    requested_mount="$(mktemp -d)"
    mount_result="$(mount_or_reuse_veracrypt_volume "${remote_keys}" "${requested_mount}" "${password}")"
    mount_mode="${mount_result%%	*}"
    mount_point="${mount_result#*	}"
    mounted_here=1
    cleanup_mount_dir=""
    if [ "${mount_mode}" = "mounted" ]; then
        cleanup_mount_dir="${requested_mount}"
    else
        cleanup_mount_dir_if_safe "${requested_mount}" || true
    fi
    trap 'cleanup_restore_mount "${mounted_here:-0}" "${mount_point:-}" "${cleanup_mount_dir:-}"' RETURN

    expected_gpg_id="$(store_gpg_id || true)"
    raw_dir="$(find_gnupg_source_dir "${mount_point}" || true)"
    if (gnupg_matches_raw_backup "${raw_dir}" || key_container_matches_local_exports "${mount_point}") && \
       { [ -z "${expected_gpg_id}" ] || local_has_secret_key "${expected_gpg_id}"; }; then
        log "The encrypted keys container already matches your current ~/.gnupg. Skipping restore."
        dismount_veracrypt_mount "${mount_point}" || true
        mounted_here=0
        if [ -n "${cleanup_mount_dir}" ]; then
            cleanup_mount_dir_if_safe "${cleanup_mount_dir}" || true
            cleanup_mount_dir=""
        fi
        trap - RETURN
        return
    fi

    if [ "${mode}" = "r" ] || [ "${mode}" = "R" ]; then
        local raw_dir local_gnupg backup_dir
        raw_dir="$(find_gnupg_source_dir "${mount_point}" || true)"
        [ -d "${raw_dir}" ] || fail "The encrypted keys container does not include a supported .gnupg backup layout for replace mode"
        local_gnupg="${HOME}/.gnupg"
        ensure_runtime_dir_ownership
        backup_dir="${GNUPG_BACKUPS_DIR}/gnupg-replace.$(date +%Y%m%dT%H%M%S)"
        gpgconf --kill gpg-agent >/dev/null 2>&1 || true
        if [ -d "${local_gnupg}" ]; then
            mv "${local_gnupg}" "${backup_dir}"
            prune_old_gnupg_backups
        fi
        mkdir -p "${local_gnupg}"
        copy_live_gnupg_runtime "${raw_dir}" "${local_gnupg}"
        sanitize_live_gnupg_runtime
        fix_gnupg_permissions
        refresh_gpg_after_restore "${mount_point}"
        log "Replaced ~/.gnupg from the encrypted remote keys container."
    else
        raw_dir="$(find_gnupg_source_dir "${mount_point}" || true)"
        show_merge_preview "${mount_point}"
        mkdir -p "${HOME}/.gnupg"
        chmod 700 "${HOME}/.gnupg" || true
        if [ -f "${mount_point}/pubkeys.asc" ]; then
            gpg --import "${mount_point}/pubkeys.asc"
        fi
        if [ -f "${mount_point}/seckeys.asc" ]; then
            gpg --import "${mount_point}/seckeys.asc"
        fi
        if [ -f "${mount_point}/ownertrust.txt" ]; then
            gpg --import-ownertrust < "${mount_point}/ownertrust.txt"
        fi
        if [ -n "${raw_dir}" ] && [ -d "${raw_dir}/openpgp-revocs.d" ]; then
            mkdir -p "${HOME}/.gnupg/openpgp-revocs.d"
            cp -an "${raw_dir}/openpgp-revocs.d/." "${HOME}/.gnupg/openpgp-revocs.d/" 2>/dev/null || true
        fi
        if [ -n "${raw_dir}" ] && [ -f "${raw_dir}/gpg.conf" ] && [ ! -f "${HOME}/.gnupg/gpg.conf" ]; then
            cp -a "${raw_dir}/gpg.conf" "${HOME}/.gnupg/gpg.conf"
        fi
        if [ -n "${raw_dir}" ] && [ -f "${raw_dir}/gpg-agent.conf" ] && [ ! -f "${HOME}/.gnupg/gpg-agent.conf" ]; then
            cp -a "${raw_dir}/gpg-agent.conf" "${HOME}/.gnupg/gpg-agent.conf"
        fi
        sanitize_live_gnupg_runtime
        gpg --check-trustdb || true
        fix_gnupg_permissions
        refresh_gpg_after_restore "${mount_point}"
        log "Merged encrypted remote GPG keys into the current ~/.gnupg."
    fi

    if [ -n "${expected_gpg_id}" ] && ! local_has_secret_key "${expected_gpg_id}"; then
        fail "Restore completed, but the secret key required by ${STORE_DIR}/.gpg-id is still missing locally: ${expected_gpg_id}"
    fi

    dismount_veracrypt_mount "${mount_point}" || true
    mounted_here=0
    if [ -n "${cleanup_mount_dir}" ]; then
        cleanup_mount_dir_if_safe "${cleanup_mount_dir}" || true
        cleanup_mount_dir=""
    fi
    trap - RETURN
}

ensure_store_first_push() {
    local github_user="$1"
    local github_repo="$2"
    local version

    if [ "${STORE_BOOTSTRAP_MODE}" = "kept-local" ]; then
        log "Remote pass-store already exists; skipping initial push bootstrap."
        return
    fi
    if [ "${STORE_BOOTSTRAP_MODE}" = "cloned-remote" ] && [ "${STORE_REMOTE_KEYS_PRESENT}" = "1" ]; then
        log "Remote pass-store already exists with an encrypted keys container; skipping initial push bootstrap."
        return
    fi

    if [ "${STORE_BOOTSTRAP_MODE}" = "cloned-remote" ] && [ "${STORE_REMOTE_KEYS_PRESENT}" = "0" ]; then
        if store_has_password_entries; then
            info "Remote pass-store exists and contains encrypted entries, but no usable keys container was found."
            package_local_gnupg_keys_to_remote
        else
            info "Remote pass-store exists, but no encrypted keys container was found. Bootstrapping the new GPG identity back to the repo."
        fi
    fi

    if [ "${STORE_BOOTSTRAP_MODE}" = "new-local" ]; then
        info "Preparing the first encrypted bootstrap for your new private password-store repo."
    fi

    write_store_readme "${github_user}" "${github_repo}"
    write_store_manifest
    version="$(next_store_version)"
    write_store_hash "${version}"

    git -C "${STORE_DIR}" add README.md manifest.xml .gpg-id "${STORE_HASH_FILE}"
    if [ -f "${STORE_DIR}/keys" ]; then
        git -C "${STORE_DIR}" add keys
    fi
    if [ -n "$(git -C "${STORE_DIR}" status --short)" ]; then
        git -C "${STORE_DIR}" commit -m "Initialize pass-store"
    fi

    ensure_store_remote "${github_repo}"
    git -C "${STORE_DIR}" push -u origin "${BRANCH}"
    git -C "${STORE_DIR}" tag -a "v${version}" -m "pass-store v${version}"
    git -C "${STORE_DIR}" push origin "v${version}"
    success "Private password-store bootstrap complete."
}

sha_check() {
    local binary_name="$1"
    local checksum_file="$2"

    if command_exists sha256sum; then
        awk '{print $1 "  '"${binary_name}"'"}' "${checksum_file}" > "${checksum_file}.check"
        sha256sum -c "${checksum_file}.check" >/dev/null
        rm -f "${checksum_file}.check"
        return
    fi

    if command_exists shasum; then
        local expected actual
        expected="$(awk '{print $1}' "${checksum_file}")"
        actual="$(shasum -a 256 "${binary_name}" | awk '{print $1}')"
        [ "${expected}" = "${actual}" ]
        return
    fi

    fail "No SHA-256 checker found."
}

json_field_value() {
    local json_content="$1"
    local field_name="$2"
    printf '%s' "${json_content}" | tr '\n' ' ' | sed -n "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

selected_release_api_endpoint() {
    if [ -n "${SYNCPSS_RELEASE_TAG:-}" ]; then
        printf '%s' "${GITHUB_API_BASE}/releases/tags/${SYNCPSS_RELEASE_TAG}"
        return
    fi
    printf '%s' "${GITHUB_API_BASE}/releases/latest"
}

selected_release_json() {
    local attempts=5
    local attempt=1
    local endpoint json_response

    endpoint="$(selected_release_api_endpoint)"

    while [ "${attempt}" -le "${attempts}" ]; do
        json_response="$(curl -fsSL --retry 3 --retry-delay 1 \
            -H 'Accept: application/vnd.github+json' \
            "${endpoint}" 2>/dev/null || true)"
        if [ -n "${json_response}" ] && [ -n "$(json_field_value "${json_response}" "tag_name")" ]; then
            printf '%s' "${json_response}"
            return 0
        fi

        if [ "${attempt}" -lt "${attempts}" ]; then
            sleep 2
        fi
        attempt=$((attempt + 1))
    done

    return 0
}

latest_release_name() {
    local release_json name tag
    release_json="$(selected_release_json)"
    [ -n "${release_json}" ] || return 0
    name="$(json_field_value "${release_json}" "name")"
    if [ -n "${name}" ]; then
        printf '%s' "${name}"
        return 0
    fi
    tag="$(json_field_value "${release_json}" "tag_name")"
    [ -n "${tag}" ] && printf '%s' "${tag}"
}

latest_release_tag() {
    local release_json
    release_json="$(selected_release_json)"
    [ -n "${release_json}" ] || return 0
    json_field_value "${release_json}" "tag_name"
}

normalize_release_name_to_tag() {
    local release_name="$1"
    release_name="${release_name#Release }"
    printf '%s' "${release_name}"
}

release_asset_url() {
    local release_tag="$1"
    local asset_name="$2"
    printf 'https://github.com/%s/%s/releases/download/%s/%s' \
        "${REPO_OWNER}" \
        "${REPO_NAME}" \
        "${release_tag}" \
        "${asset_name}"
}

download_release_asset() {
    local release_tag="$1"
    local asset_name="$2"
    local destination="$3"
    curl -fsSL --retry 3 --retry-delay 1 \
        "$(release_asset_url "${release_tag}" "${asset_name}")" \
        -o "${destination}"
}

xml_field_value() {
    local xml_content="$1"
    local field_name="$2"
    printf '%s' "${xml_content}" | tr '\n' ' ' | sed -n "s:.*<${field_name}>\\([^<]*\\)</${field_name}>.*:\\1:p" | head -n1
}

release_manifest_matches_tag() {
    local selected_tag="$1"
    local manifest_xml="$2"
    local manifest_name manifest_tag manifest_version normalized_manifest_name

    [ -n "${manifest_xml}" ] || return 1

    manifest_name="$(xml_field_value "${manifest_xml}" "name")"
    manifest_tag="$(xml_field_value "${manifest_xml}" "tag")"
    manifest_version="$(xml_field_value "${manifest_xml}" "version")"
    normalized_manifest_name="$(normalize_release_name_to_tag "${manifest_name}")"

    [ -n "${selected_tag}" ] || return 1
    [ -n "${manifest_tag}" ] || [ -n "${manifest_version}" ] || [ -n "${manifest_name}" ] || return 1

    if [ -n "${manifest_tag}" ] && [ "${manifest_tag}" = "${selected_tag}" ]; then
        return 0
    fi
    if [ -n "${manifest_version}" ] && [ "v${manifest_version}" = "${selected_tag}" ]; then
        return 0
    fi
    if [ -n "${normalized_manifest_name}" ] && [ "${normalized_manifest_name}" = "${selected_tag}" ]; then
        return 0
    fi
    return 1
}

download_release_assets_from_github() {
    local release_tag="$1"
    local attempts=5
    local attempt=1

    while [ "${attempt}" -le "${attempts}" ]; do
        rm -f \
            "${TMP_DIR}/${INSTALL_ASSET}" \
            "${TMP_DIR}/${INSTALL_SHA_ASSET}" \
            "${TMP_DIR}/${SYNCPS_ASSET}" \
            "${TMP_DIR}/${SYNCPS_SHA_ASSET}" \
            "${TMP_DIR}/${MANIFEST_ASSET}" \
            "${TMP_DIR}/${MANIFEST_SHA_ASSET}" \
            "${TMP_DIR}/${UNINSTALL_ASSET}" \
            "${TMP_DIR}/${UNINSTALL_SHA_ASSET}" \
            "${TMP_DIR}/${MASTER_FINGERPRINT_ASSET}"

        if \
            download_release_asset "${release_tag}" "${INSTALL_ASSET}" "${TMP_DIR}/${INSTALL_ASSET}" && \
            download_release_asset "${release_tag}" "${INSTALL_SHA_ASSET}" "${TMP_DIR}/${INSTALL_SHA_ASSET}" && \
            download_release_asset "${release_tag}" "${SYNCPS_ASSET}" "${TMP_DIR}/${SYNCPS_ASSET}" && \
            download_release_asset "${release_tag}" "${SYNCPS_SHA_ASSET}" "${TMP_DIR}/${SYNCPS_SHA_ASSET}" && \
            download_release_asset "${release_tag}" "${MANIFEST_ASSET}" "${TMP_DIR}/${MANIFEST_ASSET}" && \
            download_release_asset "${release_tag}" "${MANIFEST_SHA_ASSET}" "${TMP_DIR}/${MANIFEST_SHA_ASSET}" && \
            download_release_asset "${release_tag}" "${UNINSTALL_ASSET}" "${TMP_DIR}/${UNINSTALL_ASSET}" && \
            download_release_asset "${release_tag}" "${UNINSTALL_SHA_ASSET}" "${TMP_DIR}/${UNINSTALL_SHA_ASSET}" && \
            download_release_asset "${release_tag}" "${MASTER_FINGERPRINT_ASSET}" "${TMP_DIR}/${MASTER_FINGERPRINT_ASSET}"; then
            return 0
        fi

        if [ "${attempt}" -lt "${attempts}" ]; then
            sleep 2
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

find_local_dev_repo() {
    local candidate
    for candidate in \
        "${SYNCPSS_DEV_REPO:-}" \
        "${HOME}/Documents/GitHub/syncpss" \
        "/mnt/c/Users/${REAL_USER}/Documents/GitHub/syncpss" \
        "${PWD}"
    do
        [ -n "${candidate}" ] || continue
        if [ -d "${candidate}" ] && [ -f "${candidate}/CMakeLists.txt" ] && [ -f "${candidate}/scripts/sh/build.sh" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

read_local_dev_repo_id() {
    local repo_root="${1:-}"
    maintainer_current_id "${repo_root}"
}

sha256_text() {
    local value="$1"
    printf '%s' "${value}" | sha256sum | awk '{print $1}'
}

compute_repo_master_fingerprint() {
    local repo_root="$1"
    local temp_payload
    temp_payload="$(mktemp)"

    cat \
        "${repo_root}/bin/${SYNCPS_ASSET}" \
        "${repo_root}/bin/${INSTALL_ASSET}" \
        "${repo_root}/bin/installer.sh" \
        "${repo_root}/bin/uninstall_syncpss.sh" > "${temp_payload}"

    sha256sum "${temp_payload}" | awk '{print $1}'
    rm -f "${temp_payload}"
}

verify_local_dev_repo() {
    local repo_root="$1"
    local repo_id expected_hash actual_hash expected_fingerprint actual_fingerprint
    local fingerprint_path="${repo_root}/${MASTER_FINGERPRINT_ASSET}"

    repo_id="$(read_local_dev_repo_id "${repo_root}" || true)"
    [ -n "${repo_id}" ] || return 1

    actual_hash="$(sha256_text "${repo_id}")"
    expected_hash="$(maintainer_expected_hash "${repo_root}")"
    [ -n "${expected_hash}" ] || return 1
    [ "${actual_hash}" = "${expected_hash}" ] || return 1

    [ -f "${fingerprint_path}" ] || return 1
    expected_fingerprint="$(awk '{print $1}' "${fingerprint_path}")"
    [ -n "${expected_fingerprint}" ] || return 1

    actual_fingerprint="$(compute_repo_master_fingerprint "${repo_root}")"
    [ "${expected_fingerprint}" = "${actual_fingerprint}" ]
}

stage_local_dev_install_assets() {
    local repo_root="$1"

    log "Building local development assets from ${repo_root}"
    (
        cd "${repo_root}"
        bash scripts/sh/build.sh
    ) || fail "Local development build failed."

    cp -f "${repo_root}/bin/install" "${TMP_DIR}/install"
    cp -f "${repo_root}/bin/install.sha256" "${TMP_DIR}/install.sha256"
    cp -f "${repo_root}/bin/${SYNCPS_ASSET}" "${TMP_DIR}/${SYNCPS_ASSET}"
    cp -f "${repo_root}/bin/${SYNCPS_SHA_ASSET}" "${TMP_DIR}/${SYNCPS_SHA_ASSET}"
    cp -f "${repo_root}/bin/${UNINSTALL_ASSET}" "${TMP_DIR}/${UNINSTALL_ASSET}"
    cp -f "${repo_root}/bin/${UNINSTALL_SHA_ASSET}" "${TMP_DIR}/${UNINSTALL_SHA_ASSET}"
    cp -f "${repo_root}/bin/${MASTER_FINGERPRINT_ASSET}" "${TMP_DIR}/${MASTER_FINGERPRINT_ASSET}"
    (
        cd "${TMP_DIR}"
        sha_check "install" "install.sha256"
        sha_check "${SYNCPS_ASSET}" "${SYNCPS_SHA_ASSET}"
        sha_check "${UNINSTALL_ASSET}" "${UNINSTALL_SHA_ASSET}"
    ) || fail "Checksum verification failed for locally built development assets"
    chmod 755 "${TMP_DIR}/install" "${TMP_DIR}/${SYNCPS_ASSET}" "${TMP_DIR}/${UNINSTALL_ASSET}"
}

local_install_assets_available() {
    [ -f "${SCRIPT_DIR}/${INSTALL_ASSET}" ] && \
    [ -f "${SCRIPT_DIR}/${INSTALL_SHA_ASSET}" ] && \
    [ -f "${SCRIPT_DIR}/${SYNCPS_ASSET}" ] && \
    [ -f "${SCRIPT_DIR}/${SYNCPS_SHA_ASSET}" ] && \
    [ -f "${SCRIPT_DIR}/${MANIFEST_ASSET}" ] && \
    [ -f "${SCRIPT_DIR}/${MANIFEST_SHA_ASSET}" ] && \
    [ -f "${SCRIPT_DIR}/${UNINSTALL_ASSET}" ] && \
    [ -f "${SCRIPT_DIR}/${UNINSTALL_SHA_ASSET}" ] && \
    [ -f "${SCRIPT_DIR}/${MASTER_FINGERPRINT_ASSET}" ]
}

select_install_asset_source() {
    local latest_tag="$1"
    local forced_source="${SYNCPSS_INSTALL_SOURCE:-}"

    case "${forced_source}" in
        local|LOCAL)
            if local_install_assets_available; then
                printf '%s\n' "Installer source forced to local staged assets." >&2
                printf 'local'
                return 0
            fi
            fail "SYNCPSS_INSTALL_SOURCE=local was requested, but no local install assets are staged."
            ;;
        github|GITHUB|release|RELEASE)
            if [ -n "${latest_tag}" ]; then
                printf '%s\n' "Installer source forced to GitHub release ${latest_tag}." >&2
                printf 'github'
                return 0
            fi
            fail "SYNCPSS_INSTALL_SOURCE=github was requested, but no published GitHub release was found."
            ;;
        ""|auto|AUTO)
            ;;
        *)
            fail "Unsupported SYNCPSS_INSTALL_SOURCE value: ${forced_source}"
            ;;
    esac

    if [ -n "${latest_tag}" ]; then
        printf '%s\n' "Found latest GitHub release: ${latest_tag}" >&2
        printf 'github'
        return 0
    fi

    fail "No published GitHub release was found. For maintainer-only local testing, rerun with SYNCPSS_INSTALL_SOURCE=local."
}

download_install_binary() {
    local latest_tag latest_name manifest_xml asset_source
    ensure_runtime_dir_ownership
    latest_tag="$(latest_release_tag)"
    latest_name="$(latest_release_name)"

    if [ -n "${latest_name}" ]; then
        log "Latest published release: ${latest_name}"
    fi

    asset_source="$(select_install_asset_source "${latest_tag}")"

    if [ "${asset_source}" = "local" ]; then
        log "Using locally staged Windows-built install assets."
        cp -f "${SCRIPT_DIR}/${INSTALL_ASSET}" "${TMP_DIR}/install"
        cp -f "${SCRIPT_DIR}/${INSTALL_SHA_ASSET}" "${TMP_DIR}/install.sha256"
        cp -f "${SCRIPT_DIR}/${SYNCPS_ASSET}" "${TMP_DIR}/${SYNCPS_ASSET}"
        cp -f "${SCRIPT_DIR}/${SYNCPS_SHA_ASSET}" "${TMP_DIR}/${SYNCPS_SHA_ASSET}"
        cp -f "${SCRIPT_DIR}/${MANIFEST_ASSET}" "${TMP_DIR}/${MANIFEST_ASSET}"
        cp -f "${SCRIPT_DIR}/${MANIFEST_SHA_ASSET}" "${TMP_DIR}/${MANIFEST_SHA_ASSET}"
        cp -f "${SCRIPT_DIR}/${UNINSTALL_ASSET}" "${TMP_DIR}/${UNINSTALL_ASSET}"
        cp -f "${SCRIPT_DIR}/${UNINSTALL_SHA_ASSET}" "${TMP_DIR}/${UNINSTALL_SHA_ASSET}"
        cp -f "${SCRIPT_DIR}/${MASTER_FINGERPRINT_ASSET}" "${TMP_DIR}/${MASTER_FINGERPRINT_ASSET}"
        (
            cd "${TMP_DIR}"
            sha_check "install" "install.sha256"
            sha_check "${SYNCPS_ASSET}" "${SYNCPS_SHA_ASSET}"
            sha_check "${MANIFEST_ASSET}" "${MANIFEST_SHA_ASSET}"
            sha_check "${UNINSTALL_ASSET}" "${UNINSTALL_SHA_ASSET}"
        ) || fail "Checksum verification failed for locally staged install assets"
        chmod 755 "${TMP_DIR}/install" "${TMP_DIR}/${SYNCPS_ASSET}" "${TMP_DIR}/${UNINSTALL_ASSET}"
        return
    fi

    if [ -n "${latest_tag}" ]; then
        log "Downloading install assets from GitHub release ${latest_tag}."
        run_with_spinner "Downloading release install assets" \
            download_release_assets_from_github "${latest_tag}" || \
            fail "Failed to download install assets from the selected GitHub release."

        (
            cd "${TMP_DIR}"
            sha_check "install" "install.sha256"
            sha_check "${SYNCPS_ASSET}" "${SYNCPS_SHA_ASSET}"
            sha_check "${MANIFEST_ASSET}" "${MANIFEST_SHA_ASSET}"
            sha_check "${UNINSTALL_ASSET}" "${UNINSTALL_SHA_ASSET}"
        ) || fail "Checksum verification failed for downloaded install assets"
        manifest_xml="$(cat "${TMP_DIR}/${MANIFEST_ASSET}")"
        if ! release_manifest_matches_tag "${latest_tag}" "${manifest_xml}"; then
            fail "Downloaded ${MANIFEST_ASSET} does not match the selected release ${latest_tag}."
        fi
        chmod 755 "${TMP_DIR}/install" "${TMP_DIR}/${SYNCPS_ASSET}" "${TMP_DIR}/${UNINSTALL_ASSET}"
        return
    fi

    fail "No install source available."
}

persist_local_install_verification_assets() {
    ensure_runtime_dir_ownership
    install -m 600 "${TMP_DIR}/${MASTER_FINGERPRINT_ASSET}" "${RUNTIME_CONFIG_DIR}/${MASTER_FINGERPRINT_ASSET}"
    install -m 700 "${TMP_DIR}/${INSTALL_ASSET}" "${INSTALL_ASSETS_DIR}/${INSTALL_ASSET}"
    install -m 700 "${SCRIPT_DIR}/installer.sh" "${INSTALL_ASSETS_DIR}/installer.sh"
    install -m 644 "${TMP_DIR}/${MANIFEST_ASSET}" "${INSTALL_ASSETS_DIR}/${MANIFEST_ASSET}"
    install -m 600 "${TMP_DIR}/${MANIFEST_SHA_ASSET}" "${INSTALL_ASSETS_DIR}/${MANIFEST_SHA_ASSET}"
    install -m 700 "${TMP_DIR}/${UNINSTALL_ASSET}" "${INSTALL_ASSETS_DIR}/${UNINSTALL_ASSET}"
    chown -R "${REAL_USER}:${REAL_GROUP}" "${INSTALL_ASSETS_DIR}" "${RUNTIME_CONFIG_DIR}" 2>/dev/null || true
}

run_install_binary() {
    local github_user="$1"
    local github_email="$2"
    local github_repo="$3"
    local gpg_key_id="$4"
    local store_path="${5:-${STORE_DIR}}"
    local branch_name="${6:-${BRANCH}}"

    sudo_run "${TMP_DIR}/install" \
        --github-user "${github_user}" \
        --github-email "${github_email}" \
        --github-repo "${github_repo}" \
        --gpg-key-id "${gpg_key_id}" \
        --store-path "${store_path}" \
        --branch "${branch_name}"
}

main_update() {
    local github_repo="${SYNCPSS_UPDATE_GITHUB_REPO:-}"
    local gpg_key_id="${SYNCPSS_UPDATE_GPG_KEY_ID:-}"
    local github_user="${SYNCPSS_UPDATE_GITHUB_USER:-${github_repo%%/*}}"
    local github_email="${SYNCPSS_UPDATE_GITHUB_EMAIL:-}"
    local store_path="${SYNCPSS_UPDATE_STORE_PATH:-${STORE_DIR}}"
    local branch_name="${SYNCPSS_UPDATE_BRANCH:-${BRANCH}}"

    [ -n "${github_repo}" ] || fail "SYNCPSS_UPDATE_GITHUB_REPO is required for update mode"
    [ -n "${gpg_key_id}" ] || fail "SYNCPSS_UPDATE_GPG_KEY_ID is required for update mode"

    section "syncpss release updater"
    info "Updating installed syncpss from the published release channel."

    progress_step 1 3 "Preparing runtime directories"
    ensure_runtime_dir_ownership

    progress_step 2 3 "Fetching verified release assets"
    download_install_binary

    progress_step 3 3 "Installing the refreshed release and persisting verification assets"
    run_install_binary "${github_user}" "${github_email}" "${github_repo}" "${gpg_key_id}" "${store_path}" "${branch_name}"
    persist_local_install_verification_assets
    ensure_runtime_dir_ownership
    hash -r 2>/dev/null || true

    log
    success "syncpss update complete."
}

main_install() {
    local total_steps=6
    local saved_repo_name remote_keys_message repo_target_status

    section "syncpss Linux / WSL installer"
    info "Public app repo: ${REPO_OWNER}/${REPO_NAME}"
    info "Your encrypted password data lives in a separate private GitHub repo that belongs to you."

    progress_step 1 "${total_steps}" "Preparing syncpss runtime folders and Linux dependencies"
    handle_existing_install_state
    ensure_runtime_dir_ownership
    install_runtime_dependencies
    install_github_cli
    install_veracrypt

    progress_step 2 "${total_steps}" "Fetching verified syncpss release assets"
    download_install_binary

    progress_step 3 "${total_steps}" "Authenticating GitHub and confirming your private password-store target"
    ensure_github_auth
    ensure_git_identity

    local github_user default_email repo_name github_repo gpg_key_id git_email detected_repo_name
    github_user="$(gh api user --jq .login)"
    default_email="$(gh api user --jq '.email // ""')"
    git_email="$(git config --global --get user.email || true)"
    if [ -z "${default_email}" ]; then
        default_email="${git_email}"
    fi

    saved_repo_name="$(load_saved_private_repo_name || true)"
    detected_repo_name="$(detected_private_repo_name || true)"
    section "Private password-store setup"
    info "syncpss keeps your encrypted passwords in a separate private GitHub repo that belongs to you."
    info "If the repo already exists, syncpss will connect and reconcile it safely."
    info "If it does not exist yet, syncpss will create it for you during bootstrap."
    if [ -n "${detected_repo_name}" ] && [ "${detected_repo_name}" != "${saved_repo_name:-}" ]; then
        info "Detected existing private repo preference: ${detected_repo_name}"
    fi
    repo_name="${saved_repo_name:-${detected_repo_name:-${DEFAULT_REPO_NAME}}}"
    if ! validate_github_repo_name "${repo_name}"; then
        fail "Resolved private repo name is invalid: ${repo_name}"
    fi
    github_repo="$(resolve_private_repo_target "${github_user}" "${repo_name}")"
    repo_name="${github_repo##*/}"
    save_saved_private_repo_name "${repo_name}"
    if repo_exists "${github_repo}"; then
        repo_target_status="Found existing private repo: git@github.com:${github_repo}.git"
    else
        repo_target_status="No private repo exists yet for ${github_repo}; syncpss will create it during bootstrap."
    fi
    success "Private password-store target: ${github_repo}"
    info "${repo_target_status}"

    progress_step 4 "${total_steps}" "Authorizing SSH access and preparing your private password-store repo"
    ensure_ssh_key
    ensure_store_clone_or_init "${github_repo}"

    progress_step 5 "${total_steps}" "Preparing GPG keys and encrypted password-store state"
    if [ -f "${STORE_DIR}/keys" ]; then
        log
        log "Encrypted remote GPG keys were found in ${STORE_DIR}/keys."
        restore_gpg_from_remote_keys
        gpg_key_id="$(guess_gpg_key_id)"
        [ -n "${gpg_key_id}" ] || fail "Could not determine a GPG key ID after restoring the remote keys container"
    else
        if [ "${STORE_BOOTSTRAP_MODE}" = "cloned-remote" ] && [ "${STORE_REMOTE_KEYS_PRESENT}" = "0" ]; then
            remote_keys_message="Remote password store exists, but it does not include an encrypted keys container yet. Continuing with a fresh GPG onboarding."
        elif [ "${STORE_BOOTSTRAP_MODE}" = "new-local" ]; then
            remote_keys_message="No remote password store exists yet. Continuing with a fresh GPG onboarding."
        else
            remote_keys_message="No encrypted remote GPG keys were found. Continuing with a fresh GPG onboarding."
        fi
        info "${remote_keys_message}"
        gpg_key_id="$(ensure_gpg_key_id)"
    fi
    ensure_pass_initialized "${gpg_key_id}"
    write_store_manifest

    progress_step 6 "${total_steps}" "Installing syncpss and saving local verification assets"
    ensure_store_first_push "${github_user}" "${github_repo}"
    run_install_binary "${github_user}" "${default_email}" "${github_repo}" "${gpg_key_id}"
    persist_local_install_verification_assets
    ensure_runtime_dir_ownership
    hash -r 2>/dev/null || true

    log
    if command_exists syncpss || [ -x /usr/local/bin/syncpss ]; then
        success "Success. You can run 'syncpss' or 'syncpass' now."
        info "Saved private repo target: ${github_repo}"
    else
        log "syncpss was installed, but the current shell did not resolve it on PATH yet."
        log "Try: sudo /usr/local/bin/syncpss"
    fi
}

main() {
    case "${MODE}" in
        install)
            main_install
            ;;
        update|--update)
            main_update
            ;;
        --build-deps|build-deps)
            log "Installing Linux build dependencies for syncpss..."
            log "If another apt/dpkg process is already running, this script will wait for it to finish."
            if pgrep -x apt >/dev/null 2>&1 || \
               pgrep -x apt-get >/dev/null 2>&1 || \
               pgrep -x dpkg >/dev/null 2>&1 || \
               pgrep -f unattended-upgrade >/dev/null 2>&1; then
                log
                log "Current apt/dpkg activity:"
                apt_process_summary
                log
            fi
            install_build_dependencies
            log
            log "WSL build dependencies are installed."
            ;;
        *)
            cat <<EOF
Usage:
  bash scripts/sh/installer.sh
  bash scripts/sh/installer.sh update
  bash scripts/sh/installer.sh --build-deps

Modes:
  install       Install dependencies, set up the pass-store repo, then download and run the install binary
  update        Update an existing syncpss install using the latest release assets
  --build-deps  Install the Linux build toolchain needed by scripts/build.bat
EOF
            exit 1
            ;;
    esac
}

main "$@"
