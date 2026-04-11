#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

void TuiApp::run_setup_wizard(bool first_run) {
    ensure_dependencies({"git", "gpg", "ssh-keygen", "ssh-keyscan", "pass", "veracrypt"});

    syncpss::util::RuntimeConfig runtime = runtime_config_.value_or(syncpss::util::RuntimeConfig{});
    if (runtime.ssh_key_path.empty()) {
        runtime.ssh_key_path = syncpss::util::get_real_home() / ".ssh" / "syncpss_ed25519";
    }
    if (runtime.store_path.empty()) {
        runtime.store_path = syncpss::util::default_store_path();
    }
    if (runtime.install_binary.empty()) {
        runtime.install_binary = syncpss::util::binary_install_path("syncpss");
    }
    if (runtime.install_config_dir.empty()) {
        runtime.install_config_dir = syncpss::util::config_directory();
    }
    if (runtime.install_distro.empty()) {
        runtime.install_distro = current_distro_name();
    }
    runtime.install_version = syncpss_version();
    if (runtime.install_installed_at.empty()) {
        runtime.install_installed_at = iso8601_utc_now();
    }

    runtime.github_username = prompt_input(
        first_run ? "Step 1/5: GitHub account" : "GitHub account",
        "GitHub username:",
        runtime.github_username
    );
    if (runtime.github_username.empty()) {
        throw std::runtime_error("GitHub username is required");
    }
    runtime.github_email = prompt_input("GitHub account", "GitHub email:", runtime.github_email);
    const std::string preferred_repo_name = !runtime.github_repo_name.empty()
        ? runtime.github_repo_name
        : (!runtime.github_repo.empty()
            ? repo_name_from_repo_id(runtime.github_repo)
            : syncpss::util::load_preferred_private_repo_name());
    const std::string repo_name = prompt_input(
        "GitHub account",
        "Private repo name:",
        preferred_repo_name.empty() ? "password-store" : preferred_repo_name
    );
    if (repo_name.empty()) {
        throw std::runtime_error("Repository name is required");
    }
    runtime.github_repo_name = repo_name;
    runtime.github_repo = runtime.github_username + "/" + repo_name;

    syncpss::util::AppConfig new_config;
    new_config.repo_url = "git@github.com:" + runtime.github_repo + ".git";

    new_config.repo_branch = prompt_input(
        first_run ? "Step 2/5: Repository" : "Repository",
        "Branch name:",
        runtime.store_branch.empty() ? (config_.has_value() ? config_->repo_branch : "main") : runtime.store_branch
    );
    if (new_config.repo_branch.empty()) {
        new_config.repo_branch = "main";
    }
    new_config.store_path = runtime.store_path;
    runtime.store_branch = new_config.repo_branch;

    std::string gpg_key_id = prompt_input(
        first_run ? "Step 3/5: GPG key ID" : "GPG key ID",
        "Your GPG key ID (leave blank to generate a new GPG key):",
        runtime.gpg_key_id.empty() ? (config_.has_value() ? config_->gpg_key_id : "") : runtime.gpg_key_id
    );
    if (gpg_key_id.empty()) {
        endwin();
        try {
            gpg_.generate_key_interactive();
        } catch (...) {
            initialize_curses();
            throw;
        }
        initialize_curses();

        const std::vector<std::string> keys = gpg_.secret_key_ids();
        if (keys.empty()) {
            throw std::runtime_error("No GPG secret key found after generation");
        }
        gpg_key_id = keys.back();
    }
    if (!gpg_.key_exists(gpg_key_id)) {
        throw std::runtime_error("Provided GPG key ID was not found in your secret keyring");
    }
    new_config.gpg_key_id = gpg_key_id;
    runtime.gpg_key_id = gpg_key_id;

    syncpss::ssh::SshKeyStatus key_status = ssh_.ensure_ed25519_key(runtime.ssh_key_path);
    runtime.ssh_key_path = key_status.private_key_path;
    ssh_.verify_github_host_key();
    ssh_.ensure_known_hosts_entry();
    show_message(
        first_run ? "Step 4/5: SSH key for GitHub" : "SSH key for GitHub",
        {
            key_status.existing_key
                ? ("Found existing SSH key at " + key_status.private_key_path.string())
                : ("Generated new Ed25519 SSH key at " + key_status.private_key_path.string()),
            key_status.copied_to_clipboard
                ? "Public key copied to clipboard."
                : "Clipboard unavailable; copy the public key manually below.",
            trim_for_render(key_status.public_key, COLS - 4),
            "GitHub account key: Settings > SSH Keys",
            "Repo deploy key: password-store repo > Settings > Deploy keys",
            "Deploy keys are useful for invited or read-only access.",
            "Press any key when done."
        },
        kColorSuccess
    );

    if (std::filesystem::exists(new_config.store_path)) {
        if (!std::filesystem::is_empty(new_config.store_path) &&
            !confirm_with_text("Store path already exists. Replace its contents?", "REPLACE")) {
            throw std::runtime_error("Clone cancelled");
        }
        if (!syncpss::util::is_safe_recursive_delete_target(new_config.store_path)) {
            throw std::runtime_error("Refusing to replace unsafe store path: " + new_config.store_path.string());
        }
        std::filesystem::remove_all(new_config.store_path);
    }

    ssh_.clone_repo(new_config.repo_url, new_config.repo_branch, new_config.store_path, runtime.ssh_key_path);
    config_ = new_config;
    runtime.store_path = new_config.store_path;
    runtime_config_ = runtime;
    rebuild_clients();

    const std::filesystem::path gpg_id_path = new_config.store_path / ".gpg-id";
    if (!std::filesystem::exists(gpg_id_path)) {
        store_->initialize_store();
    }

    const std::filesystem::path keys_path = new_config.store_path / "keys";
    if (std::filesystem::exists(keys_path)) {
        const std::string restore_answer = prompt_input(
            first_run ? "Step 5/5: GPG key restore" : "GPG key restore",
            "Encrypted GPG keys found in the remote repo. Restore them? [Y/n]",
            "Y"
        );
        if (answer_is_yes(restore_answer)) {
            restore_keys_from_remote();
        }
        runtime_config_->gpg_keys_remote = true;
    } else {
        const std::string backup_answer = prompt_input(
            first_run ? "Step 5/5: GPG key backup" : "GPG key backup",
            "No encrypted GPG key container was found. Upload current keys? [Y/n]",
            "Y"
        );
        if (answer_is_yes(backup_answer)) {
            backup_keys_to_remote();
        }
    }

    syncpss::util::save_runtime_config(*runtime_config_);
    std::string ini_warning;
    try {
        syncpss::util::save_config(new_config);
    } catch (const std::exception& ex) {
        ini_warning = ex.what();
    }

    std::vector<std::string> lines = {
        "Clone complete.",
        "Runtime configuration saved to " + syncpss::util::runtime_config_path().string(),
        "Welcome to syncpss."
    };
    if (!ini_warning.empty()) {
        lines.push_back("Legacy /etc config was not updated: " + ini_warning);
    } else {
        lines.push_back("Legacy INI written to " + syncpss::util::config_path().string());
    }
    show_message("Setup complete", lines, kColorSuccess);
}

}  // namespace syncpss::tui
