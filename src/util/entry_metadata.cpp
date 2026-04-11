#include "util/entry_metadata.hpp"

#include "util/paths.hpp"
#include "util/process.hpp"
#include "util/runtime_config.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace syncpss::util {
namespace {

using json = nlohmann::json;

struct MetadataPreferences {
    bool enabled = false;
    bool hostname = false;
    bool ip = false;
    bool mac = false;
    bool full_telemetry = false;
    std::string mode = "off";
};

std::filesystem::path metadata_path() {
    return runtime_logs_directory() / "metadata.json";
}

std::filesystem::path legacy_metadata_path() {
    return runtime_directory() / "metadata.json";
}

std::filesystem::path logs_directory() {
    return runtime_logs_directory();
}

std::filesystem::path runtime_log_path() {
    const auto now = std::chrono::system_clock::now();
    const std::time_t now_time = std::chrono::system_clock::to_time_t(now);
    std::tm utc_time{};
#if defined(__APPLE__) || defined(__linux__)
    gmtime_r(&now_time, &utc_time);
#else
    utc_time = *std::gmtime(&now_time);
#endif
    char buffer[32]{};
    std::strftime(buffer, sizeof(buffer), "runtime-%Y%m%d.jsonl", &utc_time);
    return logs_directory() / buffer;
}

std::string trim_copy(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1U);
}

