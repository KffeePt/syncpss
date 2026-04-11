#include "common.hpp"

std::filesystem::path wsl_stage_dir(const UserEntry& user) {
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

void copy_helper_to_wsl_home(const UserEntry& user, const std::filesystem::path& helper_script) {
    const std::filesystem::path stage_dir = wsl_stage_dir(user);
    const std::filesystem::path config_dir = user.home_path / kWslRuntimeDirName / kWslConfigDirName;
    std::filesystem::create_directories(stage_dir);
    std::filesystem::create_directories(config_dir);

    const std::filesystem::path destination = stage_dir / kHelperScript;
    copy_text_file_with_lf(helper_script, destination);

    const std::filesystem::path maintainer_helper = exe_dir() / kMaintainerHelperScript;
    if (std::filesystem::exists(maintainer_helper)) {
        copy_text_file_with_lf(maintainer_helper, stage_dir / kMaintainerHelperScript);
    }

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
        << "chmod u+x ~/.syncpss/helpers/installer.sh ~/.syncpss/helpers/uninstall_syncpss.sh 2>/dev/null || true\n"
        << "clear 2>/dev/null || true\n"
        << "printf '\\nStarting syncpss installer inside WSL...\\n\\n'\n"
        << "SYNCPSS_AUTO_ADVANCE_DEFAULTS=1 bash ~/.syncpss/helpers/installer.sh\n";
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
        const std::filesystem::path local_asset = exe_dir() / asset_name;
        if (!std::filesystem::exists(local_asset)) {
            continue;
        }
        const std::filesystem::path stage_asset = stage_dir / asset_name;
        if (local_asset.extension() == L".sh") {
            copy_text_file_with_lf(local_asset, stage_asset);
        } else {
            std::filesystem::copy_file(local_asset, stage_asset, std::filesystem::copy_options::overwrite_existing);
        }

        if (asset_name == kMasterFingerprint) {
            const std::filesystem::path config_asset = config_dir / asset_name;
            std::filesystem::copy_file(local_asset, config_asset, std::filesystem::copy_options::overwrite_existing);
        }
    }

    std::ofstream note(stage_dir / L"syncpss-install-note.txt", std::ios::binary | std::ios::trunc);
    if (note) {
        note << "syncpss staged install helper\n\n";
        note << "Stage directory:\n";
        note << "  ~/.syncpss/helpers\n\n";
        note << "The Windows installer can open a WSL terminal and run:\n";
        note << "  bash ~/.syncpss/helpers/installer.sh\n";
        note << "automatically for you after staging completes.\n";
        note << "\nIf local install assets were available, they were copied next to the script,\n";
        note << "including manifest.xml so the Linux installer can record the staged version.\n";
        note << "Otherwise the WSL installer will fetch the latest GitHub Release assets\n";
        note << "automatically the first time you run it.\n";
        note << "\nIf you also need the Linux build toolchain:\n";
        note << "  bash ~/.syncpss/helpers/installer.sh --build-deps\n";
    }

    log_line("Copied installer assets to " + to_utf8(stage_dir.wstring()), kGreen);
}

void maybe_open_wsl_shell(const std::wstring& distro, const UserEntry& user) {
    std::wcout << L"\nOpen " << distro << L" as " << user.username
               << L" now and run ~/.syncpss/helpers/installer.sh automatically? [Y/n]: ";
    std::wstring answer;
    std::getline(std::wcin >> std::ws, answer);
    if (!answer.empty() && answer != L"y" && answer != L"Y") {
        return;
    }

    open_wsl_installer_window(distro, user);
}

void open_wsl_installer_window(const std::wstring& distro, const UserEntry& user) {
    const std::wstring launch_distro = resolve_launchable_distro_name(distro);
    const std::filesystem::path launcher_path = windows_runtime_dir() / L"run_syncpss_installer.cmd";
    std::ofstream launcher(launcher_path, std::ios::binary | std::ios::trunc);
    if (!launcher) {
        throw std::runtime_error("Failed to create the Windows WSL installer launcher script.");
    }

    launcher
        << "@echo off\r\n"
        << "setlocal EnableExtensions\r\n"
        << "title syncpss WSL Installer\r\n"
        << "set \"SYNCPSS_DISTRO=" << to_utf8(launch_distro) << "\"\r\n"
        << "set \"SYNCPSS_USER=" << to_utf8(user.username) << "\"\r\n"
        << "\r\n"
        << "echo Target WSL distro: %SYNCPSS_DISTRO%\r\n"
        << "echo Target Linux user: %SYNCPSS_USER%\r\n"
        << "echo.\r\n"
        << "echo Installed WSL distros detected right now:\r\n"
        << "wsl.exe -l -q\r\n"
        << "echo.\r\n"
        << "echo Launching: wsl.exe -d \"%SYNCPSS_DISTRO%\" -u \"%SYNCPSS_USER%\" -- bash -lc \"bash ~/.syncpss/helpers/"
        << to_utf8(std::wstring(kWslInstallerWindowScript)) << "\"\r\n"
        << "wsl.exe -d \"%SYNCPSS_DISTRO%\" -u \"%SYNCPSS_USER%\" -- bash -lc \"bash ~/.syncpss/helpers/"
        << to_utf8(std::wstring(kWslInstallerWindowScript)) << "\"\r\n"
        << "set \"CODE=%ERRORLEVEL%\"\r\n"
        << "echo.\r\n"
        << "echo The syncpss installer window is staying open for review.\r\n"
        << "echo Exit code: %CODE%\r\n"
        << "pause\r\n"
        << "exit /b %CODE%\r\n";
    launcher.flush();
    if (!launcher.good()) {
        throw std::runtime_error("Failed to flush the Windows WSL installer launcher script.");
    }

    launch_process_new_console({
        L"cmd.exe", L"/c", launcher_path.wstring()
    });
    log_line("Opened a WSL terminal and started installer.sh automatically.", kGreen);
}
