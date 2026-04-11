#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

void TuiApp::initialize_curses() const {
    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    curs_set(0);
    set_escdelay(250);

    if (has_colors()) {
        start_color();
        use_default_colors();
        init_pair(kColorDefault, COLOR_WHITE, -1);
        init_pair(kColorHighlight, COLOR_BLACK, COLOR_CYAN);
        init_pair(kColorSuccess, COLOR_GREEN, -1);
        init_pair(kColorError, COLOR_RED, -1);
        init_pair(kColorDim, COLOR_BLUE, -1);
        init_pair(kColorHeader, COLOR_YELLOW, -1);
        init_pair(kColorAccount, COLOR_CYAN, -1);
        init_pair(kColorSite, COLOR_GREEN, -1);
        init_pair(kColorSearch, COLOR_YELLOW, -1);
        if (can_change_color() && COLORS > 15) {
            init_color(10, 1000, 720, 820);
            init_color(11, 1000, 820, 320);
            init_color(12, 420, 760, 1000);
            init_color(13, 1000, 930, 240);
            init_color(14, 520, 1000, 420);
            init_color(15, 420, 760, 1000);
            init_pair(kColorFrosting, 10, -1);
            init_pair(kColorDough, 11, -1);
            init_pair(kColorSprinkleBlue, 12, -1);
            init_pair(kColorSprinkleYellow, 13, -1);
            init_pair(kColorSprinkleGreen, 14, -1);
            init_pair(kColorSelection, 15, -1);
        } else {
            init_pair(kColorFrosting, COLOR_MAGENTA, -1);
            init_pair(kColorDough, COLOR_YELLOW, -1);
            init_pair(kColorSprinkleBlue, COLOR_CYAN, -1);
            init_pair(kColorSprinkleYellow, COLOR_YELLOW, -1);
            init_pair(kColorSprinkleGreen, COLOR_GREEN, -1);
            init_pair(kColorSelection, COLOR_CYAN, -1);
        }
    }
}

void TuiApp::handle_resize() const {
    winsize ws{};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0 && ws.ws_col > 0) {
        resizeterm(ws.ws_row, ws.ws_col);
    } else {
        endwin();
        refresh();
    }
    clearok(stdscr, TRUE);
    erase();
    refresh();
}


void TuiApp::show_message(const std::string& title, const std::vector<std::string>& lines, int color_pair) const {
    while (true) {
        reset_screen_canvas();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "%s", title.c_str());
        attroff(A_BOLD);
        clear_pair(kColorHeader);

        int row = 3;
        apply_pair(color_pair);
        for (const std::string& line : lines) {
            if (row >= LINES - 2) {
                break;
            }
            mvprintw(row++, 2, "%s", trim_for_render(line, COLS - 4).c_str());
        }
        clear_pair(color_pair);

        mvprintw(LINES - 2, 2, "Press any key to continue");
        present_screen();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        break;
    }
}

void TuiApp::show_scrollable_page(
    const std::string& title,
    const std::vector<std::string>& lines,
    int color_pair,
    const std::string& footer
) const {
    int scroll_offset = 0;

    while (true) {
        reset_screen_canvas();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "%s", title.c_str());
        attroff(A_BOLD);
        clear_pair(kColorHeader);

        const int content_top = 3;
        const int content_height = std::max(1, LINES - 6);
        const int max_scroll = std::max(0, static_cast<int>(lines.size()) - content_height);
        scroll_offset = std::clamp(scroll_offset, 0, max_scroll);

        apply_pair(color_pair);
        for (int row = 0; row < content_height; ++row) {
            const int line_index = scroll_offset + row;
            if (line_index >= static_cast<int>(lines.size())) {
                break;
            }
            mvprintw(content_top + row, 2, "%s", trim_for_render(lines[static_cast<std::size_t>(line_index)], COLS - 4).c_str());
        }
        clear_pair(color_pair);

        apply_pair(kColorDim);
        mvhline(LINES - 2, 2, ' ', std::max(0, COLS - 4));
        mvprintw(LINES - 2, 2, "%s", trim_for_render(footer, COLS - 4).c_str());
        clear_pair(kColorDim);
        present_screen();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 'q' || ch == 'Q' || ch == 27) {
            return;
        }
        if (ch == KEY_UP || ch == 'k') {
            if (scroll_offset > 0) {
                --scroll_offset;
            }
            continue;
        }
        if (ch == KEY_DOWN || ch == 'j') {
            if (scroll_offset < max_scroll) {
                ++scroll_offset;
            }
            continue;
        }
        if (ch == KEY_PPAGE) {
            scroll_offset = std::max(0, scroll_offset - content_height);
            continue;
        }
        if (ch == KEY_NPAGE) {
            scroll_offset = std::min(max_scroll, scroll_offset + content_height);
            continue;
        }
        if (ch == KEY_HOME || ch == 'g') {
            scroll_offset = 0;
            continue;
        }
        if (ch == KEY_END || ch == 'G') {
            scroll_offset = max_scroll;
            continue;
        }
    }
}

