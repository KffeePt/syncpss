#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/passwords.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

void TuiApp::view_passwords() {
    ensure_dependencies({"pass", "gpg", "git"});

    std::vector<std::string> entries = store_->list_entries();
    std::string filter;
    std::string current_folder;
    int selected = 0;
    int scroll_offset = 0;
    bool search_mode = false;

    while (true) {
        std::vector<BrowserItem> visible;
        if (search_mode || !filter.empty()) {
            for (const std::string& entry : entries) {
                const EntryViewModel model = describe_entry(entry);
                if (matches_entry_filter(filter, model)) {
                    BrowserItem item;
                    item.path = entry;
                    item.label = model.leaf;
                    item.model = model;
                    visible.push_back(item);
                }
            }
        } else {
            visible = build_browser_items(entries, current_folder);
        }
        if (selected >= static_cast<int>(visible.size())) {
            selected = std::max(0, static_cast<int>(visible.size()) - 1);
        }
        if (selected < 0) {
            selected = 0;
        }

        const int table_header_row = search_mode ? 8 : 7;
        const int table_start_row = table_header_row + 2;
        const int visible_rows = std::max(1, std::min(10, LINES - table_start_row - 3));
        const int max_scroll = std::max(0, static_cast<int>(visible.size()) - visible_rows);
        scroll_offset = std::clamp(scroll_offset, 0, max_scroll);
        if (selected < scroll_offset) {
            scroll_offset = selected;
        }
        if (selected >= scroll_offset + visible_rows) {
            scroll_offset = selected - visible_rows + 1;
        }

        const int content_width = std::max(30, COLS - 6);
        int folder_width = std::max(10, content_width / 4);
        int account_width = std::max(16, content_width / 3);
        int site_width = content_width - folder_width - account_width - 4;
        if (site_width < 12) {
            const int folder_reduce = std::min(folder_width - 10, 12 - site_width);
            folder_width -= std::max(0, folder_reduce);
            site_width = content_width - folder_width - account_width - 4;
        }
        if (site_width < 12) {
            const int account_reduce = std::min(account_width - 12, 12 - site_width);
            account_width -= std::max(0, account_reduce);
            site_width = content_width - folder_width - account_width - 4;
        }
        site_width = std::max(10, site_width);

        erase();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "Manage Password Store");
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        apply_pair(kColorDim);
        mvprintw(
            2,
            2,
            "[Enter] open/copy  [a] add  [u] copy user  [n] notes  [e] edit  [d] delete  [s] sync  [h] help  [Esc] back"
        );
        clear_pair(kColorDim);

        if (search_mode) {
            apply_pair(kColorSearch);
            attron(A_BOLD);
            mvprintw(4, 2, "Search");
            attroff(A_BOLD);
            clear_pair(kColorSearch);
            mvhline(5, 2, ' ', static_cast<int>(COLS - 4));
            mvprintw(5, 4, "> %s", trim_for_render(filter, COLS - 10).c_str());
            apply_pair(kColorDim);
            mvprintw(6, 4, "Live results update as you type.");
            clear_pair(kColorDim);
            move(5, std::min(COLS - 3, 6 + static_cast<int>(filter.size())));
            curs_set(1);
        } else {
            curs_set(0);
            apply_pair(kColorDim);
            mvprintw(4, 2, "Folder: %s", current_folder.empty() ? "/" : current_folder.c_str());
            mvprintw(5, 2, "[Right] enter folder  [Left] go back  folders are shown first");
            if (!filter.empty()) {
                mvprintw(6, 2, "Active search: %s", trim_for_render(filter, COLS - 18).c_str());
            }
            clear_pair(kColorDim);
        }

        apply_pair(kColorHeader);
        attron(A_BOLD);
        const std::string table_header =
            pad_right("Folder", folder_width) + "  " +
            pad_right("User / Account", account_width) + "  " +
            pad_right("Site / Service", site_width);
        mvhline(table_header_row, 2, ' ', static_cast<int>(COLS - 4));
        mvhline(table_header_row + 1, 2, ' ', static_cast<int>(COLS - 4));
        mvprintw(table_header_row, 2, "%s", trim_for_render(table_header, COLS - 4).c_str());
        attroff(A_BOLD);
        clear_pair(kColorHeader);

        if (visible.empty()) {
            apply_pair(kColorError);
            mvprintw(
                table_start_row,
                2,
                "%s",
                search_mode || !filter.empty()
                    ? "No entries match the current search."
                    : "This folder is empty."
            );
            clear_pair(kColorError);
        } else {
            const int end_index = std::min(static_cast<int>(visible.size()), scroll_offset + visible_rows);
            for (int index = scroll_offset; index < end_index; ++index) {
                const int row = table_start_row + (index - scroll_offset);
                const BrowserItem& item = visible[static_cast<std::size_t>(index)];
                const std::string folder_display = item.is_folder
                    ? (current_folder.empty() ? "/" : current_folder)
                    : (item.model.folder.empty() ? "/" : item.model.folder);
                const std::string account_display = item.is_folder
                    ? "[DIR] " + item.label
                    : (item.model.account.empty() ? item.model.leaf : item.model.account);
                const std::string site_display = item.is_folder
                    ? "<folder>"
                    : (item.model.site.empty() ? "-" : item.model.site);

                if (index == selected) {
                const std::string line = pad_right(folder_display, folder_width) +
                                             "  " +
                                             pad_right(account_display, account_width) +
                                             "  " +
                                             pad_right(site_display, site_width);
                    render_menu_option(row, 2, line, true, COLS - 4);
                } else {
                    apply_pair(kColorDim);
                    mvprintw(row, 2, "%s", pad_right(folder_display, folder_width).c_str());
                    clear_pair(kColorDim);

                    apply_pair(kColorAccount);
                    attron(A_BOLD);
                    mvprintw(row, 2 + folder_width + 2, "%s", pad_right(account_display, account_width).c_str());
                    attroff(A_BOLD);
                    clear_pair(kColorAccount);

                    apply_pair(kColorSite);
                    mvprintw(row, 2 + folder_width + 2 + account_width + 2, "%s", pad_right(site_display, site_width).c_str());
                    clear_pair(kColorSite);
                }
            }
        }

        apply_pair(kColorDim);
        mvprintw(
            LINES - 2,
            2,
            "Showing %d-%d of %d",
            visible.empty() ? 0 : scroll_offset + 1,
            visible.empty() ? 0 : std::min(static_cast<int>(visible.size()), scroll_offset + visible_rows),
            static_cast<int>(visible.size())
        );
        clear_pair(kColorDim);

        present_screen();
        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 'h' || ch == 'H' || ch == '?') {
            show_scrollable_page(
                "Manage Password Store Help",
                {
                    "Navigation",
                    "",
                    "[Up]/[Down] or j/k move between rows.",
                    "[Right]/l enters a folder.",
                    "[Left]/h goes to the parent folder.",
                    "[Ctrl+S] starts live search.",
                    "[Esc] closes search or returns to the main menu.",
                    "",
                    "Entry Actions",
                    "",
                    "[Enter] copies the password to the clipboard.",
                    "[a] adds a new password entry.",
                    "[u] copies the username to the clipboard.",
                    "[n] opens the encrypted note attached to the selected entry.",
                    "[e] edits the selected entry.",
                    "[d] deletes the selected entry.",
                    "[s] opens sync without leaving the manager.",
                    "",
                    "Notes",
                    "",
                    "Notes are stored separately from the pass entry body.",
                    "Each note is saved as its own GPG-encrypted .note file under ~/.syncpss/notes.",
                    "Legacy inline entry notes remain readable for compatibility, but new saves use the separate encrypted note files."
                },
                kColorDim
            );
            continue;
        }
        if (ch == 19) {
            search_mode = true;
            continue;
        }
        if (ch == 27) {
            if (search_mode) {
                if (!filter.empty()) {
                    filter.clear();
                    selected = 0;
                    scroll_offset = 0;
                } else {
                    search_mode = false;
                }
                continue;
            }
            curs_set(0);
            return;
        }
        if (ch == KEY_UP || ch == 'k') {
            if (!visible.empty()) {
                selected = (selected - 1 + static_cast<int>(visible.size())) % static_cast<int>(visible.size());
            }
            continue;
        }
        if (ch == KEY_DOWN || ch == 'j') {
            if (!visible.empty()) {
                selected = (selected + 1) % static_cast<int>(visible.size());
            }
            continue;
        }
        if (ch == KEY_LEFT || ch == 'h') {
            if (!search_mode && !current_folder.empty()) {
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
            if (!search_mode && !visible.empty() && visible[static_cast<std::size_t>(selected)].is_folder) {
                current_folder = visible[static_cast<std::size_t>(selected)].path;
                selected = 0;
                scroll_offset = 0;
            }
            continue;
        }
        if (ch == KEY_BACKSPACE || ch == 8 || ch == 127) {
            if (search_mode && !filter.empty()) {
                filter.pop_back();
                selected = 0;
                scroll_offset = 0;
            }
            continue;
        }
        if (search_mode && ch >= 32 && ch <= 126) {
            filter.push_back(static_cast<char>(ch));
            selected = 0;
            scroll_offset = 0;
            continue;
        }
        if (ch == 'a' || ch == 'A') {
            add_password();
            entries = store_->list_entries();
            selected = 0;
            scroll_offset = 0;
            continue;
        } else if (ch == 's' || ch == 'S') {
            sync_menu();
            entries = store_->list_entries();
            selected = 0;
            scroll_offset = 0;
            continue;
        }

        if (visible.empty()) {
            continue;
        }

        const BrowserItem& item = visible[static_cast<std::size_t>(selected)];
        if (!search_mode && item.is_folder && (ch == '\n' || ch == '\r' || ch == KEY_ENTER)) {
            current_folder = item.path;
            selected = 0;
            scroll_offset = 0;
            continue;
        }
        if (item.is_folder) {
            continue;
        }

        const std::string entry_name = item.path;
        if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            syncpss::store::Entry entry;
            try {
                entry = with_terminal_handoff([&]() {
                    return store_->read_entry(entry_name);
                });
            } catch (const std::exception& ex) {
                if (is_gpg_cancelled_error(ex.what())) {
                    continue;
                }
                throw;
            }
            const syncpss::util::ClipboardLease lease =
                syncpss::util::copy_to_clipboard_with_expiry(entry.password, std::chrono::seconds(60));
            show_clipboard_notice("Password", lease);
        } else if (ch == 'u' || ch == 'U') {
            syncpss::store::Entry entry;
            try {
                entry = with_terminal_handoff([&]() {
                    return store_->read_entry(entry_name);
                });
            } catch (const std::exception& ex) {
                if (is_gpg_cancelled_error(ex.what())) {
                    continue;
                }
                throw;
            }
            const syncpss::util::ClipboardLease lease =
                syncpss::util::copy_to_clipboard_with_expiry(entry.username, std::chrono::seconds(60));
            show_clipboard_notice("Username", lease);
        } else if (ch == 'n' || ch == 'N') {
            const std::string notes = store_->read_notes(entry_name);
            std::vector<std::string> note_lines = {"Entry: " + entry_name, ""};
            if (notes.empty()) {
                note_lines.emplace_back("No plaintext notes saved for this entry.");
            } else {
                std::stringstream input(notes);
                std::string line;
                while (std::getline(input, line)) {
                    note_lines.push_back(line);
                }
            }
            show_message("Notes", note_lines, kColorAccount);
        } else if (ch == 'e' || ch == 'E') {
            edit_password(entry_name);
            entries = store_->list_entries();
            selected = 0;
            scroll_offset = 0;
        } else if (ch == 'd' || ch == 'D') {
            delete_password(entry_name);
            entries = store_->list_entries();
            selected = 0;
            scroll_offset = 0;
        }
    }
}