std::string iso8601_utc_now() {
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

std::string local_hostname() {
    char buffer[256]{};
    if (::gethostname(buffer, sizeof(buffer) - 1) == 0) {
        return trim_copy(buffer);
    }
    return "";
}

std::string first_token(const std::string& value) {
    std::stringstream input(value);
    std::string token;
    input >> token;
    return trim_copy(token);
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

std::string local_ip_address() {
    const ProcessResult route = run({"sh", "-lc", "hostname -I 2>/dev/null || true"});
    std::string candidate = first_token(route.stdout_output);
    if (!candidate.empty()) {
        return candidate;
    }

    const ProcessResult fallback = run(
        {"sh", "-lc", "ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==\"src\") {print $(i+1); exit}}'"}
    );
    return first_token(fallback.stdout_output);
}

std::string local_mac_address() {
    const ProcessResult result = run(
        {"sh", "-lc", "ip link 2>/dev/null | awk '/link\\/ether/ {print $2; exit}'"}
    );
    return first_token(result.stdout_output);
}

std::string command_output_first_line(const std::vector<std::string>& argv) {
    const ProcessResult result = run(argv);
    if (result.exit_code != 0) {
        return "";
    }
    std::stringstream input(result.stdout_output);
    std::string line;
    std::getline(input, line);
    return trim_copy(line);
}

std::string coordinates_from_termux() {
    if (!is_command_available("termux-location")) {
        return "";
    }

    const ProcessResult result = run({"termux-location"});
    if (result.exit_code != 0) {
        return "";
    }

    try {
        const json payload = json::parse(result.stdout_output);
        if (!payload.contains("latitude") || !payload.contains("longitude")) {
            return "";
        }
        if (!payload["latitude"].is_number() || !payload["longitude"].is_number()) {
            return "";
        }

        std::ostringstream rendered;
        rendered << payload["latitude"].get<double>() << "," << payload["longitude"].get<double>();
        return trim_copy(rendered.str());
    } catch (const std::exception&) {
        return "";
    }
}

std::string coordinates_from_windows_location() {
    if (!is_command_available("powershell.exe")) {
        return "";
    }

    const ProcessResult result = run(
        {
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-Command",
            "$ErrorActionPreference='SilentlyContinue';"
            "Add-Type -AssemblyName System.Device;"
            "$watcher = New-Object System.Device.Location.GeoCoordinateWatcher;"
            "if (-not $watcher.TryStart($false, [TimeSpan]::FromSeconds(3))) { exit 0 };"
            "$coord = $watcher.Position.Location;"
            "if ($coord -and -not $coord.IsUnknown) { "
            "'{0},{1}' -f "
            "$coord.Latitude.ToString([System.Globalization.CultureInfo]::InvariantCulture),"
            "$coord.Longitude.ToString([System.Globalization.CultureInfo]::InvariantCulture) }"
        }
    );
    if (result.exit_code != 0) {
        return "";
    }
    return first_token(result.stdout_output);
}

std::string approximate_coordinates() {
    const std::string termux = coordinates_from_termux();
    if (!termux.empty()) {
        return termux;
    }
    return coordinates_from_windows_location();
}

json full_system_snapshot() {
    json payload = json::object();
    const std::string os = command_output_first_line({"sh", "-lc", "uname -srmo 2>/dev/null || true"});
    const std::string cpu_model = command_output_first_line(
        {"sh", "-lc", "awk -F: '/model name/ {gsub(/^ +/,\"\",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null"}
    );
    const std::string cpu_count = command_output_first_line({"sh", "-lc", "nproc 2>/dev/null || true"});
    const std::string ram_kb = command_output_first_line(
        {"sh", "-lc", "awk '/MemTotal/ {print $2; exit}' /proc/meminfo 2>/dev/null"}
    );
    if (!os.empty()) {
        payload["os"] = os;
    }
    if (!cpu_model.empty()) {
        payload["cpu_model"] = cpu_model;
    }
    if (!cpu_count.empty()) {
        payload["cpu_count"] = cpu_count;
    }
    if (!ram_kb.empty()) {
        payload["ram_kb"] = ram_kb;
    }
    const std::string coordinates = approximate_coordinates();
    if (!coordinates.empty()) {
        payload["coordinates"] = coordinates;
    }
    return payload;
}

const json& cached_system_snapshot() {
    static const json snapshot = full_system_snapshot();
    return snapshot;
}

MetadataPreferences metadata_preferences() {
    if (!runtime_config_exists()) {
        return {};
    }

    try {
        const RuntimeConfig config = load_runtime_config();
        return MetadataPreferences{
            config.telemetry_mode != "off",
            config.telemetry_mode == "on",
            config.telemetry_mode == "on",
            config.telemetry_mode == "on",
            config.telemetry_mode == "on",
            config.telemetry_mode
        };
    } catch (const std::exception&) {
        return {};
    }
}

json event_payload(const std::string& entry_name, EntryMode mode) {
    const MetadataPreferences preferences = metadata_preferences();
    json payload = {
        {"entry", entry_name},
        {"path", entry_name},
        {"timestamp", iso8601_utc_now()},
        {"mode", to_string(mode)}
    };
    if (preferences.hostname) {
        payload["hostname"] = local_hostname();
    }
    if (preferences.ip) {
        payload["ip"] = local_ip_address();
    }
    if (preferences.mac) {
        payload["mac"] = local_mac_address();
    }
    payload["telemetry"] = preferences.mode;
    if (preferences.full_telemetry) {
        const json& system = cached_system_snapshot();
        if (!system.empty()) {
            payload["system"] = system;
        }
    }
    return payload;
}

void append_runtime_log(const json& payload) {
    std::filesystem::create_directories(logs_directory());
    secure_owner_only_path(logs_directory());
    const std::filesystem::path path = runtime_log_path();
    std::ofstream output(path, std::ios::app);
    if (!output) {
        throw std::runtime_error("Cannot write runtime log: " + path.string());
    }
    output << payload.dump() << '\n';
    secure_owner_only_path(path);
}

json load_root() {
    std::filesystem::path path = metadata_path();
    if (!std::filesystem::exists(path) && std::filesystem::exists(legacy_metadata_path())) {
        path = legacy_metadata_path();
    }
    if (!std::filesystem::exists(path)) {
        return json{
            {"meta",
             {
                 {"store_path", default_store_path().string()},
                 {"entry_count", 0},
                 {"deleted_entry_count", 0},
                 {"updated_at", iso8601_utc_now()}
             }},
            {"entries", json::object()}
        };
    }

    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("Cannot read metadata.json: " + path.string());
    }

    json root;
    input >> root;
    if (!root.is_object()) {
        root = json::object();
    }
    if (!root.contains("meta") || !root["meta"].is_object()) {
        root["meta"] = json::object();
    }
    if (!root.contains("entries") || !root["entries"].is_object()) {
        root["entries"] = json::object();
    }
    return root;
}

void refresh_root_meta(json& root) {
    json& meta = root["meta"];
    json& entries = root["entries"];
    int active_count = 0;
    int deleted_count = 0;
    for (auto it = entries.begin(); it != entries.end(); ++it) {
        const json& entry = it.value();
        if (entry.contains("deletion") && !entry["deletion"].is_null()) {
            ++deleted_count;
        } else {
            ++active_count;
        }
    }
    meta["store_path"] = default_store_path().string();
    meta["entry_count"] = active_count;
    meta["deleted_entry_count"] = deleted_count;
    meta["updated_at"] = iso8601_utc_now();
}

void save_root(json& root) {
    std::filesystem::create_directories(logs_directory());
    secure_owner_only_path(logs_directory());
    refresh_root_meta(root);

    const std::filesystem::path path = metadata_path();
    std::ofstream output(path, std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Cannot write metadata.json: " + path.string());
    }
    output << root.dump(2) << '\n';
    secure_owner_only_path(path);

    std::error_code ignored;
    const std::filesystem::path legacy_path = legacy_metadata_path();
    if (legacy_path != path && std::filesystem::exists(legacy_path)) {
        std::filesystem::remove(legacy_path, ignored);
    }
}

json& ensure_entry_record(json& root, const std::string& entry_name) {
    json& entry = root["entries"][entry_name];
    if (!entry.is_object()) {
        entry = json::object();
    }
    if (!entry.contains("entry")) {
        entry["entry"] = entry_name;
    }
    if (!entry.contains("path")) {
        entry["path"] = entry_name;
    }
    if (!entry.contains("creation")) {
        entry["creation"] = nullptr;
    }
    if (!entry.contains("modifications") || !entry["modifications"].is_array()) {
        entry["modifications"] = json::array();
    }
    if (!entry.contains("deletion")) {
        entry["deletion"] = nullptr;
    }
    if (!entry.contains("sync_history") || !entry["sync_history"].is_array()) {
        entry["sync_history"] = json::array();
    }
    return entry;
}

EntryMode latest_entry_mode(const json& entry) {
    if (entry.contains("modifications") && entry["modifications"].is_array() && !entry["modifications"].empty()) {
        const json& last = entry["modifications"].back();
        if (last.contains("mode") && last["mode"].is_string()) {
            return entry_mode_from_string(last["mode"].get<std::string>());
        }
    }
    if (entry.contains("creation") && entry["creation"].is_object() &&
        entry["creation"].contains("mode") && entry["creation"]["mode"].is_string()) {
        return entry_mode_from_string(entry["creation"]["mode"].get<std::string>());
    }
    return EntryMode::Unknown;
}

}  // namespace

