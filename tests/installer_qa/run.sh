#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

FAKE_BIN="${TMP_ROOT}/fake-bin"
mkdir -p "${FAKE_BIN}"

cat > "${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    auth)
        if [ "${2:-}" = "status" ]; then
            exit 0
        fi
        if [ "${2:-}" = "login" ] && [ "${SYNCPSSTEST_GH_AUTH_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        exit 0
        ;;
    api)
        if [ "${2:-}" = "user" ]; then
            if printf '%s ' "$@" | grep -Fq ".login"; then
                printf '%s\n' "${SYNCPSSTEST_GH_LOGIN:-gooduser}"
                exit 0
            fi
            if printf '%s ' "$@" | grep -Fq ".email"; then
                printf '%s\n' "${SYNCPSSTEST_GH_EMAIL:-user@example.com}"
                exit 0
            fi
            printf '{"login":"%s","email":"%s"}\n' "${SYNCPSSTEST_GH_LOGIN:-gooduser}" "${SYNCPSSTEST_GH_EMAIL:-user@example.com}"
            exit 0
        fi
        exit 1
        ;;
    repo)
        if [ "${2:-}" = "view" ]; then
            case "${3:-}" in
                gooduser/goodrepo|gooduser/pass-store)
                    exit 0
                    ;;
                *)
                    exit 1
                    ;;
            esac
        fi
        if [ "${2:-}" = "create" ]; then
            exit 0
        fi
        ;;
esac

exit 1
EOF

cat > "${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

joined="$(printf '%s ' "$@")"
case "${joined}" in
    *"config --global --get user.name"*)
        printf 'Tester\n'
        ;;
    *"config --global --get user.email"*)
        printf 'tester@example.com\n'
        ;;
    *"status --short"*)
        printf ' M README.md\n'
        ;;
    *"remote get-url origin"*)
        printf 'git@github.com:gooduser/goodrepo.git\n'
        ;;
    *"branch --show-current"*)
        printf 'main\n'
        ;;
    *)
        exit 0
        ;;
esac
EOF

cat > "${FAKE_BIN}/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

scenario="${SYNCPSSTEST_GPG_SCENARIO:-valid}"
joined="$(printf '%s ' "$@")"

emit_fprs() {
    case "${scenario}" in
        bad)
            printf 'fpr:::::::::NOT_A_REAL_FPR:\n'
            ;;
        public_only)
            printf 'fpr:::::::::ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234:\n'
            ;;
        *)
            printf 'fpr:::::::::ABCD1234ABCD1234ABCD1234ABCD1234ABCD1234:\n'
            ;;
    esac
}

case "${joined}" in
    *"--list-secret-keys --with-colons"*)
        if [ "${scenario}" = "public_only" ]; then
            exit 0
        fi
        emit_fprs
        ;;
    *"--list-keys --with-colons"*)
        emit_fprs
        ;;
    *"--show-keys --with-colons"*)
        emit_fprs
        ;;
    *"--list-secret-keys "*)
        last_arg=""
        for arg in "$@"; do
            last_arg="${arg}"
        done
        if [ "${SYNCPSSTEST_GPG_HAS_SECRET_KEY:-}" = "${last_arg}" ]; then
            printf 'sec:u:255:22:%s::::::::\n' "${SYNCPSSTEST_GPG_HAS_SECRET_KEY}"
        fi
        ;;
    *)
        exit 0
        ;;
esac
EOF

cat > "${FAKE_BIN}/veracrypt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

joined="$(printf '%s ' "$@")"
mode="${SYNCPSSTEST_VERACRYPT_MODE:-ok}"

if [[ "${joined}" == *"--list"* ]]; then
    printf '%s\n' "${SYNCPSSTEST_VERACRYPT_LIST:-}"
    exit 0
fi

