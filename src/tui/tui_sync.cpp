#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

namespace {

enum class ReviewChoice {
    None,
    KeepLocal,
    KeepRemote,
    Edited
};

std::vector<std::string> wrap_text_lines(const std::string& value, int width) {
    std::vector<std::string> lines;
    const int effective_width = std::max(1, width);
    std::stringstream input(value.empty() ? std::string("(no diff for this side)") : value);
    std::string line;
    while (std::getline(input, line)) {
        if (line.empty()) {
            lines.emplace_back();
            continue;
        }
        std::size_t offset = 0;
        while (offset < line.size()) {
            lines.push_back(line.substr(offset, static_cast<std::size_t>(effective_width)));
            offset += static_cast<std::size_t>(effective_width);
        }
    }
    if (lines.empty()) {
        lines.emplace_back("(no diff for this side)");
    }
    return lines;
}

const char* review_choice_label(ReviewChoice choice) {
    switch (choice) {
        case ReviewChoice::KeepLocal:
            return "Keep local";
        case ReviewChoice::KeepRemote:
            return "Accept remote";
        case ReviewChoice::Edited:
            return "Edited";
        default:
            return "Pending";
    }
}

}  // namespace

syncpss::git::SyncReport TuiApp::run_sync_operation(
    const std::string& title,
    const std::string& waiting_line,
    const std::function<syncpss::git::SyncReport(const syncpss::git::GitClient::LogCallback&)>& operation
) {
    std::mutex log_mutex;
    std::vector<std::string> live_logs = {"Preparing secure sync operation..."};
    std::optional<syncpss::git::SyncReport> report;
    std::exception_ptr worker_error;

    auto push_live_log = [&](const std::string& line) {
        std::lock_guard<std::mutex> lock(log_mutex);
        live_logs.push_back(line);
    };

    std::future<void> task_future = std::async(std::launch::async, [&]() {
        try {
            report = operation(push_live_log);
        } catch (...) {
            worker_error = std::current_exception();
        }
    });

    static const std::array<const char*, 4> kSpinner = {"|", "/", "-", "\\"};
    std::size_t spinner_index = 0;
    timeout(100);

    while (task_future.wait_for(std::chrono::milliseconds(0)) != std::future_status::ready) {
        if (getch() == KEY_RESIZE) {
            handle_resize();
        }

        erase();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "%s %s", title.c_str(), kSpinner[spinner_index]);
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        spinner_index = (spinner_index + 1U) % kSpinner.size();

        apply_pair(kColorDim);
        mvprintw(3, 2, "%s", trim_for_render(waiting_line, COLS - 4).c_str());
        clear_pair(kColorDim);

        std::vector<std::string> snapshot;
        {
            std::lock_guard<std::mutex> lock(log_mutex);
            snapshot = live_logs;
        }

        const int log_top = 5;
        const int log_height = std::max(3, LINES - 8);
        const int first_line = std::max(0, static_cast<int>(snapshot.size()) - log_height);
        for (int row = 0; row < log_height && first_line + row < static_cast<int>(snapshot.size()); ++row) {
            const std::string rendered = trim_for_render(snapshot[static_cast<std::size_t>(first_line + row)], COLS - 6);
            mvprintw(log_top + row, 3, "%s", rendered.c_str());
        }

        apply_pair(kColorSearch);
        mvprintw(LINES - 2, 2, "Please wait. This screen will return automatically when complete.");
        clear_pair(kColorSearch);
        present_screen();
    }

    timeout(-1);
    task_future.get();

    if (worker_error) {
        std::rethrow_exception(worker_error);
    }
    if (!report.has_value()) {
        throw std::runtime_error("Sync operation did not return a result");
    }
    return *report;
}

