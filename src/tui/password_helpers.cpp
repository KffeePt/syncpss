#include "tui/detail/browser.hpp"
#include "tui/detail/common.hpp"
#include "tui/detail/passwords.hpp"

namespace syncpss::tui::detail {

bool is_valid_port_text(const std::string& value) {
    if (value.empty()) {
        return true;
    }
    if (!std::all_of(value.begin(), value.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; })) {
        return false;
    }
    try {
        const int port = std::stoi(value);
        return port >= 1 && port <= 65535;
    } catch (const std::exception&) {
        return false;
    }
}

std::string normalize_query_text(const std::string& value) {
    const std::string trimmed = trim_copy(value);
    if (trimmed.empty()) {
        return "";
    }
    if (!trimmed.empty() && trimmed.front() == '/') {
        return trimmed.substr(1);
    }
    return trimmed;
}

std::string build_account_value(const std::string& user, const std::string& location) {
    const std::string trimmed_user = trim_copy(user);
    const std::string trimmed_location = trim_copy(location);
    if (trimmed_user.empty() || trimmed_location.empty()) {
        return "";
    }
    return trimmed_user + "@" + trimmed_location;
}

std::string build_site_value(
    const std::string& host,
    const std::string& port,
    const std::string& query,
    const std::string& company_location
) {
    std::string value = trim_copy(host);
    if (value.empty()) {
        return "";
    }

    const std::string trimmed_port = trim_copy(port);
    const std::string normalized_query = normalize_query_text(query);
    const std::string trimmed_company_location = trim_copy(company_location);

    if (!trimmed_port.empty()) {
        value += ":" + trimmed_port;
    }
    if (!normalized_query.empty()) {
        value += "/" + normalized_query;
    }
    if (!trimmed_company_location.empty()) {
        value += "@" + trimmed_company_location;
    }
    return value;
}

void split_account_value(const std::string& account, std::string& user, std::string& location) {
    const std::string trimmed = trim_copy(account);
    const std::size_t at = trimmed.find('@');
    if (at == std::string::npos) {
        user = trimmed;
        location.clear();
        return;
    }
    user = trim_copy(trimmed.substr(0, at));
    location = trim_copy(trimmed.substr(at + 1U));
}

void split_site_value(
    const std::string& site,
    std::string& host,
    std::string& port,
    std::string& query,
    std::string& company_location
) {
    std::string working = trim_copy(site);
    host.clear();
    port.clear();
    query.clear();
    company_location.clear();
    if (working.empty()) {
        return;
    }

    const std::size_t company_split = working.rfind('@');
    if (company_split != std::string::npos) {
        company_location = trim_copy(working.substr(company_split + 1U));
        working = trim_copy(working.substr(0, company_split));
    }

    const std::size_t slash = working.find('/');
    std::string host_port = working;
    if (slash != std::string::npos) {
        host_port = trim_copy(working.substr(0, slash));
        query = normalize_query_text(working.substr(slash + 1U));
    }

    const std::size_t colon = host_port.rfind(':');
    if (colon != std::string::npos) {
        const std::string possible_port = trim_copy(host_port.substr(colon + 1U));
        if (is_valid_port_text(possible_port)) {
            port = possible_port;
            host = trim_copy(host_port.substr(0, colon));
            return;
        }
    }
    host = trim_copy(host_port);
}

ComboDefaults combo_defaults_from_entry(const syncpss::store::Entry& entry) {
    ComboDefaults defaults;
    const std::filesystem::path path(entry.name);
    defaults.folder = path.has_parent_path() ? path.parent_path().generic_string() : "";

    const EntryViewModel model = describe_entry(entry.name);
    split_account_value(!model.account.empty() ? model.account : entry.username, defaults.user, defaults.account_location);
    split_site_value(
        model.site.empty() ? entry.url : model.site,
        defaults.site_host,
        defaults.port,
        defaults.query,
        defaults.company_location
    );
    return defaults;
}

}  // namespace syncpss::tui::detail
