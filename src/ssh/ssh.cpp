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
    if (!requested.empty()) {
        return requested;
    }
    return ssh_dir() / "syncpss_ed25519";
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
    std::error_code ignored;
    const auto perms = std::filesystem::is_directory(path)
        ? std::filesystem::perms::owner_all
        : (std::filesystem::perms::owner_read | std::filesystem::perms::owner_write);
    std::filesystem::permissions(path, perms, std::filesystem::perm_options::replace, ignored);
}

}  // namespace

SshKeyStatus SshManager::ensure_ed25519_key(const std::filesystem::path& requested_private_key_path) const {
    std::filesystem::create_directories(ssh_dir());
    set_owner_only_permissions(ssh_dir());

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
    const std::string scan_output = github_scan();
    const std::filesystem::path temp_path = syncpss::util::create_secure_temp_file("syncpss-github-hostkey", ".tmp");

    {
        std::ofstream output(temp_path, std::ios::trunc);
        output << scan_output;
    }

    syncpss::util::ProcessResult fingerprint = syncpss::util::run(
        {"ssh-keygen", "-lf", temp_path.string(), "-E", "sha256"}
    );
    std::filesystem::remove(temp_path);

    if (fingerprint.exit_code != 0) {
        throw std::runtime_error("ssh-keygen fingerprint verification failed: " + fingerprint.stderr_output);
    }
    if (fingerprint.stdout_output.find(kGitHubEd25519Fingerprint) == std::string::npos) {
        throw std::runtime_error("GitHub host key fingerprint mismatch. Aborting clone.");
    }
}

void SshManager::ensure_known_hosts_entry() const {
    const std::string scan_output = github_scan();
    verify_github_host_key();

    const std::filesystem::path known_hosts = ssh_dir() / "known_hosts";
    std::filesystem::create_directories(ssh_dir());
    set_owner_only_permissions(ssh_dir());
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
