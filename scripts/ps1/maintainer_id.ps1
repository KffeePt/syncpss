Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:MaintainerIdEnvName = "SYNCPSS_MAINTAINER_ID"
$script:LegacyMaintainerIdHash = "4e6840a7429669ff3ed6747d5727cc2cceab1113e1336b87b4a541a1c1ecc0b0"

function Resolve-SyncpssRepoRoot {
    param([string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return (Resolve-Path -LiteralPath $RepoRoot).Path
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-MaintainerHashFilePath {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    return (Join-Path $RepoRoot "config\maintainer_id.sha256")
}

function Get-MaintainerConfigDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:SYNCPSS_MAINTAINER_CONFIG_DIR)) {
        return [System.IO.Path]::GetFullPath($env:SYNCPSS_MAINTAINER_CONFIG_DIR)
    }

    return (Join-Path $HOME ".config\syncpss")
}

function Get-MaintainerEnvFilePath {
    return (Join-Path (Get-MaintainerConfigDirectory) "maintainer-id.env")
}

function Get-MaintainerEnvironmentScope {
    if ($env:SYNCPSS_MAINTAINER_ENV_SCOPE -eq "Process") {
        return "Process"
    }

    return "User"
}

function Get-LegacyMaintainerHashFilePaths {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    return @(
        (Join-Path $RepoRoot "scripts\maintainer_id.sha256"),
        (Join-Path $RepoRoot "maintainer_id.sha256")
    )
}

function Get-MaintainerLegacyIdentityPath {
    return (Join-Path (Get-MaintainerConfigDirectory) "release.identity")
}

function Get-MaintainerManifestPath {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    return (Join-Path $RepoRoot "manifest.xml")
}

function Get-MaintainerIdHashValue {
    param([Parameter(Mandatory = $true)][string]$Seed)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-MaintainerIdFormat {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value -match '^[A-Za-z0-9]{32}$'
}

function Test-MaintainerIdHashFormat {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value -match '^[0-9a-fA-F]{64}$'
}

function Assert-MaintainerIdFormat {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$SourceDescription
    )

    if (-not (Test-MaintainerIdFormat -Value $Value)) {
        throw "$SourceDescription must be exactly 32 ASCII letters or digits."
    }

    return $Value
}

function Assert-MaintainerIdHashFormat {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$SourceDescription
    )

    if (-not (Test-MaintainerIdHashFormat -Value $Value)) {
        throw "$SourceDescription must contain a full 64-character SHA-256 hex digest."
    }

    return $Value.ToLowerInvariant()
}

function New-RandomMaintainerId {
    $alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
    $builder = New-Object System.Text.StringBuilder
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 4
        for ($i = 0; $i -lt 32; $i++) {
            do {
                $rng.GetBytes($bytes)
                $value = [BitConverter]::ToUInt32($bytes, 0)
                $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$alphabet.Length)
            } while ($value -ge $limit)

            $index = [int]($value % [uint32]$alphabet.Length)
            [void]$builder.Append($alphabet[$index])
        }
    } finally {
        $rng.Dispose()
    }
    return $builder.ToString()
}

function Get-CurrentMaintainerId {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:SYNCPSS_MAINTAINER_ID)) {
        $value = Assert-MaintainerIdFormat -Value $env:SYNCPSS_MAINTAINER_ID.Trim() -SourceDescription "SYNCPSS_MAINTAINER_ID in the process environment"
        return [pscustomobject]@{
            Value  = $value
            Source = "process environment"
        }
    }

    if ((Get-MaintainerEnvironmentScope) -eq "User") {
        $userValue = [Environment]::GetEnvironmentVariable($script:MaintainerIdEnvName, "User")
        if (-not [string]::IsNullOrWhiteSpace($userValue)) {
            $value = Assert-MaintainerIdFormat -Value $userValue.Trim() -SourceDescription "SYNCPSS_MAINTAINER_ID in the user environment"
            return [pscustomobject]@{
                Value  = $value
                Source = "user environment"
            }
        }
    }

    return $null
}

function Read-MaintainerIdBootstrapFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $lines = [System.IO.File]::ReadAllLines($Path)
    $nonEmptyLines = @(
        $lines |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($nonEmptyLines.Count -eq 0) {
        throw "Maintainer bootstrap file '$Path' is empty."
    }

    if ($nonEmptyLines.Count -ne 1) {
        throw "Maintainer bootstrap file '$Path' must contain exactly one non-empty line."
    }

    $line = $nonEmptyLines[0]
    if ($line -match '^(?:export\s+)?SYNCPSS_MAINTAINER_ID=([A-Za-z0-9]{32})$') {
        return $Matches[1]
    }

    if ($line -match '^([A-Za-z0-9]{32})$') {
        return $Matches[1]
    }

    throw "Maintainer bootstrap file '$Path' must contain only a 32-character maintainer ID or a single SYNCPSS_MAINTAINER_ID assignment."
}

