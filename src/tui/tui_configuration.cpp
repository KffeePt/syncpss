#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

void TuiApp::maybe_migrate_legacy_plaintext_notes() {
    if (!store_ || !store_->has_legacy_plaintext_notes()) {
        return;
    }

    const std::size_t note_count = store_->legacy_plaintext_notes_count();
    const std::string answer = prompt_input(
        "Encrypted Notes Migration",
        "Legacy plaintext notes were found in ~/.syncpss/notes.json (" + std::to_string(note_count) +
            " entries). Migrate them into encrypted pass entries now? [Y/n]",
        "Y"
    );
    if (!answer_is_yes(answer, true)) {
        return;
    }

    const std::filesystem::path backup_path = store_->migrate_legacy_plaintext_notes();
    show_message(
        "Encrypted Notes Migration",
        {
            "Legacy plaintext notes were migrated into encrypted pass entries where possible.",
            "Backup created at: " + backup_path.string(),
            "New notes are stored only inside the encrypted password store."
        },
        kColorSuccess
    );
}

void TuiApp::change_remote_password_store_name() {
    if (!runtime_config_.has_value() || !config_.has_value() || !store_) {
        show_message(
            "Change Remote Password Store Name",
            {"No runtime configuration is loaded yet.", "Run the setup wizard first."},
            kColorError
        );
        return;
    }

    ensure_dependencies({"gh", "git"});
    if (!std::filesystem::exists(store_->path() / ".git")) {
        throw std::runtime_error("The password store is not a git repository yet. Rerun the setup wizard first.");
    }

    const std::string current_repo_name = runtime_config_->github_repo_name.empty()
        ? repo_name_from_repo_id(runtime_config_->github_repo)
        : runtime_config_->github_repo_name;
    const std::string new_repo_name = prompt_input(
        "Change Remote Password Store Name",
        "New private repo name:",
        current_repo_name
    );
    if (new_repo_name.empty() || new_repo_name == current_repo_name) {
        return;
    }

    const std::string owner = !runtime_config_->github_username.empty()
        ? runtime_config_->github_username
        : repo_owner_from_repo_id(runtime_config_->github_repo);
    if (owner.empty()) {
        throw std::runtime_error("Could not determine the GitHub username for the private password-store repo.");
    }

    const std::string new_repo_id = owner + "/" + new_repo_name;
    const std::string new_repo_url = "git@github.com:" + new_repo_id + ".git";

    const syncpss::util::ProcessResult view_result = syncpss::util::run({"gh", "repo", "view", new_repo_id});
    if (view_result.exit_code != 0) {
        const std::string create_answer = prompt_input(
            "Change Remote Password Store Name",
            "Private repo " + new_repo_id + " does not exist yet. Create it now? [Y/n]",
            "Y"
        );
        if (!answer_is_yes(create_answer, true)) {
            show_message("Cancelled", {"Remote repo target was not changed."}, kColorDim);
            return;
        }

        const syncpss::util::ProcessResult create_result =
            syncpss::util::run({"gh", "repo", "create", new_repo_id, "--private"});
        if (create_result.exit_code != 0) {
            throw std::runtime_error("Failed to create GitHub repo " + new_repo_id + ": " + create_result.stderr_output);
        }
    }

    const syncpss::util::ProcessResult origin_result =
        syncpss::util::run({"git", "-C", store_->path().string(), "remote", "get-url", "origin"});
    const std::vector<std::string> remote_argv = origin_result.exit_code == 0
        ? std::vector<std::string>{"git", "-C", store_->path().string(), "remote", "set-url", "origin", new_repo_url}
        : std::vector<std::string>{"git", "-C", store_->path().string(), "remote", "add", "origin", new_repo_url};
    const syncpss::util::ProcessResult remote_update = syncpss::util::run(remote_argv);
    if (remote_update.exit_code != 0) {
        throw std::runtime_error("Failed to update the local git remote: " + remote_update.stderr_output);
    }

    runtime_config_->github_repo_name = new_repo_name;
    runtime_config_->github_repo = new_repo_id;
    config_->repo_url = new_repo_url;
    syncpss::util::save_runtime_config(*runtime_config_);
    std::string ini_warning;
    try {
        syncpss::util::save_config(*config_);
    } catch (const std::exception& ex) {
        ini_warning = ex.what();
    }
    rebuild_clients();

    const std::string push_answer = prompt_input(
        "Change Remote Password Store Name",
        "Push the current password store to the new repo now? [Y/n]",
        "Y"
    );
    if (answer_is_yes(push_answer, true)) {
        sync_store();
        return;
    }

    show_message(
        "Change Remote Password Store Name",
        {
            "Saved new private repo target.",
            "Remote repo: " + new_repo_id,
            ini_warning.empty() ? "Legacy /etc config updated." : "Legacy /etc config was not updated: " + ini_warning,
            "Run Sync when you are ready to push the current store."
        },
        kColorSuccess
    );
}

