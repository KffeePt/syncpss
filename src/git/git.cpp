#include "git/git.hpp"

#include "util/paths.hpp"
#include "util/process.hpp"

#include <algorithm>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>

namespace syncpss::git {
namespace {

constexpr const char* kStoreHashFile = ".syncpss-store.sha256";

bool contains_conflict_marker(const std::string& text) {
    return text.find("CONFLICT") != std::string::npos;
}

void append_log(SyncReport& report, const GitClient::LogCallback& log_callback, const std::string& line) {
    report.log_lines.emplace_back(line);
    if (log_callback) {
        log_callback(line);
    }
}

std::string trim_newlines(std::string value) {
    while (!value.empty() && (value.back() == '\n' || value.back() == '\r')) {
        value.pop_back();
    }
    return value;
}

std::map<std::string, std::string> git_env_for_real_user() {
    const std::filesystem::path real_home = syncpss::util::get_real_home();
    const std::string real_user = syncpss::util::get_real_username();
    const std::filesystem::path runtime_dir = syncpss::util::get_real_xdg_runtime_dir();
    return {
        {"HOME", real_home.string()},
        {"GNUPGHOME", (real_home / ".gnupg").string()},
        {"XDG_RUNTIME_DIR", runtime_dir.string()},
        {"USER", real_user},
        {"LOGNAME", real_user},
        {"GPG_AGENT_INFO", ""}
    };
}

std::vector<std::string> git_command_as_real_user(const std::vector<std::string>& git_argv) {
    std::vector<std::string> argv;
    if (syncpss::util::is_root_user()) {
        const std::filesystem::path real_home = syncpss::util::get_real_home();
        const std::string real_user = syncpss::util::get_real_username();
        const std::filesystem::path runtime_dir = syncpss::util::get_real_xdg_runtime_dir();
        argv = {
            "sudo",
            "-H",
            "-u",
            real_user,
            "env",
            "HOME=" + real_home.string(),
            "GNUPGHOME=" + (real_home / ".gnupg").string(),
            "XDG_RUNTIME_DIR=" + runtime_dir.string(),
            "USER=" + real_user,
            "LOGNAME=" + real_user,
            "GPG_AGENT_INFO="
        };
        argv.insert(argv.end(), git_argv.begin(), git_argv.end());
        return argv;
    }
    return git_argv;
}

syncpss::util::ProcessOptions git_process_options(const std::filesystem::path& repository_path) {
    if (syncpss::util::is_root_user()) {
        return syncpss::util::ProcessOptions{repository_path.string()};
    }
    return syncpss::util::ProcessOptions{
        repository_path.string(),
        git_env_for_real_user()
    };
}

}  // namespace

GitClient::GitClient(std::filesystem::path repository_path, std::string branch)
    : repository_path_(std::move(repository_path)),
      branch_(std::move(branch)) {}

bool GitClient::is_git_repository() const {
    const std::vector<std::string> argv = git_command_as_real_user({"git", "rev-parse", "--is-inside-work-tree"});
    syncpss::util::ProcessResult result = syncpss::util::run(argv, git_process_options(repository_path_));
    return result.exit_code == 0 && result.stdout_output.find("true") != std::string::npos;
}

void GitClient::require_ok(const std::vector<std::string>& argv, const std::string& action) const {
    syncpss::util::ProcessResult result = run_git(argv, action);
    if (result.exit_code != 0) {
        throw std::runtime_error(action + " failed: " + result.stderr_output + result.stdout_output);
    }
}

syncpss::util::ProcessResult GitClient::run_git(
    const std::vector<std::string>& argv,
    const std::string& action
) const {
    syncpss::util::ProcessResult result = run_git_allow_failure(argv);
    if (result.exit_code != 0 && !action.empty()) {
        throw std::runtime_error(action + " failed: " + result.stderr_output + result.stdout_output);
    }
    return result;
}

syncpss::util::ProcessResult GitClient::run_git_allow_failure(const std::vector<std::string>& argv) const {
    const std::vector<std::string> command = git_command_as_real_user(argv);
    return syncpss::util::run(command, git_process_options(repository_path_));
}

std::string GitClient::iso8601_utc_now() const {
    const auto now = std::chrono::system_clock::now();
    const std::time_t now_time = std::chrono::system_clock::to_time_t(now);
    std::tm utc_time{};
#if defined(__APPLE__) || defined(__linux__)
    gmtime_r(&now_time, &utc_time);
#else
    utc_time = *std::gmtime(&now_time);
#endif
    char buffer[32]{};
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc_time);
    return buffer;
}