function Get-MaintainerBootstrapSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $candidateFiles = @(
        [pscustomobject]@{
            Path   = Get-MaintainerEnvFilePath
            Source = "maintainer env file"
        },
        [pscustomobject]@{
            Path   = Get-MaintainerLegacyIdentityPath
            Source = "legacy maintainer file"
        }
    )

    foreach ($candidate in $candidateFiles) {
        if (-not (Test-Path -LiteralPath $candidate.Path)) {
            continue
        }

        $value = Read-MaintainerIdBootstrapFile -Path $candidate.Path
        $value = Assert-MaintainerIdFormat -Value $value -SourceDescription "$($candidate.Source) '$($candidate.Path)'"
        return [pscustomobject]@{
            Value  = $value
            Source = $candidate.Source
            Path   = $candidate.Path
        }
    }

    return $null
}

function Get-ExpectedMaintainerIdHash {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $hashPath = Get-MaintainerHashFilePath -RepoRoot $RepoRoot
    $candidatePaths = @($hashPath) + (Get-LegacyMaintainerHashFilePaths -RepoRoot $RepoRoot)
    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            $line = [System.IO.File]::ReadAllText($candidatePath).Trim()
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                return Assert-MaintainerIdHashFormat -Value (($line -split '\s+')[0]) -SourceDescription "Maintainer hash file '$candidatePath'"
            }
        }
    }

    $current = Get-CurrentMaintainerId -RepoRoot $RepoRoot
    if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace($current.Value)) {
        return Update-MaintainerHashArtifacts -RepoRoot $RepoRoot -Seed $current.Value
    }

    $manifestPath = Get-MaintainerManifestPath -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $manifestPath) {
        $match = Select-String -Path $manifestPath -Pattern '<id_hash>\s*([^<]+)\s*</id_hash>' | Select-Object -First 1
        if ($null -ne $match) {
            $value = $match.Matches[0].Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return Assert-MaintainerIdHashFormat -Value $value -SourceDescription "Manifest maintainer hash in '$manifestPath'"
            }
        }
    }

    return $script:LegacyMaintainerIdHash
}

function Set-ContentIfChanged {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $existing = $null
    if (Test-Path -LiteralPath $Path) {
        $existing = [System.IO.File]::ReadAllText($Path)
    } else {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }
    }

    if ($existing -eq $Content) {
        return $false
    }

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function Update-MaintainerHashArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Seed
    )

    $hash = Get-MaintainerIdHashValue -Seed $Seed
    $hashPath = Get-MaintainerHashFilePath -RepoRoot $RepoRoot
    [void](Set-ContentIfChanged -Path $hashPath -Content ($hash + "  SYNCPSS_MAINTAINER_ID`n"))

    foreach ($legacyPath in (Get-LegacyMaintainerHashFilePaths -RepoRoot $RepoRoot)) {
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Force
        }
    }

    $manifestPath = Get-MaintainerManifestPath -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = [System.IO.File]::ReadAllText($manifestPath)
        $updated = [System.Text.RegularExpressions.Regex]::Replace(
            $manifest,
            '<id_hash>\s*[^<]+\s*</id_hash>',
            "<id_hash>$hash</id_hash>",
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        [void](Set-ContentIfChanged -Path $manifestPath -Content $updated)
    }

    return $hash
}

function Set-PersistedMaintainerEnvironment {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ((Get-MaintainerEnvironmentScope) -eq "User") {
        [Environment]::SetEnvironmentVariable($script:MaintainerIdEnvName, $Value, "User")
    }
    $env:SYNCPSS_MAINTAINER_ID = $Value

    $legacyIdentityPath = Get-MaintainerLegacyIdentityPath
    if (Test-Path -LiteralPath $legacyIdentityPath) {
        Remove-Item -LiteralPath $legacyIdentityPath -Force
    }
}

function Use-MaintainerId {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $Value = Assert-MaintainerIdFormat -Value $Value -SourceDescription "Maintainer ID"

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $hashPath = Get-MaintainerHashFilePath -RepoRoot $resolvedRepoRoot

    if (Test-Path -LiteralPath $hashPath) {
        $expectedHash = Get-ExpectedMaintainerIdHash -RepoRoot $resolvedRepoRoot
        $actualHash = Get-MaintainerIdHashValue -Seed $Value
        if ($actualHash -ne $expectedHash) {
            throw "The entered maintainer ID does not match config\maintainer_id.sha256."
        }

        Set-PersistedMaintainerEnvironment -Value $Value
        return [pscustomobject]@{
            Value = $Value
            Hash  = $expectedHash
        }
    }

    return Set-PersistedMaintainerId -RepoRoot $resolvedRepoRoot -Value $Value
}

