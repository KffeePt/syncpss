
#include "tui/detail/browser.hpp"
#include "tui/detail/render.hpp"

#include <algorithm>
#include <array>
#include <filesystem>
#include <regex>
#include <sstream>

namespace syncpss::tui::detail {
std::string join_entry_name(const std::string& folder, const std::string& name) {
    if (folder.empty()) {
        return name;
    }
    return folder + "/" + name;
}

std::string trim_copy(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1U);
}

std::string pad_right(const std::string& value, int width) {
    if (width <= 0) {
        return "";
    }
    std::string trimmed = trim_for_render(value, width);
    if (static_cast<int>(trimmed.size()) < width) {
        trimmed.append(static_cast<std::size_t>(width - static_cast<int>(trimmed.size())), ' ');
    }
    return trimmed;
}

bool is_wrapped_token(const std::string& value) {
    return value.size() >= 2U && value.front() == '[' && value.back() == ']';
}

std::string unwrap_token(const std::string& value) {
    auto decode = [](std::string decoded) {
        const std::array<std::pair<std::string, std::string>, 3> replacements = {{
            {"%2F", "/"},
            {"%5C", "\\"},
            {"%25", "%"}
        }};
        for (const auto& [from, to] : replacements) {
            std::size_t pos = 0;
            while ((pos = decoded.find(from, pos)) != std::string::npos) {
                decoded.replace(pos, from.size(), to);
                pos += to.size();
            }
        }
        return decoded;
    };
    if (is_wrapped_token(value)) {
        return decode(value.substr(1, value.size() - 2U));
    }
    return decode(value);
}

bool is_simple_account_token(const std::string& value) {
    static const std::regex allowed(R"(^[A-Za-z0-9._-]+$)");
    return std::regex_match(value, allowed) && value.find('@') == std::string::npos;
}

bool is_simple_site_token(const std::string& value) {
    static const std::regex allowed(R"(^[A-Za-z0-9._-]+$)");
    return std::regex_match(value, allowed);
}

std::string normalize_folder_input(const std::string& folder) {
    std::string normalized = trim_copy(folder);
    while (!normalized.empty() && normalized.front() == '/') {
        normalized.erase(normalized.begin());
    }
    while (!normalized.empty() && normalized.back() == '/') {
        normalized.pop_back();
    }
    return normalized;
}

bool validate_folder_path(const std::string& folder) {
    const std::string normalized = normalize_folder_input(folder);
    if (normalized.empty()) {
        return true;
    }

    std::stringstream input(normalized);
    std::string segment;
    while (std::getline(input, segment, '/')) {
        if (segment.empty() || segment == "." || segment == "..") {
            return false;
        }
        for (const unsigned char raw_char : segment) {
            if (raw_char < 32U || raw_char == 127U || raw_char == static_cast<unsigned char>('/')) {
                return false;
            }
        }
    }
    return true;
}

std::string format_account_token(const std::string& value) {
    const std::string trimmed = trim_copy(value);
    if (trimmed.empty()) {
        return "";
    }
    if (is_wrapped_token(trimmed) || is_simple_account_token(trimmed)) {
        return trimmed;
    }
    return "[" + trimmed + "]";
}

std::string format_site_token(const std::string& value) {
    const std::string trimmed = trim_copy(value);
    if (trimmed.empty()) {
        return "";
    }
    if (is_wrapped_token(trimmed) || is_simple_site_token(trimmed)) {
        return trimmed;
    }
    return "[" + trimmed + "]";
}

std::size_t find_top_level_at(const std::string& leaf_name) {
    int bracket_depth = 0;
    std::size_t split = std::string::npos;
    for (std::size_t index = 0; index < leaf_name.size(); ++index) {
        const char current = leaf_name[index];
        if (current == '[') {
            ++bracket_depth;
        } else if (current == ']') {
            bracket_depth = std::max(0, bracket_depth - 1);
        } else if (current == '@' && bracket_depth == 0) {
            split = index;
        }
    }
    return split;
}

bool fuzzy_match(const std::string& needle, const std::string& haystack) {
    if (needle.empty()) {
        return true;
    }

    std::size_t cursor = 0;
    for (const char raw_char : haystack) {
        if (cursor >= needle.size()) {
            break;
        }
        const char a = static_cast<char>(std::tolower(static_cast<unsigned char>(needle[cursor])));
        const char b = static_cast<char>(std::tolower(static_cast<unsigned char>(raw_char)));
        if (a == b) {
            ++cursor;
        }
    }
    return cursor == needle.size();
}

