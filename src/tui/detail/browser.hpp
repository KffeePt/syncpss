#pragma once

#include <string>
#include <vector>

namespace syncpss::tui::detail {

struct EntryViewModel {
    std::string full_name;
    std::string folder;
    std::string leaf;
    std::string account;
    std::string site;
};

struct BrowserItem {
    bool is_folder = false;
    std::string path;
    std::string label;
    EntryViewModel model;
};

std::string join_entry_name(const std::string& folder, const std::string& name);
std::string trim_copy(const std::string& value);
std::string pad_right(const std::string& value, int width);
std::string normalize_folder_input(const std::string& folder);
bool validate_folder_path(const std::string& folder);
EntryViewModel describe_entry(const std::string& full_name);
bool matches_entry_filter(const std::string& filter, const EntryViewModel& model);
std::string build_entry_name_from_parts(
    const std::string& folder,
    const std::string& account,
    const std::string& site
);
std::vector<std::string> collect_known_folders(const std::vector<std::string>& entries);
std::vector<std::string> child_folders_of(
    const std::vector<std::string>& known_folders,
    const std::string& current_folder
);
std::vector<BrowserItem> build_browser_items(
    const std::vector<std::string>& entries,
    const std::string& current_folder
);

}  // namespace syncpss::tui::detail
