#include "common.hpp"

std::wstring to_wide(const std::string& input) {
    if (input.empty()) {
        return L"";
    }
    const int size = MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, nullptr, 0);
    if (size <= 0) {
        throw std::runtime_error("UTF-8 to UTF-16 conversion failed");
    }
    std::wstring output(static_cast<std::size_t>(size - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, output.data(), size);
    return output;
}

std::string to_utf8(const std::wstring& input) {
    if (input.empty()) {
        return "";
    }
    const int size = WideCharToMultiByte(CP_UTF8, 0, input.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) {
        throw std::runtime_error("UTF-16 to UTF-8 conversion failed");
    }
    std::string output(static_cast<std::size_t>(size - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, input.c_str(), -1, output.data(), size, nullptr, nullptr);
    return output;
}

std::wstring trim(const std::wstring& value) {
    std::size_t start = 0;
    while (start < value.size() && std::iswspace(value[start]) != 0) {
        ++start;
    }
    std::size_t end = value.size();
    while (end > start && std::iswspace(value[end - 1]) != 0) {
        --end;
    }
    return value.substr(start, end - start);
}

std::string trim_ascii(const std::string& value) {
    std::size_t start = 0;
    while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start])) != 0) {
        ++start;
    }
    std::size_t end = value.size();
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
        --end;
    }
    return value.substr(start, end - start);
}

std::string strip_nuls(const std::string& value) {
    std::string cleaned;
    cleaned.reserve(value.size());
    for (const char ch : value) {
        if (ch != '\0') {
            cleaned.push_back(ch);
        }
    }
    return cleaned;
}

bool contains_control_chars(const std::wstring& value) {
    for (const wchar_t ch : value) {
        if (ch < 32 || ch == 127) {
            return true;
        }
    }
    return false;
}

void validate_wsl_distro_name_or_throw(const std::wstring& value) {
    const std::wstring trimmed = trim(value);
    if (trimmed.empty() || contains_control_chars(trimmed)) {
        throw std::runtime_error("WSL distro name is empty or contains control characters");
    }
    if (trimmed.size() > 64U) {
        throw std::runtime_error("WSL distro name is too long");
    }
    for (const wchar_t ch : trimmed) {
        if (!(std::iswalnum(ch) != 0 || ch == L'-' || ch == L'_' || ch == L'.')) {
            throw std::runtime_error("WSL distro name contains unsupported characters");
        }
    }
}

void validate_linux_username_or_throw(const std::wstring& value) {
    const std::wstring trimmed = trim(value);
    if (trimmed.empty() || contains_control_chars(trimmed)) {
        throw std::runtime_error("Linux username is empty or contains control characters");
    }
    if (trimmed.size() > 32U) {
        throw std::runtime_error("Linux username is too long");
    }
    if (trimmed.front() == L'-') {
        throw std::runtime_error("Linux username cannot start with '-'");
    }
    for (const wchar_t ch : trimmed) {
        if (!(std::iswalnum(ch) != 0 || ch == L'-' || ch == L'_' || ch == L'.')) {
            throw std::runtime_error("Linux username contains unsupported characters");
        }
    }
}

std::wstring quote_arg(const std::wstring& arg) {
    if (arg.find_first_of(L" \t\"") == std::wstring::npos) {
        return arg;
    }
    std::wstring quoted = L"\"";
    std::size_t backslash_count = 0;
    for (const wchar_t ch : arg) {
        if (ch == L'\\') {
            ++backslash_count;
            continue;
        }
        if (ch == L'"') {
            quoted.append(backslash_count * 2 + 1, L'\\');
            quoted += L'"';
            backslash_count = 0;
            continue;
        }
        if (backslash_count > 0) {
            quoted.append(backslash_count, L'\\');
            backslash_count = 0;
        }
        quoted += ch;
    }
    if (backslash_count > 0) {
        quoted.append(backslash_count * 2, L'\\');
    }
    quoted += L"\"";
    return quoted;
}

ProcessResult run_process(const std::vector<std::wstring>& argv) {
    if (argv.empty()) {
        throw std::runtime_error("Cannot run empty argv");
    }

    SECURITY_ATTRIBUTES sa{};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE read_pipe = nullptr;
    HANDLE write_pipe = nullptr;
    if (!CreatePipe(&read_pipe, &write_pipe, &sa, 0)) {
        throw std::runtime_error("CreatePipe failed");
    }
    SetHandleInformation(read_pipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = write_pipe;
    si.hStdError = write_pipe;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION pi{};
    std::wstring command_line;
    for (std::size_t i = 0; i < argv.size(); ++i) {
        if (i > 0) {
            command_line += L' ';
        }
        command_line += quote_arg(argv[i]);
    }

    std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
    mutable_command.push_back(L'\0');

    if (!CreateProcessW(
            nullptr,
            mutable_command.data(),
            nullptr,
            nullptr,
            TRUE,
            CREATE_NO_WINDOW,
            nullptr,
            nullptr,
            &si,
            &pi)) {
        CloseHandle(read_pipe);
        CloseHandle(write_pipe);
        throw std::runtime_error("CreateProcessW failed");
    }

    CloseHandle(write_pipe);

    std::string output;
    char buffer[4096];
    DWORD bytes_read = 0;
    while (ReadFile(read_pipe, buffer, sizeof(buffer), &bytes_read, nullptr) != 0 && bytes_read > 0) {
        output.append(buffer, buffer + bytes_read);
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(pi.hProcess, &exit_code);

    CloseHandle(read_pipe);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    return ProcessResult{exit_code, strip_nuls(output)};
}

int run_process_interactive(const std::vector<std::wstring>& argv) {
    if (argv.empty()) {
        throw std::runtime_error("Cannot run empty argv");
    }

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION pi{};
    std::wstring command_line;
    for (std::size_t i = 0; i < argv.size(); ++i) {
        if (i > 0) {
            command_line += L' ';
        }
        command_line += quote_arg(argv[i]);
    }

    std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
    mutable_command.push_back(L'\0');

    if (!CreateProcessW(
            nullptr,
            mutable_command.data(),
            nullptr,
            nullptr,
            TRUE,
            0,
            nullptr,
            nullptr,
            &si,
            &pi)) {
        throw std::runtime_error("CreateProcessW failed for interactive process");
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(pi.hProcess, &exit_code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return static_cast<int>(exit_code);
}

void launch_process_new_console(const std::vector<std::wstring>& argv) {
    if (argv.empty()) {
        throw std::runtime_error("Cannot run empty argv");
    }

    STARTUPINFOW si{};
    si.cb = sizeof(si);

    PROCESS_INFORMATION pi{};
    std::wstring command_line;
    for (std::size_t i = 0; i < argv.size(); ++i) {
        if (i > 0) {
            command_line += L' ';
        }
        command_line += quote_arg(argv[i]);
    }

    std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
    mutable_command.push_back(L'\0');

    if (!CreateProcessW(
            nullptr,
            mutable_command.data(),
            nullptr,
            nullptr,
            FALSE,
            CREATE_NEW_CONSOLE,
            nullptr,
            nullptr,
            &si,
            &pi)) {
        throw std::runtime_error("CreateProcessW failed for detached process");
    }

    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
}

std::string last_error_message(DWORD error) {
    LPSTR buffer = nullptr;
    const DWORD size = FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr,
        error,
        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<LPSTR>(&buffer),
        0,
        nullptr
    );

    std::string message = size > 0 && buffer != nullptr ? trim_ascii(buffer) : "Unknown Windows error";
    if (buffer != nullptr) {
        LocalFree(buffer);
    }
    return message;
}
