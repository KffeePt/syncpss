#pragma once

#include "tui/tui.hpp"
#include "tui/colors.hpp"
#include "util/clipboard.hpp"
#include "util/entry_metadata.hpp"
#include "util/paths.hpp"
#include "util/process.hpp"
#include "util/runtime_config.hpp"

#include <ncurses.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <future>
#include <iterator>
#include <map>
#include <mutex>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <type_traits>
#include <unistd.h>
#include <vector>
#include <sys/ioctl.h>

namespace syncpss::tui::detail {

struct ManifestEntry {
    std::string path;
    std::string description;
};

std::string normalize_hex_id(const std::string& value);
bool matches_gpg_identifier(const std::string& expected, const std::string& candidate);
std::vector<std::string> extract_exported_key_fingerprints(const std::filesystem::path& key_file);
void validate_expected_secret_key_material(const std::filesystem::path& mount_point, const std::string& expected_key_id);
std::string iso8601_utc_now();
std::string repo_name_from_repo_id(const std::string& repo_id);
std::string repo_owner_from_repo_id(const std::string& repo_id);
std::string github_repo_from_url(const std::string& repo_url);
bool answer_is_yes(const std::string& answer, bool default_yes = true);
bool is_gpg_cancelled_error(const std::string& message);
std::size_t container_size_mb_for(const std::filesystem::path& path);
std::string first_checksum_token(const std::filesystem::path& path);
std::string sha256_for_file(const std::filesystem::path& path);
std::string compute_local_install_fingerprint(const syncpss::util::RuntimeConfig& runtime_config);
void copy_live_gnupg_contents(const std::filesystem::path& source, const std::filesystem::path& destination);
void sanitize_live_gnupg_directory(const std::filesystem::path& gnupg_dir);
void tighten_gnupg_permissions(const std::filesystem::path& gnupg_dir);
void secure_remove_file(const std::filesystem::path& path);
std::string current_distro_name();
std::filesystem::path find_gnupg_backup_dir(const std::filesystem::path& mount_point);
std::filesystem::path gnupg_backups_directory();
void ensure_gnupg_backups_directory();
void prune_old_gnupg_backups(std::size_t max_backups = 20U);
void write_manifest_file(
    const std::filesystem::path& destination,
    const std::string& type,
    const std::vector<ManifestEntry>& exports
);
void copy_directory_tree_filtered(
    const std::filesystem::path& source,
    const std::filesystem::path& destination,
    const std::function<bool(const std::filesystem::path&)>& should_skip
);
void write_store_manifest_file(const std::filesystem::path& store_root);
std::string read_manifest_type(const std::filesystem::path& manifest_path);
std::filesystem::path find_container_manifest(const std::filesystem::path& mount_point);

}  // namespace syncpss::tui::detail