void TuiApp::sync_menu() {
    const std::vector<std::string> items = {
        "[s] Sync",
        "[p] Push",
        "[l] Pull",
        "[f] Fetch",
        "[n] Nuke",
        "Back"
    };
    int selected = 0;

    while (true) {
        erase();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "Sync");
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        mvprintw(3, 2, "Choose how this password-store should interact with its remote branch.");
        mvprintw(4, 2, "Push force-overwrites remote history. Pull force-resets local history.");

        for (std::size_t index = 0; index < items.size(); ++index) {
            render_menu_option(6 + static_cast<int>(index), 4, items[index], static_cast<int>(index) == selected, COLS - 6);
        }
        mvprintw(LINES - 2, 2, "[Up/Down] navigate  [Enter] select  [Esc] back");
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
            selected = (selected - 1 + static_cast<int>(items.size())) % static_cast<int>(items.size());
            continue;
        }
        if (ch == KEY_DOWN || ch == 'j') {
            selected = (selected + 1) % static_cast<int>(items.size());
            continue;
        }

        int chosen = -1;
        if (ch == 's' || ch == 'S') {
            chosen = 0;
        } else if (ch == 'p' || ch == 'P') {
            chosen = 1;
        } else if (ch == 'l' || ch == 'L') {
            chosen = 2;
        } else if (ch == 'f' || ch == 'F') {
            chosen = 3;
        } else if (ch == 'n' || ch == 'N') {
            chosen = 4;
        } else if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            chosen = selected;
        }

        if (chosen < 0) {
            continue;
        }
        if (chosen == 5) {
            return;
        }

        switch (chosen) {
            case 0:
                sync_store();
                break;
            case 1:
                push_store_force();
                break;
            case 2:
                pull_store_force();
                break;
            case 3:
                fetch_store_preview();
                break;
            case 4:
                nuke_store();
                break;
            default:
                break;
        }
    }
}

bool TuiApp::review_sync_preview(
    const syncpss::git::SyncPreview& preview,
    bool preview_only,
    const std::string& title
) {
    if (preview.files.empty()) {
        show_message(title, {"No file-level differences were found."}, kColorSuccess);
        return true;
    }

    std::vector<ReviewChoice> choices(preview.files.size(), ReviewChoice::None);
    std::vector<int> scroll_offsets(preview.files.size(), 0);
    int selected = 0;

    while (true) {
        const std::vector<std::string> active_conflicts = preview_only ? std::vector<std::string>{} : git_->conflict_paths();
        const auto is_conflicted = [&](const std::string& path) {
            return std::find(active_conflicts.begin(), active_conflicts.end(), path) != active_conflicts.end();
        };
        const syncpss::git::ConflictFilePreview& file = preview.files[static_cast<std::size_t>(selected)];
        const bool conflicted = is_conflicted(file.path);

        const int pane_width = std::max(20, (COLS - 8) / 2);
        const int body_top = 7;
        const int body_height = std::max(6, LINES - body_top - 4);
        const std::vector<std::string> local_lines = wrap_text_lines(file.local_diff, pane_width - 1);
        const std::vector<std::string> remote_lines = wrap_text_lines(file.remote_diff, pane_width - 1);
        const int max_scroll = std::max(
            0,
            std::max(static_cast<int>(local_lines.size()), static_cast<int>(remote_lines.size())) - body_height
        );
        scroll_offsets[static_cast<std::size_t>(selected)] =
            std::clamp(scroll_offsets[static_cast<std::size_t>(selected)], 0, max_scroll);

        erase();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "%s", title.c_str());
        attroff(A_BOLD);
        clear_pair(kColorHeader);

        mvprintw(
            2,
            2,
            "File %d/%d: %s",
            selected + 1,
            static_cast<int>(preview.files.size()),
            trim_for_render(file.path, COLS - 18).c_str()
        );
        const std::string category =
            file.changed_locally && file.changed_remotely ? "Local + remote"
            : file.changed_locally ? "Local only"
            : "Remote only";
        const std::string status = conflicted
            ? "Conflict"
            : std::string(review_choice_label(choices[static_cast<std::size_t>(selected)]));
        mvprintw(3, 2, "Status: %s   Scope: %s", status.c_str(), category.c_str());
        mvprintw(4, 2, "Overlap: %zu   Remote-only: %zu   Local-only: %zu",
            preview.overlapping_paths.size(),
            preview.remote_only_paths.size(),
            preview.local_only_paths.size());

        apply_pair(kColorAccount);
        mvprintw(5, 3, "Local / keep");
        clear_pair(kColorAccount);
        apply_pair(kColorSite);
        mvprintw(5, 5 + pane_width, "Remote / accept");
        clear_pair(kColorSite);
        mvaddch(5, 4 + pane_width, ACS_VLINE);

        for (int row = 0; row < body_height; ++row) {
            const int line_index = scroll_offsets[static_cast<std::size_t>(selected)] + row;
            const std::string left = line_index < static_cast<int>(local_lines.size())
                ? trim_for_render(local_lines[static_cast<std::size_t>(line_index)], pane_width - 1)
                : "";
            const std::string right = line_index < static_cast<int>(remote_lines.size())
                ? trim_for_render(remote_lines[static_cast<std::size_t>(line_index)], pane_width - 1)
                : "";
            mvprintw(body_top + row, 3, "%-*s", pane_width - 1, left.c_str());
            mvaddch(body_top + row, 4 + pane_width, ACS_VLINE);
            mvprintw(body_top + row, 5 + pane_width, "%-*s", pane_width - 1, right.c_str());
        }

        if (preview_only) {
            mvprintw(LINES - 2, 2, "[Left/Right] file  [j/k] scroll  [q] back");
        } else {
            mvprintw(
                LINES - 2,
                2,
                "[Left/Right] file  [Up] accept remote  [Down] keep local  [e] edit  [j/k] scroll  [Enter] continue  [q] abort"
            );
        }
        present_screen();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == KEY_LEFT || ch == 'h') {
            selected = (selected - 1 + static_cast<int>(preview.files.size())) % static_cast<int>(preview.files.size());
            continue;
        }
        if (ch == KEY_RIGHT || ch == 'l') {
            selected = (selected + 1) % static_cast<int>(preview.files.size());
            continue;
        }
        if (ch == 'j') {
            scroll_offsets[static_cast<std::size_t>(selected)] =
                std::min(max_scroll, scroll_offsets[static_cast<std::size_t>(selected)] + 1);
            continue;
        }
        if (ch == 'k') {
            scroll_offsets[static_cast<std::size_t>(selected)] =
                std::max(0, scroll_offsets[static_cast<std::size_t>(selected)] - 1);
            continue;
        }

        if (preview_only) {
            if (ch == 'q' || ch == 'Q' || ch == 27 || ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
                return true;
            }
            continue;
        }

        if (ch == KEY_UP) {
            git_->resolve_conflict(file.path, syncpss::git::ConflictChoice::KeepRemote);
            choices[static_cast<std::size_t>(selected)] = ReviewChoice::KeepRemote;
            continue;
        }
        if (ch == KEY_DOWN) {
            git_->resolve_conflict(file.path, syncpss::git::ConflictChoice::KeepLocal);
            choices[static_cast<std::size_t>(selected)] = ReviewChoice::KeepLocal;
            continue;
        }
        if (ch == 'e' || ch == 'E') {
            open_sync_editor(file.path);
            git_->stage_file(file.path);
            choices[static_cast<std::size_t>(selected)] = ReviewChoice::Edited;
            continue;
        }
        if (ch == 'q' || ch == 'Q' || ch == 27) {
            return false;
        }
        if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
            if (git_->has_unmerged_conflicts()) {
                show_message(
                    title,
                    {
                        "There are still unresolved merge conflicts.",
                        "Use [Up], [Down], or [e] on each conflicted file before continuing."
                    },
                    kColorError
                );
                continue;
            }
            return true;
        }
    }
}

