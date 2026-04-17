[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Version = "",
    [string]$Distro = "",
    [switch]$InstallDeps,
    [switch]$EnableClangTidy,
    [switch]$SkipBuild,
    [switch]$ForceOverwrite,
    [switch]$PassStoreOnly,
    [switch]$SigningReadiness,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "maintainer_id.ps1")

$MinimumReleaseVersion = "1.0.0"
$RepoManifestPath = "manifest.xml"
$MasterFingerprintPath = "master_fingerprint.sha256"
$ReleaseBundlePath = "syncpss-release-binaries.zip"
$SigningPolicyRelativePath = "config\signing_policy.json"
$SigningFingerprintPlaceholder = "0000000000000000000000000000000000000000"
$script:ReleaseStatusAlreadyPrinted = $false

function Get-ReleaseRepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:SYNCPSS_RELEASE_REPO_ROOT)) {
        return (Resolve-Path -LiteralPath $env:SYNCPSS_RELEASE_REPO_ROOT).Path
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
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

function Get-SigningPolicyPath {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:SYNCPSS_SIGNING_POLICY_PATH)) {
        return (Resolve-Path -LiteralPath $env:SYNCPSS_SIGNING_POLICY_PATH).Path
    }

    return (Join-Path $RepoRoot $SigningPolicyRelativePath)
}

function Read-ReleaseSigningPolicy {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $policyPath = Get-SigningPolicyPath -RepoRoot $RepoRoot
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
            ActiveReleaseFingerprintIsPlaceholder = ($activeReleaseFingerprint -eq $SigningFingerprintPlaceholder)
        }
        WindowsCodeSign = [pscustomobject]@{
            Phase = $windowsCodeSignPhase
            Required = [bool]$windowsCodeSignRequired
            AllowedThumbprints = $windowsCodeSignAllowedThumbprints
            SubjectHint = $windowsCodeSignSubjectHint.Trim()
        }
    }
}

function Format-IdentifierList {
    param([AllowNull()][string[]]$Values)

    $resolvedValues = [string[]]@($Values)
    if ($null -eq $Values -or $resolvedValues.Count -eq 0) {
        return "<none>"
    }

    return ($resolvedValues -join ", ")
}

function Get-ReleaseAssetRelativePaths {
    return @(
        "bin\syncpss-linux-x86_64",
        "bin\syncpss-linux-x86_64.sha256",
        "bin\manifest.xml",
        "bin\manifest.xml.sha256",
        "bin\install",
        "bin\install.sha256",
        "bin\syncpss-wsl-installer.exe",
        "bin\syncpss-wsl-installer.exe.sha256",
        "bin\installer.sh",
        "bin\installer.sh.sha256",
        "bin\managed_paths.sh",
        "bin\managed_paths.sh.sha256",
        "bin\uninstall_syncpss.sh",
        "bin\uninstall_syncpss.sh.sha256",
        "bin\master_fingerprint.sha256",
        ("bin\" + $ReleaseBundlePath)
    )
}

function Get-SignedReleaseAssetRelativePaths {
    return @(
        "bin\syncpss-linux-x86_64",
        "bin\syncpss-wsl-installer.exe",
        "bin\installer.sh",
        "bin\managed_paths.sh",
        ("bin\" + $ReleaseBundlePath)
    )
}

function Get-ReleaseManifestAssetNames {
    $baseNames = Get-ReleaseAssetRelativePaths | ForEach-Object { Split-Path -Path $_ -Leaf }
    $signatureNames = Get-SignedReleaseAssetRelativePaths | ForEach-Object { (Split-Path -Path $_ -Leaf) + ".asc" }
    return @($baseNames + $signatureNames)
}

function Test-SemVerFormat {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value -match '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
}

function ConvertTo-SemVerParts {
    param([Parameter(Mandatory = $true)][string]$Value)

    if (-not (Test-SemVerFormat -Value $Value)) {
        throw "Version must use x.y.z format, for example 1.0.0"
    }

    return [int[]]($Value.Split('.') | ForEach-Object { [int]$_ })
}

function Compare-SemVer {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftParts = ConvertTo-SemVerParts -Value $Left
    $rightParts = ConvertTo-SemVerParts -Value $Right

    for ($i = 0; $i -lt 3; $i++) {
        if ($leftParts[$i] -lt $rightParts[$i]) {
            return -1
        }
        if ($leftParts[$i] -gt $rightParts[$i]) {
            return 1
        }
    }

    return 0
}

function Get-ProjectVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $cmakePath = Join-Path $RepoRoot "CMakeLists.txt"
    if (-not (Test-Path -LiteralPath $cmakePath)) {
        return $null
    }

    $match = Select-String -Path $cmakePath -Pattern 'project\s*\(\s*syncpss\s+VERSION\s+([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value
}

function Get-RepoIdSeed {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    return Resolve-MaintainerIdSeed -RepoRoot $RepoRoot -NonInteractive:$NonInteractive
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

function Update-RepoManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$RepoIdHashValue
    )

    $manifestPath = Join-Path $RepoRoot $RepoManifestPath
    $updatedAt = [DateTime]::UtcNow.ToString("o")
    $assetNames = Get-ReleaseManifestAssetNames

    $assetXml = ($assetNames | ForEach-Object { "    <asset name=""$_"" />" }) -join "`r`n"
    $content = @"
<?xml version="1.0" encoding="UTF-8"?>
<syncpss-manifest>
  <release>
    <name>Release v$Version</name>
    <tag>v$Version</tag>
    <version>$Version</version>
    <updated_at>$updatedAt</updated_at>
  </release>
  <repository>
    <owner>KffeePt</owner>
    <name>syncpss</name>
    <id_hash>$RepoIdHashValue</id_hash>
  </repository>
  <assets>
$assetXml
  </assets>
</syncpss-manifest>
"@

    [System.IO.File]::WriteAllText($manifestPath, $content, [System.Text.UTF8Encoding]::new($false))
}

