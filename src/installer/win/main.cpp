#include "common.hpp"

int wmain() {
    try {
        const InstallerOptions options = parse_options();
        print_header();
        relaunch_as_admin_if_needed();
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
        const std::filesystem::path helper_script = resolve_helper_script();
        copy_helper_to_wsl_home(*selected_user, helper_script);

        if (options.open_shell) {
            open_wsl_installer_window(distro, *selected_user);
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
