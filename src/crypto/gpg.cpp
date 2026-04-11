#include "crypto/gpg.hpp"

#include "util/paths.hpp"
#include "util/process.hpp"

#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <stdexcept>

namespace syncpss::crypto {
namespace {

void require_ok(const syncpss::util::ProcessResult& result, const std::string& action) {
    if (result.exit_code != 0) {
        throw std::runtime_error(action + " failed: " + result.stderr_output + result.stdout_output);
    }
}

void set_owner_only_permissions(const std::filesystem::path& path) {
    std::error_code ignored;
    const auto perms = std::filesystem::is_directory(path)
        ? std::filesystem::perms::owner_all
        : (std::filesystem::perms::owner_read | std::filesystem::perms::owner_write);
    std::filesystem::permissions(path, perms, std::filesystem::perm_options::replace, ignored);
}

void write_text_file(const std::filesystem::path& path, const std::string& content) {
    std::ofstream output(path, std::ios::trunc | std::ios::binary);
    if (!output) {
        throw std::runtime_error("Cannot write file: " + path.string());
    }
    output << content;
    output.flush();
    if (!output.good()) {
        throw std::runtime_error("Cannot flush file: " + path.string());
    }
    set_owner_only_permissions(path);
}

void tighten_owner_only_tree(const std::filesystem::path& path) {
    if (!std::filesystem::exists(path)) {
        return;
    }
    set_owner_only_permissions(path);
    for (const auto& entry : std::filesystem::recursive_directory_iterator(path)) {
        set_owner_only_permissions(entry.path());
    }
}

}  // namespace

bool GpgManager::key_exists(const std::string& key_id) const {
    if (key_id.empty()) {
        return false;
    }

    syncpss::util::ProcessResult result = syncpss::util::run(
        {"gpg", "--list-secret-keys", "--with-colons", key_id}
    );
    return result.exit_code == 0 && result.stdout_output.find("sec:") != std::string::npos;
}

std::vector<std::string> GpgManager::secret_key_ids() const {
    syncpss::util::ProcessResult result = syncpss::util::run(
        {"gpg", "--list-secret-keys", "--keyid-format", "LONG", "--with-colons"}
    );
    if (result.exit_code != 0) {
        throw std::runtime_error("gpg --list-secret-keys failed: " + result.stderr_output);
    }

    std::vector<std::string> keys;
    std::stringstream lines(result.stdout_output);
    std::string line;
    while (std::getline(lines, line)) {
        if (line.rfind("sec:", 0) != 0) {
            continue;
        }

        std::stringstream fields(line);
        std::string field;
        int index = 0;
        while (std::getline(fields, field, ':')) {
            if (index == 4 && !field.empty()) {
                keys.push_back(field);
                break;
            }
            ++index;
        }
    }
    return keys;
}

void GpgManager::generate_key_interactive() const {
    const int exit_code = syncpss::util::run_passthrough({"gpg", "--full-generate-key"});
    if (exit_code != 0) {
        throw std::runtime_error("gpg --full-generate-key failed");
    }
}

std::filesystem::path GpgManager::gnupg_directory() const {
    return syncpss::util::get_real_home() / ".gnupg";
}

void GpgManager::export_to_directory(const std::filesystem::path& destination) const {
    std::filesystem::create_directories(destination);
    set_owner_only_permissions(destination);

    const syncpss::util::ProcessResult pubkeys = syncpss::util::run({"gpg", "--armor", "--export"});
    require_ok(pubkeys, "gpg --export");
    write_text_file(destination / "pubkeys.asc", pubkeys.stdout_output);

    const syncpss::util::ProcessResult seckeys = syncpss::util::run({"gpg", "--armor", "--export-secret-keys"});
    require_ok(seckeys, "gpg --export-secret-keys");
    write_text_file(destination / "seckeys.asc", seckeys.stdout_output);

    const syncpss::util::ProcessResult ownertrust = syncpss::util::run({"gpg", "--export-ownertrust"});
    require_ok(ownertrust, "gpg --export-ownertrust");
    write_text_file(destination / "ownertrust.txt", ownertrust.stdout_output);

    const std::filesystem::path raw_dir = destination / ".gnupg";
    std::filesystem::create_directories(raw_dir);
    set_owner_only_permissions(raw_dir);
    if (std::filesystem::exists(gnupg_directory())) {
        for (const auto& entry : std::filesystem::directory_iterator(gnupg_directory())) {
            std::filesystem::copy(
                entry.path(),
                raw_dir / entry.path().filename(),
                std::filesystem::copy_options::recursive | std::filesystem::copy_options::overwrite_existing
            );
        }
    }
    tighten_owner_only_tree(raw_dir);
}

void GpgManager::merge_from_directory(const std::filesystem::path& source) const {
    if (!std::filesystem::exists(source)) {
        throw std::runtime_error("GPG import directory not found: " + source.string());
    }

    const std::filesystem::path pubkeys = source / "pubkeys.asc";
    if (std::filesystem::exists(pubkeys)) {
        require_ok(syncpss::util::run({"gpg", "--import", pubkeys.string()}), "gpg --import pubkeys");
    }

    const std::filesystem::path seckeys = source / "seckeys.asc";
    if (std::filesystem::exists(seckeys)) {
        require_ok(syncpss::util::run({"gpg", "--import", seckeys.string()}), "gpg --import secret keys");
    }

    const std::filesystem::path ownertrust = source / "ownertrust.txt";
    if (std::filesystem::exists(ownertrust)) {
        const syncpss::util::ProcessResult result = syncpss::util::run(
            {"gpg", "--import-ownertrust"},
            syncpss::util::ProcessOptions{std::nullopt, std::nullopt, [&ownertrust]() {
                std::ifstream input(ownertrust, std::ios::binary);
                if (!input) {
                    throw std::runtime_error("Cannot read ownertrust file: " + ownertrust.string());
                }
                return std::string((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
            }()}
        );
        require_ok(result, "gpg --import-ownertrust");
    }

    require_ok(syncpss::util::run({"gpg", "--check-trustdb"}), "gpg --check-trustdb");
}

void GpgManager::export_public_key_to_file(const std::string& key_id, const std::filesystem::path& destination) const {
    const syncpss::util::ProcessResult result = syncpss::util::run({"gpg", "--armor", "--export", key_id});
    require_ok(result, "gpg --export public key");
    write_text_file(destination, result.stdout_output);
}

}  // namespace syncpss::crypto