void TuiApp::open_sync_editor(const std::string& path) {
    ensure_dependencies({"nano"});
    const std::filesystem::path absolute_path = config_->store_path / path;
    with_terminal_handoff([&]() {
        const int exit_code = syncpss::util::run_passthrough(
            {"nano", absolute_path.string()},
            syncpss::util::ProcessOptions{config_->store_path.string()}
        );
        if (exit_code != 0) {
            throw std::runtime_error("nano exited with status " + std::to_string(exit_code));
        }
    });
}

void TuiApp::resolve_conflicts(const std::vector<std::string>& conflicts) {
    for (const std::string& path : conflicts) {
        int selected = 0;
        const std::vector<std::string> options = {"Keep local version", "Keep remote version", "Abort sync"};
        while (true) {
            clear();
            box(stdscr, 0, 0);
            mvprintw(1, 2, "Merge conflict detected in: %s", trim_for_render(path, COLS - 32).c_str());
            for (std::size_t index = 0; index < options.size(); ++index) {
                const int row = 3 + static_cast<int>(index);
                render_menu_option(row, 4, options[index], static_cast<int>(index) == selected, COLS - 6);
            }
            refresh();

            const int ch = getch();
            if (ch == KEY_RESIZE) {
                handle_resize();
            } else if (ch == KEY_UP || ch == 'k') {
                selected = (selected - 1 + static_cast<int>(options.size())) % static_cast<int>(options.size());
            } else if (ch == KEY_DOWN || ch == 'j') {
                selected = (selected + 1) % static_cast<int>(options.size());
            } else if (ch == '\n' || ch == '\r' || ch == KEY_ENTER) {
                if (selected == 0) {
                    git_->resolve_conflict(path, syncpss::git::ConflictChoice::KeepLocal);
                    break;
                }
                if (selected == 1) {
                    git_->resolve_conflict(path, syncpss::git::ConflictChoice::KeepRemote);
                    break;
                }
                git_->resolve_conflict(path, syncpss::git::ConflictChoice::Abort);
                throw std::runtime_error("Sync aborted for manual resolution");
            }
        }
    }
    git_->finalize_merge_commit();
}

