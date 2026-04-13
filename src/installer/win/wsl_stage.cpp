#include "common.hpp"

std::filesystem::path wsl_stage_dir(const UserEntry& user) {
    validate_linux_username_or_throw(user.username);
    return user.home_path / kWslRuntimeDirName / kWslHelpersDirName;
}

namespace {

std::wstring normalized_name(const std::wstring& value) {
    std::wstring normalized = trim(value);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](wchar_t ch) {
        return static_cast<wchar_t>(std::towlower(ch));
    });
    return normalized;
}

std::wstring resolve_launchable_distro_name(const std::wstring& requested_distro) {
    validate_wsl_distro_name_or_throw(requested_distro);
    const auto installed_distros = list_distros();
    const std::wstring requested_normalized = normalized_name(requested_distro);

    for (const auto& distro : installed_distros) {
        if (normalized_name(distro) == requested_normalized) {
            return distro;
        }
    }

    std::wstring message = L"The selected WSL distro '" + requested_distro + L"' is not currently available.\n";
    if (!installed_distros.empty()) {
        message += L"Installed distros detected now:\n";
        for (const auto& distro : installed_distros) {
            message += L"  - " + distro + L"\n";
        }
    } else {
        message += L"No installed WSL distros were detected just before launch.\n";
    }
    throw std::runtime_error(to_utf8(message));
}

}  // namespace

namespace {

void stage_asset_if_present(
    const std::filesystem::path& source_root,
    const std::filesystem::path& destination_root,
    const wchar_t* asset_name
) {
    const std::filesystem::path source_path = source_root / asset_name;
    if (!std::filesystem::exists(source_path)) {
        return;
    }

    const std::filesystem::path destination_path = destination_root / asset_name;
    if (source_path.extension() == L".sh") {
        copy_text_file_with_lf(source_path, destination_path);
    } else {
        std::filesystem::copy_file(source_path, destination_path, std::filesystem::copy_options::overwrite_existing);
    }
}

std::string install_mode_note(const InstallSource install_source) {
    if (install_source == InstallSource::local) {
        return "Local development mode was selected. Windows-staged bin assets were copied into ~/.syncpss/helpers\n"
               "so installer.sh --local can install the currently built or modified version.\n";
    }
    return "Release mode was selected. Release binaries from GitHub were downloaded to ~/.syncpss/helpers\n"
           "so installer.sh --local can install the verified release channel version.\n";
}

}  // namespace

