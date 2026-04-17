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

function Get-RequiredObjectProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        throw "$Context is missing required property '$PropertyName'."
    }

    return $property.Value
}

function ConvertTo-StringArray {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { [string]$_ })
    }

    throw "$Context must be a JSON array of strings."
}

function ConvertTo-NormalizedHexIdentifier {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][int]$ExpectedLength,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $trimmed = if ($null -eq $Value) { "" } else { $Value.Trim() }
    if ($trimmed -notmatch ("^[0-9a-fA-F]{" + $ExpectedLength + "}$")) {
        throw "$Context must be exactly $ExpectedLength hexadecimal characters."
    }

    return $trimmed.ToUpperInvariant()
}

function ConvertTo-NormalizedHexArray {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$ExpectedLength,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $normalized = @(
        ConvertTo-StringArray -Value $Value -Context $Context |
            ForEach-Object { ConvertTo-NormalizedHexIdentifier -Value $_ -ExpectedLength $ExpectedLength -Context $Context }
    )

    return [string[]]@($normalized | Sort-Object -Unique)
}

function Format-IdentifierList {
    param([AllowNull()][string[]]$Values)

    $resolvedValues = [string[]]@($Values)
    if ($null -eq $Values -or $resolvedValues.Count -eq 0) {
        return "<none>"
    }

    return ($resolvedValues -join ", ")
}

function Get-ReleaseSigningPolicyPath {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:SYNCPSS_SIGNING_POLICY_PATH)) {
        return (Resolve-Path -LiteralPath $env:SYNCPSS_SIGNING_POLICY_PATH).Path
    }

    return (Join-Path $RepoRoot "config\signing_policy.json")
}

function Read-ReleaseSigningPolicy {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $policyPath = Get-ReleaseSigningPolicyPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $policyPath)) {
        throw "Signing policy file is missing at '$policyPath'."
    }

    try {
        $policyDocument = [System.IO.File]::ReadAllText($policyPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    } catch {
        throw "Signing policy file '$policyPath' is not valid JSON."
    }

    $gpgPolicy = Get-RequiredObjectProperty -Object $policyDocument -PropertyName "gpg" -Context "Signing policy file '$policyPath'"
    $windowsCodeSignPolicy = Get-RequiredObjectProperty -Object $policyDocument -PropertyName "windows_codesign" -Context "Signing policy file '$policyPath'"

    $activeReleaseFingerprint = ConvertTo-NormalizedHexIdentifier `
        -Value (Get-RequiredObjectProperty -Object $gpgPolicy -PropertyName "active_release_fingerprint" -Context "Signing policy gpg section") `
        -ExpectedLength 40 `
        -Context "Signing policy gpg.active_release_fingerprint"
    $allowedReleaseFingerprints = [string[]]@(ConvertTo-NormalizedHexArray `
        -Value (Get-RequiredObjectProperty -Object $gpgPolicy -PropertyName "allowed_release_fingerprints" -Context "Signing policy gpg section") `
        -ExpectedLength 40 `
        -Context "Signing policy gpg.allowed_release_fingerprints")
    $verifyOnlyFingerprints = [string[]]@(ConvertTo-NormalizedHexArray `
        -Value (Get-RequiredObjectProperty -Object $gpgPolicy -PropertyName "verify_only_fingerprints" -Context "Signing policy gpg section") `
        -ExpectedLength 40 `
        -Context "Signing policy gpg.verify_only_fingerprints")

    if ($allowedReleaseFingerprints.Count -eq 0) {
        throw "Signing policy gpg.allowed_release_fingerprints must list at least one release fingerprint."
    }
    if ($allowedReleaseFingerprints -notcontains $activeReleaseFingerprint) {
        throw "Signing policy gpg.active_release_fingerprint must also be listed in gpg.allowed_release_fingerprints."
    }
    if ($verifyOnlyFingerprints -contains $activeReleaseFingerprint) {
        throw "Signing policy gpg.verify_only_fingerprints must not contain the active release fingerprint."
    }
    if (@($allowedReleaseFingerprints | Where-Object { $verifyOnlyFingerprints -contains $_ }).Count -gt 0) {
        throw "Signing policy gpg.allowed_release_fingerprints and gpg.verify_only_fingerprints must not overlap."
    }

    $githubAccount = [string](Get-RequiredObjectProperty -Object $gpgPolicy -PropertyName "github_account" -Context "Signing policy gpg section")
    if ([string]::IsNullOrWhiteSpace($githubAccount)) {
        throw "Signing policy gpg.github_account must not be empty."
    }

    $windowsCodeSignPhase = ([string](Get-RequiredObjectProperty -Object $windowsCodeSignPolicy -PropertyName "phase" -Context "Signing policy windows_codesign section")).Trim().ToLowerInvariant()
    if ($windowsCodeSignPhase -notin @("phase1", "phase2")) {
        throw "Signing policy windows_codesign.phase must be either 'phase1' or 'phase2'."
    }

    $windowsCodeSignRequired = Get-RequiredObjectProperty -Object $windowsCodeSignPolicy -PropertyName "required" -Context "Signing policy windows_codesign section"
    if ($windowsCodeSignRequired -isnot [bool]) {
        throw "Signing policy windows_codesign.required must be a JSON boolean."
    }

    $windowsCodeSignAllowedThumbprints = [string[]]@(ConvertTo-NormalizedHexArray `
        -Value (Get-RequiredObjectProperty -Object $windowsCodeSignPolicy -PropertyName "allowed_thumbprints" -Context "Signing policy windows_codesign section") `
        -ExpectedLength 40 `
        -Context "Signing policy windows_codesign.allowed_thumbprints")
    $windowsCodeSignSubjectHint = [string](Get-RequiredObjectProperty -Object $windowsCodeSignPolicy -PropertyName "subject_hint" -Context "Signing policy windows_codesign section")

    return [pscustomobject]@{
        Path = $policyPath
        Gpg = [pscustomobject]@{
            ActiveReleaseFingerprint = $activeReleaseFingerprint
            AllowedReleaseFingerprints = $allowedReleaseFingerprints
            VerifyOnlyFingerprints = $verifyOnlyFingerprints
            GitHubAccount = $githubAccount.Trim()
            ActiveReleaseFingerprintIsPlaceholder = ($activeReleaseFingerprint -eq "0000000000000000000000000000000000000000")
        }
        WindowsCodeSign = [pscustomobject]@{
            Phase = $windowsCodeSignPhase
            Required = [bool]$windowsCodeSignRequired
            AllowedThumbprints = $windowsCodeSignAllowedThumbprints
            SubjectHint = $windowsCodeSignSubjectHint.Trim()
        }
    }
}

