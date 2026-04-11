// Linux-side installer entrypoint.
//
// This binary is downloaded and executed from inside Linux/WSL after the shell
// wizard has already handled package installation, GitHub auth, SSH key setup,
// and password-store bootstrap. Its job is intentionally narrower:
//   1. install the released syncpss TUI binary into /usr/local/bin
//   2. create the syncpass alias
//   3. install the release manifest into /etc/syncpass so runtime version
//      checks use the packaged metadata, not the source tree
//   4. write both the runtime JSON config and the legacy INI config
//
// Keeping this logic in a dedicated binary makes the privileged portion of the
// install flow easier to audit and keeps the shell script small.

#include "util/config.hpp"
#include "util/paths.hpp"
#include "util/process.hpp"
#include "util/runtime_config.hpp"

#include <filesystem>
#include <fstream>
#include <cstdlib>
#include <iostream>
#include <iterator>
#include <optional>
#include <regex>
#include <stdexcept>
#include <string>
#include <vector>
#include <pwd.h>
#include <sys/types.h>
#include <unistd.h>

namespace {

constexpr const char* kRepoOwner = "KffeePt";
constexpr const char* kRepoName = "syncpss";
constexpr const char* kSyncpssAsset = "syncpss-linux-x86_64";
constexpr const char* kSyncpssAssetSha = "syncpss-linux-x86_64.sha256";
constexpr const char* kManifestAsset = "manifest.xml";
constexpr const char* kManifestAssetSha = "manifest.xml.sha256";

struct InstallArgs {
    std::string github_user;
    std::string github_email;
    std::string github_repo;
    std::string gpg_key_id;
    std::filesystem::path store_path = syncpss::util::default_store_path();
    std::string branch = "main";
};

// Simple argv parser for the metadata collected earlier by installer.sh.
std::string require_value(int& index, int argc, char** argv) {
    if (index + 1 >= argc) {
        throw std::runtime_error(std::string("Missing value for argument: ") + argv[index]);
    }
    ++index;
    return argv[index];
}

InstallArgs parse_args(int argc, char** argv) {
    InstallArgs args;
    for (int i = 1; i < argc; ++i) {
        const std::string option = argv[i];
        if (option == "--github-user") {
            args.github_user = require_value(i, argc, argv);
        } else if (option == "--github-email") {
            args.github_email = require_value(i, argc, argv);
        } else if (option == "--github-repo") {
            args.github_repo = require_value(i, argc, argv);
        } else if (option == "--gpg-key-id") {
            args.gpg_key_id = require_value(i, argc, argv);
        } else if (option == "--store-path") {
            args.store_path = syncpss::util::expand_user_path(require_value(i, argc, argv));
        } else if (option == "--branch") {
            args.branch = require_value(i, argc, argv);
        } else if (option == "--help" || option == "-h") {
            std::cout << "Usage: install --github-repo <user/pass-store> --gpg-key-id <fingerprint> "
                         "[--github-user <user>] [--github-email <email>] [--store-path ~/.password-store] "
                         "[--branch main]\n";
            std::exit(0);
        } else {
            throw std::runtime_error("Unknown argument: " + option);
        }
    }

    if (args.github_repo.empty()) {
        throw std::runtime_error("--github-repo is required");
    }
    if (args.gpg_key_id.empty()) {
        throw std::runtime_error("--gpg-key-id is required");
    }
    if (args.branch.empty()) {
        args.branch = "main";
    }
    return args;
}

std::string trim(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1);
}

std::string repo_name_from_repo_id(const std::string& repo_id) {
    const std::size_t slash = repo_id.find('/');
    if (slash == std::string::npos || slash + 1U >= repo_id.size()) {
        return trim(repo_id).empty() ? "pass-store" : trim(repo_id);
    }
    return trim(repo_id.substr(slash + 1U));
}

void require_command(const std::string& executable) {
    if (!syncpss::util::is_command_available(executable)) {
        throw std::runtime_error("Required command not found in PATH: " + executable);
    }
}

void require_ok(
    const std::vector<std::string>& argv,
    const std::string& action,
    const syncpss::util::ProcessOptions& options = {}
) {
    const syncpss::util::ProcessResult result = syncpss::util::run(argv, options);
    if (result.exit_code != 0) {
        throw std::runtime_error(action + " failed: " + result.stderr_output + result.stdout_output);
    }
}

std::string release_url(const std::string& asset_name) {
    static const std::string release_tag = [] {
        if (const char* requested = std::getenv("SYNCPSS_RELEASE_TAG")) {
            const std::string trimmed = trim(requested);
            if (!trimmed.empty()) {
                return trimmed;
            }
        }

        const syncpss::util::ProcessResult result = syncpss::util::run({
            "curl",
            "-fsSL",
            "--retry",
            "3",
            "--retry-delay",
            "1",
            "-H",
            "Accept: application/vnd.github+json",
            "https://api.github.com/repos/" + std::string(kRepoOwner) + "/" + std::string(kRepoName) + "/releases/latest"
        });
        if (result.exit_code != 0) {
            throw std::runtime_error("Could not resolve the latest syncpss release");
        }

        static const std::regex tag_pattern("\"tag_name\"\\s*:\\s*\"([^\"]+)\"");
        std::smatch match;
        if (!std::regex_search(result.stdout_output, match, tag_pattern) || match.size() < 2) {
            throw std::runtime_error("GitHub did not return a release tag for syncpss");
        }

        const std::string tag = trim(match[1].str());
        if (tag.empty()) {
            throw std::runtime_error("GitHub returned an empty release tag for syncpss");
        }
        return tag;
    }();

    return "https://github.com/" + std::string(kRepoOwner) + "/" + std::string(kRepoName) +
        "/releases/download/" + release_tag + "/" + asset_name;
}

