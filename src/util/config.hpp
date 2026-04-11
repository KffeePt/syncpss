#pragma once

#include <filesystem>
#include <string>

namespace syncpss::util {

struct AppConfig {
    std::string repo_url;
    std::string repo_branch = "main";
    std::string gpg_key_id;
    std::filesystem::path store_path;
};

bool config_exists();
AppConfig load_config();
void save_config(const AppConfig& config);

}  // namespace syncpss::util