void TuiApp::sync_store() {
    ensure_dependencies({"git"});

    const syncpss::git::SyncReport preview_report = run_sync_operation(
        "Sync Preview",
        "Fetching remote updates and comparing local changes...",
        [this](const syncpss::git::GitClient::LogCallback& log_callback) { return git_->fetch_preview(log_callback); }
    );

    if (!preview_report.preview.overlapping_paths.empty()) {
        const syncpss::git::SyncReport prepared = run_sync_operation(
            "Sync Prep",
            "Committing local changes and preparing interactive review...",
            [this](const syncpss::git::GitClient::LogCallback& log_callback) { return git_->prepare_sync(log_callback); }
        );
        git_->start_merge_from_origin();
        if (!review_sync_preview(prepared.preview, false, "Sync Review")) {
            if (git_->has_merge_in_progress()) {
                git_->abort_merge();
            }
            show_message(
                "Sync Cancelled",
                {
                    "Merge review was cancelled.",
                    "The merge was aborted, but any local sync commit created during preparation was kept."
                }
            );
            return;
        }
        git_->finalize_merge_commit(prepared.store_version);
        show_message(
            "Sync",
            {
                "Interactive sync review completed.",
                "Merged local and remote changes into " + config_->repo_branch + ".",
                "Resolved content was pushed to origin/" + config_->repo_branch + "."
            },
            kColorSuccess
        );
        return;
    }

    const syncpss::git::SyncReport report = run_sync_operation(
        "Sync in Progress",
        "Pulling remote changes and pushing local updates...",
        [this](const syncpss::git::GitClient::LogCallback& log_callback) { return git_->sync(log_callback); }
    );

    if (report.had_conflicts) {
        if (!report.preview.files.empty()) {
            if (!review_sync_preview(report.preview, false, "Sync Review")) {
                if (git_->has_merge_in_progress()) {
                    git_->abort_merge();
                }
                show_message(
                    "Sync Cancelled",
                    {
                        "Merge review was cancelled.",
                        "The merge was aborted, but any local sync commit created before the pull was kept."
                    }
                );
                return;
            }
            git_->finalize_merge_commit(report.store_version);
            show_message(
                "Sync",
                {
                    "Interactive sync review completed.",
                    "Resolved content was pushed to origin/" + config_->repo_branch + "."
                },
                kColorSuccess
            );
            return;
        }
        resolve_conflicts(report.conflicts);
    }
    show_message("Sync", report.log_lines, kColorSuccess);
}

void TuiApp::push_store_force() {
    ensure_dependencies({"git"});
    if (!confirm_with_text(
            "Force push will overwrite remote history. Any remote-only changes can be lost.",
            "FORCE")) {
        show_message("Cancelled", {"Force push cancelled."});
        return;
    }

    const syncpss::git::SyncReport report = run_sync_operation(
        "Force Push",
        "Force pushing the local password-store branch...",
        [this](const syncpss::git::GitClient::LogCallback& log_callback) { return git_->push_force(log_callback); }
    );
    show_message("Push", report.log_lines, kColorSuccess);
}

void TuiApp::pull_store_force() {
    ensure_dependencies({"git"});
    if (!confirm_with_text(
            "Force pull will discard local committed and uncommitted changes by resetting to the remote branch.",
            "PULL")) {
        show_message("Cancelled", {"Force pull cancelled."});
        return;
    }

    const syncpss::git::SyncReport report = run_sync_operation(
        "Force Pull",
        "Resetting the local password-store branch to origin...",
        [this](const syncpss::git::GitClient::LogCallback& log_callback) { return git_->pull_force(log_callback); }
    );
    show_message("Pull", report.log_lines, kColorSuccess);
}

void TuiApp::fetch_store_preview() {
    ensure_dependencies({"git"});
    const syncpss::git::SyncReport report = run_sync_operation(
        "Fetch",
        "Fetching remote updates and preparing a review preview...",
        [this](const syncpss::git::GitClient::LogCallback& log_callback) { return git_->fetch_preview(log_callback); }
    );

    if (report.preview.files.empty()) {
        show_message(
            "Fetch",
            {
                "Local and remote are already aligned.",
                "No out-of-sync files were found."
            },
            kColorSuccess
        );
        return;
    }

    review_sync_preview(report.preview, true, "Fetch Preview");
}

