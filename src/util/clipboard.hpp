#pragma once

#include <chrono>
#include <cstdint>
#include <string>

namespace syncpss::util {

struct ClipboardLease {
    std::uint64_t id = 0;
    std::chrono::steady_clock::time_point expires_at{};
};

enum class ClipboardLeaseState {
    Pending,
    Cleared,
    Changed
};

bool clipboard_available();
void copy_to_clipboard(const std::string& text);
void clear_clipboard();
void clear_clipboard_after(std::chrono::seconds delay);
ClipboardLease copy_to_clipboard_with_expiry(const std::string& text, std::chrono::seconds delay);
bool clipboard_lease_active(std::uint64_t lease_id);
ClipboardLeaseState clipboard_lease_state(std::uint64_t lease_id);

}  // namespace syncpss::util
