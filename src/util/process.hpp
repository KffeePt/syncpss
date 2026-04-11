#pragma once

#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace syncpss::util {

struct ProcessResult {
    int exit_code = -1;
    std::string stdout_output;
    std::string stderr_output;
};

struct ProcessOptions {
    std::optional<std::string> cwd = std::nullopt;
    std::optional<std::map<std::string, std::string>> env = std::nullopt;
    std::string stdin_input;

    ProcessOptions() = default;
    ProcessOptions(
        std::optional<std::string> cwd_value,
        std::optional<std::map<std::string, std::string>> env_value = std::nullopt,
        std::string stdin_value = {}
    )
        : cwd(std::move(cwd_value)),
          env(std::move(env_value)),
          stdin_input(std::move(stdin_value)) {}
};

ProcessResult run(
    const std::vector<std::string>& argv,
    const ProcessOptions& options = {}
);

int run_passthrough(
    const std::vector<std::string>& argv,
    const ProcessOptions& options = {}
);

bool is_command_available(const std::string& executable);

}  // namespace syncpss::util