function Write-ReleaseSigningPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ActiveReleaseFingerprint,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllowedReleaseFingerprints,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$VerifyOnlyFingerprints,
        [Parameter(Mandatory = $true)][string]$GitHubAccount,
        [Parameter(Mandatory = $true)][string]$WindowsCodeSignPhase,
        [Parameter(Mandatory = $true)][bool]$WindowsCodeSignRequired,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$WindowsCodeSignAllowedThumbprints,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$WindowsCodeSignSubjectHint
    )

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $normalizedActiveFingerprint = ConvertTo-NormalizedHexIdentifier -Value $ActiveReleaseFingerprint -ExpectedLength 40 -Context "Release signing fingerprint"
    $normalizedAllowedFingerprints = [string[]]@(ConvertTo-NormalizedHexArray -Value $AllowedReleaseFingerprints -ExpectedLength 40 -Context "Release signing allowlist")
    $normalizedVerifyOnlyFingerprints = [string[]]@(ConvertTo-NormalizedHexArray -Value $VerifyOnlyFingerprints -ExpectedLength 40 -Context "Release signing verify-only history")
    $normalizedAllowedThumbprints = [string[]]@(ConvertTo-NormalizedHexArray -Value $WindowsCodeSignAllowedThumbprints -ExpectedLength 40 -Context "Windows code signing allowlist")

    if ($normalizedAllowedFingerprints.Count -eq 0) {
        throw "Release signing allowlist must contain at least one fingerprint."
    }
    if ($normalizedAllowedFingerprints -notcontains $normalizedActiveFingerprint) {
        throw "Release signing allowlist must contain the active release fingerprint."
    }
    if ($normalizedVerifyOnlyFingerprints -contains $normalizedActiveFingerprint) {
        throw "Verify-only history must not contain the active release fingerprint."
    }
    if (@($normalizedAllowedFingerprints | Where-Object { $normalizedVerifyOnlyFingerprints -contains $_ }).Count -gt 0) {
        throw "Release signing allowlist and verify-only history must not overlap."
    }

    $trimmedGitHubAccount = $GitHubAccount.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedGitHubAccount)) {
        throw "GitHub account must not be empty."
    }

    $normalizedWindowsCodeSignPhase = $WindowsCodeSignPhase.Trim().ToLowerInvariant()
    if ($normalizedWindowsCodeSignPhase -notin @("phase1", "phase2")) {
        throw "Windows code-signing phase must be either 'phase1' or 'phase2'."
    }

    $policyDocument = [ordered]@{
        gpg = [ordered]@{
            active_release_fingerprint = $normalizedActiveFingerprint
            allowed_release_fingerprints = $normalizedAllowedFingerprints
            verify_only_fingerprints = $normalizedVerifyOnlyFingerprints
            github_account = $trimmedGitHubAccount
        }
        windows_codesign = [ordered]@{
            phase = $normalizedWindowsCodeSignPhase
            required = [bool]$WindowsCodeSignRequired
            allowed_thumbprints = $normalizedAllowedThumbprints
            subject_hint = $WindowsCodeSignSubjectHint.Trim()
        }
    }

    $policyPath = Get-ReleaseSigningPolicyPath -RepoRoot $resolvedRepoRoot
    [void](Set-ContentIfChanged -Path $policyPath -Content (($policyDocument | ConvertTo-Json -Depth 6) + "`n"))
    return Read-ReleaseSigningPolicy -RepoRoot $resolvedRepoRoot
}

