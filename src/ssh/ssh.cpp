#include "ssh/ssh.hpp"

#include "ssh/known_hosts.hpp"
#include "util/clipboard.hpp"
#include "util/paths.hpp"
#include "util/process.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace syncpss::ssh {
namespace {

std::filesystem::path ssh_dir() {
    return syncpss::util::get_real_home() / ".ssh";
}

std::filesystem::path managed_private_key_path(const std::filesystem::path& requested) {
    const std::filesystem::path key_path = requested.empty()
        ? ssh_dir() / "syncpss_ed25519"
        : requested;
    const std::filesystem::path normalized_key_path = syncpss::util::normalize_path(key_path);
    const std::filesystem::path normalized_ssh_dir = syncpss::util::normalize_path(ssh_dir());
    if (normalized_key_path == normalized_ssh_dir ||
        !syncpss::util::path_is_within_root(normalized_key_path, normalized_ssh_dir)) {
        throw std::runtime_error("SSH key path must remain inside ~/.ssh");
    }
    if (normalized_key_path.filename().empty() || normalized_key_path.filename() == "." ||
        normalized_key_path.filename() == "..") {
        throw std::runtime_error("SSH key path must name a file inside ~/.ssh");
    }
    if (std::filesystem::exists(normalized_key_path) &&
        (std::filesystem::is_directory(normalized_key_path) || std::filesystem::is_symlink(normalized_key_path))) {
        throw std::runtime_error("SSH key path must not be a directory or symlink");
    }
    return normalized_key_path;
}

std::string read_file(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("Cannot read file: " + path.string());
    }
    return std::string((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
}

std::string host_comment() {
    char hostname[256]{};
    if (gethostname(hostname, sizeof(hostname)) != 0) {
        std::snprintf(hostname, sizeof(hostname), "unknown-host");
    }
    return syncpss::util::get_real_username() + "@" + hostname;
}

std::string github_scan() {
    syncpss::util::ProcessResult scan = syncpss::util::run({"ssh-keyscan", "-t", "ed25519", "github.com"});
    if (scan.exit_code != 0 || scan.stdout_output.empty()) {
        throw std::runtime_error("Unable to retrieve GitHub host key: " + scan.stderr_output);
    }
    return scan.stdout_output;
}

std::string shell_single_quote(const std::string& value) {
    std::string quoted = "'";
    for (const char ch : value) {
        if (ch == '\'') {
            quoted += "'\\''";
        } else {
            quoted.push_back(ch);
        }
    }
    quoted.push_back('\'');
    return quoted;
}

void set_owner_only_permissions(const std::filesystem::path& path) {
    syncpss::util::require_owner_only_permissions(path);
}

void ensure_ssh_directory() {
    const std::filesystem::path directory = ssh_dir();
    if (std::filesystem::exists(directory) && std::filesystem::is_symlink(directory)) {
        throw std::runtime_error("Refusing to use a symlink as ~/.ssh");
    }
    std::filesystem::create_directories(directory);
    set_owner_only_permissions(directory);
}

void verify_github_host_key_scan(const std::string& scan_output) {
    const std::filesystem::path temp_path =
        syncpss::util::create_secure_temp_file("syncpss-github-hostkey", ".tmp");
    try {
        {
            std::ofstream output(temp_path, std::ios::trunc);
            if (!output) {
                throw std::runtime_error("Cannot write temporary GitHub host key scan");
            }
            output << scan_output;
            output.flush();
            if (!output.good()) {
                throw std::runtime_error("Cannot flush temporary GitHub host key scan");
            }
        }

        const syncpss::util::ProcessResult fingerprint = syncpss::util::run({
            "ssh-keygen", "-lf", temp_path.string(), "-E", "sha256"
        });
        if (fingerprint.exit_code != 0) {
            throw std::runtime_error("ssh-keygen fingerprint verification failed: " + fingerprint.stderr_output);
        }
        if (fingerprint.stdout_output.find(kGitHubEd25519Fingerprint) == std::string::npos) {
            throw std::runtime_error("GitHub host key fingerprint mismatch. Aborting clone.");
        }
    } catch (...) {
        std::error_code ignored;
        std::filesystem::remove(temp_path, ignored);
        throw;
    }
    std::error_code ignored;
    std::filesystem::remove(temp_path, ignored);
}

}  // namespace

SshKeyStatus SshManager::ensure_ed25519_key(const std::filesystem::path& requested_private_key_path) const {
    ensure_ssh_directory();

    const std::filesystem::path private_key = managed_private_key_path(requested_private_key_path);
    const std::filesystem::path managed_public_key = private_key.string() + ".pub";

    SshKeyStatus status;
    status.private_key_path = private_key;
    status.public_key_path = managed_public_key;

    if (std::filesystem::exists(private_key) && std::filesystem::exists(managed_public_key)) {
        status.existing_key = true;
    } else {
        syncpss::util::ProcessResult result = syncpss::util::run({
            "ssh-keygen",
            "-t",
            "ed25519",
            "-a",
            "64",
            "-N",
            "",
            "-f",
            private_key.string(),
            "-C",
            host_comment(),
        });
        if (result.exit_code != 0) {
            throw std::runtime_error("ssh-keygen failed: " + result.stderr_output);
        }
    }

    status.public_key = read_file(managed_public_key);
    try {
        syncpss::util::copy_to_clipboard(status.public_key);
        status.copied_to_clipboard = true;
    } catch (...) {
        status.copied_to_clipboard = false;
    }
    return status;
}

void SshManager::verify_github_host_key() const {
    verify_github_host_key_scan(github_scan());
}

void SshManager::ensure_known_hosts_entry() const {
    const std::string scan_output = github_scan();
    verify_github_host_key_scan(scan_output);

    const std::filesystem::path known_hosts = ssh_dir() / "known_hosts";
    ensure_ssh_directory();
    if (std::filesystem::exists(known_hosts) && std::filesystem::is_symlink(known_hosts)) {
        throw std::runtime_error("Refusing to replace a symlink at ~/.ssh/known_hosts");
    }
    std::string existing;
    if (std::filesystem::exists(known_hosts)) {
        existing = read_file(known_hosts);
    }

    std::ofstream output(known_hosts, std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Cannot write known_hosts: " + known_hosts.string());
    }
    if (!existing.empty()) {
        std::istringstream input(existing);
        std::string line;
        while (std::getline(input, line)) {
            if (line.rfind("github.com ssh-ed25519 ", 0) == 0) {
                continue;
            }
            output << line << '\n';
        }
    }
    output << scan_output;
    output.flush();
    if (!output.good()) {
        throw std::runtime_error("Cannot flush known_hosts: " + known_hosts.string());
    }
    set_owner_only_permissions(known_hosts);
}

void SshManager::clone_repo(
    const std::string& repo_url,
    const std::string& branch,
    const std::filesystem::path& destination,
    const std::filesystem::path& requested_private_key_path
) const {
    if (std::filesystem::exists(destination) && !std::filesystem::is_empty(destination)) {
        throw std::runtime_error("Destination already exists and is not empty: " + destination.string());
    }
    if (std::filesystem::exists(destination) && std::filesystem::is_empty(destination)) {
        std::filesystem::remove(destination);
    }

    const std::filesystem::path private_key = managed_private_key_path(requested_private_key_path);
    const std::string ssh_command =
        "ssh -i " + shell_single_quote(private_key.string()) + " -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes";

    syncpss::util::ProcessResult result = syncpss::util::run(
        {"git", "clone", "--branch", branch, repo_url, destination.string()},
        syncpss::util::ProcessOptions{
            std::nullopt,
            std::map<std::string, std::string>{{"GIT_SSH_COMMAND", ssh_command}}
        }
    );
    if (result.exit_code != 0) {
        throw std::runtime_error(
            "git clone failed. Add your SSH key to GitHub, then try again. " +
            result.stderr_output + result.stdout_output
        );
    }

    syncpss::util::ProcessResult configure_result = syncpss::util::run(
        {"git", "-C", destination.string(), "config", "core.sshCommand", ssh_command}
    );
    if (configure_result.exit_code != 0) {
        throw std::runtime_error(
            "git config core.sshCommand failed: " + configure_result.stderr_output + configure_result.stdout_output
        );
    }
}

}  // namespace syncpss::ssh