if [[ "${joined}" == *"--restore-headers"* ]]; then
    case "${mode}" in
        restore-fail)
            exit 1
            ;;
        restore-timeout)
            exit 124
            ;;
        *)
            exit 0
            ;;
    esac
fi

if [[ "${joined}" == *"--dismount"* ]]; then
    if [ "${SYNCPSSTEST_VERACRYPT_DISMOUNT_FAIL:-0}" = "1" ]; then
        exit 1
    fi
    exit 0
fi

if [[ "${joined}" == *"--mount"* ]]; then
    case "${mode}" in
        wrong-password)
            printf 'Wrong password or not a valid volume.\n' >&2
            exit 2
            ;;
        headerbak-success)
            if [[ "${joined}" == *"headerbak,ro"* ]]; then
                exit 0
            fi
            printf 'Primary header failed.\n' >&2
            exit 1
            ;;
        restore-fail|restore-timeout)
            printf 'Mount failed before restore.\n' >&2
            exit 1
            ;;
        *)
            exit 0
            ;;
    esac
fi

exit 0
EOF

cat > "${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${SYNCPSSTEST_CURL_MODE:-release-json}" in
    malformed)
        printf '{bad json'
        exit 0
        ;;
    fail)
        printf 'fake curl failure\n' >&2
        exit 22
        ;;
    *)
        printf '{"tag_name":"v1.2.3","name":"Release v1.2.3"}\n'
        exit 0
        ;;
esac
EOF

cat > "${FAKE_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-n" ] && [ "${2:-}" = "true" ]; then
    exit 0
fi
if [ "${1:-}" = "-n" ]; then
    shift
fi
if [ "${1:-}" = "-S" ]; then
    shift 3
fi
"$@"
EOF

cat > "${FAKE_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="${SYNCPSSTEST_MOUNT_STATE_FILE:-}"

if [ -n "${state_file}" ] && [ -f "${state_file}" ]; then
    while IFS= read -r mounted; do
        if [ "${2:-}" = "${mounted}" ]; then
            exit 0
        fi
    done < "${state_file}"
fi

for mounted in ${SYNCPSSTEST_MOUNTPOINTS:-}; do
    if [ "${2:-}" = "${mounted}" ]; then
        exit 0
    fi
done
exit 1
EOF

cat > "${FAKE_BIN}/umount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"
state_file="${SYNCPSSTEST_MOUNT_STATE_FILE:-}"

if [ "${SYNCPSSTEST_UMOUNT_FAIL:-0}" = "1" ]; then
    exit 1
fi

if [ -n "${state_file}" ] && [ -f "${state_file}" ] && [ -n "${target}" ]; then
    filtered="$(mktemp)"
    trap 'rm -f "${filtered}"' EXIT
    grep -Fxv "${target}" "${state_file}" > "${filtered}" || true
    mv "${filtered}" "${state_file}"
fi

exit 0
EOF

cat > "${FAKE_BIN}/cmd.exe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

joined="$(printf '%s ' "$@")"
case "${joined}" in
    *"%APPDATA%"*)
        printf 'C:\\Users\\Tester\\AppData\\Roaming\r\n'
        ;;
    *"%LOCALAPPDATA%"*)
        printf 'C:\\Users\\Tester\\AppData\\Local\r\n'
        ;;
    *"%USERPROFILE%"*)
        printf 'C:\\Users\\Tester\r\n'
        ;;
    *)
        printf 'C:\\Users\\Tester\\AppData\\Roaming\r\n'
        ;;
esac
EOF

cat > "${FAKE_BIN}/wslpath" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-w" ] && [ -n "${2:-}" ]; then
    printf '%s\n' "${2}"
    exit 0
fi

