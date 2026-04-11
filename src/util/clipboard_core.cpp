#include "util/clipboard_internal.hpp"

#include "util/process.hpp"

#include <cstdlib>
#include <stdexcept>

namespace syncpss::util {
namespace detail {

std::vector<std::string> clipboard_write_command() {
#if defined(__APPLE__)
    if (is_command_available("pbcopy")) {
        return {"pbcopy"};
    }
#else
    const char* wsl_distro = std::getenv("WSL_DISTRO_NAME");
    if (wsl_distro != nullptr && std::string(wsl_distro).size() > 0U && is_command_available("clip.exe")) {
        return {"clip.exe"};
    }

    if (is_command_available("xclip")) {
        return {"xclip", "-selection", "clipboard"};
    }

    if (is_command_available("xsel")) {
        return {"xsel", "--clipboard", "--input"};
    }
#endif
    return {};
}

std::vector<std::string> clipboard_read_command() {
#if defined(__APPLE__)
    if (is_command_available("pbpaste")) {
        return {"pbpaste"};
    }
#else
    const char* wsl_distro = std::getenv("WSL_DISTRO_NAME");
    if (wsl_distro != nullptr && std::string(wsl_distro).size() > 0U && is_command_available("powershell.exe")) {
        return {"powershell.exe", "-NoLogo", "-NoProfile", "-Command", "Get-Clipboard -Raw"};
    }

    if (is_command_available("xclip")) {
        return {"xclip", "-selection", "clipboard", "-o"};
    }

    if (is_command_available("xsel")) {
        return {"xsel", "--clipboard", "--output"};
    }
#endif
    return {};
}

std::string read_clipboard_text() {
    const std::vector<std::string> command = clipboard_read_command();
    if (command.empty()) {
        return {};
    }

    const ProcessResult result = run(command);
    if (result.exit_code != 0) {
        return {};
    }
    return result.stdout_output;
}

}  // namespace detail

bool clipboard_available() {
    return !detail::clipboard_write_command().empty();
}

void copy_to_clipboard(const std::string& text) {
    const std::vector<std::string> command = detail::clipboard_write_command();
    if (command.empty()) {
        throw std::runtime_error("No supported clipboard command found (xclip, xsel, pbcopy, or clip.exe)");
    }

    const ProcessResult result = run(command, ProcessOptions{std::nullopt, std::nullopt, text});
    if (result.exit_code != 0) {
        throw std::runtime_error("Clipboard copy failed: " + result.stderr_output);
    }
}

void clear_clipboard() {
    copy_to_clipboard("");
}

}  // namespace syncpss::util
