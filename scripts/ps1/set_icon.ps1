[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-GeneratorScriptPath {
    $path = Join-Path $PSScriptRoot "generate_windows_icon.ps1"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Windows icon generator is missing at '$path'."
    }

    return $path
}

function Get-CanonicalIconState {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $svgPath = Join-Path $RepoRoot "assets\icon.svg"
    $icoPath = Join-Path $RepoRoot "assets\icon.ico"
    $icoDir = Join-Path $RepoRoot "assets\ico"
    $binIco = Join-Path $RepoRoot "bin\syncpss-icon.ico"
    $installerRc = Join-Path $RepoRoot "src\installer\win\installer.rc"

    return [pscustomobject]@{
        RepoRoot = $RepoRoot
        SvgPath = $svgPath
        CanonicalIcoPath = $icoPath
        CanonicalIcoDirectory = $icoDir
        BinIcoPath = $binIco
        InstallerResourcePath = $installerRc
        SvgExists = (Test-Path -LiteralPath $svgPath)
        CanonicalIcoExists = (Test-Path -LiteralPath $icoPath)
        CanonicalIcoDirectoryExists = (Test-Path -LiteralPath $icoDir)
        BinIcoExists = (Test-Path -LiteralPath $binIco)
    }
}

function Show-IconStatus {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    Write-Host ""
    Write-Host "syncpss icon manager" -ForegroundColor Yellow
    Write-Host ("SVG source:              {0}" -f $State.SvgPath) -ForegroundColor Cyan
    Write-Host ("Canonical ICO:           {0}" -f $State.CanonicalIcoPath) -ForegroundColor Cyan
    Write-Host ("Per-size ICO dir:        {0}" -f $State.CanonicalIcoDirectory) -ForegroundColor Cyan
    Write-Host ("Bin shortcut ICO:        {0}" -f $State.BinIcoPath) -ForegroundColor Cyan
    Write-Host ("Installer resource file: {0}" -f $State.InstallerResourcePath) -ForegroundColor Cyan
    Write-Host ("SVG present:             {0}" -f $(if ($State.SvgExists) { "yes" } else { "no" })) -ForegroundColor Cyan
    Write-Host ("Canonical ICO present:   {0}" -f $(if ($State.CanonicalIcoExists) { "yes" } else { "no" })) -ForegroundColor Cyan
    Write-Host ("Per-size ICO dir exists: {0}" -f $(if ($State.CanonicalIcoDirectoryExists) { "yes" } else { "no" })) -ForegroundColor Cyan
    Write-Host ("Bin ICO present:         {0}" -f $(if ($State.BinIcoExists) { "yes" } else { "no" })) -ForegroundColor Cyan
}

function Invoke-IconGeneration {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$RefreshCanonicalAssets
    )

    $generatorPath = Get-GeneratorScriptPath
    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $generatorPath,
        "-RepoRoot", $RepoRoot
    )
    if ($RefreshCanonicalAssets) {
        $arguments += "-RefreshCanonicalAssets"
    }

    & powershell @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Icon generation failed."
    }
}

function Show-PerSizeIconList {
    param([Parameter(Mandatory = $true)][string]$IconDirectory)

    if (-not (Test-Path -LiteralPath $IconDirectory)) {
        Write-Host "No per-size ICO directory exists yet." -ForegroundColor Yellow
        return
    }

    Write-Host "Per-size ICO files:" -ForegroundColor Green
    Get-ChildItem -LiteralPath $IconDirectory -Filter "*.ico" -File | Sort-Object Name | ForEach-Object {
        Write-Host ("  - {0}" -f $_.Name) -ForegroundColor Green
    }
}

$repoRoot = Get-RepoRoot

while ($true) {
    $state = Get-CanonicalIconState -RepoRoot $repoRoot
    Show-IconStatus -State $state
    Write-Host ""
    Write-Host "  [1] Generate the full Windows icon set from assets\icon.svg"
    Write-Host "  [2] Refresh only the bin icon outputs from the canonical ICO"
    Write-Host "  [3] Show the generated per-size ICO filenames"
    Write-Host "  [4] Exit"

    $selection = Read-Host "Choose an option [4]"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        $selection = "4"
    }

    switch ($selection.Trim()) {
        "1" {
            Invoke-IconGeneration -RepoRoot $repoRoot -RefreshCanonicalAssets
            Write-Host "Canonical Windows icon assets were regenerated from assets\icon.svg." -ForegroundColor Green
            Write-Host "Rebuild the Windows installer to embed the refreshed icon into syncpss-wsl-installer.exe." -ForegroundColor Yellow
            [void](Read-Host "Press Enter to return to the icon manager")
        }
        "2" {
            Invoke-IconGeneration -RepoRoot $repoRoot
            Write-Host "Bin icon outputs were refreshed from the current canonical icon assets." -ForegroundColor Green
            [void](Read-Host "Press Enter to return to the icon manager")
        }
        "3" {
            Show-PerSizeIconList -IconDirectory $state.CanonicalIcoDirectory
            [void](Read-Host "Press Enter to return to the icon manager")
        }
        "4" {
            exit 0
        }
        default {
            Write-Host "Invalid selection." -ForegroundColor Red
        }
    }
}
