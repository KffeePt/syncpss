#include "common.hpp"

void enable_ansi() {
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    if (GetConsoleMode(out, &mode) != 0) {
        SetConsoleMode(out, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
}

void log_line(const std::string& message, const char* color) {
    std::cout << color << message << kReset << std::endl;
}

void print_header() {
    enable_ansi();
    std::cout << kCyan;
    std::cout << R"(
                                                                     
                                                                     
  /$$$$$$$ /$$   /$$ /$$$$$$$   /$$$$$$$  /$$$$$$   /$$$$$$$ /$$$$$$$
 /$$_____/| $$  | $$| $$__  $$ /$$_____/ /$$__  $$ /$$_____//$$_____/
|  $$$$$$ | $$  | $$| $$  \ $$| $$      | $$  \ $$|  $$$$$$|  $$$$$$ 
 \____  $$| $$  | $$| $$  | $$| $$      | $$  | $$ \____  $$\____  $$
 /$$$$$$$/|  $$$$$$$| $$  | $$|  $$$$$$$| $$$$$$$/ /$$$$$$$//$$$$$$$/
|_______/  \____  $$|__/  |__/ \_______/| $$____/ |_______/|_______/ 
           /$$  | $$                    | $$                         
          |  $$$$$$/                    | $$                         
           \______/                     |__/                         
)" << std::endl;
    std::cout << kReset << std::endl;
    log_line("syncpss WSL Installer", kCyan);
    log_line("Guided Windows bootstrap for the Linux/WSL password-store installer", kYellow);
    std::cout << std::endl;
}

[[noreturn]] void pause_and_exit(int code) {
    std::cout << std::endl;
    if (code == 0) {
        log_line("Press any key to close.", kYellow);
    } else {
        log_line("Process terminated. Press any key to close.", kRed);
    }
    _getch();
    std::exit(code);
}

[[noreturn]] void exit_without_pause(int code) {
    std::exit(code);
}

bool prompt_yes_no(const std::wstring& message, bool default_yes) {
    const std::wstring suffix = default_yes ? L" [Y/n]: " : L" [y/N]: ";
    std::wcout << message << suffix;
    std::wstring answer;
    std::getline(std::wcin >> std::ws, answer);
    if (answer.empty()) {
        return default_yes;
    }

    const wchar_t first = static_cast<wchar_t>(std::towlower(answer.front()));
    return first == L'y';
}

void prompt_press_enter(const std::wstring& message) {
    std::wcout << message;
    std::wstring ignored;
    std::getline(std::wcin >> std::ws, ignored);
}
