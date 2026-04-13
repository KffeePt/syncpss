#include "util/validation.hpp"

#include <cctype>
#include <stdexcept>

namespace syncpss::util {

namespace {

bool ends_with(const std::string& value, const std::string& suffix) {
    return value.size() >= suffix.size() &&
           value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

}  // namespace

std::string trim_copy(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1U);
}

bool contains_control_chars(const std::string& value) {
    for (const unsigned char ch : value) {
        if (ch < 32U || ch == 127U) {
            return true;
        }
    }
    return false;
}

void require_safe_single_line(const std::string& value, const std::string& field_name) {
    const std::string trimmed = trim_copy(value);
    if (trimmed.empty()) {
        throw std::runtime_error(field_name + " cannot be empty");
    }
    if (contains_control_chars(trimmed)) {
        throw std::runtime_error(field_name + " contains control characters");
    }
}

void validate_repo_name_or_throw(const std::string& value, const std::string& field_name) {
    const std::string trimmed = trim_copy(value);
    require_safe_single_line(trimmed, field_name);
    if (trimmed.size() > 100U) {
        throw std::runtime_error(field_name + " is too long");
    }
    if (trimmed.front() == '.' || trimmed.front() == '-') {
        throw std::runtime_error(field_name + " cannot start with '.' or '-'");
    }
    if (trimmed.find("..") != std::string::npos || trimmed.find('/') != std::string::npos ||
        trimmed.find("//") != std::string::npos || ends_with(trimmed, ".lock")) {
        throw std::runtime_error(field_name + " contains an unsafe repository name pattern");
    }
    for (const unsigned char ch : trimmed) {
        if (!(std::isalnum(ch) != 0 || ch == '.' || ch == '_' || ch == '-')) {
            throw std::runtime_error(field_name + " contains unsupported characters");
        }
    }
}

void validate_github_account_name_or_throw(const std::string& value, const std::string& field_name) {
    const std::string trimmed = trim_copy(value);
    require_safe_single_line(trimmed, field_name);
    if (trimmed.size() > 39U) {
        throw std::runtime_error(field_name + " is too long");
    }
    if (trimmed.front() == '-' || trimmed.find("..") != std::string::npos) {
        throw std::runtime_error(field_name + " contains an unsafe account name pattern");
    }
    for (const unsigned char ch : trimmed) {
        if (!(std::isalnum(ch) != 0 || ch == '-')) {
            throw std::runtime_error(field_name + " contains unsupported characters");
        }
    }
}

void validate_repo_id_or_throw(const std::string& value, const std::string& field_name) {
    const std::string trimmed = trim_copy(value);
    require_safe_single_line(trimmed, field_name);
    const std::size_t slash = trimmed.find('/');
    if (slash == std::string::npos || slash == 0 || slash + 1U >= trimmed.size()) {
        throw std::runtime_error(field_name + " must be in owner/repo format");
    }
    if (trimmed.find('/', slash + 1U) != std::string::npos) {
        throw std::runtime_error(field_name + " must contain exactly one slash");
    }
    validate_github_account_name_or_throw(trimmed.substr(0, slash), field_name + " owner");
    validate_repo_name_or_throw(trimmed.substr(slash + 1U), field_name + " name");
}

void validate_branch_name_or_throw(const std::string& value, const std::string& field_name) {
    const std::string trimmed = trim_copy(value);
    require_safe_single_line(trimmed, field_name);
    if (trimmed.size() > 255U) {
        throw std::runtime_error(field_name + " is too long");
    }
    if (trimmed.front() == '-' || trimmed.find("..") != std::string::npos ||
        trimmed.find("@{") != std::string::npos || trimmed.find("//") != std::string::npos ||
        trimmed.back() == '/' || trimmed.back() == '.' ||
        ends_with(trimmed, ".lock")) {
        throw std::runtime_error(field_name + " contains an unsafe git ref pattern");
    }
    for (const unsigned char ch : trimmed) {
        if (!(std::isalnum(ch) != 0 || ch == '.' || ch == '_' || ch == '/' || ch == '-')) {
            throw std::runtime_error(field_name + " contains unsupported characters");
        }
    }
}

void validate_gpg_key_id_or_throw(const std::string& value, const std::string& field_name) {
    std::string trimmed = trim_copy(value);
    require_safe_single_line(trimmed, field_name);
    if (trimmed.rfind("0x", 0) == 0) {
        trimmed = trimmed.substr(2);
    }
    const std::size_t size = trimmed.size();
    if (!(size == 8U || size == 16U || size == 40U)) {
        throw std::runtime_error(field_name + " must be an 8, 16, or 40 character hex fingerprint");
    }
    for (const unsigned char ch : trimmed) {
        if (std::isxdigit(ch) == 0) {
            throw std::runtime_error(field_name + " contains non-hex characters");
        }
    }
}

}  // namespace syncpss::util
