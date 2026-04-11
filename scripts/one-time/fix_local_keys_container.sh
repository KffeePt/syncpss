#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${HOME}/.syncpss"
RUNTIME_CONFIG="${RUNTIME_DIR}/config.json"
STORE_DIR="${HOME}/.password-store"
BRANCH="main"
GITHUB_REPO=""
KEYS_PATH=""
VC_SLOT="1"
VC_MAPPER="/dev/mapper/veracrypt1"
MOUNT_POINT=""
MOUNTED_HERE=0
STORE_HASH_FILE=".syncpss-store.sha256"
GIT_NETWORK_TIMEOUT_SECONDS="25"

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

run_git_network() {
    local ssh_cmd
    ssh_cmd="ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2"

    if command -v timeout >/dev/null 2>&1; then
        timeout "${GIT_NETWORK_TIMEOUT_SECONDS}" \
            env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${ssh_cmd}" "$@"
        return $?
    fi

    env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${ssh_cmd}" "$@"
}

vc() {
    if [ "$(id -u)" -eq 0 ]; then
        veracrypt "$@"
    else
        sudo veracrypt "$@"
    fi
}

cleanup() {
    if [ "${MOUNTED_HERE}" -eq 1 ] && [ -n "${MOUNT_POINT}" ]; then
        vc --text --dismount "${MOUNT_POINT}" >/dev/null 2>&1 || true
        vc --text --dismount --slot "${VC_SLOT}" >/dev/null 2>&1 || true
    fi
    if [ -n "${MOUNT_POINT}" ] && [ -d "${MOUNT_POINT}" ]; then
        rm -rf "${MOUNT_POINT}" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

command -v veracrypt >/dev/null 2>&1 || fail "veracrypt is required"
command -v gpg >/dev/null 2>&1 || fail "gpg is required"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

load_runtime_config() {
    [ -f "${RUNTIME_CONFIG}" ] || return 0

    local parsed
    parsed="$(python3 - <<'PY' "${RUNTIME_CONFIG}"
import json
import os
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

store_path = data.get("store", {}).get("path", "")
branch = data.get("store", {}).get("branch", "main")
repo = data.get("github", {}).get("repo", "")

def emit(value):
    return os.path.expanduser(value) if value else ""

print(emit(store_path))
print(branch or "main")
print(repo or "")
PY
)"

    STORE_DIR="$(printf '%s\n' "${parsed}" | sed -n '1p')"
    BRANCH="$(printf '%s\n' "${parsed}" | sed -n '2p')"
    GITHUB_REPO="$(printf '%s\n' "${parsed}" | sed -n '3p')"

    [ -n "${STORE_DIR}" ] || STORE_DIR="${HOME}/.password-store"
    [ -n "${BRANCH}" ] || BRANCH="main"
}

infer_github_repo_from_store() {
    if [ -d "${STORE_DIR}/.git" ]; then
        local remote_url repo
        remote_url="$(git -C "${STORE_DIR}" remote get-url origin 2>/dev/null || true)"
        case "${remote_url}" in
            git@github.com:*.git)
                repo="${remote_url#git@github.com:}"
                repo="${repo%.git}"
                printf '%s' "${repo}"
                return 0
                ;;
            https://github.com/*.git)
                repo="${remote_url#https://github.com/}"
                repo="${repo%.git}"
                printf '%s' "${repo}"
                return 0
                ;;
            https://github.com/*)
                repo="${remote_url#https://github.com/}"
                printf '%s' "${repo}"
                return 0
                ;;
        esac
    fi
    return 1
}

infer_github_repo_from_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        return 1
    fi

    local username
    username="$(gh api user --jq .login 2>/dev/null || true)"
    if [ -z "${username}" ]; then
        return 1
    fi

    printf '%s/pass-store' "${username}"
}

ensure_store_dirs() {
    mkdir -p "${RUNTIME_DIR}/store-backups"
}

backup_existing_store_dir() {
    local backup_dir
    [ -d "${STORE_DIR}" ] || return 0
    backup_dir="${RUNTIME_DIR}/store-backups/password-store.fix.$(date +%Y%m%dT%H%M%S)"
    log "Backing up the current local password store to ${backup_dir}"
    mv "${STORE_DIR}" "${backup_dir}"
}

