#include "common.hpp"

std::filesystem::path shortcut_icon_path(const std::filesystem::path& app_dir) {
    const std::filesystem::path custom_ico = app_dir / kIconIcoName;
    if (std::filesystem::exists(custom_ico)) {
        return custom_ico;
    }
    return current_exe_path();
}

namespace {

const char* clipboard_helper_script_contents() {
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

const char* launch_syncpss_script_contents() {
    return R"(@echo off
setlocal EnableExtensions
title syncpss

set "DISTRO=%~1"
set "LINUX_USER=%~2"

if "%DISTRO%"=="" (
    echo syncpss launcher error: missing WSL distro argument.
    echo.
    pause
    exit /b 1
)

if "%LINUX_USER%"=="" (
    echo syncpss launcher error: missing WSL user argument.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_syncpss.ps1" -Distro "%DISTRO%" -User "%LINUX_USER%"
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" (
    echo syncpss launcher failed with exit code %CODE%.
    echo This window will stay open so you can inspect any errors.
    echo.
    pause
    exit /b %CODE%
)

echo syncpss launcher started.
echo This window will close automatically in 10 seconds.
echo.
timeout /t 10 /nobreak >nul
exit /b %CODE%
)";
}

const char* launch_syncpss_powershell_contents() {
    return R"SYNCPSSPW(param(
    [Parameter(Mandatory = $true)][string]$Distro,
    [Parameter(Mandatory = $true)][string]$User
)

$ErrorActionPreference = 'Stop'

function Normalize-WslText([object]$Value) {
    if ($null -eq $Value) {
        return ""
    }
    return (($Value | Out-String) -replace "`0", "").Trim()
}

function Get-AvailableDistros {
    $lines = & wsl.exe -l -q 2>$null
    $distros = @()
    foreach ($line in $lines) {
        $name = Normalize-WslText $line
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        if ($name -in @('docker-desktop', 'docker-desktop-data')) {
            continue
        }
        $distros += $name
    }
    return $distros
}

function Get-DefaultDistro {
    $lines = & wsl.exe -l -v 2>$null
    foreach ($line in $lines) {
        $text = Normalize-WslText $line
        if ($text.StartsWith('*')) {
            return ($text.TrimStart('*').Trim() -replace '\s{2,}.*$','')
        }
    }
    return $null
}

function Resolve-Distro([string]$RequestedDistro) {
    $distros = @(Get-AvailableDistros)
    if ($distros.Count -eq 0) {
        throw "No usable WSL distros were found."
    }
    if ($distros -contains $RequestedDistro) {
        return $RequestedDistro
    }

    $defaultDistro = Get-DefaultDistro
    if (-not [string]::IsNullOrWhiteSpace($defaultDistro) -and $distros -contains $defaultDistro) {
        Write-Host ("Requested distro '{0}' was not found. Falling back to default distro '{1}'." -f $RequestedDistro, $defaultDistro) -ForegroundColor Yellow
        return $defaultDistro
    }

    Write-Host ("Requested distro '{0}' was not found. Falling back to '{1}'." -f $RequestedDistro, $distros[0]) -ForegroundColor Yellow
    return $distros[0]
}

try {
    $Host.UI.RawUI.WindowTitle = 'syncpss'
} catch {
}

$resolvedDistro = Resolve-Distro $Distro
$command = @'
mkdir -p "$HOME/.syncpss/logs"
chmod 700 "$HOME/.syncpss/logs" 2>/dev/null || true
SYNC_LOG="$HOME/.syncpss/logs/syncpss.log"
: >> "$SYNC_LOG"
chmod 600 "$SYNC_LOG" 2>/dev/null || true
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
export TERM="${TERM:-xterm-256color}"
clear 2>/dev/null || true

run_syncpss() {
    local target="$1"
    local label="$2"

    if command -v script >/dev/null 2>&1; then
        if script -qefac "$target" "$SYNC_LOG"; then
            return 0
        fi
        printf '[%s] util-linux script(1) failed while launching %s. Falling back to direct launch.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" >> "$SYNC_LOG"
    else
        printf '[%s] Starting %s without util-linux script(1). Output capture is limited.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" >> "$SYNC_LOG"
    fi

    "$target"
}

if command -v syncpss >/dev/null 2>&1; then
    run_syncpss syncpss syncpss
elif [ -x /usr/local/bin/syncpss ]; then
    run_syncpss /usr/local/bin/syncpss /usr/local/bin/syncpss
else
    echo 'syncpss is not installed yet. Run bash ~/.syncpss/helpers/installer.sh first.'
fi

exec bash
'@

Start-Process -FilePath 'wsl.exe' -ArgumentList @(
    '-d', $resolvedDistro,
    '-u', $User,
    '--',
    'bash',
    '-lc',
    $command
) | Out-Null

exit 0
)SYNCPSSPW";
}

const char* purge_syncpss_powershell_contents() {
    return R"(param(
    [ValidateSet('start-menu-shortcut','local-app-assets')]
    [string]$Mode = 'start-menu-shortcut'
)

$ErrorActionPreference = 'Stop'

function Remove-ManagedPath([string]$LiteralPath) {
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        throw "Managed cleanup target is empty."
    }

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return
    }

    Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop
}

switch ($Mode) {
    'start-menu-shortcut' {
        $targetPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\syncpss.lnk'
    }
    'local-app-assets' {
        $targetPath = Join-Path $env:LOCALAPPDATA 'syncpss'
    }
    default {
        throw "Unsupported purge mode: $Mode"
    }
}

Remove-ManagedPath $targetPath
)";
}

}  // namespace