function Set-PersistedMaintainerId {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $Value = Assert-MaintainerIdFormat -Value $Value -SourceDescription "Maintainer ID"

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot

    Set-PersistedMaintainerEnvironment -Value $Value
    $hash = Update-MaintainerHashArtifacts -RepoRoot $resolvedRepoRoot -Seed $Value
    return [pscustomobject]@{
        Value = $Value
        Hash  = $hash
    }
}

function Remove-PersistedMaintainerId {
    if ((Get-MaintainerEnvironmentScope) -eq "User") {
        [Environment]::SetEnvironmentVariable($script:MaintainerIdEnvName, $null, "User")
    }
    Remove-Item Env:\SYNCPSS_MAINTAINER_ID -ErrorAction SilentlyContinue

    $legacyIdentityPath = Get-MaintainerLegacyIdentityPath
    if (Test-Path -LiteralPath $legacyIdentityPath) {
        Remove-Item -LiteralPath $legacyIdentityPath -Force
    }
}

function Format-MaintainerIdForDisplay {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "<not set>"
    }

    if ($Value.Length -le 8) {
        return $Value
    }

    return "{0}...{1}" -f $Value.Substring(0, 4), $Value.Substring($Value.Length - 4)
}

function Get-MaintainerIdBootstrapFailureMessage {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $hashPath = Get-MaintainerHashFilePath -RepoRoot $resolvedRepoRoot
    $envFilePath = Get-MaintainerEnvFilePath
    $legacyIdentityPath = Get-MaintainerLegacyIdentityPath

    if (Test-Path -LiteralPath $hashPath) {
        return "Missing SYNCPSS_MAINTAINER_ID. '$hashPath' only stores the SHA-256 hash, not the plaintext maintainer ID. Restore the plaintext maintainer ID in '$envFilePath' or '$legacyIdentityPath', or set it explicitly with scripts\set_fingerprint.bat."
    }

    return "Missing SYNCPSS_MAINTAINER_ID and no bootstrap maintainer file was found at '$envFilePath' or '$legacyIdentityPath'. Set or rotate it explicitly with scripts\set_fingerprint.bat."
}

function Can-UseRepoMaintainerHashWithoutPlaintext {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $hashPath = Get-MaintainerHashFilePath -RepoRoot $resolvedRepoRoot
    return (Test-Path -LiteralPath $hashPath)
}

function Initialize-MaintainerIdFromBootstrapSource {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $bootstrap = Get-MaintainerBootstrapSource -RepoRoot $resolvedRepoRoot
    if ($null -eq $bootstrap) {
        return $null
    }

    $result = Use-MaintainerId -RepoRoot $resolvedRepoRoot -Value $bootstrap.Value
    Write-Host ("Loaded maintainer ID from {0} '{1}' and saved it to the Windows user environment." -f $bootstrap.Source, $bootstrap.Path) -ForegroundColor Green
    return [pscustomobject]@{
        Value  = $result.Value
        Hash   = $result.Hash
        Source = $bootstrap.Source
        Path   = $bootstrap.Path
    }
}

function Prompt-MaintainerIdInitialization {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$NonInteractive
    )

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $hashPath = Get-MaintainerHashFilePath -RepoRoot $resolvedRepoRoot
    $hasHashFile = Test-Path -LiteralPath $hashPath
    $message = if ($hasHashFile) {
        "Missing SYNCPSS_MAINTAINER_ID. The repo already has $hashPath, so enter the existing maintainer ID or rotate it."
    } else {
        "Missing SYNCPSS_MAINTAINER_ID and no source maintainer hash exists yet at $hashPath."
    }
    if ($NonInteractive) {
        throw $message
    }

    Write-Host $message -ForegroundColor Yellow
    if ($hasHashFile) {
        $consent = Read-Host "Skip setting SYNCPSS_MAINTAINER_ID now for this Windows user? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($consent) -or $consent -match '^(?i:y|yes)$') {
            Write-Host "Keeping the repo maintainer hash as-is. SYNCPSS_MAINTAINER_ID remains unset for this Windows user." -ForegroundColor Yellow
            return $null
        }
    } else {
        $consent = Read-Host "Set SYNCPSS_MAINTAINER_ID now for this Windows user? [Y/n]"
        if (-not [string]::IsNullOrWhiteSpace($consent) -and $consent -notmatch '^(?i:y|yes)$') {
            throw $message
        }
    }

    while ($true) {
        Write-Host ""
        $defaultSelection = if ($hasHashFile) { "1" } else { "2" }
        if ($hasHashFile) {
            Write-Host "  [1] Enter the existing maintainer ID and save it to the user environment"
            Write-Host "  [2] Rotate the maintainer ID and rewrite config\maintainer_id.sha256"
        } else {
            Write-Host "  [1] Enter an existing maintainer ID and create config\maintainer_id.sha256"
            Write-Host "  [2] Generate a new 32-character maintainer ID"
        }
        Write-Host "  [3] Cancel"
        $selection = Read-Host "Choose an option [$defaultSelection]"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            $selection = $defaultSelection
        }

        switch ($selection) {
            "1" {
                $entered = Read-Host "Enter the maintainer ID"
                if (-not (Test-MaintainerIdFormat -Value $entered)) {
                    Write-Host "Maintainer ID must be exactly 32 ASCII letters or digits." -ForegroundColor Red
                    continue
                }
                try {
                    return (Use-MaintainerId -RepoRoot $resolvedRepoRoot -Value $entered).Value
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    continue
                }
            }
            "2" {
                try {
                    $generated = New-RandomMaintainerId
                    $result = Set-PersistedMaintainerId -RepoRoot $resolvedRepoRoot -Value $generated
                    Write-Host ("Generated maintainer ID: {0}" -f $result.Value) -ForegroundColor Green
                    return $result.Value
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    continue
                }
            }
            "3" {
                if ($hasHashFile) {
                    Write-Host "Keeping the repo maintainer hash as-is. SYNCPSS_MAINTAINER_ID remains unset for this Windows user." -ForegroundColor Yellow
                    return $null
                }
                throw $message
            }
            default {
                Write-Host "Invalid selection." -ForegroundColor Red
            }
        }
    }
}

