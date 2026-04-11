#pragma once

#include <filesystem>
#include <optional>
#include <string>

namespace syncpss::tui::detail {

inline constexpr const char* kRepoOwner = "KffeePt";
inline constexpr const char* kRepoName = "syncpss";
inline constexpr const char* kInstallerAsset = "installer.sh";
inline constexpr const char* kInstallerChecksumAsset = "installer.sh.sha256";

struct ReleaseVersionInfo {
    std::string local_version;
    std::string latest_version;
    bool latest_known = false;
    bool update_available = false;
    std::string error;
};

std::string trim_whitespace(const std::string& value);
std::string normalize_release_version(const std::string& value);
std::string format_release_version(const std::string& value);
int compare_release_versions(const std::string& left, const std::string& right);
std::string latest_release_asset_url(const std::string& asset_name);
std::optional<std::string> read_manifest_version_from_file(const std::filesystem::path& manifest_path);
std::optional<std::string> read_installed_manifest_version();
ReleaseVersionInfo fetch_latest_release_version_info();
std::string syncpss_version();

}  // namespace syncpss::tui::detail
