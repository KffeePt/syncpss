#include "util/release_verification.hpp"

#include "util/paths.hpp"
#include "util/process.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace syncpss::util {
namespace {

constexpr const char* kReleaseSigningFingerprint =
    "89974211D53E5FFEB3FA74745A21FD7339CC230D";

constexpr const char* kReleaseSigningPublicKey = R"KEY(-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEadnR5xYJKwYBBAHaRw8BAQdAfrq0eZ24KOJBnNvpiq1BCUdSFXAtB/54chwY
C4/bsvS0D0tvZmZlZSBQb3QgTWFpboi1BBMWCgBdFiEEiZdCEdU+X/6z+nR0WiH9
cznMIw0FAmnZ0ecbFIAAAAAABAAObWFudTIsMi41KzEuMTIsMiwxAhsDBQkFpFS5
BQsJCAcCAiICBhUKCQgLAgQWAgMBAh4HAheAAAoJEFoh/XM5zCMNm6YBAOKgk1Gn
2bT5xNUMuAUGBV8ONiVA2kmgw4X9VClCOS63APwMG683OkVeO1kJkfF1C20Bi1mm
mjCQ1NMe5AmmjpoTBbg4BGnZ0ecSCisGAQQBl1UBBQEBB0B670QnggtMmfwAy+Le
i6JP8nQtfFg0QSlsUKxOBoEIQwMBCAeImgQYFgoAQhYhBImXQhHVPl/+s/p0dFoh
/XM5zCMNBQJp2dHnGxSAAAAAAAQADm1hbnUyLDIuNSsxLjEyLDIsMQIbDAUJBaRU
uQAKCRBaIf1zOcwjDbKZAP9vDYVWR9l99fSOGb/akwRqQ4meYawl4dtQRYxkbKco
CQD/TC0/8yGytWiFv6PmMfj58vS0RYjhrHCpq/GNpXhv2AM=
=VhQF
-----END PGP PUBLIC KEY BLOCK-----
)KEY";

std::string trim_ascii(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return {};
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1U);
}

void write_public_key(const std::filesystem::path& path) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Cannot create temporary release verification key");
    }
    output << kReleaseSigningPublicKey;
    output.flush();
    if (!output.good()) {
        throw std::runtime_error("Cannot write temporary release verification key");
    }
    std::error_code error;
    std::filesystem::permissions(
        path,
        std::filesystem::perms::owner_read | std::filesystem::perms::owner_write,
        std::filesystem::perm_options::replace,
        error
    );
    if (error) {
        throw std::runtime_error("Cannot secure temporary release verification key: " + error.message());
    }
}

std::string verified_fingerprint(const std::string& status_output) {
    std::istringstream input(status_output);
    std::string line;
    while (std::getline(input, line)) {
        std::istringstream fields(line);
        std::string marker;
        std::string event;
        std::string fingerprint;
        fields >> marker >> event >> fingerprint;
        if (marker == "[GNUPG:]" && event == "VALIDSIG") {
            std::transform(
                fingerprint.begin(),
                fingerprint.end(),
                fingerprint.begin(),
                [](const unsigned char character) { return static_cast<char>(std::toupper(character)); }
            );
            return fingerprint;
        }
    }
    return {};
}

}  // namespace

void verify_detached_release_signature(
    const std::filesystem::path& asset_path,
    const std::filesystem::path& signature_path
) {
    if (!std::filesystem::is_regular_file(asset_path) || !std::filesystem::is_regular_file(signature_path)) {
        throw std::runtime_error("Release asset or detached signature is missing");
    }
    if (!is_command_available("gpg")) {
        throw std::runtime_error("gpg is required to verify signed release assets");
    }

    const std::filesystem::path verification_home = create_secure_temp_directory("syncpss-release-verify");
    try {
        const std::filesystem::path key_path = verification_home / "release-signing-key.asc";
        write_public_key(key_path);

        const ProcessResult import_result = run({
            "gpg", "--batch", "--no-options", "--no-auto-key-retrieve",
            "--homedir", verification_home.string(), "--import", key_path.string()
        });
        if (import_result.exit_code != 0) {
            throw std::runtime_error("Cannot load the embedded release verification key");
        }

        const ProcessResult verify_result = run({
            "gpg", "--batch", "--no-options", "--no-auto-key-retrieve",
            "--homedir", verification_home.string(), "--status-fd", "1",
            "--verify", signature_path.string(), asset_path.string()
        });
        if (verify_result.exit_code != 0) {
            throw std::runtime_error("Release signature verification failed");
        }

        if (verified_fingerprint(verify_result.stdout_output) != kReleaseSigningFingerprint) {
            throw std::runtime_error("Release signature was not made by the trusted syncpss release key");
        }
    } catch (...) {
        std::error_code ignored;
        std::filesystem::remove_all(verification_home, ignored);
        throw;
    }

    std::error_code ignored;
    std::filesystem::remove_all(verification_home, ignored);
}

}  // namespace syncpss::util