function Get-ReleaseMasterFingerprint {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $assetFiles = @(
        "bin\syncpss-linux-x86_64",
        "bin\install",
        "bin\installer.sh",
        "bin\managed_paths.sh",
        "bin\uninstall_syncpss.sh"
    ) | ForEach-Object { Join-Path $RepoRoot $_ }

    $buffer = New-Object System.IO.MemoryStream
    try {
        foreach ($absolutePath in $assetFiles) {
            if (-not (Test-Path -LiteralPath $absolutePath)) {
                throw "Required release asset is missing for master fingerprint generation: $absolutePath"
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

function Write-MasterFingerprintAssets {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $fingerprint = Get-ReleaseMasterFingerprint -RepoRoot $RepoRoot
    $rootFingerprintPath = Join-Path $RepoRoot $MasterFingerprintPath
    $binFingerprintPath = Join-Path (Join-Path $RepoRoot "bin") $MasterFingerprintPath

    [System.IO.File]::WriteAllText($rootFingerprintPath, ($fingerprint + "  master_fingerprint.sha256"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($binFingerprintPath, ($fingerprint + "  master_fingerprint.sha256"), [System.Text.UTF8Encoding]::new($false))
}

function Write-ReleaseBundle {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $bundleEntries = @(
        "bin\syncpss-linux-x86_64",
        "bin\install",
        "bin\syncpss-wsl-installer.exe",
        "bin\installer.sh",
        "bin\managed_paths.sh",
        "bin\uninstall_syncpss.sh"
    )

    $bundlePath = Join-Path $RepoRoot ("bin\" + $ReleaseBundlePath)
    $missing = @($bundleEntries | ForEach-Object { Join-Path $RepoRoot $_ } | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) {
        throw ("Cannot create release bundle. Missing files:`n" + (($missing | ForEach-Object { " - $_" }) -join "`n"))
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("syncpss-release-bundle-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $stagingRoot | Out-Null
        foreach ($relativePath in $bundleEntries) {
            $source = Join-Path $RepoRoot $relativePath
            $dest = Join-Path $stagingRoot (Split-Path -Path $relativePath -Leaf)
            Copy-Item -LiteralPath $source -Destination $dest -Force
        }

        if (Test-Path -LiteralPath $bundlePath) {
            Remove-Item -LiteralPath $bundlePath -Force
        }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingRoot, $bundlePath)
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
    }
}

function Remove-StaleReleaseSignatureFiles {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $binDir = Join-Path $RepoRoot "bin"
    if (-not (Test-Path -LiteralPath $binDir)) {
        return
    }

    Get-ChildItem -LiteralPath $binDir -Filter "*.asc" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
    }
}

function Get-GitSigningKey {
    $overrideItem = Get-Item -Path Env:\SYNCPSS_RELEASE_GIT_SIGNINGKEY -ErrorAction SilentlyContinue
    if ($null -ne $overrideItem) {
        $overrideValue = ([string]$overrideItem.Value).Trim()
        if ($overrideValue -eq "__unset__") {
            return ""
        }
        return $overrideValue
    }

    $signingKey = git config --get user.signingkey
    if ($LASTEXITCODE -ne 0) {
        return ""
    }
    return (($signingKey | Out-String).Trim())
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

    throw "gpg is required for signed tags and detached release signatures. Install Gpg4win on Windows and retry."
}

function Get-GpgConfExecutablePath {
    param([Parameter(Mandatory = $true)][string]$GpgProgram)

    if (-not [string]::IsNullOrWhiteSpace($env:SYNCPSS_GPGCONF_EXECUTABLE)) {
        $overridePath = $env:SYNCPSS_GPGCONF_EXECUTABLE.Trim()
        if (-not (Test-Path -LiteralPath $overridePath)) {
            throw "Configured gpgconf executable override '$overridePath' does not exist."
        }
        return (Resolve-Path -LiteralPath $overridePath).Path
    }

    $gpgConf = Get-Command gpgconf -ErrorAction SilentlyContinue
    if ($null -ne $gpgConf) {
        return $gpgConf.Source
    }

    $gpgDirectory = Split-Path -Parent $GpgProgram
    if (-not [string]::IsNullOrWhiteSpace($gpgDirectory)) {
        $siblingPath = Join-Path $gpgDirectory "gpgconf.exe"
        if (Test-Path -LiteralPath $siblingPath) {
            return (Resolve-Path -LiteralPath $siblingPath).Path
        }
    }

    return ""
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

function ConvertTo-NativeCommandOutputText {
    param([AllowNull()][object[]]$Output)

    if ($null -eq $Output -or $Output.Count -eq 0) {
        return ""
    }

    return ((($Output | Out-String) -replace "`0", "").Trim())
}

function Invoke-NativeCommandWithCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $combinedOutput = @($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Output = ConvertTo-NativeCommandOutputText -Output $combinedOutput
    }
}

function Start-GpgAgentIfAvailable {
    param([Parameter(Mandatory = $true)][string]$GpgProgram)

    try {
        $gpgConfProgram = Get-GpgConfExecutablePath -GpgProgram $GpgProgram
    } catch {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($gpgConfProgram)) {
        return ""
    }

    $launchResult = Invoke-NativeCommandWithCapture -FilePath $gpgConfProgram -Arguments @("--launch", "gpg-agent")
    if ($launchResult.ExitCode -ne 0) {
        return ""
    }

    return $gpgConfProgram
}

function Test-GpgTimeoutFailure {
    param([AllowNull()][string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    return (
        ($Output -match '(?im)\bsigning failed:\s*Timeout\b') -or
        ($Output -match '(?im)\bOperation timed out\b') -or
        ($Output -match '(?im)\bpinentry\b.*\btimeout\b') -or
        ($Output -match '(?im)\btimeout\b.*\bpinentry\b')
    )
}

function Get-GpgAgentRestartInstructions {
    param([Parameter(Mandatory = $true)][string]$GpgProgram)

    $gpgConfProgram = ""
    try {
        $gpgConfProgram = Get-GpgConfExecutablePath -GpgProgram $GpgProgram
    } catch {
        $gpgConfProgram = ""
    }

    if ([string]::IsNullOrWhiteSpace($gpgConfProgram)) {
        return @(
            "gpgconf --kill gpg-agent",
            "gpgconf --launch gpg-agent"
        )
    }

    return @(
        ('"{0}" --kill gpg-agent' -f $gpgConfProgram),
        ('"{0}" --launch gpg-agent' -f $gpgConfProgram)
    )
}

function New-GpgFailureMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][pscustomobject]$SigningInfo,
        [Parameter(Mandatory = $true)][pscustomobject]$Result
    )

    $capturedOutput = if ([string]::IsNullOrWhiteSpace($Result.Output)) {
        "<no gpg output captured>"
    } else {
        $Result.Output
    }

    if (Test-GpgTimeoutFailure -Output $capturedOutput) {
        $agentRestartCommands = Get-GpgAgentRestartInstructions -GpgProgram $SigningInfo.GpgProgram
        return @"
GPG timed out while trying to $Action '$Target' with release signing key $($SigningInfo.Fingerprint).
The signing key was detected correctly, but Gpg4win pinentry did not complete before gpg gave up.

What to check on this Windows machine:
1. Look for a hidden Gpg4win or Kleopatra pinentry window on the taskbar and approve it promptly.
2. Make sure Gpg4win was installed with a pinentry program such as pinentry-basic or pinentry-qt.
3. Restart the GPG agent, then retry:
   $($agentRestartCommands[0])
   $($agentRestartCommands[1])
4. If the prompt still never appears, open Kleopatra once, unlock the key there, then rerun scripts\cd.bat.

Raw gpg output:
$capturedOutput
"@
    }

    return @"
Failed to $Action '$Target' with release signing key $($SigningInfo.Fingerprint).

Raw gpg output:
$capturedOutput
"@
}

function Get-InstallerAuthenticodeSignatureStatus {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    if (-not [string]::IsNullOrWhiteSpace($env:SYNCPSS_TEST_AUTHENTICODE_STATUS)) {
        return [pscustomobject]@{
            Status = $env:SYNCPSS_TEST_AUTHENTICODE_STATUS.Trim()
            Thumbprint = if ([string]::IsNullOrWhiteSpace($env:SYNCPSS_TEST_AUTHENTICODE_THUMBPRINT)) { "" } else { ConvertTo-NormalizedHexIdentifier -Value $env:SYNCPSS_TEST_AUTHENTICODE_THUMBPRINT.Trim() -ExpectedLength 40 -Context "Test Authenticode thumbprint" }
            Subject = if ([string]::IsNullOrWhiteSpace($env:SYNCPSS_TEST_AUTHENTICODE_SUBJECT)) { "" } else { $env:SYNCPSS_TEST_AUTHENTICODE_SUBJECT.Trim() }
        }
    }

    $signature = Get-AuthenticodeSignature -FilePath $FilePath
    $thumbprint = ""
    if ($null -ne $signature.SignerCertificate -and -not [string]::IsNullOrWhiteSpace($signature.SignerCertificate.Thumbprint)) {
        $thumbprint = ConvertTo-NormalizedHexIdentifier -Value $signature.SignerCertificate.Thumbprint -ExpectedLength 40 -Context "Windows code signing thumbprint"
    }

    return [pscustomobject]@{
        Status = [string]$signature.Status
        Thumbprint = $thumbprint
        Subject = if ($null -eq $signature.SignerCertificate) { "" } else { [string]$signature.SignerCertificate.Subject }
    }
}

function Get-WindowsCodeSigningReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][pscustomobject]$SigningPolicy
    )

    $installerPath = Join-Path $RepoRoot "bin\syncpss-wsl-installer.exe"
    if (-not $SigningPolicy.WindowsCodeSign.Required) {
        return [pscustomobject]@{
            Required = $false
            IsReady = $true
            Message = "Windows Authenticode signing is not required by policy."
            InstallerPath = $installerPath
            Signature = $null
        }
    }

    if ([string[]]@($SigningPolicy.WindowsCodeSign.AllowedThumbprints).Count -eq 0) {
        return [pscustomobject]@{
            Required = $true
            IsReady = $false
            Message = "Windows code signing is required by policy, but windows_codesign.allowed_thumbprints is empty."
            InstallerPath = $installerPath
            Signature = $null
        }
    }
    if (-not (Test-Path -LiteralPath $installerPath)) {
        return [pscustomobject]@{
            Required = $true
            IsReady = $false
            Message = "Windows code signing is required by policy, but '$installerPath' does not exist yet."
            InstallerPath = $installerPath
            Signature = $null
        }
    }

    $signature = Get-InstallerAuthenticodeSignatureStatus -FilePath $installerPath
    if ($signature.Status -ne "Valid") {
        return [pscustomobject]@{
            Required = $true
            IsReady = $false
            Message = "Windows code signing is required by policy, but '$installerPath' is not Authenticode-signed with status Valid. Current status: $($signature.Status)."
            InstallerPath = $installerPath
            Signature = $signature
        }
    }
    if ([string]::IsNullOrWhiteSpace($signature.Thumbprint)) {
        return [pscustomobject]@{
            Required = $true
            IsReady = $false
            Message = "Windows code signing is required by policy, but '$installerPath' did not expose a signer thumbprint."
            InstallerPath = $installerPath
            Signature = $signature
        }
    }
    if ($SigningPolicy.WindowsCodeSign.AllowedThumbprints -notcontains $signature.Thumbprint) {
        return [pscustomobject]@{
            Required = $true
            IsReady = $false
            Message = "Windows code signing is required by policy, but '$installerPath' is signed with thumbprint '$($signature.Thumbprint)' instead of an allowed thumbprint."
            InstallerPath = $installerPath
            Signature = $signature
        }
    }

    return [pscustomobject]@{
        Required = $true
        IsReady = $true
        Message = "Windows Authenticode signing policy is satisfied."
        InstallerPath = $installerPath
        Signature = $signature
    }
}

function Get-ReleaseSigningReadiness {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $signingPolicy = Read-ReleaseSigningPolicy -RepoRoot $resolvedRepoRoot
    $configuredSigningKey = Get-GitSigningKey
    $gpgProgram = ""
    $detectedFingerprints = @()
    $configuredFingerprints = @()
    $selectedFingerprint = ""
    $status = "fail"
    $message = ""

    try {
        $gpgProgram = Get-GpgExecutablePath
    } catch {
        $message = $_.Exception.Message
        return [pscustomobject]@{
            RepoRoot = $resolvedRepoRoot
            SigningPolicy = $signingPolicy
            GpgProgram = ""
            ConfiguredSigningKey = $configuredSigningKey
            DetectedFingerprints = @()
            ConfiguredFingerprints = @()
            SelectedFingerprint = ""
            WindowsCodeSigning = Get-WindowsCodeSigningReadiness -RepoRoot $resolvedRepoRoot -SigningPolicy $signingPolicy
            IsReady = $false
            Status = $status
            Message = $message
        }
    }

    $detectedFingerprints = [string[]]@(Get-GpgSecretKeyFingerprints -GpgProgram $gpgProgram)

    if ($signingPolicy.Gpg.ActiveReleaseFingerprintIsPlaceholder) {
        $message = "Signing policy '$($signingPolicy.Path)' still uses the placeholder active release fingerprint. Replace gpg.active_release_fingerprint and gpg.allowed_release_fingerprints with the real release signing fingerprint before publishing."
    } elseif ($detectedFingerprints.Count -eq 0) {
        $message = "No usable Windows GPG secret key was found. GPG was checked at '$gpgProgram', but no secret signing key was visible. Import the release signing subkey, not just the public certificate, and retry."
    } elseif (-not [string]::IsNullOrWhiteSpace($configuredSigningKey)) {
        $configuredFingerprints = [string[]]@(Get-GpgSecretKeyFingerprints -GpgProgram $gpgProgram -KeySpecifier $configuredSigningKey)
        if ($configuredFingerprints.Count -eq 0) {
            $message = "git user.signingkey '$configuredSigningKey' does not resolve to a usable Windows GPG secret key in '$gpgProgram'."
        } elseif ($configuredFingerprints -notcontains $signingPolicy.Gpg.ActiveReleaseFingerprint) {
            $message = "git user.signingkey '$configuredSigningKey' resolves to '$((Format-IdentifierList -Values $configuredFingerprints))', but signing policy requires the active release fingerprint '$($signingPolicy.Gpg.ActiveReleaseFingerprint)'."
        } else {
            $selectedFingerprint = $signingPolicy.Gpg.ActiveReleaseFingerprint
        }
    } elseif ($detectedFingerprints -contains $signingPolicy.Gpg.ActiveReleaseFingerprint) {
        $selectedFingerprint = $signingPolicy.Gpg.ActiveReleaseFingerprint
    } else {
        $message = "Active release signing fingerprint '$($signingPolicy.Gpg.ActiveReleaseFingerprint)' is not present in the Windows secret keyring. Detected secret key fingerprints: $(Format-IdentifierList -Values $detectedFingerprints)."
    }

    $windowsCodeSigning = Get-WindowsCodeSigningReadiness -RepoRoot $resolvedRepoRoot -SigningPolicy $signingPolicy
    if ([string]::IsNullOrWhiteSpace($message) -and -not $windowsCodeSigning.IsReady) {
        $message = $windowsCodeSigning.Message
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        $status = "pass"
        $message = "Release signing readiness passed."
    }

    return [pscustomobject]@{
        RepoRoot = $resolvedRepoRoot
        SigningPolicy = $signingPolicy
        GpgProgram = $gpgProgram
        ConfiguredSigningKey = $configuredSigningKey
        DetectedFingerprints = $detectedFingerprints
        ConfiguredFingerprints = $configuredFingerprints
        SelectedFingerprint = $selectedFingerprint
        WindowsCodeSigning = $windowsCodeSigning
        IsReady = ($status -eq "pass")
        Status = $status
        Message = $message
    }
}

function Show-ReleaseSigningReadiness {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $readiness = Get-ReleaseSigningReadiness -RepoRoot $RepoRoot

    Write-Host ""
    Write-Host "syncpss signing readiness" -ForegroundColor Yellow
    Write-Host ("Policy file:              {0}" -f $readiness.SigningPolicy.Path) -ForegroundColor Cyan
    Write-Host ("Active release signer:    {0}" -f $readiness.SigningPolicy.Gpg.ActiveReleaseFingerprint) -ForegroundColor Cyan
    Write-Host ("Allowed release signers:  {0}" -f (Format-IdentifierList -Values $readiness.SigningPolicy.Gpg.AllowedReleaseFingerprints)) -ForegroundColor Cyan
    Write-Host ("Verify-only signers:      {0}" -f (Format-IdentifierList -Values $readiness.SigningPolicy.Gpg.VerifyOnlyFingerprints)) -ForegroundColor Cyan
    Write-Host ("GitHub account:           {0}" -f $readiness.SigningPolicy.Gpg.GitHubAccount) -ForegroundColor Cyan
    Write-Host ("Resolved gpg.exe:         {0}" -f $(if ([string]::IsNullOrWhiteSpace($readiness.GpgProgram)) { "<not found>" } else { $readiness.GpgProgram })) -ForegroundColor Cyan
    Write-Host ("git user.signingkey:      {0}" -f $(if ([string]::IsNullOrWhiteSpace($readiness.ConfiguredSigningKey)) { "<not set>" } else { $readiness.ConfiguredSigningKey })) -ForegroundColor Cyan
    Write-Host ("Detected secret keys:     {0}" -f (Format-IdentifierList -Values $readiness.DetectedFingerprints)) -ForegroundColor Cyan
    Write-Host ("Windows codesign phase:   {0}" -f $readiness.SigningPolicy.WindowsCodeSign.Phase) -ForegroundColor Cyan
    Write-Host ("Windows codesign required:{0}" -f $(if ($readiness.SigningPolicy.WindowsCodeSign.Required) { " yes" } else { " no" })) -ForegroundColor Cyan

    if ($readiness.IsReady) {
        Write-Host ("Release readiness:        PASS ({0})" -f $readiness.SelectedFingerprint) -ForegroundColor Green
        return $readiness
    }

    Write-Host ("Release readiness:        FAIL") -ForegroundColor Red
    Write-Host ($readiness.Message) -ForegroundColor Red
    $script:ReleaseStatusAlreadyPrinted = $true
    return $readiness
}

function Assert-GpgSigningReady {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $readiness = Get-ReleaseSigningReadiness -RepoRoot $RepoRoot
    if (-not $readiness.IsReady) {
        throw $readiness.Message
    }

    return [pscustomobject]@{
        GpgProgram = $readiness.GpgProgram
        Fingerprint = $readiness.SelectedFingerprint
        SigningPolicy = $readiness.SigningPolicy
    }
}

function Write-DetachedReleaseSignatures {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$SigningInfo,
        [Parameter(Mandatory = $true)][string[]]$Assets
    )

    $null = Start-GpgAgentIfAvailable -GpgProgram $SigningInfo.GpgProgram
    Write-Host "Gpg4win may open a pinentry prompt on the first signature. If nothing appears, check for a hidden taskbar window." -ForegroundColor Yellow

    foreach ($asset in $Assets) {
        $signaturePath = "$asset.asc"
        if (Test-Path -LiteralPath $signaturePath) {
            Remove-Item -LiteralPath $signaturePath -Force
        }

        Write-Host ("Signing asset: {0}" -f (Split-Path -Path $asset -Leaf)) -ForegroundColor Cyan
        $signResult = Invoke-NativeCommandWithCapture -FilePath $SigningInfo.GpgProgram -Arguments @(
            "--yes",
            "--local-user", $SigningInfo.Fingerprint,
            "--armor",
            "--detach-sign",
            "--output", $signaturePath,
            $asset
        )
        if ($signResult.ExitCode -ne 0) {
            if (Test-Path -LiteralPath $signaturePath) {
                Remove-Item -LiteralPath $signaturePath -Force
            }
            throw (New-GpgFailureMessage -Action "create a detached signature for" -Target $asset -SigningInfo $SigningInfo -Result $signResult)
        }

        $verifyResult = Invoke-NativeCommandWithCapture -FilePath $SigningInfo.GpgProgram -Arguments @("--verify", $signaturePath, $asset)
        if ($verifyResult.ExitCode -ne 0) {
            throw (New-GpgFailureMessage -Action "verify the detached signature for" -Target $asset -SigningInfo $SigningInfo -Result $verifyResult)
        }
    }
}

function New-SignedReleaseTag {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$SigningInfo,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $tagArgs = @(
        "-c", "gpg.format=openpgp",
        "-c", "gpg.program=$($SigningInfo.GpgProgram)",
        "tag", "-s", "-u", $SigningInfo.Fingerprint, $Tag, "-m", "Release $Tag"
    )

    $null = Start-GpgAgentIfAvailable -GpgProgram $SigningInfo.GpgProgram

    $tagResult = Invoke-NativeCommandWithCapture -FilePath "git" -Arguments $tagArgs
    if ($tagResult.ExitCode -ne 0) {
        throw (New-GpgFailureMessage -Action "create the signed tag for" -Target $Tag -SigningInfo $SigningInfo -Result $tagResult)
    }

    $verifyTagResult = Invoke-NativeCommandWithCapture -FilePath "git" -Arguments @(
        "-c", "gpg.format=openpgp",
        "-c", "gpg.program=$($SigningInfo.GpgProgram)",
        "tag", "-v", $Tag
    )
    if ($verifyTagResult.ExitCode -ne 0) {
        throw (New-GpgFailureMessage -Action "verify the signed tag for" -Target $Tag -SigningInfo $SigningInfo -Result $verifyTagResult)
    }
}

function Get-RemoteVersions {
    $lines = git ls-remote --tags --refs origin "v*"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query remote tags from origin."
    }

    $versions = @()
    foreach ($line in $lines) {
        $text = ($line | Out-String).Trim()
        if ($text -match 'refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$') {
            $candidate = $Matches[1]
            if (Test-SemVerFormat -Value $candidate) {
                $versions += $candidate
            }
        }
    }

    return @(
        $versions |
            Sort-Object -Unique |
            Sort-Object -Descending -Property @{ Expression = { (ConvertTo-SemVerParts -Value $_)[0] } }, @{ Expression = { (ConvertTo-SemVerParts -Value $_)[1] } }, @{ Expression = { (ConvertTo-SemVerParts -Value $_)[2] } }
    )
}

