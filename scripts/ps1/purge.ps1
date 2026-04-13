[CmdletBinding()]
param(
    [string]$Distro = "",
    [string]$User = "",
    [switch]$RunNow,
    [switch]$PurgeWindowsShortcut,
    [switch]$AssumeYes,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
        throw "WSL is required to purge syncpss from Windows."
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

function Copy-TextFileWithLf {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $content = [System.IO.File]::ReadAllText($SourcePath)
    $normalized = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($DestinationPath, $normalized, $encoding)
}

function Resolve-PurgeHelperSource {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $candidates = @(
        (Join-Path $RepoRoot "scripts\sh\$RelativePath"),
        (Join-Path $RepoRoot "bin\$RelativePath")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Could not find $RelativePath in the repo checkout or bin directory."
}

function Copy-PurgeHelpersToWslHome {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $stageDir = "\\wsl.localhost\$DistroName\home\$LinuxUser\.syncpss\helpers"
    if (-not (Test-Path -LiteralPath $stageDir)) {
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    }

    $copiedTargets = @()
    foreach ($relativePath in @("uninstall_syncpss.sh", "managed_paths.sh")) {
        $source = Resolve-PurgeHelperSource -RepoRoot $RepoRoot -RelativePath $relativePath
        $target = Join-Path $stageDir $relativePath
        Copy-TextFileWithLf -SourcePath $source -DestinationPath $target
        $copiedTargets += $target
    }

    return $copiedTargets
}

function Get-WindowsShortcutMarkerPath {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    return "\\wsl.localhost\$DistroName\home\$LinuxUser\.syncpss-purge-windows-shortcut"
}

function Remove-WindowsStartMenuIntegrationIfRequested {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $markerPath = Get-WindowsShortcutMarkerPath -DistroName $DistroName -LinuxUser $LinuxUser
    if (-not (Test-Path -LiteralPath $markerPath)) {
        return
    }

    $cleanupComplete = Remove-WindowsStartMenuIntegration
    if ($cleanupComplete) {
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        Write-Host "Removed Windows Start Menu shortcut and local syncpss launcher assets." -ForegroundColor Green
        return
    }

    Write-Host "Windows launcher cleanup is incomplete. Leaving a retry marker in WSL for a later purge run." -ForegroundColor Yellow
}

function Open-WslShellAtHome {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $cmdLine = 'wsl.exe -d "{0}" -u "{1}" -- bash -lc "cd ~/.syncpss/helpers; export PATH=`$HOME/.local/bin:/usr/local/bin:`$PATH; export TERM=`${TERM:-xterm-256color}; chmod u+x ~/.syncpss/helpers/installer.sh ~/.syncpss/helpers/uninstall_syncpss.sh 2>/dev/null || true; clear 2>/dev/null || true; printf ''\nStarting syncpss installer inside WSL...\n\n''; SYNCPSS_AUTO_ADVANCE_DEFAULTS=1 bash ~/.syncpss/helpers/installer.sh; printf ''\nThe syncpss installer window is staying open for review.\n''; exec bash"' -f $DistroName, $LinuxUser
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", $cmdLine) | Out-Null
}

function Invoke-WslUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser,
        [string[]]$ExtraArguments = @()
    )

    $argumentText = ""
    if ($ExtraArguments.Count -gt 0) {
        $argumentText = " " + (($ExtraArguments | ForEach-Object { "'$_'" }) -join " ")
    }

    $process = Start-Process `
        -FilePath "wsl.exe" `
        -ArgumentList @(
            "-d", $DistroName,
            "-u", $LinuxUser,
            "--",
            "bash", "-lc",
            "chmod u+x ~/.syncpss/helpers/uninstall_syncpss.sh 2>/dev/null || true; bash ~/.syncpss/helpers/uninstall_syncpss.sh${argumentText}"
        ) `
        -NoNewWindow `
        -Wait `
        -PassThru
    return [int]$process.ExitCode
}

function Invoke-StagedWslUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser,
        [string[]]$ExtraArguments = @()
    )

    $copiedHelpers = Copy-PurgeHelpersToWslHome -RepoRoot $RepoRoot -DistroName $DistroName -LinuxUser $LinuxUser
    foreach ($helperPath in $copiedHelpers) {
        Write-Host "Copied helper to $helperPath" -ForegroundColor Green
    }

    $exitCode = Invoke-WslUninstall -DistroName $DistroName -LinuxUser $LinuxUser -ExtraArguments $ExtraArguments
    Remove-WindowsStartMenuIntegrationIfRequested -DistroName $DistroName -LinuxUser $LinuxUser
    return $exitCode
}

function Remove-WindowsStartMenuIntegration {
    function Remove-PathBestEffort {
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [Parameter(Mandatory = $true)][string]$Label,
            [switch]$AllowEmptyDirectoryResidue
        )

        if (-not (Test-Path -LiteralPath $LiteralPath)) {
            return $true
        }

        $attempts = 3
        $lastMessage = ""
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            try {
                Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop
            } catch {
                $lastMessage = $_.Exception.Message
            }

            if (-not (Test-Path -LiteralPath $LiteralPath)) {
                return $true
            }

            if ($AllowEmptyDirectoryResidue -and (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
                Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                    } catch {
                    }
                }

                if (-not (Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                    Write-Host ("Leaving empty locked directory in place for now: {0}" -f $LiteralPath) -ForegroundColor Yellow
                    return $false
                }
            }

            Start-Sleep -Milliseconds 250
        }

        if ([string]::IsNullOrWhiteSpace($lastMessage)) {
            $lastMessage = "Path is still present after repeated delete attempts."
        }
        Write-Host ("Could not remove {0} at {1}: {2}" -f $Label, $LiteralPath, $lastMessage) -ForegroundColor Yellow
        return $false
    }

    $startMenuShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\syncpss.lnk"
    $appDataDir = Join-Path $env:LOCALAPPDATA "syncpss"
    $runtimeDir = Join-Path $env:USERPROFILE ".syncpss"
    $removedAny = $false
    $cleanupComplete = $true

    if (Test-Path -LiteralPath $startMenuShortcut) {
        if (-not (Remove-PathBestEffort -LiteralPath $startMenuShortcut -Label "Windows Start Menu shortcut")) {
            $cleanupComplete = $false
        }
        $removedAny = $true
    }
    if (Test-Path -LiteralPath $appDataDir) {
        if (-not (Remove-PathBestEffort -LiteralPath $appDataDir -Label "Windows local app assets")) {
            $cleanupComplete = $false
        }
        $removedAny = $true
    }
    if (Test-Path -LiteralPath $runtimeDir) {
        if (-not (Remove-PathBestEffort -LiteralPath $runtimeDir -Label "Windows runtime helper directory" -AllowEmptyDirectoryResidue)) {
            $cleanupComplete = $false
        }
        $removedAny = $true
    }

    if (-not $removedAny) {
        Write-Host "No Windows Start Menu shortcut or local syncpss launcher files were found." -ForegroundColor Yellow
    }

    return $cleanupComplete
}

function Invoke-Purge {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    Set-Location -LiteralPath $repoRoot

    $selectedDistro = Select-WslDistro -RequestedDistro $Distro
    $selectedUser = Select-WslUser -DistroName $selectedDistro -RequestedUser $User

    if ($RunNow) {
        $extraArguments = @()
        if ($AssumeYes) {
            $extraArguments += "--yes"
        }
        if ($PurgeWindowsShortcut) {
            $extraArguments += "--purge-windows-shortcut"
        }
        $exitCode = Invoke-StagedWslUninstall -RepoRoot $repoRoot -DistroName $selectedDistro -LinuxUser $selectedUser -ExtraArguments $extraArguments
        if ($exitCode -ne 0) {
            throw "WSL uninstall exited with code $exitCode"
        }
        return
    }

    if (-not $NonInteractive) {
        while ($true) {
            $runNowAnswer = Read-Host "Run the uninstall script now inside WSL? [Y/n]"
            if ([string]::IsNullOrWhiteSpace($runNowAnswer) -or $runNowAnswer -match '^(?i:y|yes)$') {
                $extraArguments = @()
                if ($AssumeYes) {
                    $extraArguments += "--yes"
                }
                if ($PurgeWindowsShortcut) {
                    $extraArguments += "--purge-windows-shortcut"
                }
                $exitCode = Invoke-StagedWslUninstall -RepoRoot $repoRoot -DistroName $selectedDistro -LinuxUser $selectedUser -ExtraArguments $extraArguments
                if ($exitCode -eq 0) {
                    return
                }

                Write-Host "The uninstall script did not finish successfully. Returning to the purge prompt..." -ForegroundColor Yellow
                continue
            }

            return
        }
    }
}

try {
    Invoke-Purge
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
