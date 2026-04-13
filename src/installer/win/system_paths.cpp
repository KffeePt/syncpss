#include "common.hpp"

bool host_command_available(const std::wstring& command) {
    wchar_t buffer[MAX_PATH];
    const DWORD found = SearchPathW(nullptr, command.c_str(), nullptr, MAX_PATH, buffer, nullptr);
    return found > 0 && found < MAX_PATH;
}

namespace {

std::filesystem::path normalize_windows_env_path(const std::wstring& raw_value, const wchar_t* variable_name) {
    const std::wstring trimmed = trim(raw_value);
    if (trimmed.empty() || contains_control_chars(trimmed)) {
        throw std::runtime_error("Windows environment path is empty or unsafe");
    }

    const std::filesystem::path path(trimmed);
    if (!path.is_absolute()) {
        throw std::runtime_error("Windows environment path is not absolute");
    }

    const std::filesystem::path normalized = path.lexically_normal();
    if (normalized == normalized.root_path()) {
        throw std::runtime_error("Windows environment path is too broad");
    }

    if (normalized.root_name().empty() || normalized.root_directory().empty()) {
        throw std::runtime_error("Windows environment path is malformed");
    }

    (void)variable_name;
    return normalized;
}

bool path_is_within_root(const std::filesystem::path& candidate, const std::filesystem::path& root) {
    auto candidate_it = candidate.begin();
    auto root_it = root.begin();
    for (; root_it != root.end(); ++root_it, ++candidate_it) {
        if (candidate_it == candidate.end() || *candidate_it != *root_it) {
            return false;
        }
    }
    return true;
}

void require_within_profile(const std::filesystem::path& candidate, const std::wstring& description) {
    const std::filesystem::path profile_root = normalize_windows_env_path(appdata_path(L"USERPROFILE").wstring(), L"USERPROFILE");
    if (!path_is_within_root(candidate, profile_root)) {
        throw std::runtime_error(to_utf8(description) + " is outside the active Windows profile root");
    }
}

int run_elevated_process_and_wait(const std::wstring& file, const std::wstring& parameters) {
    SHELLEXECUTEINFOW exec_info{};
    exec_info.cbSize = sizeof(exec_info);
    exec_info.fMask = SEE_MASK_NOCLOSEPROCESS;
    exec_info.lpVerb = L"runas";
    exec_info.lpFile = file.c_str();
    exec_info.lpParameters = parameters.empty() ? nullptr : parameters.c_str();
    exec_info.nShow = SW_NORMAL;

    if (ShellExecuteExW(&exec_info) == FALSE) {
        const DWORD error = GetLastError();
        if (error == ERROR_CANCELLED) {
            throw std::runtime_error("Administrator access was cancelled by the user.");
        }
        throw std::runtime_error("Failed to elevate WSL setup step: " + last_error_message(error));
    }

    WaitForSingleObject(exec_info.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(exec_info.hProcess, &exit_code);
    CloseHandle(exec_info.hProcess);
    return static_cast<int>(exit_code);
}

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
    const std::wstring elevated_parameters =
        L"-NoLogo -NoProfile -ExecutionPolicy Bypass -Command "
        L"\"Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux,VirtualMachinePlatform -All -NoRestart\"";
    const int exit_code = run_elevated_process_and_wait(L"powershell.exe", elevated_parameters);
    if (exit_code != 0) {
        throw std::runtime_error(
            "PowerShell could not enable the required WSL Windows features automatically."
        );
    }

    log_line("Windows WSL features were enabled successfully.", kGreen);
    prompt_press_enter(
        L"\nWindows now needs a restart before syncpss can continue with WSL distro setup.\n"
        L"Restart Windows, then run syncpss-wsl-installer.exe again.\n\n"
        L"Press Enter to close this installer..."
    );
    std::exit(0);
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
    const std::filesystem::path result = normalize_windows_env_path(value, variable_name);
    free(value);
    return result;
}

std::filesystem::path userprofile_path() {
    return appdata_path(L"USERPROFILE");
}

std::filesystem::path local_syncpss_app_dir() {
    const std::filesystem::path local_app_data = appdata_path(L"LOCALAPPDATA");
    require_within_profile(local_app_data, L"LOCALAPPDATA");
    return local_app_data / kWindowsAppDirName;
}

std::filesystem::path windows_runtime_dir() {
    return userprofile_path() / kWindowsRuntimeDirName;
}

std::filesystem::path start_menu_programs_dir() {
    const std::filesystem::path roaming_app_data = appdata_path(L"APPDATA");
    require_within_profile(roaming_app_data, L"APPDATA");
    return roaming_app_data / L"Microsoft" / L"Windows" / L"Start Menu" / L"Programs";
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