case "${2:-${1:-}}" in
    C:\\Users\\Tester\\AppData\\Roaming)
        printf '%s/AppData/Roaming\n' "${SYNCPSSTEST_WINDOWS_ROOT}"
        ;;
    C:\\Users\\Tester\\AppData\\Local)
        printf '%s/AppData/Local\n' "${SYNCPSSTEST_WINDOWS_ROOT}"
        ;;
    C:\\Users\\Tester)
        printf '%s\n' "${SYNCPSSTEST_WINDOWS_ROOT}"
        ;;
    *)
        printf '%s/AppData/Roaming\n' "${SYNCPSSTEST_WINDOWS_ROOT}"
        ;;
esac
EOF

cat > "${FAKE_BIN}/powershell.exe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

joined="$(printf '%s ' "$@")"
if [[ "${joined}" == *"-File"* && "${joined}" == *"purge.ps1"* ]]; then
    if [ "${SYNCPSSTEST_POWERSHELL_REMOVE_FAIL:-0}" = "1" ]; then
        exit 1
    fi

    mode=""
    next_is_mode=0
    for arg in "$@"; do
        if [ "${next_is_mode}" = "1" ]; then
            mode="${arg}"
            next_is_mode=0
            continue
        fi
        if [ "${arg}" = "-Mode" ]; then
            next_is_mode=1
        fi
    done

    case "${mode}" in
        start-menu-shortcut)
            rm -f "${SYNCPSSTEST_WINDOWS_ROOT}/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/syncpss.lnk"
            ;;
        local-app-assets)
            rm -rf "${SYNCPSSTEST_WINDOWS_ROOT}/AppData/Local/syncpss"
            ;;
        runtime-helper-dir)
            rm -rf "${SYNCPSSTEST_WINDOWS_ROOT}/.syncpss"
            ;;
    esac
    exit 0
fi

if [[ "${joined}" == *"Remove-Item"* ]]; then
    if [ "${SYNCPSSTEST_POWERSHELL_REMOVE_FAIL:-0}" = "1" ]; then
        exit 1
    fi
    target="${WINDOWS_TARGET_PATH:-}"
    if [ -z "${target}" ]; then
        target="${@: -1}"
    fi
    rm -rf "${target}"
    exit 0
fi

if [[ "${joined}" == *"Test-Path"* ]]; then
    if [ "${SYNCPSSTEST_SHORTCUT_EXISTS:-0}" = "1" ]; then
        exit 0
    fi
    exit 1
fi

if [[ "${joined}" == *"Start-Process"* ]]; then
    if [ "${SYNCPSSTEST_LAUNCH_FAIL:-0}" = "1" ]; then
        exit 1
    fi
    exit 0
fi

exit 0
EOF

cat > "${FAKE_BIN}/wsl.exe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

chmod +x "${FAKE_BIN}/"*

export PATH="${FAKE_BIN}:${PATH}"
export HOME="${TMP_ROOT}/home"
export SYNCPSSTEST_WINDOWS_ROOT="${TMP_ROOT}/fake-windows"
export SYNCPSSTEST_MOUNT_STATE_FILE="${TMP_ROOT}/mountpoints.txt"
unset SYNCPSS_PRIVATE_REPO_NAME || true
mkdir -p \
    "${HOME}/.ssh" \
    "${HOME}/.config/syncpss" \
    "${HOME}/.syncpss/tmp" \
    "${HOME}/.syncpss/config" \
    "${HOME}/.password-store" \
    "${SYNCPSSTEST_WINDOWS_ROOT}"

run_in_installer() {
    local expression="$1"
    RUN_EXPR="${expression}" bash -lc "cd '${ROOT_DIR}' && unset SYNCPSS_PRIVATE_REPO_NAME || true && source scripts/sh/installer.sh && eval \"\$RUN_EXPR\""
}

run_in_uninstall() {
    local expression="$1"
    RUN_EXPR="${expression}" bash -lc "cd '${ROOT_DIR}' && unset SYNCPSS_PRIVATE_REPO_NAME || true && source scripts/sh/uninstall_syncpss.sh && eval \"\$RUN_EXPR\""
}