function Test-RemoteTagExists {
    param([Parameter(Mandatory = $true)][string]$Tag)

    git ls-remote --exit-code --tags origin $Tag | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-LocalTagExists {
    param([Parameter(Mandatory = $true)][string]$Tag)

    git rev-parse --verify --quiet "refs/tags/$Tag" | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-GitHubReleaseExists {
    param([Parameter(Mandatory = $true)][string]$Tag)

    gh release view $Tag | Out-Null 2>$null
    return $LASTEXITCODE -eq 0
}

function Remove-ReleaseVersion {
    param([Parameter(Mandatory = $true)][string]$Tag)

    if (Test-GitHubReleaseExists -Tag $Tag) {
        gh release delete $Tag --yes
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete GitHub release $Tag"
        }
    }

    if (Test-RemoteTagExists -Tag $Tag) {
        git push origin ":refs/tags/$Tag"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete remote tag $Tag"
        }
    }

    if (Test-LocalTagExists -Tag $Tag) {
        git tag -d $Tag | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete local tag $Tag"
        }
    }
}

function Assert-ExpectedOrigin {
    $originUrl = git remote get-url origin
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read git remote 'origin'."
    }

    $originUrl = ($originUrl | Out-String).Trim()
    if ($originUrl -notmatch 'KffeePt[/\\:]syncpss(\.git)?$') {
        throw "This release script expects origin to point at KffeePt/syncpss. Current origin: $originUrl"
    }
}

