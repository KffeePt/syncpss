[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\scripts\ps1\maintainer_id.ps1")

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
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

function New-SigningPolicyJson {
    param(
        [Parameter(Mandatory = $true)][string]$ActiveFingerprint,
        [Parameter(Mandatory = $true)][string[]]$AllowedFingerprints,
        [string[]]$VerifyOnlyFingerprints = @()
    )

    $policy = [ordered]@{
        gpg = [ordered]@{
            active_release_fingerprint = $ActiveFingerprint
            allowed_release_fingerprints = $AllowedFingerprints
            verify_only_fingerprints = $VerifyOnlyFingerprints
            github_account = "KffeePt"
        }
        windows_codesign = [ordered]@{
            phase = "phase2"
            required = $false
            allowed_thumbprints = @()
            subject_hint = ""
        }
    }

    return ($policy | ConvertTo-Json -Depth 6)
}

$oldFingerprint = "1111111111111111111111111111111111111111"
$newFingerprint = "2222222222222222222222222222222222222222"
$historicFingerprint = "3333333333333333333333333333333333333333"
$missingFingerprint = "4444444444444444444444444444444444444444"
$tempRoot = Join-Path $PSScriptRoot (".release-identity-" + [guid]::NewGuid().ToString("N"))
$repoRoot = Join-Path $tempRoot "repo"
$policyPath = Join-Path $repoRoot "config\signing_policy.json"
$fakeGpgPath = Join-Path $tempRoot "fake_gpg.cmd"
$originalGpgOverride = $env:SYNCPSS_GPG_EXECUTABLE

try {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot "config") -Force | Out-Null
    & git init $repoRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize the temporary git repo."
    }

    Write-TextFile -Path $policyPath -Content ((New-SigningPolicyJson -ActiveFingerprint $oldFingerprint -AllowedFingerprints @($oldFingerprint) -VerifyOnlyFingerprints @($historicFingerprint)) + "`n")
    Write-TextFile -Path $fakeGpgPath -Content @"
@echo off
setlocal EnableExtensions
if /I "%~1"=="--list-secret-keys" goto list
echo unsupported fake gpg invocation 1>&2
exit /b 1

:list
echo sec:u:255:22:::::::scSC:
echo fpr:::::::::${oldFingerprint}:
echo sec:u:255:22:::::::scSC:
echo fpr:::::::::${newFingerprint}:
exit /b 0
"@

    $env:SYNCPSS_GPG_EXECUTABLE = $fakeGpgPath

    $result = Set-ActiveReleaseSigningKey -RepoRoot $repoRoot -SelectedFingerprint $newFingerprint -RotateHistory
    $policy = Read-ReleaseSigningPolicy -RepoRoot $repoRoot
    $gitSigningKey = & git -C $repoRoot config --get user.signingkey

    Assert-Equal -Actual $policy.Gpg.ActiveReleaseFingerprint -Expected $newFingerprint -Message "Release key rotation should set the new active fingerprint."
    Assert-True -Condition ($policy.Gpg.AllowedReleaseFingerprints.Count -eq 1 -and $policy.Gpg.AllowedReleaseFingerprints[0] -eq $newFingerprint) -Message "Release key rotation should collapse the allowlist to the new active fingerprint."
    Assert-True -Condition ($policy.Gpg.VerifyOnlyFingerprints -contains $oldFingerprint) -Message "Release key rotation should keep the previous active fingerprint for verify-only history."
    Assert-True -Condition ($policy.Gpg.VerifyOnlyFingerprints -contains $historicFingerprint) -Message "Release key rotation should preserve pre-existing verify-only history."
    Assert-True -Condition (-not ($policy.Gpg.VerifyOnlyFingerprints -contains $newFingerprint)) -Message "Verify-only history must not contain the new active fingerprint."
    Assert-Equal -Actual $gitSigningKey.Trim().ToUpperInvariant() -Expected $newFingerprint -Message "Release key rotation should sync git user.signingkey for the repo."
    Assert-True -Condition ($result.HistoryAddedFingerprints -contains $oldFingerprint) -Message "Release key rotation should report the previous active fingerprint as history that was added."

    Assert-ThrowsLike -Action {
        Set-ActiveReleaseSigningKey -RepoRoot $repoRoot -SelectedFingerprint $missingFingerprint
    } -ExpectedSubstring "is not currently available in the Windows secret keyring"

    Write-Host "release identity manager checks passed"
} finally {
    if ($null -eq $originalGpgOverride) {
        Remove-Item Env:\SYNCPSS_GPG_EXECUTABLE -ErrorAction SilentlyContinue
    } else {
        $env:SYNCPSS_GPG_EXECUTABLE = $originalGpgOverride
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
