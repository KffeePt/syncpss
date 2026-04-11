#include "util/runtime_config.hpp"

#include "util/paths.hpp"

#include <nlohmann/json.hpp>

#include <fstream>
#include <cstdlib>
#include <stdexcept>
#include <system_error>

namespace syncpss::util {
namespace {

using json = nlohmann::json;

std::string trim(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1U);
}

std::string require_string(const json& node, const char* key) {
    if (!node.contains(key) || !node.at(key).is_string()) {
        throw std::runtime_error(std::string("Runtime config missing string field: ") + key);
    }
    return node.at(key).get<std::string>();
}

std::string optional_string(const json& node, const char* key, const std::string& fallback = "") {
    if (!node.contains(key) || node.at(key).is_null()) {
        return fallback;
    }
    if (!node.at(key).is_string()) {
        throw std::runtime_error(std::string("Runtime config field must be a string: ") + key);
    }
    return node.at(key).get<std::string>();
}

bool optional_bool(const json& node, const char* key, bool fallback = false) {
    if (!node.contains(key) || node.at(key).is_null()) {
        return fallback;
    }
    if (!node.at(key).is_boolean()) {
        throw std::runtime_error(std::string("Runtime config field must be a boolean: ") + key);
    }
    return node.at(key).get<bool>();
}

std::string normalize_telemetry_mode(const std::string& value) {
    const std::string trimmed = trim(value);
    if (trimmed == "on" || trimmed == "bare" || trimmed == "off") {
        return trimmed;
    }
    return "off";
}

std::string render_path(const std::filesystem::path& path) {
    return path.string();
}

void set_owner_only_permissions(const std::filesystem::path& path) {
    const bool is_directory = std::filesystem::is_directory(path);
    std::error_code error;
    std::filesystem::permissions(
        path,
        is_directory
            ? std::filesystem::perms::owner_all
            : (std::filesystem::perms::owner_read | std::filesystem::perms::owner_write),
        std::filesystem::perm_options::replace,
        error
    );
}

std::string repo_name_from_repo_id(const std::string& repo_id) {
    const std::size_t slash = repo_id.find('/');
    if (slash == std::string::npos || slash + 1U >= repo_id.size()) {
        return trim(repo_id).empty() ? "password-store" : trim(repo_id);
    }
    return trim(repo_id.substr(slash + 1U));
}

void ensure_preferences_dir() {
    std::filesystem::create_directories(persistent_settings_directory());
    set_owner_only_permissions(persistent_settings_directory());
}

}  // namespace

bool runtime_config_exists() {
    return std::filesystem::exists(runtime_config_path());
}

std::string load_preferred_private_repo_name() {
    const char* env_value = std::getenv("SYNCPSS_PRIVATE_REPO_NAME");
    if (env_value != nullptr) {
        const std::string trimmed_env = trim(env_value);
        if (!trimmed_env.empty()) {
            return trimmed_env;
        }
    }

    const std::filesystem::path path = persistent_preferences_path();
    if (!std::filesystem::exists(path)) {
        return "";
    }

    std::ifstream input(path);
    if (!input) {
        return "";
    }

    std::string line;
    while (std::getline(input, line)) {
        const std::size_t split = line.find('=');
        if (split == std::string::npos) {
            continue;
        }
        const std::string key = trim(line.substr(0, split));
        if (key != "SYNCPSS_PRIVATE_REPO_NAME") {
            continue;
        }
        return trim(line.substr(split + 1U));
    }
    return "";
}

void save_preferred_private_repo_name(const std::string& repo_name) {
    const std::string trimmed = trim(repo_name);
    if (trimmed.empty()) {
        clear_preferred_private_repo_name();
        return;
    }

    ensure_preferences_dir();
    const std::filesystem::path path = persistent_preferences_path();
    std::ofstream output(path, std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Cannot write preferences file: " + path.string());
    }
    output << "SYNCPSS_PRIVATE_REPO_NAME=" << trimmed << '\n';
    set_owner_only_permissions(path);
}

void clear_preferred_private_repo_name() {
    std::error_code ignored;
    std::filesystem::remove(persistent_preferences_path(), ignored);
}

