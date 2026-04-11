#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

std::string TuiApp::select_folder(const std::string& title, const std::string& initial) const {
    const std::vector<std::string> entries = store_->list_entries();
    std::string current_folder = normalize_folder_input(initial);
    int selected = 0;

    while (true) {
        const std::vector<std::string> children = child_folders_of(collect_known_folders(entries), current_folder);
        if (selected >= static_cast<int>(children.size())) {
            selected = std::max(0, static_cast<int>(children.size()) - 1);
        }

        erase();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "%s", title.c_str());
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        mvprintw(3, 2, "Current folder: %s", current_folder.empty() ? "/" : current_folder.c_str());
        apply_pair(kColorDim);
        mvprintw(4, 2, "[Enter] use current  [Right] enter folder  [Left] up  [n] new  [r] root  [Esc] cancel");
        clear_pair(kColorDim);

        if (children.empty()) {
            mvprintw(6, 2, "No child folders here.");
        } else {
            for (std::size_t index = 0; index < children.size(); ++index) {
                const int row = 6 + static_cast<int>(index);
                if (row >= LINES - 2) {
                    break;
                }
                const std::string label = "[DIR] " + children[index];
                render_menu_option(row, 2, label, static_cast<int>(index) == selected, COLS - 4, kColorAccount);
            }
        }
        present_screen();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 27) {
            return {};
        }
        if (ch == KEY_UP || ch == 'k') {
            if (!children.empty()) {
                selected = (selected - 1 + static_cast<int>(children.size())) % static_cast<int>(children.size());
            }
            continue;
        }
        if (ch == KEY_DOWN || ch == 'j') {
            if (!children.empty()) {
                selected = (selected + 1) % static_cast<int>(children.size());
            }
            continue;
        }
        if (ch == KEY_LEFT || ch == 'h') {
            if (!current_folder.empty()) {
                current_folder = std::filesystem::path(current_folder).parent_path().generic_string();
                if (current_folder == ".") {
                    current_folder.clear();
                }
                selected = 0;
            }
            continue;
        }
        if (ch == KEY_RIGHT || ch == 'l') {
            if (!children.empty()) {
                current_folder = current_folder.empty()
                    ? children[static_cast<std::size_t>(selected)]
                    : current_folder + "/" + children[static_cast<std::size_t>(selected)];
                selected = 0;
            }
            continue;
        }
        if (ch == 'r' || ch == 'R') {
            return {};
        }
        if (ch == 'n' || ch == 'N') {
            const std::string child = prompt_input(title, "New folder path (relative to current folder):");
            if (child.empty()) {
                continue;
            }
            const std::string candidate = current_folder.empty() ? child : current_folder + "/" + child;
            if (!validate_folder_path(candidate)) {
                show_message(
                    "Invalid Folder",
                    {"Folder names cannot contain empty segments, . or .., or control characters."},
                    kColorError
                );
                continue;
            }
            return normalize_folder_input(candidate);
        }
        if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            return normalize_folder_input(current_folder);
        }
    }
}

std::optional<std::string> TuiApp::select_entry(const std::string& title) const {
    const std::vector<std::string> entries = store_->list_entries();
    if (entries.empty()) {
        return std::nullopt;
    }

    std::string current_folder;
    int selected = 0;
    int scroll_offset = 0;

    while (true) {
        const std::vector<BrowserItem> items = build_browser_items(entries, current_folder);
        if (selected >= static_cast<int>(items.size())) {
            selected = std::max(0, static_cast<int>(items.size()) - 1);
        }
        const int visible_rows = std::max(1, std::min(10, LINES - 8));
        const int max_scroll = std::max(0, static_cast<int>(items.size()) - visible_rows);
        scroll_offset = std::clamp(scroll_offset, 0, max_scroll);
        if (selected < scroll_offset) {
            scroll_offset = selected;
        }
        if (selected >= scroll_offset + visible_rows) {
            scroll_offset = selected - visible_rows + 1;
        }

        erase();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "%s", title.c_str());
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        mvprintw(3, 2, "Folder: %s", current_folder.empty() ? "/" : current_folder.c_str());
        apply_pair(kColorDim);
        mvprintw(4, 2, "[Enter] open/select  [Right] enter folder  [Left] up  [Esc] cancel");
        clear_pair(kColorDim);

        if (items.empty()) {
            mvprintw(6, 2, "This folder is empty.");
        } else {
            const int end_index = std::min(static_cast<int>(items.size()), scroll_offset + visible_rows);
            for (int index = scroll_offset; index < end_index; ++index) {
                const int row = 6 + (index - scroll_offset);
                const BrowserItem& item = items[static_cast<std::size_t>(index)];
                const std::string label = item.is_folder ? "[DIR] " + item.label : item.path;
                if (index == selected) {
                    render_menu_option(row, 2, label, true, COLS - 4);
                } else if (item.is_folder) {
                    apply_pair(kColorAccount);
                    mvprintw(row, 2, "%s", trim_for_render(label, COLS - 4).c_str());
                    clear_pair(kColorAccount);
                } else {
                    mvprintw(row, 2, "%s", trim_for_render(label, COLS - 4).c_str());
                }
            }
        }
        present_screen();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 27) {
            return std::nullopt;
        }
        if (ch == KEY_UP || ch == 'k') {
            if (!items.empty()) {
                selected = (selected - 1 + static_cast<int>(items.size())) % static_cast<int>(items.size());
            }
            continue;
        }
        if (ch == KEY_DOWN || ch == 'j') {
            if (!items.empty()) {
                selected = (selected + 1) % static_cast<int>(items.size());
            }
            continue;
        }
        if (ch == KEY_LEFT || ch == 'h') {
            if (!current_folder.empty()) {
                current_folder = std::filesystem::path(current_folder).parent_path().generic_string();
                if (current_folder == ".") {
                    current_folder.clear();
                }
                selected = 0;
                scroll_offset = 0;
            }
            continue;
        }
        if (ch == KEY_RIGHT || ch == 'l') {
            if (!items.empty() && items[static_cast<std::size_t>(selected)].is_folder) {
                current_folder = items[static_cast<std::size_t>(selected)].path;
                selected = 0;
                scroll_offset = 0;
            }
            continue;
        }
        if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            if (items.empty()) {
                continue;
            }
            const BrowserItem& item = items[static_cast<std::size_t>(selected)];
            if (item.is_folder) {
                current_folder = item.path;
                selected = 0;
                scroll_offset = 0;
                continue;
            }
            return item.path;
        }
    }
}

}  // namespace syncpss::tui
