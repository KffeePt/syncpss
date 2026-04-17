[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\scripts\ps1\maintainer_id.ps1")

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Save-FileSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            Bytes  = $null
        }
    }

    return [pscustomobject]@{
        Exists = $true
        Bytes  = [System.IO.File]::ReadAllBytes($Path)
    }
}

function Restore-FileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][pscustomobject]$Snapshot
    )

    if ($Snapshot.Exists) {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes($Path, $Snapshot.Bytes)
        return
    }

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, (New-Utf8NoBomEncoding))
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedSubstring
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -like "*$ExpectedSubstring*") {
            return
        }
        throw "Expected an error containing '$ExpectedSubstring', but got: $($_.Exception.Message)"
    }

    throw "Expected an error containing '$ExpectedSubstring', but no error was thrown."
}

function Clear-MaintainerTestState {
    param(
        [Parameter(Mandatory = $true)][string]$EnvFilePath,
        [Parameter(Mandatory = $true)][string]$LegacyIdentityPath
    )

    Remove-Item Env:\SYNCPSS_MAINTAINER_ID -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $EnvFilePath) {
        Remove-Item -LiteralPath $EnvFilePath -Force
    }
    if (Test-Path -LiteralPath $LegacyIdentityPath) {
        Remove-Item -LiteralPath $LegacyIdentityPath -Force
    }
}

$tempRoot = Join-Path $PSScriptRoot (".maintainer-bootstrap-" + [guid]::NewGuid().ToString("N"))
$tempRepoRoot = Join-Path $tempRoot "repo"
$tempConfigRoot = Join-Path $tempRoot "config-root"
$originalConfigOverride = $env:SYNCPSS_MAINTAINER_CONFIG_DIR
$originalScopeOverride = $env:SYNCPSS_MAINTAINER_ENV_SCOPE
$env:SYNCPSS_MAINTAINER_CONFIG_DIR = $tempConfigRoot
$env:SYNCPSS_MAINTAINER_ENV_SCOPE = "Process"
$envFilePath = Get-MaintainerEnvFilePath
$legacyIdentityPath = Get-MaintainerLegacyIdentityPath
$envFileSnapshot = Save-FileSnapshot -Path $envFilePath
$legacyIdentitySnapshot = Save-FileSnapshot -Path $legacyIdentityPath
$originalProcessValue = $env:SYNCPSS_MAINTAINER_ID
$seed = "AbCd1234EfGh5678IjKl9012MnOp3456"
$expectedHash = Get-MaintainerIdHashValue -Seed $seed
$hashFilePath = Join-Path $tempRepoRoot "config\maintainer_id.sha256"

try {
    New-Item -ItemType Directory -Path (Join-Path $tempRepoRoot "config") -Force | Out-Null

    Clear-MaintainerTestState -EnvFilePath $envFilePath -LegacyIdentityPath $legacyIdentityPath
    Write-TextFile -Path $hashFilePath -Content ($expectedHash + "  SYNCPSS_MAINTAINER_ID`n")
    Write-TextFile -Path $legacyIdentityPath -Content ($seed + "`n")
    $resolved = Resolve-MaintainerIdSeed -RepoRoot $tempRepoRoot
    Assert-Equal -Actual $resolved -Expected $seed -Message "Legacy maintainer file should bootstrap the maintainer ID."
    Assert-Equal -Actual $env:SYNCPSS_MAINTAINER_ID -Expected $seed -Message "Bootstrap should persist the maintainer ID into the active environment."
    Assert-True -Condition (-not (Test-Path -LiteralPath $legacyIdentityPath)) -Message "Legacy maintainer file should be removed after a successful bootstrap."

    Clear-MaintainerTestState -EnvFilePath $envFilePath -LegacyIdentityPath $legacyIdentityPath
    Write-TextFile -Path $hashFilePath -Content ($expectedHash + "  SYNCPSS_MAINTAINER_ID`n")
    Write-TextFile -Path $envFilePath -Content ("export SYNCPSS_MAINTAINER_ID=" + $seed + "`n")
    $resolved = Resolve-MaintainerIdSeed -RepoRoot $tempRepoRoot
    Assert-Equal -Actual $resolved -Expected $seed -Message "Maintainer env file should bootstrap the maintainer ID."
    Assert-Equal -Actual $env:SYNCPSS_MAINTAINER_ID -Expected $seed -Message "Env-file bootstrap should persist the maintainer ID into the active environment."

    Clear-MaintainerTestState -EnvFilePath $envFilePath -LegacyIdentityPath $legacyIdentityPath
    Write-TextFile -Path $hashFilePath -Content ($expectedHash + "  SYNCPSS_MAINTAINER_ID`n")
    Write-TextFile -Path $envFilePath -Content "export SYNCPSS_MAINTAINER_ID=short`n"
    Assert-ThrowsLike -Action { Resolve-MaintainerIdSeed -RepoRoot $tempRepoRoot } -ExpectedSubstring "must contain only a 32-character maintainer ID"

    Clear-MaintainerTestState -EnvFilePath $envFilePath -LegacyIdentityPath $legacyIdentityPath
    Write-TextFile -Path $hashFilePath -Content "not-a-sha256  SYNCPSS_MAINTAINER_ID`n"
    Write-TextFile -Path $envFilePath -Content ("export SYNCPSS_MAINTAINER_ID=" + $seed + "`n")
    Assert-ThrowsLike -Action { Resolve-MaintainerIdSeed -RepoRoot $tempRepoRoot } -ExpectedSubstring "must contain a full 64-character SHA-256 hex digest"

    Clear-MaintainerTestState -EnvFilePath $envFilePath -LegacyIdentityPath $legacyIdentityPath
    Write-TextFile -Path $hashFilePath -Content ($expectedHash + "  SYNCPSS_MAINTAINER_ID`n")
    $resolved = Resolve-MaintainerIdSeed -RepoRoot $tempRepoRoot
    Assert-True -Condition ($null -eq $resolved) -Message "When only the repo hash exists, maintainer seed resolution should continue without a plaintext maintainer ID."

    Write-Host "maintainer bootstrap checks passed"
    exit 0
} finally {
    if ($null -eq $originalProcessValue) {
        Remove-Item Env:\SYNCPSS_MAINTAINER_ID -ErrorAction SilentlyContinue
    } else {
        $env:SYNCPSS_MAINTAINER_ID = $originalProcessValue
    }
    if ($null -eq $originalConfigOverride) {
        Remove-Item Env:\SYNCPSS_MAINTAINER_CONFIG_DIR -ErrorAction SilentlyContinue
    } else {
        $env:SYNCPSS_MAINTAINER_CONFIG_DIR = $originalConfigOverride
    }
    if ($null -eq $originalScopeOverride) {
        Remove-Item Env:\SYNCPSS_MAINTAINER_ENV_SCOPE -ErrorAction SilentlyContinue
    } else {
        $env:SYNCPSS_MAINTAINER_ENV_SCOPE = $originalScopeOverride
    }

    Restore-FileSnapshot -Path $envFilePath -Snapshot $envFileSnapshot
    Restore-FileSnapshot -Path $legacyIdentityPath -Snapshot $legacyIdentitySnapshot

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