function Prompt-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Message $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }

    return $answer.Trim().ToLowerInvariant() -in @("y", "yes")
}

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
        throw "WSL is required to sync the password store from Windows."
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
        [string]$RequestedUser = ""
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

function Invoke-WslCommandInteractive {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser,
        [Parameter(Mandatory = $true)][string]$ShellCommand
    )

    $process = Start-Process `
        -FilePath "wsl.exe" `
        -ArgumentList @(
            "-d", $DistroName,
            "-u", $LinuxUser,
            "--",
            "bash", "-lc",
            $ShellCommand
        ) `
        -NoNewWindow `
        -Wait `
        -PassThru
    return [int]$process.ExitCode
}

function Write-WslScriptFile {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$LinuxUser,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $stageDir = "\\wsl.localhost\$DistroName\home\$LinuxUser\.syncpss\helpers"
    if (-not (Test-Path -LiteralPath $stageDir)) {
        New-Item -ItemType Directory -Path $stageDir | Out-Null
    }

    $target = Join-Path $stageDir $FileName
    [System.IO.File]::WriteAllText($target, $Content, [System.Text.UTF8Encoding]::new($false))
    & wsl.exe -d $DistroName -u $LinuxUser -- bash -lc "chmod 700 '/home/$LinuxUser/.syncpss/helpers/$FileName'"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to mark $FileName executable in WSL."
    }
    return "/home/$LinuxUser/.syncpss/helpers/$FileName"
}

function Invoke-PassStoreSync {
    param([string]$RequestedDistro)

    $selectedDistro = Select-WslDistro -RequestedDistro $RequestedDistro
    $selectedUser = Select-WslUser -DistroName $selectedDistro

    $syncScript = @'
#!/usr/bin/env bash
set -euo pipefail
STORE_HASH_FILE=".syncpss-store.sha256"
STORE_DIR=""

if [ -f "$HOME/.syncpss/config.json" ] && command -v python3 >/dev/null 2>&1; then
  STORE_DIR="$(python3 - <<'PY'
import json
import os
from pathlib import Path

config_path = Path.home() / ".syncpss" / "config.json"
try:
    with config_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    value = data.get("store", {}).get("path", "")
    if isinstance(value, str) and value.strip():
        print(os.path.expanduser(value.strip()))
except Exception:
    pass
PY
)"
fi

if [ -z "$STORE_DIR" ]; then
  STORE_DIR="$HOME/.password-store"
fi

if [ ! -d "$STORE_DIR/.git" ]; then
  echo "No git password store was found at $STORE_DIR"
  exit 1
fi

branch="$(git -C "$STORE_DIR" rev-parse --abbrev-ref HEAD)"
if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  branch="main"
fi

next_store_version() {
  local latest patch
  latest="$(git -C "$STORE_DIR" tag --list 'v0.0.*' | sed 's/^v//' | sort | tail -n1 || true)"
  if [ -z "$latest" ]; then
    printf '0.0.0001'
    return
  fi
  patch="${latest##*.}"
  patch=$((10#${patch} + 1))
  printf '0.0.%04d' "$patch"
}

write_store_hash() {
  local version="$1"
  local manifest hash
  manifest="$(mktemp)"
  (
    cd "$STORE_DIR"
    find . -path './.git' -prune -o -type f ! -name "$STORE_HASH_FILE" -print0 |
      sort -z |
      while IFS= read -r -d '' file; do
        sha256sum "$file"
      done
  ) > "$manifest"
  hash="$(sha256sum "$manifest" | awk '{print $1}')"
  rm -f "$manifest"
  printf '%s  v%s\n' "$hash" "$version" > "$STORE_DIR/$STORE_HASH_FILE"
}

git -C "$STORE_DIR" config pull.rebase false
git -C "$STORE_DIR" fetch origin

status="$(git -C "$STORE_DIR" status --porcelain)"
version=""

if [ -n "$status" ]; then
  version="$(next_store_version)"
  write_store_hash "$version"
fi

git -C "$STORE_DIR" add -A

if [ -n "$(git -C "$STORE_DIR" diff --cached --stat)" ]; then
  git -C "$STORE_DIR" commit -m "syncpss: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

git -C "$STORE_DIR" pull --no-rebase origin "$branch"
git -C "$STORE_DIR" push origin "$branch"

if [ -n "$version" ]; then
  git -C "$STORE_DIR" tag -a "v$version" -m "pass-store v$version"
  git -C "$STORE_DIR" push origin "v$version"
  echo "Password store synced and tagged as v$version"
else
  echo "Password store was already clean; fetch/pull/push completed."
fi
'@

    $scriptPath = Write-WslScriptFile `
        -DistroName $selectedDistro `
        -LinuxUser $selectedUser `
        -FileName "release_pass_store_sync.sh" `
        -Content $syncScript

    & wsl.exe -d $selectedDistro -u $selectedUser -- bash $scriptPath
    $exitCode = [int]$LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Pass-store sync exited with code $exitCode"
    }
}

function Get-ReleaseCommitPrefix {
    param([Parameter(Mandatory = $true)][string]$Version)

    return "[syncpss: release v${Version}: "
}

function Get-ReleaseCommitSummary {
    param([AllowEmptyString()][string]$Message)

    $trimmed = if ($null -eq $Message) { "" } else { $Message.Trim() }
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return "release prep"
    }

    if ($trimmed -match '^\[syncpss: release v[^:]+:\s*(.*?)\]$') {
        $summary = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($summary)) {
            return $summary
        }
    }

    return $trimmed
}

function ConvertTo-ReleaseCommitMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [AllowEmptyString()][string]$Summary
    )

    $resolvedSummary = Get-ReleaseCommitSummary -Message $Summary
    return ((Get-ReleaseCommitPrefix -Version $Version) + $resolvedSummary + "]")
}

function Prompt-ReleaseCommitMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [AllowEmptyString()][string]$DefaultSummary,
        [Parameter(Mandatory = $true)][string]$PromptMessage
    )

    $resolvedSummary = Get-ReleaseCommitSummary -Message $DefaultSummary
    $defaultMessage = ConvertTo-ReleaseCommitMessage -Version $Version -Summary $resolvedSummary
    if ($NonInteractive) {
        return $defaultMessage
    }

    Write-Host ("Commit message: {0}" -f $defaultMessage) -ForegroundColor Cyan
    $enteredSummary = Read-Host "$PromptMessage [$resolvedSummary]"
    if ([string]::IsNullOrWhiteSpace($enteredSummary)) {
        $enteredSummary = $resolvedSummary
    }

    $commitMessage = ConvertTo-ReleaseCommitMessage -Version $Version -Summary $enteredSummary
    Write-Host ("Using commit message: {0}" -f $commitMessage) -ForegroundColor Cyan
    return $commitMessage
}

function Test-CanRecommitLastCommit {
    git rev-parse --verify HEAD~1 | Out-Null
    return $LASTEXITCODE -eq 0
}

function Get-LastCommitMessage {
    $message = git log -1 --pretty=%B
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read the last commit message."
    }

    return (($message | Out-String).Trim())
}

function Test-ManifestUpdatedAtOnlyWorktreeChange {
    param([Parameter(Mandatory = $true)][string[]]$StatusLines)

    $normalizedStatus = @(
        $StatusLines |
            ForEach-Object { ($_ | Out-String).TrimEnd() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($normalizedStatus.Count -ne 1) {
        return $false
    }

    $statusEntry = $normalizedStatus[0]
    if ($statusEntry.Length -lt 4) {
        return $false
    }

    $path = $statusEntry.Substring(3).Trim()
    if ($path -ne "manifest.xml") {
        return $false
    }

    $diffLines = git diff --no-ext-diff --no-color --unified=0 HEAD -- manifest.xml
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect manifest.xml changes."
    }

    $contentLines = @(
        $diffLines |
            ForEach-Object { ($_ | Out-String).TrimEnd() } |
            Where-Object {
                (-not [string]::IsNullOrWhiteSpace($_)) -and
                ($_ -notmatch '^(diff --git|index |--- |\+\+\+ |@@ )')
            }
    )

    if ($contentLines.Count -ne 2) {
        return $false
    }

    return (
        ($contentLines[0] -match '^\-\s*<updated_at>.*</updated_at>$') -and
        ($contentLines[1] -match '^\+\s*<updated_at>.*</updated_at>$')
    )
}

function Invoke-ManifestOnlyRecommitFlow {
    param([Parameter(Mandatory = $true)][string]$Version)

    $lastCommitMessage = Get-LastCommitMessage
    Write-Host "Only manifest.xml changed, and the diff is just the updated_at timestamp." -ForegroundColor Yellow
    Write-Host ("Last commit message: {0}" -f $lastCommitMessage) -ForegroundColor Cyan

    if (-not (Prompt-YesNo -Message "Soft-reset the last commit and recommit it for v$Version?" -DefaultYes $true)) {
        return $false
    }

    git reset --soft HEAD~1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to soft-reset the last commit."
    }

    $defaultSummary = Get-ReleaseCommitSummary -Message $lastCommitMessage
    while ($true) {
        Write-Host "  [1] Use the last commit message"
        Write-Host "  [2] Enter a new release summary"
        $selection = Read-Host "Choose commit message flow [1]"
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq "1") {
            $commitMessage = ConvertTo-ReleaseCommitMessage -Version $Version -Summary $defaultSummary
            Write-Host ("Using commit message: {0}" -f $commitMessage) -ForegroundColor Cyan
            break
        }
        if ($selection -eq "2") {
            $commitMessage = Prompt-ReleaseCommitMessage -Version $Version -DefaultSummary $defaultSummary -PromptMessage "Release commit summary"
            break
        }
        Write-Host "Invalid selection." -ForegroundColor Red
    }

    git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) {
        throw "git commit failed after the soft reset."
    }

    return $true
}

function Ensure-CleanOrCommit {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [AllowEmptyString()][string]$ReleaseVersion
    )

    if ([string]::IsNullOrWhiteSpace($ReleaseVersion)) {
        $ReleaseVersion = $MinimumReleaseVersion
    }

    $status = git status --short
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed"
    }

    if ([string]::IsNullOrWhiteSpace(($status -join "`n"))) {
        return
    }

    if ((-not $NonInteractive) -and (Test-CanRecommitLastCommit) -and (Test-ManifestUpdatedAtOnlyWorktreeChange -StatusLines $status)) {
        if (Invoke-ManifestOnlyRecommitFlow -Version $ReleaseVersion) {
            $status = git status --short
            if ($LASTEXITCODE -ne 0) {
                throw "git status failed after recommit"
            }
            if ([string]::IsNullOrWhiteSpace(($status -join "`n"))) {
                return
            }
            throw "Worktree is still dirty after recommitting. Resolve the remaining changes and retry."
        }
    }

    Write-Host
    Write-Host "Working tree has uncommitted changes:" -ForegroundColor Yellow
    $status | ForEach-Object { Write-Host "  $_" }
    Write-Host

    if (-not (Prompt-YesNo -Message "Stage all changes and create a commit before releasing?" -DefaultYes $true)) {
        throw "Release cancelled because the worktree is dirty."
    }

    git add -A
    if ($LASTEXITCODE -ne 0) {
        throw "git add -A failed"
    }

    $commitMessage = Prompt-ReleaseCommitMessage -Version $ReleaseVersion -DefaultSummary "release prep" -PromptMessage "Release commit summary"

    git commit -m $commitMessage
    if ($LASTEXITCODE -ne 0) {
        throw "git commit failed"
    }

    $status = git status --short
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed after commit"
    }
    if (-not [string]::IsNullOrWhiteSpace(($status -join "`n"))) {
        throw "Worktree is still dirty after committing. Resolve the remaining changes and retry."
    }
}

