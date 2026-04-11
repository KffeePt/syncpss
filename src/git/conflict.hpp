#pragma once

#include <string>
#include <vector>

namespace syncpss::git {

enum class ConflictChoice {
    KeepLocal,
    KeepRemote,
    Abort
};

struct ConflictFilePreview {
    std::string path;
    bool changed_locally = false;
    bool changed_remotely = false;
    bool has_unmerged_conflict = false;
    std::string local_diff;
    std::string remote_diff;
};

struct SyncPreview {
    std::vector<ConflictFilePreview> files;
    std::vector<std::string> overlapping_paths;
    std::vector<std::string> local_only_paths;
    std::vector<std::string> remote_only_paths;
};

struct SyncReport {
    std::vector<std::string> log_lines;
    bool had_conflicts = false;
    std::vector<std::string> conflicts;
    std::string store_version;
    SyncPreview preview;
};

}  // namespace syncpss::git
