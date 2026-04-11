#include "store/store.hpp"

#include "util/paths.hpp"
#include "util/process.hpp"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <unistd.h>

namespace syncpss::store {
namespace {

using json = nlohmann::json;

std::filesystem::path legacy_notes_db_path() {
    return syncpss::util::runtime_directory() / "notes.json";
}

std::filesystem::path notes_directory_path() {
    return syncpss::util::runtime_notes_directory();
}

void secure_runtime_file(const std::filesystem::path& path) {
    std::error_code ignored;
    std::filesystem::permissions(
        path,
        std::filesystem::perms::owner_read | std::filesystem::perms::owner_write,
        std::filesystem::perm_options::replace,
        ignored
    );
}

void secure_runtime_directory(const std::filesystem::path& path) {
    std::error_code ignored;
    std::filesystem::permissions(
        path,
        std::filesystem::perms::owner_all,
        std::filesystem::perm_options::replace,
        ignored
    );
}

json load_legacy_notes_db() {
    const std::filesystem::path path = legacy_notes_db_path();
    if (!std::filesystem::exists(path)) {
        return json::object();
    }

    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("Cannot read legacy notes database: " + path.string());
    }

    json root;
    input >> root;
    if (!root.is_object()) {
        return json::object();
    }
    return root;
}

std::string iso8601_timestamp_for_filename() {
    const auto now = std::chrono::system_clock::now();
    const std::time_t now_time = std::chrono::system_clock::to_time_t(now);
    std::tm utc_time{};
#if defined(__APPLE__) || defined(__linux__)
    gmtime_r(&now_time, &utc_time);
#else
    utc_time = *std::gmtime(&now_time);
#endif
    char buffer[32]{};
    std::strftime(buffer, sizeof(buffer), "%Y%m%dT%H%M%SZ", &utc_time);
    return buffer;
}

void repair_gnupg_permissions_for_real_user() {
    const std::filesystem::path gnupg_dir = syncpss::util::get_real_home() / ".gnupg";
    if (!std::filesystem::exists(gnupg_dir)) {
        return;
    }

    if (syncpss::util::is_root_user()) {
        const std::string owner =
            syncpss::util::get_real_username() + ":" + syncpss::util::get_real_groupname();
        (void)syncpss::util::run({"chown", "-R", owner, gnupg_dir.string()});
    }

    std::error_code ignored;
    std::filesystem::permissions(
        gnupg_dir,
        std::filesystem::perms::owner_all,
        std::filesystem::perm_options::replace,
        ignored
    );

    for (const auto& entry : std::filesystem::recursive_directory_iterator(gnupg_dir)) {
        const auto perms = entry.is_directory()
            ? std::filesystem::perms::owner_all
            : (std::filesystem::perms::owner_read | std::filesystem::perms::owner_write);
        std::filesystem::permissions(entry.path(), perms, std::filesystem::perm_options::replace, ignored);
    }
}

std::map<std::string, std::string> pass_env(const std::filesystem::path& store_path) {
    const std::filesystem::path real_home = syncpss::util::get_real_home();
    const std::string real_user = syncpss::util::get_real_username();
    const std::filesystem::path runtime_dir = syncpss::util::get_real_xdg_runtime_dir();
    std::map<std::string, std::string> env = {
        {"PASSWORD_STORE_DIR", store_path.string()},
        {"HOME", real_home.string()},
        {"GNUPGHOME", (real_home / ".gnupg").string()},
        {"XDG_RUNTIME_DIR", runtime_dir.string()},
        {"USER", real_user},
        {"LOGNAME", real_user},
        {"GPG_AGENT_INFO", ""}
    };

    if (const char* tty_path = ::ttyname(STDIN_FILENO); tty_path != nullptr) {
        env["GPG_TTY"] = tty_path;
    }
    return env;
}

std::map<std::string, std::string> gpg_env() {
    const std::filesystem::path real_home = syncpss::util::get_real_home();
    const std::string real_user = syncpss::util::get_real_username();
    const std::filesystem::path runtime_dir = syncpss::util::get_real_xdg_runtime_dir();
    std::map<std::string, std::string> env = {
        {"HOME", real_home.string()},
        {"GNUPGHOME", (real_home / ".gnupg").string()},
        {"XDG_RUNTIME_DIR", runtime_dir.string()},
        {"USER", real_user},
        {"LOGNAME", real_user},
        {"GPG_AGENT_INFO", ""}
    };

    if (const char* tty_path = ::ttyname(STDIN_FILENO); tty_path != nullptr) {
        env["GPG_TTY"] = tty_path;
    }
    return env;
}

std::vector<std::string> pass_command_as_real_user(
    const std::vector<std::string>& pass_argv,
    const std::filesystem::path& store_path
) {
    std::vector<std::string> argv;
    if (syncpss::util::is_root_user()) {
        const std::filesystem::path real_home = syncpss::util::get_real_home();
        const std::string real_user = syncpss::util::get_real_username();
        const std::filesystem::path runtime_dir = syncpss::util::get_real_xdg_runtime_dir();
        argv = {
            "sudo",
            "-H",
            "-u",
            real_user,
            "env",
            "HOME=" + real_home.string(),
            "GNUPGHOME=" + (real_home / ".gnupg").string(),
            "XDG_RUNTIME_DIR=" + runtime_dir.string(),
            "USER=" + real_user,
            "LOGNAME=" + real_user,
            "PASSWORD_STORE_DIR=" + store_path.string(),
            "GPG_AGENT_INFO="
        };
        if (const char* tty_path = ::ttyname(STDIN_FILENO); tty_path != nullptr) {
            argv.push_back("GPG_TTY=" + std::string(tty_path));
        }
        argv.insert(argv.end(), pass_argv.begin(), pass_argv.end());
        return argv;
    }

    return pass_argv;
}

std::vector<std::string> command_as_real_user(
    const std::vector<std::string>& argv,
    const std::map<std::string, std::string>& env
) {
    if (!syncpss::util::is_root_user()) {
        return argv;
    }

    std::vector<std::string> prefixed = {
        "sudo",
        "-H",
        "-u",
        syncpss::util::get_real_username(),
        "env"
    };
    for (const auto& [key, value] : env) {
        prefixed.push_back(key + "=" + value);
    }
    prefixed.insert(prefixed.end(), argv.begin(), argv.end());
    return prefixed;
}

syncpss::util::ProcessResult run_pass(
    const std::vector<std::string>& pass_argv,
    const std::filesystem::path& store_path,
    const std::string& stdin_input = ""
) {
    repair_gnupg_permissions_for_real_user();
    const std::vector<std::string> argv = pass_command_as_real_user(pass_argv, store_path);
    if (syncpss::util::is_root_user()) {
        return syncpss::util::run(argv, syncpss::util::ProcessOptions{std::nullopt, std::nullopt, stdin_input});
    }
    return syncpss::util::run(argv, syncpss::util::ProcessOptions{std::nullopt, pass_env(store_path), stdin_input});
}

syncpss::util::ProcessResult run_gpg(
    const std::vector<std::string>& argv,
    const std::string& stdin_input = ""
) {
    repair_gnupg_permissions_for_real_user();
    const std::map<std::string, std::string> env = gpg_env();
    const std::vector<std::string> final_argv = command_as_real_user(argv, env);
    if (syncpss::util::is_root_user()) {
        return syncpss::util::run(final_argv, syncpss::util::ProcessOptions{std::nullopt, std::nullopt, stdin_input});
    }
    return syncpss::util::run(final_argv, syncpss::util::ProcessOptions{std::nullopt, env, stdin_input});
}

std::string trim(const std::string& value) {
    const std::size_t start = value.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) {
        return "";
    }
    const std::size_t end = value.find_last_not_of(" \t\r\n");
    return value.substr(start, end - start + 1);
}

