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
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "maintainer_id.ps1")

$MinimumReleaseVersion = "1.0.0"
$RepoManifestPath = "manifest.xml"
$MasterFingerprintPath = "master_fingerprint.sha256"
$ReleaseBundlePath = "syncpss-release-binaries.zip"

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
    $signingKey = git config --get user.signingkey
    if ($LASTEXITCODE -ne 0) {
        return ""
    }
    return (($signingKey | Out-String).Trim())
}

function Get-GpgExecutablePath {
    $gpg = Get-Command gpg -ErrorAction SilentlyContinue
    if ($null -eq $gpg) {
        throw "gpg is required for signed tags and detached release signatures. Install Gpg4win on Windows and retry."
    }
    return $gpg.Source
}

function Get-GpgSecretKeyFingerprint {
    param([AllowEmptyString()][string]$KeySpecifier = "")

    $listArgs = @("--list-secret-keys", "--keyid-format=long", "--with-colons")
    if (-not [string]::IsNullOrWhiteSpace($KeySpecifier)) {
        $listArgs += $KeySpecifier
    }

    $secretKeyOutput = & gpg @listArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

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
                return $parts[9].Trim()
            }
        }
    }

    return ""
}

function Resolve-UsableGpgSigningKey {
    $configuredSigningKey = Get-GitSigningKey
    if (-not [string]::IsNullOrWhiteSpace($configuredSigningKey)) {
        $configuredFingerprint = Get-GpgSecretKeyFingerprint -KeySpecifier $configuredSigningKey
        if (-not [string]::IsNullOrWhiteSpace($configuredFingerprint)) {
            return [pscustomobject]@{
                Fingerprint = $configuredFingerprint
                Requested    = $configuredSigningKey
                UsedFallback  = $false
            }
        }
    }

    $defaultFingerprint = Get-GpgSecretKeyFingerprint
    if (-not [string]::IsNullOrWhiteSpace($defaultFingerprint)) {
        return [pscustomobject]@{
            Fingerprint = $defaultFingerprint
            Requested    = $configuredSigningKey
            UsedFallback  = -not [string]::IsNullOrWhiteSpace($configuredSigningKey)
        }
    }

    if ([string]::IsNullOrWhiteSpace($configuredSigningKey)) {
        throw "No usable Windows GPG secret key was found. Install Gpg4win, import your key, and retry."
    }

    throw "No usable Windows GPG secret key was found for git user.signingkey '$configuredSigningKey'. Install or import it through Gpg4win and retry."
}

function Assert-GpgSigningReady {
    $gpgProgram = Get-GpgExecutablePath

    $resolvedKey = Resolve-UsableGpgSigningKey
    if ($resolvedKey.UsedFallback -and -not [string]::IsNullOrWhiteSpace($resolvedKey.Requested)) {
        Write-Host ("Configured git user.signingkey '{0}' does not have a usable secret key. Falling back to Windows GPG key {1}." -f $resolvedKey.Requested, $resolvedKey.Fingerprint) -ForegroundColor Yellow
    }

    return [pscustomobject]@{
        GpgProgram  = $gpgProgram
        Fingerprint = $resolvedKey.Fingerprint
    }
}

function Write-DetachedReleaseSignatures {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$SigningInfo,
        [Parameter(Mandatory = $true)][string[]]$Assets
    )

    foreach ($asset in $Assets) {
        $signaturePath = "$asset.asc"
        if (Test-Path -LiteralPath $signaturePath) {
            Remove-Item -LiteralPath $signaturePath -Force
        }

        Write-Host ("Signing asset: {0}" -f (Split-Path -Path $asset -Leaf)) -ForegroundColor Cyan
        & gpg --yes --local-user $SigningInfo.Fingerprint --armor --detach-sign --output $signaturePath $asset
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create detached signature for $asset"
        }

        & gpg --verify $signaturePath $asset | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Detached signature verification failed for $asset"
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

    & git @tagArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create signed tag $Tag"
    }

    & git -c gpg.format=openpgp -c "gpg.program=$($SigningInfo.GpgProgram)" tag -v $Tag | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Signed tag verification failed for $Tag"
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

    $defaultMessage = "syncpss: release v$ReleaseVersion"
    $commitMessage = Read-Host "Commit message [$defaultMessage]"
    if ([string]::IsNullOrWhiteSpace($commitMessage)) {
        $commitMessage = $defaultMessage
    }

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

    git commit -m "syncpss: refresh release metadata for v$ReleaseVersion"
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
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) is required."
    }
    gh auth status | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run 'gh auth login'."
    }

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    Set-Location -LiteralPath $repoRoot

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

    $signingInfo = Assert-GpgSigningReady
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
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
