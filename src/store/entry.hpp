#pragma once

#include <string>

namespace syncpss::store {

struct Entry {
    std::string name;
    std::string username;
    std::string password;
    std::string url;
    std::string notes;
};

}  // namespace syncpss::store