void TuiApp::nuke_store() {
    ensure_dependencies({"git"});
    const std::string remote_answer = prompt_input(
        "Nuke",
        "Also wipe the current remote branch after deleting local passwords? [y/N]",
        "N"
    );
    const bool include_remote = answer_is_yes(remote_answer, false);
    if (!confirm_with_text(
            include_remote
                ? "This will delete all local password entries and force-push the wiped branch to the remote."
                : "This will delete all local password entries from the current password store.",
            "DELETE")) {
        show_message("Cancelled", {"Nuke cancelled."});
        return;
    }

    const syncpss::git::SyncReport report = run_sync_operation(
        "Nuke",
        include_remote
            ? "Deleting local password entries and force-updating the remote branch..."
            : "Deleting local password entries...",
        [this, include_remote](const syncpss::git::GitClient::LogCallback& log_callback) {
            return git_->nuke_passwords(include_remote, log_callback);
        }
    );
    show_message("Nuke", report.log_lines, kColorSuccess);
}

void TuiApp::uninstall_flow() {
    const std::vector<std::string> items = {
        "Remove ~/.password-store",
        "Remove ~/.syncpss runtime data",
        "Remove /usr/local/bin syncpss + syncpass",
        "Remove ~/.gnupg",
        "Remove /etc/syncpass",
        "Remove /mnt/keys",
        "Uninstall pass",
        "Full cleanup",
        "Back"
    };
    int selected = 0;

    while (true) {
        clear();
        box(stdscr, 0, 0);
        mvprintw(1, 2, "Uninstall");
        mvprintw(2, 2, "Typed DELETE confirmation is required for destructive actions.");

        for (std::size_t index = 0; index < items.size(); ++index) {
            const int row = 4 + static_cast<int>(index);
            render_menu_option(row, 2, items[index], static_cast<int>(index) == selected, COLS - 4);
        }
        refresh();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
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
        if (selected == 8) {
            return;
        }
        if (!confirm_with_text("This action is destructive.", "DELETE")) {
            show_message("Cancelled", {"Uninstall operation cancelled."});
            continue;
        }

        const auto remove_home_dir = [](const std::filesystem::path& path) {
            if (!syncpss::util::is_safe_recursive_delete_target(path)) {
                throw std::runtime_error("Refusing to recursively delete unsafe path: " + path.string());
            }
            if (std::filesystem::exists(path)) {
                std::filesystem::remove_all(path);
            }
        };

        if (selected == 0 || selected == 7) {
            remove_home_dir(syncpss::util::default_store_path());
        }
        const auto remove_managed_system_path = [](const std::filesystem::path& path) {
            const std::string rendered = path.lexically_normal().string();
            if (rendered != "/etc/syncpass" &&
                rendered != "/usr/local/bin/syncpss" &&
                rendered != "/usr/local/bin/syncpass") {
                throw std::runtime_error("Refusing to delete unmanaged system path: " + rendered);
            }
            std::error_code ignored;
            std::filesystem::remove_all(path, ignored);
            std::filesystem::remove(path, ignored);
        };

        if (selected == 1 || selected == 7) {
            remove_home_dir(syncpss::util::default_install_root());
        }
        if (selected == 2 || selected == 7) {
            remove_managed_system_path(syncpss::util::binary_install_path("syncpss"));
            remove_managed_system_path(syncpss::util::binary_install_path("syncpass"));
        }
        if (selected == 3 || selected == 7) {
            remove_home_dir(syncpss::util::get_real_home() / ".gnupg");
        }
        if (selected == 4 || selected == 7) {
            remove_managed_system_path(syncpss::util::config_directory());
        }
        if (selected == 5 || selected == 7) {
            const std::filesystem::path mount_point = "/mnt/keys";
            if (std::filesystem::exists(mount_point)) {
                std::filesystem::remove_all(mount_point);
            }
        }
        if (selected == 6 || selected == 7) {
            syncpss::util::ProcessResult result = syncpss::util::run({"apt-get", "purge", "-y", "pass"});
            if (result.exit_code != 0) {
                throw std::runtime_error("apt-get purge pass failed: " + result.stderr_output);
            }
        }
        show_message("Uninstall", {"Requested cleanup completed."}, kColorSuccess);
    }
}

}  // namespace syncpss::tui
