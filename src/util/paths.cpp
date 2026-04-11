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