run_test() {
    local name="$1"
    shift
    if "$@"; then
        printf 'PASS %s\n' "${name}"
        return 0
    fi
    printf 'FAIL %s\n' "${name}" >&2
    return 1
}

run_failure_contains() {
    local runner="$1"
    local expression="$2"
    local needle="$3"
    local output

    if output="$("${runner}" "${expression}" 2>&1)"; then
        printf '%s\n' "${output}" >&2
        return 1
    fi

    printf '%s' "${output}" | grep -Fq "${needle}"
}

SHORTCUT_PATH="${SYNCPSSTEST_WINDOWS_ROOT}/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/syncpss.lnk"
WINDOWS_RUNTIME_DIR="${SYNCPSSTEST_WINDOWS_ROOT}/.syncpss"
WINDOWS_APP_DIR="${SYNCPSSTEST_WINDOWS_ROOT}/AppData/Local/syncpss"
LONG_REPO_NAME="$(printf 'a%.0s' $(seq 1 101))"
mkdir -p "$(dirname "${SHORTCUT_PATH}")" "${WINDOWS_RUNTIME_DIR}" "${WINDOWS_APP_DIR}"
touch "${SHORTCUT_PATH}" "${WINDOWS_APP_DIR}/asset.txt" "${WINDOWS_RUNTIME_DIR}/purge.ps1"

run_test "valid repo name accepted" run_in_installer "validate_github_repo_name 'goodrepo'"
run_test "invalid repo name rejected" bash -lc "! (cd '${ROOT_DIR}' && source scripts/sh/installer.sh && validate_github_repo_name '../bad')"
run_test "oversized repo name rejected" bash -lc "! (cd '${ROOT_DIR}' && source scripts/sh/installer.sh && validate_github_repo_name '${LONG_REPO_NAME}')"
run_test "invalid branch rejected" bash -lc "! (cd '${ROOT_DIR}' && source scripts/sh/installer.sh && validate_store_branch 'bad branch;rm')"
run_test "installer local flag sets explicit local source" run_in_installer "parse_cli_args --local; [ \"\${MODE}\" = 'install' ] && [ \"\${SYNCPSS_INSTALL_SOURCE}\" = 'local' ]"
run_test "installer release is the default install source" run_in_installer "[ \"\$(select_install_asset_source 'v1.2.3' 2>/dev/null)\" = 'github' ]"
run_test "installer local flag fails closed without staged assets" run_failure_contains run_in_installer "parse_cli_args --local; select_install_asset_source 'v1.2.3'" "no local install assets are staged"
run_test "sudo_run propagates TUI privileged command failures" run_in_installer "INSTALLER_TUI_ENABLED=1; INSTALLER_TUI_ACTIVE=1; installer_tui_run_command_logged(){ return 23; }; prompt_secret(){ printf 'pw'; }; yes_no_prompt(){ printf 'n'; }; sudo(){ [ \"\${1:-}\" = '-n' ] && [ \"\${2:-}\" = 'true' ] && return 0; return 23; }; set +e; sudo_run false >/dev/null 2>&1; status=\$?; set -e; [ \"\${status}\" -eq 23 ]"
run_test "poisoned repo env rejected" run_failure_contains run_in_installer "export SYNCPSS_PRIVATE_REPO_NAME=\$'bad\nname'; validate_runtime_env_overrides" "SYNCPSS_PRIVATE_REPO_NAME is invalid"
run_test "managed repo target resolves" run_in_installer "[ \"\$(resolve_private_repo_target gooduser goodrepo | tail -n 1 | tr -d '\r')\" = 'gooduser/goodrepo' ]"
run_test "legacy pass-store fallback resolves" run_in_installer "[ \"\$(resolve_private_repo_target gooduser betterrepo | tail -n 1 | tr -d '\r')\" = 'gooduser/pass-store' ]"

