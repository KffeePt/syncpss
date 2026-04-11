#include "tui/detail/common.hpp"

namespace syncpss::tui::detail {

std::string iso8601_utc_now() {
    const auto now = std::chrono::system_clock::now();
    const std::time_t now_time = std::chrono::system_clock::to_time_t(now);
    std::tm utc_time{};
#if defined(__APPLE__) || defined(__linux__)
    gmtime_r(&now_time, &utc_time);
#else
    utc_time = *std::gmtime(&now_time);
#endif
    char buffer[32]{};
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc_time);
    return buffer;
}

std::string repo_name_from_repo_id(const std::string& repo_id) {
    const std::size_t slash = repo_id.find('/');
    if (slash == std::string::npos || slash + 1U >= repo_id.size()) {
        return repo_id.empty() ? "pass-store" : repo_id;
    }
    return repo_id.substr(slash + 1U);
}

std::string repo_owner_from_repo_id(const std::string& repo_id) {
    const std::size_t slash = repo_id.find('/');
    if (slash == std::string::npos) {
        return "";
    }
    return repo_id.substr(0, slash);
}

std::string github_repo_from_url(const std::string& repo_url) {
    const std::string ssh_prefix = "git@github.com:";
    if (repo_url.rfind(ssh_prefix, 0) == 0) {
        std::string repo = repo_url.substr(ssh_prefix.size());
        if (repo.size() > 4U && repo.substr(repo.size() - 4U) == ".git") {
            repo.resize(repo.size() - 4U);
        }
        return repo;
    }
    const std::string https_prefix = "https://github.com/";
    if (repo_url.rfind(https_prefix, 0) == 0) {
        std::string repo = repo_url.substr(https_prefix.size());
        if (repo.size() > 4U && repo.substr(repo.size() - 4U) == ".git") {
            repo.resize(repo.size() - 4U);
        }
        return repo;
    }
    return "";
}

bool answer_is_yes(const std::string& answer, bool default_yes) {
    if (answer.empty()) {
        return default_yes;
    }
    const char lowered = static_cast<char>(std::tolower(static_cast<unsigned char>(answer.front())));
    if (lowered == 'y') {
        return true;
    }
    if (lowered == 'n') {
        return false;
    }
    return default_yes;
}

bool is_gpg_cancelled_error(const std::string& message) {
    return message.find("Operation cancelled") != std::string::npos ||
           message.find("Operation canceled") != std::string::npos ||
           message.find("operation cancelled") != std::string::npos ||
           message.find("operation canceled") != std::string::npos ||
           message.find("Cancelled by user") != std::string::npos ||
           message.find("canceled by user") != std::string::npos;
}

}  // namespace syncpss::tui::detail
