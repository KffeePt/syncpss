[CmdletBinding()]
param(
    [string]$Distro = "",
    [string]$User = "",
    [ValidateSet("tui","installer","all")]
    [string]$Target = "tui",
    [ValidateSet("windows-cross","wsl")]
    [string]$BuildHost = "wsl",
    [string]$BuildType = "Release",
    [string]$BuildDir = "",
    [string]$BinDir = "bin",
    [switch]$InstallDeps,
    [switch]$EnableClangTidy,
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
        throw "WSL is required to build syncpss from Windows."
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

function Convert-ToWslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $resolved = $WindowsPath
    if (Test-Path -LiteralPath $WindowsPath) {
        $resolved = (Resolve-Path -LiteralPath $WindowsPath).Path
    }
    if ($resolved -notmatch '^[A-Za-z]:\\') {
        throw "Cannot convert path to WSL path: $resolved"
    }

    $drive = $resolved.Substring(0,1).ToLowerInvariant()
    $rest = $resolved.Substring(3).Replace('\','/')
    return "/mnt/$drive/$rest"
}

function Get-ResolvedBuildDir {
    param(
        [Parameter(Mandatory = $true)][string]$BuildHostName,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$RequestedBuildDir,
        [string]$DistroName = "",
        [string]$LinuxUser = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedBuildDir)) {
        if ([System.IO.Path]::IsPathRooted($RequestedBuildDir)) {
            return $RequestedBuildDir
        }
        return Join-Path $RepoRoot $RequestedBuildDir
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "syncpss-build-cache"
    if ($BuildHostName -eq "wsl") {
        $distroSegment = if ([string]::IsNullOrWhiteSpace($DistroName)) { "default-distro" } else { $DistroName }
        $userSegment = if ([string]::IsNullOrWhiteSpace($LinuxUser)) { "default-user" } else { $LinuxUser }
        return Join-Path $tempRoot ("wsl-{0}-{1}" -f $distroSegment, $userSegment)
    }

    return Join-Path $tempRoot "windows-cross"
}

function Test-WslBuildToolchain {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser
    )

    $command = "command -v cmake >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 && command -v make >/dev/null 2>&1 && command -v pkg-config >/dev/null 2>&1"
    & wsl.exe -d $DistroName -u $LinuxUser -- bash -lc $command | Out-Null
    return $LASTEXITCODE -eq 0
}

function Ensure-WslBuildToolchain {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser,
        [bool]$ForceInstall
    )

    if (-not $ForceInstall -and (Test-WslBuildToolchain -DistroName $DistroName -LinuxUser $LinuxUser)) {
        return
    }

    $repoRootWsl = Convert-ToWslPath -WindowsPath $RepoRoot
    Write-Host "Installing Linux build dependencies inside WSL distro '$DistroName' as user '$LinuxUser'..." -ForegroundColor Yellow
    Write-Host "You may be prompted for your WSL sudo password." -ForegroundColor Yellow
    Write-Host "If apt or dpkg is already running, the bootstrap will wait for it instead of starting a competing install." -ForegroundColor Yellow
        & wsl.exe -d $DistroName -u $LinuxUser -- bash -lc "cd '$repoRootWsl'; bash scripts/sh/installer.sh --build-deps"
    $bootstrapExit = [int]$LASTEXITCODE
    if ($bootstrapExit -ne 0) {
        throw "WSL dependency bootstrap failed with exit code $bootstrapExit"
    }

    if (-not (Test-WslBuildToolchain -DistroName $DistroName -LinuxUser $LinuxUser)) {
        throw "WSL dependency bootstrap completed, but the required Linux build tools are still missing."
    }
}

function Get-CommandPathOrEmpty {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return ""
    }
    return $command.Source
}

function Get-WindowsCrossBuildTools {
    return [pscustomobject]@{
        CMake      = Get-CommandPathOrEmpty -Name "cmake"
        Make       = Get-CommandPathOrEmpty -Name "mingw32-make"
        Gxx        = Get-CommandPathOrEmpty -Name "x86_64-linux-gnu-g++"
        Gcc        = Get-CommandPathOrEmpty -Name "x86_64-linux-gnu-gcc"
        PkgConfig  = Get-CommandPathOrEmpty -Name "x86_64-linux-gnu-pkg-config"
        PlainGxx   = Get-CommandPathOrEmpty -Name "g++"
    }
}

