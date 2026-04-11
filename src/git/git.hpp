#pragma once

#include "git/conflict.hpp"
#include "util/process.hpp"

#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace syncpss::git {

class GitClient {
public:
    using LogCallback = std::function<void(const std::string&)>;

    GitClient(std::filesystem::path repository_path, std::string branch);

    bool is_git_repository() const;
    SyncReport sync(const LogCallback& log_callback = {}) const;
    SyncReport fetch_preview(const LogCallback& log_callback = {}) const;
    SyncReport prepare_sync(const LogCallback& log_callback = {}) const;
    SyncReport push_force(const LogCallback& log_callback = {}) const;
    SyncReport pull_force(const LogCallback& log_callback = {}) const;
    SyncReport nuke_passwords(bool include_remote, const LogCallback& log_callback = {}) const;
    std::vector<std::string> conflict_paths() const;
    void resolve_conflict(const std::string& path, ConflictChoice choice) const;
    void finalize_merge_commit(const std::string& version = "") const;
    void abort_merge() const;
    void start_merge_from_origin() const;
    bool has_merge_in_progress() const;
    bool has_unmerged_conflicts() const;
    void stage_file(const std::string& path) const;
    void push_current_branch(bool force, const LogCallback& log_callback = {}) const;

private:
    std::filesystem::path repository_path_;
    std::string branch_;

    int commits_ahead_of_origin() const;
    std::vector<std::string> parse_paths(const std::string& output) const;
    std::vector<std::string> head_store_version_tags() const;
    SyncPreview build_preview(bool include_worktree) const;
    std::string diff_for_path(const std::vector<std::string>& argv, const std::string& action) const;
    std::string merge_base_with_origin() const;
    bool path_exists_in_revision(const std::string& revision, const std::string& path) const;
    std::string stage_and_commit_local_changes(SyncReport& report, const LogCallback& log_callback) const;
    std::string ensure_store_version_tracking(
        SyncReport& report,
        const LogCallback& log_callback,
        const std::string& commit_reason
    ) const;
    void remove_local_password_entries() const;
    void require_ok(const std::vector<std::string>& argv, const std::string& action) const;
    syncpss::util::ProcessResult run_git(const std::vector<std::string>& argv, const std::string& action) const;
    syncpss::util::ProcessResult run_git_allow_failure(const std::vector<std::string>& argv) const;
    std::string iso8601_utc_now() const;
    std::string next_store_version() const;
    std::string compute_store_hash() const;
    std::string sha256_for_file(const std::filesystem::path& path) const;
    void write_store_hash_file(const std::string& version) const;
    void create_store_version_tag(const std::string& version) const;
    std::string current_head_short() const;
};

}  // namespace syncpss::git
