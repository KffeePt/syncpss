#pragma once

#include "util/clipboard.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace syncpss::util::detail {

struct LeaseRecord {
    std::string text;
    ClipboardLeaseState state = ClipboardLeaseState::Pending;
};

extern std::atomic<std::uint64_t> g_clipboard_generation;
extern std::mutex g_clipboard_mutex;
extern std::unordered_map<std::uint64_t, LeaseRecord> g_clipboard_leases;

std::vector<std::string> clipboard_write_command();
std::vector<std::string> clipboard_read_command();
std::string read_clipboard_text();
bool register_windows_clipboard_lease(std::uint64_t lease_id, const std::string& text);
bool launch_windows_clipboard_watcher(std::uint64_t lease_id, std::chrono::seconds delay);
bool schedule_windows_clipboard_clear(std::uint64_t lease_id, std::chrono::seconds delay);
void set_clipboard_lease_state(std::uint64_t lease_id, ClipboardLeaseState state);
std::string clipboard_lease_text(std::uint64_t lease_id);

}  // namespace syncpss::util::detail