bool looks_like_tree_line(const std::string& line) {
    return line.find("|-- ") != std::string::npos || line.find("`-- ") != std::string::npos;
}

std::size_t tree_depth(const std::string& line, std::size_t& offset) {
    std::size_t depth = 0;
    offset = 0;
    while (offset + 4U <= line.size()) {
        const std::string chunk = line.substr(offset, 4U);
        if (chunk == "|   " || chunk == "    ") {
            ++depth;
            offset += 4U;
            continue;
        }
        break;
    }
    return depth;
}

std::string sanitize_note_token(const std::string& value, const std::string& fallback) {
    std::string sanitized;
    sanitized.reserve(value.size());
    for (const unsigned char ch : value) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            sanitized.push_back(static_cast<char>(ch));
        } else if (ch == '-' || ch == '_' || ch == '.') {
            sanitized.push_back(static_cast<char>(ch));
        } else if (ch == '/' || ch == '@' || ch == ':' || ch == ' ' || ch == '[' || ch == ']') {
            sanitized.push_back('-');
        }
    }
    while (!sanitized.empty() && sanitized.front() == '-') {
        sanitized.erase(sanitized.begin());
    }
    while (!sanitized.empty() && sanitized.back() == '-') {
        sanitized.pop_back();
    }
    return sanitized.empty() ? fallback : sanitized;
}

