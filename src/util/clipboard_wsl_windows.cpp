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
    [ValidateSet('copy','register','clear','watch','cancel')]
    [string]$Mode = 'clear',
    [string]$LeaseId = "",
    [int]$TimeoutSeconds = 30
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

function Initialize-ClipboardHistorySupport {
    if ($script:clipboardHistoryInitialized) {
        return
    }

    $script:clipboardHistoryInitialized = $true
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $script:clipboardType = [Windows.ApplicationModel.DataTransfer.Clipboard, Windows.ApplicationModel.DataTransfer, ContentType=WindowsRuntime]
    } catch {
        $script:clipboardType = $null
    }
}

function Fill-RandomBytes([byte[]]$Buffer) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($Buffer)
    } finally {
        if ($null -ne $rng) {
            $rng.Dispose()
        }
    }
}

function Invoke-WinRtAsync([object]$Operation, [Type]$ResultType) {
    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    if ($null -eq $asTaskMethod) {
        throw "WinRT async bridge is unavailable."
    }

    $genericMethod = $asTaskMethod.MakeGenericMethod($ResultType)
    $task = $genericMethod.Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Get-ClipboardHistoryItemsResult {
    Initialize-ClipboardHistorySupport
    if ($null -eq $script:clipboardType) {
        return $null
    }

    try {
        if (-not $script:clipboardType::IsHistoryEnabled()) {
            return $null
        }

        return Invoke-WinRtAsync `
            -Operation ($script:clipboardType::GetHistoryItemsAsync()) `
            -ResultType ([Windows.ApplicationModel.DataTransfer.ClipboardHistoryItemsResult])
    } catch {
        return $null
    }
}

function Get-ClipboardHistoryItemText([object]$Item) {
    if ($null -eq $Item) {
        return $null
    }

    try {
        return Invoke-WinRtAsync -Operation ($Item.Content.GetTextAsync()) -ResultType ([string])
    } catch {
        return $null
    }
}

function Get-ClipboardHistoryItemId([string]$ExpectedText, [int]$RetryCount = 10, [int]$SleepMilliseconds = 100) {
    if ([string]::IsNullOrEmpty($ExpectedText)) {
        return $null
    }

    $maxAttempts = [Math]::Max($RetryCount, 1)
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        $historyResult = Get-ClipboardHistoryItemsResult
        if ($null -ne $historyResult) {
            foreach ($item in $historyResult.Items) {
                if ((Get-ClipboardHistoryItemText $item) -eq $ExpectedText) {
                    return $item.Id
                }
            }

            if ($historyResult.Items.Count -gt 0 -and $attempt + 1 -eq $maxAttempts) {
                return $historyResult.Items[0].Id
            }
        }

        if ($attempt + 1 -lt $maxAttempts) {
            Start-Sleep -Milliseconds $SleepMilliseconds
        }
    }

    return $null
}

function Get-ClipboardCurrentHistoryItem {
    $historyResult = Get-ClipboardHistoryItemsResult
    if ($null -eq $historyResult -or $historyResult.Items.Count -eq 0) {
        return $null
    }
    return $historyResult.Items[0]
}

