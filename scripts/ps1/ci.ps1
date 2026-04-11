[CmdletBinding()]
param(
    [string]$Distro = "",
    [string]$User = "",
    [ValidateSet("local", "github")]
    [string]$InstallSource = "",
    [switch]$RunNow,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ColorReset = [ConsoleColor]::White
$script:ColorRed = [ConsoleColor]::Red
$script:ColorGreen = [ConsoleColor]::Green
$script:ColorYellow = [ConsoleColor]::Yellow
$script:ColorLightBlue = [ConsoleColor]::Cyan
$script:ColorDarkBlue = [ConsoleColor]::Blue

function Write-Title {
    param([Parameter(Mandatory = $true)][string]$Message)
    $normalized = if ($Message.Length -gt 0) {
        $Message.Substring(0, 1).ToUpperInvariant() + $Message.Substring(1)
    } else {
        $Message
    }
    Write-Host (">> {0}" -f $normalized) -ForegroundColor $script:ColorYellow
}

function Write-Build {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message -ForegroundColor $script:ColorLightBlue
}

function Write-Input {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message -ForegroundColor $script:ColorDarkBlue
}

function Write-Success {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message -ForegroundColor $script:ColorGreen
}

function Write-WarningText {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message -ForegroundColor $script:ColorRed
}

function Write-ErrorText {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message -ForegroundColor $script:ColorRed
}

function Normalize-WslText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return (($Value | Out-String) -replace "`0", "").Trim()
}

function Get-WslDistros {
    $lines = & wsl.exe -l -q 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "WSL is required to run ci.bat."
    }

    $distros = @()
    foreach ($line in $lines) {
        $name = Normalize-WslText -Value $line
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        if ($name -in @("docker-desktop", "docker-desktop-data")) {
            continue
        }
        $distros += $name
    }
    return $distros
}

function Get-DefaultWslDistro {
    $lines = & wsl.exe -l -v 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    foreach ($line in $lines) {
        $text = Normalize-WslText -Value $line
        if ($text.StartsWith("*")) {
            return $text.TrimStart("*").Trim() -replace '\s{2,}.*$',''
        }
    }
    return $null
}

function Select-WslDistro {
    param([string]$RequestedDistro)

    $distros = @(Get-WslDistros)
    if ($distros.Count -eq 0) {
        throw "No usable WSL distros were found."
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedDistro)) {
        if ($distros -notcontains $RequestedDistro) {
            throw "WSL distro '$RequestedDistro' was not found."
        }
        return $RequestedDistro
    }

    if ($distros.Count -eq 1) {
        return $distros[0]
    }

    $preferred = Get-DefaultWslDistro
    if ($null -ne $preferred -and $distros -contains $preferred) {
        return $preferred
    }

    Write-Host "Available WSL distros:"
    for ($i = 0; $i -lt $distros.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $distros[$i])
    }
    $selection = Read-Host "Select distro [1]"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        $selection = "1"
    }
    if ($selection -notmatch '^\d+$') {
        throw "Invalid distro selection."
    }
    $index = [int]$selection - 1
    if ($index -lt 0 -or $index -ge $distros.Count) {
        throw "Distro selection out of range."
    }
    return $distros[$index]
}

function Get-WslHomeUsers {
    param([Parameter(Mandatory = $true)][string]$DistroName)

    $homeRoot = "\\wsl.localhost\$DistroName\home"
    if (-not (Test-Path -LiteralPath $homeRoot)) {
        throw "Could not access $homeRoot from Windows."
    }

    return @(
        Get-ChildItem -LiteralPath $homeRoot -Directory |
            Select-Object -ExpandProperty Name |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Select-WslUser {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [string]$RequestedUser
    )

    $users = @(Get-WslHomeUsers -DistroName $DistroName)
    if ($users.Count -eq 0) {
        throw "No Linux users were found under \\wsl.localhost\$DistroName\home."
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedUser)) {
        if ($users -notcontains $RequestedUser) {
            throw "Linux user '$RequestedUser' was not found in distro '$DistroName'."
        }
        return $RequestedUser
    }

    if ($users.Count -eq 1) {
        return $users[0]
    }

    Write-Host "Available Linux users in ${DistroName}:"
    for ($i = 0; $i -lt $users.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $users[$i])
    }
    $selection = Read-Host "Select user [1]"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        $selection = "1"
    }
    if ($selection -notmatch '^\d+$') {
        throw "Invalid user selection."
    }
    $index = [int]$selection - 1
    if ($index -lt 0 -or $index -ge $users.Count) {
        throw "User selection out of range."
    }
    return $users[$index]
}