void TuiApp::configure_privacy_settings() {
    if (!runtime_config_.has_value()) {
        show_message(
            "Privacy Settings",
            {"No runtime configuration is loaded yet.", "Run the setup wizard first."},
            kColorError
        );
        return;
    }

    syncpss::util::RuntimeConfig updated = *runtime_config_;
    updated.notes_mode = "encrypted";
    const std::string telemetry_prompt = prompt_input(
        "Privacy Settings",
        "Telemetry mode: [o]ff, [b]are, [f]ull",
        updated.telemetry_mode == "on" ? "f" : (updated.telemetry_mode == "bare" ? "b" : "o")
    );
    if (telemetry_prompt.empty()) {
        return;
    }

    const char telemetry_choice = static_cast<char>(std::tolower(static_cast<unsigned char>(telemetry_prompt.front())));
    if (telemetry_choice == 'f') {
        updated.telemetry_mode = "on";
    } else if (telemetry_choice == 'b') {
        updated.telemetry_mode = "bare";
    } else {
        updated.telemetry_mode = "off";
    }
    updated.metadata_logging_enabled = updated.telemetry_mode != "off";
    updated.metadata_log_hostname = updated.telemetry_mode == "on";
    updated.metadata_log_ip = updated.telemetry_mode == "on";
    updated.metadata_log_mac = updated.telemetry_mode == "on";

    syncpss::util::save_runtime_config(updated);
    runtime_config_ = updated;
    show_message(
        "Privacy Settings",
        {
            "Telemetry mode: " + updated.telemetry_mode,
            "Runtime log path: " + (syncpss::util::runtime_directory() / "logs").string(),
            updated.telemetry_mode == "off"
                ? "No runtime logs or system metadata will be written."
                : (updated.telemetry_mode == "bare"
                    ? "Basic password-operation logs will be kept without host, network, or location details."
                    : "Full telemetry keeps password-operation logs plus host, system, network, and location details when supported."),
            "Notes storage: encrypted separate .note files"
        },
        kColorSuccess
    );
}

