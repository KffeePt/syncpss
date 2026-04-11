#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

TuiApp::TuiApp(
    std::optional<syncpss::util::AppConfig> config,
    std::optional<syncpss::util::RuntimeConfig> runtime_config
)
    : config_(std::move(config)),
      runtime_config_(std::move(runtime_config)) {
    if (!runtime_config_.has_value() && config_.has_value()) {
        syncpss::util::RuntimeConfig seeded_runtime;
        seeded_runtime.github_repo = github_repo_from_url(config_->repo_url);
        seeded_runtime.github_repo_name = repo_name_from_repo_id(seeded_runtime.github_repo);
        seeded_runtime.gpg_key_id = config_->gpg_key_id;
        seeded_runtime.store_path = config_->store_path;
        seeded_runtime.store_branch = config_->repo_branch;
        seeded_runtime.ssh_key_path = syncpss::util::get_real_home() / ".ssh" / "syncpss_ed25519";
        seeded_runtime.install_binary = syncpss::util::binary_install_path("syncpss");
        seeded_runtime.install_config_dir = syncpss::util::config_directory();
        seeded_runtime.install_distro = current_distro_name();
        seeded_runtime.install_version = syncpss_version();
        runtime_config_ = seeded_runtime;
    }
    rebuild_clients();
}


void TuiApp::rebuild_clients() {
    store_.reset();
    git_.reset();
    if (!config_.has_value()) {
        return;
    }

    store_ = std::make_unique<syncpss::store::PasswordStore>(config_->store_path, config_->gpg_key_id);
    git_ = std::make_unique<syncpss::git::GitClient>(config_->store_path, config_->repo_branch);
}

void TuiApp::ensure_dependencies(const std::vector<std::string>& commands) const {
    std::vector<std::string> missing;
    for (const std::string& command : commands) {
        if (!syncpss::util::is_command_available(command)) {
            missing.push_back(command);
        }
    }

    if (!missing.empty()) {
        std::string rendered;
        for (std::size_t index = 0; index < missing.size(); ++index) {
            if (index > 0) {
                rendered += ", ";
            }
            rendered += missing[index];
        }
        throw std::runtime_error("Missing required dependency: " + rendered);
    }
}


int TuiApp::run() {
    initialize_curses();
    syncpss::util::record_runtime_event(
        "session.start",
        "syncpss TUI launched",
        {
            {"version", syncpss_version()}
        }
    );
    show_startup_splash();

    try {
        if (!config_.has_value()) {
            try {
                run_setup_wizard(true);
            } catch (const std::exception& ex) {
                rebuild_clients();
                show_message(
                    "Error",
                    {
                        ex.what(),
                        "Returned to the main menu.",
                        "Use Configuration to retry setup."
                    },
                    kColorError
                );
            }
        }

        if (config_.has_value()) {
            maybe_migrate_legacy_plaintext_notes();
        }

        while (true) {
            const int choice = main_menu();
            if (choice < 0) {
                break;
            }

            try {
                switch (choice) {
                    case 0:
                        view_passwords();
                        break;
                    case 1:
                        sync_menu();
                        break;
                    case 2:
                        configuration_menu();
                        break;
                    case 3:
                        update_to_latest_version();
                        break;
                    default:
                        break;
                }
            } catch (const std::exception& ex) {
                rebuild_clients();
                show_message(
                    "Error",
                    {
                        ex.what(),
                        "Returned to the main menu."
                    },
                    kColorError
                );
            }
        }
    } catch (const std::exception& ex) {
        show_message("Error", {ex.what()}, kColorError);
        endwin();
        return 1;
    }

    endwin();
    return 0;
}

}  // namespace syncpss::tui