copy_store_content_without_git_or_containers() {
    local source_dir="$1"
    local destination_dir="$2"
    [ -d "${source_dir}" ] || return 0

    python3 - <<'PY' "${source_dir}" "${destination_dir}"
import os
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
skip_names = {".git", "keys", "backup", "manifest.xml", ".syncpss-store.sha256"}

for root, dirs, files in os.walk(source):
    root_path = Path(root)
    rel = root_path.relative_to(source)
    dirs[:] = [d for d in dirs if d not in skip_names]
    for file_name in files:
        if file_name in skip_names:
            continue
        src = root_path / file_name
        dest = destination / rel / file_name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
PY
}

ensure_store_git_repo() {
    ensure_store_dirs

    if [ -z "${GITHUB_REPO}" ]; then
        GITHUB_REPO="$(infer_github_repo_from_store || true)"
    fi
    if [ -z "${GITHUB_REPO}" ]; then
        GITHUB_REPO="$(infer_github_repo_from_gh || true)"
    fi
    [ -n "${GITHUB_REPO}" ] || fail "No github.repo is configured in ${RUNTIME_CONFIG}, and no pass-store repo could be inferred automatically"

    if [ -d "${STORE_DIR}/.git" ]; then
        log "Refreshing the existing password-store git repo..."
        if ! run_git_network git -C "${STORE_DIR}" fetch origin; then
            fail "Could not refresh the existing password-store git repo. Check GitHub SSH access and try again."
        fi
        if [ -n "$(git -C "${STORE_DIR}" status --porcelain)" ]; then
            log "Skipping pull --rebase because the local password-store already has unstaged changes."
        else
            if ! run_git_network git -C "${STORE_DIR}" pull --rebase origin "${BRANCH}"; then
                fail "Could not pull the latest password-store changes. Check GitHub SSH access and try again."
            fi
        fi
        return
    fi

    local temp_clone previous_store
    previous_store=""
    if [ -d "${STORE_DIR}" ]; then
        previous_store="$(mktemp -d)"
        cp -a "${STORE_DIR}/." "${previous_store}/"
        backup_existing_store_dir
    fi

    temp_clone="$(mktemp -d)"
    log "Cloning git@github.com:${GITHUB_REPO}.git into ${STORE_DIR}"
    if ! run_git_network git clone "git@github.com:${GITHUB_REPO}.git" "${temp_clone}"; then
        fail "Could not clone git@github.com:${GITHUB_REPO}.git. Check GitHub SSH access and try again."
    fi

    if [ -n "${previous_store}" ]; then
        log "Merging the current local passwords into the freshly cloned repo (without ~/.gnupg)..."
        copy_store_content_without_git_or_containers "${previous_store}" "${temp_clone}"
        rm -rf "${previous_store}"
    fi

    rm -rf "${STORE_DIR}"
    mkdir -p "$(dirname "${STORE_DIR}")"
    mv "${temp_clone}" "${STORE_DIR}"
    git -C "${STORE_DIR}" checkout "${BRANCH}" >/dev/null 2>&1 || true
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
        find . -path './.git' -prune -o -type f ! -name "${STORE_HASH_FILE}" -print0 |
            sort -z |
            while IFS= read -r -d '' file; do
                sha256sum "${file}"
            done
    ) > "${manifest}"

    hash="$(sha256sum "${manifest}" | awk '{print $1}')"
    rm -f "${manifest}"
    printf '%s  v%s\n' "${hash}" "${version}" > "${STORE_DIR}/${STORE_HASH_FILE}"
}

mount_keys_container() {
    [ -f "${KEYS_PATH}" ] || fail "Keys container not found at ${KEYS_PATH}"

    read -r -s -p "VeraCrypt password for ${KEYS_PATH}: " VC_PASSWORD
    printf '\n'
    [ -n "${VC_PASSWORD}" ] || fail "A password is required"

    MOUNT_POINT="$(mktemp -d)"
    log "Mounting ${KEYS_PATH} read-write through VeraCrypt slot ${VC_SLOT}..."
    vc --text --dismount --slot "${VC_SLOT}" >/dev/null 2>&1 || true
    if ! printf '%s\n' "${VC_PASSWORD}" | vc --text --non-interactive --stdin --slot "${VC_SLOT}" --mount "${KEYS_PATH}" "${MOUNT_POINT}" \
        --pim 0 \
        --keyfiles "" \
        --protect-hidden no >/dev/null; then
        fail "Failed to mount ${KEYS_PATH}"
    fi
    MOUNTED_HERE=1

    [ -e "${VC_MAPPER}" ] || fail "Expected VeraCrypt mapper device was not created: ${VC_MAPPER}"
}

