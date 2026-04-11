#pragma once

#include <ncurses.h>
#include <string>
#include <type_traits>

namespace syncpss::tui::detail {

std::string trim_for_render(const std::string& value, int max_width);
std::string trim_ascii_art_line(const std::string& value, int max_width);
void apply_pair(int pair);
void clear_pair(int pair);
void render_menu_option(
    int row,
    int col,
    const std::string& label,
    bool selected,
    int max_width = -1,
    int inactive_pair = 0
);
void present_screen();
void reset_screen_canvas();
int render_main_banner(int start_row, int max_rows);
void render_donut_frame(
    double angle_a,
    double angle_b,
    int loading_phase,
    const std::string& loading_base = "Loading secure TUI",
    const std::string& detail_line = "",
    double progress_fraction = -1.0,
    const std::string& prompt_line = "",
    bool animate_loading = true
);

template <typename Callback>
auto with_terminal_handoff(Callback&& callback) -> decltype(callback()) {
    def_prog_mode();
    endwin();
    try {
        if constexpr (std::is_void_v<decltype(callback())>) {
            callback();
            reset_prog_mode();
            refresh();
            clearok(stdscr, TRUE);
            curs_set(0);
            return;
        } else {
            auto result = callback();
            reset_prog_mode();
            refresh();
            clearok(stdscr, TRUE);
            curs_set(0);
            return result;
        }
    } catch (...) {
        reset_prog_mode();
        refresh();
        clearok(stdscr, TRUE);
        curs_set(0);
        throw;
    }
}

}  // namespace syncpss::tui::detail
