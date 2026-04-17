[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$SourceSvg = "",
    [string]$OutputDir = "",
    [switch]$RefreshCanonicalAssets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-EffectiveRepoRoot {
    param([string]$RequestedRepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRepoRoot)) {
        return (Resolve-Path -LiteralPath $RequestedRepoRoot).Path
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-EffectiveAssetPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$DefaultRelativePath,
        [string]$RequestedPath = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if ([System.IO.Path]::IsPathRooted($RequestedPath)) {
            return $RequestedPath
        }

        return (Join-Path $RepoRoot $RequestedPath)
    }

    return (Join-Path $RepoRoot $DefaultRelativePath)
}

function Get-IconSizes {
    return @(16, 24, 32, 48, 64, 128, 256)
}

function Get-EmbeddedPngBytes {
    param([Parameter(Mandatory = $true)][string]$SvgPath)

    $svgContent = [System.IO.File]::ReadAllText($SvgPath)
    $match = [System.Text.RegularExpressions.Regex]::Match(
        $svgContent,
        'href="data:image/png;base64,([^"]+)"',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        throw "The SVG does not contain an embedded PNG data URL: $SvgPath"
    }

    return [System.Convert]::FromBase64String($match.Groups[1].Value)
}

function New-ResizedPngBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$SourceBytes,
        [int]$Size = 256
    )

    Add-Type -AssemblyName System.Drawing

    $inputStream = New-Object System.IO.MemoryStream(,$SourceBytes)
    try {
        $sourceImage = [System.Drawing.Image]::FromStream($inputStream)
        try {
            $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.Clear([System.Drawing.Color]::Transparent)
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.DrawImage($sourceImage, 0, 0, $Size, $Size)
                } finally {
                    $graphics.Dispose()
                }

                $outputStream = New-Object System.IO.MemoryStream
                try {
                    $bitmap.Save($outputStream, [System.Drawing.Imaging.ImageFormat]::Png)
                    return $outputStream.ToArray()
                } finally {
                    $outputStream.Dispose()
                }
            } finally {
                $bitmap.Dispose()
            }
        } finally {
            $sourceImage.Dispose()
        }
    } finally {
        $inputStream.Dispose()
    }
}

function Write-IcoFromPng {
    param(
        [Parameter(Mandatory = $true)][byte[]]$PngBytes,
        [Parameter(Mandatory = $true)][string]$IcoPath
    )

    $fileStream = [System.IO.File]::Open($IcoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $writer = New-Object System.IO.BinaryWriter($fileStream)
        try {
            $writer.Write([UInt16]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]1)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$PngBytes.Length)
            $writer.Write([UInt32]22)
            $writer.Write($PngBytes)
        } finally {
            $writer.Dispose()
        }
    } finally {
        $fileStream.Dispose()
    }
}

function Write-IcoFile {
    param(
        [Parameter(Mandatory = $true)][byte[][]]$PngImages,
        [Parameter(Mandatory = $true)][int[]]$Sizes,
        [Parameter(Mandatory = $true)][string]$IcoPath
    )

    if ($PngImages.Count -ne $Sizes.Count) {
        throw "ICO image size metadata must line up with the PNG payload count."
    }

    $fileStream = [System.IO.File]::Open($IcoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $writer = New-Object System.IO.BinaryWriter($fileStream)
        try {
            $writer.Write([UInt16]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]$PngImages.Count)

            $offset = 6 + (16 * $PngImages.Count)
            for ($i = 0; $i -lt $PngImages.Count; $i++) {
                $size = $Sizes[$i]
                $pngBytes = $PngImages[$i]
                $dimensionByte = if ($size -ge 256) { [byte]0 } else { [byte]$size }

                $writer.Write($dimensionByte)
                $writer.Write($dimensionByte)
                $writer.Write([byte]0)
                $writer.Write([byte]0)
                $writer.Write([UInt16]1)
                $writer.Write([UInt16]32)
                $writer.Write([UInt32]$pngBytes.Length)
                $writer.Write([UInt32]$offset)

                $offset += $pngBytes.Length
            }

            for ($i = 0; $i -lt $PngImages.Count; $i++) {
                $writer.Write($PngImages[$i])
            }
        } finally {
            $writer.Dispose()
        }
    } finally {
        $fileStream.Dispose()
    }
}

$resolvedRepoRoot = Get-EffectiveRepoRoot -RequestedRepoRoot $RepoRoot
$svgPath = Get-EffectiveAssetPath -RepoRoot $resolvedRepoRoot -DefaultRelativePath "assets\icon.svg" -RequestedPath $SourceSvg
$preferredIcoPath = Join-Path $resolvedRepoRoot "assets\icon.ico"
$canonicalIconDir = Join-Path $resolvedRepoRoot "assets\ico"

if (-not (Test-Path -LiteralPath $svgPath)) {
    Write-Host "Skipping Windows icon generation because the SVG source was not found: $svgPath" -ForegroundColor Yellow
    exit 0
}

$targetDir = if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
    if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $resolvedRepoRoot $OutputDir }
} else {
    Join-Path $resolvedRepoRoot "bin"
}

if (-not (Test-Path -LiteralPath $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir | Out-Null
}

$embeddedPng = Get-EmbeddedPngBytes -SvgPath $svgPath
$iconSizes = Get-IconSizes
$pngPayloads = New-Object System.Collections.Generic.List[byte[]]
foreach ($size in $iconSizes) {
    [void]$pngPayloads.Add((New-ResizedPngBytes -SourceBytes $embeddedPng -Size $size))
}
$pngImages = [byte[][]]$pngPayloads.ToArray()
$resizedPng = $pngImages[$pngImages.Length - 1]

if ($RefreshCanonicalAssets -or (-not (Test-Path -LiteralPath $preferredIcoPath))) {
    if (-not (Test-Path -LiteralPath $canonicalIconDir)) {
        New-Item -ItemType Directory -Path $canonicalIconDir | Out-Null
    }

    for ($i = 0; $i -lt $iconSizes.Count; $i++) {
        $size = $iconSizes[$i]
        $singleIcoPath = Join-Path $canonicalIconDir ("{0}.ico" -f $size)
        Write-IcoFromPng -PngBytes $pngImages[$i] -IcoPath $singleIcoPath
    }

    Write-IcoFile -PngImages $pngImages -Sizes $iconSizes -IcoPath $preferredIcoPath
}

$pngTarget = Join-Path $targetDir "syncpss-icon.png"
$icoTarget = Join-Path $targetDir "syncpss-icon.ico"
$svgTarget = Join-Path $targetDir "syncpss-icon.svg"

[System.IO.File]::WriteAllBytes($pngTarget, $resizedPng)
[System.IO.File]::Copy($svgPath, $svgTarget, $true)

if (Test-Path -LiteralPath $preferredIcoPath) {
    [System.IO.File]::Copy($preferredIcoPath, $icoTarget, $true)
} else {
    Write-IcoFromPng -PngBytes $resizedPng -IcoPath $icoTarget
}

Write-Host "Generated Windows icon assets:" -ForegroundColor Green
Write-Host "  $pngTarget"
Write-Host "  $icoTarget"
Write-Host "  $svgTarget"
if (Test-Path -LiteralPath $preferredIcoPath) {
    Write-Host "Canonical Windows ICO: $preferredIcoPath" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $canonicalIconDir) {
        Write-Host "Per-size ICO directory: $canonicalIconDir" -ForegroundColor Cyan
    }
} else {
    Write-Host "Committed assets\\icon.ico was not found, so the ICO was generated from the SVG source." -ForegroundColor Yellow
}
