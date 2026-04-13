#pragma once

#include <string>

namespace syncpss::util {

std::string trim_copy(const std::string& value);
bool contains_control_chars(const std::string& value);
void require_safe_single_line(const std::string& value, const std::string& field_name);
void validate_repo_name_or_throw(const std::string& value, const std::string& field_name = "repo name");
void validate_github_account_name_or_throw(const std::string& value, const std::string& field_name = "GitHub account");
void validate_repo_id_or_throw(const std::string& value, const std::string& field_name = "GitHub repo");
void validate_branch_name_or_throw(const std::string& value, const std::string& field_name = "branch");
void validate_gpg_key_id_or_throw(const std::string& value, const std::string& field_name = "GPG key id");

}  // namespace syncpss::util