function Resolve-MaintainerIdSeed {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$NonInteractive
    )

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $current = Get-CurrentMaintainerId -RepoRoot $resolvedRepoRoot
    if ($null -ne $current) {
        return $current.Value
    }

    $bootstrapped = Initialize-MaintainerIdFromBootstrapSource -RepoRoot $resolvedRepoRoot
    if ($null -ne $bootstrapped) {
        return $bootstrapped.Value
    }

    if (Can-UseRepoMaintainerHashWithoutPlaintext -RepoRoot $resolvedRepoRoot) {
        Write-Host "No plaintext maintainer ID file was found. Continuing with the existing repo maintainer hash from config\maintainer_id.sha256." -ForegroundColor Yellow
        return $null
    }

    throw (Get-MaintainerIdBootstrapFailureMessage -RepoRoot $resolvedRepoRoot)
}

function Show-MaintainerIdManager {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot

    while ($true) {
        $current = Get-CurrentMaintainerId -RepoRoot $resolvedRepoRoot
        $expectedHash = Get-ExpectedMaintainerIdHash -RepoRoot $resolvedRepoRoot
        $currentValue = if ($null -ne $current) { $current.Value } else { $null }
        $currentSource = if ($null -ne $current) { $current.Source } else { "<none>" }

        Write-Host ""
        Write-Host "syncpss maintainer ID manager" -ForegroundColor Yellow
        Write-Host ("Current ID:  {0}" -f (Format-MaintainerIdForDisplay -Value $currentValue)) -ForegroundColor Cyan
        Write-Host ("Source:      {0}" -f $currentSource) -ForegroundColor Cyan
        Write-Host ("Repo hash:   {0}" -f $expectedHash) -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] Set maintainer ID"
        Write-Host "  [2] Remove maintainer ID"
        Write-Host "  [3] Rotate maintainer ID"
        Write-Host "  [4] Exit"

        $selection = Read-Host "Choose an option [4]"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            $selection = "4"
        }

        switch ($selection) {
            "1" {
                $entered = Read-Host "Enter the maintainer ID"
                if (-not (Test-MaintainerIdFormat -Value $entered)) {
                    Write-Host "Maintainer ID must be exactly 32 ASCII letters or digits." -ForegroundColor Red
                    continue
                }
                try {
                    $result = Use-MaintainerId -RepoRoot $resolvedRepoRoot -Value $entered
                    Write-Host ("Saved maintainer ID. Repo hash is {0}" -f $result.Hash) -ForegroundColor Green
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                }
            }
            "2" {
                $confirm = Read-Host "Remove the persisted maintainer ID from this machine? [y/N]"
                if ($confirm -match '^(?i:y|yes)$') {
                    Remove-PersistedMaintainerId
                    Write-Host "Removed the persisted maintainer ID from this Windows user." -ForegroundColor Green
                }
            }
            "3" {
                try {
                    $generated = New-RandomMaintainerId
                    $result = Set-PersistedMaintainerId -RepoRoot $resolvedRepoRoot -Value $generated
                    Write-Host ("Rotated maintainer ID to {0}" -f $result.Value) -ForegroundColor Green
                    Write-Host ("Repo hash is now {0}" -f $result.Hash) -ForegroundColor Green
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                }
            }
            "4" {
                return
            }
            default {
                Write-Host "Invalid selection." -ForegroundColor Red
            }
        }
    }
}