std::string GitClient::sha256_for_file(const std::filesystem::path& path) const {
    syncpss::util::ProcessResult result;
    if (syncpss::util::is_command_available("sha256sum")) {
        result = syncpss::util::run({"sha256sum", path.string()});
    } else if (syncpss::util::is_command_available("shasum")) {
        result = syncpss::util::run({"shasum", "-a", "256", path.string()});
    } else {
        throw std::runtime_error("sha256sum or shasum is required to hash the password store");
    }

    if (result.exit_code != 0) {
        throw std::runtime_error("Failed to hash file: " + path.string());
    }

    const std::size_t split = result.stdout_output.find_first_of(" \t");
    if (split == std::string::npos) {
        throw std::runtime_error("Unexpected hash output for file: " + path.string());
    }
    return result.stdout_output.substr(0, split);
}

std::string GitClient::compute_store_hash() const {
    std::vector<std::filesystem::path> files;
    auto iterator = std::filesystem::recursive_directory_iterator(repository_path_);
    for (const auto& entry : iterator) {
        const std::filesystem::path relative = std::filesystem::relative(entry.path(), repository_path_);
        if (relative.empty()) {
            continue;
        }

        const std::string first_component = relative.begin()->string();
        if (first_component == ".git") {
            if (entry.is_directory()) {
                iterator.disable_recursion_pending();
            }
            continue;
        }

        if (entry.is_regular_file()) {
            if (relative.filename() == kStoreHashFile) {
                continue;
            }
            files.push_back(relative);
        }
    }

    std::sort(files.begin(), files.end());

    std::ostringstream manifest;
    for (const auto& relative : files) {
        manifest << relative.generic_string() << '\t'
                 << sha256_for_file(repository_path_ / relative) << '\n';
    }

    syncpss::util::ProcessResult result;
    const std::string manifest_data = manifest.str();
    if (syncpss::util::is_command_available("sha256sum")) {
        result = syncpss::util::run({"sha256sum"}, syncpss::util::ProcessOptions{std::nullopt, std::nullopt, manifest_data});
    } else if (syncpss::util::is_command_available("shasum")) {
        result = syncpss::util::run({"shasum", "-a", "256"}, syncpss::util::ProcessOptions{std::nullopt, std::nullopt, manifest_data});
    } else {
        throw std::runtime_error("sha256sum or shasum is required to hash the password store manifest");
    }

    if (result.exit_code != 0) {
        throw std::runtime_error("Failed to hash store manifest");
    }

    const std::size_t split = result.stdout_output.find_first_of(" \t");
    if (split == std::string::npos) {
        throw std::runtime_error("Unexpected hash output for store manifest");
    }
    return result.stdout_output.substr(0, split);
}

std::string GitClient::next_store_version() const {
    const std::vector<std::string> argv = git_command_as_real_user({"git", "tag", "--list", "v0.0.*"});
    const syncpss::util::ProcessResult result = syncpss::util::run(argv, git_process_options(repository_path_));
    if (result.exit_code != 0) {
        throw std::runtime_error("git tag --list failed: " + result.stderr_output);
    }

    int max_patch = 0;
    std::stringstream lines(result.stdout_output);
    std::string line;
    while (std::getline(lines, line)) {
        if (line.rfind("v0.0.", 0) != 0) {
            continue;
        }
        const std::string patch_text = line.substr(5);
        try {
            max_patch = std::max(max_patch, std::stoi(patch_text));
        } catch (const std::exception&) {
            continue;
        }
    }

    std::ostringstream version;
    version << "0.0." << std::setw(4) << std::setfill('0') << (max_patch + 1);
    return version.str();
}

void GitClient::write_store_hash_file(const std::string& version) const {
    std::ofstream output(repository_path_ / kStoreHashFile, std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Cannot write " + std::string(kStoreHashFile));
    }
    output << compute_store_hash() << "  v" << version << '\n';
}

