#include "util/config.hpp"

#include "util/paths.hpp"
#include "util/runtime_config.hpp"
#include "util/validation.hpp"

#include <filesystem>
#include <fstream>
#include <map>
#include <stdexcept>
#include <string>

namespace syncpss::util {
namespace {

std::string trim(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1);
}

std::filesystem::path legacy_config_directory() {
    return get_real_home() / ".config" / "syncpss";
}

std::filesystem::path legacy_config_path() {
    return legacy_config_directory() / "config";
}

std::filesystem::path existing_config_path() {
    if (std::filesystem::exists(config_path())) {
        return config_path();
    }
    if (std::filesystem::exists(legacy_config_path())) {
        return legacy_config_path();
    }
    return config_path();
}

}  // namespace

bool config_exists() {
    return runtime_config_exists() ||
        std::filesystem::exists(config_path()) ||
        std::filesystem::exists(legacy_config_path());
}

AppConfig load_config() {
    if (runtime_config_exists()) {
        return to_app_config(load_runtime_config());
    }

    const std::filesystem::path source_path = existing_config_path();
    std::ifstream input(source_path);
    if (!input) {
        throw std::runtime_error("Config file not found: " + source_path.string());
    }

    std::map<std::string, std::map<std::string, std::string>> values;
    std::string section;
    std::string line;
    while (std::getline(input, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#' || line[0] == ';') {
            continue;
        }
        if (line.front() == '[' && line.back() == ']') {
            section = line.substr(1, line.size() - 2);
            continue;
        }
        const std::size_t split = line.find('=');
        if (split == std::string::npos || section.empty()) {
            continue;
        }

        const std::string key = trim(line.substr(0, split));
        const std::string value = trim(line.substr(split + 1));
        values[section][key] = value;
    }

    AppConfig config;
    config.repo_url = values["repo"]["url"];
    if (values["repo"].count("branch") > 0U && !values["repo"]["branch"].empty()) {
        config.repo_branch = values["repo"]["branch"];
    }
    config.gpg_key_id = values["gpg"]["key_id"];

    const std::string store_path_value = values["store"]["path"].empty()
        ? std::string("~/.password-store")
        : values["store"]["path"];
    config.store_path = expand_user_path(store_path_value);

    if (config.repo_url.empty()) {
        throw std::runtime_error("Config missing [repo] url");
    }
    if (config.gpg_key_id.empty()) {
        throw std::runtime_error("Config missing [gpg] key_id");
    }
    const std::string repo_prefix = "git@github.com:";
    const std::string repo_suffix = ".git";
    if (config.repo_url.rfind(repo_prefix, 0) != 0 || config.repo_url.size() <= repo_prefix.size() + repo_suffix.size() ||
        config.repo_url.substr(config.repo_url.size() - repo_suffix.size()) != repo_suffix) {
        throw std::runtime_error("Config [repo] url must be a git@github.com:<owner>/<repo>.git URL");
    }
    validate_repo_id_or_throw(
        config.repo_url.substr(repo_prefix.size(), config.repo_url.size() - repo_prefix.size() - repo_suffix.size()),
        "config github repo"
    );
    validate_gpg_key_id_or_throw(config.gpg_key_id, "config gpg key id");
    validate_branch_name_or_throw(config.repo_branch, "config repo branch");
    require_managed_path(config.store_path, "config store path");

    return config;
}

void save_config(const AppConfig& config) {
    const std::string repo_prefix = "git@github.com:";
    const std::string repo_suffix = ".git";
    if (config.repo_url.rfind(repo_prefix, 0) != 0 || config.repo_url.size() <= repo_prefix.size() + repo_suffix.size() ||
        config.repo_url.substr(config.repo_url.size() - repo_suffix.size()) != repo_suffix) {
        throw std::runtime_error("Refusing to write an invalid GitHub SSH repo URL to config");
    }
    validate_repo_id_or_throw(
        config.repo_url.substr(repo_prefix.size(), config.repo_url.size() - repo_prefix.size() - repo_suffix.size()),
        "config github repo"
    );
    validate_gpg_key_id_or_throw(config.gpg_key_id, "config gpg key id");
    validate_branch_name_or_throw(config.repo_branch, "config repo branch");
    require_managed_path(config.store_path, "config store path");
    std::filesystem::create_directories(config_directory());

    std::ofstream output(config_path(), std::ios::trunc);
    if (!output) {
        throw std::runtime_error("Cannot write config file: " + config_path().string() + ". Run syncpss with sudo so it can update /etc/syncpass.");
    }

    output << "[repo]\n";
    output << "url = " << config.repo_url << "\n";
    output << "branch = " << config.repo_branch << "\n\n";
    output << "[gpg]\n";
    output << "key_id = " << config.gpg_key_id << "\n\n";
    output << "[store]\n";
    output << "path = " << config.store_path.string() << "\n";
}

}  // namespace syncpss::util
