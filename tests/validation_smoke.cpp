#include "util/validation.hpp"

#include <exception>
#include <iostream>
#include <string>

namespace {

bool expect_accept_branch(const std::string& value) {
    try {
        syncpss::util::validate_branch_name_or_throw(value, "test branch");
        return true;
    } catch (const std::exception& ex) {
        std::cerr << "Expected branch to be accepted: " << value << " (" << ex.what() << ")\n";
        return false;
    }
}

bool expect_reject_branch(const std::string& value) {
    try {
        syncpss::util::validate_branch_name_or_throw(value, "test branch");
        std::cerr << "Expected branch to be rejected: " << value << "\n";
        return false;
    } catch (...) {
        return true;
    }
}

bool expect_accept_repo(const std::string& value) {
    try {
        syncpss::util::validate_repo_name_or_throw(value, "test repo");
        return true;
    } catch (const std::exception& ex) {
        std::cerr << "Expected repo to be accepted: " << value << " (" << ex.what() << ")\n";
        return false;
    }
}

bool expect_reject_repo(const std::string& value) {
    try {
        syncpss::util::validate_repo_name_or_throw(value, "test repo");
        std::cerr << "Expected repo to be rejected: " << value << "\n";
        return false;
    } catch (...) {
        return true;
    }
}

}  // namespace

int main() {
    bool ok = true;

    ok = expect_accept_branch("main") && ok;
    ok = expect_accept_branch("dev") && ok;
    ok = expect_accept_branch("feature/test") && ok;
    ok = expect_reject_branch("main.lock") && ok;

    ok = expect_accept_repo("app") && ok;
    ok = expect_accept_repo("password-store") && ok;
    ok = expect_reject_repo("repo.lock") && ok;

    return ok ? 0 : 1;
}
