#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/release.hpp"
#include "tui/detail/render.hpp"

namespace syncpss::tui {
using namespace detail;

void TuiApp::backup_keys_to_remote() {
    if (!config_.has_value() || !runtime_config_.has_value() || !git_ || !store_) {
        throw std::runtime_error("Setup must complete before backing up GPG keys");
    }

    const std::string password = prompt_input("Backup GPG Keys", "VeraCrypt container password:", "", true);
    if (password.empty()) {
        return;
    }
    const std::string confirmation = prompt_input("Backup GPG Keys", "Confirm VeraCrypt container password:", "", true);
    if (confirmation != password) {
        throw std::runtime_error("Container passwords did not match");
    }

    const std::filesystem::path staging_volume = syncpss::util::runtime_directory() / "keys.vc";
    const std::filesystem::path mount_point = syncpss::util::create_secure_temp_directory("syncpss-vc-backup");
    const std::filesystem::path remote_keys = config_->store_path / "keys";

    if (std::filesystem::exists(staging_volume)) {
        secure_remove_file(staging_volume);
    }

    try {
        veracrypt_.create_volume(staging_volume, container_size_mb_for(gpg_.gnupg_directory()), password);
        veracrypt_.mount(staging_volume, mount_point, password);
        gpg_.export_to_directory(mount_point);
        write_manifest_file(
            mount_point,
            "keys",
            {
                {"manifest.xml", "Container manifest describing the portable GPG key backup."},
                {"pubkeys.asc", "Exported public keys from the GPG keyring stored in this container."},
                {"seckeys.asc", "Exported secret keys from the GPG keyring stored in this container."},
                {"ownertrust.txt", "Ownertrust assignments associated with the exported GPG keys."},
                {".gnupg/", "Raw .gnupg directory snapshot used for full keyring rebase and recovery."}
            }
        );
        veracrypt_.dismount(mount_point);
        std::filesystem::copy_file(staging_volume, remote_keys, std::filesystem::copy_options::overwrite_existing);
        secure_remove_file(staging_volume);
        std::filesystem::remove_all(mount_point);

        runtime_config_->gpg_keys_remote = true;
        syncpss::util::save_runtime_config(*runtime_config_);

        syncpss::git::SyncReport report = git_->sync();
        if (report.had_conflicts) {
            resolve_conflicts(report.conflicts);
        }

        show_message(
            "GPG Backup Complete",
            {
                "Encrypted GPG key container copied to " + remote_keys.string(),
                "Runtime config updated.",
                "Remote sync completed."
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
        if (std::filesystem::exists(staging_volume)) {
            secure_remove_file(staging_volume);
        }
        throw;
    }
}

void TuiApp::restore_keys_from_remote() {
    if (!config_.has_value() || !runtime_config_.has_value()) {
        throw std::runtime_error("Setup must complete before restoring GPG keys");
    }

    const std::filesystem::path remote_keys = config_->store_path / "keys";
    if (!std::filesystem::exists(remote_keys)) {
        throw std::runtime_error("No encrypted GPG key container exists at " + remote_keys.string());
    }

    const std::string password = prompt_input("Restore GPG Keys", "VeraCrypt container password:", "", true);
    if (password.empty()) {
        return;
    }

    const std::filesystem::path mount_point = syncpss::util::create_secure_temp_directory("syncpss-vc-restore");

    try {
        veracrypt_.mount(remote_keys, mount_point, password, true);
        const std::filesystem::path manifest_path = find_container_manifest(mount_point);
        if (std::filesystem::exists(manifest_path) && read_manifest_type(manifest_path) != "keys") {
            throw std::runtime_error("The selected container is not a keys container");
        }
        const std::string expected_key_id = !runtime_config_->gpg_key_id.empty()
            ? runtime_config_->gpg_key_id
            : config_->gpg_key_id;
        validate_expected_secret_key_material(mount_point, expected_key_id);
        gpg_.merge_from_directory(mount_point);

        const std::string full_rebase_answer = prompt_input(
            "Restore GPG Keys",
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
            syncpss::util::ProcessResult kill_agent = syncpss::util::run({"gpgconf", "--kill", "gpg-agent"});
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

        if (!runtime_config_->gpg_key_id.empty() && !gpg_.key_exists(runtime_config_->gpg_key_id)) {
            throw std::runtime_error("Expected GPG key is still missing after restore: " + runtime_config_->gpg_key_id);
        }

        show_message(
            "GPG Restore Complete",
            {
                "GPG keys were imported from the encrypted remote container.",
                "Runtime config updated."
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
