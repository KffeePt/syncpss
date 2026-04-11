#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

void TuiApp::refresh_latest_release_info(bool force_refresh) {
    {
        std::lock_guard<std::mutex> lock(latest_release_mutex_);
        if (latest_release_checked_ && !force_refresh) {
            return;
        }
        if (latest_release_check_in_progress_ && !force_refresh) {
            return;
        }
        latest_release_check_in_progress_ = true;
    }

    ReleaseVersionInfo info;
    try {
        info = fetch_latest_release_version_info();
    } catch (const std::exception& ex) {
        info.error = ex.what();
    }
    {
        std::lock_guard<std::mutex> lock(latest_release_mutex_);
        latest_release_checked_ = true;
        latest_release_check_in_progress_ = false;
        latest_release_version_ = info.latest_version;
        latest_release_error_ = info.error;
        latest_release_update_available_ = info.latest_known && info.update_available;
    }
}

void TuiApp::show_startup_splash() {
    using clock = std::chrono::steady_clock;

    const bool can_offer_update = runtime_config_.has_value() || config_.has_value();
    const std::string telemetry_status = runtime_config_.has_value()
        ? ("Telemetry: " + runtime_config_->telemetry_mode)
        : ("Telemetry: " + syncpss::util::telemetry_mode_label());
    {
        std::lock_guard<std::mutex> lock(latest_release_mutex_);
        if (!latest_release_checked_ && !latest_release_check_in_progress_) {
            latest_release_check_in_progress_ = true;
            std::thread([this]() { refresh_latest_release_info(true); }).detach();
        }
    }

    const clock::time_point splash_deadline = clock::now() + std::chrono::seconds(3);
    clock::time_point prompt_deadline{};
    double angle_a = 0.0;
    double angle_b = 0.0;
    int loading_phase = 0;
    bool prompt_active = false;
    bool release_result_consumed = false;

    timeout(0);
    while (true) {
        const int ch = getch();
        if (ch == KEY_RESIZE) {
            resize_term(0, 0);
            clearok(stdscr, TRUE);
        }

        bool latest_release_checked = false;
        bool latest_release_check_in_progress = false;
        bool latest_release_update_available = false;
        std::string latest_release_version;
        std::string latest_release_error;
        {
            std::lock_guard<std::mutex> lock(latest_release_mutex_);
            latest_release_checked = latest_release_checked_;
            latest_release_check_in_progress = latest_release_check_in_progress_;
            latest_release_update_available = latest_release_update_available_;
            latest_release_version = latest_release_version_;
            latest_release_error = latest_release_error_;
        }

        if (!release_result_consumed && latest_release_checked) {
            release_result_consumed = true;
            if (can_offer_update && latest_release_update_available) {
                prompt_active = true;
                prompt_deadline = clock::now() + std::chrono::seconds(30);
            }
        }

        if (prompt_active) {
            if (ch == '\n' || ch == '\r' || ch == KEY_ENTER || ch == 'u' || ch == 'U') {
                timeout(-1);
                update_to_latest_version(true);
                return;
            }
            if (ch != ERR && ch != KEY_RESIZE) {
                break;
            }
            if (clock::now() >= prompt_deadline) {
                break;
            }

            const double seconds_remaining = std::max(
                0.0,
                std::chrono::duration<double>(prompt_deadline - clock::now()).count()
            );
            const std::string detail =
                telemetry_status + " · update available: " + format_release_version(syncpss_version()) + " -> " +
                format_release_version(latest_release_version);
            const std::string prompt =
                "[Enter]/[u] update now  [any other key] skip  (" +
                std::to_string(static_cast<int>(std::ceil(seconds_remaining))) + "s)";
            render_donut_frame(
                angle_a,
                angle_b,
                loading_phase,
                "Loading updater",
                detail,
                seconds_remaining / 30.0,
                prompt
            );
            present_screen();
        } else {
            if (clock::now() >= splash_deadline) {
                break;
            }
            if (ch != ERR && ch != KEY_RESIZE) {
                break;
            }

            std::string detail = latest_release_checked
                ? (latest_release_error.empty()
                    ? (telemetry_status + " · latest release: " + format_release_version(latest_release_version))
                    : (telemetry_status + " · update check unavailable right now"))
                : (latest_release_check_in_progress
                    ? (telemetry_status + " · checking GitHub for the latest release")
                    : (telemetry_status + " · preparing update status"));
            render_donut_frame(angle_a, angle_b, loading_phase, "Loading secure TUI", detail);
            present_screen();
        }

        angle_a += 0.04;
        angle_b += 0.02;
        ++loading_phase;
        napms(30);
    }

    timeout(-1);
}


