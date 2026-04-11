#pragma once

#include <filesystem>
#include <string>

namespace syncpss::ssh {

struct SshKeyStatus {
    bool existing_key = false;
    std::filesystem::path private_key_path;
    std::filesystem::path public_key_path;
    std::string public_key;
    bool copied_to_clipboard = false;
};

class SshManager {
public:
    SshKeyStatus ensure_ed25519_key(const std::filesystem::path& private_key_path = {}) const;
    void verify_github_host_key() const;
    void ensure_known_hosts_entry() const;
    void clone_repo(
        const std::string& repo_url,
        const std::string& branch,
        const std::filesystem::path& destination,
        const std::filesystem::path& private_key_path = {}
    ) const;
};

}  // namespace syncpss::ssh
