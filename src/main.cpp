#include "tui/tui.hpp"
#include "util/config.hpp"
#include "util/paths.hpp"
#include "util/runtime_config.hpp"

#include <exception>
#include <iostream>
#include <optional>

int main(int /*argc*/, char** /*argv*/) {
    try {
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