std::uint64_t fnv1a_64(const std::string& value) {
    std::uint64_t hash = 1469598103934665603ULL;
    for (const unsigned char ch : value) {
        hash ^= static_cast<std::uint64_t>(ch);
        hash *= 1099511628211ULL;
    }
    return hash;
}

std::filesystem::path note_path_for_entry_name(const std::string& name, const std::string& username) {
    const std::filesystem::path parsed(name);
    const std::string password_token = sanitize_note_token(parsed.filename().generic_string(), "entry");
    const std::string username_token = sanitize_note_token(username, "note");
    std::ostringstream suffix;
    suffix << std::hex << std::nouppercase << fnv1a_64(name);
    return notes_directory_path() / (password_token + "-" + username_token + "-" + suffix.str() + ".note");
}

void ensure_notes_directory() {
    std::filesystem::create_directories(notes_directory_path());
    secure_runtime_directory(notes_directory_path());
}

std::optional<std::string> decrypt_note_file(const std::filesystem::path& note_path) {
    if (!std::filesystem::exists(note_path)) {
        return std::nullopt;
    }

    const syncpss::util::ProcessResult result =
        run_gpg({"gpg", "--batch", "--quiet", "--decrypt", note_path.string()});
    if (result.exit_code != 0) {
        throw std::runtime_error("gpg note decrypt failed: " + result.stderr_output);
    }
    return result.stdout_output;
}

void encrypt_note_file(const std::filesystem::path& note_path, const std::string& key_id, const std::string& notes) {
    ensure_notes_directory();
    const syncpss::util::ProcessResult result = run_gpg(
        {
            "gpg",
            "--batch",
            "--yes",
            "--quiet",
            "--armor",
            "--trust-model",
            "always",
            "--encrypt",
            "--recipient",
            key_id,
            "--output",
            note_path.string()
        },
        notes
    );
    if (result.exit_code != 0) {
        throw std::runtime_error("gpg note encrypt failed: " + result.stderr_output);
    }
    secure_runtime_file(note_path);
}

}  // namespace

PasswordStore::PasswordStore(std::filesystem::path store_path, std::string gpg_key_id)
    : store_path_(std::move(store_path)),
      gpg_key_id_(std::move(gpg_key_id)) {}

const std::filesystem::path& PasswordStore::path() const noexcept {
    return store_path_;
}

bool PasswordStore::validate_entry_name(const std::string& name) const {
    if (name.empty() || name.front() == '/' || name.back() == '/') {
        return false;
    }

    std::stringstream input(name);
    std::string segment;
    while (std::getline(input, segment, '/')) {
        if (segment.empty() || segment == "." || segment == "..") {
            return false;
        }
        for (const unsigned char raw_char : segment) {
            if (raw_char < 32U || raw_char == 127U || raw_char == static_cast<unsigned char>('/')) {
                return false;
            }
        }
    }
    return true;
}

std::vector<std::string> PasswordStore::list_entries() const {
    syncpss::util::ProcessResult listed = run_pass({"pass", "ls"}, store_path_);
    if (listed.exit_code != 0) {
        throw std::runtime_error("pass ls failed: " + listed.stderr_output);
    }

    std::vector<std::string> entries;
    std::vector<std::string> stack;
    std::stringstream lines(listed.stdout_output);
    std::string line;
    while (std::getline(lines, line)) {
        const std::string stripped = trim(line);
        if (stripped.empty() || stripped == "Password Store") {
            continue;
        }
        if (!looks_like_tree_line(line)) {
            continue;
        }

        std::size_t offset = 0;
        const std::size_t depth = tree_depth(line, offset);
        if (offset + 4U > line.size()) {
            continue;
        }
        offset += 4U;

        const std::string name = trim(line.substr(offset));
        stack.resize(depth);

        std::filesystem::path candidate;
        for (const std::string& part : stack) {
            candidate /= part;
        }
        candidate /= name;

        const std::filesystem::path entry_path = store_path_ / candidate;
        if (std::filesystem::is_directory(entry_path)) {
            stack.push_back(name);
        }
        if (std::filesystem::exists(entry_path.string() + ".gpg")) {
            entries.push_back(candidate.generic_string());
        }
    }

    if (entries.empty()) {
        for (const auto& file : std::filesystem::recursive_directory_iterator(store_path_)) {
            if (!file.is_regular_file() || file.path().extension() != ".gpg") {
                continue;
            }
            if (file.path().string().find((store_path_ / ".git").string()) == 0) {
                continue;
            }
            std::filesystem::path relative = std::filesystem::relative(file.path(), store_path_);
            relative.replace_extension();
            entries.push_back(relative.generic_string());
        }
    }

    std::sort(entries.begin(), entries.end());
    entries.erase(std::unique(entries.begin(), entries.end()), entries.end());
    return entries;
}