void TuiApp::configuration_menu() {
    enum class ConfigAction {
        ShowCurrentConfiguration,
        ChangeRemotePasswordStoreName,
        PrivacySettings,
        VerifyFingerprint,
        ManageGpgKeys,
        BackupRestore,
        UpdateToLatestVersion,
        RerunSetupWizard,
        HomerMode,
        Uninstall,
        Back
    };

    struct ConfigMenuRow {
        std::string label;
        bool selectable;
        ConfigAction action;
        int inactive_pair;
    };

    int selected = 0;
    const std::vector<ConfigMenuRow> rows = {
        {"Account & Store", false, ConfigAction::Back, kColorHeader},
        {"[o] Show current configuration", true, ConfigAction::ShowCurrentConfiguration, kColorAccount},
        {"[r] Change remote password store name", true, ConfigAction::ChangeRemotePasswordStoreName, kColorAccount},
        {"[p] Privacy settings", true, ConfigAction::PrivacySettings, kColorAccount},
        {"", false, ConfigAction::Back, 0},
        {"Security & Recovery", false, ConfigAction::Back, kColorHeader},
        {"[f] Verify fingerprint", true, ConfigAction::VerifyFingerprint, kColorSite},
        {"[g] Manage GPG keys", true, ConfigAction::ManageGpgKeys, kColorSite},
        {"[b] Backup / restore", true, ConfigAction::BackupRestore, kColorSite},
        {"", false, ConfigAction::Back, 0},
        {"Setup & Maintenance", false, ConfigAction::Back, kColorHeader},
        {"[u] Update to latest version", true, ConfigAction::UpdateToLatestVersion, kColorFrosting},
        {"[w] Rerun setup wizard", true, ConfigAction::RerunSetupWizard, kColorFrosting},
        {"[h] Homer mode", true, ConfigAction::HomerMode, kColorFrosting},
        {"[x] Uninstall", true, ConfigAction::Uninstall, kColorError},
        {"[q] Back", true, ConfigAction::Back, kColorDim}
    };
    std::vector<int> selectable_rows;
    selectable_rows.reserve(rows.size());
    for (std::size_t index = 0; index < rows.size(); ++index) {
        if (rows[index].selectable) {
            selectable_rows.push_back(static_cast<int>(index));
        }
    }

    while (true) {
        clear();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "Configuration");
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        apply_pair(kColorDim);
        mvprintw(2, 2, "%s", trim_for_render("Organized settings for store access, recovery, and maintenance.", COLS - 4).c_str());
        clear_pair(kColorDim);

        for (std::size_t index = 0; index < rows.size(); ++index) {
            const int row = 4 + static_cast<int>(index);
            const ConfigMenuRow& entry = rows[index];
            if (!entry.selectable) {
                if (entry.label.empty()) {
                    continue;
                }
                apply_pair(entry.inactive_pair);
                attron(A_BOLD);
                mvprintw(row, 2, "%s", trim_for_render(entry.label, COLS - 4).c_str());
                attroff(A_BOLD);
                clear_pair(entry.inactive_pair);
                continue;
            }
            const bool is_selected = selectable_rows[selected] == static_cast<int>(index);
            render_menu_option(row, 4, entry.label, is_selected, COLS - 8, entry.inactive_pair);
        }
        mvprintw(LINES - 2, 2, "[Enter] select  [Esc]/[q] back  [j/k] move");
        refresh();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 27 || ch == 'q' || ch == 'Q') {
            return;
        }
        if (ch == 'o' || ch == 'O') {
            selected = 0;
        } else if (ch == 'r' || ch == 'R') {
            selected = 1;
        } else if (ch == 'p' || ch == 'P') {
            selected = 2;
        } else if (ch == 'f' || ch == 'F') {
            selected = 3;
        } else if (ch == 'g' || ch == 'G') {
            selected = 4;
        } else if (ch == 'b' || ch == 'B') {
            selected = 5;
        } else if (ch == 'u' || ch == 'U') {
            selected = 6;
        } else if (ch == 'w' || ch == 'W') {
            selected = 7;
        } else if (ch == 'h' || ch == 'H') {
            selected = 8;
        } else if (ch == 'x' || ch == 'X') {
            selected = 9;
        }
        if (ch == KEY_UP || ch == 'k') {
            selected = (selected - 1 + static_cast<int>(selectable_rows.size())) % static_cast<int>(selectable_rows.size());
            continue;
        }
        if (ch == KEY_DOWN || ch == 'j') {
            selected = (selected + 1) % static_cast<int>(selectable_rows.size());
            continue;
        }
        if (ch != '\n' && ch != '\r' && ch != KEY_ENTER &&
            ch != 'o' && ch != 'O' &&
            ch != 'r' && ch != 'R' &&
            ch != 'p' && ch != 'P' &&
            ch != 'f' && ch != 'F' &&
            ch != 'g' && ch != 'G' &&
            ch != 'b' && ch != 'B' &&
            ch != 'u' && ch != 'U' &&
            ch != 'w' && ch != 'W' &&
            ch != 'h' && ch != 'H' &&
            ch != 'x' && ch != 'X') {
            continue;
        }

        switch (rows[static_cast<std::size_t>(selectable_rows[selected])].action) {
            case ConfigAction::ShowCurrentConfiguration: {
            std::vector<std::string> lines;
            bool latest_release_checked = false;
            std::string latest_release_version;
            {
                std::lock_guard<std::mutex> lock(latest_release_mutex_);
                latest_release_checked = latest_release_checked_;
                latest_release_version = latest_release_version_;
            }
            const std::string latest_release_label = latest_release_checked && !latest_release_version.empty()
                ? format_release_version(latest_release_version)
                : (latest_release_checked ? "unavailable" : "checking...");
            if (runtime_config_.has_value()) {
                lines = {
                    "GitHub username: " + runtime_config_->github_username,
                    "GitHub email: " + runtime_config_->github_email,
                    "GitHub repo: " + runtime_config_->github_repo,
                    "Saved repo name: " + runtime_config_->github_repo_name,
                    "SSH key: " + runtime_config_->ssh_key_path.string(),
                    "Store path: " + runtime_config_->store_path.string(),
                    "Branch: " + runtime_config_->store_branch,
                    "GPG key: " + runtime_config_->gpg_key_id,
                    "Remote key backup: " + std::string(runtime_config_->gpg_keys_remote ? "yes" : "no"),
                    "Telemetry mode: " + runtime_config_->telemetry_mode,
                    "Runtime logs: " + (syncpss::util::runtime_directory() / "logs").string(),
                    "Local version: " + format_release_version(syncpss_version()),
                    "Latest release: " + latest_release_label,
                    "Notes mode: " + runtime_config_->notes_mode,
                    "Runtime config: " + syncpss::util::runtime_config_path().string(),
                };
            } else if (config_.has_value()) {
                lines = {
                    "Repo URL: " + config_->repo_url,
                    "Branch: " + config_->repo_branch,
                    "Store path: " + config_->store_path.string(),
                    "GPG key: " + config_->gpg_key_id,
                    "Local version: " + format_release_version(syncpss_version()),
                    "Latest release: " + latest_release_label,
                };
            } else {
                lines = {"No configuration loaded."};
            }
            show_message("Current Configuration", lines, kColorDim);
                break;
            }
            case ConfigAction::ChangeRemotePasswordStoreName:
                change_remote_password_store_name();
                break;
            case ConfigAction::PrivacySettings:
                configure_privacy_settings();
                break;
            case ConfigAction::VerifyFingerprint:
                verify_local_fingerprint();
                break;
            case ConfigAction::ManageGpgKeys:
                manage_gpg_keys();
                break;
            case ConfigAction::BackupRestore:
                migration_menu();
                break;
            case ConfigAction::UpdateToLatestVersion:
                update_to_latest_version();
                break;
            case ConfigAction::RerunSetupWizard:
                run_setup_wizard(false);
                return;
            case ConfigAction::HomerMode:
                show_startup_splash();
                break;
            case ConfigAction::Uninstall:
                uninstall_flow();
                break;
            case ConfigAction::Back:
                return;
        }
    }
}