function Remove-ClipboardHistoryItemById([string]$ItemId) {
    if ([string]::IsNullOrWhiteSpace($ItemId)) {
        return $false
    }

    $historyResult = Get-ClipboardHistoryItemsResult
    if ($null -eq $historyResult) {
        return $false
    }

    foreach ($item in $historyResult.Items) {
        if ($item.Id -ne $ItemId) {
            continue
        }

        try {
            return $script:clipboardType::DeleteItemFromHistory($item)
        } catch {
            return $false
        }
    }

    return $false
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

function Clear-ClipboardCurrentValue {
    Initialize-ClipboardHistorySupport
    if ($null -ne $script:clipboardType) {
        try {
            $script:clipboardType::Clear()
            return
        } catch {
        }
    }

    Set-Clipboard -Value ""
}

$runtimeDir = Join-Path $HOME '.syncpss'
$leaseDir = Join-Path $runtimeDir 'clipboard-leases'
New-Item -ItemType Directory -Force -Path $leaseDir | Out-Null

if (-not $LeaseId) {
    Clear-ClipboardCurrentValue
    exit 0
}

$leasePath = Join-Path $leaseDir ("lease-" + $LeaseId + ".json")

function Get-LeaseRecord([string]$Path) {
    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        return Get-Content -Raw -Path $Path | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-LeaseMatch([string]$Path) {
    $leaseRecord = Get-LeaseRecord $Path
    if ($null -eq $leaseRecord) {
        return $false
    }

    $salt = [System.Convert]::FromBase64String($leaseRecord.salt)
    if (-not [string]::IsNullOrWhiteSpace($leaseRecord.historyItemId)) {
        $currentItem = Get-ClipboardCurrentHistoryItem
        if ($null -ne $currentItem) {
            if ($currentItem.Id -ne $leaseRecord.historyItemId) {
                return $false
            }

            $currentItemText = Get-ClipboardHistoryItemText $currentItem
            if ($null -ne $currentItemText) {
                $currentItemHash = Get-SaltedHash -Text $currentItemText -Salt $salt
                return $currentItemHash -eq $leaseRecord.hash
            }
        }
    }

    $currentText = Get-ClipboardText
    $currentHash = Get-SaltedHash -Text $currentText -Salt $salt
    return $currentHash -eq $leaseRecord.hash
}

function Remove-Lease([string]$Path) {
    Remove-Item -Force -ErrorAction SilentlyContinue $Path
}

function Clear-LeaseArtifacts([string]$Path, [bool]$ClearCurrentClipboard) {
    $leaseRecord = Get-LeaseRecord $Path
    if ($ClearCurrentClipboard) {
        Clear-ClipboardCurrentValue
    }

    if ($null -ne $leaseRecord -and -not [string]::IsNullOrWhiteSpace($leaseRecord.historyItemId)) {
        Remove-ClipboardHistoryItemById $leaseRecord.historyItemId | Out-Null
    }

    Remove-Lease $Path
}

function Wait-ForLeaseMatch([string]$Path, [int]$RetryCount = 10, [int]$SleepMilliseconds = 100) {
    $maxAttempts = [Math]::Max($RetryCount, 1)
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        if (Test-LeaseMatch $Path) {
            return $true
        }
        if ($attempt + 1 -lt $maxAttempts) {
            Start-Sleep -Milliseconds $SleepMilliseconds
        }
    }
    return $false
}

if ($Mode -eq 'copy') {
    $expected = [Console]::In.ReadToEnd()
    Set-Clipboard -Value $expected
    if ([string]::IsNullOrWhiteSpace($LeaseId)) {
        exit 0
    }
    $salt = New-Object byte[] 32
    Fill-RandomBytes $salt
    $leaseRecord = @{
        salt = [System.Convert]::ToBase64String($salt)
        hash = Get-SaltedHash -Text $expected -Salt $salt
        historyItemId = Get-ClipboardHistoryItemId -ExpectedText $expected
    }
    $leaseRecord | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 -NoNewline -Path $leasePath
    if (Wait-ForLeaseMatch $leasePath) {
        exit 0
    }
    exit 1
}

if ($Mode -eq 'register') {
    $expected = [Console]::In.ReadToEnd()
    $salt = New-Object byte[] 32
    Fill-RandomBytes $salt
    $leaseRecord = @{
        salt = [System.Convert]::ToBase64String($salt)
        hash = Get-SaltedHash -Text $expected -Salt $salt
        historyItemId = Get-ClipboardHistoryItemId -ExpectedText $expected
    }
    $leaseRecord | ConvertTo-Json -Compress | Set-Content -Encoding UTF8 -NoNewline -Path $leasePath
    exit 0
}

if ($Mode -eq 'cancel') {
    Clear-LeaseArtifacts $leasePath $false
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
            Clear-LeaseArtifacts $leasePath $false
            exit 0
        }

        if (Test-PasteGesture) {
            Start-Sleep -Milliseconds 180
            Clear-LeaseArtifacts $leasePath (Test-LeaseMatch $leasePath)
            exit 0
        }

        Start-Sleep -Milliseconds 200
    }

    Clear-LeaseArtifacts $leasePath (Test-LeaseMatch $leasePath)
    exit 0
}

Clear-LeaseArtifacts $leasePath (Test-LeaseMatch $leasePath)
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

bool copy_windows_clipboard_with_lease(std::uint64_t lease_id, const std::string& text) {
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
            "copy",
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
    if (!is_wsl() || !is_command_available("powershell.exe")) {
        return false;
    }

    std::string helper_windows_path;
    if (!ensure_windows_clipboard_helper(helper_windows_path)) {
        return false;
    }

    const std::string delayed_command =
        std::string("& { Start-Sleep -Seconds ") +
        std::to_string(std::max<std::int64_t>(1, delay.count())) +
        "; & '" + powershell_single_quote(helper_windows_path) + "' -Mode clear -LeaseId '" +
        std::to_string(lease_id) + "' }";
    const std::string command =
        "$command = '" + powershell_single_quote(delayed_command) + "'; "
        "Start-Process -WindowStyle Hidden -FilePath 'powershell.exe' -ArgumentList "
        "@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-Command', $command) | Out-Null";

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

bool cancel_windows_clipboard_lease(std::uint64_t lease_id) {
    if (lease_id == 0U || !is_wsl() || !is_command_available("powershell.exe")) {
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
            "cancel",
            "-LeaseId",
            std::to_string(lease_id)
        }
    );

    return result.exit_code == 0;
}

}  // namespace syncpss::util::detail
