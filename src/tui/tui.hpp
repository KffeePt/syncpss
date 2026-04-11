#pragma once

#include "crypto/gpg.hpp"
#include "crypto/veracrypt.hpp"
#include "git/git.hpp"
#include "ssh/ssh.hpp"
#include "store/store.hpp"
#include "util/clipboard.hpp"
#include "util/config.hpp"
#include "util/runtime_config.hpp"

#include <mutex>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace syncpss::tui {

class TuiApp {
public:
    explicit TuiApp(
        std::optional<syncpss::util::AppConfig> config,
        std::optional<syncpss::util::RuntimeConfig> runtime_config = std::nullopt
    );
    int run();

private:
    std::optional<syncpss::util::AppConfig> config_;
    std::optional<syncpss::util::RuntimeConfig> runtime_config_;
    syncpss::crypto::GpgManager gpg_;
    syncpss::crypto::VeraCryptManager veracrypt_;
    syncpss::ssh::SshManager ssh_;
    std::unique_ptr<syncpss::store::PasswordStore> store_;
    std::unique_ptr<syncpss::git::GitClient> git_;
    mutable std::mutex latest_release_mutex_;
    std::string latest_release_version_;
    std::string latest_release_error_;
    bool latest_release_checked_ = false;
    bool latest_release_check_in_progress_ = false;
    bool latest_release_update_available_ = false;

    void initialize_curses() const;
    void handle_resize() const;
    void rebuild_clients();
    void show_startup_splash();
    void refresh_latest_release_info(bool force_refresh = false);
    void ensure_dependencies(const std::vector<std::string>& commands) const;
    int main_menu();
    void show_help() const;
    void show_message(const std::string& title, const std::vector<std::string>& lines, int color_pair = 0) const;
    void show_scrollable_page(
        const std::string& title,
        const std::vector<std::string>& lines,
        int color_pair = 0,
        const std::string& footer = "[Up/Down] scroll  [q] back"
    ) const;
    void show_clipboard_notice(const std::string& label, const syncpss::util::ClipboardLease& lease) const;
    bool confirm_with_text(const std::string& prompt, const std::string& expected) const;
    std::string prompt_input(
        const std::string& title,
        const std::string& prompt,
        const std::string& initial = "",
        bool secret = false
    ) const;
    void run_setup_wizard(bool first_run);
    void view_passwords();
    void add_password();
    void configuration_menu();
    void change_remote_password_store_name();
    void configure_privacy_settings();
    void update_to_latest_version(bool skip_confirmation = false);
    void maybe_migrate_legacy_plaintext_notes();
    void verify_local_fingerprint();
    void manage_gpg_keys();
    void migration_menu();
    void export_backup_container();
    void import_backup_container();
    void export_local_keys_backup();
    void import_local_keys_backup();
    void backup_keys_to_remote();
    void restore_keys_from_remote();
    void export_public_key();
    void edit_password(const std::optional<std::string>& preselected = std::nullopt);
    void delete_password(const std::optional<std::string>& preselected = std::nullopt);
    void sync_menu();
    void sync_store();
    void push_store_force();
    void pull_store_force();
    void fetch_store_preview();
    void nuke_store();
    void uninstall_flow();
    void resolve_conflicts(const std::vector<std::string>& conflicts);
    syncpss::git::SyncReport run_sync_operation(
        const std::string& title,
        const std::string& waiting_line,
        const std::function<syncpss::git::SyncReport(const syncpss::git::GitClient::LogCallback&)>& operation
    );
    bool review_sync_preview(const syncpss::git::SyncPreview& preview, bool preview_only, const std::string& title);
    void open_sync_editor(const std::string& path);
    std::optional<std::string> select_entry(const std::string& title) const;
    std::string select_folder(const std::string& title, const std::string& initial = "") const;
    std::string prompt_password_value(const std::string& title, bool allow_keep_current, const std::string& current_value = "") const;
};

}  // namespace syncpss::tui
