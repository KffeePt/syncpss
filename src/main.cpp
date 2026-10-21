#include "tui/tui.hpp"
#include "util/config.hpp"
#include "util/paths.hpp"
#include "util/process.hpp"
#include "util/runtime_config.hpp"

#include <nlohmann/json.hpp>

#include <exception>
#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <vector>
#include <unistd.h>

namespace {

void print_help() {
    std::cout << "syncpss " << SYNCPSS_VERSION << "\n"
              << "Usage: syncpss [tui | doctor [--json] | setup [--local|--release]]\n"
              << "  tui           Open the password manager (default, requires a terminal)\n"
              << "  doctor        Check installation and runtime dependencies without reading secrets\n"
              << "  setup         Run the installed setup/repair wizard\n"
              << "  -h, --help    Show this help\n"
              << "  -V, --version Show the installed application version\n";
}

int doctor(bool json_output) {
    nlohmann::json checks = nlohmann::json::object();
    bool ready = true;
    for (const auto* command : {"pass", "gpg", "git", "ssh", "ssh-keygen", "curl", "gh"}) {
        const bool available = syncpss::util::is_command_available(command);
        checks[command] = available;
        ready = ready && available;
    }
    const bool configured = syncpss::util::runtime_config_exists() || syncpss::util::config_exists();
    const nlohmann::json report = {
        {"schema_version", 1}, {"version", SYNCPSS_VERSION},
        {"configured", configured}, {"dependencies", checks},
        {"ready", ready && configured}
    };
    if (json_output) {
        std::cout << report.dump() << '\n';
    } else {
        std::cout << "syncpss " << SYNCPSS_VERSION << '\n';
        for (auto it = checks.begin(); it != checks.end(); ++it) {
            std::cout << (it.value().get<bool>() ? "OK      " : "MISSING ") << it.key() << '\n';
        }
        std::cout << (configured ? "Configuration present\n" : "Setup required: run syncpss setup\n");
    }
    return ready && configured ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const std::string command = argc > 1 ? argv[1] : "tui";
        if (command == "--help" || command == "-h" || command == "help") {
            print_help();
            return 0;
        }
        if (command == "--version" || command == "-V" || command == "version") {
            std::cout << "syncpss " << SYNCPSS_VERSION << '\n';
            return 0;
        }
        if (command == "doctor" && (argc == 2 || (argc == 3 && std::string(argv[2]) == "--json"))) {
            return doctor(argc == 3);
        }
        if (command == "setup") {
            if (argc == 3 && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
                std::cout << "Usage: syncpss setup [--local|--release]\n"
                          << "Runs the installed wizard; setup decisions remain interactive.\n";
                return 0;
            }
            if (argc > 3 || (argc == 3 && std::string(argv[2]) != "--local" && std::string(argv[2]) != "--release")) {
                std::cerr << "Usage: syncpss setup [--local|--release]\n";
                return 2;
            }
            if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
                std::cerr << "Setup needs an interactive terminal. Run syncpss setup in your terminal.\n";
                return 2;
            }
            const auto helper = syncpss::util::resolve_runtime_helper_path("installer.sh");
            syncpss::util::require_managed_path(helper, "setup helper");
            if (std::filesystem::is_symlink(helper) || !std::filesystem::is_regular_file(helper)) {
                std::cerr << "Setup helper is missing or unsafe. Run the one-command installer again.\n";
                return 1;
            }
            std::vector<std::string> args = {"bash", helper.string()};
            if (argc == 3) {
                args.emplace_back(argv[2]);
            }
            return syncpss::util::run_passthrough(args);
        }
        if (command != "tui" || argc > 2) {
            std::cerr << "Unknown command or option. Run syncpss --help.\n";
            return 2;
        }
        if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
            std::cerr << "The TUI needs an interactive terminal. Use syncpss doctor --json for automation.\n";
            return 2;
        }
        std::optional<syncpss::util::AppConfig> config;
        std::optional<syncpss::util::RuntimeConfig> runtime_config;
        if (syncpss::util::runtime_config_exists()) {
            runtime_config = syncpss::util::load_runtime_config();
            config = syncpss::util::to_app_config(*runtime_config);
        } else if (syncpss::util::config_exists()) {
            config = syncpss::util::load_config();
        }

        syncpss::tui::TuiApp app(config, runtime_config);
        return app.run();
    } catch (const std::exception& ex) {
        std::cerr << "syncpss startup error: " << ex.what() << '\n';
        return 1;
    }
}