printf '{"install":{"binary":"/usr/local/bin/syncpss"}}\n' > "${HOME}/.syncpss/config.json"
run_test "runtime config nested field parses safely" run_in_installer "[ \"\$(runtime_config_string_field binary)\" = '/usr/local/bin/syncpss' ]"
printf '{bad json\n' > "${HOME}/.syncpss/config.json"
run_test "runtime config malformed json is rejected" bash -lc "! (cd '${ROOT_DIR}' && export PATH='${FAKE_BIN}':\$PATH && export HOME='${HOME}'; source scripts/sh/installer.sh && runtime_config_string_field binary)"

run_test "malformed release json is ignored" bash -lc "(cd '${ROOT_DIR}' && export PATH='${FAKE_BIN}':\$PATH && export HOME='${HOME}' && export SYNCPSSTEST_CURL_MODE=malformed; source scripts/sh/installer.sh; [ -z \"\$(latest_release_tag || true)\" ])"

run_test "veracrypt wrong password reports safe retry" run_in_installer "export SYNCPSSTEST_VERACRYPT_MODE=wrong-password; ! mount_or_reuse_veracrypt_volume '${HOME}/.password-store/keys' '${TMP_ROOT}/mount-one' 'secret' >/dev/null 2>&1; printf '%s' \"\$(veracrypt_mount_failure_message '${HOME}/.password-store/keys')\" | grep -Fq 'safe to retry'"
run_test "veracrypt embedded backup header fallback succeeds" run_in_installer "export SYNCPSSTEST_VERACRYPT_MODE=headerbak-success; result=\"\$(mount_or_reuse_veracrypt_volume '${HOME}/.password-store/keys' '${TMP_ROOT}/mount-two' 'secret' 2>/dev/null | tail -n 1 | tr -d '\r')\"; [ \"\${result%%	*}\" = 'mounted' ]"
run_test "veracrypt header restore failure surfaces explicit error" run_in_installer "export SYNCPSSTEST_VERACRYPT_MODE=restore-fail; ! mount_or_reuse_veracrypt_volume '${HOME}/.password-store/keys' '${TMP_ROOT}/mount-three' 'secret' >/dev/null 2>&1; printf '%s' \"\$(veracrypt_mount_failure_message '${HOME}/.password-store/keys')\" | grep -Fq 'Nothing under ~/.gnupg was changed'"

run_test "invalid gpg fingerprints are filtered" bash -lc "(cd '${ROOT_DIR}' && export PATH='${FAKE_BIN}':\$PATH && export HOME='${HOME}' && export SYNCPSSTEST_GPG_SCENARIO=bad; source scripts/sh/installer.sh; [ -z \"\$(list_secret_key_fingerprints || true)\" ])"

run_test "windows shortcut readiness succeeds when shortcut exists" bash -lc "(cd '${ROOT_DIR}' && export PATH='${FAKE_BIN}':\$PATH && export HOME='${HOME}' && export SYNCPSSTEST_SHORTCUT_EXISTS=1; source scripts/sh/installer.sh; windows_shortcut_launch_ready)"
run_test "launch now fails closed when shortcut is missing" bash -lc "! (cd '${ROOT_DIR}' && export PATH='${FAKE_BIN}':\$PATH && export HOME='${HOME}' && export SYNCPSSTEST_SHORTCUT_EXISTS=0; source scripts/sh/installer.sh; launch_syncpss_now)"

