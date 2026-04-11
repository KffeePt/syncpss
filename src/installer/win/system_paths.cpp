#include "common.hpp"

bool host_command_available(const std::wstring& command) {
    wchar_t buffer[MAX_PATH];
    const DWORD found = SearchPathW(nullptr, command.c_str(), nullptr, MAX_PATH, buffer, nullptr);
    return found > 0 && found < MAX_PATH;
}

bool host_package_manager_available() {
    return host_command_available(L"winget.exe");
}

namespace {

void maybe_install_windows_dependency(
    const std::wstring& command,
    const std::wstring& display_name,
    const std::wstring& winget_id
) {
    if (host_command_available(command)) {
        return;
    }

    std::wstringstream prompt;
    prompt << L"Windows dependency missing: " << display_name
           << L". Install it automatically with winget now?";
    if (!prompt_yes_no(prompt.str(), true)) {
        throw std::runtime_error(
            to_utf8(display_name) + " is required before syncpss can continue on Windows."
        );
    }

    if (!host_package_manager_available()) {
        throw std::runtime_error(
            "winget.exe is not available, so " + to_utf8(display_name) +
            " must be installed manually before syncpss can continue."
        );
    }

    log_line("Installing " + to_utf8(display_name) + " with winget...", kYellow);
    const int exit_code = run_process_interactive({
        L"winget.exe",
        L"install",
        L"--id",
        winget_id,
        L"-e",
        L"--accept-package-agreements",
        L"--accept-source-agreements"
    });
    if (exit_code != 0 || !host_command_available(command)) {
        throw std::runtime_error("Failed to install " + to_utf8(display_name) + " automatically.");
    }
    log_line("Installed " + to_utf8(display_name) + " successfully.", kGreen);
}

}  // namespace

void ensure_host_prerequisites() {
    if (!host_command_available(L"wsl.exe")) {
        throw std::runtime_error(
            "wsl.exe is not available on this Windows install. Enable WSL support in Windows first, then rerun syncpss."
        );
    }

    maybe_install_windows_dependency(L"git.exe", L"Git for Windows", L"Git.Git");
    maybe_install_windows_dependency(L"gh.exe", L"GitHub CLI", L"GitHub.cli");
}

bool is_running_as_admin() {
    BOOL is_admin = FALSE;
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
    PSID administrators_group = nullptr;
    if (AllocateAndInitializeSid(
            &authority,
            2,
            SECURITY_BUILTIN_DOMAIN_RID,
            DOMAIN_ALIAS_RID_ADMINS,
            0,
            0,
            0,
            0,
            0,
            0,
            &administrators_group) != FALSE) {
        CheckTokenMembership(nullptr, administrators_group, &is_admin);
        FreeSid(administrators_group);
    }
    return is_admin == TRUE;
}

std::wstring current_exe_path() {
    std::wstring buffer(MAX_PATH, L'\0');
    while (true) {
        const DWORD written = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (written == 0) {
            throw std::runtime_error("GetModuleFileNameW failed");
        }
        if (written < buffer.size() - 1) {
            buffer.resize(written);
            return buffer;
        }
        buffer.resize(buffer.size() * 2);
    }
}

std::filesystem::path appdata_path(const wchar_t* variable_name) {
    wchar_t* value = nullptr;
    std::size_t size = 0;
    if (_wdupenv_s(&value, &size, variable_name) != 0 || value == nullptr || size == 0) {
        throw std::runtime_error("Required Windows environment variable is missing");
    }
    std::filesystem::path result(value);
    free(value);
    return result;
}

std::filesystem::path userprofile_path() {
    return appdata_path(L"USERPROFILE");
}

std::filesystem::path local_syncpss_app_dir() {
    return appdata_path(L"LOCALAPPDATA") / kWindowsAppDirName;
}

std::filesystem::path windows_runtime_dir() {
    return userprofile_path() / kWindowsRuntimeDirName;
}

std::filesystem::path start_menu_programs_dir() {
    return appdata_path(L"APPDATA") / L"Microsoft" / L"Windows" / L"Start Menu" / L"Programs";
}

std::wstring ps_single_quote(const std::wstring& value) {
    std::wstring escaped;
    escaped.reserve(value.size() + 8U);
    for (const wchar_t ch : value) {
        if (ch == L'\'') {
            escaped += L"''";
        } else {
            escaped.push_back(ch);
        }
    }
    return escaped;
}

void relaunch_as_admin_if_needed() {
    if (is_running_as_admin()) {
        return;
    }

    log_line("Administrator access is required. Requesting elevation...", kYellow);
    SHELLEXECUTEINFOW exec_info{};
    exec_info.cbSize = sizeof(exec_info);
    exec_info.lpVerb = L"runas";
    const std::wstring exe_path = current_exe_path();
    exec_info.lpFile = exe_path.c_str();
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    std::wstring parameters;
    if (argv != nullptr) {
        for (int index = 1; index < argc; ++index) {
            if (!parameters.empty()) {
                parameters += L' ';
            }
            parameters += quote_arg(argv[index]);
        }
        LocalFree(argv);
    }
    exec_info.lpParameters = parameters.empty() ? nullptr : parameters.c_str();
    exec_info.nShow = SW_NORMAL;

    if (ShellExecuteExW(&exec_info) == FALSE) {
        const DWORD error = GetLastError();
        if (error == ERROR_CANCELLED) {
            throw std::runtime_error("Administrator access was cancelled by the user");
        }
        throw std::runtime_error("Failed to elevate installer: " + last_error_message(error));
    }
    std::exit(0);
}
