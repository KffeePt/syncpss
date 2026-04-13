#include "util/clipboard_internal.hpp"

#include <algorithm>
#include <thread>

namespace syncpss::util {
namespace detail {

std::atomic<std::uint64_t> g_clipboard_generation{0};
std::atomic<std::uint64_t> g_active_clipboard_lease_id{0};
std::mutex g_clipboard_mutex;
std::unordered_map<std::uint64_t, LeaseRecord> g_clipboard_leases;

void set_clipboard_lease_state(std::uint64_t lease_id, ClipboardLeaseState state) {
    const std::lock_guard<std::mutex> lock(g_clipboard_mutex);
    const auto it = g_clipboard_leases.find(lease_id);
    if (it != g_clipboard_leases.end()) {
        it->second.state = state;
    }
}

std::string clipboard_lease_text(std::uint64_t lease_id) {
    const std::lock_guard<std::mutex> lock(g_clipboard_mutex);
    const auto it = g_clipboard_leases.find(lease_id);
    if (it == g_clipboard_leases.end()) {
        return {};
    }
    return it->second.text;
}

bool clipboard_lease_is_current(std::uint64_t lease_id) {
    return lease_id != 0U && g_active_clipboard_lease_id.load(std::memory_order_relaxed) == lease_id;
}

}  // namespace detail

void clear_clipboard_after(std::chrono::seconds delay) {
    std::thread([delay]() {
        std::this_thread::sleep_for(delay);
        try {
            clear_clipboard();
        } catch (...) {
        }
    }).detach();
}

ClipboardLease copy_to_clipboard_with_expiry(const std::string& text, std::chrono::seconds delay) {
    const std::uint64_t lease_id = detail::g_clipboard_generation.fetch_add(1U, std::memory_order_relaxed) + 1U;
    const auto expires_at = std::chrono::steady_clock::now() + delay;
    std::vector<std::uint64_t> stale_leases;
    {
        const std::lock_guard<std::mutex> lock(detail::g_clipboard_mutex);
        stale_leases.reserve(detail::g_clipboard_leases.size());
        for (auto& [existing_id, record] : detail::g_clipboard_leases) {
            if (existing_id == lease_id) {
                continue;
            }
            record.state = ClipboardLeaseState::Changed;
            record.text.clear();
            stale_leases.push_back(existing_id);
        }
        detail::g_clipboard_leases[lease_id] = detail::LeaseRecord{text, ClipboardLeaseState::Pending};
    }
    detail::g_active_clipboard_lease_id.store(lease_id, std::memory_order_relaxed);

    for (const std::uint64_t stale_lease_id : stale_leases) {
        detail::cancel_windows_clipboard_lease(stale_lease_id);
    }

    bool copied_via_windows_helper = false;
    try {
        copied_via_windows_helper = detail::copy_windows_clipboard_with_lease(lease_id, text);
        if (!copied_via_windows_helper) {
            copy_to_clipboard(text);
        }
    } catch (...) {
        detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Changed);
        throw;
    }

    const auto write_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (std::chrono::steady_clock::now() < write_deadline) {
        if (detail::read_clipboard_text() == text) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    if (!copied_via_windows_helper) {
        detail::register_windows_clipboard_lease(lease_id, text);
    }
    detail::launch_windows_clipboard_watcher(lease_id, delay);
    detail::schedule_windows_clipboard_clear(lease_id, delay);

    std::thread([delay, lease_id]() {
        const auto deadline = std::chrono::steady_clock::now() + delay;
        try {
            while (std::chrono::steady_clock::now() < deadline) {
                if (!detail::clipboard_lease_is_current(lease_id)) {
                    detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Changed);
                    return;
                }
                const std::string expected_text = detail::clipboard_lease_text(lease_id);
                if (expected_text.empty()) {
                    detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Changed);
                    return;
                }

                const std::string current_text = detail::read_clipboard_text();
                if (current_text.empty()) {
                    detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Cleared);
                    return;
                }
                if (current_text != expected_text) {
                    detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Changed);
                    return;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(250));
            }

            if (!detail::clipboard_lease_is_current(lease_id)) {
                detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Changed);
                return;
            }

            const std::string expected_text = detail::clipboard_lease_text(lease_id);
            if (expected_text.empty()) {
                detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Changed);
                return;
            }

            const std::string current_text = detail::read_clipboard_text();
            if (current_text.empty()) {
                detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Cleared);
            } else if (current_text == expected_text) {
                clear_clipboard();
                detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Cleared);
                std::uint64_t expected_active_lease_id = lease_id;
                detail::g_active_clipboard_lease_id.compare_exchange_strong(
                    expected_active_lease_id,
                    0U,
                    std::memory_order_relaxed
                );
            } else {
                detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Changed);
            }
        } catch (...) {
            detail::set_clipboard_lease_state(lease_id, ClipboardLeaseState::Changed);
        }
    }).detach();

    return ClipboardLease{lease_id, expires_at};
}

bool clipboard_lease_active(std::uint64_t lease_id) {
    if (lease_id == 0U) {
        return false;
    }

    std::string expected_text;
    {
        const std::lock_guard<std::mutex> lock(detail::g_clipboard_mutex);
        const auto it = detail::g_clipboard_leases.find(lease_id);
        if (it == detail::g_clipboard_leases.end() || it->second.state != ClipboardLeaseState::Pending) {
            return false;
        }
        expected_text = it->second.text;
    }
    if (!detail::clipboard_lease_is_current(lease_id)) {
        return false;
    }
    return detail::read_clipboard_text() == expected_text;
}

ClipboardLeaseState clipboard_lease_state(std::uint64_t lease_id) {
    const std::lock_guard<std::mutex> lock(detail::g_clipboard_mutex);
    const auto it = detail::g_clipboard_leases.find(lease_id);
    if (it == detail::g_clipboard_leases.end()) {
        return ClipboardLeaseState::Changed;
    }
    return it->second.state;
}

}  // namespace syncpss::util
