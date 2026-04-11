
#include "tui/detail/common.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui::detail {
std::string trim_for_render(const std::string& value, int max_width) {
    if (max_width <= 0) {
        return "";
    }
    if (static_cast<int>(value.size()) <= max_width) {
        return value;
    }
    if (max_width <= 3) {
        return value.substr(0, static_cast<std::size_t>(max_width));
    }
    return value.substr(0, static_cast<std::size_t>(max_width - 3)) + "...";
}

std::string trim_ascii_art_line(const std::string& value, int max_width) {
    std::size_t end = value.find_last_not_of(' ');
    std::string trimmed = end == std::string::npos ? "" : value.substr(0, end + 1U);
    if (max_width <= 0) {
        return "";
    }
    if (static_cast<int>(trimmed.size()) <= max_width) {
        return trimmed;
    }
    return trimmed.substr(0, static_cast<std::size_t>(max_width));
}

void apply_pair(int pair) {
    if (has_colors() && pair > 0) {
        attron(COLOR_PAIR(pair));
    }
}

void clear_pair(int pair) {
    if (has_colors() && pair > 0) {
        attroff(COLOR_PAIR(pair));
    }
}


void render_menu_option(
    int row,
    int col,
    const std::string& label,
    bool selected,
    int max_width,
    int inactive_pair
) {
    const std::string rendered = max_width >= 0
        ? trim_for_render(label, std::max(0, max_width - 2))
        : label;
    const int pair = selected ? kColorSelection : inactive_pair;
    if (pair > 0) {
        apply_pair(pair);
    }
    mvprintw(row, col, "%s%s", selected ? "> " : "  ", rendered.c_str());
    if (pair > 0) {
        clear_pair(pair);
    }
}

void present_screen() {
    wnoutrefresh(stdscr);
    doupdate();
}

void reset_screen_canvas() {
    attrset(A_NORMAL);
    clearok(stdscr, TRUE);
    clear();
    erase();
}

int render_main_banner(int start_row, int max_rows) {
    static const std::array<const char*, 5> kBanner = {
        " ______     __  __     __   __     ______     ______   ______     ______    ",
        "/\\  ___\\   /\\ \\_\\ \\   /\\ \"-.\\ \\   /\\  ___\\   /\\  == \\ /\\  ___\\   /\\  ___\\   ",
        "\\ \\___  \\  \\ \\____ \\  \\ \\ \\-.  \\  \\ \\ \\____  \\ \\  _-/ \\ \\___  \\  \\ \\___  \\  ",
        " \\/\\_____\\  \\/\\_____\\  \\ \\_\\\\\"\\_\\  \\ \\_____\\  \\ \\_\\    \\/\\_____\\  \\/\\_____\\ ",
        "  \\/_____/   \\/_____/   \\/_/ \\/_/   \\/_____/   \\/_/     \\/_____/   \\/_____/ "
    };

    static const std::array<int, 5> kBannerColors = {
        kColorHeader, kColorFrosting, kColorAccount, kColorSite, kColorDim
    };

    const int draw_limit = std::max(0, max_rows);
    int drawn = 0;
    std::array<std::string, 5> rendered_lines{};
    int max_visible_width = 0;
    for (std::size_t index = 0; index < kBanner.size(); ++index) {
        rendered_lines[index] = trim_ascii_art_line(kBanner[index], COLS - 4);
        max_visible_width = std::max(max_visible_width, static_cast<int>(rendered_lines[index].size()));
    }
    const int banner_column = std::max(2, (COLS - max_visible_width) / 2);

    attron(A_BOLD);
    for (std::size_t index = 0; index < kBanner.size(); ++index) {
        if (drawn >= draw_limit) {
            break;
        }
        const std::string& line = rendered_lines[index];
        if (line.empty()) {
            continue;
        }
        apply_pair(kBannerColors[index]);
        mvprintw(start_row + static_cast<int>(index), banner_column, "%s", line.c_str());
        clear_pair(kBannerColors[index]);
        ++drawn;
    }
    attroff(A_BOLD);
    return drawn;
}