Entry PasswordStore::parse_entry(const std::string& name, const std::string& raw) const {
    Entry entry;
    entry.name = name;

    std::stringstream input(raw);
    std::getline(input, entry.password);

    std::string line;
    bool in_notes = false;
    std::ostringstream notes;
    while (std::getline(input, line)) {
        if (in_notes) {
            if (!notes.str().empty()) {
                notes << '\n';
            }
            notes << line;
            continue;
        }

        if (line.rfind("username: ", 0) == 0) {
            entry.username = line.substr(10);
        } else if (line.rfind("url: ", 0) == 0) {
            entry.url = line.substr(5);
        } else if (line == "notes:") {
            in_notes = true;
        }
    }

    entry.notes = notes.str();
    return entry;
}

Entry PasswordStore::read_entry(const std::string& name) const {
    if (!validate_entry_name(name)) {
        throw std::runtime_error("Invalid entry name. Allowed: [a-zA-Z0-9/_@.:-[]]");
    }

    syncpss::util::ProcessResult result = run_pass({"pass", "show", name}, store_path_);
    if (result.exit_code != 0) {
        throw std::runtime_error("pass show failed: " + result.stderr_output);
    }
    Entry entry = parse_entry(name, result.stdout_output);
    if (const std::optional<std::string> note_text = decrypt_note_file(note_path_for_entry_name(entry.name, entry.username));
        note_text.has_value()) {
        entry.notes = *note_text;
    }
    return entry;
}

std::string PasswordStore::read_notes(const std::string& name) const {
    if (!validate_entry_name(name)) {
        throw std::runtime_error("Invalid entry name. Allowed: [a-zA-Z0-9/_@.:-[]]");
    }
    return read_entry(name).notes;
}

std::string PasswordStore::serialize_entry(const Entry& entry) const {
    std::ostringstream output;
    output << entry.password << '\n';
    if (!entry.username.empty()) {
        output << "username: " << entry.username << '\n';
    }
    if (!entry.url.empty()) {
        output << "url: " << entry.url << '\n';
    }
    return output.str();
}

void PasswordStore::save_entry(const Entry& entry, bool overwrite) const {
    if (!validate_entry_name(entry.name)) {
        throw std::runtime_error("Invalid entry name. Allowed: [a-zA-Z0-9/_@.:-[]]");
    }
    if (entry.password.empty()) {
        throw std::runtime_error("Password cannot be empty");
    }

    std::vector<std::string> argv = {"pass", "insert", "-m"};
    if (overwrite) {
        argv.push_back("-f");
    }
    argv.push_back(entry.name);

    syncpss::util::ProcessResult result = run_pass(argv, store_path_, serialize_entry(entry));
    if (result.exit_code != 0) {
        throw std::runtime_error("pass insert failed: " + result.stderr_output);
    }

    if (entry.notes.empty()) {
        delete_notes(entry.name, entry.username);
    } else {
        encrypt_note_file(note_path_for_entry_name(entry.name, entry.username), gpg_key_id_, entry.notes);
    }
}

void PasswordStore::delete_entry(const std::string& name) const {
    if (!validate_entry_name(name)) {
        throw std::runtime_error("Invalid entry name. Allowed: [a-zA-Z0-9/_@.:-[]]");
    }

    std::string username;
    try {
        username = read_entry(name).username;
    } catch (const std::exception&) {
    }

    syncpss::util::ProcessResult result = run_pass({"pass", "rm", "-f", name}, store_path_);
    if (result.exit_code != 0) {
        throw std::runtime_error("pass rm failed: " + result.stderr_output);
    }
    delete_notes(name, username);
}