std::string read_first_token(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("Cannot read checksum file: " + path.string());
    }
    std::string token;
    input >> token;
    return trim(token);
}

std::string sha256_for_file(const std::filesystem::path& path) {
    syncpss::util::ProcessResult result;
    if (syncpss::util::is_command_available("sha256sum")) {
        result = syncpss::util::run({"sha256sum", path.string()});
    } else if (syncpss::util::is_command_available("shasum")) {
        result = syncpss::util::run({"shasum", "-a", "256", path.string()});
    } else {
        throw std::runtime_error("Need sha256sum or shasum to verify release assets");
    }

    if (result.exit_code != 0) {
        throw std::runtime_error("Checksum command failed for " + path.string());
    }

    const std::size_t split = result.stdout_output.find_first_of(" \t");
    if (split == std::string::npos) {
        throw std::runtime_error("Unexpected checksum output for " + path.string());
    }
    return trim(result.stdout_output.substr(0, split));
}

void verify_checksum(const std::filesystem::path& binary_path, const std::filesystem::path& checksum_path) {
    std::string expected = read_first_token(checksum_path);
    std::string actual = sha256_for_file(binary_path);
    if (expected != actual) {
        throw std::runtime_error("Checksum verification failed for " + binary_path.string());
    }
}

std::filesystem::path executable_dir(char** argv) {
    return std::filesystem::absolute(argv[0]).parent_path();
}

std::optional<std::string> read_manifest_version_from_file(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) {
        return std::nullopt;
    }

    const std::string content{
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>()
    };
    static const std::regex version_pattern(R"(<version>\s*([^<]+)\s*</version>)");
    std::smatch match;
    if (!std::regex_search(content, match, version_pattern) || match.size() < 2) {
        return std::nullopt;
    }

    const std::string version = trim(match[1].str());
    if (version.empty()) {
        return std::nullopt;
    }
    return version;
}

// The install binary prefers colocated release assets in bin/ so local testing
// can use freshly built artifacts, but it can fall back to GitHub Releases.
std::filesystem::path resolve_or_download_asset(
    const std::filesystem::path& temp_dir,
    const std::filesystem::path& local_dir,
    const std::string& asset_name,
    const std::string& checksum_name
) {
    const std::filesystem::path local_binary = local_dir / asset_name;
    const std::filesystem::path local_checksum = local_dir / checksum_name;
    if (std::filesystem::exists(local_binary) && std::filesystem::exists(local_checksum)) {
        verify_checksum(local_binary, local_checksum);
        return local_binary;
    }

    const std::filesystem::path downloaded_binary = temp_dir / asset_name;
    const std::filesystem::path downloaded_checksum = temp_dir / checksum_name;
    require_ok({"curl", "-fsSL", release_url(asset_name), "-o", downloaded_binary.string()}, "Download syncpss binary");
    require_ok({"curl", "-fsSL", release_url(checksum_name), "-o", downloaded_checksum.string()}, "Download syncpss checksum");
    verify_checksum(downloaded_binary, downloaded_checksum);
    return downloaded_binary;
}

std::string utc_now_iso8601() {
    const syncpss::util::ProcessResult result = syncpss::util::run({"date", "-u", "+%Y-%m-%dT%H:%M:%SZ"});
    if (result.exit_code != 0) {
        throw std::runtime_error("date command failed while generating install timestamp");
    }
    return trim(result.stdout_output);
}

void install_syncpss_binary(const std::filesystem::path& source_path) {
    if (!syncpss::util::is_root_user()) {
        throw std::runtime_error("Run the install binary with sudo so it can write /usr/local/bin and /etc/syncpass");
    }

    const std::filesystem::path target = syncpss::util::binary_install_path("syncpss");
    require_ok({"install", "-d", "-m", "755", syncpss::util::install_bin_directory().string()}, "Create /usr/local/bin");
    require_ok({"install", "-m", "755", source_path.string(), target.string()}, "Install syncpss binary");
    require_ok({"ln", "-sfn", target.string(), syncpss::util::binary_install_path("syncpass").string()}, "Create syncpass symlink");
}

void install_manifest(const std::filesystem::path& source_path) {
    if (!syncpss::util::is_root_user()) {
        throw std::runtime_error("Run the install binary with sudo so it can write /etc/syncpass");
    }

    const std::filesystem::path target = syncpss::util::config_manifest_path();
    require_ok({"install", "-d", "-m", "755", syncpss::util::config_directory().string()}, "Create /etc/syncpass");
    require_ok({"install", "-m", "644", source_path.string(), target.string()}, "Install syncpss manifest");
}

