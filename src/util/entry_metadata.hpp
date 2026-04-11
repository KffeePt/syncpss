#pragma once

#include <map>
#include <string>

namespace syncpss::util {

enum class EntryMode {
    Unknown,
    Manual,
    Combo
};

std::string to_string(EntryMode mode);
EntryMode entry_mode_from_string(const std::string& value);

EntryMode preferred_entry_mode(const std::string& entry_name);
std::string telemetry_mode_label();
void record_entry_creation(const std::string& entry_name, EntryMode mode);
void record_entry_modification(const std::string& previous_entry_name, const std::string& entry_name, EntryMode mode);
void record_entry_deletion(const std::string& entry_name);
void record_recursive_entry_deletion(const std::string& folder_prefix);
void record_runtime_event(const std::string& event_name, const std::string& message, const std::map<std::string, std::string>& details = {});

}  // namespace syncpss::util