run_test "uninstall rejects unmanaged windows path" run_failure_contains run_in_uninstall "remove_windows_path_if_safe '/tmp/not-windows' '${SHORTCUT_PATH}'" "Refusing to delete unmanaged Windows path"
run_test "uninstall removes only exact allowed windows paths" run_in_uninstall "purge_windows_shortcut_assets; [ ! -e '${SHORTCUT_PATH}' ] && [ ! -e '${WINDOWS_RUNTIME_DIR}' ] && [ ! -e '${WINDOWS_APP_DIR}' ]"
mkdir -p "$(dirname "${SHORTCUT_PATH}")" "${WINDOWS_RUNTIME_DIR}"
touch "${SHORTCUT_PATH}" "${WINDOWS_RUNTIME_DIR}/purge.ps1"
run_test "uninstall uses staged Windows purge helper for Start Menu shortcut" run_in_uninstall "rm(){ if [ \"\${1:-}\" = '-rf' ] && [ \"\${2:-}\" = '${SHORTCUT_PATH}' ]; then return 1; fi; command rm \"\$@\"; }; purge_windows_shortcut_assets; [ ! -e '${SHORTCUT_PATH}' ]"
mkdir -p "${WINDOWS_RUNTIME_DIR}"
touch "${WINDOWS_RUNTIME_DIR}/purge.ps1"
run_test "uninstall uses staged Windows purge helper for runtime dir" run_in_uninstall "rm(){ if [ \"\${1:-}\" = '-rf' ] && [ \"\${2:-}\" = '${WINDOWS_RUNTIME_DIR}' ]; then return 1; fi; command rm \"\$@\"; }; purge_windows_shortcut_assets; [ ! -e '${WINDOWS_RUNTIME_DIR}' ]"
mkdir -p "${WINDOWS_RUNTIME_DIR}"
touch "${WINDOWS_RUNTIME_DIR}/runtime.txt"
run_test "uninstall falls back to PowerShell when WSL rm is denied" run_in_uninstall "rm(){ if [ \"\${1:-}\" = '-rf' ] && [ \"\${2:-}\" = '${WINDOWS_RUNTIME_DIR}' ]; then return 1; fi; command rm \"\$@\"; }; remove_windows_path_if_safe '${WINDOWS_RUNTIME_DIR}' '${WINDOWS_RUNTIME_DIR}'; [ ! -e '${WINDOWS_RUNTIME_DIR}' ]"
mkdir -p "${WINDOWS_RUNTIME_DIR}"
touch "${WINDOWS_RUNTIME_DIR}/runtime.txt"
run_test "uninstall returns nonzero when PowerShell fallback also fails" bash -lc "! (cd '${ROOT_DIR}' && export PATH='${FAKE_BIN}':\$PATH && export HOME='${HOME}' && export SYNCPSSTEST_WINDOWS_ROOT='${SYNCPSSTEST_WINDOWS_ROOT}' && export SYNCPSSTEST_POWERSHELL_REMOVE_FAIL=1; source scripts/sh/uninstall_syncpss.sh; rm(){ if [ \"\${1:-}\" = '-rf' ] && [ \"\${2:-}\" = '${WINDOWS_RUNTIME_DIR}' ]; then return 1; fi; command rm \"\$@\"; }; remove_windows_path_if_safe '${WINDOWS_RUNTIME_DIR}' '${WINDOWS_RUNTIME_DIR}')"

printf '/mnt/keys\n' > "${SYNCPSSTEST_MOUNT_STATE_FILE}"
run_test "mounted /mnt/keys is left in place for safety" bash -lc "cd '${ROOT_DIR}' && export PATH='${FAKE_BIN}':\$PATH && export HOME='${HOME}' && export SYNCPSSTEST_MOUNT_STATE_FILE='${SYNCPSSTEST_MOUNT_STATE_FILE}' && export SYNCPSSTEST_VERACRYPT_DISMOUNT_FAIL=1 && export SYNCPSSTEST_UMOUNT_FAIL=1 && output=\"\$(source scripts/sh/uninstall_syncpss.sh; remove_managed_mount_path '/mnt/keys' 2>&1 || true)\" && printf '%s' \"\${output}\" | grep -Fq 'Leaving it in place' && grep -Fxq '/mnt/keys' '${SYNCPSSTEST_MOUNT_STATE_FILE}'"

printf 'installer QA harness completed successfully.\n'
