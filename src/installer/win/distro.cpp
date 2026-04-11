#include "common.hpp"

InstallerOptions parse_options() {
    InstallerOptions options;

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv == nullptr) {
        throw std::runtime_error("CommandLineToArgvW failed");
    }

    for (int index = 1; index < argc; ++index) {
        const std::wstring arg = argv[index];
        if (arg == L"--distro" && index + 1 < argc) {
            options.distro = argv[++index];
            continue;
        }
        if (arg == L"--user" && index + 1 < argc) {
            options.user = argv[++index];
            continue;
        }
        if (arg == L"--open-shell") {
            options.open_shell = true;
            continue;
        }
        if (arg == L"--no-open-shell") {
            options.open_shell = false;
            continue;
        }
        if (arg == L"--no-pause") {
            options.pause_on_exit = false;
            continue;
        }
    }

    LocalFree(argv);
    return options;
}

std::vector<std::wstring> list_distros() {
    const ProcessResult result = run_process({L"wsl.exe", L"-l", L"-q"});
    if (result.exit_code != 0) {
        throw std::runtime_error("Failed to list WSL distros");
    }

    std::vector<std::wstring> distros;
    std::stringstream stream(result.output);
    std::string line;
    while (std::getline(stream, line)) {
        const std::wstring distro = trim(to_wide(trim_ascii(line)));
        if (distro.empty() || distro == L"docker-desktop" || distro == L"docker-desktop-data") {
            continue;
        }
        distros.push_back(distro);
    }
    return distros;
}

std::vector<std::wstring> list_online_distros() {
    const ProcessResult result = run_process({L"wsl.exe", L"-l", L"-o"});
    if (result.exit_code != 0) {
        return {};
    }

    std::vector<std::wstring> distros;
    std::stringstream stream(result.output);
    std::string line;
    while (std::getline(stream, line)) {
        const std::string trimmed_line = trim_ascii(line);
        if (trimmed_line.empty() || trimmed_line == "NAME" || trimmed_line == "NAME            FRIENDLY NAME") {
            continue;
        }

        std::size_t split = trimmed_line.find_first_of(" \t");
        const std::string machine_name = split == std::string::npos
            ? trimmed_line
            : trim_ascii(trimmed_line.substr(0, split));
        if (machine_name.empty()) {
            continue;
        }
        distros.push_back(to_wide(machine_name));
    }
    return distros;
}

std::optional<std::wstring> default_distro() {
    const ProcessResult result = run_process({L"wsl.exe", L"-l", L"-v"});
    if (result.exit_code != 0) {
        return std::nullopt;
    }

    std::stringstream stream(result.output);
    std::string line;
    while (std::getline(stream, line)) {
        const std::string trimmed_line = trim_ascii(line);
        if (!trimmed_line.empty() && trimmed_line[0] == '*') {
            const std::string without_star = trim_ascii(trimmed_line.substr(1));
            const std::size_t double_space = without_star.find("  ");
            return to_wide(double_space == std::string::npos ? without_star : without_star.substr(0, double_space));
        }
    }
    return std::nullopt;
}

std::wstring select_distro_tui(const std::vector<std::wstring>& distros) {
    if (distros.empty()) {
        throw std::runtime_error("No installable WSL distros found");
    }

    int selected = 0;
    if (const auto preferred = default_distro(); preferred.has_value()) {
        for (std::size_t i = 0; i < distros.size(); ++i) {
            if (distros[i] == *preferred) {
                selected = static_cast<int>(i);
                break;
            }
        }
    }

    while (true) {
        std::wcout << L"\x1b[2J\x1b[H";
        print_header();
        std::wcout << L"Choose the Linux distribution where syncpss should be installed:\n\n";
        for (std::size_t i = 0; i < distros.size(); ++i) {
            std::wcout << (static_cast<int>(i) == selected ? L"  > " : L"    ") << distros[i] << L"\n";
        }
        std::wcout << L"\nUse Up/Down or j/k, then press Enter.\n";
        std::wcout.flush();

        const int ch = _getch();
        if (ch == 224 || ch == 0) {
            const int extended = _getch();
            if (extended == 72) {
                selected = (selected - 1 + static_cast<int>(distros.size())) % static_cast<int>(distros.size());
            } else if (extended == 80) {
                selected = (selected + 1) % static_cast<int>(distros.size());
            }
            continue;
        }
        if (ch == 'k' || ch == 'K') {
            selected = (selected - 1 + static_cast<int>(distros.size())) % static_cast<int>(distros.size());
        } else if (ch == 'j' || ch == 'J') {
            selected = (selected + 1) % static_cast<int>(distros.size());
        } else if (ch == '\r') {
            return distros[static_cast<std::size_t>(selected)];
        }
    }
}

