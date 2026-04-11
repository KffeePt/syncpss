#pragma once

#include <filesystem>
#include <string>

namespace syncpss::crypto {

class VeraCryptManager {
public:
    void create_volume(const std::filesystem::path& volume_path, std::size_t size_mb, const std::string& password) const;
    void mount(
        const std::filesystem::path& volume_path,
        const std::filesystem::path& mount_point,
        const std::string& password,
        bool read_only = false
    ) const;
    void dismount(const std::filesystem::path& mount_point) const;
};

}  // namespace syncpss::crypto