function Resolve-RequestedVersion {
    param(
        [AllowEmptyString()][string]$RequestedVersion,
        [AllowNull()][string]$ProjectVersion,
        [AllowNull()][string]$CurrentVersion
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
        if (-not (Test-SemVerFormat -Value $RequestedVersion)) {
            throw "Version must use x.y.z format, for example 1.0.0"
        }
        if ((Compare-SemVer -Left $RequestedVersion -Right $MinimumReleaseVersion) -lt 0) {
            throw "Minimum release version is $MinimumReleaseVersion"
        }
        return $RequestedVersion
    }

    if ($null -ne $CurrentVersion) {
        return $CurrentVersion
    }

    if ($null -ne $ProjectVersion -and (Test-SemVerFormat -Value $ProjectVersion) -and (Compare-SemVer -Left $ProjectVersion -Right $MinimumReleaseVersion) -ge 0) {
        Write-Host "No published release exists yet. Using project version $ProjectVersion for the first release." -ForegroundColor Yellow
        return $ProjectVersion
    }

    Write-Host "No published release exists yet. Falling back to first release version $MinimumReleaseVersion." -ForegroundColor Yellow
    return $MinimumReleaseVersion
}

function Get-SafeReleaseVersion {
    param(
        [AllowEmptyString()][string]$Candidate,
        [AllowNull()][string]$ProjectVersion
    )

    if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
        return $Candidate.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectVersion) -and (Test-SemVerFormat -Value $ProjectVersion)) {
        return $ProjectVersion.Trim()
    }

    return $MinimumReleaseVersion
}

