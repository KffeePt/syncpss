#include "common.hpp"

std::filesystem::path wsl_stage_dir(const UserEntry& user) {
    return user.home_path / kWslRuntimeDirName / kWslHelpersDirName;
}

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
    const std::wstring command =
        L"cd ~/.syncpss/helpers && "
        L"export PATH=$HOME/.local/bin:/usr/local/bin:$PATH; "
        L"export TERM=${TERM:-xterm-256color}; "
        L"chmod u+x ~/.syncpss/helpers/installer.sh ~/.syncpss/helpers/uninstall_syncpss.sh 2>/dev/null || true; "
        L"clear 2>/dev/null || true; "
        L"printf '\\nStarting syncpss installer inside WSL...\\n\\n'; "
        L"SYNCPSS_AUTO_ADVANCE_DEFAULTS=1 bash ~/.syncpss/helpers/installer.sh; "
        L"printf '\\nThe syncpss installer window is staying open for review.\\n'; "
        L"exec bash";

    launch_process_new_console({
        L"wsl.exe", L"-d", distro, L"-u", user.username, L"--", L"bash", L"-lc", command
    });
    log_line("Opened a WSL terminal and started installer.sh automatically.", kGreen);
}
