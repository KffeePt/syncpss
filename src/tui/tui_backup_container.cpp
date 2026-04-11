#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

namespace {

std::string backup_timestamp_id() {
    const auto now = std::chrono::system_clock::now();
    const std::time_t now_time = std::chrono::system_clock::to_time_t(now);
    std::tm utc_time{};
#if defined(__APPLE__) || defined(__linux__)
    gmtime_r(&now_time, &utc_time);
#else
    utc_time = *std::gmtime(&now_time);
#endif
    char buffer[32]{};
    std::strftime(buffer, sizeof(buffer), "%Y%m%dT%H%M%SZ", &utc_time);
    return buffer;
}

void secure_owner_only_path(const std::filesystem::path& path) {
    std::error_code ignored;
    std::filesystem::permissions(
        path,
        std::filesystem::is_directory(path)
            ? std::filesystem::perms::owner_all
            : (std::filesystem::perms::owner_read | std::filesystem::perms::owner_write),
        std::filesystem::perm_options::replace,
        ignored
    );
}

std::filesystem::path ensure_backups_directory() {
    const std::filesystem::path path = syncpss::util::runtime_backups_directory();
    std::filesystem::create_directories(path);
    secure_owner_only_path(path);
    return path;
}

std::filesystem::path latest_backup_with_prefix(const std::string& prefix) {
    const std::filesystem::path backup_dir = ensure_backups_directory();
    std::filesystem::path best_match;
    for (const auto& entry : std::filesystem::directory_iterator(backup_dir)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        const std::string filename = entry.path().filename().string();
        if (filename.rfind(prefix, 0) != 0 || entry.path().extension() != ".bak") {
            continue;
        }
        if (best_match.empty() || entry.path().filename().string() > best_match.filename().string()) {
            best_match = entry.path();
        }
    }
    return best_match;
}

void secure_owner_only_tree(const std::filesystem::path& root) {
    if (!std::filesystem::exists(root)) {
        return;
    }

    secure_owner_only_path(root);
    for (const auto& entry : std::filesystem::recursive_directory_iterator(root)) {
        secure_owner_only_path(entry.path());
    }
}

void ensure_safe_replace_target(const std::filesystem::path& path, const std::string& label) {
    if (!syncpss::util::is_safe_recursive_delete_target(path)) {
        throw std::runtime_error("Refusing to replace unsafe " + label + " path: " + path.string());
    }
}

std::filesystem::path sibling_stage_path(const std::filesystem::path& target, const std::string& label) {
    return target.parent_path() / (target.filename().string() + "." + label + "-" + backup_timestamp_id());
}

void clear_path_if_present(const std::filesystem::path& path) {
    std::error_code ignored;
    if (std::filesystem::exists(path)) {
        std::filesystem::remove_all(path, ignored);
    }
}

void prepare_staged_directory_copy(
    const std::filesystem::path& source,
    const std::filesystem::path& staged_target
) {
    clear_path_if_present(staged_target);
    std::filesystem::create_directories(staged_target);
    copy_directory_tree_filtered(source, staged_target, [](const std::filesystem::path&) {
        return false;
    });
}

void replace_directory_with_rollback(
    const std::filesystem::path& staged_target,
    const std::filesystem::path& live_target
) {
    const std::filesystem::path backup_target = sibling_stage_path(live_target, "restore-backup");
    const bool had_existing = std::filesystem::exists(live_target);

    clear_path_if_present(backup_target);
    if (had_existing) {
        std::filesystem::rename(live_target, backup_target);
    }

    try {
        std::filesystem::rename(staged_target, live_target);
        clear_path_if_present(backup_target);
    } catch (...) {
        clear_path_if_present(live_target);
        if (had_existing && std::filesystem::exists(backup_target)) {
            std::filesystem::rename(backup_target, live_target);
        }
        clear_path_if_present(staged_target);
        throw;
    }
}

}  // namespace

