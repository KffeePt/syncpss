#pragma once

#include "store/entry.hpp"

#include <string>

namespace syncpss::tui::detail {

struct ComboDefaults {
    std::string folder;
    std::string user;
    std::string account_location;
    std::string site_host;
    std::string port;
    std::string query;
    std::string company_location;
};

bool is_valid_port_text(const std::string& value);
std::string normalize_query_text(const std::string& value);
std::string build_account_value(const std::string& user, const std::string& location);
std::string build_site_value(
    const std::string& host,
    const std::string& port,
    const std::string& query,
    const std::string& company_location
);
void split_account_value(const std::string& account, std::string& user, std::string& location);
void split_site_value(
    const std::string& site,
    std::string& host,
    std::string& port,
    std::string& query,
    std::string& company_location
);
ComboDefaults combo_defaults_from_entry(const syncpss::store::Entry& entry);

}  // namespace syncpss::tui::detail