function New-GitHubReleaseWithAssets {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string[]]$Assets
    )

    Write-Host "Creating GitHub release metadata for $Tag..." -ForegroundColor Cyan
    gh release create $Tag `
      --verify-tag `
      --latest `
      --title "Release $Tag" `
      --generate-notes
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create GitHub release $Tag"
    }

    foreach ($asset in $Assets) {
        $assetName = Split-Path -Path $asset -Leaf
        Write-Host ("Uploading asset: {0}" -f $assetName) -ForegroundColor Cyan
        gh release upload $Tag $asset --clobber
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to upload release asset $assetName"
        }
    }
}

function Remove-LocalTagIfPresent {
    param([Parameter(Mandatory = $true)][string]$Tag)

    if (Test-LocalTagExists -Tag $Tag) {
        Write-Host "Local tag $Tag already exists. Replacing it automatically." -ForegroundColor Yellow
        git tag -d $Tag | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete local tag $Tag"
        }
    }
}

function Invoke-ReleaseBranchPush {
    param(
        [Parameter(Mandatory = $true)][string]$Branch,
        [AllowNull()][string]$ReleaseVersion
    )

    function New-ReleasePullRequestBranchName {
        param(
            [Parameter(Mandatory = $true)][string]$SourceBranch,
            [AllowNull()][string]$Version
        )

        $safeSource = ($SourceBranch -replace '[^0-9A-Za-z._-]+', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($safeSource)) {
            $safeSource = "sync"
        }

        $safeVersion = if ([string]::IsNullOrWhiteSpace($Version)) {
            "adhoc"
        } else {
            (($Version -replace '[^0-9A-Za-z._-]+', '-') -replace '^-+|-+$', '')
        }
        if ([string]::IsNullOrWhiteSpace($safeVersion)) {
            $safeVersion = "adhoc"
        }

        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        return "release/$safeSource-v$safeVersion-$timestamp"
    }

    function Publish-ReleasePullRequestBranch {
        param(
            [Parameter(Mandatory = $true)][string]$SourceBranch,
            [AllowNull()][string]$Version
        )

        $pullRequestBranch = New-ReleasePullRequestBranchName -SourceBranch $SourceBranch -Version $Version
        Write-Host "Publishing current HEAD to $pullRequestBranch so GitHub can review it through a PR..." -ForegroundColor Cyan
        git push origin ("HEAD:refs/heads/{0}" -f $pullRequestBranch)
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to publish release branch $pullRequestBranch."
        }

        $pullRequestUrl = New-BranchPullRequest -BaseBranch "main" -HeadBranch $pullRequestBranch -ReleaseVersion $Version -SkipPrompt
        return [pscustomobject]@{
            Branch = $pullRequestBranch
            OpenedPullRequest = $true
            PullRequestUrl = $pullRequestUrl
        }
    }

    while ($true) {
        git push origin $Branch
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{
                Branch = $Branch
                OpenedPullRequest = $false
                PullRequestUrl = ""
            }
        }

        if ($NonInteractive) {
            throw "Failed to push branch $Branch. Remote changes or a ruleset are blocking direct pushes; publish a PR branch manually and retry."
        }

        Write-Host "Remote branch $Branch has new commits that are not in your local branch." -ForegroundColor Yellow
        Write-Host "If GitHub requires pull requests on this branch, you can publish a fresh release branch instead." -ForegroundColor Yellow
        Write-Host "Run Push?" -ForegroundColor Yellow
        Write-Host "  [p] Publish a release branch and open PR"
        Write-Host "  [r] Pull with rebase, then retry push"
        Write-Host "  [f] Force push with --force-with-lease"
        Write-Host "  [c] Cancel release"

        $selection = Read-Host "Choose push flow [p]"
        if ([string]::IsNullOrWhiteSpace($selection)) {
            $selection = "p"
        }

        switch ($selection.Trim().ToLowerInvariant()) {
            "p" {
                return Publish-ReleasePullRequestBranch -SourceBranch $Branch -Version $ReleaseVersion
            }
            "r" {
                git pull --rebase origin $Branch
                if ($LASTEXITCODE -ne 0) {
                    throw "Pull --rebase failed for branch $Branch. Resolve it, then rerun the release."
                }
            }
            "f" {
                git push --force-with-lease origin $Branch
                if ($LASTEXITCODE -eq 0) {
                    return
                }
                throw "Force push failed for branch $Branch."
            }
            "c" {
                throw "Release cancelled before branch push."
            }
            default {
                Write-Host "Invalid selection." -ForegroundColor Red
            }
        }
    }
}