void TuiApp::add_password() {
    ensure_dependencies({"pass", "gpg"});

    syncpss::store::Entry entry;
    const std::string mode = prompt_input(
        "Add Password",
        "Mode: [m] manual entry name, [c] combo builder",
        "c"
    );
    if (mode.empty()) {
        return;
    }
    const char choice = static_cast<char>(std::tolower(static_cast<unsigned char>(mode.front())));
    const syncpss::util::EntryMode entry_mode =
        choice == 'm' ? syncpss::util::EntryMode::Manual : syncpss::util::EntryMode::Combo;

    if (choice == 'm') {
        while (true) {
            entry.name = prompt_input("Add Password", "Entry name (freeform):", entry.name);
            if (entry.name.empty()) {
                return;
            }
            if (store_->validate_entry_name(entry.name)) {
                break;
            }
            show_message(
                "Invalid Input",
                {"Entry names cannot contain empty segments, . or .., or control characters."},
                kColorError
            );
        }
    } else {
        const std::string folder = select_folder("Select Folder");
        std::string user;
        while (true) {
            user = prompt_input("Add Password", "User:", user);
            if (user.empty()) {
                return;
            }
            break;
        }

        std::string account_location;
        while (true) {
            account_location = prompt_input(
                "Add Password",
                "Location for the user/account (freehand, email-style second part):",
                account_location
            );
            if (account_location.empty()) {
                return;
            }
            break;
        }

        std::string site_host;
        while (true) {
            site_host = prompt_input(
                "Add Password",
                "Domain / host (examples: www.example.com, example.com, http://www.example.com, https://www.example.com, localhost, 127.0.0.1):",
                site_host
            );
            if (site_host.empty()) {
                return;
            }
            break;
        }

        std::string port;
        while (true) {
            port = prompt_input(
                "Add Password",
                "Port (optional, leave empty for none, valid range 1-65535):",
                port
            );
            if (is_valid_port_text(port)) {
                break;
            }
            show_message("Invalid Input", {"Port must be empty or an integer from 1 to 65535."}, kColorError);
        }

        const std::string query = prompt_input(
            "Add Password",
            "URL query / path (optional, accept '/value' or 'value'):"
        );
        const std::string company_location = prompt_input(
            "Add Password",
            "Company / location (optional, appended after '@' in the site token):"
        );

        const std::string account_value = build_account_value(user, account_location);
        const std::string site_value = build_site_value(site_host, port, query, company_location);
        if (account_value.empty()) {
            show_message("Invalid Input", {"User and account location are both required in combo mode."}, kColorError);
            return;
        }
        if (site_value.empty()) {
            show_message("Invalid Input", {"A valid domain / host is required in combo mode."}, kColorError);
            return;
        }

        const std::string account_token = "[" + account_value + "]";
        const std::string site_token = "[" + site_value + "]";
        entry.name = build_entry_name_from_parts(folder, account_token, site_token);
        entry.username = account_value;
        entry.url = site_value;
    }

    entry.password = prompt_password_value("Add Password", false);
    if (entry.password.empty()) {
        return;
    }
    entry.notes = prompt_input("Add Password", "Encrypted notes (stored as a separate GPG note file):");

    while (true) {
        try {
            store_->save_entry(entry, false);
            syncpss::util::record_entry_creation(entry.name, entry_mode);
            show_message(
                "Saved",
                {
                    "Password entry added.",
                    "Built entry name: " + entry.name
                },
                kColorSuccess
            );
            return;
        } catch (const std::exception& ex) {
            show_message("Invalid Input", {ex.what(), "Please correct the entry and try again."}, kColorError);
            if (choice == 'm') {
                entry.name = prompt_input("Add Password", "Entry name (freeform):", entry.name);
                if (entry.name.empty()) {
                    return;
                }
                continue;
            }
            throw;
        }
    }
}

