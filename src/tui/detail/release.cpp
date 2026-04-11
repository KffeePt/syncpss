
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"

#include <nlohmann/json.hpp>

namespace syncpss::tui::detail {

using json = nlohmann::json;

#ifndef SYNCPSS_VERSION
#define SYNCPSS_VERSION "dev"
#endif

constexpr const char* kReleaseApiUrl = "https://api.github.com/repos/KffeePt/syncpss/releases/latest";

std::string trim_whitespace(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1U);
}

std::string normalize_release_version(const std::string& value) {
    std::string normalized = trim_whitespace(value);
    if (normalized.rfind("Release ", 0) == 0) {
        normalized = normalized.substr(8);
    }
    while (!normalized.empty() && (normalized.front() == 'v' || normalized.front() == 'V')) {
        normalized.erase(normalized.begin());
    }
    return trim_whitespace(normalized);
}

std::string format_release_version(const std::string& value) {
    const std::string normalized = normalize_release_version(value);
    if (normalized.empty()) {
        return "unknown";
    }
    if (normalized == "dev") {
        return normalized;
    }
    return "v" + normalized;
}

bool try_parse_semver(const std::string& value, std::array<int, 3>& parts) {
    const std::regex pattern(R"(^([0-9]+)\.([0-9]+)\.([0-9]+)$)");
    std::smatch match;
    const std::string normalized = normalize_release_version(value);
    if (!std::regex_match(normalized, match, pattern)) {
        return false;
    }

    parts = {
        std::stoi(match[1].str()),
        std::stoi(match[2].str()),
        std::stoi(match[3].str())
    };
    return true;
}

int compare_release_versions(const std::string& left, const std::string& right) {
    std::array<int, 3> left_parts{};
    std::array<int, 3> right_parts{};
    const bool left_semver = try_parse_semver(left, left_parts);
    const bool right_semver = try_parse_semver(right, right_parts);

    if (left_semver && right_semver) {
        if (left_parts < right_parts) {
            return -1;
        }
        if (left_parts > right_parts) {
            return 1;
        }
        return 0;
    }

    const std::string normalized_left = normalize_release_version(left);
    const std::string normalized_right = normalize_release_version(right);
    if (normalized_left == normalized_right) {
        return 0;
    }
    return normalized_left < normalized_right ? -1 : 1;
}

std::string latest_release_asset_url(const std::string& asset_name) {
    return "https://github.com/" + std::string(kRepoOwner) + "/" + std::string(kRepoName) +
        "/releases/latest/download/" + asset_name;
}

std::optional<std::string> read_manifest_version_from_file(const std::filesystem::path& manifest_path) {
    std::ifstream input(manifest_path);
    if (!input) {
        return std::nullopt;
    }

    const std::string content{
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>()
    };
    static const std::regex version_pattern(R"(<version>\s*([^<]+)\s*</version>)");
    std::smatch match;
    if (!std::regex_search(content, match, version_pattern) || match.size() < 2) {
        return std::nullopt;
    }

    const std::string version = normalize_release_version(match[1].str());
    if (version.empty()) {
        return std::nullopt;
    }
    return version;
}

std::optional<std::string> read_installed_manifest_version() {
    std::error_code ignored;
    const std::filesystem::path manifest_path = syncpss::util::config_manifest_path();
    if (!std::filesystem::exists(manifest_path, ignored)) {
        return std::nullopt;
    }
    return read_manifest_version_from_file(manifest_path);
}

std::string syncpss_version() {
    const std::optional<std::string> manifest_version = read_installed_manifest_version();
    if (manifest_version.has_value()) {
        return *manifest_version;
    }
    return SYNCPSS_VERSION;
}

ReleaseVersionInfo fetch_latest_release_version_info() {
    ReleaseVersionInfo info;
    const std::optional<std::string> installed_manifest_version = read_installed_manifest_version();
    info.local_version = normalize_release_version(
        installed_manifest_version.has_value() ? *installed_manifest_version : SYNCPSS_VERSION
    );

    syncpss::util::ProcessResult result;
    if (syncpss::util::is_command_available("curl")) {
        result = syncpss::util::run(
            {
                "curl",
                "-fsSL",
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                "User-Agent: syncpss",
                kReleaseApiUrl
            }
        );
    } else if (syncpss::util::is_command_available("gh")) {
        result = syncpss::util::run(
            {
                "gh",
                "release",
                "view",
                "latest",
                "-R",
                std::string(kRepoOwner) + "/" + std::string(kRepoName),
                "--json",
                "tagName"
            }
        );
    } else {
        info.error = "Neither curl nor gh is available to check for updates.";
        return info;
    }

    if (result.exit_code != 0) {
        info.error = trim_whitespace(result.stderr_output.empty() ? result.stdout_output : result.stderr_output);
        if (info.error.empty()) {
            info.error = "Failed to fetch the latest release version.";
        }
        return info;
    }

    json payload;
    try {
        payload = json::parse(result.stdout_output);
    } catch (const std::exception& ex) {
        info.error = "Failed to parse the latest release metadata: " + std::string(ex.what());
        return info;
    }
    std::string latest;
    if (payload.is_object()) {
        latest = payload.value("tag_name", payload.value("tagName", payload.value("name", "")));
    }

    latest = normalize_release_version(latest);
    if (latest.empty()) {
        info.error = "Latest release metadata did not include a usable version tag.";
        return info;
    }

    info.latest_version = latest;
    info.latest_known = true;
    info.update_available = compare_release_versions(info.local_version, info.latest_version) < 0;
    return info;
}

}  // namespace syncpss::tui::detail
