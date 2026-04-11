#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

void TuiApp::manage_gpg_keys() {
    ensure_dependencies({"gpg", "veracrypt", "git"});

    auto configured_key_id = [&]() -> std::string {
        if (runtime_config_.has_value() && !runtime_config_->gpg_key_id.empty()) {
            return runtime_config_->gpg_key_id;
        }
        if (config_.has_value() && !config_->gpg_key_id.empty()) {
            return config_->gpg_key_id;
        }
        return "(not configured)";
    };

    auto persist_active_key = [&](const std::string& key_id) {
        if (!runtime_config_.has_value()) {
            syncpss::util::RuntimeConfig runtime;
            if (config_.has_value()) {
                runtime.github_repo = github_repo_from_url(config_->repo_url);
                runtime.gpg_key_id = config_->gpg_key_id;
                runtime.store_path = config_->store_path;
                runtime.store_branch = config_->repo_branch;
            }
            runtime_config_ = runtime;
        }
        runtime_config_->gpg_key_id = key_id;
        syncpss::util::save_runtime_config(*runtime_config_);
        if (config_.has_value()) {
            config_->gpg_key_id = key_id;
        }
        rebuild_clients();
    };

    auto choose_secret_key = [&]() -> std::optional<std::string> {
        const std::vector<std::string> keys = gpg_.secret_key_ids();
        if (keys.empty()) {
            throw std::runtime_error("No GPG secret keys were found in the local keyring");
        }

        std::vector<std::string> lines = {
            "Configured key: " + configured_key_id(),
            "Select which local secret key syncpss should use:"
        };
        for (std::size_t index = 0; index < keys.size(); ++index) {
            lines.push_back(std::to_string(index + 1U) + ". " + keys[index]);
        }
        show_message("Select GPG Key", lines, kColorHeader);

        while (true) {
            const std::string answer = prompt_input("Select GPG Key", "Enter the key number to use:", "1");
            if (answer.empty()) {
                return std::nullopt;
            }
            try {
                const int selected_index = std::stoi(answer);
                if (selected_index >= 1 && selected_index <= static_cast<int>(keys.size())) {
                    return keys[static_cast<std::size_t>(selected_index - 1)];
                }
            } catch (const std::exception&) {
            }
            show_message(
                "Invalid Input",
                {"Please enter a number from 1 to " + std::to_string(keys.size()) + "."},
                kColorError
            );
        }
    };

    auto select_active_key = [&]() {
        const std::optional<std::string> selected_key = choose_secret_key();
        if (!selected_key.has_value()) {
            return;
        }
        persist_active_key(*selected_key);
        show_message(
            "Configured Key Updated",
            {
                "syncpss will now use this key as the configured GPG key:",
                *selected_key
            },
            kColorSuccess
        );
    };

    auto generate_and_select_key = [&]() {
        endwin();
        try {
            gpg_.generate_key_interactive();
        } catch (...) {
            initialize_curses();
            throw;
        }
        initialize_curses();
        handle_resize();

        const std::vector<std::string> keys = gpg_.secret_key_ids();
        if (keys.empty()) {
            throw std::runtime_error("No GPG secret key was found after generation");
        }
        const std::string generated_key = keys.back();
        persist_active_key(generated_key);
        show_message(
            "GPG Key Generated",
            {
                "A new GPG key was generated and selected.",
                "Configured key: " + generated_key
            },
            kColorSuccess
        );
    };

    int selected = 0;
    const std::vector<std::string> items = {
        "[s] Select active GPG key",
        "[g] Generate new GPG key",
        "[b] Backup keys to remote",
        "[r] Restore keys from remote",
        "[e] Export public key",
        "[q] Back"
    };

    while (true) {
        clear();
        box(stdscr, 0, 0);
        mvprintw(1, 2, "GPG Key Manager");
        mvprintw(3, 2, "Configured key: %s", trim_for_render(configured_key_id(), COLS - 20).c_str());
        if (config_.has_value()) {
            const bool remote_keys_exist = std::filesystem::exists(config_->store_path / "keys");
            mvprintw(4, 2, "Remote keys container: %s", remote_keys_exist ? "present" : "missing");
        }

        for (std::size_t index = 0; index < items.size(); ++index) {
            const int row = 6 + static_cast<int>(index);
            render_menu_option(row, 2, items[index], static_cast<int>(index) == selected, COLS - 4);
        }
        mvprintw(LINES - 2, 2, "[Enter] select  [Esc] back");
        refresh();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 27 || ch == 'q' || ch == 'Q') {
            return;
        }
        if (ch == 's' || ch == 'S') {
            select_active_key();
            continue;
        }
        if (ch == 'g' || ch == 'G') {
            generate_and_select_key();
            continue;
        }
        if (ch == 'b' || ch == 'B') {
            backup_keys_to_remote();
            continue;
        }
        if (ch == 'r' || ch == 'R') {
            restore_keys_from_remote();
            continue;
        }
        if (ch == 'e' || ch == 'E') {
            export_public_key();
            continue;
        }
        if (ch == KEY_UP || ch == 'k') {
            selected = (selected - 1 + static_cast<int>(items.size())) % static_cast<int>(items.size());
            continue;
        }
        if (ch == KEY_DOWN || ch == 'j') {
            selected = (selected + 1) % static_cast<int>(items.size());
            continue;
        }
        if (ch != '\n' && ch != '\r' && ch != KEY_ENTER) {
            continue;
        }

        switch (selected) {
            case 0:
                select_active_key();
                break;
            case 1:
                generate_and_select_key();
                break;
            case 2:
                backup_keys_to_remote();
                break;
            case 3:
                restore_keys_from_remote();
                break;
            case 4:
                export_public_key();
                break;
            default:
                return;
        }
    }
}

void TuiApp::export_public_key() {
    if (!runtime_config_.has_value()) {
        throw std::runtime_error("No runtime config loaded");
    }
    if (runtime_config_->gpg_key_id.empty()) {
        throw std::runtime_error("No configured GPG key ID to export");
    }

    const std::string destination = prompt_input(
        "Export Public Key",
        "Destination path:",
        (syncpss::util::runtime_directory() / "public-key.asc").string()
    );
    if (destination.empty()) {
        return;
    }

    gpg_.export_public_key_to_file(runtime_config_->gpg_key_id, destination);
    show_message("Public Key Exported", {"Wrote " + destination}, kColorSuccess);
}

}  // namespace syncpss::tui