function Get-RepoGitSigningKey {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $overrideItem = Get-Item -Path Env:\SYNCPSS_RELEASE_GIT_SIGNINGKEY -ErrorAction SilentlyContinue
    if ($null -ne $overrideItem) {
        $overrideValue = ([string]$overrideItem.Value).Trim()
        if ($overrideValue -eq "__unset__") {
            return ""
        }
        return $overrideValue
    }

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $signingKey = & git -C $resolvedRepoRoot config --get user.signingkey 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return (($signingKey | Out-String).Trim())
}

function Set-RepoGitSigningKey {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $normalizedFingerprint = ConvertTo-NormalizedHexIdentifier -Value $Fingerprint -ExpectedLength 40 -Context "Git signing fingerprint"
    & git -C $resolvedRepoRoot config user.signingkey $normalizedFingerprint
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update git user.signingkey for '$resolvedRepoRoot'."
    }

    return $normalizedFingerprint
}

function Get-GpgExecutablePath {
    if (-not [string]::IsNullOrWhiteSpace($env:SYNCPSS_GPG_EXECUTABLE)) {
        $overridePath = $env:SYNCPSS_GPG_EXECUTABLE.Trim()
        if (-not (Test-Path -LiteralPath $overridePath)) {
            throw "Configured GPG executable override '$overridePath' does not exist."
        }

        return (Resolve-Path -LiteralPath $overridePath).Path
    }

    $gpg = Get-Command gpg -ErrorAction SilentlyContinue
    if ($null -ne $gpg) {
        return $gpg.Source
    }

    $candidatePaths = @(
        (Join-Path ${env:ProgramFiles} "GnuPG\bin\gpg.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "GnuPG\bin\gpg.exe"),
        "C:\Program Files\Git\usr\bin\gpg.exe"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            return (Resolve-Path -LiteralPath $candidatePath).Path
        }
    }

    throw "gpg is required for release signing. Install Gpg4win on Windows and retry."
}

