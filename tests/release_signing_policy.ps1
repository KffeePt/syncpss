[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ExpectedSubstring,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Text -notlike "*$ExpectedSubstring*") {
        throw "$Message`nExpected to find: $ExpectedSubstring`nActual output:`n$Text"
    }
}

function New-SigningPolicyJson {
    param(
        [Parameter(Mandatory = $true)][string]$ActiveFingerprint,
        [Parameter(Mandatory = $true)][string[]]$AllowedFingerprints,
        [string[]]$VerifyOnlyFingerprints = @(),
        [bool]$WindowsCodeSignRequired = $false,
        [string[]]$AllowedThumbprints = @(),
        [string]$SubjectHint = ""
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
            required = $WindowsCodeSignRequired
            allowed_thumbprints = $AllowedThumbprints
            subject_hint = $SubjectHint
        }
    }

    return ($policy | ConvertTo-Json -Depth 6)
}

function Invoke-ReadinessCheck {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseScriptPath,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$PolicyPath,
        [Parameter(Mandatory = $true)][string]$PolicyJson,
        [Parameter(Mandatory = $true)][string]$FakeGpgPath,
        [string]$AllFingerprints = "",
        [string]$MatchFingerprints = "",
        [string]$WrongFingerprints = "",
        [string]$ConfiguredSigningKey = "",
        [string]$AuthenticodeStatus = "",
        [string]$AuthenticodeThumbprint = "",
        [string]$AuthenticodeSubject = ""
    )

    Write-TextFile -Path $PolicyPath -Content ($PolicyJson + "`n")

    $overrides = @{
        SYNCPSS_RELEASE_REPO_ROOT = $RepoRoot
        SYNCPSS_SIGNING_POLICY_PATH = $PolicyPath
        SYNCPSS_GPG_EXECUTABLE = $FakeGpgPath
        SYNCPSS_TEST_GPG_ALL_FINGERPRINTS = $AllFingerprints
        SYNCPSS_TEST_GPG_MATCH_FINGERPRINTS = $MatchFingerprints
        SYNCPSS_TEST_GPG_WRONG_FINGERPRINTS = $WrongFingerprints
        SYNCPSS_RELEASE_GIT_SIGNINGKEY = $ConfiguredSigningKey
        SYNCPSS_TEST_AUTHENTICODE_STATUS = $AuthenticodeStatus
        SYNCPSS_TEST_AUTHENTICODE_THUMBPRINT = $AuthenticodeThumbprint
        SYNCPSS_TEST_AUTHENTICODE_SUBJECT = $AuthenticodeSubject
    }

    $originalValues = @{}
    foreach ($name in $overrides.Keys) {
        $item = Get-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
        $originalValues[$name] = if ($null -eq $item) { $null } else { $item.Value }
        if ([string]::IsNullOrWhiteSpace($overrides[$name])) {
            Remove-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path ("Env:" + $name) -Value $overrides[$name]
        }
    }

    try {
        $output = & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ReleaseScriptPath -SigningReadiness 2>&1
        return [pscustomobject]@{
            ExitCode = [int]$LASTEXITCODE
            Output = (($output | Out-String).Trim())
        }
    } finally {
        foreach ($name in $overrides.Keys) {
            if ($null -eq $originalValues[$name]) {
                Remove-Item -Path ("Env:" + $name) -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path ("Env:" + $name) -Value $originalValues[$name]
            }
        }
    }
}

$activeFingerprint = "1111111111111111111111111111111111111111"
$wrongFingerprint = "2222222222222222222222222222222222222222"
$verifyOnlyFingerprint = "3333333333333333333333333333333333333333"
$allowedThumbprint = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
$tempRoot = Join-Path $PSScriptRoot (".release-signing-" + [guid]::NewGuid().ToString("N"))
$repoRoot = Join-Path $tempRoot "repo"
$policyPath = Join-Path $repoRoot "config\signing_policy.json"
$fakeGpgPath = Join-Path $tempRoot "fake_gpg.cmd"
$installerPath = Join-Path $repoRoot "bin\syncpss-wsl-installer.exe"
$releaseScriptPath = Join-Path $PSScriptRoot "..\scripts\ps1\release.ps1"

try {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot "config") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot "bin") -Force | Out-Null
    [System.IO.File]::WriteAllBytes($installerPath, [byte[]](0))

    Write-TextFile -Path $fakeGpgPath -Content @'
@echo off
setlocal EnableExtensions
if /I "%~1"=="--version" (
    echo gpg fake 1.0
    exit /b 0
)
if /I "%~1"=="--list-secret-keys" goto list
echo unsupported fake gpg invocation 1>&2
exit /b 1

