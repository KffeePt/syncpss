#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace syncpss::crypto {

class GpgManager {
public:
    bool key_exists(const std::string& key_id) const;
    std::vector<std::string> secret_key_ids() const;
    void generate_key_interactive() const;
    void export_to_directory(const std::filesystem::path& destination) const;
    void merge_from_directory(const std::filesystem::path& source) const;
    void export_public_key_to_file(const std::string& key_id, const std::filesystem::path& destination) const;
    std::filesystem::path gnupg_directory() const;
};

}  // namespace syncpss::crypto