void GitClient::create_store_version_tag(const std::string& version) const {
    const std::string tag_name = "v" + version;
    const syncpss::util::ProcessResult existing_tag = run_git_allow_failure(
        {"git", "show-ref", "--tags", "--verify", "refs/tags/" + tag_name}
    );
    if (existing_tag.exit_code != 0) {
        require_ok({"git", "tag", "-a", tag_name, "-m", "pass-store " + tag_name}, "git tag");
    }
    require_ok({"git", "push", "origin", tag_name}, "git push tag");
}

std::string GitClient::current_head_short() const {
    const syncpss::util::ProcessResult result = run_git(
        {"git", "rev-parse", "--short", "HEAD"},
        "git rev-parse --short HEAD"
    );
    std::string hash = result.stdout_output;
    while (!hash.empty() && (hash.back() == '\n' || hash.back() == '\r')) {
        hash.pop_back();
    }
    return hash;
}

int GitClient::commits_ahead_of_origin() const {
    const syncpss::util::ProcessResult result = run_git(
        {"git", "rev-list", "--count", "origin/" + branch_ + "..HEAD"},
        "git rev-list --count origin/" + branch_ + "..HEAD"
    );
    const std::string count_text = trim_newlines(result.stdout_output);
    if (count_text.empty()) {
        return 0;
    }
    return std::stoi(count_text);
}

std::vector<std::string> GitClient::parse_paths(const std::string& output) const {
    std::set<std::string> unique_paths;
    std::stringstream lines(output);
    std::string line;
    while (std::getline(lines, line)) {
        if (!line.empty()) {
            unique_paths.insert(line);
        }
    }
    return {unique_paths.begin(), unique_paths.end()};
}

std::vector<std::string> GitClient::head_store_version_tags() const {
    const syncpss::util::ProcessResult result = run_git(
        {"git", "tag", "--points-at", "HEAD", "--list", "v0.0.*"},
        "git tag --points-at HEAD"
    );
    return parse_paths(result.stdout_output);
}

std::vector<std::string> GitClient::conflict_paths() const {
    const syncpss::util::ProcessResult result = run_git_allow_failure(
        {"git", "diff", "--name-only", "--diff-filter=U"}
    );
    if (result.exit_code != 0) {
        return {};
    }
    return parse_paths(result.stdout_output);
}

std::string GitClient::merge_base_with_origin() const {
    const syncpss::util::ProcessResult result = run_git(
        {"git", "merge-base", "HEAD", "origin/" + branch_},
        "git merge-base HEAD origin/" + branch_
    );
    const std::string merge_base = trim_newlines(result.stdout_output);
    if (merge_base.empty()) {
        throw std::runtime_error("git merge-base returned an empty merge base");
    }
    return merge_base;
}

std::string GitClient::diff_for_path(const std::vector<std::string>& argv, const std::string& action) const {
    const syncpss::util::ProcessResult result = run_git(argv, action);
    return trim_newlines(result.stdout_output);
}

SyncPreview GitClient::build_preview(bool include_worktree) const {
    SyncPreview preview;
    const std::string merge_base = merge_base_with_origin();
    const std::vector<std::string> local_path_args = include_worktree
        ? std::vector<std::string>{"git", "diff", "--name-only", merge_base}
        : std::vector<std::string>{"git", "diff", "--name-only", merge_base + "..HEAD"};
    const std::vector<std::string> remote_path_args = {
        "git",
        "diff",
        "--name-only",
        merge_base + "..origin/" + branch_
    };

    const std::vector<std::string> local_paths = parse_paths(
        run_git(local_path_args, "git diff --name-only local").stdout_output
    );
    const std::vector<std::string> remote_paths = parse_paths(
        run_git(remote_path_args, "git diff --name-only remote").stdout_output
    );

    std::set<std::string> local_set(local_paths.begin(), local_paths.end());
    std::set<std::string> remote_set(remote_paths.begin(), remote_paths.end());
    std::set<std::string> union_paths(local_set.begin(), local_set.end());
    union_paths.insert(remote_set.begin(), remote_set.end());

    for (const std::string& path : union_paths) {
        ConflictFilePreview file;
        file.path = path;
        file.changed_locally = local_set.count(path) > 0U;
        file.changed_remotely = remote_set.count(path) > 0U;
        if (file.changed_locally) {
            const std::vector<std::string> argv = include_worktree
                ? std::vector<std::string>{"git", "diff", "--no-ext-diff", "--unified=3", merge_base, "--", path}
                : std::vector<std::string>{"git", "diff", "--no-ext-diff", "--unified=3", merge_base + "..HEAD", "--", path};
            file.local_diff = diff_for_path(argv, "git diff local path");
        }
        if (file.changed_remotely) {
            file.remote_diff = diff_for_path(
                {"git", "diff", "--no-ext-diff", "--unified=3", merge_base + "..origin/" + branch_, "--", path},
                "git diff remote path"
            );
        }
        if (file.changed_locally && file.changed_remotely) {
            preview.overlapping_paths.push_back(path);
        } else if (file.changed_locally) {
            preview.local_only_paths.push_back(path);
        } else if (file.changed_remotely) {
            preview.remote_only_paths.push_back(path);
        }
        preview.files.push_back(std::move(file));
    }

    return preview;
}