std::string to_string(const EntryMode mode) {
    switch (mode) {
        case EntryMode::Manual:
            return "manual";
        case EntryMode::Combo:
            return "combo";
        default:
            return "unknown";
    }
}

EntryMode entry_mode_from_string(const std::string& value) {
    const std::string trimmed = trim_copy(value);
    if (trimmed == "manual") {
        return EntryMode::Manual;
    }
    if (trimmed == "combo") {
        return EntryMode::Combo;
    }
    return EntryMode::Unknown;
}

EntryMode preferred_entry_mode(const std::string& entry_name) {
    const json root = load_root();
    const json& entries = root["entries"];
    if (!entries.contains(entry_name) || !entries[entry_name].is_object()) {
        return EntryMode::Unknown;
    }
    return latest_entry_mode(entries[entry_name]);
}

std::string telemetry_mode_label() {
    return metadata_preferences().mode;
}

void record_entry_creation(const std::string& entry_name, const EntryMode mode) {
    if (!metadata_preferences().enabled) {
        return;
    }
    json root = load_root();
    json& entry = ensure_entry_record(root, entry_name);
    entry["entry"] = entry_name;
    entry["path"] = entry_name;
    const json event = event_payload(entry_name, mode);
    entry["creation"] = event;
    entry["modifications"] = json::array();
    entry["deletion"] = nullptr;
    save_root(root);
    append_runtime_log(
        {
            {"type", "password.create"},
            {"timestamp", iso8601_utc_now()},
            {"payload", event}
        }
    );
}