void TuiApp::edit_password(const std::optional<std::string>& preselected) {
    ensure_dependencies({"pass", "gpg"});

    std::optional<std::string> target = preselected;
    if (!target.has_value()) {
        target = select_entry("Edit Password");
    }
    if (!target.has_value()) {
        return;
    }

    syncpss::store::Entry entry;
    try {
        entry = with_terminal_handoff([&]() {
            return store_->read_entry(*target);
        });
    } catch (const std::exception& ex) {
        if (is_gpg_cancelled_error(ex.what())) {
            return;
        }
        throw;
    }
    const ComboDefaults defaults = combo_defaults_from_entry(entry);
    const syncpss::util::EntryMode preferred_mode = syncpss::util::preferred_entry_mode(*target);
    const std::string original_entry_name = *target;
    const std::string original_username = entry.username;

    const std::string password_only_answer = prompt_input(
        "Edit Password",
        "Only change the password and keep the rest as-is? [y/N]",
        "N"
    );
    if (answer_is_yes(password_only_answer, false)) {
        const std::string updated_password = prompt_password_value("Edit Password", false);
        if (updated_password.empty()) {
            return;
        }
        entry.password = updated_password;
        try {
            store_->save_entry(entry, true);
            if (entry.name == original_entry_name && entry.username != original_username) {
                store_->delete_notes(original_entry_name, original_username);
            }
            syncpss::util::record_entry_modification(original_entry_name, entry.name, preferred_mode);
            show_message("Updated", {"Password updated.", entry.name}, kColorSuccess);
        } catch (const std::exception& ex) {
            show_message("Invalid Input", {ex.what(), "Password update was not saved."}, kColorError);
        }
        return;
    }

    const bool combo_candidate = !defaults.user.empty() && !defaults.site_host.empty();
    const std::string mode = prompt_input(
        "Edit Password",
        "Mode: [m] manual entry name, [c] combo builder",
        preferred_mode == syncpss::util::EntryMode::Manual
            ? "m"
            : ((preferred_mode == syncpss::util::EntryMode::Combo || combo_candidate) ? "c" : "m")
    );
    if (mode.empty()) {
        return;
    }

    const char choice = static_cast<char>(std::tolower(static_cast<unsigned char>(mode.front())));
    const syncpss::util::EntryMode entry_mode =
        choice == 'm' ? syncpss::util::EntryMode::Manual : syncpss::util::EntryMode::Combo;
    if (choice == 'm') {
        while (true) {
            entry.name = prompt_input("Edit Password", "Entry name (freeform):", entry.name);
            if (entry.name.empty()) {
                return;
            }
            if (store_->validate_entry_name(entry.name)) {
                break;
            }
            show_message(
                "Invalid Input",
                {"Entry names cannot contain empty segments, . or .., or control characters."},
                kColorError
            );
        }
    } else {
        const std::string folder = select_folder("Select Folder", defaults.folder);
        std::string user = defaults.user;
        while (true) {
            user = prompt_input("Edit Password", "User:", user);
            if (user.empty()) {
                return;
            }
            break;
        }

        std::string account_location = defaults.account_location;
        while (true) {
            account_location = prompt_input(
                "Edit Password",
                "Location for the user/account (freehand, email-style second part):",
                account_location
            );
            if (account_location.empty()) {
                return;
            }
            break;
        }

        std::string site_host = defaults.site_host;
        while (true) {
            site_host = prompt_input(
                "Edit Password",
                "Domain / host (examples: www.example.com, example.com, http://www.example.com, https://www.example.com, localhost, 127.0.0.1):",
                site_host
            );
            if (site_host.empty()) {
                return;
            }
            break;
        }

        std::string port = defaults.port;
        while (true) {
            port = prompt_input(
                "Edit Password",
                "Port (optional, leave empty for none, valid range 1-65535):",
                port
            );
            if (is_valid_port_text(port)) {
                break;
            }
            show_message("Invalid Input", {"Port must be empty or an integer from 1 to 65535."}, kColorError);
        }

        const std::string query = prompt_input(
            "Edit Password",
            "URL query / path (optional, accept '/value' or 'value'):",
            defaults.query
        );
        const std::string company_location = prompt_input(
            "Edit Password",
            "Company / location (optional, appended after '@' in the site token):",
            defaults.company_location
        );

        const std::string account_value = build_account_value(user, account_location);
        const std::string site_value = build_site_value(site_host, port, query, company_location);
        if (account_value.empty()) {
            show_message("Invalid Input", {"User and account location are both required in combo mode."}, kColorError);
            return;
        }
        if (site_value.empty()) {
            show_message("Invalid Input", {"A valid domain / host is required in combo mode."}, kColorError);
            return;
        }

        const std::string account_token = "[" + account_value + "]";
        const std::string site_token = "[" + site_value + "]";
        entry.name = build_entry_name_from_parts(folder, account_token, site_token);
        entry.username = account_value;
        entry.url = site_value;
    }

    entry.password = prompt_password_value("Edit Password", true, entry.password);
    entry.notes = prompt_input("Edit Password", "Encrypted notes (stored as a separate GPG note file):", entry.notes);

    while (true) {
        try {
            store_->save_entry(entry, true);
            if (entry.name == original_entry_name && entry.username != original_username) {
                store_->delete_notes(original_entry_name, original_username);
            }
            bool removed_old_entry = false;
            if (entry.name != original_entry_name) {
                const std::string delete_old_answer = prompt_input(
                    "Edit Password",
                    "Delete the old entry '" + original_entry_name + "' now? [Y/n]",
                    "Y"
                );
                if (answer_is_yes(delete_old_answer, true)) {
                    store_->delete_entry(original_entry_name);
                    removed_old_entry = true;
                }
            }
            syncpss::util::record_entry_modification(original_entry_name, entry.name, entry_mode);
            if (removed_old_entry) {
                show_message(
                    "Updated",
                    {
                        "Password entry updated.",
                        "Active entry: " + entry.name,
                        "Removed stale entry: " + original_entry_name
                    },
                    kColorSuccess
                );
            } else if (entry.name != original_entry_name) {
                show_message(
                    "Updated",
                    {
                        "Password entry updated.",
                        "Active entry: " + entry.name,
                        "Old entry kept: " + original_entry_name
                    },
                    kColorSuccess
                );
            } else {
                show_message("Updated", {"Password entry updated.", entry.name}, kColorSuccess);
            }
            return;
        } catch (const std::exception& ex) {
            show_message("Invalid Input", {ex.what(), "Please correct the entry and try again."}, kColorError);
            if (choice == 'm') {
                entry.name = prompt_input("Edit Password", "Entry name (freeform):", entry.name);
                if (entry.name.empty()) {
                    return;
                }
                continue;
            }
            throw;
        }
    }
}