void PasswordStore::delete_tree(const std::string& path) const {
    if (!validate_entry_name(path)) {
        throw std::runtime_error("Invalid entry path. Allowed: [a-zA-Z0-9/_@.:-[]]");
    }

    const std::vector<std::string> existing_entries = list_entries();
    std::vector<Entry> removed_entries;
    for (const std::string& entry_name : existing_entries) {
        if (entry_name == path || entry_name.rfind(path + "/", 0) == 0) {
            try {
                removed_entries.push_back(read_entry(entry_name));
            } catch (const std::exception&) {
                Entry fallback;
                fallback.name = entry_name;
                removed_entries.push_back(std::move(fallback));
            }
        }
    }

    syncpss::util::ProcessResult result = run_pass({"pass", "rm", "-r", "-f", path}, store_path_);
    if (result.exit_code != 0) {
        throw std::runtime_error("pass rm -r failed: " + result.stderr_output);
    }

    for (const Entry& entry : removed_entries) {
        delete_notes(entry.name, entry.username);
    }
}

void PasswordStore::delete_notes(const std::string& name, const std::string& username) const {
    const std::filesystem::path note_path = note_path_for_entry_name(name, username);
    if (std::filesystem::exists(note_path)) {
        std::filesystem::remove(note_path);
    }
}

void PasswordStore::initialize_store() const {
    if (std::filesystem::exists(store_path_ / ".gpg-id")) {
        return;
    }

    syncpss::util::ProcessResult result = run_pass({"pass", "init", gpg_key_id_}, store_path_);
    if (result.exit_code != 0) {
        throw std::runtime_error("pass init failed: " + result.stderr_output);
    }
}

bool PasswordStore::has_legacy_plaintext_notes() const {
    return std::filesystem::exists(legacy_notes_db_path());
}

std::size_t PasswordStore::legacy_plaintext_notes_count() const {
    const json root = load_legacy_notes_db();
    std::size_t count = 0;
    for (auto it = root.begin(); it != root.end(); ++it) {
        if (it.value().is_string() && !it.value().get<std::string>().empty()) {
            ++count;
        }
    }
    return count;
}

std::filesystem::path PasswordStore::migrate_legacy_plaintext_notes() const {
    const std::filesystem::path source = legacy_notes_db_path();
    if (!std::filesystem::exists(source)) {
        return {};
    }

    const json root = load_legacy_notes_db();
    const std::filesystem::path backup =
        syncpss::util::runtime_directory() / ("notes.json.bak." + iso8601_timestamp_for_filename());
    std::filesystem::copy_file(source, backup, std::filesystem::copy_options::overwrite_existing);
    secure_runtime_file(backup);

    for (auto it = root.begin(); it != root.end(); ++it) {
        if (!it.value().is_string()) {
            continue;
        }

        const std::string entry_name = it.key();
        const std::string notes = it.value().get<std::string>();
        if (notes.empty() || !validate_entry_name(entry_name)) {
            continue;
        }

        try {
            Entry entry = read_entry(entry_name);
            if (!entry.notes.empty()) {
                continue;
            }
            entry.notes = notes;
            save_entry(entry, true);
        } catch (const std::exception&) {
            continue;
        }
    }

    std::filesystem::remove(source);
    return backup;
}

std::string PasswordStore::generate_password(std::size_t length) const {
    static const std::string alphabet =
        "ABCDEFGHJKLMNPQRSTUVWXYZ"
        "abcdefghijkmnopqrstuvwxyz"
        "23456789";
    constexpr unsigned int kAlphabetSize = 57U;
    constexpr unsigned int kMaxUnbiasedByte = (256U / kAlphabetSize) * kAlphabetSize;

    std::ifstream random("/dev/urandom", std::ios::binary);
    if (!random) {
        throw std::runtime_error("Cannot open /dev/urandom");
    }

    std::string password;
    password.reserve(length);
    while (password.size() < length) {
        unsigned char byte = 0;
        random.read(reinterpret_cast<char*>(&byte), 1);
        if (!random) {
            throw std::runtime_error("Failed reading /dev/urandom");
        }
        if (static_cast<unsigned int>(byte) >= kMaxUnbiasedByte) {
            continue;
        }
        password.push_back(alphabet[static_cast<std::size_t>(byte) % alphabet.size()]);
    }
    return password;
}

}  // namespace syncpss::store
