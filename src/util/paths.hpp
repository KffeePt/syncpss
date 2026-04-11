#pragma once

#include <filesystem>
#include <string>
#include <sys/types.h>

namespace syncpss::util {

std::filesystem::path get_real_home();
std::string get_real_username();
uid_t get_real_uid();
gid_t get_real_gid();
std::string get_real_groupname();
std::filesystem::path get_real_xdg_runtime_dir();
std::filesystem::path expand_user_path(const std::string& raw_path);
std::filesystem::path runtime_directory();
std::filesystem::path runtime_logs_directory();
std::filesystem::path runtime_notes_directory();
std::filesystem::path runtime_backups_directory();
std::filesystem::path runtime_install_assets_directory();
std::filesystem::path runtime_config_path();
std::filesystem::path runtime_master_fingerprint_path();
std::filesystem::path persistent_settings_directory();
std::filesystem::path persistent_preferences_path();
std::filesystem::path config_path();
std::filesystem::path config_directory();
std::filesystem::path config_manifest_path();
std::filesystem::path default_store_path();
std::filesystem::path default_install_root();
std::filesystem::path create_secure_temp_directory(const std::string& prefix);
std::filesystem::path create_secure_temp_file(const std::string& prefix, const std::string& suffix = "");
std::filesystem::path install_bin_directory();
std::filesystem::path binary_install_path(const std::string& binary_name);
bool is_safe_recursive_delete_target(const std::filesystem::path& path);
bool is_root_user();
bool is_user_in_group(const std::string& group_name);

}  // namespace syncpss::util