function Write-Sha256File {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($SourcePath)
        try {
            $hashBytes = $sha.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }

    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    [System.IO.File]::WriteAllText($OutputPath, "$hash  $DisplayName")
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

function Package-WindowsCrossOutputs {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$BuildDirValue,
        [Parameter(Mandatory = $true)][string]$BinDirValue,
        [Parameter(Mandatory = $true)][string]$BuildTargetValue
    )

    $buildRoot = Join-Path $RepoRoot $BuildDirValue
    $binRoot = Join-Path $RepoRoot $BinDirValue
    if (-not (Test-Path -LiteralPath $binRoot)) {
        New-Item -ItemType Directory -Path $binRoot | Out-Null
    }

    if ($BuildTargetValue -in @("tui", "all")) {
        $sourceBinary = Join-Path $buildRoot "syncpss"
        $destBinary = Join-Path $binRoot "syncpss-linux-x86_64"
        if (-not (Test-Path -LiteralPath $sourceBinary)) {
            throw "Expected cross-built TUI binary not found: $sourceBinary"
        }
        Copy-Item -LiteralPath $sourceBinary -Destination $destBinary -Force
        Write-Sha256File -SourcePath $destBinary -OutputPath (Join-Path $binRoot "syncpss-linux-x86_64.sha256") -DisplayName "syncpss-linux-x86_64"
    }

    if ($BuildTargetValue -in @("installer", "all")) {
        $sourceInstall = Join-Path $buildRoot "install"
        $destInstall = Join-Path $binRoot "install"
        if (-not (Test-Path -LiteralPath $sourceInstall)) {
            throw "Expected cross-built install binary not found: $sourceInstall"
        }
        Copy-Item -LiteralPath $sourceInstall -Destination $destInstall -Force
        Write-Sha256File -SourcePath $destInstall -OutputPath (Join-Path $binRoot "install.sha256") -DisplayName "install"

        $manifestSource = Join-Path $RepoRoot "manifest.xml"
        $manifestOut = Join-Path $binRoot "manifest.xml"
        if (-not (Test-Path -LiteralPath $manifestSource)) {
            throw "Missing repo manifest for packaging: $manifestSource"
        }
        Copy-Item -LiteralPath $manifestSource -Destination $manifestOut -Force
        Write-Sha256File -SourcePath $manifestOut -OutputPath (Join-Path $binRoot "manifest.xml.sha256") -DisplayName "manifest.xml"

        $installerScript = Join-Path $RepoRoot "scripts\sh\installer.sh"
        $installerOut = Join-Path $binRoot "installer.sh"
        Copy-TextFileWithLf -SourcePath $installerScript -DestinationPath $installerOut
        Write-Sha256File -SourcePath $installerOut -OutputPath (Join-Path $binRoot "installer.sh.sha256") -DisplayName "installer.sh"

        $uninstallScript = Join-Path $RepoRoot "scripts\sh\uninstall_syncpss.sh"
        $uninstallOut = Join-Path $binRoot "uninstall_syncpss.sh"
        Copy-TextFileWithLf -SourcePath $uninstallScript -DestinationPath $uninstallOut
        Write-Sha256File -SourcePath $uninstallOut -OutputPath (Join-Path $binRoot "uninstall_syncpss.sh.sha256") -DisplayName "uninstall_syncpss.sh"
    }
}

