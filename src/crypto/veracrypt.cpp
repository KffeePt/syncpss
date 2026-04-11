#include "crypto/veracrypt.hpp"

#include "util/process.hpp"

#include <filesystem>
#include <stdexcept>
#include <vector>

namespace syncpss::crypto {
namespace {

void require_ok(const syncpss::util::ProcessResult& result, const std::string& action) {
    if (result.exit_code != 0) {
        throw std::runtime_error(action + " failed: " + result.stderr_output + result.stdout_output);
    }
}

std::vector<std::string> base_mount_argv(
    const std::filesystem::path& volume_path,
    const std::filesystem::path& mount_point
) {
    return {
        "veracrypt",
        "--text",
        "--non-interactive",
        "--stdin",
        "--mount",
        volume_path.string(),
        mount_point.string(),
        "--pim",
        "0",
        "--keyfiles",
        "",
        "--protect-hidden",
        "no",
    };
}

}  // namespace

void VeraCryptManager::create_volume(
    const std::filesystem::path& volume_path,
    std::size_t size_mb,
    const std::string& password
) const {
    std::filesystem::create_directories(volume_path.parent_path());
    const std::string stdin_password = password + "\n";
    require_ok(
        syncpss::util::run(
            {
                "veracrypt",
                "--text",
                "--non-interactive",
                "--stdin",
                "--create",
                volume_path.string(),
                "--size",
                std::to_string(size_mb) + "M",
                "--volume-type",
                "normal",
                "--encryption",
                "AES",
                "--hash",
                "sha-512",
                "--filesystem",
                "FAT",
                "--pim",
                "0",
                "--keyfiles",
                "",
                "--random-source",
                "/dev/urandom",
            },
            syncpss::util::ProcessOptions{std::nullopt, std::nullopt, stdin_password}
        ),
        "veracrypt --create"
    );
}

void VeraCryptManager::mount(
    const std::filesystem::path& volume_path,
    const std::filesystem::path& mount_point,
    const std::string& password,
    bool read_only
) const {
    std::filesystem::create_directories(mount_point);
    std::vector<std::string> argv = base_mount_argv(volume_path, mount_point);
    if (read_only) {
        argv.push_back("--mount-options");
        argv.push_back("ro");
    }
    require_ok(
        syncpss::util::run(argv, syncpss::util::ProcessOptions{std::nullopt, std::nullopt, password + "\n"}),
        "veracrypt --mount"
    );
}

void VeraCryptManager::dismount(const std::filesystem::path& mount_point) const {
    require_ok(
        syncpss::util::run({"veracrypt", "--text", "--dismount", mount_point.string()}),
        "veracrypt --dismount"
    );
}

}  // namespace syncpss::crypto