function Get-GpgSecretKeyFingerprints {
    param(
        [Parameter(Mandatory = $true)][string]$GpgProgram,
        [AllowEmptyString()][string]$KeySpecifier = ""
    )

    $listArgs = @("--list-secret-keys", "--keyid-format=long", "--with-colons")
    if (-not [string]::IsNullOrWhiteSpace($KeySpecifier)) {
        $listArgs += $KeySpecifier
    }

    $secretKeyOutput = & $GpgProgram @listArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    $fingerprints = New-Object System.Collections.Generic.List[string]
    $awaitingFingerprint = $false
    foreach ($line in $secretKeyOutput) {
        $text = (($line | Out-String).Trim())
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text.StartsWith("sec:")) {
            $awaitingFingerprint = $true
            continue
        }

        if ($awaitingFingerprint -and $text.StartsWith("fpr:")) {
            $parts = $text.Split(':')
            if ($parts.Length -ge 10 -and -not [string]::IsNullOrWhiteSpace($parts[9])) {
                $fingerprint = ConvertTo-NormalizedHexIdentifier -Value $parts[9].Trim() -ExpectedLength 40 -Context "GPG secret key fingerprint"
                if (-not $fingerprints.Contains($fingerprint)) {
                    [void]$fingerprints.Add($fingerprint)
                }
                $awaitingFingerprint = $false
            }
        }
    }

    return [string[]]@($fingerprints.ToArray())
}

function Get-ReleaseIdentityState {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $current = Get-CurrentMaintainerId -RepoRoot $resolvedRepoRoot
    $expectedHash = Get-ExpectedMaintainerIdHash -RepoRoot $resolvedRepoRoot
    $currentValue = if ($null -ne $current) { $current.Value } else { $null }
    $currentSource = if ($null -ne $current) { $current.Source } else { "<none>" }
    $configuredSigningKey = Get-RepoGitSigningKey -RepoRoot $resolvedRepoRoot
    $policyPath = Get-ReleaseSigningPolicyPath -RepoRoot $resolvedRepoRoot
    $state = [ordered]@{
        RepoRoot = $resolvedRepoRoot
        CurrentMaintainerId = $currentValue
        CurrentMaintainerSource = $currentSource
        ExpectedMaintainerHash = $expectedHash
        PolicyPath = $policyPath
        PolicyError = ""
        ActiveReleaseFingerprint = ""
        AllowedReleaseFingerprints = @()
        VerifyOnlyFingerprints = @()
        GitHubAccount = ""
        ConfiguredSigningKey = $configuredSigningKey
        ConfiguredSigningKeyFingerprints = @()
        GpgProgram = ""
        GpgError = ""
        DetectedFingerprints = @()
        Status = "warning"
        StatusMessage = "Release identity status is incomplete."
    }

    try {
        $policy = Read-ReleaseSigningPolicy -RepoRoot $resolvedRepoRoot
        $state.ActiveReleaseFingerprint = $policy.Gpg.ActiveReleaseFingerprint
        $state.AllowedReleaseFingerprints = $policy.Gpg.AllowedReleaseFingerprints
        $state.VerifyOnlyFingerprints = $policy.Gpg.VerifyOnlyFingerprints
        $state.GitHubAccount = $policy.Gpg.GitHubAccount
        if ($policy.Gpg.ActiveReleaseFingerprintIsPlaceholder) {
            $state.StatusMessage = "Replace the placeholder release signing fingerprint in config\signing_policy.json."
        }
    } catch {
        $state.PolicyError = $_.Exception.Message
        $state.StatusMessage = $_.Exception.Message
        return [pscustomobject]$state
    }

    try {
        $state.GpgProgram = Get-GpgExecutablePath
        $state.DetectedFingerprints = [string[]]@(Get-GpgSecretKeyFingerprints -GpgProgram $state.GpgProgram)
    } catch {
        $state.GpgError = $_.Exception.Message
        $state.StatusMessage = $_.Exception.Message
        return [pscustomobject]$state
    }

    if ($state.ActiveReleaseFingerprint -eq "0000000000000000000000000000000000000000") {
        return [pscustomobject]$state
    }
    if ([string[]]@($state.DetectedFingerprints).Count -eq 0) {
        $state.StatusMessage = "No Windows GPG secret keys are visible yet."
        return [pscustomobject]$state
    }
    if ($state.DetectedFingerprints -notcontains $state.ActiveReleaseFingerprint) {
        $state.StatusMessage = "The active release signing fingerprint is not present in the Windows secret keyring."
        return [pscustomobject]$state
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredSigningKey)) {
        $state.ConfiguredSigningKeyFingerprints = [string[]]@(Get-GpgSecretKeyFingerprints -GpgProgram $state.GpgProgram -KeySpecifier $configuredSigningKey)
        if ($state.ConfiguredSigningKeyFingerprints.Count -eq 0) {
            $state.StatusMessage = "git user.signingkey is set, but it does not resolve to a usable Windows secret key."
            return [pscustomobject]$state
        }
        if ($state.ConfiguredSigningKeyFingerprints -notcontains $state.ActiveReleaseFingerprint) {
            $state.StatusMessage = "git user.signingkey resolves to a different fingerprint than the active release signer."
            return [pscustomobject]$state
        }
    }

    $state.Status = "pass"
    $state.StatusMessage = "The active release signing fingerprint is present and ready on this Windows machine."
    return [pscustomobject]$state
}