void TuiApp::show_clipboard_notice(const std::string& label, const syncpss::util::ClipboardLease& lease) const {
    const auto render_notice_frame = [&]() {
        reset_screen_canvas();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "Copied");
        attroff(A_BOLD);
        clear_pair(kColorHeader);

        apply_pair(kColorSuccess);
        mvprintw(3, 2, "%s copied to the clipboard.", label.c_str());
        clear_pair(kColorSuccess);
        mvprintw(5, 2, "Clipboard will be cleared automatically after 60 seconds.");
        mvprintw(7, 2, "Returning to the menu in 3 seconds. Press any key to dismiss now.");
    };

    render_notice_frame();

    int remaining_seconds = -1;
    bool status_shown = false;
    timeout(100);
    const auto dismiss_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (true) {
        const bool active = syncpss::util::clipboard_lease_active(lease.id);
        const syncpss::util::ClipboardLeaseState state = syncpss::util::clipboard_lease_state(lease.id);
        int next_remaining = 0;
        if (active) {
            next_remaining = static_cast<int>(
                std::max<std::int64_t>(
                    0,
                    std::chrono::duration_cast<std::chrono::seconds>(
                        lease.expires_at - std::chrono::steady_clock::now()
                    ).count()
                )
            );
        }

        if (active && next_remaining != remaining_seconds) {
            remaining_seconds = next_remaining;
            mvhline(9, 2, ' ', static_cast<int>(COLS - 4));
            apply_pair(kColorSearch);
            attron(A_BOLD);
            mvprintw(9, 2, "Clearing in: %02d:%02d", remaining_seconds / 60, remaining_seconds % 60);
            attroff(A_BOLD);
            clear_pair(kColorSearch);
            mvhline(11, 2, ' ', static_cast<int>(COLS - 4));
            present_screen();
        } else if (!active && !status_shown && state != syncpss::util::ClipboardLeaseState::Pending) {
            status_shown = true;
            mvhline(9, 2, ' ', static_cast<int>(COLS - 4));
            mvhline(11, 2, ' ', static_cast<int>(COLS - 4));
            if (state == syncpss::util::ClipboardLeaseState::Cleared) {
                apply_pair(kColorSuccess);
                attron(A_BOLD);
                mvprintw(9, 2, "Clipboard cleared.");
                attroff(A_BOLD);
                clear_pair(kColorSuccess);
                mvprintw(11, 2, "%s was removed from the clipboard.", label.c_str());
            } else {
                apply_pair(kColorError);
                attron(A_BOLD);
                mvprintw(9, 2, "Clipboard changed.");
                attroff(A_BOLD);
                clear_pair(kColorError);
                mvprintw(11, 2, "A newer clipboard item replaced this one before the timer expired.");
            }
            present_screen();
        }

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            render_notice_frame();
            remaining_seconds = -1;
            continue;
        }
        if (ch != ERR) {
            break;
        }
        if (std::chrono::steady_clock::now() >= dismiss_deadline) {
            break;
        }
    }
    timeout(-1);
}