function Invoke-WslProcessInteractive {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )

    $fullArgumentList = @("-d", $DistroName, "-u", $LinuxUser, "--")
    $fullArgumentList += $ArgumentList

    & wsl.exe @fullArgumentList | Out-Host
    return [int]$LASTEXITCODE
}

function Invoke-WindowsInstallerStaging {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $installerExe = Join-Path $RepoRoot "bin\syncpss-wsl-installer.exe"
    if (-not (Test-Path -LiteralPath $installerExe)) {
        throw "Missing build artifact: $installerExe"
    }

    & $installerExe @(
        "--distro", $DistroName,
        "--user", $LinuxUser,
        "--no-open-shell",
        "--no-pause"
    ) | Out-Host
    return [int]$LASTEXITCODE
}

function Start-WslSyncpassWindow {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $command = "cd ~/.syncpss/helpers && export PATH=`$HOME/.local/bin:/usr/local/bin:`$PATH; syncpass; exec bash"
    Start-Process -FilePath "wsl.exe" -ArgumentList @(
        "-d", $DistroName,
        "-u", $LinuxUser,
        "--",
        "bash",
        "-lc",
        $command
    ) | Out-Null
}

function Start-WslInstallerWindow {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser,
        [Parameter(Mandatory = $true)][string]$InstallSource
    )

    $command = "cd ~/.syncpss/helpers && export PATH=`$HOME/.local/bin:/usr/local/bin:`$PATH; export TERM=`${TERM:-xterm-256color}; chmod u+x ~/.syncpss/helpers/installer.sh ~/.syncpss/helpers/uninstall_syncpss.sh 2>/dev/null || true; clear 2>/dev/null || true; printf '\nStarting syncpss installer inside WSL...\n\n'; SYNCPSS_FORCE_INSTALL=1 SYNCPSS_AUTO_ADVANCE_DEFAULTS=1 SYNCPSS_INSTALL_SOURCE=${InstallSource} bash ~/.syncpss/helpers/installer.sh; printf '\nThe syncpss installer window is staying open for review.\n'; exec bash"
    Start-Process -FilePath "wsl.exe" -ArgumentList @(
        "-d", $DistroName,
        "-u", $LinuxUser,
        "--",
        "bash",
        "-lc",
        $command
    ) | Out-Null
}

