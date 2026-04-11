[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [switch]$SkipIfUnavailable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "maintainer_id.ps1")

$MasterFingerprintPath = "master_fingerprint.sha256"

function Get-EffectiveRepoRoot {
    param([string]$RequestedRepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRepoRoot)) {
        return (Resolve-Path -LiteralPath $RequestedRepoRoot).Path
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Maybe-Skip {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ($SkipIfUnavailable) {
        Write-Host $Message -ForegroundColor Yellow
        exit 0
    }

    throw $Message
}

function Get-RepoIdSeedOrNull {
    param([Parameter(Mandatory = $true)][string]$ResolvedRepoRoot)

    $current = Get-CurrentMaintainerId -RepoRoot $ResolvedRepoRoot
    if ($null -eq $current -or [string]::IsNullOrWhiteSpace($current.Value)) {
        return $null
    }

    return $current.Value
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

function Get-RepoIdSeedHash {
    param([Parameter(Mandatory = $true)][string]$Seed)

    return Get-Sha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Seed))
}

function Get-ReleaseMasterFingerprint {
    param([Parameter(Mandatory = $true)][string]$ResolvedRepoRoot)

    $assetFiles = @(
        "bin\syncpss-linux-x86_64",
        "bin\install",
        "bin\installer.sh",
        "bin\uninstall_syncpss.sh"
    ) | ForEach-Object { Join-Path $ResolvedRepoRoot $_ }

    $buffer = New-Object System.IO.MemoryStream
    try {
        foreach ($absolutePath in $assetFiles) {
            if (-not (Test-Path -LiteralPath $absolutePath)) {
                Maybe-Skip -Message "Skipping master fingerprint refresh because a required release asset is missing: $absolutePath"
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

function Set-ContentIfChanged {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = [System.IO.File]::ReadAllText($Path)
        if ($existing -eq $Content) {
            return $false
        }
    } else {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }
    }

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    return $true
}

$resolvedRepoRoot = Get-EffectiveRepoRoot -RequestedRepoRoot $RepoRoot
$fingerprint = Get-ReleaseMasterFingerprint -ResolvedRepoRoot $resolvedRepoRoot
$content = $fingerprint + "  master_fingerprint.sha256"

$rootFingerprintPath = Join-Path $resolvedRepoRoot $MasterFingerprintPath
$binFingerprintPath = Join-Path (Join-Path $resolvedRepoRoot "bin") $MasterFingerprintPath

$binChanged = Set-ContentIfChanged -Path $binFingerprintPath -Content $content
$rootChanged = $false
$updatedRootFingerprint = $false
$repoIdSeed = Get-RepoIdSeedOrNull -ResolvedRepoRoot $resolvedRepoRoot

if (-not [string]::IsNullOrWhiteSpace($repoIdSeed)) {
    $repoIdSeedHash = Get-RepoIdSeedHash -Seed $repoIdSeed
    $expectedRepoIdHash = Get-ExpectedMaintainerIdHash -RepoRoot $resolvedRepoRoot
    if ($repoIdSeedHash -eq $expectedRepoIdHash) {
        $rootChanged = Set-ContentIfChanged -Path $rootFingerprintPath -Content $content
        $updatedRootFingerprint = $true
    } else {
        Maybe-Skip -Message "Skipping repo-root master fingerprint refresh because SYNCPSS_MAINTAINER_ID hash mismatch. Expected $expectedRepoIdHash but found $repoIdSeedHash. The staged bin fingerprint was still refreshed."
    }
} else {
    if (-not $SkipIfUnavailable) {
        Maybe-Skip -Message "Skipping repo-root master fingerprint refresh because SYNCPSS_MAINTAINER_ID is not configured. The staged bin fingerprint was still refreshed."
    }
}

if ($updatedRootFingerprint) {
    if ($rootChanged -or $binChanged) {
        Write-Host "Updated release and staged master fingerprints: $fingerprint" -ForegroundColor Green
    } else {
        Write-Host "Release and staged master fingerprints are unchanged." -ForegroundColor DarkGray
    }
} else {
    if ($binChanged) {
        Write-Host "Updated staged bin master fingerprint: $fingerprint" -ForegroundColor Green
    } else {
        Write-Host "Staged bin master fingerprint is unchanged." -ForegroundColor DarkGray
    }
}