function Invoke-WindowsCrossBuild {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$BuildTypeValue,
        [Parameter(Mandatory = $true)][string]$BuildDirValue,
        [Parameter(Mandatory = $true)][string]$BinDirValue,
        [Parameter(Mandatory = $true)][string]$BuildTargetValue,
        [bool]$RunClangTidy
    )

    $tools = Get-WindowsCrossBuildTools
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($tools.CMake)) { $missing += "cmake" }
    if ([string]::IsNullOrWhiteSpace($tools.Make)) { $missing += "mingw32-make" }
    if ([string]::IsNullOrWhiteSpace($tools.Gcc)) { $missing += "x86_64-linux-gnu-gcc" }
    if ([string]::IsNullOrWhiteSpace($tools.Gxx)) { $missing += "x86_64-linux-gnu-g++" }
    if ([string]::IsNullOrWhiteSpace($tools.PkgConfig)) { $missing += "x86_64-linux-gnu-pkg-config" }

    if ($missing.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($tools.PlainGxx)) {
            throw ("Windows g++ was found at '{0}', but it is a native Windows compiler and cannot build the Linux syncpss binaries from this Unix-only codebase. Missing Windows-hosted Linux cross-build tools: {1}" -f $tools.PlainGxx, ($missing -join ", "))
        }
        throw ("Missing Windows-hosted Linux cross-build tools: {0}" -f ($missing -join ", "))
    }

    $toolchainFile = Join-Path $RepoRoot "cmake\toolchains\linux-cross-gcc.cmake"
    if (-not (Test-Path -LiteralPath $toolchainFile)) {
        throw "Missing cross-build toolchain file: $toolchainFile"
    }

    $buildRoot = $BuildDirValue
    if (-not (Test-Path -LiteralPath $buildRoot)) {
        New-Item -ItemType Directory -Path $buildRoot | Out-Null
    }

    $env:SYNCPSS_BUILD_TARGET = $BuildTargetValue
    $env:SYNCPSS_BUILD_TYPE = $BuildTypeValue
    $env:SYNCPSS_BIN_DIR = $BinDirValue
    $env:SYNCPSS_ENABLE_CLANG_TIDY = if ($RunClangTidy) { "1" } else { "0" }
    $env:PKG_CONFIG = $tools.PkgConfig

    $configureArgs = @(
        "-S", $RepoRoot,
        "-B", $buildRoot,
        "-G", "MinGW Makefiles",
        "-DCMAKE_BUILD_TYPE=$BuildTypeValue",
        "-DCMAKE_TOOLCHAIN_FILE=$toolchainFile"
    )
    if ($RunClangTidy) {
        $configureArgs += "-DSYNCPSS_ENABLE_CLANG_TIDY=ON"
    }

    Write-Host "Configuring Windows-hosted Linux cross-build for target '$BuildTargetValue'..."
    & cmake @configureArgs
    if ($LASTEXITCODE -ne 0) {
        return [int]$LASTEXITCODE
    }

    $buildArgs = @("--build", $buildRoot, "--parallel")
    switch ($BuildTargetValue) {
        "tui" { $buildArgs += @("--target", "syncpss") }
        "installer" { $buildArgs += @("--target", "syncpss_install") }
        default { }
    }

    Write-Host "Building Windows-hosted Linux cross-build target '$BuildTargetValue'..."
    & cmake @buildArgs
    if ($LASTEXITCODE -ne 0) {
        return [int]$LASTEXITCODE
    }

    Write-Host "Packaging Windows-hosted Linux cross-build artifacts..."
    Package-WindowsCrossOutputs `
        -RepoRoot $RepoRoot `
        -BuildDirValue $BuildDirValue `
        -BinDirValue $BinDirValue `
        -BuildTargetValue $BuildTargetValue

    return 0
}

function Invoke-WslBuild {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser,
        [Parameter(Mandatory = $true)][string]$BuildTypeValue,
        [Parameter(Mandatory = $true)][string]$BuildDirValue,
        [Parameter(Mandatory = $true)][string]$BinDirValue,
        [Parameter(Mandatory = $true)][string]$BuildTargetValue,
        [bool]$RunClangTidy
    )

    $repoRootWsl = Convert-ToWslPath -WindowsPath $RepoRoot
    $buildDirWsl = Convert-ToWslPath -WindowsPath $BuildDirValue
    $clangTidyValue = if ($RunClangTidy) { "1" } else { "0" }
    $command = @(
        "cd '$repoRootWsl'",
        "export SYNCPSS_BUILD_TYPE='$BuildTypeValue'",
        "export SYNCPSS_BUILD_DIR='$buildDirWsl'",
        "export SYNCPSS_BIN_DIR='$BinDirValue'",
        "export SYNCPSS_BUILD_TARGET='$BuildTargetValue'",
        "export SYNCPSS_ENABLE_CLANG_TIDY='$clangTidyValue'",
        "bash scripts/sh/build.sh"
    ) -join "; "

    Write-Host "Building Linux target '$BuildTargetValue' in WSL distro '$DistroName' as user '$LinuxUser'..."
    $commandOutput = & wsl.exe -d $DistroName -u $LinuxUser -- bash -lc $command 2>&1
    $commandExitCode = [int]$LASTEXITCODE
    if ($null -ne $commandOutput) {
        $commandOutput | Out-Host
    }
    return $commandExitCode
}

