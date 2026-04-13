#pragma once

#include <windows.h>
#include <shellapi.h>
#include <urlmon.h>
#include <conio.h>

#include <algorithm>
#include <cctype>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

inline constexpr wchar_t kRepoOwner[] = L"KffeePt";
inline constexpr wchar_t kRepoName[] = L"syncpss";
inline constexpr wchar_t kHelperScript[] = L"installer.sh";
inline constexpr wchar_t kHelperScriptChecksum[] = L"installer.sh.sha256";
inline constexpr wchar_t kManagedPathsScript[] = L"managed_paths.sh";
inline constexpr wchar_t kManagedPathsScriptChecksum[] = L"managed_paths.sh.sha256";
inline constexpr wchar_t kMaintainerHelperScript[] = L"maintainer_id.sh";
inline constexpr wchar_t kInstallBinary[] = L"install";
inline constexpr wchar_t kInstallChecksum[] = L"install.sha256";
inline constexpr wchar_t kSyncpssBinary[] = L"syncpss-linux-x86_64";
inline constexpr wchar_t kSyncpssChecksum[] = L"syncpss-linux-x86_64.sha256";
inline constexpr wchar_t kManifestAsset[] = L"manifest.xml";
inline constexpr wchar_t kManifestChecksum[] = L"manifest.xml.sha256";
inline constexpr wchar_t kMasterFingerprint[] = L"master_fingerprint.sha256";
inline constexpr wchar_t kShortcutName[] = L"syncpss.lnk";
inline constexpr wchar_t kWindowsAppDirName[] = L"syncpss";
inline constexpr wchar_t kWindowsRuntimeDirName[] = L".syncpss";
inline constexpr wchar_t kWslInstallerWindowScript[] = L"run_installer_window.sh";
inline constexpr wchar_t kIconPngName[] = L"syncpss-icon.png";
inline constexpr wchar_t kIconIcoName[] = L"syncpss-icon.ico";
inline constexpr wchar_t kIconSvgName[] = L"syncpss-icon.svg";
inline constexpr wchar_t kClipboardHelperScriptName[] = L"clear_syncpss_clipboard.ps1";
inline constexpr wchar_t kLaunchScriptName[] = L"launch_syncpss.cmd";
inline constexpr wchar_t kLaunchPowerShellScriptName[] = L"launch_syncpss.ps1";
inline constexpr wchar_t kPurgePowerShellScriptName[] = L"purge.ps1";
inline constexpr wchar_t kWslRuntimeDirName[] = L".syncpss";
inline constexpr wchar_t kWslHelpersDirName[] = L"helpers";
inline constexpr wchar_t kWslConfigDirName[] = L"config";

inline constexpr const char* kReset = "\033[0m";
inline constexpr const char* kRed = "\033[31m";
inline constexpr const char* kGreen = "\033[32m";
inline constexpr const char* kYellow = "\033[33m";
inline constexpr const char* kCyan = "\033[36m";

struct ProcessResult {
    DWORD exit_code = 1;
    std::string output;
};

struct UserEntry {
    std::wstring username;
    std::filesystem::path home_path;
};

enum class InstallSource {
    release,
    local
};

struct InstallerOptions {
    std::optional<std::wstring> distro;
    std::optional<std::wstring> user;
    InstallSource install_source = InstallSource::release;
    bool open_shell = true;
    bool pause_on_exit = true;
};

struct PreparedInstallerAssets {
    InstallSource install_source = InstallSource::release;
    std::filesystem::path root_dir;
    std::filesystem::path helper_script;
};

void enable_ansi();
void log_line(const std::string& message, const char* color = kReset);
void print_header();
[[noreturn]] void pause_and_exit(int code);
[[noreturn]] void exit_without_pause(int code);
bool prompt_yes_no(const std::wstring& message, bool default_yes = true);
void prompt_press_enter(const std::wstring& message);

std::wstring to_wide(const std::string& input);
std::string to_utf8(const std::wstring& input);
std::wstring trim(const std::wstring& value);
std::string trim_ascii(const std::string& value);
std::string strip_nuls(const std::string& value);
bool contains_control_chars(const std::wstring& value);
void validate_wsl_distro_name_or_throw(const std::wstring& value);
void validate_linux_username_or_throw(const std::wstring& value);
std::wstring quote_arg(const std::wstring& arg);
ProcessResult run_process(const std::vector<std::wstring>& argv);
int run_process_interactive(const std::vector<std::wstring>& argv);
void launch_process_new_console(const std::vector<std::wstring>& argv);
std::string last_error_message(DWORD error);

bool host_command_available(const std::wstring& command);
bool host_package_manager_available();
void ensure_host_prerequisites();
bool is_running_as_admin();
std::wstring current_exe_path();
std::filesystem::path appdata_path(const wchar_t* variable_name);
std::filesystem::path userprofile_path();
std::filesystem::path local_syncpss_app_dir();
std::filesystem::path windows_runtime_dir();
std::filesystem::path start_menu_programs_dir();
std::wstring ps_single_quote(const std::wstring& value);

InstallerOptions parse_options();
std::vector<std::wstring> list_distros();
std::vector<std::wstring> list_online_distros();
std::optional<std::wstring> default_distro();
std::wstring select_distro_tui(const std::vector<std::wstring>& distros);
std::wstring select_online_distro_tui(const std::vector<std::wstring>& distros);
std::vector<std::wstring> ensure_distros_ready(const InstallerOptions& options);
std::filesystem::path distro_home_root(const std::wstring& distro);
std::vector<UserEntry> list_users_in_distro(const std::wstring& distro);
void ensure_distro_users_ready(const std::wstring& distro);
std::optional<UserEntry> select_user_tui(const std::vector<UserEntry>& users);

std::filesystem::path exe_dir();
std::filesystem::path process_temp_dir();
std::string normalize_lf_text(const std::string& input);
void copy_text_file_with_lf(const std::filesystem::path& source, const std::filesystem::path& destination);
std::wstring release_asset_url(const std::wstring& asset_name);
std::string normalize_sha256(const std::string& input);
std::string checksum_from_sha256_file(const std::filesystem::path& checksum_path);
std::string sha256_for_file(const std::filesystem::path& file_path);
void verify_release_asset_checksum(const std::filesystem::path& asset_path, const std::filesystem::path& checksum_path);
std::filesystem::path download_release_asset(const std::wstring& asset_name);
std::filesystem::path download_helper_script();
PreparedInstallerAssets prepare_installer_assets(InstallSource install_source);
std::string install_source_name(InstallSource install_source);
std::wstring install_source_cli_flag(InstallSource install_source);
void copy_optional_windows_assets(const std::filesystem::path& app_dir);

std::filesystem::path shortcut_icon_path(const std::filesystem::path& app_dir);
void ensure_windows_runtime_support();
void create_start_menu_shortcut(const std::wstring& distro, const UserEntry& user);

std::filesystem::path wsl_stage_dir(const UserEntry& user);
void copy_helper_to_wsl_home(const UserEntry& user, const PreparedInstallerAssets& assets);
void open_wsl_installer_window(const std::wstring& distro, const UserEntry& user, InstallSource install_source);
void maybe_open_wsl_shell(const std::wstring& distro, const UserEntry& user);