std::wstring select_online_distro_tui(const std::vector<std::wstring>& distros) {
    if (distros.empty()) {
        throw std::runtime_error("No online WSL distros were returned by wsl.exe");
    }

    const std::vector<std::wstring> preferred = {L"Ubuntu", L"kali-linux"};
    std::vector<std::wstring> items;
    for (const auto& name : preferred) {
        if (std::find(distros.begin(), distros.end(), name) != distros.end()) {
            items.push_back(name);
        }
    }
    for (const auto& distro : distros) {
        if (std::find(items.begin(), items.end(), distro) == items.end()) {
            items.push_back(distro);
        }
    }

    int selected = 0;
    while (true) {
        std::wcout << L"\x1b[2J\x1b[H";
        print_header();
        std::wcout << L"No WSL Linux distributions are installed yet.\n\n";
        std::wcout << L"Choose a Linux distribution to install now. Ubuntu and Kali are the recommended defaults.\n\n";
        for (std::size_t i = 0; i < items.size(); ++i) {
            std::wcout << (static_cast<int>(i) == selected ? L"  > " : L"    ") << items[i] << L"\n";
        }
        std::wcout << L"\nUse Up/Down or j/k, then press Enter.\n";
        std::wcout.flush();

        const int ch = _getch();
        if (ch == 224 || ch == 0) {
            const int extended = _getch();
            if (extended == 72) {
                selected = (selected - 1 + static_cast<int>(items.size())) % static_cast<int>(items.size());
            } else if (extended == 80) {
                selected = (selected + 1) % static_cast<int>(items.size());
            }
            continue;
        }
        if (ch == 'k' || ch == 'K') {
            selected = (selected - 1 + static_cast<int>(items.size())) % static_cast<int>(items.size());
        } else if (ch == 'j' || ch == 'J') {
            selected = (selected + 1) % static_cast<int>(items.size());
        } else if (ch == '\r') {
            return items[static_cast<std::size_t>(selected)];
        }
    }
}

namespace {

void open_store_uri(const std::wstring& uri) {
    HINSTANCE result = ShellExecuteW(nullptr, L"open", uri.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(result) <= 32) {
        throw std::runtime_error("Failed to open Microsoft Store from the installer.");
    }
}

void enable_wsl_core() {
    if (!prompt_yes_no(
            L"WSL does not look ready on this Windows install. Enable the required Windows features automatically now?",
            true)) {
        throw std::runtime_error("WSL must be enabled before syncpss can continue.");
    }

    log_line("Enabling the Windows WSL platform with wsl.exe --install --no-distribution...", kYellow);
    const int exit_code = run_process_interactive({L"wsl.exe", L"--install", L"--no-distribution"});
    if (exit_code != 0) {
        throw std::runtime_error(
            "wsl.exe --install --no-distribution did not complete successfully. If Windows requested a reboot, reboot and rerun syncpss."
        );
    }
}

void guide_store_distro_install() {
    while (true) {
        std::wcout << L"\x1b[2J\x1b[H";
        print_header();
        std::wcout << L"No WSL Linux distributions are installed yet.\n\n";
        std::wcout << L"Install a distro from Microsoft Store first.\n";
        std::wcout << L"Recommended: Ubuntu or Kali Linux.\n";
        std::wcout << L"You can also choose any other WSL-compatible distro you prefer.\n\n";
        std::wcout << L"  [u] Open Microsoft Store search for Ubuntu\n";
        std::wcout << L"  [k] Open Microsoft Store search for Kali Linux\n";
        std::wcout << L"  [m] Open Microsoft Store home\n";
        std::wcout << L"  [c] Continue after installing and configuring your distro\n";
        std::wcout << L"  [q] Cancel installer\n\n";
        std::wcout << L"Choose an option: ";
        std::wcout.flush();

        const int ch = _getch();
        switch (std::towlower(ch)) {
            case L'u':
                open_store_uri(L"ms-windows-store://search/?query=Ubuntu");
                prompt_press_enter(
                    L"\nInstall Ubuntu, launch it once, finish the Linux username/password setup, then press Enter here to continue..."
                );
                return;
            case L'k':
                open_store_uri(L"ms-windows-store://search/?query=Kali%20Linux");
                prompt_press_enter(
                    L"\nInstall Kali Linux, launch it once, finish the Linux username/password setup, then press Enter here to continue..."
                );
                return;
            case L'm':
                open_store_uri(L"ms-windows-store://home");
                prompt_press_enter(
                    L"\nInstall and launch your preferred Linux distro from Microsoft Store, finish the Linux username/password setup, then press Enter here to continue..."
                );
                return;
            case L'c':
                prompt_press_enter(
                    L"\nAfter you install and launch your Linux distro and finish the Linux username/password setup, press Enter here to continue..."
                );
                return;
            case L'q':
            case 27:
                throw std::runtime_error("A WSL Linux distribution is required before syncpss can continue.");
            default:
                break;
        }
    }
}

void launch_first_run_setup_window(const std::wstring& distro) {
    log_line(
        "Opening a second terminal window so you can finish the first Linux user setup for " + to_utf8(distro) + "...",
        kYellow
    );
    launch_process_new_console({
        L"wsl.exe",
        L"-d",
        distro
    });
}

void wait_for_first_linux_user(const std::wstring& distro) {
    while (true) {
        prompt_press_enter(
            L"\nComplete the Linux username/password setup in the new WSL window, then press Enter here to continue..."
        );
        try {
            const auto users = list_users_in_distro(distro);
            if (!users.empty()) {
                return;
            }
        } catch (...) {
        }

        if (!prompt_yes_no(
                L"syncpss still could not detect a Linux home user in that distro. Keep waiting and try again?",
                true)) {
            throw std::runtime_error("WSL distro setup was not finished yet.");
        }
    }
}

}  // namespace