EntryViewModel describe_entry(const std::string& full_name) {
    EntryViewModel model;
    model.full_name = full_name;

    const std::filesystem::path path(full_name);
    model.folder = path.has_parent_path() ? path.parent_path().generic_string() : "/";
    model.leaf = path.filename().generic_string();

    const std::size_t split = find_top_level_at(model.leaf);
    if (split == std::string::npos) {
        model.account = unwrap_token(model.leaf);
        model.site = "";
        return model;
    }

    model.account = unwrap_token(model.leaf.substr(0, split));
    model.site = unwrap_token(model.leaf.substr(split + 1U));
    return model;
}

bool matches_entry_filter(const std::string& filter, const EntryViewModel& model) {
    return fuzzy_match(filter, model.full_name) ||
           fuzzy_match(filter, model.folder) ||
           fuzzy_match(filter, model.account) ||
           fuzzy_match(filter, model.site);
}

std::string build_entry_name_from_parts(
    const std::string& folder,
    const std::string& account,
    const std::string& site
) {
    auto encode = [](std::string encoded) {
        const std::array<std::pair<std::string, std::string>, 3> replacements = {{
            {"%", "%25"},
            {"/", "%2F"},
            {"\\", "%5C"}
        }};
        for (const auto& [from, to] : replacements) {
            std::size_t pos = 0;
            while ((pos = encoded.find(from, pos)) != std::string::npos) {
                encoded.replace(pos, from.size(), to);
                pos += to.size();
            }
        }
        return encoded;
    };

    const std::string formatted_account = format_account_token(encode(account));
    const std::string formatted_site = format_site_token(encode(site));
    if (formatted_account.empty() || formatted_site.empty()) {
        return "";
    }
    return join_entry_name(normalize_folder_input(folder), formatted_account + "@" + formatted_site);
}

std::vector<std::string> collect_known_folders(const std::vector<std::string>& entries) {
    std::vector<std::string> folders;
    for (const std::string& entry : entries) {
        std::filesystem::path current;
        for (const auto& part : std::filesystem::path(entry).parent_path()) {
            current /= part;
            folders.push_back(current.generic_string());
        }
    }
    std::sort(folders.begin(), folders.end());
    folders.erase(std::unique(folders.begin(), folders.end()), folders.end());
    return folders;
}

std::vector<std::string> child_folders_of(
    const std::vector<std::string>& known_folders,
    const std::string& current_folder
) {
    std::vector<std::string> children;
    const std::string prefix = current_folder.empty() ? "" : current_folder + "/";
    for (const std::string& folder : known_folders) {
        if (!prefix.empty()) {
            if (folder.rfind(prefix, 0) != 0) {
                continue;
            }
        }

        const std::string remainder = prefix.empty() ? folder : folder.substr(prefix.size());
        if (remainder.empty()) {
            continue;
        }

        const std::size_t slash = remainder.find('/');
        children.push_back(slash == std::string::npos ? remainder : remainder.substr(0, slash));
    }

    std::sort(children.begin(), children.end());
    children.erase(std::unique(children.begin(), children.end()), children.end());
    return children;
}

std::vector<BrowserItem> build_browser_items(
    const std::vector<std::string>& entries,
    const std::string& current_folder
) {
    std::vector<BrowserItem> items;
    const std::vector<std::string> known_folders = collect_known_folders(entries);
    for (const std::string& child : child_folders_of(known_folders, current_folder)) {
        BrowserItem item;
        item.is_folder = true;
        item.label = child;
        item.path = current_folder.empty() ? child : current_folder + "/" + child;
        item.model.folder = current_folder.empty() ? "/" : current_folder;
        item.model.account = child;
        item.model.site = "<folder>";
        items.push_back(item);
    }

    for (const std::string& entry : entries) {
        const EntryViewModel model = describe_entry(entry);
        const std::string normalized_folder = model.folder == "/" ? "" : model.folder;
        if (normalized_folder != current_folder) {
            continue;
        }

        BrowserItem item;
        item.is_folder = false;
        item.path = entry;
        item.label = model.leaf;
        item.model = model;
        items.push_back(item);
    }

    std::sort(
        items.begin(),
        items.end(),
        [](const BrowserItem& left, const BrowserItem& right) {
            if (left.is_folder != right.is_folder) {
                return left.is_folder > right.is_folder;
            }
            return left.label < right.label;
        }
    );
    return items;
}


}  // namespace syncpss::tui::detail
