#include "util/process.hpp"

#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace syncpss::util {
namespace {

using EnvMap = std::map<std::string, std::string>;

[[noreturn]] void throw_errno(const std::string& message) {
    throw std::runtime_error(message + ": " + std::strerror(errno));
}

std::vector<char*> build_argv(const std::vector<std::string>& argv) {
    std::vector<char*> result;
    result.reserve(argv.size() + 1);
    for (const std::string& item : argv) {
        result.push_back(const_cast<char*>(item.c_str()));
    }
    result.push_back(nullptr);
    return result;
}

void apply_environment_overrides(const std::optional<EnvMap>& extra_env) {
    if (!extra_env.has_value()) {
        return;
    }
    for (const auto& [key, value] : *extra_env) {
        if (setenv(key.c_str(), value.c_str(), 1) != 0) {
            _exit(127);
        }
    }
}

void write_all(int fd, const std::string& input) {
    std::size_t offset = 0;
    while (offset < input.size()) {
        const ssize_t written =
            ::write(fd, input.data() + static_cast<std::ptrdiff_t>(offset), input.size() - offset);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            throw_errno("Failed writing to child stdin");
        }
        offset += static_cast<std::size_t>(written);
    }
}

void append_from_fd(int fd, std::string& target, bool& open_flag) {
    std::array<char, 4096> buffer{};
    const ssize_t bytes_read = ::read(fd, buffer.data(), buffer.size());
    if (bytes_read > 0) {
        target.append(buffer.data(), static_cast<std::size_t>(bytes_read));
        return;
    }
    if (bytes_read == 0) {
        ::close(fd);
        open_flag = false;
        return;
    }
    if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        ::close(fd);
        open_flag = false;
    }
}

void set_nonblocking(int fd) {
    const int flags = fcntl(fd, F_GETFL);
    if (flags < 0) {
        throw_errno("Failed to read file descriptor flags");
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        throw_errno("Failed to set non-blocking mode");
    }
}

ProcessResult wait_and_capture(
    pid_t child_pid,
    int stdout_fd,
    int stderr_fd,
    int stdin_fd,
    const std::string& stdin_input
) {
    ProcessResult result;
    bool stdout_open = true;
    bool stderr_open = true;

    if (stdin_fd >= 0) {
        if (!stdin_input.empty()) {
            write_all(stdin_fd, stdin_input);
        }
        ::close(stdin_fd);
    }

    set_nonblocking(stdout_fd);
    set_nonblocking(stderr_fd);

    while (stdout_open || stderr_open) {
        fd_set read_set;
        FD_ZERO(&read_set);

        int max_fd = -1;
        if (stdout_open) {
            FD_SET(stdout_fd, &read_set);
            max_fd = std::max(max_fd, stdout_fd);
        }
        if (stderr_open) {
            FD_SET(stderr_fd, &read_set);
            max_fd = std::max(max_fd, stderr_fd);
        }

        const int ready = ::select(max_fd + 1, &read_set, nullptr, nullptr, nullptr);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            throw_errno("Failed waiting on child pipes");
        }

        if (stdout_open && FD_ISSET(stdout_fd, &read_set)) {
            append_from_fd(stdout_fd, result.stdout_output, stdout_open);
        }
        if (stderr_open && FD_ISSET(stderr_fd, &read_set)) {
            append_from_fd(stderr_fd, result.stderr_output, stderr_open);
        }
    }

    int status = 0;
    while (waitpid(child_pid, &status, 0) < 0) {
        if (errno != EINTR) {
            throw_errno("Failed waiting for child process");
        }
    }

    if (WIFEXITED(status)) {
        result.exit_code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        result.exit_code = 128 + WTERMSIG(status);
    } else {
        result.exit_code = -1;
    }

    return result;
}

}  // namespace

ProcessResult run(const std::vector<std::string>& argv, const ProcessOptions& options) {
    if (argv.empty()) {
        throw std::invalid_argument("Cannot execute an empty argv");
    }

    int stdout_pipe[2]{-1, -1};
    int stderr_pipe[2]{-1, -1};
    int stdin_pipe[2]{-1, -1};

    if (pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
        throw_errno("Failed to create output pipes");
    }

    const bool needs_stdin = !options.stdin_input.empty();
    if (needs_stdin && pipe(stdin_pipe) < 0) {
        throw_errno("Failed to create stdin pipe");
    }

    std::vector<char*> exec_argv = build_argv(argv);

    const pid_t pid = fork();
    if (pid < 0) {
        throw_errno("Failed to fork");
    }

    if (pid == 0) {
        if (options.cwd.has_value() && chdir(options.cwd->c_str()) != 0) {
            _exit(127);
        }
        apply_environment_overrides(options.env);

        if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0 || dup2(stderr_pipe[1], STDERR_FILENO) < 0) {
            _exit(127);
        }

        if (needs_stdin && dup2(stdin_pipe[0], STDIN_FILENO) < 0) {
            _exit(127);
        }

        ::close(stdout_pipe[0]);
        ::close(stdout_pipe[1]);
        ::close(stderr_pipe[0]);
        ::close(stderr_pipe[1]);

        if (needs_stdin) {
            ::close(stdin_pipe[0]);
            ::close(stdin_pipe[1]);
        }

        execvp(exec_argv[0], exec_argv.data());
        _exit(127);
    }

    ::close(stdout_pipe[1]);
    ::close(stderr_pipe[1]);

    if (needs_stdin) {
        ::close(stdin_pipe[0]);
    }

    return wait_and_capture(
        pid,
        stdout_pipe[0],
        stderr_pipe[0],
        needs_stdin ? stdin_pipe[1] : -1,
        options.stdin_input
    );
}

int run_passthrough(const std::vector<std::string>& argv, const ProcessOptions& options) {
    if (argv.empty()) {
        throw std::invalid_argument("Cannot execute an empty argv");
    }

    std::vector<char*> exec_argv = build_argv(argv);

    const pid_t pid = fork();
    if (pid < 0) {
        throw_errno("Failed to fork");
    }

    if (pid == 0) {
        if (options.cwd.has_value() && chdir(options.cwd->c_str()) != 0) {
            _exit(127);
        }
        apply_environment_overrides(options.env);
        execvp(exec_argv[0], exec_argv.data());
        _exit(127);
    }

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            throw_errno("Failed waiting for child process");
        }
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
}

bool is_command_available(const std::string& executable) {
    if (executable.empty()) {
        return false;
    }

    if (executable.find('/') != std::string::npos) {
        return access(executable.c_str(), X_OK) == 0;
    }

    const char* path_env = std::getenv("PATH");
    if (path_env == nullptr) {
        return false;
    }

    std::stringstream path_stream(path_env);
    std::string segment;
    while (std::getline(path_stream, segment, ':')) {
        if (segment.empty()) {
            continue;
        }
        const std::filesystem::path candidate = std::filesystem::path(segment) / executable;
        if (access(candidate.c_str(), X_OK) == 0) {
            return true;
        }
    }

    return false;
}

}  // namespace syncpss::util
