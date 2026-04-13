#include "common.hpp"

namespace {

std::optional<std::wstring> configured_release_tag() {
    wchar_t* value = nullptr;
    std::size_t size = 0;
    if (_wdupenv_s(&value, &size, L"SYNCPSS_RELEASE_TAG") != 0 || value == nullptr || size == 0) {
        free(value);
        return std::nullopt;
    }

    const std::wstring tag = trim(value);
    free(value);
    if (tag.empty() || contains_control_chars(tag)) {
        return std::nullopt;
    }
    return tag;
}

std::wstring release_api_base() {
    return L"https://api.github.com/repos/" + std::wstring(kRepoOwner) + L"/" + std::wstring(kRepoName);
}

ProcessResult run_powershell_capture(const std::wstring& command) {
    return run_process({
        L"powershell.exe",
        L"-NoLogo",
        L"-NoProfile",
        L"-ExecutionPolicy",
        L"Bypass",
        L"-Command",
        command
    });
}

std::optional<std::wstring> resolved_release_tag() {
    static bool initialized = false;
    static std::optional<std::wstring> cached_tag;
    if (initialized) {
        return cached_tag;
    }
    initialized = true;

    cached_tag = configured_release_tag();
    if (cached_tag.has_value()) {
        return cached_tag;
    }

    const std::wstring command =
        L"$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'syncpss' }; "
        L"$repo = '" + ps_single_quote(release_api_base()) + L"'; "
        L"try { "
        L"  $release = Invoke-RestMethod -Headers $headers -Uri ($repo + '/releases/latest') -ErrorAction Stop; "
        L"  if ($release.tag_name) { Write-Output $release.tag_name; exit 0 } "
        L"} catch { } "
        L"try { "
        L"  $releases = Invoke-RestMethod -Headers $headers -Uri ($repo + '/releases?per_page=10') -ErrorAction Stop; "
        L"  $tag = $releases | Where-Object { $_.tag_name } | Select-Object -ExpandProperty tag_name -First 1; "
        L"  if ($tag) { Write-Output $tag; exit 0 } "
        L"} catch { } "
        L"exit 1";

    const ProcessResult result = run_powershell_capture(command);
    if (result.exit_code != 0) {
        return std::nullopt;
    }

    const std::wstring tag = trim(to_wide(trim_ascii(result.output)));
    if (tag.empty() || contains_control_chars(tag)) {
        return std::nullopt;
    }
    cached_tag = tag;
    return cached_tag;
}

std::filesystem::path require_asset_path(const std::filesystem::path& base_dir, const wchar_t* asset_name) {
    const std::filesystem::path asset_path = base_dir / asset_name;
    if (!std::filesystem::exists(asset_path)) {
        throw std::runtime_error("Required installer asset is missing: " + to_utf8(asset_path.wstring()));
    }
    return asset_path;
}

void copy_optional_text_asset(
    const std::filesystem::path& source_path,
    const std::filesystem::path& destination_path
) {
    if (!std::filesystem::exists(source_path)) {
        return;
    }
    copy_text_file_with_lf(source_path, destination_path);
}

void copy_optional_binary_asset(
    const std::filesystem::path& source_path,
    const std::filesystem::path& destination_path
) {
    if (!std::filesystem::exists(source_path)) {
        return;
    }
    std::filesystem::copy_file(source_path, destination_path, std::filesystem::copy_options::overwrite_existing);
}

void try_prepare_release_support_asset(
    const wchar_t* asset_name,
    const wchar_t* checksum_name = nullptr
) {
    try {
        const std::filesystem::path asset_path = download_release_asset(asset_name);
        if (checksum_name != nullptr) {
            const std::filesystem::path checksum_path = download_release_asset(checksum_name);
            verify_release_asset_checksum(asset_path, checksum_path);
        }
    } catch (...) {
        if (std::wstring(asset_name) == kManagedPathsScript) {
            const std::filesystem::path local_asset = exe_dir() / asset_name;
            if (std::filesystem::exists(local_asset)) {
                copy_text_file_with_lf(local_asset, process_temp_dir() / asset_name);
                const std::filesystem::path local_checksum = exe_dir() / kManagedPathsScriptChecksum;
                copy_optional_binary_asset(local_checksum, process_temp_dir() / kManagedPathsScriptChecksum);
                return;
            }
        }
        throw;
    }
}

}  // namespace

