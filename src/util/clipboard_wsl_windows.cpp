#include "util/clipboard_internal.hpp"

#include "util/process.hpp"

#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <optional>
#include <sstream>

namespace syncpss::util::detail {
namespace {

std::string powershell_single_quote(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size() + 8U);
    for (const char ch : value) {
        if (ch == '\'') {
            escaped += "''";
        } else {
            escaped.push_back(ch);
        }
    }
    return escaped;
}

bool is_wsl() {
    const char* wsl_distro = std::getenv("WSL_DISTRO_NAME");
    return wsl_distro != nullptr && std::string(wsl_distro).size() > 0U;
}

std::optional<std::string> windows_userprofile() {
    if (!is_wsl() || !is_command_available("cmd.exe")) {
        return std::nullopt;
    }

    static bool initialized = false;
    static std::optional<std::string> cached_path;
    if (initialized) {
        return cached_path;
    }
    initialized = true;

    const ProcessResult result = run({"cmd.exe", "/C", "echo", "%USERPROFILE%"});
    if (result.exit_code != 0) {
        return std::nullopt;
    }

    std::string path = result.stdout_output;
    while (!path.empty() && (path.back() == '\n' || path.back() == '\r' || path.back() == ' ' || path.back() == '\t')) {
        path.pop_back();
    }
    while (!path.empty() && (path.front() == ' ' || path.front() == '\t')) {
        path.erase(path.begin());
    }

    if (path.empty() || path.size() < 3U || path[1] != ':') {
        return std::nullopt;
    }

    cached_path = path;
    return cached_path;
}

std::optional<std::filesystem::path> windows_path_to_wsl(const std::string& windows_path) {
    if (windows_path.size() < 3U || windows_path[1] != ':' || windows_path[2] != '\\') {
        return std::nullopt;
    }

    std::string converted = "/mnt/";
    converted.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(windows_path[0]))));
    converted.push_back('/');
    for (std::size_t index = 3; index < windows_path.size(); ++index) {
        converted.push_back(windows_path[index] == '\\' ? '/' : windows_path[index]);
    }
    return std::filesystem::path(converted);
}

const char* windows_clipboard_helper_script() {
    return R"(param(
    [ValidateSet('register','clear','watch')]
    [string]$Mode = 'clear',
    [string]$LeaseId = "",
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SyncPssClipboardNative {
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);
}
"@

function Get-ClipboardText {
    try {
        return Get-Clipboard -Raw
    } catch {
        try {
            return Get-Clipboard
        } catch {
            return ""
        }
    }
}

function Get-SaltedHash([string]$Text, [byte[]]$Salt) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $textBytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $payload = New-Object byte[] ($Salt.Length + $textBytes.Length)
        [System.Buffer]::BlockCopy($Salt, 0, $payload, 0, $Salt.Length)
        [System.Buffer]::BlockCopy($textBytes, 0, $payload, $Salt.Length, $textBytes.Length)
        return [System.Convert]::ToBase64String($sha.ComputeHash($payload))
    } finally {
        $sha.Dispose()
    }
}

function Test-KeyDown([int]$VirtualKey) {
    return ([SyncPssClipboardNative]::GetAsyncKeyState($VirtualKey) -band 0x8000) -ne 0
}

function Test-PasteGesture {
    return ((Test-KeyDown 0x11) -and (Test-KeyDown 0x56)) -or ((Test-KeyDown 0x10) -and (Test-KeyDown 0x2D))
}

$runtimeDir = Join-Path $HOME '.syncpss'
$leaseDir = Join-Path $runtimeDir 'clipboard-leases'
New-Item -ItemType Directory -Force -Path $leaseDir | Out-Null

if (-not $LeaseId) {
    Set-Clipboard -Value ""
    exit 0
}

$leasePath = Join-Path $leaseDir ("lease-" + $LeaseId + ".json")

function Test-LeaseMatch([string]$Path) {
    if (-not (Test-Path $Path)) {
        return $false
    }
    $leaseRecord = Get-Content -Raw -Path $Path | ConvertFrom-Json
    $salt = [System.Convert]::FromBase64String($leaseRecord.salt)
    $current = Get-ClipboardText
    $currentHash = Get-SaltedHash -Text $current -Salt $salt
    return $currentHash -eq $leaseRecord.hash
}

function Remove-Lease([string]$Path) {
    Remove-Item -Force -ErrorAction SilentlyContinue $Path
}

if ($Mode -eq 'register') {
    $expected = [Console]::In.ReadToEnd()
    $salt = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt)
    $leaseRecord = @{
        salt = [System.Convert]::ToBase64String($salt)
        hash = Get-SaltedHash -Text $expected -Salt $salt
    }
    $leaseRecord | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 -NoNewline -Path $leasePath
    exit 0
}

if ($Mode -eq 'watch') {
    if (-not (Test-Path $leasePath)) {
        exit 0
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds, 1))
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path $leasePath)) {
            exit 0
        }

        if (-not (Test-LeaseMatch $leasePath)) {
            Remove-Lease $leasePath
            exit 0
        }

        if (Test-PasteGesture) {
            Start-Sleep -Milliseconds 180
            if (Test-LeaseMatch $leasePath) {
                Set-Clipboard -Value ""
            }
            Remove-Lease $leasePath
            exit 0
        }

        Start-Sleep -Milliseconds 200
    }

    if (Test-LeaseMatch $leasePath) {
        Set-Clipboard -Value ""
    }
    Remove-Lease $leasePath
    exit 0
}

