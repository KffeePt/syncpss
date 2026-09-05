#pragma once

#include <filesystem>

namespace syncpss::util {

void verify_detached_release_signature(
    const std::filesystem::path& asset_path,
    const std::filesystem::path& signature_path
);

}  // namespace syncpss::util
