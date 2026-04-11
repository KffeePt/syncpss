[CmdletBinding()]
param(
    [string]$Distro = "",
    [string]$User = "",
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
        throw "WSL is required to run the container repair helper."
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

function Copy-FixScriptToWslHome {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $source = Join-Path $RepoRoot "scripts\fix_local_keys_container.sh"
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Missing local fix script: $source"
    }

    $target = "\\wsl.localhost\$DistroName\home\$LinuxUser\fix_local_keys_container.sh"
    Copy-Item -LiteralPath $source -Destination $target -Force
    & wsl.exe -d $DistroName -u $LinuxUser -- bash -lc "chmod 700 /home/$LinuxUser/fix_local_keys_container.sh"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to mark fix_local_keys_container.sh executable in WSL."
    }
    return $target
}

function Invoke-WslFixScript {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $process = Start-Process `
        -FilePath "wsl.exe" `
        -ArgumentList @(
            "-d", $DistroName,
            "-u", $LinuxUser,
            "--",
            "bash", "/home/$LinuxUser/fix_local_keys_container.sh"
        ) `
        -NoNewWindow `
        -Wait `
        -PassThru
    return [int]$process.ExitCode
}

function Invoke-RunContainerFix {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    Set-Location -LiteralPath $repoRoot

    $selectedDistro = Select-WslDistro -RequestedDistro $Distro
    $selectedUser = Select-WslUser -DistroName $selectedDistro -RequestedUser $User

    $target = Copy-FixScriptToWslHome -RepoRoot $repoRoot -DistroName $selectedDistro -LinuxUser $selectedUser
    Write-Host "Copied local keys repair helper to $target" -ForegroundColor Green

    $exitCode = Invoke-WslFixScript -DistroName $selectedDistro -LinuxUser $selectedUser
    if ($exitCode -ne 0) {
        throw "WSL fix_local_keys_container.sh exited with code $exitCode"
    }
}

try {
    Invoke-RunContainerFix
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