void record_entry_modification(
    const std::string& previous_entry_name,
    const std::string& entry_name,
    const EntryMode mode
) {
    if (!metadata_preferences().enabled) {
        return;
    }
    json root = load_root();
    json record = json::object();

    if (root["entries"].contains(previous_entry_name) && root["entries"][previous_entry_name].is_object()) {
        record = root["entries"][previous_entry_name];
        root["entries"].erase(previous_entry_name);
    }

    json& entry = root["entries"][entry_name];
    entry = record;
    if (!entry.is_object()) {
        entry = json::object();
    }

    if (!entry.contains("creation") || entry["creation"].is_null()) {
        entry["creation"] = event_payload(entry_name, mode);
    }
    if (!entry.contains("modifications") || !entry["modifications"].is_array()) {
        entry["modifications"] = json::array();
    }
    if (!entry.contains("sync_history") || !entry["sync_history"].is_array()) {
        entry["sync_history"] = json::array();
    }

    json event = event_payload(entry_name, mode);
    event["previous_entry"] = previous_entry_name;
    event["previous_path"] = previous_entry_name;
    entry["entry"] = entry_name;
    entry["path"] = entry_name;
    entry["deletion"] = nullptr;
    entry["modifications"].push_back(event);
    save_root(root);
    append_runtime_log(
        {
            {"type", "password.modify"},
            {"timestamp", iso8601_utc_now()},
            {"payload", event}
        }
    );
}

void record_entry_deletion(const std::string& entry_name) {
    if (!metadata_preferences().enabled) {
        return;
    }
    json root = load_root();
    json& entry = ensure_entry_record(root, entry_name);
    entry["entry"] = entry_name;
    entry["path"] = entry_name;
    const EntryMode mode = latest_entry_mode(entry);
    json event = event_payload(entry_name, mode);
    entry["deletion"] = event;
    save_root(root);
    append_runtime_log(
        {
            {"type", "password.delete"},
            {"timestamp", iso8601_utc_now()},
            {"payload", event}
        }
    );
}

void record_recursive_entry_deletion(const std::string& folder_prefix) {
    if (!metadata_preferences().enabled) {
        return;
    }
    json root = load_root();
    json& entries = root["entries"];

    for (auto it = entries.begin(); it != entries.end(); ++it) {
        const std::string entry_name = it.key();
        if (entry_name != folder_prefix && entry_name.rfind(folder_prefix + "/", 0) != 0) {
            continue;
        }

        json& entry = it.value();
        const EntryMode mode = latest_entry_mode(entry);
        entry["entry"] = entry_name;
        entry["path"] = entry_name;
        const json event = event_payload(entry_name, mode);
        entry["deletion"] = event;
        append_runtime_log(
            {
                {"type", "password.delete_recursive"},
                {"timestamp", iso8601_utc_now()},
                {"payload", event}
            }
        );
    }

    save_root(root);
}

void record_runtime_event(const std::string& event_name, const std::string& message, const std::map<std::string, std::string>& details) {
    const MetadataPreferences preferences = metadata_preferences();
    if (!preferences.enabled) {
        return;
    }

    json payload = {
        {"type", event_name},
        {"timestamp", iso8601_utc_now()},
        {"message", message},
        {"telemetry", preferences.mode}
    };
    if (!details.empty()) {
        payload["details"] = details;
    }
    if (preferences.hostname) {
        payload["hostname"] = local_hostname();
    }
    if (preferences.ip) {
        payload["ip"] = local_ip_address();
    }
    if (preferences.mac) {
        payload["mac"] = local_mac_address();
    }
    if (preferences.full_telemetry) {
        const json& system = cached_system_snapshot();
        if (!system.empty()) {
            payload["system"] = system;
        }
    }
    append_runtime_log(payload);
}

}  // namespace syncpss::util