bool GitClient::path_exists_in_revision(const std::string& revision, const std::string& path) const {
    const syncpss::util::ProcessResult result = run_git_allow_failure(
        {"git", "cat-file", "-e", revision + ":" + path}
    );
    return result.exit_code == 0;
}

std::string GitClient::stage_and_commit_local_changes(SyncReport& report, const LogCallback& log_callback) const {
    append_log(report, log_callback, "Inspecting local password-store status...");
    const syncpss::util::ProcessResult status = run_git({"git", "status", "--porcelain"}, "git status --porcelain");
    const bool had_local_changes = !status.stdout_output.empty();
    int changed_file_count = 0;
    {
        std::stringstream status_lines(status.stdout_output);
        std::string line;
        while (std::getline(status_lines, line)) {
            if (!line.empty()) {
                ++changed_file_count;
            }
        }
    }
    append_log(report, log_callback, had_local_changes
        ? "Local changes detected: " + std::to_string(changed_file_count) + " file(s)"
        : "No local password-store changes detected");

    std::string store_version;
    if (had_local_changes) {
        store_version = next_store_version();
        write_store_hash_file(store_version);
        append_log(report, log_callback, "Updated " + std::string(kStoreHashFile) + " for v" + store_version);
    }

    append_log(report, log_callback, "Staging local changes...");
    require_ok({"git", "add", "-A"}, "git add -A");
    append_log(report, log_callback, "Staged local changes");

    const syncpss::util::ProcessResult staged = run_git(
        {"git", "diff", "--cached", "--stat"},
        "git diff --cached --stat"
    );

    if (staged.stdout_output.empty()) {
        append_log(report, log_callback, "Nothing new to commit");
        return store_version;
    }

    append_log(report, log_callback, "Creating local sync commit...");
    require_ok({"git", "commit", "-m", "syncpss: " + iso8601_utc_now()}, "git commit");
    append_log(report, log_callback, "Committed staged changes");
    append_log(report, log_callback, "Current commit: " + current_head_short());
    return store_version;
}

std::string GitClient::ensure_store_version_tracking(
    SyncReport& report,
    const LogCallback& log_callback,
    const std::string& commit_reason
) const {
    if (!report.store_version.empty()) {
        return report.store_version;
    }

    const std::vector<std::string> existing_head_tags = head_store_version_tags();
    if (!existing_head_tags.empty()) {
        const std::string existing_tag = existing_head_tags.front();
        const std::string existing_version =
            existing_tag.size() > 1U && existing_tag.front() == 'v' ? existing_tag.substr(1U) : existing_tag;
        append_log(report, log_callback, "HEAD already carries store version tag " + existing_tag);
        report.store_version = existing_version;
        return report.store_version;
    }

    if (commits_ahead_of_origin() <= 0) {
        return report.store_version;
    }

    report.store_version = next_store_version();
    write_store_hash_file(report.store_version);
    append_log(
        report,
        log_callback,
        "Version tracking required before push. Updated " + std::string(kStoreHashFile) + " for v" + report.store_version
    );
    require_ok({"git", "add", "--", kStoreHashFile}, "git add store hash file");
    require_ok(
        {"git", "commit", "-m", "syncpss: " + commit_reason + " " + iso8601_utc_now()},
        "git commit version tracking"
    );
    append_log(report, log_callback, "Committed store version tracking as v" + report.store_version);
    append_log(report, log_callback, "Current commit: " + current_head_short());
    return report.store_version;
}