repair_keys_container() {
    local raw_dir export_home

    mount_keys_container

    if [ -d "${MOUNT_POINT}/.gnupg" ]; then
        raw_dir="${MOUNT_POINT}/.gnupg"
    elif [ -d "${MOUNT_POINT}/gnupg" ]; then
        log "Normalizing gnupg/ to .gnupg/ inside the keys container..."
        rm -rf "${MOUNT_POINT}/.gnupg"
        mv "${MOUNT_POINT}/gnupg" "${MOUNT_POINT}/.gnupg"
        raw_dir="${MOUNT_POINT}/.gnupg"
    else
        fail "The mounted keys container does not contain .gnupg or gnupg"
    fi

    log "Removing live-only GPG runtime artifacts from the keys container copy..."
    rm -rf "${raw_dir}/README.md" "${raw_dir}/S.scdaemon" >/dev/null 2>&1 || true
    find "${raw_dir}" -maxdepth 1 \( -name '.#lk*' -o -name 'S.gpg-agent*' -o -name '*.lock' \) \
        -exec rm -rf {} + 2>/dev/null || true

    cat > "${MOUNT_POINT}/manifest.xml" <<'EOF'
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
      <description>Raw .gnupg directory snapshot used for full keyring rebase and recovery.</description>
    </file>
  </exports>
</syncpss>
EOF
    rm -f "${MOUNT_POINT}/pub.xml"

    export_home="$(mktemp -d)"
    cp -a "${raw_dir}/." "${export_home}/"
    chmod 700 "${export_home}" || true
    find "${export_home}" -type d -exec chmod 700 {} \; 2>/dev/null || true
    find "${export_home}" -type f -exec chmod 600 {} \; 2>/dev/null || true

    log "Refreshing pubkeys.asc / seckeys.asc / ownertrust.txt from the keys container keyring..."
    if GNUPGHOME="${export_home}" gpg --list-secret-keys >/dev/null 2>&1; then
        GNUPGHOME="${export_home}" gpg --armor --export > "${MOUNT_POINT}/pubkeys.asc" 2>/dev/null || true
        GNUPGHOME="${export_home}" gpg --armor --export-secret-keys > "${MOUNT_POINT}/seckeys.asc" 2>/dev/null || true
        GNUPGHOME="${export_home}" gpg --export-ownertrust > "${MOUNT_POINT}/ownertrust.txt" 2>/dev/null || true
    fi
    rm -rf "${export_home}"

    log "Dismounting the repaired keys container..."
    vc --text --dismount "${MOUNT_POINT}" >/dev/null
    MOUNTED_HERE=0
    rm -rf "${MOUNT_POINT}"
    MOUNT_POINT=""
}

push_repaired_store() {
    local version

    git -C "${STORE_DIR}" config pull.rebase false
    if ! run_git_network git -C "${STORE_DIR}" fetch origin; then
        fail "Could not refresh remote refs before pushing the repaired password store."
    fi

    version="$(next_store_version)"
    write_store_manifest
    write_store_hash "${version}"

    git -C "${STORE_DIR}" add -A
    if [ -n "$(git -C "${STORE_DIR}" diff --cached --stat)" ]; then
        git -C "${STORE_DIR}" commit -m "syncpss: repair store layout ${version}"
    fi

    if ! run_git_network git -C "${STORE_DIR}" push --force-with-lease origin "${BRANCH}"; then
        fail "Could not push the repaired password store branch to GitHub."
    fi
    git -C "${STORE_DIR}" tag -f -a "v${version}" -m "pass-store v${version}"
    if ! run_git_network git -C "${STORE_DIR}" push --force origin "v${version}"; then
        fail "Could not push the repaired password store tag to GitHub."
    fi
    log "Password store synced and tagged as v${version}"
}

main() {
    load_runtime_config
    [ -n "${STORE_DIR}" ] || STORE_DIR="${HOME}/.password-store"
    if [ -z "${GITHUB_REPO}" ]; then
        GITHUB_REPO="$(infer_github_repo_from_store || true)"
    fi
    KEYS_PATH="${STORE_DIR}/keys"

    ensure_store_git_repo
    repair_keys_container
    write_store_manifest
    push_repaired_store

    log
    log "Done. The pass-store repo was repaired, synced, and the keys container was updated in place."
}

main "$@"