void TuiApp::delete_password(const std::optional<std::string>& preselected) {
    if (preselected.has_value()) {
        if (!confirm_with_text("Delete " + *preselected + "?", *preselected)) {
            show_message("Cancelled", {"Delete operation cancelled."});
            return;
        }

        store_->delete_entry(*preselected);
        syncpss::util::record_entry_deletion(*preselected);
        show_message("Deleted", {"Entry removed.", *preselected}, kColorSuccess);
        return;
    }

    std::vector<std::string> entries = store_->list_entries();
    if (entries.empty()) {
        show_message("Delete Password", {"The password store is empty."}, kColorDim);
        return;
    }

    std::string current_folder;
    int selected = 0;
    int scroll_offset = 0;

    while (true) {
        const std::vector<BrowserItem> items = build_browser_items(entries, current_folder);
        if (selected >= static_cast<int>(items.size())) {
            selected = std::max(0, static_cast<int>(items.size()) - 1);
        }

        const int visible_rows = std::max(1, LINES - 8);
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
        mvprintw(1, 2, "Delete Password");
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        mvprintw(3, 2, "Folder: %s", current_folder.empty() ? "/" : current_folder.c_str());
        apply_pair(kColorDim);
        mvprintw(4, 2, "[Enter] delete  [Right] enter folder  [Left] up  [Esc] cancel");
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
            return;
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
        if (ch != '\n' && ch != '\r' && ch != KEY_ENTER) {
            continue;
        }
        if (items.empty()) {
            continue;
        }

        const BrowserItem& item = items[static_cast<std::size_t>(selected)];
        if (item.is_folder) {
            if (!confirm_with_text("Delete folder " + item.path + " recursively?", "DELETE")) {
                show_message("Cancelled", {"Recursive folder delete cancelled."});
                entries = store_->list_entries();
                continue;
            }
            store_->delete_tree(item.path);
            syncpss::util::record_recursive_entry_deletion(item.path);
            if (current_folder == item.path || current_folder.rfind(item.path + "/", 0) == 0) {
                current_folder = std::filesystem::path(item.path).parent_path().generic_string();
                if (current_folder == ".") {
                    current_folder.clear();
                }
            }
            entries = store_->list_entries();
            selected = 0;
            scroll_offset = 0;
            show_message("Deleted", {"Folder removed recursively.", item.path}, kColorSuccess);
            continue;
        }

        if (!confirm_with_text("Delete " + item.path + "?", item.path)) {
            show_message("Cancelled", {"Delete operation cancelled."});
            entries = store_->list_entries();
            continue;
        }

        store_->delete_entry(item.path);
        syncpss::util::record_entry_deletion(item.path);
        entries = store_->list_entries();
        selected = 0;
        scroll_offset = 0;
        show_message("Deleted", {"Entry removed.", item.path}, kColorSuccess);
    }
}

}  // namespace syncpss::tui