void GitClient::remove_local_password_entries() const {
    std::vector<std::filesystem::path> files_to_remove;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(repository_path_)) {
        const std::filesystem::path relative = std::filesystem::relative(entry.path(), repository_path_);
        if (relative.empty()) {
            continue;
        }
        const std::string first_component = relative.begin()->string();
        if (first_component == ".git") {
            continue;
        }
        if (!entry.is_regular_file() || entry.path().extension() != ".gpg") {
            continue;
        }
        files_to_remove.push_back(entry.path());
    }

    for (const auto& path : files_to_remove) {
        std::filesystem::remove(path);
    }

    std::vector<std::filesystem::path> directories;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(repository_path_)) {
        if (!entry.is_directory()) {
            continue;
        }
        const std::filesystem::path relative = std::filesystem::relative(entry.path(), repository_path_);
        if (relative.empty()) {
            continue;
        }
        const std::string first_component = relative.begin()->string();
        if (first_component == ".git") {
            continue;
        }
        directories.push_back(entry.path());
    }

    std::sort(directories.begin(), directories.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.string().size() > rhs.string().size();
    });
    for (const auto& directory : directories) {
        std::error_code ignored;
        std::filesystem::remove(directory, ignored);
    }
}

SyncReport GitClient::sync(const LogCallback& log_callback) const {
    if (!is_git_repository()) {
        throw std::runtime_error("Store path is not a git repository: " + repository_path_.string());
    }

    SyncReport report;

    append_log(report, log_callback, "Preparing sync configuration...");
    require_ok({"git", "config", "pull.rebase", "false"}, "git config pull.rebase false");
    append_log(report, log_callback, "Configured pull.rebase=false");

    append_log(report, log_callback, "Fetching latest changes and tags from origin...");
    require_ok({"git", "fetch", "--tags", "origin"}, "git fetch --tags origin");
    append_log(report, log_callback, "Fetched latest changes and tags from origin");

    report.store_version = stage_and_commit_local_changes(report, log_callback);
    ensure_store_version_tracking(report, log_callback, "track store update");

    append_log(report, log_callback, "Pulling remote updates from origin/" + branch_ + "...");
    const std::vector<std::string> pull_argv = git_command_as_real_user({"git", "pull", "--no-rebase", "origin", branch_});
    syncpss::util::ProcessResult pull = syncpss::util::run(pull_argv, git_process_options(repository_path_));
    if (pull.exit_code != 0) {
        if (contains_conflict_marker(pull.stdout_output) || contains_conflict_marker(pull.stderr_output)) {
            report.had_conflicts = true;
            report.conflicts = conflict_paths();
            report.preview = build_preview(false);
            for (auto& file : report.preview.files) {
                file.has_unmerged_conflict =
                    std::find(report.conflicts.begin(), report.conflicts.end(), file.path) != report.conflicts.end();
            }
            append_log(report, log_callback, "Merge conflict detected");
            return report;
        }
        throw std::runtime_error("git pull failed: " + pull.stderr_output + pull.stdout_output);
    }
    append_log(report, log_callback, "Pulled latest changes");

    append_log(report, log_callback, "Pushing local branch to origin/" + branch_ + "...");
    require_ok({"git", "push", "origin", branch_}, "git push");
    append_log(report, log_callback, "Pushed local branch to origin/" + branch_);
    if (!report.store_version.empty()) {
        append_log(report, log_callback, "Publishing store version tag v" + report.store_version + "...");
        create_store_version_tag(report.store_version);
        append_log(report, log_callback, "Tagged store state as v" + report.store_version);
    }
    append_log(report, log_callback, "HEAD ready for testing: " + current_head_short());
    return report;
}

SyncReport GitClient::fetch_preview(const LogCallback& log_callback) const {
    if (!is_git_repository()) {
        throw std::runtime_error("Store path is not a git repository: " + repository_path_.string());
    }

    SyncReport report;
    append_log(report, log_callback, "Fetching latest changes and tags from origin...");
    require_ok({"git", "fetch", "--tags", "origin"}, "git fetch --tags origin");
    append_log(report, log_callback, "Fetched latest changes and tags from origin");
    report.preview = build_preview(true);
    append_log(
        report,
        log_callback,
        "Preview ready: " +
            std::to_string(report.preview.overlapping_paths.size()) + " overlapping, " +
            std::to_string(report.preview.remote_only_paths.size()) + " remote-only, " +
            std::to_string(report.preview.local_only_paths.size()) + " local-only file(s)"
    );
    return report;
}