function Prompt-ReleaseSigningKeyChoice {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    $state = Get-ReleaseIdentityState -RepoRoot $RepoRoot
    $candidates = [string[]]@($state.DetectedFingerprints)
    if ($candidates.Count -eq 0) {
        throw "No usable Windows GPG secret keys were detected. Import the release signing subkey first."
    }

    $defaultIndex = 1
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        if ($candidates[$i] -eq $state.ActiveReleaseFingerprint) {
            $defaultIndex = $i + 1
            break
        }
    }

    Write-Host ""
    Write-Host "Detected Windows GPG secret keys" -ForegroundColor Yellow
    Write-Host ("Resolved gpg.exe: {0}" -f $state.GpgProgram) -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $tags = New-Object System.Collections.Generic.List[string]
        if ($candidates[$i] -eq $state.ActiveReleaseFingerprint) {
            [void]$tags.Add("active")
        }
        if ($state.ConfiguredSigningKeyFingerprints -contains $candidates[$i]) {
            [void]$tags.Add("git")
        }

        $label = $candidates[$i]
        if ($tags.Count -gt 0) {
            $label = "$label [" + ($tags -join ", ") + "]"
        }

        Write-Host ("  [{0}] {1}" -f ($i + 1), $label)
    }
    Write-Host "  [C] Cancel"

    while ($true) {
        $selection = Read-Host ("{0} [{1}]" -f $Prompt, $defaultIndex)
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return $candidates[$defaultIndex - 1]
        }
        if ($selection -match '^(?i:c|cancel)$') {
            return $null
        }
        if ($selection -match '^\d+$') {
            $index = [int]$selection
            if ($index -ge 1 -and $index -le $candidates.Count) {
                return $candidates[$index - 1]
            }
        }

        Write-Host "Choose one of the listed numbers or C to cancel." -ForegroundColor Red
    }
}

