#pragma once

#include "util/config.hpp"

#include <filesystem>
#include <string>

namespace syncpss::util {

struct RuntimeConfig {
    std::string github_username;
    std::string github_email;
    std::filesystem::path ssh_key_path;
    std::string github_repo;
    std::string github_repo_name = "password-store";
    std::string gpg_key_id;
    bool gpg_keys_remote = false;
    std::string telemetry_mode = "off";
    bool metadata_logging_enabled = false;
    bool metadata_log_hostname = false;
    bool metadata_log_ip = false;
    bool metadata_log_mac = false;
    std::string notes_mode = "encrypted";
    std::filesystem::path store_path;
    std::string store_branch = "main";
    std::filesystem::path install_binary = "/usr/local/bin/syncpss";
    std::filesystem::path install_config_dir = "/etc/syncpass";
    std::string install_distro;
    std::string install_installed_at;
    std::string install_version;
};

RuntimeConfig load_runtime_config();
void save_runtime_config(const RuntimeConfig& config);
bool runtime_config_exists();
std::string load_preferred_private_repo_name();
void save_preferred_private_repo_name(const std::string& repo_name);
void clear_preferred_private_repo_name();
AppConfig to_app_config(const RuntimeConfig& config);

}  // namespace syncpss::util
