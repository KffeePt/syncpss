#include "common.hpp"

bool host_command_available(const std::wstring& command) {
    wchar_t buffer[MAX_PATH];
    const DWORD found = SearchPathW(nullptr, command.c_str(), nullptr, MAX_PATH, buffer, nullptr);
    return found > 0 && found < MAX_PATH;
}

namespace {

void ensure_wsl_available() {
    if (host_command_available(L"wsl.exe")) {
        return;
    }

    if (!prompt_yes_no(
            L"WSL is not available on this Windows install yet. Enable the required Windows features automatically now?",
            true)) {
        throw std::runtime_error(
            "wsl.exe is not available on this Windows install. Enable WSL support in Windows first, then rerun syncpss."
        );
    }

    log_line("Enabling Windows Subsystem for Linux and Virtual Machine Platform with PowerShell...", kYellow);
    const int exit_code = run_process_interactive({
        L"powershell.exe",
        L"-NoLogo",
        L"-NoProfile",
        L"-ExecutionPolicy",
        L"Bypass",
        L"-Command",
        L"Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux,VirtualMachinePlatform -All -NoRestart"
    });
    if (exit_code != 0) {
        throw std::runtime_error(
            "PowerShell could not enable the required WSL Windows features automatically."
        );
    }

    if (!host_command_available(L"wsl.exe")) {
        throw std::runtime_error(
            "WSL features were enabled, but wsl.exe is still not available yet. A Windows reboot may be required before syncpss can continue."
        );
    }

    log_line("Windows WSL features were enabled successfully.", kGreen);
}
}  // namespace

void ensure_host_prerequisites() {
    ensure_wsl_available();
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
