#include "tui/detail/common.hpp"

namespace syncpss::tui::detail {
namespace {

std::uintmax_t directory_size_bytes(const std::filesystem::path& path) {
    if (!std::filesystem::exists(path)) {
        return 0;
    }

    std::uintmax_t total = 0;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(path)) {
        if (entry.is_regular_file()) {
            total += entry.file_size();
        }
    }
    return total;
}

std::string xml_escape(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (const char ch : value) {
        switch (ch) {
            case '&':
                escaped += "&amp;";
                break;
            case '<':
                escaped += "&lt;";
                break;
            case '>':
                escaped += "&gt;";
                break;
            case '"':
                escaped += "&quot;";
                break;
            case '\'':
                escaped += "&apos;";
                break;
            default:
                escaped.push_back(ch);
                break;
        }
    }
    return escaped;
}

}  // namespace

std::size_t container_size_mb_for(const std::filesystem::path& path) {
    constexpr std::uintmax_t kMegabyte = 1024U * 1024U;
    const std::uintmax_t bytes = directory_size_bytes(path);
    std::uintmax_t megabytes = (bytes + kMegabyte - 1U) / kMegabyte;
    if (megabytes < 20U) {
        megabytes = 20U;
    }
    if (megabytes % 5U != 0U) {
        megabytes += 5U - (megabytes % 5U);
    }
    return static_cast<std::size_t>(megabytes);
}

void write_manifest_file(
    const std::filesystem::path& destination,
    const std::string& type,
    const std::vector<ManifestEntry>& exports
) {
    std::ofstream output(destination / "manifest.xml", std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Cannot write manifest.xml");
    }

    output << "<syncpss>\n";
    output << "  <type>" << xml_escape(type) << "</type>\n";
    output << "  <exports>\n";
    for (const ManifestEntry& item : exports) {
        output << "    <file>\n";
        output << "      <path>" << xml_escape(item.path) << "</path>\n";
        output << "      <description>" << xml_escape(item.description) << "</description>\n";
        output << "    </file>\n";
    }
    output << "  </exports>\n";
    output << "</syncpss>\n";
}

void copy_directory_tree_filtered(
    const std::filesystem::path& source,
    const std::filesystem::path& destination,
    const std::function<bool(const std::filesystem::path&)>& should_skip
) {
    const std::function<void(const std::filesystem::path&, const std::filesystem::path&)> recurse =
        [&](const std::filesystem::path& current_source, const std::filesystem::path& current_destination) {
            std::filesystem::create_directories(current_destination);
            for (const auto& entry : std::filesystem::directory_iterator(current_source)) {
                const std::filesystem::path relative = std::filesystem::relative(entry.path(), source);
                if (should_skip(relative)) {
                    continue;
                }

                const std::filesystem::path target = current_destination / entry.path().filename();
                if (entry.is_directory()) {
                    recurse(entry.path(), target);
                } else if (entry.is_regular_file()) {
                    std::filesystem::create_directories(target.parent_path());
                    std::filesystem::copy_file(
                        entry.path(),
                        target,
                        std::filesystem::copy_options::overwrite_existing
                    );
                }
            }
        };

    recurse(source, destination);
}

void write_store_manifest_file(const std::filesystem::path& store_root) {
    write_manifest_file(
        store_root,
        "backup",
        {
            {"manifest.xml", "Store-level manifest that describes this password-store backup layout."},
            {".git/", "Git repository metadata for the password store, including commit history and refs."},
            {".gpg-id", "The pass recipient key id used to encrypt entries in this store."},
            {"keys", "Encrypted VeraCrypt container that carries only the .gnupg keyring backup."},
            {"backup", "Encrypted VeraCrypt backup container with store export data and a full snapshot."},
            {"*.gpg", "Encrypted password entries managed by the pass CLI inside this store."}
        }
    );
}

std::string read_manifest_type(const std::filesystem::path& manifest_path) {
    std::ifstream input(manifest_path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("Cannot read manifest: " + manifest_path.string());
    }

    const std::string content((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    const std::string open = "<type>";
    const std::string close = "</type>";
    const std::size_t start = content.find(open);
    const std::size_t end = content.find(close);
    if (start == std::string::npos || end == std::string::npos || end <= start + open.size()) {
        throw std::runtime_error("manifest.xml is missing a valid <type> field");
    }
    return content.substr(start + open.size(), end - (start + open.size()));
}

std::filesystem::path find_container_manifest(const std::filesystem::path& mount_point) {
    const std::array<std::filesystem::path, 2> candidates = {
        mount_point / "manifest.xml",
        mount_point / "pub.xml"
    };
    for (const auto& candidate : candidates) {
        if (std::filesystem::exists(candidate)) {
            return candidate;
        }
    }
    return {};
}

}  // namespace syncpss::tui::detail