void copy_helper_to_wsl_home(const UserEntry& user, const PreparedInstallerAssets& assets) {
    const std::filesystem::path stage_dir = wsl_stage_dir(user);
    const std::filesystem::path config_dir = user.home_path / kWslRuntimeDirName / kWslConfigDirName;
    const std::filesystem::path logs_dir = user.home_path / kWslRuntimeDirName / L"logs";
    const std::filesystem::path wsl_installer_log = logs_dir / L"wsl-installer.log";
    std::filesystem::create_directories(stage_dir);
    std::filesystem::create_directories(config_dir);
    std::filesystem::create_directories(logs_dir);

    {
        std::ofstream log_output(wsl_installer_log, std::ios::app);
        if (log_output) {
            log_output << "[windows-bootstrap] Prepared "
                       << install_source_name(assets.install_source)
                       << " staging assets for "
                       << to_utf8(user.username)
                       << " at "
                       << to_utf8(stage_dir.wstring())
                       << "\n";
        }
    }

    copy_text_file_with_lf(assets.helper_script, stage_dir / kHelperScript);
    stage_asset_if_present(assets.root_dir, stage_dir, kHelperScriptChecksum);
    stage_asset_if_present(assets.root_dir, stage_dir, kManagedPathsScript);
    stage_asset_if_present(assets.root_dir, stage_dir, kManagedPathsScriptChecksum);
    stage_asset_if_present(assets.root_dir, stage_dir, kMaintainerHelperScript);

    const std::filesystem::path installer_window_script = stage_dir / kWslInstallerWindowScript;
    std::ofstream window_script(installer_window_script, std::ios::binary | std::ios::trunc);
    if (!window_script) {
        throw std::runtime_error("Failed to create the WSL installer launch helper.");
    }
    window_script
        << "#!/usr/bin/env bash\n"
        << "set -euo pipefail\n"
        << "cd ~/.syncpss/helpers\n"
        << "export PATH=\"$HOME/.local/bin:/usr/local/bin:$PATH\"\n"
        << "export TERM=\"${TERM:-xterm-256color}\"\n"
        << "mkdir -p \"$HOME/.syncpss/logs\"\n"
        << "chmod 700 \"$HOME/.syncpss/logs\" 2>/dev/null || true\n"
        << "WSL_INSTALLER_LOG=\"$HOME/.syncpss/logs/wsl-installer.log\"\n"
        << ": >> \"$WSL_INSTALLER_LOG\"\n"
        << "chmod 600 \"$WSL_INSTALLER_LOG\" 2>/dev/null || true\n"
        << "chmod u+x ~/.syncpss/helpers/install ~/.syncpss/helpers/installer.sh ~/.syncpss/helpers/managed_paths.sh ~/.syncpss/helpers/uninstall_syncpss.sh 2>/dev/null || true\n"
        << "clear 2>/dev/null || true\n"
        << "printf '[%s] Starting syncpss installer window in "
        << install_source_name(assets.install_source)
        << " mode.\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" >> \"$WSL_INSTALLER_LOG\"\n"
        << "printf '\\nStarting syncpss installer inside WSL...\\n\\n'\n"
        << "set +e\n"
        << "SYNCPSS_AUTO_ADVANCE_DEFAULTS=1 bash ~/.syncpss/helpers/installer.sh "
        << to_utf8(install_source_cli_flag(assets.install_source))
        << "\n"
        << "installer_exit=$?\n"
        << "set -e\n"
        << "printf '[%s] Installer exit code: %s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"${installer_exit}\" >> \"$WSL_INSTALLER_LOG\"\n"
        << "printf '[%s] Detailed installer output is in %s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"$HOME/.syncpss/logs/installer.log\" >> \"$WSL_INSTALLER_LOG\"\n"
        << "printf '\\nInstaller exit code: %s\\n' \"${installer_exit}\"\n"
        << "if [ \"${installer_exit}\" -eq 0 ]; then\n"
        << "    printf 'syncpss installer completed. This WSL window will stay open for review.\\n\\n'\n"
        << "else\n"
        << "    printf 'syncpss installer failed. Review the output above and ~/.syncpss/logs/installer.log before retrying.\\n\\n'\n"
        << "fi\n"
        << "exec bash\n";
    window_script.flush();
    if (!window_script.good()) {
        throw std::runtime_error("Failed to flush the WSL installer launch helper.");
    }

    for (const auto& asset_name : {
             kInstallBinary,
             kInstallChecksum,
             kSyncpssBinary,
             kSyncpssChecksum,
             kManifestAsset,
             kManifestChecksum,
             kMasterFingerprint,
             L"uninstall_syncpss.sh",
             L"uninstall_syncpss.sh.sha256"
         }) {
        stage_asset_if_present(assets.root_dir, stage_dir, asset_name);

        if (asset_name == kMasterFingerprint && std::filesystem::exists(assets.root_dir / asset_name)) {
            std::filesystem::copy_file(
                assets.root_dir / asset_name,
                config_dir / asset_name,
                std::filesystem::copy_options::overwrite_existing
            );
        }
    }

    std::ofstream note(stage_dir / L"syncpss-install-note.txt", std::ios::binary | std::ios::trunc);
    if (note) {
        note << "syncpss staged install helper\n\n";
        note << "Stage directory:\n";
        note << "  ~/.syncpss/helpers\n\n";
        note << "The Windows installer can open a WSL terminal and run:\n";
        note << "  bash ~/.syncpss/helpers/installer.sh " << to_utf8(install_source_cli_flag(assets.install_source)) << "\n";
        note << "automatically for you after staging completes.\n";
        note << "\n" << install_mode_note(assets.install_source);
        note << "\nIf you also need the Linux build toolchain:\n";
        note << "  bash ~/.syncpss/helpers/installer.sh --build-deps\n";
    }

    log_line(
        "Copied " + install_source_name(assets.install_source) + " installer assets to " + to_utf8(stage_dir.wstring()),
        kGreen
    );
}

void maybe_open_wsl_shell(const std::wstring& distro, const UserEntry& user) {
    std::wcout << L"\nOpen " << distro << L" as " << user.username
               << L" now and run ~/.syncpss/helpers/installer.sh automatically? [Y/n]: ";
    std::wstring answer;
    std::getline(std::wcin >> std::ws, answer);
    if (!answer.empty() && answer != L"y" && answer != L"Y") {
        return;
    }

    open_wsl_installer_window(distro, user, InstallSource::release);
}

void open_wsl_installer_window(const std::wstring& distro, const UserEntry& user, const InstallSource install_source) {
    const std::wstring launch_distro = resolve_launchable_distro_name(distro);
    launch_process_new_console({
        L"wsl.exe",
        L"-d",
        launch_distro,
        L"-u",
        user.username,
        L"--",
        L"bash",
        L"-lc",
        L"bash ~/.syncpss/helpers/run_installer_window.sh"
    });
    log_line(
        "Opened a WSL terminal and started installer.sh in " + install_source_name(install_source) + " mode.",
        kGreen
    );
}