void ensure_windows_runtime_support() {
    const std::filesystem::path runtime_dir = windows_runtime_dir();
    std::filesystem::create_directories(runtime_dir);

    const std::filesystem::path helper_path = runtime_dir / kClipboardHelperScriptName;
    const std::filesystem::path purge_powershell_path = runtime_dir / kPurgePowerShellScriptName;
    bool should_write = true;
    if (std::filesystem::exists(helper_path)) {
        std::ifstream existing(helper_path, std::ios::binary);
        std::stringstream buffer;
        buffer << existing.rdbuf();
        should_write = buffer.str() != clipboard_helper_script_contents();
    }

    if (should_write) {
        std::ofstream output(helper_path, std::ios::binary | std::ios::trunc);
        if (!output) {
            throw std::runtime_error("Failed to write Windows clipboard helper script");
        }
        output << clipboard_helper_script_contents();
        output.flush();
        if (!output.good()) {
            throw std::runtime_error("Failed to flush Windows clipboard helper script");
        }
    }

    bool should_write_purge_powershell = true;
    if (std::filesystem::exists(purge_powershell_path)) {
        std::ifstream existing(purge_powershell_path, std::ios::binary);
        std::stringstream buffer;
        buffer << existing.rdbuf();
        should_write_purge_powershell = buffer.str() != purge_syncpss_powershell_contents();
    }

    if (should_write_purge_powershell) {
        std::ofstream output(purge_powershell_path, std::ios::binary | std::ios::trunc);
        if (!output) {
            throw std::runtime_error("Failed to write Windows syncpss purge helper script");
        }
        output << purge_syncpss_powershell_contents();
        output.flush();
        if (!output.good()) {
            throw std::runtime_error("Failed to flush Windows syncpss purge helper script");
        }
    }

    const std::filesystem::path launch_script_path = runtime_dir / kLaunchScriptName;
    const std::filesystem::path launch_powershell_path = runtime_dir / kLaunchPowerShellScriptName;
    bool should_write_launch_script = true;
    if (std::filesystem::exists(launch_script_path)) {
        std::ifstream existing(launch_script_path, std::ios::binary);
        std::stringstream buffer;
        buffer << existing.rdbuf();
        should_write_launch_script = buffer.str() != launch_syncpss_script_contents();
    }

    if (should_write_launch_script) {
        std::ofstream output(launch_script_path, std::ios::binary | std::ios::trunc);
        if (!output) {
            throw std::runtime_error("Failed to write Windows syncpss launcher script");
        }
        output << launch_syncpss_script_contents();
        output.flush();
        if (!output.good()) {
            throw std::runtime_error("Failed to flush Windows syncpss launcher script");
        }
    }

    bool should_write_launch_powershell = true;
    if (std::filesystem::exists(launch_powershell_path)) {
        std::ifstream existing(launch_powershell_path, std::ios::binary);
        std::stringstream buffer;
        buffer << existing.rdbuf();
        should_write_launch_powershell = buffer.str() != launch_syncpss_powershell_contents();
    }

    if (should_write_launch_powershell) {
        std::ofstream output(launch_powershell_path, std::ios::binary | std::ios::trunc);
        if (!output) {
            throw std::runtime_error("Failed to write Windows syncpss PowerShell launcher script");
        }
        output << launch_syncpss_powershell_contents();
        output.flush();
        if (!output.good()) {
            throw std::runtime_error("Failed to flush Windows syncpss PowerShell launcher script");
        }
    }

    log_line("Prepared Windows runtime helper at " + to_utf8(helper_path.wstring()), kGreen);
}

void create_start_menu_shortcut(const std::wstring& distro, const UserEntry& user) {
    const std::filesystem::path app_dir = local_syncpss_app_dir();
    copy_optional_windows_assets(app_dir);
    const std::filesystem::path shortcut_path = start_menu_programs_dir() / kShortcutName;
    const std::filesystem::path icon_path = shortcut_icon_path(app_dir);
    const std::filesystem::path launch_script_path = windows_runtime_dir() / kLaunchScriptName;
    const std::wstring launcher_arguments = L"\"" + distro + L"\" \"" + user.username + L"\"";

    std::ofstream note(app_dir / L"icon-readme.txt", std::ios::binary | std::ios::trunc);
    if (note) {
        note << "syncpss Start Menu launcher assets\n\n";
        note << "Windows shortcuts use .ico files for icons.\n";
        note << "Default icon: syncpss-wsl-installer.exe\n";
        note << "Canonical source art: assets/icon.svg -> syncpss-icon.svg\n";
        note << "Generated preview: syncpss-icon.png\n";
        note << "Preferred custom icon: syncpss-icon.ico\n";
    }

    const std::wstring powershell_script =
        L"$WshShell = New-Object -ComObject WScript.Shell; "
        L"$Shortcut = $WshShell.CreateShortcut('" + ps_single_quote(shortcut_path.wstring()) + L"'); "
        L"$Shortcut.TargetPath = '" + ps_single_quote(launch_script_path.wstring()) + L"'; "
        L"$Shortcut.Arguments = '" + ps_single_quote(launcher_arguments) + L"'; "
        L"$Shortcut.WorkingDirectory = '" + ps_single_quote(windows_runtime_dir().wstring()) + L"'; "
        L"$Shortcut.IconLocation = '" + ps_single_quote(icon_path.wstring()) + L",0'; "
        L"$Shortcut.Description = 'Launch syncpss inside WSL'; "
        L"$Shortcut.Save()";

    const ProcessResult result = run_process({
        L"powershell.exe", L"-NoLogo", L"-NoProfile", L"-ExecutionPolicy", L"Bypass", L"-Command", powershell_script
    });
    if (result.exit_code != 0) {
        throw std::runtime_error("Failed to create Start Menu shortcut: " + result.output);
    }

    log_line("Created Start Menu shortcut at " + to_utf8(shortcut_path.wstring()), kGreen);
}
