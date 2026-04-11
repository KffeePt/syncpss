#include "util/clipboard_internal.hpp"

#include <thread>

namespace syncpss::util {
namespace detail {

std::atomic<std::uint64_t> g_clipboard_generation{0};
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
    copy_to_clipboard(text);

    const std::uint64_t lease_id = detail::g_clipboard_generation.fetch_add(1U, std::memory_order_relaxed) + 1U;
    const auto expires_at = std::chrono::steady_clock::now() + delay;
    {
        const std::lock_guard<std::mutex> lock(detail::g_clipboard_mutex);
        detail::g_clipboard_leases[lease_id] = detail::LeaseRecord{text, ClipboardLeaseState::Pending};
    }

    detail::register_windows_clipboard_lease(lease_id, text);
    detail::launch_windows_clipboard_watcher(lease_id, delay);
    detail::schedule_windows_clipboard_clear(lease_id, delay);

    std::thread([delay, lease_id]() {
        const auto deadline = std::chrono::steady_clock::now() + delay;
        try {
            while (std::chrono::steady_clock::now() < deadline) {
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