function Get-ExistingPullRequestUrl {
    param(
        [Parameter(Mandatory = $true)][string]$BaseBranch,
        [Parameter(Mandatory = $true)][string]$HeadBranch
    )

    $url = gh pr list --base $BaseBranch --head $HeadBranch --state open --limit 1 --json url --jq '.[0].url' 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect pull requests for branch $HeadBranch."
    }

    $normalized = (($url | Out-String) -replace "`0", "").Trim()
    if ($normalized -eq "null") {
        return ""
    }

    return $normalized
}

function New-BranchPullRequest {
    param(
        [Parameter(Mandatory = $true)][string]$BaseBranch,
        [Parameter(Mandatory = $true)][string]$HeadBranch,
        [AllowNull()][string]$ReleaseVersion,
        [switch]$SkipPrompt
    )

    $existingUrl = Get-ExistingPullRequestUrl -BaseBranch $BaseBranch -HeadBranch $HeadBranch
    if (-not [string]::IsNullOrWhiteSpace($existingUrl)) {
        Write-Host "Open pull request already exists: $existingUrl" -ForegroundColor Green
        return $existingUrl
    }

    $createPullRequest = $true
    if ((-not $NonInteractive) -and (-not $SkipPrompt)) {
        $createPullRequest = Prompt-YesNo -Message "Create a pull request from $HeadBranch into $BaseBranch now?" -DefaultYes $true
    }

    if (-not $createPullRequest) {
        Write-Host "Pull request creation skipped." -ForegroundColor Yellow
        return ""
    }

    $title = if (-not [string]::IsNullOrWhiteSpace($ReleaseVersion)) {
        "syncpss: release v$ReleaseVersion from $HeadBranch"
    } else {
        "syncpss: sync $HeadBranch into $BaseBranch"
    }

    $body = @"
This pull request was created automatically by scripts\cd.bat after pushing branch '$HeadBranch'.

GitHub Actions will run the branch push checks and the pull request checks automatically.
"@

    Write-Host "Creating pull request from $HeadBranch into $BaseBranch..." -ForegroundColor Cyan
    gh pr create --base $BaseBranch --head $HeadBranch --title $title --body $body
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create pull request from $HeadBranch into $BaseBranch."
    }

    $createdUrl = Get-ExistingPullRequestUrl -BaseBranch $BaseBranch -HeadBranch $HeadBranch
    if (-not [string]::IsNullOrWhiteSpace($createdUrl)) {
        Write-Host "Pull request created: $createdUrl" -ForegroundColor Green
    }

    return $createdUrl
}

function Commit-ReleaseMetadataIfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseVersion
    )

    git add -- manifest.xml
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stage manifest.xml."
    }

    git add -f -- master_fingerprint.sha256
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to stage release metadata files."
    }

    $status = git status --short -- manifest.xml master_fingerprint.sha256
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect release metadata git status."
    }

    if ([string]::IsNullOrWhiteSpace(($status -join "`n"))) {
        return
    }

    git commit -m "[syncpss: release v${ReleaseVersion}: refresh release metadata]"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to commit refreshed release metadata."
    }
}

function Prompt-ReleaseVersionChoice {
    param(
        [AllowNull()][string]$CurrentVersion,
        [AllowNull()][string]$ProjectVersion
    )

    if ($NonInteractive) {
        return Resolve-RequestedVersion -RequestedVersion $Version -ProjectVersion $ProjectVersion -CurrentVersion $CurrentVersion
    }

    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
        return Resolve-RequestedVersion -RequestedVersion $Version -ProjectVersion $ProjectVersion -CurrentVersion $CurrentVersion
    }

    Write-Host
    Write-Host "No release version was provided." -ForegroundColor Yellow
    Write-Host "Current published version: v$CurrentVersion"
    Write-Host "Minimum allowed version: $MinimumReleaseVersion"
    Write-Host "  [1] Overwrite current release v$CurrentVersion"
    Write-Host "  [2] Enter a new release version"

    while ($true) {
        $selection = Read-Host "Choose release version flow [1]"
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq "1") {
            return $CurrentVersion
        }
        if ($selection -eq "2") {
            while ($true) {
                $enteredVersion = Read-Host "Enter new release version (minimum $MinimumReleaseVersion)"
                if ([string]::IsNullOrWhiteSpace($enteredVersion)) {
                    Write-Host "Please enter a version." -ForegroundColor Yellow
                    continue
                }
                return Resolve-RequestedVersion -RequestedVersion $enteredVersion -ProjectVersion $ProjectVersion -CurrentVersion $CurrentVersion
            }
        }
    }
}