void TuiApp::show_help() const {
    show_scrollable_page(
        "Help",
        {
            "Main Menu",
            "",
            "[m] Manage Password Store opens the integrated password browser.",
            "[s] Sync opens the sync and conflict-resolution actions.",
            "[c] Configuration opens setup, backup, key-management, and maintenance tools.",
            "[u] checks for an app update right away.",
            "[q] exits the TUI.",
            "",
            "Navigation",
            "",
            "[Up]/[Down] or j/k move through menu items.",
            "[Enter] selects the highlighted item.",
            "[h] or [?] opens this help page.",
            "[q] closes this help page.",
            "",
            "Password Store Manager",
            "",
            "[Enter] copies the selected password to the clipboard.",
            "[a] adds a new password entry.",
            "[u] copies the selected username.",
            "[n] opens encrypted notes for the selected entry.",
            "[e] edits the selected entry.",
            "[d] deletes the selected entry.",
            "[s] opens sync from inside the manager.",
            "[Ctrl+S] toggles live search.",
            "",
            "Security Notes",
            "",
            "Passwords are never rendered in plaintext on screen.",
            "Clipboard copies expire automatically.",
            "Entry notes are stored as separate GPG-encrypted files in ~/.syncpss/notes.",
            "Release verification compares the installed master fingerprint against the staged local fingerprint."
        },
        kColorDim,
        "[Up/Down/PgUp/PgDn] scroll  [q] back"
    );
}

int TuiApp::main_menu() {
    const std::vector<std::string> items = {
        "[m] Manage Password Store",
        "[s] Sync",
        "[c] Configuration"
    };

    int selected = 0;
    while (true) {
        erase();
        box(stdscr, 0, 0);
        const int banner_rows = render_main_banner(1, std::max(0, LINES - 16));
        const int meta_row = std::max(2, std::min(LINES - 8, 1 + banner_rows + 1));
        const int hint_row = std::max(meta_row + 2, std::min(LINES - 7, meta_row + 3));
        const int menu_start_row =
            std::max(hint_row + 2, std::min(LINES - static_cast<int>(items.size()) - 2, hint_row + 2));
        bool latest_release_checked = false;
        bool latest_release_check_in_progress = false;
        bool latest_release_update_available = false;
        std::string latest_release_version;
        {
            std::lock_guard<std::mutex> lock(latest_release_mutex_);
            latest_release_checked = latest_release_checked_;
            latest_release_check_in_progress = latest_release_check_in_progress_;
            latest_release_update_available = latest_release_update_available_;
            latest_release_version = latest_release_version_;
        }
        const std::string latest_label = latest_release_checked && !latest_release_version.empty()
            ? format_release_version(latest_release_version)
            : (latest_release_checked ? "unavailable" : (latest_release_check_in_progress ? "checking..." : "unknown"));
        const std::string headline =
            "syncpss local " + format_release_version(syncpss_version()) + " · latest " + latest_label;
        const std::string subheadline = latest_release_update_available
            ? "password store · synced · safe · update available"
            : "password store · synced · safe";
        apply_pair(kColorDim);
        mvprintw(meta_row, 2, "%s", trim_for_render(headline, std::max(0, COLS - 4)).c_str());
        mvprintw(meta_row + 1, 2, "%s", trim_for_render(subheadline, std::max(0, COLS - 4)).c_str());
        clear_pair(kColorDim);
        mvprintw(hint_row, 2, "[Up/Down] navigate   [Enter] select   [u] update   [q] quit   [h/?] help");

        for (std::size_t index = 0; index < items.size(); ++index) {
            const int row = menu_start_row + static_cast<int>(index);
            render_menu_option(row, 4, items[index], static_cast<int>(index) == selected, COLS - 6);
        }

        present_screen();
        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 'q' || ch == 'Q') {
            return -1;
        }
        if (ch == 'm' || ch == 'M') {
            return 0;
        }
        if (ch == 's' || ch == 'S') {
            return 1;
        }
        if (ch == 'c' || ch == 'C') {
            return 2;
        }
        if (ch == 'u' || ch == 'U') {
            return 3;
        }
        if (ch == '?' || ch == 'h' || ch == 'H') {
            show_help();
            continue;
        }
        if (ch == KEY_UP || ch == 'k') {
            selected = (selected - 1 + static_cast<int>(items.size())) % static_cast<int>(items.size());
        } else if (ch == KEY_DOWN || ch == 'j') {
            selected = (selected + 1) % static_cast<int>(items.size());
        } else if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            return selected;
        }
    }
}

}  // namespace syncpss::tui