if (Test-LeaseMatch $leasePath) {
    Set-Clipboard -Value ""
}
Remove-Lease $leasePath
)";
}

bool ensure_windows_clipboard_helper(std::string& helper_windows_path) {
    const std::optional<std::string> userprofile = windows_userprofile();
    if (!userprofile.has_value()) {
        return false;
    }

    const std::string helper_dir_windows = *userprofile + "\\.syncpss";
    const std::string helper_file_windows = helper_dir_windows + "\\clear_syncpss_clipboard.ps1";
    const std::optional<std::filesystem::path> helper_dir_wsl = windows_path_to_wsl(helper_dir_windows);
    const std::optional<std::filesystem::path> helper_file_wsl = windows_path_to_wsl(helper_file_windows);
    if (!helper_dir_wsl.has_value() || !helper_file_wsl.has_value()) {
        return false;
    }

    std::error_code error;
    std::filesystem::create_directories(*helper_dir_wsl, error);
    if (error) {
        return false;
    }

    bool should_write = true;
    if (std::filesystem::exists(*helper_file_wsl)) {
        std::ifstream existing(*helper_file_wsl, std::ios::binary);
        std::stringstream buffer;
        buffer << existing.rdbuf();
        should_write = buffer.str() != windows_clipboard_helper_script();
    }

    if (should_write) {
        std::ofstream output(*helper_file_wsl, std::ios::binary | std::ios::trunc);
        if (!output) {
            return false;
        }
        output << windows_clipboard_helper_script();
        output.flush();
        if (!output.good()) {
            return false;
        }
    }

    helper_windows_path = helper_file_windows;
    return true;
}

}  // namespace

bool register_windows_clipboard_lease(std::uint64_t lease_id, const std::string& text) {
    if (!is_wsl() || !is_command_available("powershell.exe")) {
        return false;
    }

    std::string helper_windows_path;
    if (!ensure_windows_clipboard_helper(helper_windows_path)) {
        return false;
    }

    const ProcessResult result = run(
        {
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            helper_windows_path,
            "-Mode",
            "register",
            "-LeaseId",
            std::to_string(lease_id)
        },
        ProcessOptions{std::nullopt, std::nullopt, text}
    );

    return result.exit_code == 0;
}

bool launch_windows_clipboard_watcher(std::uint64_t lease_id, std::chrono::seconds delay) {
    if (!is_wsl() || !is_command_available("powershell.exe")) {
        return false;
    }

    std::string helper_windows_path;
    if (!ensure_windows_clipboard_helper(helper_windows_path)) {
        return false;
    }

    const std::string command =
        "$args = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','" +
        powershell_single_quote(helper_windows_path) +
        "','-Mode','watch','-LeaseId','" + std::to_string(lease_id) +
        "','-TimeoutSeconds','" + std::to_string(std::max<std::int64_t>(1, delay.count())) +
        "'); Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' -ArgumentList $args | Out-Null";

    const ProcessResult result = run(
        {
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command
        }
    );

    return result.exit_code == 0;
}

bool schedule_windows_clipboard_clear(std::uint64_t lease_id, std::chrono::seconds delay) {
    if (!is_wsl() || !is_command_available("schtasks.exe")) {
        return false;
    }

    static std::atomic<std::uint64_t> g_windows_task_generation{0};

    std::string helper_windows_path;
    if (!ensure_windows_clipboard_helper(helper_windows_path)) {
        return false;
    }

    auto desired_time = std::chrono::system_clock::now() + delay;
    const auto next_minute_boundary =
        std::chrono::time_point_cast<std::chrono::minutes>(desired_time) + std::chrono::minutes(1);
    desired_time = next_minute_boundary;

    std::time_t run_at = std::chrono::system_clock::to_time_t(desired_time);
    std::tm local_tm{};
#if defined(__APPLE__) || defined(__linux__)
    localtime_r(&run_at, &local_tm);
#else
    local_tm = *std::localtime(&run_at);
#endif

    std::ostringstream date_stream;
    date_stream << std::put_time(&local_tm, "%m/%d/%Y");

    std::ostringstream time_stream;
    time_stream << std::put_time(&local_tm, "%H:%M");

    const std::uint64_t task_id =
        lease_id == 0U ? (g_windows_task_generation.fetch_add(1U, std::memory_order_relaxed) + 1U) : lease_id;
    const std::string task_name = "syncpss-clipboard-clear-" + std::to_string(task_id);
    const std::string action =
        "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" +
        helper_windows_path + "\" -Mode clear -LeaseId \"" + std::to_string(lease_id) + "\"";

    const ProcessResult result = run(
        {
            "schtasks.exe",
            "/Create",
            "/F",
            "/SC",
            "ONCE",
            "/TN",
            task_name,
            "/TR",
            action,
            "/ST",
            time_stream.str(),
            "/SD",
            date_stream.str(),
            "/Z"
        }
    );

    return result.exit_code == 0;
}

}  // namespace syncpss::util::detail