void TuiApp::migration_menu() {
    ensure_dependencies({"pass", "gpg", "veracrypt", "zip", "unzip"});

    int selected = 0;
    const std::vector<std::string> items = {
        "[e] Export password-store backup (.bak zip)",
        "[i] Import password-store backup (.bak zip)",
        "[g] Export local keys backup (.bak VeraCrypt)",
        "[r] Restore local keys backup (.bak VeraCrypt)",
        "[q] Back"
    };

    while (true) {
        clear();
        box(stdscr, 0, 0);
        apply_pair(kColorHeader);
        attron(A_BOLD);
        mvprintw(1, 2, "Backup / Restore");
        attroff(A_BOLD);
        clear_pair(kColorHeader);
        apply_pair(kColorDim);
        mvprintw(2, 2, "%s", trim_for_render("Local production backups live in ~/.syncpss/backups as .bak files.", COLS - 4).c_str());
        clear_pair(kColorDim);

        for (std::size_t index = 0; index < items.size(); ++index) {
            const int row = 4 + static_cast<int>(index);
            render_menu_option(row, 2, items[index], static_cast<int>(index) == selected, COLS - 4);
        }
        mvprintw(LINES - 2, 2, "[Enter] select  [Esc]/[q] back");
        refresh();

        const int ch = getch();
        if (ch == KEY_RESIZE) {
            handle_resize();
            continue;
        }
        if (ch == 27 || ch == 'q' || ch == 'Q') {
            return;
        }
        if (ch == 'e' || ch == 'E') {
            export_backup_container();
            continue;
        }
        if (ch == 'i' || ch == 'I') {
            import_backup_container();
            continue;
        }
        if (ch == 'g' || ch == 'G') {
            export_local_keys_backup();
            continue;
        }
        if (ch == 'r' || ch == 'R') {
            import_local_keys_backup();
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

        if (selected == 0) {
            export_backup_container();
        } else if (selected == 1) {
            import_backup_container();
        } else if (selected == 2) {
            export_local_keys_backup();
        } else if (selected == 3) {
            import_local_keys_backup();
        } else {
            return;
        }
    }
}

void TuiApp::export_backup_container() {
    if (!config_.has_value() || !store_) {
        throw std::runtime_error("Setup must complete before exporting a password-store backup");
    }

    const std::vector<std::string> entries = store_->list_entries();
    if (entries.empty()) {
        throw std::runtime_error("There are no password entries to back up");
    }

    const std::filesystem::path default_archive =
        ensure_backups_directory() / ("password-store-" + backup_timestamp_id() + ".bak");
    const std::string destination = prompt_input(
        "Export Password-Store Backup",
        "Destination .bak archive:",
        default_archive.string()
    );
    if (destination.empty()) {
        return;
    }

    const std::filesystem::path archive_path = destination;
    std::filesystem::create_directories(archive_path.parent_path());
    secure_owner_only_path(archive_path.parent_path());

    const std::filesystem::path staging_root =
        syncpss::util::create_secure_temp_directory("syncpss-password-store-export");
    try {
        const std::filesystem::path staged_store = staging_root / config_->store_path.filename();
        const std::filesystem::path live_notes = syncpss::util::runtime_notes_directory();
        const std::filesystem::path staged_notes = staging_root / "notes";

        prepare_staged_directory_copy(config_->store_path, staged_store);
        write_store_manifest_file(staged_store);

        std::filesystem::create_directories(staged_notes);
        if (std::filesystem::exists(live_notes)) {
            copy_directory_tree_filtered(live_notes, staged_notes, [](const std::filesystem::path&) {
                return false;
            });
        }
        secure_owner_only_tree(staged_notes);

        write_manifest_file(
            staging_root,
            "password-store-backup",
            {
                {"manifest.xml", "Root manifest for this password-store backup archive."},
                {config_->store_path.filename().generic_string() + "/", "Compressed snapshot of the full password-store repository."},
                {"notes/", "Separate GPG-encrypted per-entry note files stored under ~/.syncpss/notes."}
            }
        );

        const syncpss::util::ProcessResult result = syncpss::util::run(
            {
                "zip",
                "-qr",
                archive_path.string(),
                "manifest.xml",
                config_->store_path.filename().string(),
                "notes"
            },
            syncpss::util::ProcessOptions{staging_root.string()}
        );
        if (result.exit_code != 0) {
            throw std::runtime_error("zip backup failed: " + result.stderr_output);
        }
        secure_owner_only_path(archive_path);

        std::error_code ignored;
        std::filesystem::remove_all(staging_root, ignored);
    } catch (...) {
        std::error_code ignored;
        std::filesystem::remove_all(staging_root, ignored);
        throw;
    }

    show_message(
        "Password-Store Backup Complete",
        {
            "Created local .bak archive:",
            archive_path.string(),
            "Format: zip archive containing the password store plus separate encrypted notes."
        },
        kColorSuccess
    );
}

void TuiApp::import_backup_container() {
    if (!config_.has_value() || !store_) {
        throw std::runtime_error("Setup must complete before importing a password-store backup");
    }

    const std::filesystem::path suggested =
        latest_backup_with_prefix("password-store-").empty()
            ? ensure_backups_directory() / "password-store-import.bak"
            : latest_backup_with_prefix("password-store-");
    const std::string source = prompt_input(
        "Import Password-Store Backup",
        "Source .bak archive:",
        suggested.string()
    );
    if (source.empty()) {
        return;
    }

    const std::filesystem::path archive_path = source;
    if (!std::filesystem::exists(archive_path)) {
        throw std::runtime_error("Backup archive not found: " + archive_path.string());
    }
    if (!confirm_with_text("Replace the current password store from this backup?", "REPLACE")) {
        show_message("Cancelled", {"Password-store import cancelled."}, kColorDim);
        return;
    }

    const std::filesystem::path extract_dir = syncpss::util::create_secure_temp_directory("syncpss-store-backup");
    try {
        const syncpss::util::ProcessResult unzip_result = syncpss::util::run(
            {"unzip", "-oq", archive_path.string(), "-d", extract_dir.string()}
        );
        if (unzip_result.exit_code != 0) {
            throw std::runtime_error("unzip backup failed: " + unzip_result.stderr_output);
        }

        const std::filesystem::path root_manifest = extract_dir / "manifest.xml";
        if (!std::filesystem::exists(root_manifest) || read_manifest_type(root_manifest) != "password-store-backup") {
            throw std::runtime_error(
                "The selected .bak archive is not a supported password-store backup. "
                "Expected a syncpss password-store-backup manifest."
            );
        }

        const std::filesystem::path extracted_store = extract_dir / config_->store_path.filename();
        if (!std::filesystem::exists(extracted_store) || !std::filesystem::is_directory(extracted_store)) {
            throw std::runtime_error(
                "The selected .bak archive is missing the expected store folder: " +
                config_->store_path.filename().string()
            );
        }

        const std::filesystem::path extracted_store_manifest = extracted_store / "manifest.xml";
        if (!std::filesystem::exists(extracted_store_manifest) || read_manifest_type(extracted_store_manifest) != "backup") {
            throw std::runtime_error("The selected .bak archive contains an invalid password-store snapshot.");
        }

        const std::filesystem::path extracted_notes = extract_dir / "notes";
        if (std::filesystem::exists(extracted_notes) && !std::filesystem::is_directory(extracted_notes)) {
            throw std::runtime_error("The selected .bak archive contains an invalid notes payload.");
        }

        ensure_safe_replace_target(config_->store_path, "password-store");
        const std::filesystem::path live_notes = syncpss::util::runtime_notes_directory();
        ensure_safe_replace_target(live_notes, "notes");

        std::filesystem::create_directories(config_->store_path.parent_path());
        std::filesystem::create_directories(live_notes.parent_path());

        const std::filesystem::path staged_store = sibling_stage_path(config_->store_path, "restore-stage");
        const std::filesystem::path staged_notes = sibling_stage_path(live_notes, "restore-stage");
        prepare_staged_directory_copy(extracted_store, staged_store);
        clear_path_if_present(staged_notes);
        std::filesystem::create_directories(staged_notes);
        if (std::filesystem::exists(extracted_notes)) {
            copy_directory_tree_filtered(extracted_notes, staged_notes, [](const std::filesystem::path&) {
                return false;
            });
        }

        secure_owner_only_tree(staged_notes);
        replace_directory_with_rollback(staged_store, config_->store_path);
        replace_directory_with_rollback(staged_notes, live_notes);
        write_store_manifest_file(config_->store_path);
        rebuild_clients();

        std::filesystem::remove_all(extract_dir);
        show_message(
            "Password-Store Restore Complete",
            {
                "Restored the local password store from:",
                archive_path.string(),
                "Separate encrypted notes were restored into ~/.syncpss/notes."
            },
            kColorSuccess
        );
    } catch (...) {
        std::error_code ignored;
        std::filesystem::remove_all(extract_dir, ignored);
        throw;
    }
}

void TuiApp::export_local_keys_backup() {
    if (!runtime_config_.has_value()) {
        throw std::runtime_error("Setup must complete before exporting a local GPG keys backup");
    }

    const std::string password = prompt_input("Export Local Keys Backup", "VeraCrypt backup password:", "", true);
    if (password.empty()) {
        return;
    }
    const std::string confirmation = prompt_input(
        "Export Local Keys Backup",
        "Confirm VeraCrypt backup password:",
        "",
        true
    );
    if (confirmation != password) {
        throw std::runtime_error("Container passwords did not match");
    }

    const std::filesystem::path archive_path =
        ensure_backups_directory() / ("keys-" + backup_timestamp_id() + ".bak");
    const std::filesystem::path mount_point = syncpss::util::create_secure_temp_directory("syncpss-vc-keys-backup");

    try {
        veracrypt_.create_volume(archive_path, container_size_mb_for(gpg_.gnupg_directory()), password);
        veracrypt_.mount(archive_path, mount_point, password);
        gpg_.export_to_directory(mount_point);
        write_manifest_file(
            mount_point,
            "keys",
            {
                {"manifest.xml", "Container manifest describing the local portable GPG key backup."},
                {"pubkeys.asc", "Exported public keys from the GPG keyring stored in this container."},
                {"seckeys.asc", "Exported secret keys from the GPG keyring stored in this container."},
                {"ownertrust.txt", "Ownertrust assignments associated with the exported GPG keys."},
                {".gnupg/", "Raw .gnupg directory snapshot used for full keyring rebase and recovery."}
            }
        );
        veracrypt_.dismount(mount_point);
        std::filesystem::remove_all(mount_point);
        secure_owner_only_path(archive_path);

        show_message(
            "Local Keys Backup Complete",
            {
                "Created encrypted local keys backup:",
                archive_path.string()
            },
            kColorSuccess
        );
    } catch (...) {
        std::error_code ignored;
        if (std::filesystem::exists(mount_point)) {
            const syncpss::util::ProcessResult result =
                syncpss::util::run({"veracrypt", "--text", "--dismount", mount_point.string()});
            if (result.exit_code != 0) {
                std::filesystem::remove_all(mount_point, ignored);
            }
        }
        throw;
    }
}

void TuiApp::import_local_keys_backup() {
    if (!config_.has_value() || !runtime_config_.has_value()) {
        throw std::runtime_error("Setup must complete before restoring a local GPG keys backup");
    }

    const std::filesystem::path suggested =
        latest_backup_with_prefix("keys-").empty()
            ? ensure_backups_directory() / "keys-import.bak"
            : latest_backup_with_prefix("keys-");
    const std::string source = prompt_input(
        "Restore Local Keys Backup",
        "Source .bak container:",
        suggested.string()
    );
    if (source.empty()) {
        return;
    }

    const std::filesystem::path archive_path = source;
    if (!std::filesystem::exists(archive_path)) {
        throw std::runtime_error("Local keys backup not found: " + archive_path.string());
    }

    const std::string password = prompt_input("Restore Local Keys Backup", "VeraCrypt container password:", "", true);
    if (password.empty()) {
        return;
    }

    const std::filesystem::path mount_point = syncpss::util::create_secure_temp_directory("syncpss-vc-keys-restore");
    try {
        veracrypt_.mount(archive_path, mount_point, password, true);
        const std::filesystem::path manifest_path = find_container_manifest(mount_point);
        if (!std::filesystem::exists(manifest_path) || read_manifest_type(manifest_path) != "keys") {
            throw std::runtime_error("The selected .bak file is not a keys backup container");
        }

        const std::string expected_key_id = !runtime_config_->gpg_key_id.empty()
            ? runtime_config_->gpg_key_id
            : config_->gpg_key_id;
        validate_expected_secret_key_material(mount_point, expected_key_id);
        gpg_.merge_from_directory(mount_point);

        const std::string full_rebase_answer = prompt_input(
            "Restore Local Keys Backup",
            "Replace the entire local ~/.gnupg with the container copy? [y/N]",
            "N"
        );
        if (answer_is_yes(full_rebase_answer, false)) {
            const std::filesystem::path raw_dir = find_gnupg_backup_dir(mount_point);
            if (raw_dir.empty()) {
                throw std::runtime_error("No supported .gnupg backup directory was found inside the container");
            }

            const std::filesystem::path local_gnupg = gpg_.gnupg_directory();
            ensure_gnupg_backups_directory();
            const std::filesystem::path backup_dir =
                gnupg_backups_directory() / ("gnupg-rebase." + std::to_string(std::time(nullptr)));
            const syncpss::util::ProcessResult kill_agent = syncpss::util::run({"gpgconf", "--kill", "gpg-agent"});
            if (kill_agent.exit_code != 0) {
                throw std::runtime_error("gpgconf --kill gpg-agent failed: " + kill_agent.stderr_output);
            }
            if (std::filesystem::exists(local_gnupg)) {
                std::filesystem::rename(local_gnupg, backup_dir);
                prune_old_gnupg_backups();
            }
            std::filesystem::create_directories(local_gnupg);
            copy_live_gnupg_contents(raw_dir, local_gnupg);
            sanitize_live_gnupg_directory(local_gnupg);
            tighten_gnupg_permissions(local_gnupg);
        }

        veracrypt_.dismount(mount_point);
        std::filesystem::remove_all(mount_point);

        runtime_config_->gpg_keys_remote = true;
        syncpss::util::save_runtime_config(*runtime_config_);
        show_message(
            "Local Keys Restore Complete",
            {
                "Restored local GPG keys from:",
                archive_path.string()
            },
            kColorSuccess
        );
    } catch (...) {
        std::error_code ignored;
        if (std::filesystem::exists(mount_point)) {
            const syncpss::util::ProcessResult result =
                syncpss::util::run({"veracrypt", "--text", "--dismount", mount_point.string()});
            if (result.exit_code != 0) {
                std::filesystem::remove_all(mount_point, ignored);
            }
        }
        throw;
    }
}

}  // namespace syncpss::tui