function Invoke-Build {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    Set-Location -LiteralPath $repoRoot

    if ($BuildHost -eq "windows-cross") {
        $resolvedBuildDir = Get-ResolvedBuildDir -BuildHostName $BuildHost -RepoRoot $repoRoot -RequestedBuildDir $BuildDir
        $exitCode = Invoke-WindowsCrossBuild `
            -RepoRoot $repoRoot `
            -BuildTypeValue $BuildType `
            -BuildDirValue $resolvedBuildDir `
            -BinDirValue $BinDir `
            -BuildTargetValue $Target `
            -RunClangTidy $EnableClangTidy.IsPresent

        if ($exitCode -ne 0) {
            throw "Windows-hosted Linux build failed with exit code $exitCode"
        }
    } else {
        $selectedDistro = Select-WslDistro -RequestedDistro $Distro
        $selectedUser = Select-WslUser -DistroName $selectedDistro -RequestedUser $User
        $resolvedBuildDir = Get-ResolvedBuildDir `
            -BuildHostName $BuildHost `
            -RepoRoot $repoRoot `
            -RequestedBuildDir $BuildDir `
            -DistroName $selectedDistro `
            -LinuxUser $selectedUser

        Ensure-WslBuildToolchain `
            -RepoRoot $repoRoot `
            -DistroName $selectedDistro `
            -LinuxUser $selectedUser `
            -ForceInstall $InstallDeps.IsPresent

        $exitCode = Invoke-WslBuild `
            -RepoRoot $repoRoot `
            -DistroName $selectedDistro `
            -LinuxUser $selectedUser `
            -BuildTypeValue $BuildType `
            -BuildDirValue $resolvedBuildDir `
            -BinDirValue $BinDir `
            -BuildTargetValue $Target `
            -RunClangTidy $EnableClangTidy.IsPresent

        if ($exitCode -ne 0) {
            throw "WSL build failed with exit code $exitCode"
        }
    }

    $requiredOutputs = switch ($Target) {
        "tui" {
            @(
                (Join-Path $repoRoot "$BinDir\syncpss-linux-x86_64"),
                (Join-Path $repoRoot "$BinDir\syncpss-linux-x86_64.sha256")
            )
        }
        "installer" {
            @(
                (Join-Path $repoRoot "$BinDir\install"),
                (Join-Path $repoRoot "$BinDir\install.sha256"),
                (Join-Path $repoRoot "$BinDir\installer.sh"),
                (Join-Path $repoRoot "$BinDir\installer.sh.sha256"),
                (Join-Path $repoRoot "$BinDir\uninstall_syncpss.sh"),
                (Join-Path $repoRoot "$BinDir\uninstall_syncpss.sh.sha256")
            )
        }
        default {
            @(
                (Join-Path $repoRoot "$BinDir\syncpss-linux-x86_64"),
                (Join-Path $repoRoot "$BinDir\syncpss-linux-x86_64.sha256"),
                (Join-Path $repoRoot "$BinDir\install"),
                (Join-Path $repoRoot "$BinDir\install.sha256"),
                (Join-Path $repoRoot "$BinDir\installer.sh"),
                (Join-Path $repoRoot "$BinDir\installer.sh.sha256"),
                (Join-Path $repoRoot "$BinDir\uninstall_syncpss.sh"),
                (Join-Path $repoRoot "$BinDir\uninstall_syncpss.sh.sha256")
            )
        }
    }

    $missingOutputs = @($requiredOutputs | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingOutputs.Count -gt 0) {
        throw ("WSL build completed but required artifacts are missing:`n" + (($missingOutputs | ForEach-Object { " - $_" }) -join "`n"))
    }
}

try {
    Invoke-Build
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