std::vector<std::wstring> ensure_distros_ready(const InstallerOptions& options) {
    (void)options;
    std::vector<std::wstring> distros;
    try {
        distros = list_distros();
    } catch (const std::exception&) {
        enable_wsl_core();
        try {
            distros = list_distros();
        } catch (const std::exception&) {
            throw std::runtime_error(
                "WSL still is not ready after the automatic bootstrap. If Windows requested a reboot, reboot and rerun syncpss."
            );
        }
    }
    if (!distros.empty()) {
        return distros;
    }

    while (true) {
        guide_store_distro_install();
        try {
            distros = list_distros();
        } catch (const std::exception&) {
            distros.clear();
        }

        if (!distros.empty()) {
            return distros;
        }

        if (!prompt_yes_no(
                L"syncpss still cannot detect an installed WSL Linux distribution. Open Microsoft Store again and keep waiting?",
                true)) {
            throw std::runtime_error("A WSL Linux distribution is required before syncpss can continue.");
        }
    }
}

std::filesystem::path distro_home_root(const std::wstring& distro) {
    return std::filesystem::path(L"\\\\wsl.localhost") / distro / L"home";
}

std::vector<UserEntry> list_users_in_distro(const std::wstring& distro) {
    const std::filesystem::path home_root = distro_home_root(distro);
    if (!std::filesystem::exists(home_root)) {
        throw std::runtime_error("Could not access " + to_utf8(home_root.wstring()));
    }

    std::vector<UserEntry> users;
    for (const auto& entry : std::filesystem::directory_iterator(home_root)) {
        if (!entry.is_directory()) {
            continue;
        }
        const std::wstring username = entry.path().filename().wstring();
        if (username.empty()) {
            continue;
        }
        users.push_back(UserEntry{username, entry.path()});
    }

    std::sort(users.begin(), users.end(), [](const UserEntry& left, const UserEntry& right) {
        return left.username < right.username;
    });
    return users;
}

void ensure_distro_users_ready(const std::wstring& distro) {
    try {
        if (!list_users_in_distro(distro).empty()) {
            return;
        }
    } catch (...) {
    }

    launch_first_run_setup_window(distro);
    wait_for_first_linux_user(distro);
}

std::optional<UserEntry> select_user_tui(const std::vector<UserEntry>& users) {
    if (users.empty()) {
        return std::nullopt;
    }

    int selected = 0;
    while (true) {
        std::wcout << L"\x1b[2J\x1b[H";
        print_header();
        std::wcout << L"Choose the Linux user home where syncpss should stage installer.sh:\n\n";
        for (std::size_t i = 0; i < users.size(); ++i) {
            std::wcout << (static_cast<int>(i) == selected ? L"  > " : L"    ")
                       << users[i].username << L" (" << users[i].home_path.wstring() << L")\n";
        }
        std::wcout << L"\nUse Up/Down or j/k, then press Enter.\n";
        std::wcout.flush();

        const int ch = _getch();
        if (ch == 224 || ch == 0) {
            const int extended = _getch();
            if (extended == 72) {
                selected = (selected - 1 + static_cast<int>(users.size())) % static_cast<int>(users.size());
            } else if (extended == 80) {
                selected = (selected + 1) % static_cast<int>(users.size());
            }
            continue;
        }
        if (ch == 'k' || ch == 'K') {
            selected = (selected - 1 + static_cast<int>(users.size())) % static_cast<int>(users.size());
        } else if (ch == 'j' || ch == 'J') {
            selected = (selected + 1) % static_cast<int>(users.size());
        } else if (ch == '\r') {
            return users[static_cast<std::size_t>(selected)];
        } else if (ch == 27) {
            return std::nullopt;
        }
    }
}
