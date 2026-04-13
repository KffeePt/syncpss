#include "tui/detail/common.hpp"

namespace syncpss::tui::detail {

std::string normalize_hex_id(const std::string& value) {
    std::string normalized;
    normalized.reserve(value.size());
    for (const unsigned char ch : value) {
        if (std::isxdigit(ch)) {
            normalized.push_back(static_cast<char>(std::toupper(ch)));
        }
    }
    return normalized;
}

bool matches_gpg_identifier(const std::string& expected, const std::string& candidate) {
    const std::string normalized_expected = normalize_hex_id(expected);
    const std::string normalized_candidate = normalize_hex_id(candidate);
    if (normalized_expected.empty() || normalized_candidate.empty()) {
        return false;
    }
    if (normalized_expected == normalized_candidate) {
        return true;
    }
    return normalized_candidate.size() > normalized_expected.size() &&
           normalized_candidate.compare(
               normalized_candidate.size() - normalized_expected.size(),
               normalized_expected.size(),
               normalized_expected
           ) == 0;
}

std::vector<std::string> extract_exported_key_fingerprints(const std::filesystem::path& key_file) {
    if (!std::filesystem::exists(key_file)) {
        return {};
    }

    const syncpss::util::ProcessResult result =
        syncpss::util::run({"gpg", "--show-keys", "--with-colons", key_file.string()});
    if (result.exit_code != 0) {
        throw std::runtime_error("Failed to inspect exported key material: " + result.stderr_output);
    }

    std::vector<std::string> fingerprints;
    std::stringstream stream(result.stdout_output);
    std::string line;
    while (std::getline(stream, line)) {
        if (line.rfind("fpr:", 0) != 0) {
            continue;
        }
        std::vector<std::string> fields;
        std::stringstream line_stream(line);
        std::string field;
        while (std::getline(line_stream, field, ':')) {
            fields.push_back(field);
        }
        if (fields.size() > 9 && !fields[9].empty()) {
            fingerprints.push_back(fields[9]);
        }
    }
    return fingerprints;
}

void validate_expected_secret_key_material(
    const std::filesystem::path& mount_point,
    const std::string& expected_key_id
) {
    if (expected_key_id.empty()) {
        return;
    }

    const std::filesystem::path secret_keys = mount_point / "seckeys.asc";
    if (!std::filesystem::exists(secret_keys)) {
        return;
    }

    const std::vector<std::string> fingerprints = extract_exported_key_fingerprints(secret_keys);
    if (fingerprints.empty()) {
        throw std::runtime_error("The keys container did not expose any secret key fingerprints to validate.");
    }

    bool matched_expected = false;
    for (const std::string& fingerprint : fingerprints) {
        if (matches_gpg_identifier(expected_key_id, fingerprint)) {
            matched_expected = true;
            continue;
        }
        throw std::runtime_error(
            "The keys container contains unexpected secret key material (" + fingerprint +
            ") that does not match the configured GPG key."
        );
    }

    if (!matched_expected) {
        throw std::runtime_error("The keys container does not contain the configured GPG key: " + expected_key_id);
    }
}

std::string first_checksum_token(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("Cannot read fingerprint file: " + path.string());
    }
    std::string token;
    input >> token;
    if (token.empty()) {
        throw std::runtime_error("Fingerprint file is empty: " + path.string());
    }
    return token;
}

std::string sha256_for_file(const std::filesystem::path& path) {
    if (!std::filesystem::exists(path)) {
        throw std::runtime_error("Fingerprint input file is missing: " + path.string());
    }

    syncpss::util::ProcessResult result;
    if (syncpss::util::is_command_available("sha256sum")) {
        result = syncpss::util::run({"sha256sum", path.string()});
    } else if (syncpss::util::is_command_available("shasum")) {
        result = syncpss::util::run({"shasum", "-a", "256", path.string()});
    } else {
        throw std::runtime_error("Need sha256sum or shasum to verify the installed fingerprint");
    }

    if (result.exit_code != 0) {
        throw std::runtime_error("Checksum command failed for " + path.string());
    }

    const std::size_t split = result.stdout_output.find_first_of(" \t");
    if (split == std::string::npos) {
        throw std::runtime_error("Unexpected checksum output for " + path.string());
    }
    return result.stdout_output.substr(0, split);
}

std::string compute_local_install_fingerprint(const syncpss::util::RuntimeConfig& runtime_config) {
    const std::filesystem::path install_assets_dir = syncpss::util::runtime_install_assets_directory();
    const std::array<std::filesystem::path, 5> inputs = {
        runtime_config.install_binary,
        install_assets_dir / "install",
        install_assets_dir / "installer.sh",
        install_assets_dir / "managed_paths.sh",
        install_assets_dir / "uninstall_syncpss.sh"
    };

    const std::filesystem::path temp_payload =
        syncpss::util::runtime_directory() / (".fingerprint-payload-" + std::to_string(::getpid()));

    {
        std::ofstream output(temp_payload, std::ios::binary | std::ios::trunc);
        if (!output) {
            throw std::runtime_error("Cannot create temporary fingerprint payload");
        }

        for (const auto& input_path : inputs) {
            if (!std::filesystem::exists(input_path)) {
                throw std::runtime_error("Installed verification asset is missing: " + input_path.string());
            }

            std::ifstream input(input_path, std::ios::binary);
            if (!input) {
                throw std::runtime_error("Cannot read installed verification asset: " + input_path.string());
            }
            output << input.rdbuf();
        }
    }

    const std::string fingerprint = sha256_for_file(temp_payload);
    std::error_code ignored;
    std::filesystem::remove(temp_payload, ignored);
    return fingerprint;
}

}  // namespace syncpss::tui::detail
