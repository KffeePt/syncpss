#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

void TuiApp::update_to_latest_version(bool skip_confirmation) {
    using clock = std::chrono::steady_clock;

    refresh_latest_release_info(true);

    bool latest_release_checked = false;
    bool latest_release_update_available = false;
    std::string latest_release_version;
    std::string latest_release_error;
    {
        std::lock_guard<std::mutex> lock(latest_release_mutex_);
        latest_release_checked = latest_release_checked_;
        latest_release_update_available = latest_release_update_available_;
        latest_release_version = latest_release_version_;
        latest_release_error = latest_release_error_;
    }

    if (!latest_release_checked || !latest_release_error.empty()) {
        show_message(
            "Update",
            {
                "Could not check the latest syncpss release.",
                latest_release_error.empty() ? "Try again in a moment." : latest_release_error
            },
            kColorError
        );
        return;
    }

    const std::string local_label = format_release_version(syncpss_version());
    const std::string latest_label = format_release_version(latest_release_version);
    if (!latest_release_update_available) {
        show_message(
            "Update",
            {
                "You are already on the latest syncpss release.",
                "Local version: " + local_label,
                "Latest release: " + latest_label
            },
            kColorSuccess
        );
        return;
    }

    syncpss::util::RuntimeConfig runtime = runtime_config_.value_or(syncpss::util::RuntimeConfig{});
    if (!runtime_config_.has_value() && config_.has_value()) {
        runtime.github_repo = github_repo_from_url(config_->repo_url);
        runtime.github_repo_name = repo_name_from_repo_id(runtime.github_repo);
        runtime.gpg_key_id = config_->gpg_key_id;
        runtime.store_path = config_->store_path;
        runtime.store_branch = config_->repo_branch;
        runtime.ssh_key_path = syncpss::util::get_real_home() / ".ssh" / "syncpss_ed25519";
        runtime.install_binary = syncpss::util::binary_install_path("syncpss");
        runtime.install_config_dir = syncpss::util::config_directory();
        runtime.install_distro = current_distro_name();
        runtime.install_version = syncpss_version();
    }

    if (runtime.github_repo.empty() || runtime.gpg_key_id.empty()) {
        show_message(
            "Update",
            {
                "syncpss is missing the runtime metadata needed for an in-app update.",
                "Run the setup wizard again, then retry the update."
            },
            kColorError
        );
        return;
    }
    if (runtime.store_path.empty()) {
        runtime.store_path = syncpss::util::default_store_path();
    }
    if (runtime.store_branch.empty()) {
        runtime.store_branch = "main";
    }
    if (runtime.install_binary.empty()) {
        runtime.install_binary = syncpss::util::binary_install_path("syncpss");
    }

    if (!skip_confirmation) {
        const std::string answer = prompt_input(
            "Update syncpss",
            "Update from " + local_label + " to " + latest_label + "? [Y/n]",
            "Y"
        );
        if (!answer_is_yes(answer, true)) {
            return;
        }
    }

    try {
        const std::filesystem::path temp_dir = syncpss::util::create_secure_temp_directory("syncpss-update");
        const std::filesystem::path helper_path = temp_dir / kInstallerAsset;
        const std::filesystem::path helper_checksum_path = temp_dir / kInstallerChecksumAsset;

        syncpss::util::ProcessResult helper_download;
        syncpss::util::ProcessResult checksum_download;
        if (syncpss::util::is_command_available("curl")) {
            helper_download = syncpss::util::run(
                {"curl", "-fsSL", latest_release_asset_url(kInstallerAsset), "-o", helper_path.string()}
            );
            checksum_download = syncpss::util::run(
                {"curl", "-fsSL", latest_release_asset_url(kInstallerChecksumAsset), "-o", helper_checksum_path.string()}
            );
        } else if (syncpss::util::is_command_available("gh")) {
            helper_download = syncpss::util::run(
                {
                    "gh",
                    "release",
                    "download",
                    "-R",
                    std::string(kRepoOwner) + "/" + std::string(kRepoName),
                    "--pattern",
                    kInstallerAsset,
                    "--pattern",
                    kInstallerChecksumAsset,
                    "--dir",
                    temp_dir.string(),
                    "--clobber"
                }
            );
            checksum_download.exit_code = helper_download.exit_code;
            checksum_download.stderr_output = helper_download.stderr_output;
        } else {
            throw std::runtime_error("Need curl or gh installed to download the latest updater.");
        }

        if (helper_download.exit_code != 0) {
            throw std::runtime_error("Failed to download the latest installer helper: " + helper_download.stderr_output);
        }
        if (checksum_download.exit_code != 0) {
            throw std::runtime_error("Failed to download the installer checksum: " + checksum_download.stderr_output);
        }

        if (first_checksum_token(helper_checksum_path) != sha256_for_file(helper_path)) {
            throw std::runtime_error("Checksum verification failed for the downloaded installer helper.");
        }

        std::error_code ignored;
        std::filesystem::permissions(
            helper_path,
            std::filesystem::perms::owner_all,
            std::filesystem::perm_options::replace,
            ignored
        );

        std::map<std::string, std::string> env = {
            {"SYNCPSS_FORCE_INSTALL", "1"},
            {"SYNCPSS_UPDATE_GITHUB_REPO", runtime.github_repo},
            {"SYNCPSS_UPDATE_GPG_KEY_ID", runtime.gpg_key_id},
            {"SYNCPSS_UPDATE_STORE_PATH", runtime.store_path.string()},
            {"SYNCPSS_UPDATE_BRANCH", runtime.store_branch}
        };
        if (!runtime.github_username.empty()) {
            env["SYNCPSS_UPDATE_GITHUB_USER"] = runtime.github_username;
        }
        if (!runtime.github_email.empty()) {
            env["SYNCPSS_UPDATE_GITHUB_EMAIL"] = runtime.github_email;
        }

        render_donut_frame(
            0.0,
            0.0,
            0,
            "Loading updater",
            "Installing " + latest_label,
            1.0,
            "Installer output is running in your terminal",
            false
        );
        present_screen();

        const int update_exit = with_terminal_handoff([&]() {
            return syncpss::util::run_passthrough(
                {"bash", helper_path.string(), "update"},
                syncpss::util::ProcessOptions(temp_dir.string(), env)
            );
        });
        if (update_exit != 0) {
            throw std::runtime_error("The update helper exited with code " + std::to_string(update_exit) + ".");
        }

        if (syncpss::util::runtime_config_exists()) {
            runtime_config_ = syncpss::util::load_runtime_config();
            config_ = syncpss::util::to_app_config(*runtime_config_);
            rebuild_clients();
        }

        {
            std::lock_guard<std::mutex> lock(latest_release_mutex_);
            latest_release_checked_ = true;
            latest_release_check_in_progress_ = false;
            latest_release_version_ = latest_release_version;
            latest_release_update_available_ = false;
            latest_release_error_.clear();
        }

        const clock::time_point restart_start = clock::now();
        const clock::time_point restart_deadline = clock::now() + std::chrono::seconds(3);
        double angle_a = 0.0;
        double angle_b = 0.0;
        int loading_phase = 0;
        timeout(0);
        while (clock::now() < restart_deadline) {
            const int ch = getch();
            if (ch == KEY_RESIZE) {
                resize_term(0, 0);
                clearok(stdscr, TRUE);
            }

            const double elapsed = std::chrono::duration<double>(clock::now() - restart_start).count();
            render_donut_frame(
                angle_a,
                angle_b,
                loading_phase,
                "Loading updated TUI",
                "Update installed successfully: " + latest_label,
                std::clamp(elapsed / 3.0, 0.0, 1.0),
                "Restarting syncpss in 3 seconds",
                false
            );
            present_screen();
            angle_a += 0.04;
            angle_b += 0.02;
            ++loading_phase;
            napms(30);
        }
        timeout(-1);

        const std::filesystem::path restart_binary = runtime_config_.has_value() && !runtime_config_->install_binary.empty()
            ? runtime_config_->install_binary
            : syncpss::util::binary_install_path("syncpss");
        def_prog_mode();
        endwin();
        execl(restart_binary.c_str(), restart_binary.c_str(), static_cast<char*>(nullptr));
        reset_prog_mode();
        refresh();
        clearok(stdscr, TRUE);
        curs_set(0);
        throw std::runtime_error(
            "The update finished, but syncpss could not restart itself from " + restart_binary.string()
        );
    } catch (const std::exception& ex) {
        show_message(
            "Update failed",
            {
                ex.what(),
                "The current syncpss session is still running."
            },
            kColorError
        );
    }
}

}  // namespace syncpss::tui