function Set-ActiveReleaseSigningKey {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$SelectedFingerprint,
        [switch]$RotateHistory
    )

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $normalizedFingerprint = ConvertTo-NormalizedHexIdentifier -Value $SelectedFingerprint -ExpectedLength 40 -Context "Release signing fingerprint"
    $policy = Read-ReleaseSigningPolicy -RepoRoot $resolvedRepoRoot
    $gpgProgram = Get-GpgExecutablePath
    $detectedFingerprints = [string[]]@(Get-GpgSecretKeyFingerprints -GpgProgram $gpgProgram)
    if ($detectedFingerprints.Count -eq 0) {
        throw "No usable Windows GPG secret keys were detected in '$gpgProgram'."
    }
    if ($detectedFingerprints -notcontains $normalizedFingerprint) {
        throw "Selected fingerprint '$normalizedFingerprint' is not currently available in the Windows secret keyring. Detected secret keys: $(Format-IdentifierList -Values $detectedFingerprints)."
    }

    $historyAdded = New-Object System.Collections.Generic.List[string]
    $verifyOnlyFingerprints = New-Object System.Collections.Generic.List[string]
    foreach ($fingerprint in $policy.Gpg.VerifyOnlyFingerprints) {
        if ($fingerprint -ne $normalizedFingerprint -and -not $verifyOnlyFingerprints.Contains($fingerprint)) {
            [void]$verifyOnlyFingerprints.Add($fingerprint)
        }
    }

    if ($RotateHistory) {
        foreach ($fingerprint in (@($policy.Gpg.ActiveReleaseFingerprint) + @($policy.Gpg.AllowedReleaseFingerprints))) {
            if ([string]::IsNullOrWhiteSpace($fingerprint)) {
                continue
            }
            if ($fingerprint -eq $normalizedFingerprint) {
                continue
            }
            if ($fingerprint -eq "0000000000000000000000000000000000000000") {
                continue
            }
            if (-not $verifyOnlyFingerprints.Contains($fingerprint)) {
                [void]$verifyOnlyFingerprints.Add($fingerprint)
                [void]$historyAdded.Add($fingerprint)
            }
        }
    }

    $updatedPolicy = Write-ReleaseSigningPolicy `
        -RepoRoot $resolvedRepoRoot `
        -ActiveReleaseFingerprint $normalizedFingerprint `
        -AllowedReleaseFingerprints @($normalizedFingerprint) `
        -VerifyOnlyFingerprints ([string[]]$verifyOnlyFingerprints.ToArray()) `
        -GitHubAccount $policy.Gpg.GitHubAccount `
        -WindowsCodeSignPhase $policy.WindowsCodeSign.Phase `
        -WindowsCodeSignRequired $policy.WindowsCodeSign.Required `
        -WindowsCodeSignAllowedThumbprints $policy.WindowsCodeSign.AllowedThumbprints `
        -WindowsCodeSignSubjectHint $policy.WindowsCodeSign.SubjectHint
    $configuredSigningKey = Set-RepoGitSigningKey -RepoRoot $resolvedRepoRoot -Fingerprint $normalizedFingerprint

    return [pscustomobject]@{
        Fingerprint = $normalizedFingerprint
        PreviousActiveFingerprint = $policy.Gpg.ActiveReleaseFingerprint
        HistoryAddedFingerprints = [string[]]$historyAdded.ToArray()
        Policy = $updatedPolicy
        GpgProgram = $gpgProgram
        GitSigningKey = $configuredSigningKey
    }
}

function Invoke-ReleaseSigningReadinessCheck {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot
    $releaseScriptPath = Join-Path $PSScriptRoot "release.ps1"
    if (-not (Test-Path -LiteralPath $releaseScriptPath)) {
        throw "Release script is missing at '$releaseScriptPath'."
    }

    $originalRepoOverride = $env:SYNCPSS_RELEASE_REPO_ROOT
    $env:SYNCPSS_RELEASE_REPO_ROOT = $resolvedRepoRoot
    try {
        & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $releaseScriptPath -SigningReadiness | Out-Host
        return [int]$LASTEXITCODE
    } finally {
        if ($null -eq $originalRepoOverride) {
            Remove-Item Env:\SYNCPSS_RELEASE_REPO_ROOT -ErrorAction SilentlyContinue
        } else {
            $env:SYNCPSS_RELEASE_REPO_ROOT = $originalRepoOverride
        }
    }
}

function Show-ReleaseIdentityManager {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = Resolve-SyncpssRepoRoot -RepoRoot $RepoRoot

    while ($true) {
        $state = Get-ReleaseIdentityState -RepoRoot $resolvedRepoRoot
        $statusColor = if ($state.Status -eq "pass") { "Green" } else { "Yellow" }

        Write-Host ""
        Write-Host "syncpss release identity manager" -ForegroundColor Yellow
        Write-Host ("Current maintainer ID:    {0}" -f (Format-MaintainerIdForDisplay -Value $state.CurrentMaintainerId)) -ForegroundColor Cyan
        Write-Host ("Maintainer source:        {0}" -f $state.CurrentMaintainerSource) -ForegroundColor Cyan
        Write-Host ("Repo maintainer hash:     {0}" -f $state.ExpectedMaintainerHash) -ForegroundColor Cyan
        Write-Host ("Signing policy:           {0}" -f $state.PolicyPath) -ForegroundColor Cyan
        Write-Host ("Active release signer:    {0}" -f $(if ([string]::IsNullOrWhiteSpace($state.ActiveReleaseFingerprint)) { "<unavailable>" } else { $state.ActiveReleaseFingerprint })) -ForegroundColor Cyan
        Write-Host ("Allowed release signers:  {0}" -f (Format-IdentifierList -Values $state.AllowedReleaseFingerprints)) -ForegroundColor Cyan
        Write-Host ("Verify-only signers:      {0}" -f (Format-IdentifierList -Values $state.VerifyOnlyFingerprints)) -ForegroundColor Cyan
        Write-Host ("git user.signingkey:      {0}" -f $(if ([string]::IsNullOrWhiteSpace($state.ConfiguredSigningKey)) { "<not set>" } else { $state.ConfiguredSigningKey })) -ForegroundColor Cyan
        Write-Host ("Resolved gpg.exe:         {0}" -f $(if ([string]::IsNullOrWhiteSpace($state.GpgProgram)) { "<not found>" } else { $state.GpgProgram })) -ForegroundColor Cyan
        Write-Host ("Detected secret keys:     {0}" -f (Format-IdentifierList -Values $state.DetectedFingerprints)) -ForegroundColor Cyan
        Write-Host ("Quick release status:     {0}" -f $state.StatusMessage) -ForegroundColor $statusColor
        Write-Host ""
        Write-Host "  [1] Set maintainer ID"
        Write-Host "  [2] Rotate maintainer ID"
        Write-Host "  [3] Remove maintainer ID from this Windows user"
        Write-Host "  [4] Set the active release signing key from detected Windows GPG secret keys"
        Write-Host "  [5] Rotate the release signing key and keep the previous key for verify-only history"
        Write-Host "  [6] Show the full signing readiness report"
        Write-Host "  [7] Exit"

        $selection = Read-Host "Choose an option [7]"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            $selection = "7"
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
                try {
                    $generated = New-RandomMaintainerId
                    $result = Set-PersistedMaintainerId -RepoRoot $resolvedRepoRoot -Value $generated
                    Write-Host ("Rotated maintainer ID to {0}" -f $result.Value) -ForegroundColor Green
                    Write-Host ("Repo hash is now {0}" -f $result.Hash) -ForegroundColor Green
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                }
            }
            "3" {
                $confirm = Read-Host "Remove the persisted maintainer ID from this machine? [y/N]"
                if ($confirm -match '^(?i:y|yes)$') {
                    Remove-PersistedMaintainerId
                    Write-Host "Removed the persisted maintainer ID from this Windows user." -ForegroundColor Green
                }
            }
            "4" {
                try {
                    $selectedFingerprint = Prompt-ReleaseSigningKeyChoice -RepoRoot $resolvedRepoRoot -Prompt "Choose the active release signing key"
                    if ($null -eq $selectedFingerprint) {
                        Write-Host "Release signing key update canceled." -ForegroundColor Yellow
                        continue
                    }

                    $result = Set-ActiveReleaseSigningKey -RepoRoot $resolvedRepoRoot -SelectedFingerprint $selectedFingerprint
                    Write-Host ("Active release signing key set to {0}" -f $result.Fingerprint) -ForegroundColor Green
                    Write-Host ("git user.signingkey was updated to {0}" -f $result.GitSigningKey) -ForegroundColor Green
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                }
            }
            "5" {
                try {
                    $selectedFingerprint = Prompt-ReleaseSigningKeyChoice -RepoRoot $resolvedRepoRoot -Prompt "Choose the new active release signing key"
                    if ($null -eq $selectedFingerprint) {
                        Write-Host "Release signing key rotation canceled." -ForegroundColor Yellow
                        continue
                    }

                    $result = Set-ActiveReleaseSigningKey -RepoRoot $resolvedRepoRoot -SelectedFingerprint $selectedFingerprint -RotateHistory
                    Write-Host ("Active release signing key rotated to {0}" -f $result.Fingerprint) -ForegroundColor Green
                    if ($result.HistoryAddedFingerprints.Count -gt 0) {
                        Write-Host ("Verify-only history now includes: {0}" -f (Format-IdentifierList -Values $result.HistoryAddedFingerprints)) -ForegroundColor Green
                    } else {
                        Write-Host "No additional verify-only fingerprints needed to be recorded." -ForegroundColor Green
                    }
                    Write-Host ("git user.signingkey was updated to {0}" -f $result.GitSigningKey) -ForegroundColor Green
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                }
            }
            "6" {
                try {
                    [void](Invoke-ReleaseSigningReadinessCheck -RepoRoot $resolvedRepoRoot)
                } catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                }
                [void](Read-Host "Press Enter to return to the manager")
            }
            "7" {
                return
            }
            default {
                Write-Host "Invalid selection." -ForegroundColor Red
            }
        }
    }
}

function Show-MaintainerIdManager {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    Show-ReleaseIdentityManager -RepoRoot $RepoRoot
}