void render_donut_frame(
    double angle_a,
    double angle_b,
    int loading_phase,
    const std::string& loading_base,
    const std::string& detail_line,
    double progress_fraction,
    const std::string& prompt_line,
    bool animate_loading
) {
    constexpr int kSourceWidth = 80;
    constexpr int kSourceHeight = 22;
    std::array<float, kSourceWidth * kSourceHeight> depth{};
    std::array<char, kSourceWidth * kSourceHeight> buffer{};
    std::array<int, kSourceWidth * kSourceHeight> color_index{};
    buffer.fill(' ');
    color_index.fill(kColorDim);

    for (double j = 0.0; j < 6.28; j += 0.07) {
        for (double i = 0.0; i < 6.28; i += 0.02) {
            const double c = std::sin(i);
            const double d = std::cos(j);
            const double e = std::sin(angle_a);
            const double f = std::sin(j);
            const double g = std::cos(angle_a);
            const double h = d + 2.0;
            const double reciprocal = 1.0 / (c * h * e + f * g + 5.0);
            const double l = std::cos(i);
            const double m = std::cos(angle_b);
            const double n = std::sin(angle_b);
            const double t = c * h * g - f * e;

            const int x = static_cast<int>(40.0 + 30.0 * reciprocal * (l * h * m - t * n));
            const int y = static_cast<int>(12.0 + 15.0 * reciprocal * (l * h * n + t * m));
            if (x <= 0 || x >= kSourceWidth || y <= 0 || y >= kSourceHeight) {
                continue;
            }

            const int offset = x + kSourceWidth * y;
            const int luminance = static_cast<int>(8.0 * ((f * e - c * d * g) * m - c * d * e - f * g - l * d * n));
            if (reciprocal > depth[static_cast<std::size_t>(offset)]) {
                depth[static_cast<std::size_t>(offset)] = static_cast<float>(reciprocal);
                static const std::string kRamp = ".,-~:;=!*#$@";
                const int ramp_index = std::clamp(luminance, 0, static_cast<int>(kRamp.size()) - 1);
                buffer[static_cast<std::size_t>(offset)] = kRamp[static_cast<std::size_t>(ramp_index)];
                const bool frosting = f >= 0.0;
                int pair =
                    ramp_index <= 2 ? kColorDim :
                    frosting ? kColorFrosting : kColorDough;
                if (frosting && ((y * 17 + x * 11 + loading_phase) % 29 == 0)) {
                    switch ((y + x + loading_phase) % 3) {
                        case 0:
                            pair = kColorSprinkleBlue;
                            break;
                        case 1:
                            pair = kColorSprinkleYellow;
                            break;
                        default:
                            pair = kColorSprinkleGreen;
                            break;
                    }
                }
                color_index[static_cast<std::size_t>(offset)] = pair;
            }
        }
    }

    const int available_width = std::max(0, COLS - 4);
    const int available_height = std::max(0, LINES - 8);
    const int render_width = std::min(kSourceWidth, available_width);
    const int render_height = std::min(kSourceHeight, available_height);
    const int source_x = std::max(0, (kSourceWidth - render_width) / 2);
    const int source_y = std::max(0, (kSourceHeight - render_height) / 2);
    const bool show_detail = !detail_line.empty();
    const bool show_progress = progress_fraction >= 0.0;
    const bool show_prompt = !prompt_line.empty();
    const int block_height = render_height + 5 + (show_detail ? 1 : 0) + (show_progress ? 1 : 0) + (show_prompt ? 1 : 0);
    const int title_row = std::max(1, (LINES - block_height) / 2);
    const int subtitle_row = title_row + 1;
    const int top = subtitle_row + 2;
    const int left = std::max(2, (COLS - render_width) / 2);
    const int loading_row = std::min(LINES - 2, top + render_height + 1);

    erase();
    box(stdscr, 0, 0);
    apply_pair(kColorHeader);
    attron(A_BOLD);
    mvprintw(title_row, std::max(2, (COLS - 7) / 2), "syncpss");
    attroff(A_BOLD);
    clear_pair(kColorHeader);
    apply_pair(kColorDim);
    mvprintw(subtitle_row, std::max(2, (COLS - 33) / 2), "warming up secure password space");
    clear_pair(kColorDim);

    for (int row = 0; row < render_height; ++row) {
        const int source_row = source_y + row;
        for (int column = 0; column < render_width; ++column) {
            const int source_column = source_x + column;
            const std::size_t offset = static_cast<std::size_t>(source_row * kSourceWidth + source_column);
            const int pair = color_index[offset];
            if (buffer[offset] == ' ') {
                mvaddch(top + row, left + column, ' ');
                continue;
            }
            apply_pair(pair);
            mvaddch(top + row, left + column, static_cast<unsigned char>(buffer[offset]));
            clear_pair(pair);
        }
    }

    const int dot_count = 1 + (loading_phase % 3);
    const std::string loading_full = loading_base + (animate_loading ? "..." : "");
    const int loading_col = std::max(2, (COLS - static_cast<int>(loading_full.size())) / 2);
    apply_pair(kColorFrosting);
    mvhline(loading_row, 2, ' ', std::max(0, COLS - 4));
    mvprintw(loading_row, loading_col, "%s", loading_base.c_str());
    if (animate_loading) {
        mvhline(loading_row, loading_col + static_cast<int>(loading_base.size()), ' ', 3);
        mvprintw(
            loading_row,
            loading_col + static_cast<int>(loading_base.size()),
            "%s",
            std::string(static_cast<std::size_t>(dot_count), '.').c_str()
        );
    }
    clear_pair(kColorFrosting);

    int status_row = loading_row + 1;
    if (show_detail && status_row < LINES - 1) {
        apply_pair(kColorHeader);
        mvhline(status_row, 2, ' ', std::max(0, COLS - 4));
        mvprintw(status_row, std::max(2, (COLS - static_cast<int>(detail_line.size())) / 2), "%s", detail_line.c_str());
        clear_pair(kColorHeader);
        ++status_row;
    }

    if (show_progress && status_row < LINES - 1) {
        const int bar_width = std::max(10, std::min(COLS - 20, 36));
        const int filled = std::clamp(static_cast<int>(std::round(progress_fraction * static_cast<double>(bar_width))), 0, bar_width);
        const std::string progress_bar =
            "[" + std::string(static_cast<std::size_t>(filled), '=') +
            std::string(static_cast<std::size_t>(bar_width - filled), '-') + "]";
        apply_pair(kColorAccount);
        mvhline(status_row, 2, ' ', std::max(0, COLS - 4));
        mvprintw(status_row, std::max(2, (COLS - static_cast<int>(progress_bar.size())) / 2), "%s", progress_bar.c_str());
        clear_pair(kColorAccount);
        ++status_row;
    }

    if (show_prompt && status_row < LINES - 1) {
        apply_pair(kColorDim);
        mvhline(status_row, 2, ' ', std::max(0, COLS - 4));
        mvprintw(status_row, std::max(2, (COLS - static_cast<int>(prompt_line.size())) / 2), "%s", prompt_line.c_str());
        clear_pair(kColorDim);
    }
}

}  // namespace syncpss::tui::detail