void TuiApp::verify_local_fingerprint() {
    try {
        if (!runtime_config_.has_value()) {
            show_message(
                "Verify Fingerprint",
                {
                    "No runtime configuration is loaded.",
                    "Run the installer or setup wizard first."
                },
                kColorError
            );
            return;
        }

        const std::filesystem::path fingerprint_path = syncpss::util::runtime_master_fingerprint_path();
        if (!std::filesystem::exists(fingerprint_path)) {
            show_message(
                "Verify Fingerprint",
                {
                    "No installed release fingerprint was found.",
                    "Reinstall or update syncpss so the release fingerprint is staged locally."
                },
                kColorDim
            );
            return;
        }

        const std::string expected = first_checksum_token(fingerprint_path);
        const std::string actual = compute_local_install_fingerprint(*runtime_config_);
        const bool matched = expected == actual;

        std::vector<std::string> lines = {
            std::string("Installed version: ") +
                (runtime_config_->install_version.empty() ? "unknown" : runtime_config_->install_version),
            std::string("Fingerprint file: ") + fingerprint_path.string(),
            std::string("Expected: ") + expected,
            std::string("Actual:   ") + actual
        };

        if (matched) {
            lines.push_back("Result: OK. The installed syncpss files match the staged release fingerprint.");
            show_message("Verify Fingerprint", lines, kColorSuccess);
            return;
        }

        lines.push_back("Result: WARN. The installed syncpss files do not match the staged release fingerprint.");
        show_message("Verify Fingerprint", lines, kColorError);
    } catch (const std::exception& ex) {
        show_message("Verify Fingerprint", {ex.what()}, kColorError);
    }
}

}  // namespace syncpss::tui
