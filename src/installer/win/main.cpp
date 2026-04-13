#include "common.hpp"

int wmain() {
    try {
        const InstallerOptions options = parse_options();
        print_header();
        log_line("Detecting WSL distros and local Linux users...", kYellow);
        ensure_host_prerequisites();

        const std::vector<std::wstring> distros = ensure_distros_ready(options);

        std::wstring distro;
        std::optional<UserEntry> selected_user;
        while (true) {
            if (options.distro.has_value()) {
                distro = *options.distro;
            } else {
                distro = select_distro_tui(distros);
            }
            validate_wsl_distro_name_or_throw(distro);

            ensure_distro_users_ready(distro);
            const std::vector<UserEntry> users = list_users_in_distro(distro);
            selected_user.reset();
            if (options.user.has_value()) {
                for (const auto& user : users) {
                    if (user.username == *options.user) {
                        selected_user = user;
                        break;
                    }
                }
            } else {
                selected_user = select_user_tui(users);
            }
            if (!selected_user.has_value()) {
                throw std::runtime_error("No Linux user was selected");
            }
            validate_linux_username_or_throw(selected_user->username);

            std::wstringstream confirmation;
            confirmation << L"Stage syncpss into distro '" << distro
                         << L"' for Linux user '" << selected_user->username
                         << L"' and continue?";
            if (prompt_yes_no(confirmation.str(), true)) {
                break;
            }

            if (options.distro.has_value() || options.user.has_value()) {
                throw std::runtime_error("Installer selection was not confirmed.");
            }
        }

        ensure_windows_runtime_support();
        create_start_menu_shortcut(distro, *selected_user);
        const PreparedInstallerAssets assets = prepare_installer_assets(options.install_source);
        log_line(
            "Preparing " + install_source_name(options.install_source) + " installer assets for WSL staging...",
            kYellow
        );
        copy_helper_to_wsl_home(*selected_user, assets);

        if (options.open_shell) {
            if (options.pause_on_exit) {
                prompt_press_enter(L"\nPress Enter to Run WSL Installer...");
            }
            open_wsl_installer_window(distro, *selected_user, options.install_source);
        }

        if (options.pause_on_exit) {
            pause_and_exit(0);
        }
        exit_without_pause(0);
    } catch (const std::exception& ex) {
        log_line("Installer error: " + std::string(ex.what()), kRed);
        try {
            const InstallerOptions options = parse_options();
            if (options.pause_on_exit) {
                pause_and_exit(1);
            }
        } catch (...) {
        }
        exit_without_pause(1);
    }
}