:list
set "fingerprints=%SYNCPSS_TEST_GPG_ALL_FINGERPRINTS%"
echo %* | findstr /I /C:" MATCH" >nul && set "fingerprints=%SYNCPSS_TEST_GPG_MATCH_FINGERPRINTS%"
echo %* | findstr /I /C:" WRONG" >nul && set "fingerprints=%SYNCPSS_TEST_GPG_WRONG_FINGERPRINTS%"
if not defined fingerprints exit /b 0
for %%F in (%fingerprints:;= %) do (
    echo sec:u:255:22:::::::scSC:
    echo fpr:::::::::%%F:
)
exit /b 0
'@

    $result = Invoke-ReadinessCheck `
        -ReleaseScriptPath $releaseScriptPath `
        -RepoRoot $repoRoot `
        -PolicyPath $policyPath `
        -PolicyJson (New-SigningPolicyJson -ActiveFingerprint $activeFingerprint -AllowedFingerprints @($activeFingerprint) -VerifyOnlyFingerprints @($verifyOnlyFingerprint)) `
        -FakeGpgPath $fakeGpgPath `
        -AllFingerprints $activeFingerprint
    Assert-True -Condition ($result.ExitCode -eq 0) -Message "Signing readiness should pass when the active release fingerprint is present."
    Assert-Contains -Text $result.Output -ExpectedSubstring "Release readiness:        PASS" -Message "Signing readiness output should report PASS."
    Assert-Contains -Text $result.Output -ExpectedSubstring $activeFingerprint -Message "Signing readiness output should include the active release fingerprint."

    $result = Invoke-ReadinessCheck `
        -ReleaseScriptPath $releaseScriptPath `
        -RepoRoot $repoRoot `
        -PolicyPath $policyPath `
        -PolicyJson (New-SigningPolicyJson -ActiveFingerprint $activeFingerprint -AllowedFingerprints @($activeFingerprint)) `
        -FakeGpgPath $fakeGpgPath
    Assert-True -Condition ($result.ExitCode -ne 0) -Message "Signing readiness should fail when no secret keys are visible."
    Assert-Contains -Text $result.Output -ExpectedSubstring "no secret signing key was visible" -Message "Missing secret key output should explain the problem."

    $result = Invoke-ReadinessCheck `
        -ReleaseScriptPath $releaseScriptPath `
        -RepoRoot $repoRoot `
        -PolicyPath $policyPath `
        -PolicyJson (New-SigningPolicyJson -ActiveFingerprint $activeFingerprint -AllowedFingerprints @($activeFingerprint) -VerifyOnlyFingerprints @($verifyOnlyFingerprint)) `
        -FakeGpgPath $fakeGpgPath `
        -AllFingerprints $wrongFingerprint
    Assert-True -Condition ($result.ExitCode -ne 0) -Message "Signing readiness should fail when only the wrong secret key is present."
    Assert-Contains -Text $result.Output -ExpectedSubstring "is not present in the Windows secret keyring" -Message "Wrong-key output should explain the active fingerprint mismatch."

    $result = Invoke-ReadinessCheck `
        -ReleaseScriptPath $releaseScriptPath `
        -RepoRoot $repoRoot `
        -PolicyPath $policyPath `
        -PolicyJson (New-SigningPolicyJson -ActiveFingerprint $activeFingerprint -AllowedFingerprints @($activeFingerprint)) `
        -FakeGpgPath $fakeGpgPath `
        -AllFingerprints $activeFingerprint `
        -ConfiguredSigningKey "WRONG" `
        -WrongFingerprints $wrongFingerprint
    Assert-True -Condition ($result.ExitCode -ne 0) -Message "Signing readiness should fail when git user.signingkey resolves to the wrong fingerprint."
    Assert-Contains -Text $result.Output -ExpectedSubstring "git user.signingkey 'WRONG' resolves to" -Message "Configured signing key mismatch should be explicit."

    $result = Invoke-ReadinessCheck `
        -ReleaseScriptPath $releaseScriptPath `
        -RepoRoot $repoRoot `
        -PolicyPath $policyPath `
        -PolicyJson (New-SigningPolicyJson -ActiveFingerprint $activeFingerprint -AllowedFingerprints @($activeFingerprint) -WindowsCodeSignRequired $true -AllowedThumbprints @($allowedThumbprint)) `
        -FakeGpgPath $fakeGpgPath `
        -AllFingerprints $activeFingerprint `
        -AuthenticodeStatus "NotSigned"
    Assert-True -Condition ($result.ExitCode -ne 0) -Message "Signing readiness should fail when Windows code signing is required and the installer is unsigned."
    Assert-Contains -Text $result.Output -ExpectedSubstring "not Authenticode-signed with status Valid" -Message "Windows code signing failure should be explicit."

    $result = Invoke-ReadinessCheck `
        -ReleaseScriptPath $releaseScriptPath `
        -RepoRoot $repoRoot `
        -PolicyPath $policyPath `
        -PolicyJson (New-SigningPolicyJson -ActiveFingerprint $activeFingerprint -AllowedFingerprints @($activeFingerprint) -WindowsCodeSignRequired $true -AllowedThumbprints @($allowedThumbprint)) `
        -FakeGpgPath $fakeGpgPath `
        -AllFingerprints $activeFingerprint `
        -AuthenticodeStatus "Valid" `
        -AuthenticodeThumbprint $allowedThumbprint `
        -AuthenticodeSubject "CN=syncpss release"
    Assert-True -Condition ($result.ExitCode -eq 0) -Message "Signing readiness should pass when the active release key and allowed Windows signer are both present."
    Assert-Contains -Text $result.Output -ExpectedSubstring "Release readiness:        PASS" -Message "Combined release readiness output should report PASS."

    Write-Host "release signing policy checks passed"
    exit 0
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