function Invoke-BatchScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $argumentList = @("/c", $ScriptPath)
    if ($Arguments.Count -gt 0) {
        $argumentList += $Arguments
    }

    & cmd.exe @argumentList | Out-Host
    return [int]$LASTEXITCODE
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-LocalReleaseMasterFingerprint {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $assetFiles = @(
        "bin\syncpss-linux-x86_64",
        "bin\install",
        "bin\installer.sh",
        "bin\uninstall_syncpss.sh"
    ) | ForEach-Object { Join-Path $RepoRoot $_ }

    $buffer = New-Object System.IO.MemoryStream
    try {
        foreach ($absolutePath in $assetFiles) {
            if (-not (Test-Path -LiteralPath $absolutePath)) {
                throw "Missing local CI asset required for staged fingerprint verification: $absolutePath"
            }
            $bytes = [System.IO.File]::ReadAllBytes($absolutePath)
            $buffer.Write($bytes, 0, $bytes.Length)
        }
        $buffer.Position = 0

        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha.ComputeHash($buffer)
            return ([BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $buffer.Dispose()
    }
}

function Start-SyncpssFromStartMenu {
    $shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\syncpss.lnk"
    if (-not (Test-Path -LiteralPath $shortcutPath)) {
        throw "Start Menu shortcut not found: $shortcutPath"
    }

    Start-Process -FilePath $shortcutPath | Out-Null
}

function Select-PostInstallLaunchMode {
    if ($NonInteractive) {
        return "wsl"
    }

    Write-Host ""
    Write-Title "Choose how to launch syncpss for this CI test"
    Write-Input "  [1] Run syncpss directly in a fresh WSL window (default)"
    Write-Input "  [2] Run the Windows Start Menu shortcut"
    Write-Input "  [3] Skip launch"

    while ($true) {
        Write-Input "Select launch mode [1]"
        $selection = Read-Host
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq "1") {
            return "wsl"
        }
        if ($selection -eq "2") {
            return "start-menu"
        }
        if ($selection -eq "3") {
            return "skip"
        }
    }
}

function Select-InstallSource {
    param([string]$RequestedSource)

    if (-not [string]::IsNullOrWhiteSpace($RequestedSource)) {
        return $RequestedSource.ToLowerInvariant()
    }

    if ($NonInteractive) {
        return "local"
    }

    Write-Host ""
    Write-Title "Choose installer source for this CI run"
    Write-Input "  [1] Local Windows-built binaries (default)"
    Write-Input "  [2] GitHub release channel"

    while ($true) {
        Write-Input "Select source [1]"
        $selection = Read-Host
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq "1") {
            return "local"
        }
        if ($selection -eq "2") {
            return "github"
        }
    }
}

function Maybe-OfferDeployment {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    if ($NonInteractive) {
        return
    }

    Write-Host ""
    Write-Input "Run cd.bat next for deployment? [y/N]"
    $answer = Read-Host
    if ($answer -notmatch '^(?i:y|yes)$') {
        return
    }

    $cdScript = Join-Path $RepoRoot "scripts\cd.bat"
    if (-not (Test-Path -LiteralPath $cdScript)) {
        throw "Deployment entrypoint not found: $cdScript"
    }

    Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", $cdScript) | Out-Null
}