RuntimeConfig load_runtime_config() {
    std::ifstream input(runtime_config_path());
    if (!input) {
        throw std::runtime_error("Runtime config file not found: " + runtime_config_path().string());
    }

    json root;
    input >> root;

    if (!root.contains("github") || !root.at("github").is_object()) {
        throw std::runtime_error("Runtime config missing github object");
    }
    if (!root.contains("gpg") || !root.at("gpg").is_object()) {
        throw std::runtime_error("Runtime config missing gpg object");
    }
    if (!root.contains("store") || !root.at("store").is_object()) {
        throw std::runtime_error("Runtime config missing store object");
    }

    const json& github = root.at("github");
    const json& gpg = root.at("gpg");
    const json& store = root.at("store");
    const json install = root.contains("install") && root.at("install").is_object()
        ? root.at("install")
        : json::object();

    RuntimeConfig config;
    config.github_username = optional_string(github, "username");
    config.github_email = optional_string(github, "email");
    const std::string ssh_key = optional_string(github, "ssh_key_path", "~/.ssh/syncpss_ed25519");
    config.ssh_key_path = expand_user_path(ssh_key);
    config.github_repo = require_string(github, "repo");
    config.github_repo_name = optional_string(github, "repo_name", repo_name_from_repo_id(config.github_repo));
    if (config.github_repo_name.empty()) {
        config.github_repo_name = load_preferred_private_repo_name();
    }
    if (config.github_repo_name.empty()) {
        config.github_repo_name = repo_name_from_repo_id(config.github_repo);
    }

    config.gpg_key_id = require_string(gpg, "key_id");
    config.gpg_keys_remote = optional_bool(gpg, "keys_remote", false);
    const json telemetry = root.contains("telemetry") && root.at("telemetry").is_object()
        ? root.at("telemetry")
        : json::object();
    config.telemetry_mode = normalize_telemetry_mode(optional_string(telemetry, "mode"));
    config.metadata_logging_enabled = optional_bool(gpg, "metadata_logging_enabled", false);
    config.metadata_log_hostname = optional_bool(gpg, "metadata_log_hostname", false);
    config.metadata_log_ip = optional_bool(gpg, "metadata_log_ip", false);
    config.metadata_log_mac = optional_bool(gpg, "metadata_log_mac", false);
    if (config.telemetry_mode == "off" && config.metadata_logging_enabled) {
        config.telemetry_mode =
            (config.metadata_log_hostname || config.metadata_log_ip || config.metadata_log_mac) ? "on" : "bare";
    }
    config.notes_mode = optional_string(gpg, "notes_mode", "encrypted");
    if (config.notes_mode.empty()) {
        config.notes_mode = "encrypted";
    }

    config.store_path = expand_user_path(optional_string(store, "path", "~/.password-store"));
    config.store_branch = optional_string(store, "branch", "main");
    if (config.store_branch.empty()) {
        config.store_branch = "main";
    }

    config.install_binary = expand_user_path(optional_string(install, "binary", "/usr/local/bin/syncpss"));
    config.install_config_dir = expand_user_path(optional_string(install, "config_dir", "/etc/syncpass"));
    config.install_distro = optional_string(install, "distro");
    config.install_installed_at = optional_string(install, "installed_at");
    config.install_version = optional_string(install, "version");

    return config;
}

void save_runtime_config(const RuntimeConfig& config) {
    std::filesystem::create_directories(runtime_directory());
    set_owner_only_permissions(runtime_directory());

    RuntimeConfig normalized = config;
    if (normalized.github_repo_name.empty()) {
        normalized.github_repo_name = repo_name_from_repo_id(normalized.github_repo);
    }
    normalized.telemetry_mode = normalize_telemetry_mode(normalized.telemetry_mode);
    normalized.metadata_logging_enabled = normalized.telemetry_mode != "off";
    normalized.metadata_log_hostname = normalized.telemetry_mode == "on";
    normalized.metadata_log_ip = normalized.telemetry_mode == "on";
    normalized.metadata_log_mac = normalized.telemetry_mode == "on";
    if (normalized.notes_mode.empty()) {
        normalized.notes_mode = "encrypted";
    }

    json root = {
        {"github",
         {
             {"username", normalized.github_username},
             {"email", normalized.github_email},
             {"ssh_key_path", render_path(normalized.ssh_key_path)},
             {"repo", normalized.github_repo},
             {"repo_name", normalized.github_repo_name},
         }},
        {"gpg",
         {
             {"key_id", normalized.gpg_key_id},
             {"keys_remote", normalized.gpg_keys_remote},
             {"metadata_logging_enabled", normalized.metadata_logging_enabled},
             {"metadata_log_hostname", normalized.metadata_log_hostname},
             {"metadata_log_ip", normalized.metadata_log_ip},
             {"metadata_log_mac", normalized.metadata_log_mac},
             {"notes_mode", normalized.notes_mode},
         }},
        {"telemetry",
         {
             {"mode", normalized.telemetry_mode},
         }},
        {"store",
         {
             {"path", render_path(normalized.store_path)},
             {"branch", normalized.store_branch},
         }},
        {"install",
         {
             {"binary", render_path(normalized.install_binary)},
             {"config_dir", render_path(normalized.install_config_dir)},
             {"distro", normalized.install_distro},
             {"installed_at", normalized.install_installed_at},
             {"version", normalized.install_version},
         }},
    };

    const std::filesystem::path target = runtime_config_path();
    const std::filesystem::path temp = target.string() + ".tmp";

    {
        std::ofstream output(temp, std::ios::trunc);
        if (!output) {
            throw std::runtime_error("Cannot write runtime config: " + temp.string());
        }
        output << root.dump(2) << '\n';
    }

    set_owner_only_permissions(temp);
    std::filesystem::rename(temp, target);
    set_owner_only_permissions(target);
    save_preferred_private_repo_name(normalized.github_repo_name);
}

AppConfig to_app_config(const RuntimeConfig& config) {
    if (config.github_repo.empty()) {
        throw std::runtime_error("Runtime config missing github repo");
    }
    if (config.gpg_key_id.empty()) {
        throw std::runtime_error("Runtime config missing gpg key id");
    }

    AppConfig app_config;
    app_config.repo_url = "git@github.com:" + config.github_repo + ".git";
    app_config.repo_branch = config.store_branch.empty() ? "main" : config.store_branch;
    app_config.gpg_key_id = config.gpg_key_id;
    app_config.store_path = config.store_path;
    return app_config;
}

}  // namespace syncpss::util
