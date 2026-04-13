#include "util/paths.hpp"

#include <cstdlib>
#include <grp.h>
#include <pwd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <stdexcept>
#include <string>
#include <vector>

namespace syncpss::util {
namespace {

std::filesystem::path passwd_home_for_user(const std::string& username) {
    passwd* pw = getpwnam(username.c_str());
    if (pw == nullptr || pw->pw_dir == nullptr) {
        throw std::runtime_error("Cannot resolve passwd entry for user: " + username);
    }
    return std::filesystem::path(pw->pw_dir);
}

std::filesystem::path legacy_runtime_directory() {
    return get_real_home() / ".syncpass";
}

void migrate_legacy_runtime_directory_if_needed(const std::filesystem::path& new_runtime_dir) {
    const std::filesystem::path old_runtime_dir = legacy_runtime_directory();
    if (std::filesystem::exists(new_runtime_dir) || !std::filesystem::exists(old_runtime_dir)) {
        return;
    }

    std::filesystem::create_directories(new_runtime_dir);
    const std::filesystem::path old_install_meta = old_runtime_dir / "install-meta";
    const std::filesystem::path new_install_meta = new_runtime_dir / "install-meta";
    if (std::filesystem::exists(old_install_meta) && !std::filesystem::exists(new_install_meta)) {
        std::filesystem::copy_file(old_install_meta, new_install_meta);
    }
}

}  // namespace

std::filesystem::path get_real_home() {
    const char* sudo_user = ::getenv("SUDO_USER");
    if (sudo_user != nullptr && std::string(sudo_user).size() > 0U) {
        return passwd_home_for_user(sudo_user);
    }

    passwd* pw = getpwuid(getuid());
    if (pw == nullptr || pw->pw_dir == nullptr) {
        throw std::runtime_error("Cannot determine real home directory");
    }
    return std::filesystem::path(pw->pw_dir);
}

std::string get_real_username() {
    const char* sudo_user = ::getenv("SUDO_USER");
    if (sudo_user != nullptr && std::string(sudo_user).size() > 0U) {
        return std::string(sudo_user);
    }

    passwd* pw = getpwuid(getuid());
    if (pw == nullptr || pw->pw_name == nullptr) {
        throw std::runtime_error("Cannot determine real username");
    }
    return std::string(pw->pw_name);
}

uid_t get_real_uid() {
    const std::string username = get_real_username();
    passwd* pw = getpwnam(username.c_str());
    if (pw == nullptr) {
        throw std::runtime_error("Cannot determine real uid for user: " + username);
    }
    return pw->pw_uid;
}

gid_t get_real_gid() {
    const std::string username = get_real_username();
    passwd* pw = getpwnam(username.c_str());
    if (pw == nullptr) {
        throw std::runtime_error("Cannot determine real gid for user: " + username);
    }
    return pw->pw_gid;
}

std::string get_real_groupname() {
    group* grp = getgrgid(get_real_gid());
    if (grp == nullptr || grp->gr_name == nullptr) {
        throw std::runtime_error("Cannot determine real group name");
    }
    return std::string(grp->gr_name);
}

std::filesystem::path get_real_xdg_runtime_dir() {
    return std::filesystem::path("/run/user") / std::to_string(get_real_uid());
}

std::filesystem::path expand_user_path(const std::string& raw_path) {
    if (raw_path == "~") {
        return get_real_home();
    }
    if (raw_path.rfind("~/", 0) == 0) {
        return get_real_home() / raw_path.substr(2);
    }
    return std::filesystem::path(raw_path);
}

std::filesystem::path runtime_directory() {
    const std::filesystem::path path = get_real_home() / ".syncpss";
    migrate_legacy_runtime_directory_if_needed(path);
    return path;
}

std::filesystem::path runtime_logs_directory() {
    return runtime_directory() / "logs";
}

std::filesystem::path runtime_notes_directory() {
    return runtime_directory() / "notes";
}

std::filesystem::path runtime_backups_directory() {
    return runtime_directory() / "backups";
}

std::filesystem::path runtime_install_assets_directory() {
    return runtime_directory() / "install-assets";
}

std::filesystem::path runtime_helpers_directory() {
    return runtime_directory() / "helpers";
}

std::filesystem::path runtime_helper_path(const std::string& helper_name) {
    return runtime_helpers_directory() / helper_name;
}

std::filesystem::path resolve_runtime_helper_path(const std::string& helper_name) {
    const std::filesystem::path preferred = runtime_install_assets_directory() / helper_name;
    if (std::filesystem::exists(preferred)) {
        return preferred;
    }

    const std::filesystem::path legacy = runtime_helper_path(helper_name);
    if (std::filesystem::exists(legacy)) {
        return legacy;
    }

    return preferred;
}

std::filesystem::path runtime_config_path() {
    return runtime_directory() / "config.json";
}

std::filesystem::path runtime_master_fingerprint_path() {
    return runtime_directory() / "config" / "master_fingerprint.sha256";
}

std::filesystem::path persistent_settings_directory() {
    return get_real_home() / ".config" / "syncpss";
}

std::filesystem::path persistent_preferences_path() {
    return persistent_settings_directory() / "preferences.env";
}

std::filesystem::path config_directory() {
    return std::filesystem::path("/etc/syncpass");
}

std::filesystem::path config_path() {
    return config_directory() / "config";
}

std::filesystem::path config_manifest_path() {
    return config_directory() / "manifest.xml";
}

std::filesystem::path default_store_path() {
    return get_real_home() / ".password-store";
}

std::filesystem::path default_install_root() {
    return runtime_directory();
}

std::filesystem::path create_secure_temp_directory(const std::string& prefix) {
    std::filesystem::path pattern = std::filesystem::temp_directory_path() / (prefix + "-XXXXXX");
    std::string mutable_pattern = pattern.string();
    std::vector<char> buffer(mutable_pattern.begin(), mutable_pattern.end());
    buffer.push_back('\0');

    char* created = ::mkdtemp(buffer.data());
    if (created == nullptr) {
        throw std::runtime_error("Failed to create secure temporary directory");
    }

    std::error_code ignored;
    std::filesystem::permissions(
        created,
        std::filesystem::perms::owner_all,
        std::filesystem::perm_options::replace,
        ignored
    );
    return std::filesystem::path(created);
}

std::filesystem::path create_secure_temp_file(const std::string& prefix, const std::string& suffix) {
    std::filesystem::path pattern =
        std::filesystem::temp_directory_path() / (prefix + "-XXXXXX" + suffix);
    std::string mutable_pattern = pattern.string();
    std::vector<char> buffer(mutable_pattern.begin(), mutable_pattern.end());
    buffer.push_back('\0');

    int fd = -1;
    if (suffix.empty()) {
        fd = ::mkstemp(buffer.data());
    } else {
        fd = ::mkstemps(buffer.data(), static_cast<int>(suffix.size()));
    }
    if (fd < 0) {
        throw std::runtime_error("Failed to create secure temporary file");
    }

    if (::fchmod(fd, S_IRUSR | S_IWUSR) != 0) {
        ::close(fd);
        throw std::runtime_error("Failed to set secure permissions on temporary file");
    }
    ::close(fd);
    return std::filesystem::path(buffer.data());
}

std::filesystem::path install_bin_directory() {
    return std::filesystem::path("/usr/local/bin");
}

std::filesystem::path binary_install_path(const std::string& binary_name) {
    return install_bin_directory() / binary_name;
}

std::filesystem::path normalize_path(const std::filesystem::path& path) {
    if (path.empty()) {
        return {};
    }

    std::error_code error;
    std::filesystem::path normalized =
        (path.is_absolute() ? path : std::filesystem::absolute(path, error)).lexically_normal();
    if (error) {
        normalized = std::filesystem::absolute(path).lexically_normal();
    }

    const bool exists = std::filesystem::exists(normalized, error);
    if (!error && exists) {
        const std::filesystem::path canonical = std::filesystem::weakly_canonical(normalized, error);
        if (!error) {
            return canonical.lexically_normal();
        }
    }

    std::filesystem::path parent = normalized.parent_path();
    if (parent.empty()) {
        parent = normalized.root_path();
    }
    const std::filesystem::path canonical_parent = std::filesystem::weakly_canonical(parent, error);
    if (!error) {
        return (canonical_parent / normalized.filename()).lexically_normal();
    }

    return normalized.lexically_normal();
}

bool path_has_control_chars(const std::filesystem::path& path) {
    const std::string rendered = path.string();
    for (const unsigned char ch : rendered) {
        if (ch < 32U || ch == 127U) {
            return true;
        }
    }
    return false;
}

bool path_is_root_like(const std::filesystem::path& path) {
    const std::filesystem::path normalized = normalize_path(path);
    if (normalized.empty()) {
        return true;
    }
    if (normalized == normalized.root_path()) {
        return true;
    }

    const std::string rendered = normalized.string();
    return rendered == "/home" || rendered == "/mnt" || rendered == "/tmp" || rendered == "/usr" ||
        rendered == "/etc" || rendered == "/var" || rendered == "/opt" || rendered == "/root" ||
        rendered == "/proc" || rendered == "/sys" || rendered == "/dev" || rendered == "/run" ||
        rendered == "/mnt/c" || rendered == "/mnt/d" || rendered == "/mnt/e" ||
        rendered == "/mnt/c/Users" || rendered == "/mnt/d/Users" || rendered == "/mnt/e/Users";
}

bool path_is_windows_mounted(const std::filesystem::path& path) {
    const std::string rendered = normalize_path(path).string();
    return rendered.size() > 7U && rendered.rfind("/mnt/", 0) == 0 && std::isalpha(rendered[5]) != 0 &&
        rendered[6] == '/';
}

bool path_is_within_root(const std::filesystem::path& candidate, const std::filesystem::path& root) {
    const std::filesystem::path normalized_candidate = normalize_path(candidate);
    const std::filesystem::path normalized_root = normalize_path(root);

    auto candidate_it = normalized_candidate.begin();
    auto root_it = normalized_root.begin();
    for (; root_it != normalized_root.end(); ++root_it, ++candidate_it) {
        if (candidate_it == normalized_candidate.end() || *candidate_it != *root_it) {
            return false;
        }
    }
    return true;
}

bool is_managed_user_path(const std::filesystem::path& path) {
    return path_is_within_root(path, runtime_directory()) ||
        path_is_within_root(path, persistent_settings_directory()) ||
        path_is_within_root(path, default_store_path()) ||
        path_is_within_root(path, get_real_home() / ".gnupg");
}

bool is_managed_system_path(const std::filesystem::path& path) {
    const std::filesystem::path normalized = normalize_path(path);
    return normalized == normalize_path("/usr/local/bin/syncpss") ||
        normalized == normalize_path("/usr/local/bin/syncpass") ||
        normalized == normalize_path("/etc/syncpass") ||
        normalized == normalize_path("/mnt/keys");
}

bool is_managed_temp_path(const std::filesystem::path& path) {
    return path_is_within_root(path, std::filesystem::temp_directory_path());
}

void require_managed_path(const std::filesystem::path& path, const std::string& action) {
    if (path.empty()) {
        throw std::runtime_error(action + " path is empty");
    }
    if (!path.is_absolute()) {
        throw std::runtime_error(action + " path must be absolute: " + path.string());
    }
    if (path_has_control_chars(path)) {
        throw std::runtime_error(action + " path contains control characters: " + path.string());
    }
    if (path_is_root_like(path)) {
        throw std::runtime_error(action + " path is too broad to trust: " + path.string());
    }
    if (path_is_windows_mounted(path)) {
        throw std::runtime_error(action + " path points into a Windows-mounted filesystem: " + path.string());
    }
    if (!is_managed_user_path(path) && !is_managed_system_path(path)) {
        throw std::runtime_error(action + " path is outside the managed syncpss boundary: " + path.string());
    }
}

void require_temporary_path(const std::filesystem::path& path, const std::string& action) {
    if (path.empty()) {
        throw std::runtime_error(action + " temporary path is empty");
    }
    if (!path.is_absolute()) {
        throw std::runtime_error(action + " temporary path must be absolute: " + path.string());
    }
    if (path_has_control_chars(path)) {
        throw std::runtime_error(action + " temporary path contains control characters: " + path.string());
    }
    if (path_is_root_like(path)) {
        throw std::runtime_error(action + " temporary path is too broad to trust: " + path.string());
    }
    if (!is_managed_temp_path(path)) {
        throw std::runtime_error(action + " temporary path is outside the allowed temp root: " + path.string());
    }
}

bool is_safe_recursive_delete_target(const std::filesystem::path& path) {
    const std::string rendered = path.lexically_normal().string();
    if (rendered.size() <= 10U) {
        return false;
    }
    return rendered.rfind("/home/", 0) == 0 || rendered.rfind("/Users/", 0) == 0;
}

bool is_root_user() {
    return getuid() == 0;
}

bool is_user_in_group(const std::string& group_name) {
    group* grp = getgrnam(group_name.c_str());
    if (grp == nullptr) {
        return false;
    }

    if (getgid() == grp->gr_gid || getegid() == grp->gr_gid) {
        return true;
    }

    int group_count = getgroups(0, nullptr);
    if (group_count < 0) {
        return false;
    }

    std::vector<gid_t> groups(static_cast<std::size_t>(group_count));
    group_count = getgroups(group_count, groups.data());
    if (group_count < 0) {
        return false;
    }

    for (const gid_t gid : groups) {
        if (gid == grp->gr_gid) {
            return true;
        }
    }
    return false;
}

}  // namespace syncpss::util