function Invoke-CiPipeline {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    Set-Location -LiteralPath $repoRoot

    Write-Build "[1/3] Building fresh local artifacts..."
    $buildScript = Join-Path $repoRoot "scripts\build.bat"
    $buildExit = Invoke-BatchScript -ScriptPath $buildScript -Arguments @("--no-pause")
    if ($buildExit -ne 0) {
        throw "Build failed with exit code $buildExit"
    }

    $selectedDistro = Select-WslDistro -RequestedDistro $Distro
    $selectedUser = Select-WslUser -DistroName $selectedDistro -RequestedUser $User
    $selectedInstallSource = Select-InstallSource -RequestedSource $InstallSource
    $linuxHome = "/home/$selectedUser"
    $linuxStageDir = "$linuxHome/.syncpss/helpers"

    if ($selectedInstallSource -eq "local") {
        $requiredLocalAssets = @(
            (Join-Path $repoRoot "bin\syncpss-linux-x86_64"),
            (Join-Path $repoRoot "bin\syncpss-linux-x86_64.sha256"),
            (Join-Path $repoRoot "bin\install"),
            (Join-Path $repoRoot "bin\install.sha256"),
            (Join-Path $repoRoot "bin\installer.sh"),
            (Join-Path $repoRoot "bin\installer.sh.sha256"),
            (Join-Path $repoRoot "bin\uninstall_syncpss.sh"),
            (Join-Path $repoRoot "bin\uninstall_syncpss.sh.sha256"),
            (Join-Path $repoRoot "bin\manifest.xml"),
            (Join-Path $repoRoot "bin\manifest.xml.sha256"),
            (Join-Path $repoRoot "bin\master_fingerprint.sha256")
        )
        $missingLocalAssets = @($requiredLocalAssets | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missingLocalAssets.Count -gt 0) {
            throw ("Local CI install source was selected, but required staged assets are missing:`n" +
                (($missingLocalAssets | ForEach-Object { " - $_" }) -join "`n"))
        }

        $recordedFingerprint = ((Get-Content -LiteralPath (Join-Path $repoRoot "bin\master_fingerprint.sha256") |
            Select-Object -First 1).Split() | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($recordedFingerprint)) {
            throw "Local CI install source was selected, but bin\master_fingerprint.sha256 is empty."
        }

        $actualFingerprint = Get-LocalReleaseMasterFingerprint -RepoRoot $repoRoot
        if ($recordedFingerprint -ne $actualFingerprint) {
            throw ("Local CI install source fingerprint mismatch. " +
                "Recorded=$recordedFingerprint Actual=$actualFingerprint")
        }
    }

    $purgeArguments = @("--distro", $selectedDistro, "--user", $selectedUser, "--no-batch-pause")
    if ($RunNow -or $NonInteractive) {
        Write-Build "[2/3] Running the real purge flow non-interactively..."
        $purgeArguments += @("--run-now", "--assume-yes", "--no-pause")
    } else {
        Write-Build "[2/3] Running the real purge flow so you can choose what to remove..."
    }
    $purgeScript = Join-Path $repoRoot "scripts\purge.bat"
    $purgeExit = Invoke-BatchScript `
        -ScriptPath $purgeScript `
        -Arguments $purgeArguments

    if ($purgeExit -ne 0) {
        throw "Purge helper exited with code $purgeExit"
    }

    Write-Build "[3/3] Running the Windows WSL installer and staging rebuilt artifacts into ~/.syncpss/helpers..."
    $stageExit = Invoke-WindowsInstallerStaging -RepoRoot $repoRoot -DistroName $selectedDistro -LinuxUser $selectedUser
    if ($stageExit -ne 0) {
        throw "Windows WSL installer exited with code $stageExit"
    }

    $stageDir = "\\wsl.localhost\$selectedDistro\home\$selectedUser\.syncpss\helpers"
    Write-Success "Staged fresh assets in $stageDir"
    Write-Title ("Installer test source: {0}" -f $selectedInstallSource)

    $shouldRun = $RunNow
    if (-not $NonInteractive -and -not $RunNow) {
        Write-Input "Run bash ~/.syncpss/helpers/installer.sh now? [Y/n]"
        $answer = Read-Host
        $shouldRun = [string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(?i:y|yes)$'
    }

    if ($shouldRun) {
        Write-Title "Opening the Linux installer in a separate WSL window."
        Start-WslInstallerWindow `
            -DistroName $selectedDistro `
            -LinuxUser $selectedUser `
            -InstallSource $selectedInstallSource

        if (-not $NonInteractive) {
            Write-Input "Return here after the WSL installer window finishes, then press Enter to continue."
            [void](Read-Host)
        }

        $launchMode = Select-PostInstallLaunchMode
        switch ($launchMode) {
            "wsl" {
                Start-WslSyncpassWindow -DistroName $selectedDistro -LinuxUser $selectedUser
            }
            "start-menu" {
                Start-SyncpssFromStartMenu
            }
            default {
            }
        }
    } else {
        Write-Title "Opening a WSL window and starting installer.sh automatically instead of leaving a manual step."
        Start-WslInstallerWindow `
            -DistroName $selectedDistro `
            -LinuxUser $selectedUser `
            -InstallSource $selectedInstallSource
    }

    Maybe-OfferDeployment -RepoRoot $repoRoot
}

try {
    Invoke-CiPipeline
    exit 0
} catch {
    Write-ErrorText $_.Exception.Message
    exit 1
}