function Invoke-Release {
    $repoRoot = Get-ReleaseRepoRoot
    Set-Location -LiteralPath $repoRoot

    if ($SigningReadiness) {
        $readiness = Show-ReleaseSigningReadiness -RepoRoot $repoRoot
        if (-not $readiness.IsReady) {
            throw $readiness.Message
        }
        return
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) is required."
    }
    gh auth status | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run 'gh auth login'."
    }

    if ($PassStoreOnly) {
        Invoke-PassStoreSync -RequestedDistro $Distro
        Write-Host
        Write-Host "Pass-store sync completed." -ForegroundColor Green
        return
    }

    $continueWithAppRelease = $true
    if (-not $NonInteractive) {
        if (Prompt-YesNo -Message "Run the optional WSL pass-store sync/version bump first?" -DefaultYes $false) {
            Invoke-PassStoreSync -RequestedDistro $Distro
            Write-Host
            $continueWithAppRelease = Prompt-YesNo -Message "Continue with the syncpss app release too?" -DefaultYes $false
            if (-not $continueWithAppRelease) {
                Write-Host "Pass-store sync completed. App release skipped." -ForegroundColor Green
                return
            }
        }
    }

    Assert-ExpectedOrigin

    $projectVersion = Get-ProjectVersion -RepoRoot $repoRoot
    $remoteVersions = @(Get-RemoteVersions)
    $currentVersion = if ($remoteVersions.Count -gt 0) { $remoteVersions[0] } else { $null }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $requestedVersion = Prompt-ReleaseVersionChoice -CurrentVersion $currentVersion -ProjectVersion $projectVersion
    } else {
        $requestedVersion = Resolve-RequestedVersion -RequestedVersion $Version -ProjectVersion $projectVersion -CurrentVersion $currentVersion
    }
    $requestedVersion = Get-SafeReleaseVersion -Candidate $requestedVersion -ProjectVersion $projectVersion
    $expectedRepoIdHash = Get-ExpectedMaintainerIdHash -RepoRoot $repoRoot
    $repoIdSeed = Get-RepoIdSeed -RepoRoot $repoRoot
    if ([string]::IsNullOrWhiteSpace($repoIdSeed)) {
        $repoIdHashForRelease = $expectedRepoIdHash
        Write-Host "Using the existing repo maintainer hash from config\maintainer_id.sha256 for this release." -ForegroundColor Yellow
    } else {
        $repoIdSeedHash = Get-RepoIdSeedHash -Seed $repoIdSeed
        if ($repoIdSeedHash -ne $expectedRepoIdHash) {
            throw "SYNCPSS_MAINTAINER_ID hash mismatch. Expected $expectedRepoIdHash but found $repoIdSeedHash against config\maintainer_id.sha256."
        }
        $repoIdHashForRelease = $repoIdSeedHash
    }
    Update-RepoManifest -RepoRoot $repoRoot -Version $requestedVersion -RepoIdHashValue $repoIdHashForRelease

    $branch = git branch --show-current
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to determine current branch."
    }
    $branch = ($branch | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw "Release must be created from a named branch, not a detached HEAD."
    }

    Ensure-CleanOrCommit -RepoRoot $repoRoot -ReleaseVersion $requestedVersion

    $overwriteExisting = $false
    if ([string]::IsNullOrWhiteSpace($Version) -and $null -ne $currentVersion) {
        $overwriteExisting = $true
        Write-Host "No version was provided. Releasing by overwriting the current published version v$requestedVersion." -ForegroundColor Yellow
    } elseif ($null -ne $currentVersion) {
        $comparison = Compare-SemVer -Left $requestedVersion -Right $currentVersion
        if ($comparison -lt 0) {
            $requestedTag = "v$requestedVersion"
            $versionExists = (Test-RemoteTagExists -Tag $requestedTag) -or (Test-GitHubReleaseExists -Tag $requestedTag) -or (Test-LocalTagExists -Tag $requestedTag)
            if (-not $versionExists) {
                throw "v$requestedVersion is older than the current release v$currentVersion. Older versions can only be recreated by overwriting an existing release version."
            }
            $overwriteExisting = $true
            Write-Host "Requested version v$requestedVersion is older than current v$currentVersion. Overwriting release v$requestedVersion automatically." -ForegroundColor Yellow
        } elseif ($comparison -eq 0) {
            $overwriteExisting = $true
            Write-Host "Requested version v$requestedVersion matches the current release. Overwriting it automatically." -ForegroundColor Yellow
        } else {
            Write-Host "Requested version v$requestedVersion is newer than current v$currentVersion. Creating a new release automatically." -ForegroundColor Green
        }
    } else {
        Write-Host "No published release exists yet. Creating initial release v$requestedVersion." -ForegroundColor Green
    }

    $tag = "v$requestedVersion"

    if (-not $SkipBuild) {
        $buildScript = Join-Path $repoRoot "scripts\build.bat"
        $buildArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($Distro)) {
            $buildArgs += $Distro
        }
        if ($InstallDeps) {
            $buildArgs += "-InstallDeps"
        }
        if ($EnableClangTidy) {
            $buildArgs += "-EnableClangTidy"
        }

        & cmd /c "`"$buildScript`" --no-pause $($buildArgs -join ' ')"
        if ($LASTEXITCODE -ne 0) {
            throw "Build step failed; aborting release."
        }
    }

    Write-MasterFingerprintAssets -RepoRoot $repoRoot
    Write-ReleaseBundle -RepoRoot $repoRoot
    Commit-ReleaseMetadataIfNeeded -ReleaseVersion $requestedVersion

    $requiredAssets = Get-ReleaseAssetRelativePaths | ForEach-Object { Join-Path $repoRoot $_ }

    $missingAssets = @($requiredAssets | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingAssets.Count -gt 0) {
        throw ("Missing release assets:`n" + (($missingAssets | ForEach-Object { " - $_" }) -join "`n"))
    }

    $signingInfo = Assert-GpgSigningReady -RepoRoot $repoRoot
    Write-Host ("Using Windows GPG signing key {0}" -f $signingInfo.Fingerprint) -ForegroundColor Cyan
    Remove-StaleReleaseSignatureFiles -RepoRoot $repoRoot
    $signedAssets = Get-SignedReleaseAssetRelativePaths | ForEach-Object { Join-Path $repoRoot $_ }
    Write-DetachedReleaseSignatures -SigningInfo $signingInfo -Assets $signedAssets
    $releaseAssets = @($requiredAssets + ($signedAssets | ForEach-Object { "$_.asc" }))
    Write-Host "Release assets staged for upload:" -ForegroundColor Cyan
    $releaseAssets | ForEach-Object { Write-Host ("  - {0}" -f (Split-Path -Path $_ -Leaf)) }

    $pushResult = Invoke-ReleaseBranchPush -Branch $branch -ReleaseVersion $requestedVersion
    if ($pushResult.OpenedPullRequest) {
        Write-Host
        Write-Host "Direct push to $branch was blocked, so a reviewable PR branch was published instead." -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($pushResult.PullRequestUrl)) {
            Write-Host "Review and merge the release PR here: $($pushResult.PullRequestUrl)" -ForegroundColor Green
        }
        Write-Host "After that PR lands on main, rerun scripts\\cd.bat $requestedVersion to publish the signed release." -ForegroundColor Yellow
        return
    }

    if ($overwriteExisting) {
        Remove-ReleaseVersion -Tag $tag
    } else {
        Remove-LocalTagIfPresent -Tag $tag
        if (Test-RemoteTagExists -Tag $tag) {
            throw "Tag $tag already exists on origin."
        }
        if (Test-GitHubReleaseExists -Tag $tag) {
            throw "Release $tag already exists on GitHub."
        }
    }

    New-SignedReleaseTag -SigningInfo $signingInfo -Tag $tag

    git push origin $tag
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to push tag $tag"
    }

    New-GitHubReleaseWithAssets -Tag $tag -Assets $releaseAssets

    if ($branch -ne "main") {
        try {
            $pullRequestUrl = New-BranchPullRequest -BaseBranch "main" -HeadBranch $branch -ReleaseVersion $requestedVersion
            if (-not [string]::IsNullOrWhiteSpace($pullRequestUrl)) {
                Write-Host "Review the PR checks here: $pullRequestUrl" -ForegroundColor Green
            }
        } catch {
            Write-Warning "Release completed, but automatic pull request creation failed: $($_.Exception.Message)"
        }
    }

    Write-Host
    if ($overwriteExisting) {
        Write-Host "Release overwritten with uploaded assets: $tag"
    } else {
        Write-Host "Release created with uploaded assets: $tag"
    }
    Write-Host "Branch pushed: $branch"
    Write-Host "Watch GitHub Actions: https://github.com/KffeePt/syncpss/actions"
}

try {
    Invoke-Release
    exit 0
} catch {
    if (-not ($SigningReadiness -and $script:ReleaseStatusAlreadyPrinted)) {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    exit 1
}