bool TuiApp::confirm_with_text(const std::string& prompt, const std::string& expected) const {
    const std::string input = prompt_input("Confirm", prompt + " Type " + expected + " to confirm.", "");
    return input == expected;
}

std::string TuiApp::prompt_input(
    const std::string& title,
    const std::string& prompt,
    const std::string& initial,
    bool secret
) const {
    std::string value = initial;
    std::size_t cursor = value.size();
    std::size_t scroll_offset = 0;
    curs_set(1);
    flushinp();

    while (true) {
        reset_screen_canvas();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "%s", title.c_str());
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        mvprintw(3, 2, "%s", trim_for_render(prompt, COLS - 4).c_str());

        const std::string display = secret ? std::string(value.size(), '*') : value;
        const int field_width = std::max(1, COLS - 6);
        if (cursor < scroll_offset) {
            scroll_offset = cursor;
        }
        if (cursor > scroll_offset + static_cast<std::size_t>(field_width - 1)) {
            scroll_offset = cursor - static_cast<std::size_t>(field_width - 1);
        }
        if (scroll_offset > display.size()) {
            scroll_offset = display.size();
        }

        const std::string visible = display.substr(scroll_offset, static_cast<std::size_t>(field_width));
        mvhline(5, 2, ' ', field_width + 2);
        mvprintw(5, 2, "> %s", visible.c_str());
        mvprintw(LINES - 2, 2, "[Enter] accept  [Esc] cancel  [Left/Right] move cursor");
        move(5, std::min(COLS - 2, 4 + static_cast<int>(cursor - scroll_offset)));
        present_screen();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 27) {
            curs_set(0);
            return "";
        }
        if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            curs_set(0);
            return value;
        }
        if (ch == KEY_LEFT) {
            if (cursor > 0) {
                --cursor;
            }
            continue;
        }
        if (ch == KEY_RIGHT) {
            if (cursor < value.size()) {
                ++cursor;
            }
            continue;
        }
        if (ch == KEY_HOME) {
            cursor = 0;
            continue;
        }
        if (ch == KEY_END) {
            cursor = value.size();
            continue;
        }
        if (ch == KEY_BACKSPACE || ch == 8 || ch == 127) {
            if (cursor > 0 && !value.empty()) {
                value.erase(cursor - 1U, 1U);
                --cursor;
            }
            continue;
        }
        if (ch == KEY_DC) {
            if (cursor < value.size()) {
                value.erase(cursor, 1U);
            }
            continue;
        }
        if (ch >= 32 && ch <= 126) {
            value.insert(value.begin() + static_cast<std::ptrdiff_t>(cursor), static_cast<char>(ch));
            ++cursor;
        }
    }
}

std::string TuiApp::prompt_password_value(
    const std::string& title,
    bool allow_keep_current,
    const std::string& current_value
) const {
    while (true) {
        const std::string mode = prompt_input(
            title,
            allow_keep_current
                ? "Password mode: [k]eep current, [m]anual, [1] 16-char random, [3] 32-char random"
                : "Password mode: [m]anual, [1] 16-char random, [3] 32-char random",
            allow_keep_current ? "k" : "m"
        );
        if (mode.empty()) {
            return allow_keep_current ? current_value : "";
        }

        const char choice = static_cast<char>(std::tolower(static_cast<unsigned char>(mode.front())));
        if (allow_keep_current && choice == 'k') {
            return current_value;
        }
        if (choice == 'm') {
            return prompt_input(title, "Password:", "", true);
        }
        if (choice == '1' || choice == '3') {
            const std::size_t length = choice == '1' ? 16U : 32U;
            const std::string generated = store_->generate_password(length);
            const syncpss::util::ClipboardLease lease =
                syncpss::util::copy_to_clipboard_with_expiry(generated, std::chrono::seconds(60));
            show_clipboard_notice(std::to_string(length) + "-character generated password", lease);
            return generated;
        }
    }
}


}  // namespace syncpss::tui