SyncReport GitClient::prepare_sync(const LogCallback& log_callback) const {
    if (!is_git_repository()) {
        throw std::runtime_error("Store path is not a git repository: " + repository_path_.string());
    }

    SyncReport report;
    append_log(report, log_callback, "Preparing sync configuration...");
    require_ok({"git", "config", "pull.rebase", "false"}, "git config pull.rebase false");
    append_log(report, log_callback, "Configured pull.rebase=false");

    append_log(report, log_callback, "Fetching latest changes and tags from origin...");
    require_ok({"git", "fetch", "--tags", "origin"}, "git fetch --tags origin");
    append_log(report, log_callback, "Fetched latest changes and tags from origin");

    report.store_version = stage_and_commit_local_changes(report, log_callback);
    ensure_store_version_tracking(report, log_callback, "track store update");
    report.preview = build_preview(false);
    append_log(
        report,
        log_callback,
        "Interactive review ready for " + std::to_string(report.preview.overlapping_paths.size()) +
            " overlapping file(s)"
    );
    return report;
}

void GitClient::push_current_branch(bool force, const LogCallback& log_callback) const {
    if (log_callback) {
        log_callback(
            std::string(force ? "Force pushing" : "Pushing") + " local branch to origin/" + branch_ + "..."
        );
    }

    std::vector<std::string> argv = {"git", "push"};
    if (force) {
        argv.push_back("--force");
    }
    argv.push_back("origin");
    argv.push_back(branch_);
    require_ok(argv, force ? "git push --force" : "git push");

    if (log_callback) {
        log_callback(
            std::string(force ? "Force pushed" : "Pushed") + " local branch to origin/" + branch_
        );
    }
}

SyncReport GitClient::push_force(const LogCallback& log_callback) const {
    if (!is_git_repository()) {
        throw std::runtime_error("Store path is not a git repository: " + repository_path_.string());
    }

    SyncReport report;
    append_log(report, log_callback, "Fetching latest changes and tags from origin before force push...");
    require_ok({"git", "fetch", "--tags", "origin"}, "git fetch --tags origin");
    append_log(report, log_callback, "Fetched latest changes and tags from origin");
    report.store_version = stage_and_commit_local_changes(report, log_callback);
    ensure_store_version_tracking(report, log_callback, "track store update");
    push_current_branch(true, [&](const std::string& line) { append_log(report, log_callback, line); });
    if (!report.store_version.empty()) {
        append_log(report, log_callback, "Publishing store version tag v" + report.store_version + "...");
        create_store_version_tag(report.store_version);
        append_log(report, log_callback, "Tagged store state as v" + report.store_version);
    }
    append_log(report, log_callback, "HEAD ready for testing: " + current_head_short());
    return report;
}

SyncReport GitClient::pull_force(const LogCallback& log_callback) const {
    if (!is_git_repository()) {
        throw std::runtime_error("Store path is not a git repository: " + repository_path_.string());
    }
    if (has_merge_in_progress()) {
        throw std::runtime_error("A merge is already in progress. Finish or abort it before force pulling.");
    }

    SyncReport report;
    append_log(report, log_callback, "Fetching latest changes and tags from origin...");
    require_ok({"git", "fetch", "--tags", "origin"}, "git fetch --tags origin");
    append_log(report, log_callback, "Fetched latest changes and tags from origin");
    append_log(report, log_callback, "Resetting local branch to origin/" + branch_ + "...");
    require_ok({"git", "checkout", branch_}, "git checkout branch");
    require_ok({"git", "reset", "--hard", "origin/" + branch_}, "git reset --hard origin branch");
    append_log(report, log_callback, "Local branch now matches origin/" + branch_);
    append_log(report, log_callback, "HEAD ready for testing: " + current_head_short());
    return report;
}