std::filesystem::path exe_dir() {
    return std::filesystem::path(current_exe_path()).parent_path();
}

std::filesystem::path process_temp_dir() {
    static const std::filesystem::path temp_dir = [] {
        wchar_t temp_root[MAX_PATH];
        const DWORD temp_length = GetTempPathW(MAX_PATH, temp_root);
        if (temp_length == 0 || temp_length >= MAX_PATH) {
            throw std::runtime_error("GetTempPathW failed");
        }

        wchar_t temp_name[MAX_PATH];
        if (GetTempFileNameW(temp_root, L"sps", 0, temp_name) == 0) {
            throw std::runtime_error("GetTempFileNameW failed");
        }

        const std::filesystem::path directory(temp_name);
        std::error_code ignored;
        std::filesystem::remove(directory, ignored);
        std::filesystem::create_directories(directory);
        return directory;
    }();
    return temp_dir;
}

std::string normalize_lf_text(const std::string& input) {
    std::string output;
    output.reserve(input.size());
    for (std::size_t i = 0; i < input.size(); ++i) {
        const char ch = input[i];
        if (ch == '\r') {
            if (i + 1 < input.size() && input[i + 1] == '\n') {
                ++i;
            }
            output.push_back('\n');
            continue;
        }
        output.push_back(ch);
    }
    return output;
}

void copy_text_file_with_lf(const std::filesystem::path& source, const std::filesystem::path& destination) {
    std::ifstream input(source, std::ios::binary);
    if (!input) {
        throw std::runtime_error("Failed to read text asset: " + to_utf8(source.wstring()));
    }

    std::stringstream buffer;
    buffer << input.rdbuf();
    std::ofstream output(destination, std::ios::binary | std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Failed to write text asset: " + to_utf8(destination.wstring()));
    }

    output << normalize_lf_text(buffer.str());
    output.flush();
    if (!output.good()) {
        throw std::runtime_error("Failed to flush text asset: " + to_utf8(destination.wstring()));
    }
}

std::wstring release_asset_url(const std::wstring& release_tag, const std::wstring& asset_name) {
    return L"https://github.com/" + std::wstring(kRepoOwner) + L"/" + std::wstring(kRepoName) +
           L"/releases/download/" + release_tag + L"/" + asset_name;
}

std::string normalize_sha256(const std::string& input) {
    std::string value = trim_ascii(input);
    value.erase(std::remove_if(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }), value.end());
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string checksum_from_sha256_file(const std::filesystem::path& checksum_path) {
    std::ifstream input(checksum_path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("Failed to read checksum file: " + to_utf8(checksum_path.wstring()));
    }

    std::string line;
    std::getline(input, line);
    line = trim_ascii(strip_nuls(line));
    const std::size_t separator = line.find_first_of(" \t");
    if (separator == std::string::npos) {
        return normalize_sha256(line);
    }
    return normalize_sha256(line.substr(0, separator));
}

std::string sha256_for_file(const std::filesystem::path& file_path) {
    const std::wstring command =
        L"$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath '" +
        ps_single_quote(file_path.wstring()) +
        L"').Hash; Write-Output $hash";
    const ProcessResult result = run_process({
        L"powershell.exe",
        L"-NoLogo",
        L"-NoProfile",
        L"-ExecutionPolicy",
        L"Bypass",
        L"-Command",
        command
    });
    if (result.exit_code != 0) {
        throw std::runtime_error("Failed to compute SHA256 for " + to_utf8(file_path.wstring()) + ": " + result.output);
    }

    const std::string hash = normalize_sha256(strip_nuls(result.output));
    if (hash.size() != 64U) {
        throw std::runtime_error("Unexpected SHA256 output for " + to_utf8(file_path.wstring()));
    }
    return hash;
}

void verify_release_asset_checksum(const std::filesystem::path& asset_path, const std::filesystem::path& checksum_path) {
    const std::string expected = checksum_from_sha256_file(checksum_path);
    const std::string actual = sha256_for_file(asset_path);
    if (expected.empty()) {
        throw std::runtime_error("Checksum file is empty: " + to_utf8(checksum_path.wstring()));
    }
    if (actual != expected) {
        std::ostringstream message;
        message << "Checksum mismatch for " << to_utf8(asset_path.wstring())
                << "\nExpected: " << expected
                << "\nActual:   " << actual;
        throw std::runtime_error(message.str());
    }
}

