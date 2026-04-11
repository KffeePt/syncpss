#include "tui/detail/common.hpp"

namespace syncpss::tui::detail {
namespace {

bool should_skip_live_gnupg_entry(const std::filesystem::directory_entry& entry) {
    const std::string name = entry.path().filename().string();
    if (name == ".git" || name == "README.md" || name == "S.scdaemon") {
        return true;
    }
    if (name.rfind(".#lk", 0) == 0 || name.rfind("S.gpg-agent", 0) == 0) {
        return true;
    }
    if (name.size() >= 5U && name.substr(name.size() - 5U) == ".lock") {
        return true;
    }
    return entry.is_socket();
}

}  // namespace

void copy_live_gnupg_contents(const std::filesystem::path& source, const std::filesystem::path& destination) {
    std::filesystem::create_directories(destination);
    for (const auto& entry : std::filesystem::directory_iterator(source)) {
        if (should_skip_live_gnupg_entry(entry)) {
            continue;
        }
        const std::filesystem::path target = destination / entry.path().filename();
        std::filesystem::copy(
            entry.path(),
            target,
            std::filesystem::copy_options::recursive | std::filesystem::copy_options::overwrite_existing
        );
    }
}

void sanitize_live_gnupg_directory(const std::filesystem::path& gnupg_dir) {
    if (!std::filesystem::exists(gnupg_dir)) {
        return;
    }

    std::error_code ignored;
    std::filesystem::remove_all(gnupg_dir / ".git", ignored);
    std::filesystem::remove(gnupg_dir / "README.md", ignored);
    for (const auto& entry : std::filesystem::directory_iterator(gnupg_dir)) {
        const std::string name = entry.path().filename().string();
        if (name.rfind(".#lk", 0) == 0 ||
            name.rfind("S.gpg-agent", 0) == 0 ||
            name == "S.scdaemon" ||
            (name.size() >= 5U && name.substr(name.size() - 5U) == ".lock")) {
            std::filesystem::remove_all(entry.path(), ignored);
        }
    }
}

void tighten_gnupg_permissions(const std::filesystem::path& gnupg_dir) {
    if (syncpss::util::is_root_user()) {
        const syncpss::util::ProcessResult chown_result = syncpss::util::run(
            {
                "chown",
                "-R",
                syncpss::util::get_real_username() + ":" + syncpss::util::get_real_groupname(),
                gnupg_dir.string()
            }
        );
        if (chown_result.exit_code != 0) {
            throw std::runtime_error("Failed to chown ~/.gnupg to the real user: " + chown_result.stderr_output);
        }
    }

    std::error_code ignored;
    std::filesystem::permissions(
        gnupg_dir,
        std::filesystem::perms::owner_all,
        std::filesystem::perm_options::replace,
        ignored
    );

    for (const auto& entry : std::filesystem::recursive_directory_iterator(gnupg_dir)) {
        const auto perms = entry.is_directory()
            ? std::filesystem::perms::owner_all
            : (std::filesystem::perms::owner_read | std::filesystem::perms::owner_write);
        std::filesystem::permissions(entry.path(), perms, std::filesystem::perm_options::replace, ignored);
    }
}

void secure_remove_file(const std::filesystem::path& path) {
    if (!std::filesystem::exists(path)) {
        return;
    }
    if (syncpss::util::is_command_available("shred")) {
        const syncpss::util::ProcessResult result = syncpss::util::run({"shred", "-u", path.string()});
        if (result.exit_code == 0) {
            return;
        }
    }
    std::filesystem::remove(path);
}

std::string current_distro_name() {
    const char* distro = std::getenv("WSL_DISTRO_NAME");
    return distro == nullptr ? "" : std::string(distro);
}

std::filesystem::path find_gnupg_backup_dir(const std::filesystem::path& mount_point) {
    const std::array<std::filesystem::path, 2> candidates = {mount_point / ".gnupg", mount_point / "gnupg"};
    for (const auto& candidate : candidates) {
        if (std::filesystem::exists(candidate) && std::filesystem::is_directory(candidate)) {
            return candidate;
        }
    }
    return {};
}

std::filesystem::path gnupg_backups_directory() {
    return syncpss::util::runtime_directory() / "gnupg-backups";
}

void ensure_gnupg_backups_directory() {
    std::filesystem::create_directories(gnupg_backups_directory());
}

void prune_old_gnupg_backups(std::size_t max_backups) {
    ensure_gnupg_backups_directory();

    std::vector<std::filesystem::path> backups;
    for (const auto& entry : std::filesystem::directory_iterator(gnupg_backups_directory())) {
        backups.push_back(entry.path());
    }

    std::sort(backups.begin(), backups.end());
    while (backups.size() > max_backups) {
        std::error_code ignored;
        std::filesystem::remove_all(backups.front(), ignored);
        backups.erase(backups.begin());
    }
}

}  // namespace syncpss::tui::detail