SyncReport GitClient::nuke_passwords(bool include_remote, const LogCallback& log_callback) const {
    if (!is_git_repository()) {
        throw std::runtime_error("Store path is not a git repository: " + repository_path_.string());
    }
    if (has_merge_in_progress()) {
        throw std::runtime_error("A merge is already in progress. Finish or abort it before nuking the store.");
    }

    SyncReport report;
    append_log(report, log_callback, "Removing local encrypted password entries...");
    remove_local_password_entries();
    append_log(report, log_callback, "Local password entries removed");

    report.store_version = next_store_version();
    write_store_hash_file(report.store_version);
    append_log(report, log_callback, "Updated " + std::string(kStoreHashFile) + " for v" + report.store_version);

    require_ok({"git", "add", "-A"}, "git add -A");
    const syncpss::util::ProcessResult staged = run_git(
        {"git", "diff", "--cached", "--stat"},
        "git diff --cached --stat"
    );
    if (staged.stdout_output.empty()) {
        append_log(report, log_callback, "No password entries were available to remove");
        return report;
    }

    require_ok({"git", "commit", "-m", "syncpss: nuke passwords " + iso8601_utc_now()}, "git commit");
    append_log(report, log_callback, "Committed nuked password-store state");
    if (include_remote) {
        ensure_store_version_tracking(report, log_callback, "track store update");
        push_current_branch(true, [&](const std::string& line) { append_log(report, log_callback, line); });
        append_log(report, log_callback, "Publishing store version tag v" + report.store_version + "...");
        create_store_version_tag(report.store_version);
        append_log(report, log_callback, "Tagged store state as v" + report.store_version);
    }
    append_log(report, log_callback, "HEAD ready for testing: " + current_head_short());
    return report;
}

void GitClient::resolve_conflict(const std::string& path, ConflictChoice choice) const {
    if (choice == ConflictChoice::Abort) {
        abort_merge();
        return;
    }

    const std::string side = choice == ConflictChoice::KeepLocal ? "--ours" : "--theirs";
    const syncpss::util::ProcessResult side_result = run_git_allow_failure({"git", "checkout", side, "--", path});
    if (side_result.exit_code != 0) {
        const std::string revision = choice == ConflictChoice::KeepLocal ? "HEAD" : "origin/" + branch_;
        if (path_exists_in_revision(revision, path)) {
            require_ok({"git", "checkout", revision, "--", path}, "git checkout conflict revision");
            require_ok({"git", "add", "--", path}, "git add resolved file");
            return;
        }
        require_ok({"git", "rm", "-f", "--", path}, "git rm resolved file");
        return;
    }
    require_ok({"git", "add", "--", path}, "git add resolved file");
}

void GitClient::finalize_merge_commit(const std::string& version) const {
    if (!conflict_paths().empty()) {
        throw std::runtime_error("Cannot finalize merge while conflicts remain");
    }
    if (!std::filesystem::exists(repository_path_ / ".git" / "MERGE_HEAD")) {
        return;
    }

    const std::string resolved_version = version.empty() ? next_store_version() : version;
    write_store_hash_file(resolved_version);
    require_ok({"git", "add", "-A"}, "git add -A");
    require_ok(
        {"git", "commit", "-m", "syncpss: resolve conflicts " + iso8601_utc_now()},
        "git commit merge resolution"
    );
    require_ok({"git", "push", "origin", branch_}, "git push after conflict resolution");
    create_store_version_tag(resolved_version);
}

void GitClient::abort_merge() const {
    require_ok({"git", "merge", "--abort"}, "git merge --abort");
}

void GitClient::start_merge_from_origin() const {
    if (has_merge_in_progress()) {
        return;
    }

    const syncpss::util::ProcessResult result = run_git_allow_failure(
        {"git", "merge", "--no-commit", "--no-ff", "origin/" + branch_}
    );
    if (result.exit_code == 0) {
        return;
    }
    if (contains_conflict_marker(result.stdout_output) || contains_conflict_marker(result.stderr_output) ||
        !conflict_paths().empty()) {
        return;
    }
    throw std::runtime_error("git merge --no-commit --no-ff failed: " + result.stderr_output + result.stdout_output);
}

bool GitClient::has_merge_in_progress() const {
    return std::filesystem::exists(repository_path_ / ".git" / "MERGE_HEAD");
}

bool GitClient::has_unmerged_conflicts() const {
    return !conflict_paths().empty();
}

void GitClient::stage_file(const std::string& path) const {
    if (std::filesystem::exists(repository_path_ / path)) {
        require_ok({"git", "add", "--", path}, "git add file");
        return;
    }
    require_ok({"git", "rm", "-f", "--", path}, "git rm file");
}

}  // namespace syncpss::git