std::filesystem::path download_release_asset(const std::wstring& asset_name) {
    log_line("Downloading " + to_utf8(asset_name) + "...", kCyan);
    const auto temp_root = process_temp_dir();
    const auto destination = temp_root / std::filesystem::path(asset_name);
    const std::optional<std::wstring> release_tag = resolved_release_tag();
    if (!release_tag.has_value()) {
        throw std::runtime_error("Failed to resolve the current GitHub release tag.");
    }

    const std::wstring url = release_asset_url(*release_tag, asset_name);
    const std::wstring command =
        L"$headers = @{ Accept = 'application/octet-stream'; 'User-Agent' = 'syncpss' }; "
        L"Invoke-WebRequest -Headers $headers -Uri '" + ps_single_quote(url) +
        L"' -OutFile '" + ps_single_quote(destination.wstring()) + L"' -ErrorAction Stop";
    const ProcessResult result = run_powershell_capture(command);
    if (result.exit_code != 0 || !std::filesystem::exists(destination)) {
        throw std::runtime_error(
            "Failed to download release asset: " + to_utf8(asset_name) +
            " from " + to_utf8(url) +
            (result.output.empty() ? "" : " (" + trim_ascii(result.output) + ")")
        );
    }
    return destination;
}

std::filesystem::path download_helper_script() {
    const std::filesystem::path script_path = download_release_asset(kHelperScript);
    const std::filesystem::path checksum_path = download_release_asset(kHelperScriptChecksum);
    verify_release_asset_checksum(script_path, checksum_path);
    return script_path;
}

std::string install_source_name(const InstallSource install_source) {
    switch (install_source) {
        case InstallSource::local:
            return "local";
        case InstallSource::release:
            return "release";
    }
    return "release";
}

std::wstring install_source_cli_flag(const InstallSource install_source) {
    (void)install_source;
    return L"--local";
}

PreparedInstallerAssets prepare_installer_assets(const InstallSource install_source) {
    PreparedInstallerAssets assets;
    assets.install_source = install_source;

    if (install_source == InstallSource::local) {
        const std::filesystem::path root_dir = exe_dir();
        require_asset_path(root_dir, kHelperScript);
        require_asset_path(root_dir, kHelperScriptChecksum);
        require_asset_path(root_dir, kManagedPathsScript);
        require_asset_path(root_dir, kInstallBinary);
        require_asset_path(root_dir, kInstallChecksum);
        require_asset_path(root_dir, kSyncpssBinary);
        require_asset_path(root_dir, kSyncpssChecksum);
        require_asset_path(root_dir, kManifestAsset);
        require_asset_path(root_dir, kManifestChecksum);
        require_asset_path(root_dir, kMasterFingerprint);
        require_asset_path(root_dir, L"uninstall_syncpss.sh");
        require_asset_path(root_dir, L"uninstall_syncpss.sh.sha256");
        assets.root_dir = root_dir;
        assets.helper_script = root_dir / kHelperScript;
        return assets;
    }

    const std::filesystem::path root_dir = process_temp_dir();
    const std::filesystem::path helper_script = download_helper_script();
    try_prepare_release_support_asset(kManagedPathsScript, kManagedPathsScriptChecksum);
    try_prepare_release_support_asset(kInstallBinary, kInstallChecksum);
    try_prepare_release_support_asset(kSyncpssBinary, kSyncpssChecksum);
    try_prepare_release_support_asset(kManifestAsset, kManifestChecksum);
    try_prepare_release_support_asset(L"uninstall_syncpss.sh", L"uninstall_syncpss.sh.sha256");
    try_prepare_release_support_asset(kMasterFingerprint, nullptr);
    copy_optional_text_asset(exe_dir() / kMaintainerHelperScript, root_dir / kMaintainerHelperScript);
    assets.root_dir = root_dir;
    assets.helper_script = helper_script;
    return assets;
}

void copy_optional_windows_assets(const std::filesystem::path& app_dir) {
    std::filesystem::create_directories(app_dir);
    for (const auto& asset_name : {kIconPngName, kIconIcoName, kIconSvgName}) {
        const std::filesystem::path source = exe_dir() / asset_name;
        if (!std::filesystem::exists(source)) {
            continue;
        }
        std::filesystem::copy_file(source, app_dir / asset_name, std::filesystem::copy_options::overwrite_existing);
    }
}