void chown_recursive_to_real_user(const std::filesystem::path& path) {
    if (!std::filesystem::exists(path)) {
        return;
    }

    const std::string username = syncpss::util::get_real_username();
    passwd* pw = ::getpwnam(username.c_str());
    if (pw == nullptr) {
        throw std::runtime_error("Cannot resolve passwd entry for real user: " + username);
    }

    std::error_code ignored;
    std::filesystem::permissions(
        path,
        std::filesystem::perms::owner_all,
        std::filesystem::perm_options::add,
        ignored
    );
    if (::chown(path.c_str(), pw->pw_uid, pw->pw_gid) != 0) {
        throw std::runtime_error("Failed to chown path to real user: " + path.string());
    }

    for (const auto& entry : std::filesystem::recursive_directory_iterator(path)) {
        std::filesystem::permissions(
            entry.path(),
            std::filesystem::perms::owner_all,
            std::filesystem::perm_options::add,
            ignored
        );
        if (::chown(entry.path().c_str(), pw->pw_uid, pw->pw_gid) != 0) {
            throw std::runtime_error("Failed to chown path to real user: " + entry.path().string());
        }
    }
}

// We keep both config formats in sync for compatibility with older code paths
// while the JSON runtime config remains the primary source of truth.
void save_all_config(const InstallArgs& args) {
    std::filesystem::create_directories(syncpss::util::runtime_directory());
    syncpss::util::RuntimeConfig runtime_config;
    runtime_config.github_username = args.github_user;
    runtime_config.github_email = args.github_email;
    runtime_config.github_repo = args.github_repo;
    runtime_config.github_repo_name = repo_name_from_repo_id(args.github_repo);
    runtime_config.gpg_key_id = args.gpg_key_id;
    runtime_config.gpg_keys_remote = std::filesystem::exists(args.store_path / "keys");
    runtime_config.metadata_logging_enabled = false;
    runtime_config.metadata_log_hostname = false;
    runtime_config.metadata_log_ip = false;
    runtime_config.metadata_log_mac = false;
    runtime_config.notes_mode = "encrypted";
    runtime_config.store_path = args.store_path;
    runtime_config.store_branch = args.branch;
    runtime_config.install_binary = syncpss::util::binary_install_path("syncpss");
    runtime_config.install_config_dir = syncpss::util::config_directory();
    const char* wsl_distro = std::getenv("WSL_DISTRO_NAME");
    runtime_config.install_distro = wsl_distro == nullptr ? "" : std::string(wsl_distro);
    runtime_config.install_installed_at = utc_now_iso8601();
    const std::optional<std::string> installed_manifest_version =
        read_manifest_version_from_file(syncpss::util::config_manifest_path());
    runtime_config.install_version = installed_manifest_version.value_or(SYNCPSS_VERSION);
    if (args.github_user.empty()) {
        const std::size_t slash = args.github_repo.find('/');
        if (slash != std::string::npos) {
            runtime_config.github_username = args.github_repo.substr(0, slash);
        }
    }
    runtime_config.ssh_key_path = syncpss::util::get_real_home() / ".ssh" / "syncpss_ed25519";

    syncpss::util::save_runtime_config(runtime_config);
    chown_recursive_to_real_user(syncpss::util::runtime_directory());

    syncpss::util::AppConfig config = syncpss::util::to_app_config(runtime_config);
    syncpss::util::save_config(config);
}

}  // namespace

int main(int argc, char** argv) {
    try {
        require_command("curl");
        require_command("install");
        require_command("ln");
        const InstallArgs args = parse_args(argc, argv);

        const std::filesystem::path temp_dir = syncpss::util::create_secure_temp_directory("syncpss-install");
        struct TempDirCleanup {
            std::filesystem::path path;
            ~TempDirCleanup() {
                std::error_code ignored;
                std::filesystem::remove_all(path, ignored);
            }
        } cleanup{temp_dir};

        const std::filesystem::path asset_dir = executable_dir(argv);
        const std::filesystem::path syncpss_binary =
            resolve_or_download_asset(temp_dir, asset_dir, kSyncpssAsset, kSyncpssAssetSha);
        const std::filesystem::path manifest_xml =
            resolve_or_download_asset(temp_dir, asset_dir, kManifestAsset, kManifestAssetSha);

        install_syncpss_binary(syncpss_binary);
        install_manifest(manifest_xml);
        save_all_config(args);

        std::cout << "Installed syncpss to " << syncpss::util::binary_install_path("syncpss") << '\n';
        std::cout << "Installed syncpass symlink to " << syncpss::util::binary_install_path("syncpass") << '\n';
        std::cout << "Wrote runtime config to " << syncpss::util::runtime_config_path() << '\n';
        std::cout << "Wrote legacy config to " << syncpss::util::config_path() << '\n';
    std::cout << "You can run 'syncpss' or 'syncpass' now." << '\n';
        return 0;
    } catch (const std::exception& ex) {
        std::cerr << "install error: " << ex.what() << '\n';
        return 1;
    }
}
