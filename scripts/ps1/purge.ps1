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

function Resolve-UninstallScriptSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $candidates = @(
        (Join-Path $RepoRoot "scripts\sh\uninstall_syncpss.sh"),
        (Join-Path $RepoRoot "bin\uninstall_syncpss.sh")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Could not find uninstall_syncpss.sh in the repo checkout or bin directory."
}

function Copy-UninstallScriptToWslHome {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $source = Resolve-UninstallScriptSource -RepoRoot $RepoRoot
    $stageDir = "\\wsl.localhost\$DistroName\home\$LinuxUser\.syncpss\helpers"
    if (-not (Test-Path -LiteralPath $stageDir)) {
        New-Item -ItemType Directory -Path $stageDir | Out-Null
    }
    $target = Join-Path $stageDir "uninstall_syncpss.sh"
    Copy-TextFileWithLf -SourcePath $source -DestinationPath $target
    return $target
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

    Remove-WindowsStartMenuIntegration
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    Write-Host "Removed Windows Start Menu shortcut and local syncpss launcher assets." -ForegroundColor Green
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

function Remove-WindowsStartMenuIntegration {
    $startMenuShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\syncpss.lnk"
    $appDataDir = Join-Path $env:LOCALAPPDATA "syncpss"
    $runtimeDir = Join-Path $env:USERPROFILE ".syncpss"
    $removedAny = $false

    if (Test-Path -LiteralPath $startMenuShortcut) {
        Remove-Item -LiteralPath $startMenuShortcut -Force -ErrorAction SilentlyContinue
        $removedAny = $true
    }
    if (Test-Path -LiteralPath $appDataDir) {
        Remove-Item -LiteralPath $appDataDir -Recurse -Force -ErrorAction SilentlyContinue
        $removedAny = $true
    }
    if (Test-Path -LiteralPath $runtimeDir) {
        Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue
        $removedAny = $true
    }

    if (-not $removedAny) {
        Write-Host "No Windows Start Menu shortcut or local syncpss launcher files were found." -ForegroundColor Yellow
    }
}

function Invoke-Purge {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    Set-Location -LiteralPath $repoRoot

    $selectedDistro = Select-WslDistro -RequestedDistro $Distro
    $selectedUser = Select-WslUser -DistroName $selectedDistro -RequestedUser $User
    $scriptPath = Copy-UninstallScriptToWslHome -RepoRoot $repoRoot -DistroName $selectedDistro -LinuxUser $selectedUser

    Write-Host "Copied uninstall script to $scriptPath" -ForegroundColor Green

    if ($RunNow) {
        $extraArguments = @()
        if ($AssumeYes) {
            $extraArguments += "--yes"
        }
        if ($PurgeWindowsShortcut) {
            $extraArguments += "--purge-windows-shortcut"
        }
        $exitCode = Invoke-WslUninstall -DistroName $selectedDistro -LinuxUser $selectedUser -ExtraArguments $extraArguments
        Remove-WindowsStartMenuIntegrationIfRequested -DistroName $selectedDistro -LinuxUser $selectedUser
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
                $exitCode = Invoke-WslUninstall -DistroName $selectedDistro -LinuxUser $selectedUser -ExtraArguments $extraArguments
                if ($exitCode -eq 0) {
                    Remove-WindowsStartMenuIntegrationIfRequested -DistroName $selectedDistro -LinuxUser $selectedUser
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
